defmodule BridgeForTeams.TriageEngineAcceptanceTest do
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
      owner = Application.fetch_env!(:bridge_for_teams_core, :triage_acceptance_owner)
      send(owner, {:worker_command, agent, payload})

      send(
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
      send(opts["test_pid"], {:stub_provider_called, tools})

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
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    :ok = Fixture.install_clickhouse_reader!(self())

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

    namespace = "triage-ch-row-acceptance-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 100)

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

  test "configured Worker changes new intake while the accepted Task keeps its Worker",
       ctx do
    authority = ctx.authority
    {:ok, project} = BridgeForTeams.Projects.get_project_by_salix_group(authority["group_id"])

    workers =
      for label <- ["First investigator", "Second investigator"] do
        worker =
          SalixAgent.TestSupport.create_control_agent_in_group!(
            authority["tenant_id"],
            authority["group_id"],
            %{"role" => "worker", "name" => label}
          )

        BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.Agent{
          project_id: project.id,
          salix_agent_id: worker["agent_id"],
          role: "worker",
          configuration_authority: "salix"
        })

        worker["agent_id"]
      end

    previous = Application.fetch_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, NoWakeWorkerDelivery)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        {:ok, value} -> Application.put_env(:salix_im, :agent_delivery_mod, value)
        :error -> Application.delete_env(:salix_im, :agent_delivery_mod)
      end
    end)

    namespace = "selected-worker-#{ULID.generate()}"
    server = start_engine!(namespace, [debounce_ms: 50], StubProvider)

    Fixture.put_thread([
      Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", "Who can check the original source?")
    ])

    Fixture.put_linked_message(%{
      "workspace_url" => "https://atlas.slack.com",
      "ts" => Fixture.root_ts(),
      "thread_ts" => Fixture.root_ts(),
      "user" => "U_LIN",
      "text" => "Who can check the original source?"
    })

    Fixture.admit_reply!(
      server,
      authority,
      "Ev-worker-choice",
      Fixture.root_ts(),
      "Who can check the original source?"
    )

    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated"
    assert run["evaluator"]["request_count"] == 0
    {:ok, [claim]} = Fixture.claim_round!(%{namespace: namespace, run: run}, "selected-worker")

    # Review-mode ingress does not create the provider route owner. Use its
    # real owner contract before exercising the final Slack adapter.
    route =
      authority
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id))
      |> Map.merge(%{
        "channel_id" => claim.payload["target"]["channel_id"],
        "root_thread_ts" => claim.payload["target"]["thread_ts"]
      })

    assert {:ok, :triage} =
             SalixIM.Provider.Slack.ThreadRouteOwner.claim_triage(route, run["context_sha256"])

    Harness.assert_worker_assignment!(run)

    assert {:ok, %{status: :fresh}} =
             SalixIM.Triage.SlackEffectAdapter.Freshness.check(claim, [])

    initial_effect = SalixIM.Triage.SlackEffectAdapter.apply(claim)
    refute_receive {:slack_reply_posted, _}, 100

    assert {:ok,
            %{
              outcome: :applied,
              external_writes: 0,
              communication: %{"kind" => "silence"}
            }} = initial_effect

    assert %Postgrex.Result{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM triage_companion_reaction_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    delegation = hd(claim.payload["delegations"])

    {:ok, selected} =
      BridgeForTeams.Salix.Erpc.ensure_triage_worker(
        authority["group_id"],
        authority["inbound_agent_id"]
      )

    refute selected in workers
    assert delegation["worker_ref"] == "comma-agent://" <> selected
    request = "triage-delegation:#{claim.obligation_id}:0"
    assert {:ok, prepared} = BridgeForTeams.TriageDelegation.prepare(claim, delegation, request)
    next_worker = hd(workers)
    assert {:ok, %{"revision" => revision}} = SalixAgent.TriageWorker.get(authority["group_id"])

    assert {:ok, _} =
             SalixAgent.TriageWorker.configure(
               authority["group_id"],
               authority["inbound_agent_id"],
               next_worker,
               revision,
               %{"actor_user_id" => "project-admin", "request_id" => "switch-worker"}
             )

    assert {:ok, result} = BridgeForTeams.TriageDelegation.commit(prepared)
    assert result["disposition"] == "created"
    assert result["worker_agent_id"] == selected

    assert {:ok, ^result} = BridgeForTeams.TriageDelegation.commit(prepared)

    assert {:ok, %{"data" => [task]}} =
             SalixIM.Conversations.list_group_conversations(authority["group_id"],
               kind: "agent_task",
               limit: 10
             )

    assert task["conversation_id"] == result["conversation_id"]
    assert task["task_worker_agent_id"] == selected

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(
        authority["group_id"],
        task["conversation_id"]
      )

    assert Enum.find(participants, &(&1["role_label"] == "delegator"))["notification_filter"][
             "messages"
           ] == "none"

    {:ok, router_session} =
      SalixIM.ProviderConnects.agent_group_router_session_id(
        authority["inbound_agent_id"],
        authority["group_id"]
      )

    assert_receive {:worker_delivery, ^selected}, 5_000
    router_id = authority["inbound_agent_id"]
    refute_receive {:worker_delivery, ^router_id}, 100

    case SalixAgent.InternalSessionStore.read(router_id, router_session) do
      {:error, :not_found} ->
        :ok

      {:ok, session} ->
        assert SalixAgent.InternalSession.get(session, :input_queue) == [] and
                 SalixAgent.InternalSession.get(session, :messages) == []
    end

    assert_receive {:worker_command, ^selected, command}, 5_000

    tool_context = %{
      "session_id" => command.session_id,
      "trusted_origin" => command.trusted_origin
    }

    memory_path = "/memory/index.md"

    {:ok, memory_event} =
      SalixAgent.AgentWorkspace.prepare_write(
        router_id,
        memory_path,
        "Project context: inspect the original source."
      )

    {:ok, _} =
      SalixAgent.AgentWorkspace.seed_operation(
        router_id,
        "memory-read-#{ULID.generate()}",
        %{},
        [Map.put(memory_event, "ifc_label", ["public"])]
      )

    memory_request = %{
      "connect_id" => "internal",
      "params" => %{"path" => memory_path},
      "tool_context" => tool_context
    }

    assert {:ok, memory} =
             SalixIM.Provider.call_api(
               selected,
               "internal",
               "internal.triage.read_memory",
               memory_request
             )

    assert memory["content"] =~ "Project context: inspect the original source."
    assert memory["__ifc__"] == %{"label" => ["public"]}

    assert {:ok, source} =
             SalixIM.Provider.call_api(selected, "internal", "internal.triage.read_source", %{
               "connect_id" => "internal",
               "params" => %{},
               "tool_context" => tool_context
             })

    final_text = "The original source asks who can inspect it."

    assert {:ok, _} =
             SalixIM.Provider.call_api(selected, "internal", "internal.triage.complete", %{
               "connect_id" => "internal",
               "params" => %{
                 "source_snapshot" => source["source_snapshot"],
                 "decision" => %{"kind" => "reply", "text" => final_text, "source_refs" => []}
               },
               "tool_context" => tool_context
             })

    assert_receive {:slack_reply_posted, %{"text" => ^final_text}}, 5_000
    refute_receive {:slack_reply_posted, _}, 100

    assert true ==
             SalixAgent.LiveLlmTestSupport.eventually(fn ->
               case SalixIM.Conversations.get_group_conversation(
                      authority["group_id"],
                      task["conversation_id"]
                    ) do
                 {:ok, %{"status" => "ready_for_review"}} -> {:ok, true}
                 _ -> :retry
               end
             end)

    {:ok, agent} = BridgeForTeams.Agents.get_project_agent(project.id, selected)
    archive_agent_fixture!(agent)
    assert {:error, _, false} = BridgeForTeams.TriageDelegation.commit(prepared)

    assert {:error, _} =
             SalixIM.Provider.call_api(
               selected,
               "internal",
               "internal.triage.read_memory",
               memory_request
             )

    next_namespace = "next-worker-#{ULID.generate()}"
    next_server = start_engine!(next_namespace, [debounce_ms: 50], StubProvider)
    next_root = "1788249900.000100"
    Fixture.put_thread([Fixture.mirrored_message(next_root, "U_LIN", "Check this new source")])

    Fixture.admit_reply!(
      next_server,
      authority,
      "Ev-next-worker",
      next_root,
      "Check this new source",
      root_ts: next_root,
      actor_id: "U_LIN"
    )

    next_run = Fixture.await_run!(next_server)

    {:ok, [next_claim]} =
      Fixture.claim_round!(%{namespace: next_namespace, run: next_run}, "next-worker")

    assert [next_delegation] = next_claim.payload["delegations"]
    assert next_delegation["worker_ref"] == "comma-agent://" <> next_worker
  end

  test "forwarded Task evidence reaches the model through the native source and identity pipeline",
       ctx do
    namespace = "triage-forwarded-task-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 50)
    text = "这个 task 完成了但没回复？"
    root = Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)

    Fixture.put_thread([
      Map.put(root, "attachments", [
        %{
          "is_msg_unfurl" => true,
          "channel_id" => "C_TASKS",
          "ts" => "1787018000.000001",
          "from_url" =>
            "https://atlas.slack.com/archives/C_TASKS/p1787018000000001?thread_ts=1787017999.000000&cid=C_TASKS",
          "text" => "Task Review PR #67: ready for review",
          "blocks" => [
            %{
              "type" => "task_card",
              "title" => "Review PR #67",
              "status" => "complete",
              "output" => %{
                "type" => "rich_text",
                "elements" => [
                  %{
                    "type" => "rich_text_section",
                    "elements" => [
                      %{
                        "type" => "text",
                        "text" =>
                          "Approved PR #67 at f231813; no blockers. Nothing merged or deployed."
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ])
    ])

    Fixture.admit_root!(server, ctx.authority, "Ev-forwarded-task", text)
    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated"
    assert run["authoritative"] == true

    snapshot = Jason.decode!(run["input_snapshot"]["canonical_snapshot_bytes"])
    assert [%{"text" => model_text}] = snapshot["slack_context"]["messages"]
    assert model_text =~ text
    assert model_text =~ "Task Review PR #67: ready for review"
    assert model_text =~ "Approved PR #67 at f231813; no blockers. Nothing merged or deployed."
    assert model_text =~ "1787018000.000001"
    assert model_text =~ "1787017999.000000"
    assert model_text =~ "untrusted Slack forwarded-message references"
    assert run["evaluator"]["request_count"] == 0
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert Fixture.collected_slack_calls() == ["api/emoji.list"]
  end

  @tag :worker_effect
  test "continuous channel roots share one trailing batch and retain physical reply sources",
       ctx do
    %{authority: authority, project: project} = ctx
    namespace = "triage-channel-batch-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 1_000, max_wait_ms: 30_000)

    messages = [
      {"1789094839.768769", "你让它直接看代码看可能会是什么原因吧"},
      {"1789094849.609089", "就是没打开 full access"},
      {"1789094871.066279", "设置里的 fullaccess 不是文件访问权限么"},
      {"1789094888.003919", "按理说没有文件访问权限不会导致 connect 断开"},
      {"1789094899.234539", "我问问"}
    ]

    Fixture.put_thread(
      Enum.map(messages, fn {timestamp, text} ->
        Fixture.mirrored_message(timestamp, "U_LIN", text) |> Map.put("thread_ts", "")
      end)
    )

    receipts =
      Enum.map(messages, fn {timestamp, text} ->
        Fixture.admit_root!(server, authority, "Ev-channel-#{timestamp}", text,
          root_ts: timestamp
        )
      end)

    [bucket_scope] = receipts |> Enum.map(&Bucketing.scope_key/1) |> Enum.uniq()
    assert String.ends_with?(bucket_scope, ":__channel__")
    assert length(Enum.uniq_by(receipts, &Bucketing.source_key/1)) == 5
    refute Enum.any?(receipts, & &1["triage_event"]["fast_path"])
    assert Triage.ledger_records(server) == []

    open = Bucketing.load!(namespace, bucket_scope)
    assert length(open["open_receipts"]) == 5
    refute open["open_fast_path"]

    run = Fixture.await_run!(server)
    assert run["authoritative"] and run["status"] == "evaluated"
    snapshot = run["input_snapshot"]["snapshot"]
    assert snapshot["schema"] == "comma.triage-context-snapshot.v10"
    assert snapshot["source_authority"]["scope_kind"] == "channel"
    projected = snapshot["slack_context"]["messages"]
    assert Enum.map(projected, & &1["text"]) == Enum.map(messages, &elem(&1, 1))
    assert length(Enum.uniq_by(projected, & &1["thread_ref"])) == 5
    assert snapshot["slack_context"]["decision_target"]["ordinal"] == 5
    assert length(run["input_receipt_refs"]) == 5
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])

    assert Enum.count(
             Fixture.collected_source_reads(),
             &(elem(&1, 0) == "clickhouse.channel_current")
           ) == 1

    assert run["evaluator"]["request_count"] == 0

    fence = load_fence!(namespace, bucket_scope, run["generation"])
    assert fence["sealed_generation"]["receipts"] == receipts
    assert RunFence.valid_record?(fence)
    assert Bucketing.load!(namespace, bucket_scope)["sealed_generations"] == []

    assert {:ok, :duplicate, :sealed_member} =
             SalixIM.Triage.Runtime.accept_current_with_membership(
               server,
               authority,
               hd(receipts)
             )

    assert Bucketing.load!(namespace, bucket_scope)["open_receipts"] == []

    bundle =
      Jason.decode!(
        fence["identity_observation"]["private_projection"]["raw_source_bundle_bytes"]
      )

    raw_messages = bundle["raw_context"]["slack_context"]["messages"]
    assert Enum.map(raw_messages, & &1["root_thread_ts"]) == Enum.map(messages, &elem(&1, 0))

    assert Enum.all?(raw_messages, fn message ->
             String.ends_with?(
               message["source_ref"],
               "/#{message["root_thread_ts"]}/#{message["message_ts"]}"
             )
           end)

    assert %Postgrex.Result{rows: [[target, window]]} =
             Repo.query!(
               "SELECT payload -> 'target', payload -> 'source_window' FROM triage_product_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    assert target["thread_ts"] == "1789094899.234539"
    assert window["thread_roots"] == Enum.map(messages, &elem(&1, 0))
    claim_triage_route!(authority, target)

    assert {:ok, %{applied: 1, failed: 0}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               holder: "triage-channel-batch",
               batch_size: 50
             )

    assert {:ok, [outcome]} = TriageProductRuntime.recent_outcomes(project.id)
    assert outcome.state == :applied
    assert outcome.result["external_writes"] == 0
    assert [%{"status" => "created"}] = outcome.result["metadata"]["delegations"]
    refute_receive {:slack_reply_posted, _}
  end

  @tag :archived_processing
  test "completed channel batches retain replay and timeline results without growing active history",
       ctx do
    namespace = "triage-channel-history-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 50)

    receipts =
      for ordinal <- 1..12 do
        timestamp = "#{1_789_096_000 + ordinal}.000001"

        text =
          ("Atlas follow-up #{ordinal}: " <> String.duplicate("rollout evidence ", 4_000))
          |> String.trim()

        Fixture.put_thread([
          Fixture.mirrored_message(timestamp, "U_LIN", text) |> Map.put("thread_ts", "")
        ])

        receipt =
          Fixture.admit_root!(server, ctx.authority, "Ev-channel-history-#{ordinal}", text,
            root_ts: timestamp
          )

        runs = Fixture.await_runs!(server, ordinal)
        assert Enum.all?(runs, &(&1["status"] == "evaluated"))

        assert Bucketing.load!(namespace, Bucketing.scope_key(receipt))["sealed_generations"] ==
                 []

        receipt
      end

    for run <- Triage.ledger_records(server) do
      assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    end

    for receipt <- receipts do
      assert {:ok, :duplicate, :sealed_member} =
               SalixIM.Triage.Runtime.accept_current_with_membership(
                 server,
                 ctx.authority,
                 receipt
               )
    end

    scope = Bucketing.scope_key(hd(receipts))
    assert Bucketing.load!(namespace, scope)["open_receipts"] == []
    assert Bucketing.load!(namespace, scope)["sealed_generations"] == []
    assert length(Triage.ledger_records(server)) == 12

    evidence_bytes =
      Triage.ledger_records(server)
      |> Enum.reduce(0, fn run, total ->
        keys = [
          SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, run["generation"]),
          SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run["run_id"])
        ]

        Enum.reduce(keys, total, fn key, bytes ->
          assert {:ok, %{body: body}} = SalixStore.TriageRecords.get(key)
          bytes + byte_size(body)
        end)
      end)

    assert evidence_bytes > 4 * 1024 * 1024

    assert {:ok, %{items: full_page}} =
             SalixIM.Triage.ReadModel.recent_processing(namespace, 0, limit: 20)

    assert Enum.any?(full_page, &(&1.state == :unavailable))

    summaries =
      for run <- Triage.ledger_records(server) do
        key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, run["generation"])
        assert {:ok, fence} = CasRecord.get(key)
        refs = Enum.map(fence["sealed_generation"]["receipts"], & &1["receipt_ref"])
        assert {:ok, summary} = SalixStore.TriageRecords.processing_fence(key, refs)
        assert summary["terminal"]["status"] == "evaluated"
        assert summary["archived_membership"] == true
        summary
      end

    assert length(summaries) == 12
    assert byte_size(Jason.encode!(summaries)) < 16_384

    assert {:ok, %{items: [%{state: :terminal, terminal_status: "evaluated"}], truncated: true}} =
             SalixIM.Triage.ReadModel.recent_processing(namespace, 0, limit: 1)
  end

  @tag :archived_processing
  test "a vanished sealed target does not become an identity failure or retarget later activity",
       ctx do
    namespace = "triage-missing-target-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 20)
    later_ts = "1787019060.000000"

    # Current-state reads omit deleted messages. Only unrelated later activity
    # remains when the admitted target disappears during the debounce window.
    Fixture.put_thread([Fixture.mirrored_message(later_ts, "U_LIN", "An unrelated update")])
    receipt = Fixture.admit_root!(server, ctx.authority, "Ev-missing-target", "Investigate this")

    assert [%{"status" => "failed"} = run] = Fixture.await_runs!(server, 1)

    assert run["decision"] == %{
             "action" => "silence",
             "reason" => "triage_source_target_unavailable"
           }

    assert run["evaluator"] == %{}
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert Bucketing.load!(namespace, Bucketing.scope_key(receipt))["sealed_generations"] == []

    assert {:ok, %{items: [item]}} =
             SalixIM.Triage.ReadModel.recent_processing(namespace, 0, limit: 20)

    assert item.state == :terminal
    assert item.diagnostics.decision_reason == "source_read_unavailable"
    refute_receive {:worker_delivery, _}
    refute_receive {:slack_reply_posted, _}
  end

  @tag :archived_processing
  test "an archived evaluation failure stays visible instead of reverting to Received", ctx do
    namespace = "triage-channel-failure-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 20)
    text = "Investigate this error. api_key = opaque-fixture-secret"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
    receipt = Fixture.admit_root!(server, ctx.authority, "Ev-channel-failure", text)

    assert [%{"status" => "failed"} = run] = Fixture.await_runs!(server, 1)
    assert run["decision"]["reason"] == "identity_projection_privacy_rejected"
    assert Bucketing.load!(namespace, Bucketing.scope_key(receipt))["sealed_generations"] == []

    assert {:ok, %{items: [item]}} =
             SalixIM.Triage.ReadModel.recent_processing(namespace, 0, limit: 20)

    assert item.state == :terminal
    assert item.terminal_status == "failed"
    assert item.diagnostics.decision_reason == "evidence_invalid"

    assert {:ok, debug} =
             SalixIM.Triage.ReadModel.model_debug(
               namespace,
               ctx.project.id,
               ctx.project.salix_group_id,
               ctx.authority["inbound_agent_id"],
               "receipt",
               receipt["receipt_ref"]
             )

    assert debug.run_id == run["run_id"]
    assert debug.decision["reason"] == "identity_projection_privacy_rejected"

    Repo.query!(
      "DELETE FROM triage_run_fences WHERE namespace_key = $1 AND body ->> 'run_id' = $2",
      [
        SalixStore.TriageKeys.namespace_key(namespace),
        run["run_id"]
      ]
    )

    assert {:ok, %{items: [%{state: :unavailable}]}} =
             SalixIM.Triage.ReadModel.recent_processing(namespace, 0, limit: 20)
  end

  test "a fresh runtime recovers a pending channel batch and rejects the old timer", ctx do
    namespace = "triage-channel-restart-#{System.unique_integer([:positive])}"
    original = start_engine!(namespace, debounce_ms: 1_000)
    text = "Atlas follow-up needs a current owner"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
    receipt = Fixture.admit_root!(original, ctx.authority, "Ev-channel-restart", text)
    :ok = :sys.suspend(original)
    on_exit(fn -> if Process.alive?(original), do: :sys.resume(original) end)

    recovered = start_engine!(namespace, debounce_ms: 50)

    start_supervised!(
      {SalixIM.Triage.ReceiptRecovery,
       name: nil,
       runtime: recovered,
       interval_ms: 5,
       full_ring_idle_ms: 50,
       held_poll_ms: 5,
       lease_key: "ctl/test/triage-channel-restart/#{System.unique_integer([:positive])}",
       lease_ttl_ms: 1_000},
      id: make_ref()
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

  @tag :credential_terminology
  test "ordinary authorization terminology in project context reaches evaluation", ctx do
    %{authority: authority, project: project} = ctx

    project
    |> Ecto.Changeset.change(name: "Atlas authorization controls")
    |> BridgeForTeams.Repo.update!()

    namespace = "triage-credential-terminology-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, debounce_ms: 20)
    question = "Atlas 的登录问题现在进展如何？"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", question)])
    Fixture.admit_root!(server, authority, "Ev-credential-terminology", question)

    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated", inspect(Map.take(run, ~w(status decision evaluator)))
    assert run["evaluator"]["request_count"] == 0
    assert RunFence.valid_model_proof?(run["evaluator"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
  end

  for credential <- [
        "api_key = opaque-fixture-secret",
        "OPENAI_API_KEY = opaque-fixture-secret",
        "api_key: `opaque-fixture-secret`",
        "`OPENAI_API_KEY` = `opaque-fixture-secret`",
        "Authorization: Basic Zml4dHVyZQ=="
      ] do
    @tag :credential_terminology
    test "credential material #{credential} is rejected before the model is called", ctx do
      server =
        start_engine!("triage-credential-#{System.unique_integer([:positive])}", debounce_ms: 20)

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

    namespace = "triage-acceptance-#{System.unique_integer([:positive])}"
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
    Process.sleep(200)
    assert Fixture.collected_source_reads() == []
    assert Triage.ledger_records(server) == [run]
  end

  @tag :triage_continuous
  @tag :worker_context_completion
  test "an explicit evidenced Worker completion resolves the retained follow-up and leaves its next wakeup inert",
       ctx do
    %{authority: authority, project: project} = ctx
    value = "Atlas 公网探测仍失败，请你负责复查恢复并取得值班负责人确认"

    first_namespace = "triage-followup-open-#{System.unique_integer([:positive])}"

    first =
      start_engine!(
        first_namespace,
        [debounce_ms: 20],
        LaterEvidenceProvider,
        %{"expected_evidence" => value}
      )

    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", value)])
    Fixture.admit_root!(first, authority, "Ev-followup-open", value)
    first_run = Fixture.await_run!(first)

    complete_worker_context!(first_namespace, first_run, authority, %{
      "kind" => "follow_up",
      "subject" => "Atlas release gate",
      "value" => value,
      "confidence" => "explicit",
      "recheck_after_hours" => 12,
      "follow_up_basis" => "agent_owned"
    })

    assert {:ok, [%{state: :active} = entry]} = TriageProductRuntime.list_context(project.id)

    second_namespace = "triage-followup-completed-#{System.unique_integer([:positive])}"

    second =
      start_engine!(
        second_namespace,
        [debounce_ms: 20],
        LaterEvidenceProvider,
        %{"expected_evidence" => "公网探测通过，值班负责人确认恢复"}
      )

    Fixture.put_thread([
      Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", value),
      Fixture.mirrored_message(ts(9), "U_LIN", "公网探测通过，值班负责人确认恢复")
    ])

    Fixture.admit_reply!(second, authority, "Ev-followup-check", ts(9), "公网探测通过，值班负责人确认恢复")
    second_run = Fixture.await_run!(second)

    complete_worker_context!(second_namespace, second_run, authority, %{
      "kind" => "follow_up_resolution",
      "subject" => "Atlas release gate",
      "value" => "公网探测通过，值班负责人确认恢复",
      "confidence" => "explicit",
      "resolution_basis" => "source_confirmation"
    })

    assert {:ok, [%{state: :resolved, entry_id: entry_id}]} =
             TriageProductRuntime.list_context(project.id)

    assert entry_id == entry.entry_id
    due_ms = DateTime.to_unix(entry.next_check_at, :millisecond)

    assert {:ok, :stale} =
             TriageProductRuntime.get_due_follow_up(
               entry_id,
               entry.payload["authority_generation"],
               entry.payload["schedule_id"],
               due_ms
             )

    # Exercise this follow-up's real scheduler dispatch, without sweeping due
    # schedules owned by other fixtures in the shared Salix store.
    assert {:ok, schedule} = SalixCluster.Schedules.get(entry.payload["schedule_id"])
    assert {:ok, :fired} = SalixCluster.Schedules.fire(schedule, due_ms, now: due_ms)
    assert {:error, :not_found} = SalixCluster.Schedules.get(entry.payload["schedule_id"])
  end

  @tag :worker_context_completion
  test "two scheduled reminders for one message settle without losing either occurrence", ctx do
    %{authority: authority, project: project} = ctx

    first_namespace = "reminder-confirm-#{System.unique_integer([:positive])}"

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
        "reminder-due-#{System.unique_integer([:positive])}",
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
                     send(self(), {:accepted_recheck, receipt["event_id"]})
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
  @tag :credential_terminology
  @tag :worker_context_completion
  test "a Worker-retained authorization decision is read into a later question without repeating its source",
       ctx do
    %{authority: authority, project: project} = ctx
    value = "Atlas 发布须检查 authorization 流程、api_key 轮换和 access_token 刷新，不在讨论中粘贴凭据"

    first_namespace = "triage-memory-first-#{System.unique_integer([:positive])}"

    first =
      start_engine!(
        first_namespace,
        [debounce_ms: 20],
        LaterEvidenceProvider,
        %{"expected_evidence" => value}
      )

    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", value)])
    Fixture.admit_root!(first, authority, "Ev-memory-decision", value)
    first_run = Fixture.await_run!(first)

    complete_worker_context!(first_namespace, first_run, authority, %{
      "kind" => "decision",
      "subject" => "Atlas release gate",
      "value" => value,
      "confidence" => "explicit",
      "knowledge_scope" => "project"
    })

    assert {:ok, [%{state: :active, payload: %{"value" => ^value}}]} =
             TriageProductRuntime.list_context(project.id)

    second_namespace = "triage-memory-second-#{System.unique_integer([:positive])}"

    second =
      start_engine!(second_namespace, [debounce_ms: 20], LaterEvidenceProvider, %{
        "expected_evidence" => value
      })

    question = "Atlas 发布前还有什么必须确认？"
    Fixture.put_thread([Fixture.mirrored_message(ts(9), "U_LIN", question)])
    Fixture.admit_root!(second, authority, "Ev-memory-question", question, root_ts: ts(9))
    run = Fixture.await_run!(second)
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    assert RunFence.valid_model_proof?(run["evaluator"])
    assert {:ok, ^run} = Triage.replay(second, run["run_id"])
  end

  @tag :triage_continuous
  test "an alert source update reaches Worker assignment with its later evidence",
       ctx do
    %{authority: authority} = ctx
    namespace = "triage-alert-lifecycle-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, [debounce_ms: 20], LaterEvidenceProvider)

    Fixture.put_thread([
      Fixture.mirrored_agent_message(Fixture.root_ts(), "U_ALERTS", "公网健康检查失败"),
      Fixture.mirrored_agent_message(ts(9), "U_ALERTS", "恢复仍未确认，下一步检查公网探测")
    ])

    Fixture.admit_root!(server, authority, "Ev-alert-open", "公网健康检查失败",
      actor_kind: "agent",
      actor_id: "U_ALERTS"
    )

    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    assert RunFence.valid_model_proof?(run["evaluator"])
    assert {:ok, ^run} = Ledger.fetch(namespace, run["run_id"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])

    # Full current context must not silently retarget the sealed event, and
    # rehashing a fabricated later message cannot make it committed evidence.
    snapshot = run["input_snapshot"]["snapshot"]
    assert snapshot["schema"] == "comma.triage-context-snapshot.v10"
    assert snapshot["slack_context"]["decision_target"]["ordinal"] == 1
    assert length(snapshot["slack_context"]["messages"]) == 2
    refute Map.has_key?(snapshot, "answered_recheck")
    fence = load_fence!(namespace, scope(authority), run["generation"])
    projection = fence["identity_observation"]["private_projection"]
    assert {:ok, _} = IdentityContract.recompute_projected_context(projection)
    bundle = Jason.decode!(projection["raw_source_bundle_bytes"])

    tampered =
      put_in(bundle, ["raw_context", "slack_context", "messages", Access.at(1), "text"], "已恢复")

    bytes = SalixIM.Triage.CanonicalJSON.encode!(tampered)

    projection =
      Map.merge(projection, %{
        "raw_source_bundle_bytes" => bytes,
        "raw_source_bundle_sha256" => Fixture.sha256(bytes)
      })

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_projected_context(projection)

    assert Fixture.collected_slack_calls() == ["api/emoji.list"]
  end

  test "sending-tool attribution reaches Worker assignment without becoming a recipient", ctx do
    %{authority: authority} = ctx
    namespace = "triage-attribution-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace, [debounce_ms: 20], StubProvider)
    text = "Does RSS growth prove actor state growth? *Sent using* <@U_TOOL>"
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_LIN", text)])
    Fixture.admit_root!(server, authority, "Ev-attribution", text)

    run = Fixture.await_run!(server)
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)

    fence = load_fence!(namespace, scope(authority), run["generation"])
    projection = fence["identity_observation"]["private_projection"]
    assert {:ok, recomputed} = IdentityContract.recompute_projected_context(projection)

    assert recomputed.projected_context["slack_context"]["decision_target"]["syntactic_addressee"] ==
             "none"

    bundle = Jason.decode!(projection["raw_source_bundle_bytes"])
    assert Enum.any?(bundle["raw_context"]["slack_context"]["messages"], &(&1["text"] == text))
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
  end

  test "a later human answer reaches Worker assignment without a preliminary reply", ctx do
    %{authority: authority} = ctx

    namespace = "triage-acceptance-answered-#{System.unique_integer([:positive])}"

    server =
      start_engine!(namespace, [], LaterEvidenceProvider, %{
        "expected_evidence" => "我来跟进，负责人是 Lin。"
      })

    Fixture.put_thread(answered_thread(authority))

    Fixture.admit_root!(server, authority, "Ev-answered-1", "Atlas 登录事故还需要确认处理人")
    Fixture.admit_reply!(server, authority, "Ev-answered-2", ts(2), "我记得周会里讨论过这件事")

    Fixture.admit_reply!(
      server,
      authority,
      "Ev-answered-3",
      ts(3),
      "谁在跟进 Atlas 登录事故？"
    )

    run = Fixture.await_run!(server)

    assert run["authoritative"] == true
    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    assert RunFence.valid_model_proof?(run["evaluator"])

    fence = load_fence!(namespace, scope(authority), run["generation"])
    assert RunFence.valid_terminal?(fence["terminal"])
    assert fence["terminal"]["status"] == "evaluated"

    assert {:ok, ^run} = Ledger.fetch(namespace, run["run_id"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert {:ok, listed} = Ledger.list(namespace)
    assert Enum.filter(listed, &(&1["run_id"] == run["run_id"])) == [run]

    # The full thread reaches Worker assignment, including the human answer.
    assert run["input_snapshot"]["schema"] == "comma.triage-model-input.v3"
    assert run["evaluator"]["request_count"] == 0

    # Same closed transport surface, and the same absent worker/memory effects.
    assert Fixture.collected_source_reads() |> Enum.map(&elem(&1, 0)) == [
             "clickhouse.channel_current"
           ]

    assert Fixture.collected_slack_calls() == ["api/emoji.list"]
    refute SalixAgent.Fleet.running?(authority["inbound_agent_id"])

    for literal <- Fixture.raw_meeting_literals() do
      assert run["input_snapshot"]["canonical_snapshot_bytes"] =~ literal
      assert Jason.encode!(run) =~ literal
    end
  end

  # BRI-1659: the addressed bot remains an explicit principal in the context
  # handed to the Worker. Intake does not make the participation decision.
  test "an agent that @-mentions this bot reaches Worker assignment with its principal identity",
       ctx do
    %{authority: authority} = ctx

    namespace = "triage-acceptance-agent-#{System.unique_integer([:positive])}"
    server = start_engine!(namespace)

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

  test "a later agent answer reaches Worker assignment without a preliminary reply", ctx do
    %{authority: authority} = ctx

    namespace = "triage-acceptance-agent-answered-#{System.unique_integer([:positive])}"

    server =
      start_engine!(namespace, [], LaterEvidenceProvider, %{
        "expected_evidence" => "我已经贴了负责人：Lin。"
      })

    Fixture.put_thread(
      unanswered_thread(authority) ++
        [Fixture.mirrored_agent_message(ts(9), "U_REVIEWER", "我已经贴了负责人：Lin。")]
    )

    Fixture.admit_root!(server, authority, "Ev-agent-answered-1", "Atlas 登录事故还需要确认处理人")
    Fixture.admit_reply!(server, authority, "Ev-agent-answered-2", ts(2), "我记得周会里讨论过这件事")

    Fixture.admit_reply!(
      server,
      authority,
      "Ev-agent-answered-3",
      ts(3),
      "谁在跟进 Atlas 登录事故？"
    )

    run = Fixture.await_run!(server)

    assert run["status"] == "evaluated"
    Harness.assert_worker_assignment!(run)
    assert RunFence.valid_model_proof?(run["evaluator"])

    assert run["evaluator"]["request_count"] == 0

    assert Fixture.collected_source_reads() |> Enum.map(&elem(&1, 0)) == [
             "clickhouse.channel_current"
           ]

    assert Fixture.collected_slack_calls() == ["api/emoji.list"]
  end

  # The engine side of typed reply admission, on a window wide enough that
  # nothing can settle by accident: every step is asserted on the DURABLE
  # bucket rather than on wall-clock luck.
  test "a reply and a question both extend the trailing debounce window", ctx do
    %{authority: authority} = ctx

    namespace = "triage-acceptance-reply-#{System.unique_integer([:positive])}"
    policy = %{debounce_ms: 2_000, max_wait_ms: 30_000}
    owner = self()

    # The seal is held open just long enough for this test to read the durable
    # bucket the fast path armed, so the read cannot race the evaluation it is
    # about.
    before_seal_hook = fn _scope_key, _generation ->
      send(owner, {:before_seal, self()})

      receive do
        :continue_seal -> :ok
      after
        5_000 -> :ok
      end
    end

    server =
      start_engine!(namespace,
        debounce_ms: 2_000,
        max_wait_ms: 30_000,
        before_seal_hook: before_seal_hook
      )

    Fixture.put_thread(unanswered_thread(authority))

    root = Fixture.admit_root!(server, authority, "Ev-reply-window-1", "Atlas 登录事故还需要确认处理人")

    scope = scope(authority)
    assert Bucketing.scope_key(root) == scope

    root_only = Bucketing.load!(namespace, scope)
    assert Enum.map(root_only["open_receipts"], & &1["receipt_ref"]) == [root["receipt_ref"]]
    refute root_only["open_fast_path"]
    root_due_at = Bucketing.durable_due_at(root_only, policy, now_ms())
    assert root_due_at > now_ms()

    # A human continuation lands inside the open window: same bucket, and the
    # deadline moves out to a trailing window measured from the REPLY. Without
    # reply admission this receipt would not exist and the deadline would be
    # frozen at the root's own.
    Process.sleep(50)

    reply =
      Fixture.admit_reply!(server, authority, "Ev-reply-window-2", ts(2), "我记得周会里讨论过这件事")

    assert Bucketing.scope_key(reply) == scope
    refute reply["triage_event"]["fast_path"]

    with_reply = Bucketing.load!(namespace, scope)

    assert Enum.map(with_reply["open_receipts"], & &1["receipt_ref"]) ==
             [root["receipt_ref"], reply["receipt_ref"]]

    assert Bucketing.durable_due_at(with_reply, policy, now_ms()) > root_due_at
    assert Triage.ledger_records(server) == []

    # Ambient questions remain inside the same trailing window. Only explicit
    # directed traffic uses the separate immediate path.
    question =
      Fixture.admit_reply!(
        server,
        authority,
        "Ev-reply-window-3",
        ts(3),
        "谁在跟进 Atlas 登录事故？"
      )

    refute question["triage_event"]["fast_path"]
    with_question = Bucketing.load!(namespace, scope)
    refute with_question["open_fast_path"]
    assert Bucketing.durable_due_at(with_question, policy, now_ms()) > now_ms() + 1_000
    refute_receive {:before_seal, _engine}, 100
    assert_receive {:before_seal, engine}, 3_000

    send(engine, :continue_seal)

    run = Fixture.await_run!(server)

    assert run["authoritative"] == true
    assert run["status"] == "evaluated"

    assert run["input_receipt_refs"] ==
             ["receipt://run/r001", "receipt://run/r002", "receipt://run/r003"]

    # One sealed generation holding the root and both replies, and an empty
    # open one behind it.
    assert {:ok, bucket} = Bucketing.load(namespace, scope)
    assert bucket["open_receipts"] == []
    assert bucket["sealed_generations"] == []

    assert {:ok, %{"receipts" => sealed}} =
             Bucketing.load_sealed_generation(
               namespace,
               bucket["bucket_scope"],
               run["generation"]
             )

    assert Enum.map(sealed, & &1["receipt_ref"]) ==
             Enum.map([root, reply, question], & &1["receipt_ref"])

    fence = load_fence!(namespace, scope, run["generation"])
    assert RunFence.valid_terminal?(fence["terminal"])
    assert fence["terminal"]["status"] == "evaluated"
  end

  defp install_no_wake_worker_delivery! do
    previous = Application.fetch_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, NoWakeWorkerDelivery)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        {:ok, value} -> Application.put_env(:salix_im, :agent_delivery_mod, value)
        :error -> Application.delete_env(:salix_im, :agent_delivery_mod)
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
                    %{trusted_origin: %{"conversation_id" => ^task_id}} = command},
                   5_000

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

  defp now_ms, do: System.system_time(:millisecond)

  defp start_engine!(namespace, overrides \\ [], provider \\ StubProvider, provider_opts \\ %{}) do
    test_pid = self()

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

  defp answered_thread(authority) do
    unanswered_thread(authority) ++
      [Fixture.mirrored_message(ts(9), "U_ADA", "我来跟进，负责人是 Lin。")]
  end

  ## Small helpers

  defp scope(authority), do: Fixture.scope(authority, "__channel__")

  defp ts(n), do: Fixture.ts(n)
end
