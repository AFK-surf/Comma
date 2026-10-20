defmodule BridgeForTeams.TriageEngineAcceptanceTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Native Triage intake and Worker completion against a local project fixture.

  ClickHouse reads use an in-BEAM corpus. Ordinary assignment makes no model
  request. Scheduled evaluation uses a deterministic provider. Admission, trailing debounce, fences, PostgreSQL
  project context, identity projection, ledger and replay use production code.
  Ordinary intake uses its domain-owned internal Worker and leaves participation pending.

  The fixture includes twelve meetings, three project members and scoped Worker
  identities. Authorized meeting links and contact details remain in the frozen
  context. Credential values still fail the privacy check before evaluation.

  Selected cases create a canonical Task and submit a scripted Worker completion
  through the real provider APIs. Worker delivery uses no_wake, so it cannot call
  a model. Context settles through the result participant before later retrieval
  or scheduled reminder checks. Scheduled rechecks retain their own contract.
  """

  use BridgeForTeams.DataCase, async: false
  use SalixStore.QueueCase, queues: [:triage_product_effects]

  alias BridgeForTeams.Meetings
  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageEngineLiveHarness, as: Harness
  alias SalixIM.{ProviderReceipts, Triage}

  alias SalixIM.Triage.{
    AuditSink,
    Bucketing,
    ClickHousePatrol,
    IdentityContract,
    Ledger,
    ProductEffectWorker,
    RunFence
  }

  alias SalixStore.{CasRecord, Ids, Repo, TriagePatrolScanState, TriageProductRuntime, ULID}

  defmodule StubProvider do
    def complete(_messages, _tools, _opts),
      do: raise("ordinary intake must not call a selection model")
  end

  defmodule NoWakeWorkerDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      owner = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :triage_acceptance_owner)
      SystemsRuntime.Proc.send(owner, {:worker_command, agent, payload})

      SystemsRuntime.Proc.send(
        owner,
        {:worker_delivery, agent}
      )

      SalixAgent.deliver(agent, payload, Keyword.put(opts, :no_wake, true))
    end
  end

  # The provider checks that later evidence reaches the actual request.
  # Ordinary intake assigns a Worker. Scheduled rechecks retain their decision contract.
  defmodule LaterEvidenceProvider do
    import ExUnit.Assertions

    def complete(messages, tools, opts) do
      payload =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload)
      assert payload =~ Map.get(opts, "expected_evidence", "恢复仍未确认，下一步检查公网探测")
      SystemsRuntime.Proc.send(opts["test_pid"], {:stub_provider_called, tools})

      schema = opts["response_format"]["schema"]

      if get_in(schema, ["properties", "communication", "properties", "reason", "enum"]) ==
           ["worker_pending"] do
        snapshot =
          messages |> Enum.find(&(&1.role == "user")) |> Map.fetch!(:content) |> Jason.decode!()

        source = snapshot["slack_context"]["decision_target"]["source_ref"]
        {:final, Jason.encode!(Harness.assignment_decision(schema, [source]))}
      else
        product_decision(messages, opts)
      end
    end

    defp product_decision(messages, opts) do
      silence =
        opts["response_format"]["schema"]["properties"]["communication"]["anyOf"]
        |> Enum.find(&(get_in(&1, ["properties", "kind", "enum"]) == ["silence"]))

      snapshot =
        messages |> Enum.find(&(&1.role == "user")) |> Map.fetch!(:content) |> Jason.decode!()

      source = List.last(snapshot["slack_context"]["messages"])["source_ref"]
      assert source in silence["properties"]["source_refs"]["items"]["enum"]

      {:final,
       Jason.encode!(%{
         "schema" => "comma.triage-product-decision.v2",
         "communication" => %{
           "kind" => "silence",
           "reason" => "no_actionable_request",
           "source_refs" => [source]
         },
         "companion_reaction" => nil,
         "context_candidates" => [],
         "delegations" => [],
         "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
       })}
    end
  end

  setup context do
    SalixStore.S3.Fake.reset()
    unless SystemsRuntime.Proc.whereis(Ids), do: start_supervised!(Ids)

    :ok = Fixture.install_clickhouse_reader!(SystemsRuntime.Proc.self())

    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    Harness.seed_worker!(authority, project)
    Fixture.seed_meetings!(authority["group_id"])

    if context[:worker_context_completion] || context[:worker_effect],
      do: install_no_wake_worker_delivery!()

    %{authority: authority, project: project}
  end

  @tag :worker_effect
  test "one mirrored CH row drives the Runtime and assigns a Worker without a Slack write", ctx do
    %{authority: authority, project: project} = ctx

    namespace = "triage-ch-row-acceptance-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 100)

    # The deployment's review Runtime, which the patrol admits to: the test node runs none of its own.
    start_supervised!(
      {Triage.Runtime,
       name: Salix.Bindings.TriageReviewRuntime,
       mode: :review,
       namespace: SalixStore.TriageKeys.default_namespace()}
    )

    Fixture.put_thread([
      Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", "谁在跟进 Atlas 登录事故？")
    ])

    assert {:ok, scan_state} =
             TriagePatrolScanState.initial(%{
               "ingest_at" => "2026-09-01T00:00:00.000Z",
               "message_ts_us" => 0,
               "version" => 0
             })

    assert {:ok, %{created: 1, settled: 1, ineligible: 0, has_more?: false}} =
             ClickHousePatrol.scan(authority, scan_state,
               reader: Fixture.ClickHouseReader,
               cursor_revision: 7,
               limit: 50,
               authority_verifier: fn current -> if current == authority, do: :ok end
             )

    {:ok, message_ts_us} =
      SalixIM.SlackMessageMirror.Row.slack_ts_micros(Fixture.root_ts())

    event_id = clickhouse_event_id(authority, message_ts_us)
    assert {:ok, receipt} = ProviderReceipts.fetch_slack(authority["connect_id"], event_id)
    assert receipt["schema"] == "comma.slack-triage-event-receipt.v3"
    assert receipt["triage_event"]["source_mode"] == "clickhouse_etl"
    assert {:ok, :accepted} = Triage.Runtime.accept_current(server, authority, receipt)

    run = Fixture.await_run!(server)
    assert run["authoritative"] == true
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)

    assert %{rows: [[payload]]} =
             Repo.query!(
               "SELECT payload FROM triage_product_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    assert payload["ordinary_worker_assignment"] == true
    assert SalixIM.Triage.ProductObligation.valid?(payload)
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])

    assert {:ok, %{claimed: claimed, applied: applied, failed: 0}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               holder: "triage-ch-row-acceptance",
               batch_size: 50
             )

    assert claimed >= 1
    assert applied == claimed

    assert {:ok, [outcome]} = TriageProductRuntime.recent_outcomes(project.id)
    assert outcome.state == :applied
    assert outcome.result["adapter"] == "audit_sink"
    assert outcome.result["external_writes"] == 0
    assert outcome.result["communication"]["status"] == "recorded"
    assert outcome.result["communication"]["reason"] == "worker_pending"
    assert [%{"status" => "created"}] = outcome.result["metadata"]["delegations"]
    refute_receive {:slack_reply_posted, _}

    # Task admission checks the same channel window twice around preparation.
    assert Fixture.collected_source_reads() |> Enum.map(&elem(&1, 0)) == [
             "clickhouse.tail",
             "clickhouse.list_changes",
             "clickhouse.latest_states",
             "clickhouse.channel_current",
             "clickhouse.channel_current",
             "clickhouse.channel_current"
           ]
  end

  test "a fresh runtime recovers a pending channel batch and rejects the old timer", ctx do
    namespace = "triage-channel-restart-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    original = start_engine!(namespace, debounce_ms: 1_000)
    text = "Atlas follow-up needs a current owner"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
    receipt = Fixture.admit_root!(original, ctx.authority, "Ev-channel-restart", text)
    :ok = :sys.suspend(original)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(original), do: :sys.resume(original) end)

    recovered = start_engine!(namespace, debounce_ms: 50)

    start_supervised!(
      {SalixIM.Triage.ReceiptRecovery,
       name: nil,
       runtime: recovered,
       interval_ms: 5,
       full_ring_idle_ms: 50,
       held_poll_ms: 5,
       lease_key:
         "ctl/test/triage-channel-restart/#{SystemsRuntime.Proc.unique_integer([:positive])}",
       lease_ttl_ms: 1_000},
      id: SystemsRuntime.Proc.make_ref()
    )

    run = Fixture.await_run!(recovered)
    assert run["status"] == "evaluated"
    assert run["evaluator"]["request_count"] == 0
    assert Bucketing.load!(namespace, Bucketing.scope_key(receipt))["sealed_generations"] == []
    :ok = :sys.resume(original)
    assert {:ok, ^run} = Triage.replay(original, run["run_id"])
    refute_receive {:stub_provider_called, _tools}, 1_100
    assert Triage.ledger_records(original) == [run]
  end

  for credential <- [
        "OPENAI_API_KEY = opaque-fixture-secret",
        "api_key: `opaque-fixture-secret`",
        "`OPENAI_API_KEY` = `opaque-fixture-secret`"
      ] do
    @tag :credential_terminology
    test "credential material #{credential} is rejected before the model is called", ctx do
      server =
        start_engine!("triage-credential-#{SystemsRuntime.Proc.unique_integer([:positive])}",
          debounce_ms: 20
        )

      text = "Atlas 登录还是失败，帮忙看一下？ #{unquote(credential)}"
      Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
      Fixture.admit_root!(server, ctx.authority, "Ev-credential", text)

      run = Fixture.await_run!(server)
      assert run["status"] == "failed"
      assert run["decision"]["reason"] == "identity_projection_privacy_rejected"
      assert run["evaluator"] == %{}
      refute_receive {:stub_provider_called, _tools}, 100
    end
  end

  test "settles one authoritative evaluated run over a realistic project and replays it", ctx do
    %{authority: authority, project: project} = ctx

    # The bounded meeting source answers for a twelve-meeting group inside its
    # own deadline; anything else surfaces as `:triage_meeting_source_*` here
    # and the freeze below would never see a fact at all.
    assert {:ok, meetings} = Meetings.list_triage_meetings(project, limit: 25)
    assert length(meetings) == 12

    namespace = "triage-acceptance-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    server = start_engine!(namespace)

    Fixture.put_thread(unanswered_thread(authority))

    first = Fixture.admit_root!(server, authority, "Ev-acceptance-1", "Atlas 登录事故还需要确认处理人")

    second =
      Fixture.admit_reply!(server, authority, "Ev-acceptance-2", ts(2), "我记得周会里讨论过这件事")

    third =
      Fixture.admit_reply!(
        server,
        authority,
        "Ev-acceptance-3",
        ts(3),
        "谁在跟进 Atlas 登录事故？"
      )

    refute third["triage_event"]["fast_path"]
    refute first["triage_event"]["fast_path"]
    refute second["triage_event"]["fast_path"]

    run = Fixture.await_run!(server)

    ## 1. One valid authoritative terminal, with the expected status/decision.

    assert run["authoritative"] == true
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)

    assert [decision_source_ref] =
             hd(run["decision"]["delegations"])["source_refs"]

    # All three receipts reached the one run. The ledger projection replaces raw
    # receipt refs with stable per-run ordinals, so membership is asserted as the
    # ordered projection.
    assert run["input_receipt_refs"] ==
             ["receipt://run/r001", "receipt://run/r002", "receipt://run/r003"]

    fence = load_fence!(namespace, scope(authority), run["generation"])
    assert RunFence.valid_terminal?(fence["terminal"])
    assert fence["terminal"]["status"] == "evaluated"
    assert fence["terminal"]["decision"] == run["decision"]
    assert ULID.valid?(fence["terminal"]["terminal_id"])

    # The sealed generation the run was cut from is durable and closed.
    assert {:ok, bucket} = Bucketing.load(namespace, scope(authority))
    assert bucket["open_receipts"] == []
    assert bucket["sealed_generations"] == []

    assert {:ok, %{"receipts" => sealed}} =
             Bucketing.load_sealed_generation(
               namespace,
               bucket["bucket_scope"],
               run["generation"]
             )

    assert Enum.map(sealed, & &1["receipt_ref"]) ==
             Enum.map([first, second, third], & &1["receipt_ref"])

    ## 2. Ledger fetch, listing, and offline replay all agree on the same run.

    assert {:ok, ^run} = Ledger.fetch(namespace, run["run_id"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert {:ok, listed} = Ledger.list(namespace)
    assert Enum.filter(listed, &(&1["run_id"] == run["run_id"])) == [run]

    # A fresh runtime reads the same durable record with no local state.
    fresh = start_engine!(namespace)
    assert Triage.ledger_records(fresh) == [run]
    assert {:ok, ^run} = Triage.replay(fresh, run["run_id"])

    ## 3. Authorized meeting facts keep ordinary names, links, and paths.

    projected_bytes = run["input_snapshot"]["canonical_snapshot_bytes"]
    ledger_bytes = Jason.encode!(run)
    raw_memory = raw_product_memory!(fence)
    raw_memory_text = Enum.map_join(raw_memory["facts"], "\n", & &1["text"])

    # Check source presence as well as the resulting model input.
    assert raw_memory_text =~ Fixture.raw_meeting_url()
    assert raw_memory_text =~ Fixture.raw_meeting_path()
    assert Enum.any?(raw_memory["facts"], &(&1["text"] =~ Fixture.raw_meeting_email()))

    for literal <- Fixture.raw_meeting_literals() do
      assert projected_bytes =~ literal
      assert ledger_bytes =~ literal
    end

    ## 4. The B3 agreement: the freeze's own memory source_refs are exactly what
    ##    the verifier rebuilds from the facts, despite the in-progress,
    ##    scheduled, and blank-summary meetings in the same group.

    assert raw_memory["source_refs"] ==
             IdentityContract.raw_memory_source_refs(
               get_in(raw_memory, ["project", "source_ref"]),
               Enum.map(raw_memory["members"], & &1["source_ref"]),
               raw_memory["facts"]
             )

    assert IdentityContract.valid_raw_memory?(raw_memory, %{"project_status" => "active"})
    assert length(raw_memory["members"]) == 3

    # The one place this chain correlates a product member with the people in
    # the thread: every action-item owner named in a meeting summary resolved to
    # a real membership row, and travels into the model as that member's alias
    # rather than as a name.
    projected_memory = get_in(run, ["input_snapshot", "snapshot", "team_project_memory"])
    member_refs = Enum.map(projected_memory["members"], & &1["entity_ref"])
    assert length(member_refs) == 3

    owner_refs =
      projected_memory["facts"]
      |> Enum.map(& &1["owner_ref"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert length(owner_refs) == 3
    assert Enum.all?(owner_refs, &(&1 in member_refs))

    ## 5. Only the six fact-bearing meetings contributed a ref; the six that
    ##    produced no fact contributed none, and none of them cost the run.

    meeting_refs = Enum.filter(raw_memory["source_refs"], &String.starts_with?(&1, "meeting://"))
    assert length(meeting_refs) == 6
    assert Enum.uniq(meeting_refs) == meeting_refs

    ## 6. Zero external effects.

    # The only Slack method this whole chain reached is the authorized read.
    assert Fixture.collected_source_reads() |> Enum.map(&elem(&1, 0)) == [
             "clickhouse.channel_current"
           ]

    assert Fixture.collected_slack_calls() == ["api/emoji.list"]

    # Ordinary assignment reaches no model or tool dispatch.
    assert run["evaluator"]["request_count"] == 0

    # The product projection publishes durable obligations only after the
    # authoritative fence commits. The evaluator itself performs no effect.
    artifact = run["evaluator"]["review_artifact"]
    assert artifact["delivery_mode"] == "authoritative_obligations"
    assert artifact["executed_actions"] == []
    assert artifact["communication"]["source_refs"] == []
    assert hd(artifact["delegations"])["source_refs"] == [decision_source_ref]

    assert artifact["readback"] == %{
             "status" => "authoritative_obligations_pending",
             "slack_writes" => 0,
             "worker_starts" => 0,
             "context_writes" => 0
           }

    # No agent worker was ever claimed or started for this run's Router. The
    # agent id is minted per test, so this is a statement about THIS run rather
    # than about whatever else the suite left running.
    refute SalixAgent.Fleet.running?(authority["inbound_agent_id"])

    # And nothing keeps happening after the terminal settles.
    SystemsRuntime.Proc.sleep(200)
    assert Fixture.collected_source_reads() == []
    assert Triage.ledger_records(server) == [run]
  end

  @tag :worker_context_completion
  test "two scheduled reminders for one message settle without losing either occurrence", ctx do
    %{authority: authority, project: project} = ctx

    first_namespace = "reminder-confirm-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    first =
      start_engine!(
        first_namespace,
        [debounce_ms: 20],
        LaterEvidenceProvider,
        %{"expected_evidence" => "好"}
      )

    # The Worker decision is a fixture. This test proves that the accepted
    # reminder's next occurrence reaches the model-input boundary.
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", "好")])
    Fixture.admit_root!(first, authority, "Ev-reminder-confirm", "好")
    first_run = Fixture.await_run!(first)

    complete_worker_context!(
      first_namespace,
      first_run,
      authority,
      for {subject, value} <- [{"Weekly report", "提醒发送周报"}, {"Expense report", "提醒提交报销"}] do
        %{
          "kind" => "follow_up",
          "subject" => subject,
          "value" => value,
          "confidence" => "explicit",
          "recheck_after_hours" => 12,
          "follow_up_basis" => "reminder_confirmed"
        }
      end
    )

    assert {:ok, [_, _] = entries} = TriageProductRuntime.list_context(project.id)
    assert Enum.all?(entries, &(&1.state == :active))
    assert {:ok, []} = TriageProductRuntime.list_active_context(project.id, query: "好")

    second =
      start_engine!(
        "reminder-due-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        [debounce_ms: 1_000, evaluation_timeout_ms: 10_000],
        LaterEvidenceProvider,
        %{"expected_evidence" => "triggered the current scheduled recheck"}
      )

    message = %{
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => Fixture.root_ts(),
      "message_ts" => Fixture.root_ts(),
      "actor_id" => "U_LIN",
      "actor_kind" => "human",
      "text" => "好"
    }

    event_ids =
      for entry <- entries do
        due_ms = DateTime.to_unix(entry.next_check_at, :millisecond)

        occurrence = %{
          "entry_id" => entry.entry_id,
          "schedule_id" => entry.payload["schedule_id"],
          "scheduled_for_ms" => due_ms
        }

        assert {:ok, :rescheduled} =
                 TriageProductRuntime.admit_follow_up_wakeup(
                   entry.entry_id,
                   entry.payload["authority_generation"],
                   occurrence["schedule_id"],
                   due_ms,
                   fn ->
                     {:ok, _, receipt} =
                       ProviderReceipts.record_slack_triage_recheck(
                         authority,
                         message,
                         occurrence
                       )

                     assert {:ok, :accepted} = Triage.accept_current(second, authority, receipt)

                     SystemsRuntime.Proc.send(
                       SystemsRuntime.Proc.self(),
                       {:accepted_recheck, receipt["event_id"]}
                     )

                     {:ok, receipt["event_id"]}
                   end
                 )

        assert_receive {:accepted_recheck, event_id}
        event_id
      end

    run = Fixture.await_run!(second)
    assert run["status"] == "evaluated"
    assert run["input_snapshot"]["canonical_snapshot_bytes"] =~ "提醒发送周报"

    assert [[obligation]] =
             Repo.query!("SELECT payload FROM triage_product_obligations WHERE run_id = $1", [
               run["run_id"]
             ]).rows

    assert Enum.sort(obligation["recheck_context_refs"]) ==
             Enum.sort(Enum.map(entries, &("triage-context://" <> &1.entry_id)))

    assert Enum.sort(obligation["recheck_event_ids"]) == Enum.sort(event_ids)
    assert obligation["target_cutoff"] == %{"event_message_timestamps" => [Fixture.root_ts()]}
    assert SalixIM.Triage.ProductObligation.valid?(obligation)

    assert run["input_snapshot"]["snapshot"]["identity_context"]["source_mode"] ==
             "scheduled_recheck"

    assert run["decision"]["delegations"] == []
    assert run["decision"]["communication"]["reason"] == "no_actionable_request"
    assert RunFence.valid_model_proof?(run["evaluator"])
    assert {:ok, ^run} = Triage.replay(second, run["run_id"])
  end

  @tag :triage_continuous
  # Staging shape: the decision target itself names the Bearer scheme.
  test "a Bearer span in the decision target is withheld and the run proceeds", ctx do
    %{authority: authority} = ctx
    namespace = "triage-bearer-target-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    server = start_engine!(namespace, [debounce_ms: 20], StubProvider)
    text = "请 review PR #2642，接入要求 Bearer Token，且仅公开只读工具"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
    receipt = Fixture.admit_root!(server, authority, "Ev-bearer-target", text)

    assert receipt["triage_event"]["text"] ==
             "请 review PR #2642，接入要求 [Bearer-credential withheld]"

    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated", inspect(Map.take(run, ~w(status decision)))
    Harness.assert_worker_assignment!(run)

    fence = load_fence!(namespace, scope(authority), run["generation"])
    projection = fence["identity_observation"]["private_projection"]
    assert {:ok, recomputed} = IdentityContract.recompute_projected_context(projection)

    assert [%{"text" => target}] =
             recomputed.projected_context["slack_context"]["messages"]

    assert target =~ "[Bearer-credential withheld]"
    refute Jason.encode!(fence) =~ "Token，且仅公开只读工具"
    refute Jason.encode!(run) =~ "Token，且仅公开只读工具"
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
  end

  for {bearer, secret} <- [
        {"接入要求：Bearer Token，且仅公开只读工具", "Token，且仅公开只读工具"},
        {"临时凭据 Bearer QUJDREVGRw 已过期", "QUJDREVGRw"}
      ] do
  end

  # BRI-1659: the addressed bot remains an explicit principal in the context
  # handed to the Worker. Intake does not make the participation decision.
  test "an agent that @-mentions this bot reaches Worker assignment with its principal identity",
       ctx do
    %{authority: authority} = ctx

    namespace = "triage-acceptance-agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    # The ambient root opens its own channel bucket. Keep that bucket open for
    # the test so only the immediate mention bucket can settle a run.
    server = start_engine!(namespace, debounce_ms: 60_000, max_wait_ms: 120_000)

    Fixture.put_thread([
      Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", "Atlas 登录事故还需要确认处理人"),
      # Context, not a trigger: this line ends in a question mark and is still
      # not allowed to arm anything by itself.
      Fixture.mirrored_agent_message(ts(2), "U_REVIEWER", "静态检查发现两个可疑改动，要我贴出来吗？"),
      Fixture.mirrored_agent_message(
        ts(3),
        "U_REVIEWER",
        "<@#{authority["bot_user_id"]}> 谁在跟进 Atlas 登录事故？"
      )
    ])

    root = Fixture.admit_root!(server, authority, "Ev-agent-1", "Atlas 登录事故还需要确认处理人")

    addressed =
      Fixture.admit_reply!(
        server,
        authority,
        "Ev-agent-3",
        ts(3),
        "<@#{authority["bot_user_id"]}> 谁在跟进 Atlas 登录事故？",
        actor_id: "U_REVIEWER",
        actor_kind: "agent",
        event_type: "app_mention"
      )

    # The unaddressed agent message is CH context only. The addressed agent
    # message is the one CH row allowed to trigger this bucket.
    refute root["triage_event"]["fast_path"]
    assert addressed["triage_event"]["fast_path"]
    assert addressed["triage_event"]["actor_kind"] == "agent"
    assert addressed["triage_event"]["source_mode"] == "clickhouse_etl"

    run = Fixture.await_run!(server)

    assert run["authoritative"] == true
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    assert [^root] = Bucketing.load!(namespace, Bucketing.scope_key(root))["open_receipts"]

    assert %Postgrex.Result{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM triage_companion_reaction_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    # The explicit mention is immediate; the preceding ambient receipt retains
    # its channel membership and remains visible through the thread context.
    assert run["input_receipt_refs"] == ["receipt://run/r001"]
    context_messages = run["input_snapshot"]["snapshot"]["slack_context"]["messages"]
    assert length(context_messages) == 3
    assert Enum.at(context_messages, 1)["text"] == "静态检查发现两个可疑改动，要我贴出来吗？"

    # The freeze registered the peer bot as a principal — projected under the
    # `@agent:` alias namespace, carrying its bot_profile display name. The
    # Worker can use this identity when deciding whether to participate.
    identity = run["input_snapshot"]["snapshot"]["identity_context"]

    peer =
      Enum.find(identity["observed_principals"], &(&1["relation_to_self"] == "other"))

    assert peer["kind"] == "agent"
    assert peer["evidence_tier"] == "thread_authorship"
    assert hd(peer["display_aliases"]) =~ ~r{\A@agent:p\d+\z}
    assert "codex-review" in peer["display_aliases"]

    assert run["decision"]["identity_interpretation"] == %{
             "topic" => "none",
             "referenced_principal_refs" => []
           }

    # Review mode still has zero egress, so no agent round was ever spent.
    assert run["evaluator"]["review_artifact"]["executed_actions"] == []
    refute SalixAgent.Fleet.running?(authority["inbound_agent_id"])
  end

  defp install_no_wake_worker_delivery! do
    previous = SystemsRuntime.fetch_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, NoWakeWorkerDelivery)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        {:ok, value} -> SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, value)
        :error -> SystemsRuntime.delete_env(:salix_im, :agent_delivery_mod)
      end
    end)
  end

  # Use the same Task entry and completion APIs as the roster-selection case.
  # The scripted Worker never calls a model. Context settles through its real
  # result participant before the next intake or scheduled recheck starts.
  defp complete_worker_context!(namespace, run, authority, candidate) do
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    {:ok, [claim]} = Fixture.claim_round!(%{namespace: namespace, run: run}, "context-worker")

    claim_triage_route!(authority, claim.payload["target"])

    [delegation] = claim.payload["delegations"]
    request = "triage-delegation:#{claim.obligation_id}:0"
    assert {:ok, prepared} = BridgeForTeams.TriageDelegation.prepare(claim, delegation, request)
    assert {:ok, result} = BridgeForTeams.TriageDelegation.commit(prepared)
    worker_id = result["worker_agent_id"]
    task_id = result["conversation_id"]

    assert_receive {:worker_command, ^worker_id,
                    %{trusted_origin: %{"conversation_id" => ^task_id}} = command}

    tool_context = %{
      "session_id" => command.session_id,
      "trusted_origin" => command.trusted_origin
    }

    call = fn tool, params ->
      SalixIM.Provider.call_api(worker_id, "internal", tool, %{
        "connect_id" => "internal",
        "params" => params,
        "tool_context" => tool_context
      })
    end

    assert {:ok, source} = call.("internal.triage.read_source", %{})
    assert {:ok, context} = call.("internal.triage.read_context", %{})

    refs =
      Enum.map(context["entries"], & &1["source_ref"]) ++
        [List.last(source["messages"])["source_ref"]]

    assert {:ok, %{"accepted" => true}} =
             call.("internal.triage.complete", %{
               "source_snapshot" => source["source_snapshot"],
               "decision" => %{
                 "kind" => "silence",
                 "reason" => "The evidence only changes retained context.",
                 "source_refs" => [],
                 "context_candidates" =>
                   Enum.map(List.wrap(candidate), &Map.put(&1, "source_refs", refs))
               }
             })

    assert true ==
             SalixAgent.LiveLlmTestSupport.eventually(fn ->
               case SalixIM.Conversations.get_group_conversation(authority["group_id"], task_id) do
                 {:ok, %{"status" => "ready_for_review"}} -> {:ok, true}
                 _ -> :retry
               end
             end)

    refute_receive {:slack_reply_posted, _}
  end

  defp claim_triage_route!(authority, target) do
    route =
      authority
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id))
      |> Map.merge(%{
        "channel_id" => target["channel_id"],
        "root_thread_ts" => target["thread_ts"]
      })

    assert {:ok, root_us} =
             SalixIM.SlackMessageMirror.Row.slack_ts_micros(route["root_thread_ts"])

    assert {:ok, route_identity} =
             SalixIM.Provider.Slack.ThreadRouteOwner.clickhouse_root_claim_identity(
               route,
               root_us
             )

    assert {:ok, :triage} =
             SalixIM.Provider.Slack.ThreadRouteOwner.claim_triage(route, route_identity)
  end

  ## Engine

  defp clickhouse_event_id(authority, message_ts_us) do
    [
      "slack-clickhouse-etl-v1",
      authority["connect_id"],
      authority["approved_channel_id"],
      Integer.to_string(message_ts_us)
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp start_engine!(namespace, overrides \\ [], provider \\ StubProvider, provider_opts \\ %{}) do
    test_pid = SystemsRuntime.Proc.self()

    # Keep every synchronously admitted fixture event inside one open window.
    # PostgreSQL admission is intentionally heavier than the former in-memory
    # fake, so a millisecond-scale debounce turns this acceptance test into a
    # scheduler race. This short test window preserves trailing debounce while
    # avoiding the production three-minute wait.
    engine_overrides =
      Keyword.merge([debounce_ms: 2_000, max_wait_ms: 30_000], overrides)

    Fixture.start_engine!(
      namespace,
      {Salix.Bindings.TriageEvaluator,
       [
         provider: provider,
         provider_opts:
           provider_opts
           |> Map.put("test_pid", test_pid)
           |> Map.put_new("protocol", "responses"),
         transport_receipt: fn payload_bytes ->
           %{payload_sha256: Fixture.sha256(payload_bytes), request_count: 1}
         end
       ]},
      engine_overrides
    )
  end

  defp load_fence!(namespace, scope, generation) do
    assert {:ok, fence} =
             CasRecord.get(
               SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
             )

    fence
  end

  defp raw_product_memory!(fence) do
    bytes =
      get_in(fence, ["identity_observation", "private_projection", "raw_source_bundle_bytes"])

    assert is_binary(bytes)
    assert {:ok, raw_bundle} = Jason.decode(bytes)
    raw_bundle["product_context"]
  end

  ## Slack thread

  defp unanswered_thread(_authority) do
    [
      Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", "Atlas 登录事故还需要确认处理人"),
      Fixture.mirrored_message(ts(2), "U_PENG", "我记得周会里讨论过这件事"),
      Fixture.mirrored_message(
        ts(3),
        "U_LIN",
        "谁在跟进 Atlas 登录事故？"
      )
    ]
  end

  ## Small helpers

  defp scope(authority), do: Fixture.scope(authority, "__channel__")

  defp ts(n), do: Fixture.ts(n)
end
