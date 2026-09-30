defmodule BridgeForTeams.TriageCollaborationCompositionTest do
  @moduledoc """
  Opt-in eight-thread production-path local collaboration replay.

  Load alongside triage_investigation_composition_test.exs to reuse its bounded
  real-provider observer and Slack transport. Both actual role profiles must
  be explicit. No expected answer, chosen Worker, artifact locator or later
  reply is inserted into any model input. Standard Worker tools remain enabled.
  Ambient Triage uses one configured Worker from three local Workers with the selected profile.
  Direct commands retain Router discovery.
  The separately tagged, owner-approved peer-review trial adds one operational
  followup after a fresh baseline, naming a driver-selected unused reviewer.

  Real boundaries: ambient typed Triage receipt/Runtime/fence/BFT delegation or
  explicit-command signed ProviderHTTP ingress, followed by the normal Router,
  canonical Task, Worker execution, and product-owned participation delivery. Ambient Triage has no mandatory card; direct human Tasks retain it.
  Substitutions: frozen de-identified messages/files, finite local search/web
  cache, fixture installation/project, fake local S3, loopback Slack; immediate
  Triage communication uses AuditSink. No online write or UI acceptance is claimed.
  Mechanical success is not semantic quality acceptance. Full outcomes, reads,
  failures and actual role settings are emitted for source-grounded human review.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.TriageCollaborationCorpus, as: Corpus
  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageInvestigationCompositionTest, as: Observer
  alias Observer.{BoundedLiveProvider, RoleProfiles, SlackLoopback, SourceImageObserver}
  alias BridgeForTeams.TriageInvestigationContext, as: Context
  alias BridgeForTeams.TriageInvestigationSearch, as: Search
  alias BridgeForTeams.TriageInvestigationTransports, as: Transports
  alias BridgeForTeams.TriageSourceAuthorityDiagnostic, as: SourceAuthorityDiagnostic
  alias BridgeForTeams.Schema.Agent, as: ProductAgent
  alias SalixAgent.{AgentWorkspace, InternalSessionStore}
  alias SalixAgent.LiveLlmTestSupport, as: Live
  alias SalixIM.Conversations
  alias SalixIM.Triage.{AuditSink, CanonicalJSON, ProductEffectWorker}
  alias SalixStore.Ids

  @moduletag :live_llm
  @moduletag :triage_collaboration_composition
  @moduletag timeout: 420_000
  @moduletag sandbox_ownership_timeout: 420_000
  @state_key :triage_investigation_composition_state

  defmodule CapturedHTTPPageReader do
    # Preserve snapshot/search seams. Only optional history/replies callbacks
    # are absent, so MessageRead uses the finite captured HTTP pages.
    alias BridgeForTeams.TriageInvestigationContext, as: Context
    defdelegate tail(scope), to: Context
    defdelegate list_changes(scope, window, limit), to: Context
    defdelegate latest_states(scope, timestamps), to: Context
    defdelegate read_thread(scope, root, opts), to: Context
    defdelegate read_channel(scope, window, opts), to: Context
    defdelegate search(scope, opts), to: Context
  end

  setup do
    profiles = RoleProfiles.read!()
    assert System.get_env("COMMA_TRIAGE_WORKER_CONTEXT_DIAGNOSTIC") in [nil, ""]
    SalixStore.S3.Fake.reset()
    unless Process.whereis(Ids), do: start_supervised!(Ids)
    :ok = Fixture.install_clickhouse_reader!(self())
    restore_runtime = Live.install_runtime!()

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             provider_calls: 0,
             request_contracts: [],
             source_image_requests: [],
             slack_reads: [],
             context_reads: [],
             provider_responses: [],
             transport_events: [],
             slack_thread: nil,
             slack: [],
             deadline: System.monotonic_time(:millisecond) + 300_000
           }
         end}
      )

    previous_state = Application.get_env(:bridge_for_teams_core, @state_key)
    previous_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:bridge_for_teams_core, @state_key, state)
    Application.put_env(:salix_agent, :llm, BoundedLiveProvider)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: {SlackLoopback, state}, port: port, startup_log: false}
      end)

    base = "http://127.0.0.1:#{port}/api"
    Application.put_env(:salix_im, :slack_api_base_url, base)

    restore_transports =
      Transports.install!(
        llm_base_urls: [profiles.router.base_url, profiles.worker.base_url],
        slack_base_url: base,
        live_exa_api_key: System.get_env("COMMA_TRIAGE_LIVE_WEB_API_KEY"),
        llm_request_observer: &SourceImageObserver.capture_request(state, &1, &2),
        exa: fn request -> Context.web_response(Agent.get(state, & &1.context), request) end,
        capture: fn event ->
          if Process.alive?(state) do
            Agent.update(
              state,
              &Map.update!(&1, :transport_events, fn events -> [event | events] end)
            )
          end

          :ok
        end
      )

    on_exit(fn ->
      restore_transports.()
      restore_runtime.()
      restore_env(:salix_im, :slack_api_base_url, previous_base)
      restore_env(:bridge_for_teams_core, @state_key, previous_state)
    end)

    %{profiles: profiles, state: state, base: base}
  end

  defmodule FollowUpThreadReader do
    def read(_authority, _connect, _target) do
      state =
        Application.fetch_env!(:bridge_for_teams_core, :triage_investigation_composition_state)

      {:ok, %{"messages" => Agent.get(state, & &1.context.source_messages)}}
    end
  end

  @tag triage_collaboration_composition: false
  @tag :triage_autonomous_followup
  test "Worker-owned recovery verification creates and fires a follow-up", context do
    original = Corpus.fetch!("historical_message_sources")
    root = Integer.to_string(System.system_time(:second)) <> ".000001"

    message =
      original["source_messages"]
      |> List.last()
      |> Map.merge(%{
        "ts" => root,
        "thread_ts" => root,
        "files" => [],
        "text" => "登录服务修复正在发布，部署窗口预计还要一小时，当前没有恢复结果。请 Triage 负责恢复验证并跟到恢复为止；发布完成后仍有503就请成员甲处理。"
      })

    sample =
      Map.merge(original, %{
        "id" => "autonomous_open_incident",
        "title" => "Synthetic unresolved incident",
        "root_ts" => root,
        "cutoff_ts" => root,
        "input_message_ts" => root,
        "source_messages" => [message],
        "retrievable_messages" => [],
        "held_out_message_ts" => [],
        "expected" => %{"route" => "participate"},
        "sample_kind" => "synthetic_open_incident",
        "capture_boundary" =>
          "Synthetic source and local Slack transport. The real Worker chooses whether and when to follow up."
      })

    run_case(sample, context)
    project_id = Agent.get(context.state, & &1.project_id)

    assert {:ok, [entry]} =
             SalixStore.TriageProductRuntime.list_context(project_id, kind: "follow_up")

    assert entry.state == :active
    assert entry.payload["follow_up_basis"] == "agent_owned"
    schedule_id = entry.payload["schedule_id"]
    assert {:ok, schedule} = SalixCluster.Schedules.get(schedule_id)
    assert schedule["receiver"] == "triage_follow_up"
    due = SalixCluster.Schedules.next_fire_ms(schedule)
    assert due == DateTime.to_unix(entry.next_check_at, :millisecond)

    previous = Application.get_env(:salix_im, :triage_follow_up_thread_reader_mod)
    Application.put_env(:salix_im, :triage_follow_up_thread_reader_mod, FollowUpThreadReader)
    on_exit(fn -> restore_env(:salix_im, :triage_follow_up_thread_reader_mod, previous) end)

    assert {:ok, sweep} = SalixCluster.Schedules.run_once(now: due)
    assert schedule_id in sweep.fired

    assert {:ok, [next]} =
             SalixStore.TriageProductRuntime.list_context(project_id, kind: "follow_up")

    assert next.state == :active
    assert next.payload["last_wakeup_schedule_id"] == schedule_id
    assert is_binary(next.payload["last_wakeup_event_id"])
    refute next.payload["schedule_id"] == schedule_id
    assert {:ok, _} = SalixCluster.Schedules.get(next.payload["schedule_id"])
  end

  for case_data <- Corpus.cases() do
    @tag collaboration_case: case_data["id"]
    test "real collaboration: #{case_data["id"]}", context do
      run_case(unquote(Macro.escape(case_data)), context)
    end
  end

  for case_data <- Corpus.participation_cases() do
    @tag collaboration_case: case_data["id"]
    test "real participation: #{case_data["id"]}", context do
      run_case(unquote(Macro.escape(case_data)), context)
    end
  end

  for case_data <- Corpus.direct_correction_cases() do
    @tag triage_collaboration_composition: false
    @tag triage_direct_correction_case: case_data["id"]
    test "direct correction keeps unresolved work: #{case_data["id"]}", context do
      run_case(unquote(Macro.escape(case_data)), context, direct_correction_trial: true)
    end
  end

  @tag triage_collaboration_composition: false
  @tag :triage_login_screenshot_original
  test "current ambient entry reads the originally supplied login screenshot", context do
    run_case(Corpus.login_screenshot_original(), context)
  end

  @tag triage_collaboration_composition: false
  @tag :triage_subscription_screenshot_original
  test "an existing source screenshot reaches Worker vision before its risk answer", context do
    run_case(Corpus.subscription_screenshot_original(), context)
  end

  @tag triage_collaboration_composition: false
  @tag :triage_worker_only_calendar
  test "ambient Calendar investigation reads the captured original sources", context do
    original = Corpus.fetch!("calendar_source_conflict")
    # A labeled ambient variant of the same source corpus: remove only the
    # trigger's direct recipient mention, so this exercises Triage admission.
    variant =
      original
      |> Map.put("id", "ambient_calendar_source_conflict")
      |> Map.put("source_case_id", original["id"])
      |> Map.put("sample_kind", "derived_ambient_calendar_request")
      |> Map.update!(
        "capture_boundary",
        &(&1 <>
            " Ambient variant removes the direct recipient mention from the trigger only; original evidence is unchanged.")
      )
      |> Map.update!("source_messages", fn messages ->
        Enum.map(messages, fn message ->
          if message["ts"] == original["input_message_ts"],
            do:
              Map.update!(
                message,
                "text",
                &(&1 |> String.replace(~r/<@U_BFT(?:\|[^>]*)?>/u, "") |> String.trim())
              ),
            else: message
        end)
      end)

    run_case(variant, context)
  end

  @tag triage_collaboration_composition: false
  @tag :triage_requested_attachment
  test "supplemental local request returns the captured original transcript", context do
    run_case(Corpus.attachment_request(), context, original_file: "FCOLLAB001")
  end

  for arm <- SourceAuthorityDiagnostic.arms() do
    @tag triage_collaboration_composition: false
    @tag :triage_source_authority_probe
    @tag source_authority_arm: arm
    test "diagnostic Task command factor: #{arm}", context do
      case_data =
        Corpus.fetch!("screenshot_implementation_uncertainty")
        |> Map.put("sample_kind", "captured_source_with_test_only_task_command_intervention")
        |> Map.put("source_case_id", "screenshot_implementation_uncertainty")
        |> Map.put(
          "capture_boundary",
          "The source request, ordinary role settings and tools are unchanged. Only initial Task content is controlled at the test port before reservation; the Router's title and later coordination remain stochastic. Not product acceptance."
        )

      run_case(case_data, context, source_authority_arm: unquote(arm))
    end
  end

  for case_id <- ~w(calendar_source_conflict historical_message_sources) do
    @tag triage_collaboration_composition: false
    @tag :triage_peer_review_trial
    @tag review_trial_case: case_id
    @tag timeout: 720_000
    @tag sandbox_ownership_timeout: 720_000
    test "one independent evidence review and original Worker revision: #{case_id}", context do
      run_case(Corpus.fetch!(unquote(case_id)), context, peer_review_trial: true)
    end
  end

  defp run_case(case_data, %{profiles: profiles, state: state, base: base}, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    # Local source identities must pass the same Slack selector validation as
    # production; the old C_ATLAS placeholder could not be searched.
    authority =
      Fixture.seed_authority!(%{
        "workspace_id" => "T0ATLAS001",
        "approved_channel_id" => "C0ATLAS001"
      })

    router = authority["inbound_agent_id"]

    context =
      Corpus.build(case_data, authority, base, System.get_env("COMMA_TRIAGE_COLLABORATION_CACHE"))

    Fixture.put_thread(context.source_messages)

    {:ok, connect} =
      SalixStore.CasRecord.get(
        SalixStore.Keys.ctl_im_connect(authority["group_id"], authority["connect_id"])
      )

    on_exit(Context.install!(state, context))

    if opts[:direct_correction_trial] do
      assert Corpus.entrypoint(case_data) == :direct_command
      Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, CapturedHTTPPageReader)
    end

    # File-only messages have no lexical text unit. Their attachments remain
    # discoverable through the real original-thread read/fetch-file operations.
    searchable = Enum.reject(context.messages, &(String.trim(&1["text"]) == ""))
    on_exit(Search.install!(state, connect, searchable))

    role_instructions = System.fetch_env!("COMMA_TRIAGE_ROLE_INSTRUCTIONS") |> Jason.decode!()
    configure_selected_agent!(router, "router", profiles.router, role_instructions["router"])
    project = Fixture.seed_project!(authority)

    worker_ids =
      for _index <- 1..3 do
        id = Ids.new_agent_id(authority["group_id"])
        configure_selected_agent!(id, "worker", profiles.worker, role_instructions["worker"])

        Repo.insert!(%ProductAgent{
          project_id: project.id,
          salix_agent_id: id,
          role: "worker",
          configuration_authority: "salix"
        })

        id
      end

    assert {:ok, _} =
             SalixAgent.TriageWorker.configure(
               authority["group_id"],
               router,
               hd(worker_ids),
               0,
               %{"actor_user_id" => "local-fixture-admin", "request_id" => "collaboration-worker"}
             )

    Agent.update(
      state,
      &Map.merge(&1, %{
        project_id: project.id,
        authority: authority,
        worker_ids: worker_ids,
        case_id: case_data["id"],
        expected_route: case_data["expected"]["route"],
        root_ts: case_data["root_ts"],
        requested_attachment: not is_nil(opts[:original_file]),
        peer_review_trial: opts[:peer_review_trial] == true,
        phase: :baseline,
        expected_source_images:
          case case_data["id"] do
            "screenshot_implementation_uncertainty" ->
              Map.take(context.files, ~w(FCOLLAB007 FCOLLAB008))

            "login_screenshot_original" ->
              Map.take(context.files, ~w(FLOGIN001))

            "subscription_screenshot_original" ->
              Map.take(context.files, ~w(FSUBSCRIPTION001))

            _ ->
              %{}
          end,
        outcome: "running"
      })
    )

    if arm = opts[:source_authority_arm] do
      {:ok, binding} = previous = Application.fetch_env(:salix_im, :task_create_mod)
      Application.put_env(:salix_im, :task_create_mod, SourceAuthorityDiagnostic)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:salix_im, :task_create_mod, value)
          :error -> Application.delete_env(:salix_im, :task_create_mod)
        end
      end)

      Agent.update(
        state,
        &Map.merge(&1, %{
          source_authority_arm: arm,
          source_authority_task_create_binding: binding
        })
      )
    end

    try do
      case Corpus.entrypoint(case_data) do
        :triage ->
          admit_and_observe!(case_data, authority, worker_ids, state)

        :direct_command ->
          admit_direct_and_observe!(case_data, authority, worker_ids, state, opts)
      end

      assert_role_profiles!(state, profiles)

      if case_data["id"] == "meeting_action_detail" do
        replies = Agent.get(state, & &1.slack)

        assert Enum.any?(replies, fn reply ->
                 text = get_in(reply, [:params, "text"]) || ""
                 String.contains?(text, "14") and String.contains?(String.downcase(text), "ical")
               end),
               "available action-item evidence must not become only a request to wait for history sync"
      end

      if opts[:source_authority_arm], do: assert_source_authority_command!(authority, state)

      if case_data["id"] == "screenshot_implementation_uncertainty",
        do: assert_source_images_reached_worker!(state)

      if case_data["id"] == "login_screenshot_original",
        do: assert_source_images_reached_worker!(state, ~w(FLOGIN001))

      if case_data["id"] == "subscription_screenshot_original" do
        assert_source_images_reached_worker!(state, ~w(FSUBSCRIPTION001))

        assert get_in(Agent.get(state, & &1.run), ["decision", "communication", "kind"]) ==
                 "silence",
               "an unread supplied image must not become an upfront request to describe it"
      end

      if file_id = opts[:original_file],
        do: assert_original_file_returned!(authority, state, file_id)

      if opts[:peer_review_trial] do
        Agent.update(
          state,
          &Map.put(&1, :outcome, "baseline_mechanical_checks_passed_semantic_review_pending")
        )

        emit_outcome(case_data, state, profiles, System.monotonic_time(:millisecond) - started)
        peer_review_and_revise!(case_data, authority, worker_ids, state)
        assert_role_profiles!(state, profiles)
      end

      Agent.update(
        state,
        &Map.put(&1, :outcome, "mechanical_checks_passed_semantic_review_pending")
      )
    rescue
      error ->
        Agent.update(state, &Map.put(&1, :outcome, "mechanical_checks_failed"))
        reraise error, __STACKTRACE__
    after
      emit_outcome(case_data, state, profiles, System.monotonic_time(:millisecond) - started)
    end
  end

  defp configure_selected_agent!(id, role, profile, instructions) do
    assert is_map(instructions), "selected live role instructions must be read explicitly"

    Observer.configure_agent!(
      id,
      role,
      instructions["name"],
      profile,
      instructions["system_prompt"] || ""
    )

    patch = Map.take(instructions, ~w(purpose router_system_prompt disabled_tools))
    assert {:ok, _} = SalixAgent.Control.configure(id, patch, Ids.tenant_id_from_agent!(id))
    assert {:ok, actual} = SalixAgent.Control.get_record(id)
    assert Map.take(actual, Map.keys(instructions)) == instructions
  end

  defp assert_source_authority_command!(authority, state) do
    current = Agent.get(state, & &1)
    [observation] = current.source_authority_commands
    [task] = tasks(authority["group_id"])

    {:ok, [initial | _]} =
      Conversations.list_group_conversation_messages(
        authority["group_id"],
        task["conversation_id"],
        limit: 100
      )

    assert task["task_worker_agent_id"] == observation.worker
    assert task["title"] == observation.effective["title"]
    assert task["title"] == observation.requested["title"]
    assert initial["content"] == [%{"type" => "text", "text" => observation.effective["content"]}]
    assert initial["agent_id"] == authority["inbound_agent_id"]
  end

  defp admit_and_observe!(case_data, authority, worker_ids, state) do
    root = case_data["root_ts"]

    route_scope =
      authority
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id))
      |> Map.merge(%{"channel_id" => authority["approved_channel_id"], "root_thread_ts" => root})

    {:ok, root_us} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(root)

    {:ok, identity} =
      SalixIM.Provider.Slack.ThreadRouteOwner.clickhouse_root_claim_identity(route_scope, root_us)

    assert {:ok, :triage} =
             SalixIM.Provider.Slack.ThreadRouteOwner.claim_triage(route_scope, identity)

    namespace = "triage-collaboration-" <> Live.unique_suffix()

    server =
      Fixture.start_engine!(
        namespace,
        {Salix.Bindings.TriageEvaluator,
         [
           provider: BoundedLiveProvider,
           provider_config: :agent_template,
           transport_receipt: fn bytes ->
             %{payload_sha256: CanonicalJSON.sha256(bytes), request_count: 1}
           end
         ]},
        evaluation_timeout_ms: 150_000
      )

    trigger =
      Agent.get(
        state,
        &Enum.find(&1.context.source_messages, fn message ->
          message["ts"] == case_data["input_message_ts"]
        end)
      )

    Fixture.admit_reply!(
      server,
      authority,
      "Ev-collaboration-#{case_data["id"]}",
      trigger["ts"],
      trigger["text"],
      root_ts: root,
      actor_id: trigger["user"]
    )

    run = Fixture.await_run!(server, 3_000)
    Agent.update(state, &Map.put(&1, :run, run))
    assert run["status"] == "evaluated"

    # Every admitted ordinary batch reaches one Worker, including resolved/social
    # observations. Silence is a completed Worker decision, not an intake skip.
    assert [_selection] = run["decision"]["delegations"]
    assert run["decision"]["communication"]["reason"] == "worker_pending"
    {:ok, [claim]} = Fixture.claim_round!(%{namespace: namespace, run: run}, "collaboration")

    assert {:ok, %{status: :fresh}} =
             SalixIM.Triage.SlackEffectAdapter.Freshness.check(claim, [])

    assert {:ok, %{claimed: 1, applied: 1, failed: 0}} =
             ProductEffectWorker.process_once(
               adapter: SalixIM.Triage.SlackEffectAdapter,
               claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
               delegation_opts: [delegation_port: BridgeForTeams.TriageDelegation]
             )

    observe_participation_return!(authority, worker_ids, root, state)
  end

  defp admit_direct_and_observe!(case_data, authority, worker_ids, state, opts) do
    trigger =
      Agent.get(
        state,
        &Enum.find(&1.context.source_messages, fn message ->
          message["ts"] == case_data["input_message_ts"]
        end)
      )

    secret = "local-collaboration-callback-signature"
    key = SalixStore.Keys.ctl_im_connect(authority["group_id"], authority["connect_id"])
    {:ok, connect} = SalixStore.CasRecord.update(key, &Map.put(&1, "signing_secret", secret))

    envelope = %{
      "type" => "event_callback",
      "api_app_id" => authority["app_id"],
      "team_id" => authority["workspace_id"],
      "event_id" => "Ev-collaboration-#{case_data["id"]}",
      "event" => trigger |> Map.put("type", "app_mention") |> Map.put("channel_type", "channel")
    }

    raw = Jason.encode!(envelope)
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "v0:#{timestamp}:#{raw}") |> Base.encode16(case: :lower)

    headers = [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> signature}
    ]

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(connect, envelope, headers, raw)

    cond do
      opts[:direct_correction_trial] ->
        observe_direct_correction!(case_data, authority, worker_ids, state)

      case_data["expected"]["route"] == "answer" ->
        route =
          Live.eventually(
            fn ->
              cond do
                tasks(authority["group_id"]) != [] ->
                  {:ok, :worker}

                Agent.get(
                  state,
                  &Enum.any?(&1.slack, fn request -> request.method == "chat.postMessage" end)
                ) ->
                  {:ok, :reply}

                true ->
                  :retry
              end
            end,
            180_000
          )

        case route do
          :worker ->
            observe_worker_return!(authority, worker_ids, case_data["root_ts"], state)

          :reply ->
            {:ok, session_id} =
              SalixIM.ProviderConnects.agent_group_router_session_id(
                authority["inbound_agent_id"],
                authority["group_id"]
              )

            assert :ok =
                     SalixAgent.TestSupport.await_session_quiet(
                       authority["inbound_agent_id"],
                       session_id,
                       30_000
                     )

            [reply] =
              Agent.get(
                state,
                &Enum.filter(&1.slack, fn request -> request.method == "chat.postMessage" end)
              )

            assert reply.params["channel"] == authority["approved_channel_id"]
            assert reply.params["thread_ts"] == case_data["root_ts"]
            assert String.trim(reply.params["text"] || "") != ""
        end

      true ->
        observe_worker_return!(authority, worker_ids, case_data["root_ts"], state)
    end
  end

  defp observe_direct_correction!(case_data, authority, worker_ids, state) do
    group = authority["group_id"]
    router = authority["inbound_agent_id"]
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(router, group)

    {task, result, session} =
      Live.eventually(
        fn ->
          {:ok, session} = InternalSessionStore.read(router, session_id)

          source =
            Enum.find(
              SalixAgent.InternalSession.get(session, :messages),
              &direct_probe_source?(&1, case_data, authority)
            )

          source_acked =
            source &&
              SalixAgent.InternalSession.last_ack_message_id(session) >= value(source, :id)

          settled =
            source_acked && SalixAgent.ProviderReplyObligation.blocking_count(session) == 0

          case tasks(group) do
            [] ->
              if settled, do: {:ok, {nil, nil, session}}, else: :retry

            [%{"status" => "ready_for_review"} = task] ->
              {:ok, messages} =
                Conversations.list_group_conversation_messages(group, task["conversation_id"],
                  limit: 100
                )

              result =
                Observer.worker_result_at_card_write(messages, task["task_worker_agent_id"])

              returned =
                result &&
                  Enum.find(SalixAgent.InternalSession.get(session, :messages), fn item ->
                    origin = value(item, :trusted_origin) || %{}

                    value(item, :role) == "user" && origin["provider"] == "internal" &&
                      origin["conversation_id"] == task["conversation_id"] &&
                      origin["message_id"] == result["message_id"]
                  end)

              if settled && returned &&
                   SalixAgent.InternalSession.last_ack_message_id(session) >= value(returned, :id),
                 do: {:ok, {task, result, session}},
                 else: :retry

            [_active] ->
              :retry

            many ->
              flunk("expected at most one investigation, found #{length(many)} Tasks")
          end
        end,
        remaining_case_budget(state)
      )

    final =
      if task do
        result_id = result["message_id"]

        Live.eventually(
          fn ->
            delivered = Agent.get(state, & &1.slack)

            final =
              Enum.find(Enum.reverse(delivered), fn request ->
                captured = request.task_at_write

                captured && captured["status"] == "ready_for_review" &&
                  match?(
                    %{"message_id" => ^result_id},
                    Observer.worker_result_at_card_write(
                      captured["messages"],
                      task["task_worker_agent_id"]
                    )
                  )
              end)

            if final, do: {:ok, final}, else: :retry
          end,
          remaining_case_budget(state)
        )
      end

    writes = Agent.get(state, & &1.slack)
    posts = Enum.filter(writes, &(&1.method == "chat.postMessage"))
    assert posts != []

    for request <- writes do
      assert request.method in ["chat.postMessage", "chat.update"]
      assert request.params["channel"] == authority["approved_channel_id"]

      if request.method == "chat.postMessage",
        do: assert(request.params["thread_ts"] == case_data["root_ts"])
    end

    if case_data["expected"]["route"] == "answer" do
      assert is_nil(task), "a complete answer or apology-only exchange must not create work"
      assert [reply] = posts
      assert length(writes) == 1
      refute task_card_write?(reply)
      assert String.trim(reply.params["text"] || "") != ""

      if case_data["id"] == "direct_known_answer" do
        text = String.replace(reply.params["text"], " ", "")
        assert text =~ "15:00" and text =~ "新加坡" and text =~ "2号会议室"
      end
    else
      # Source reads or completed capability discovery must precede the final
      # answer. Task/Agent listing and a correction alone cannot pass this case.
      actors = if task, do: [router, task["task_worker_agent_id"]], else: [router]
      cutoff_ms = if result, do: result["created_at"], else: System.system_time(:millisecond)

      checks =
        for actor <- actors,
            %{"session_id" => id} <-
              elem(SalixAgent.Runtime.list_sessions(actor, include_hidden: true), 1),
            {:ok, current} = InternalSessionStore.read(actor, id),
            message <- SalixAgent.InternalSession.get(current, :messages),
            check = completed_calendar_source_check(message, cutoff_ms),
            not is_nil(check),
            do: check

      assert checks != [], "correction alone must not discharge the unanswered Calendar question"
      Agent.update(state, &Map.put(&1, :direct_source_checks, checks))

      if task do
        assert task["task_worker_agent_id"] in worker_ids
        assert task["created_by_agent_id"] == router
        assert final.params["channel"] == authority["approved_channel_id"]
        Observer.assert_native_worker_output!(final.params, result)
      else
        final = posts |> Enum.reject(&task_card_write?/1) |> List.last()
        assert final && String.trim(final.params["text"] || "") != ""

        checked_at =
          Enum.find_index(
            SalixAgent.InternalSession.get(session, :messages),
            &completed_calendar_source_check(&1, cutoff_ms)
          )

        published_at =
          Enum.find_index(SalixAgent.InternalSession.get(session, :messages), fn message ->
            Enum.any?(value(message, :tool_calls) || [], fn call ->
              args = value(call, :args) || %{}

              args["tool"] == "im_api.slack.reply_message" &&
                get_in(args, ["params", "text"]) == final.params["text"]
            end)
          end)

        assert is_integer(checked_at) && is_integer(published_at) && checked_at < published_at,
               "a direct result must be delivered after the source or capability check completed"
      end
    end

    assert SalixAgent.ProviderReplyObligation.blocking_count(session) == 0
  end

  defp direct_probe_source?(message, case_data, authority) do
    origin = value(message, :trusted_origin) || %{}
    source = origin["provider_context"] || %{}

    value(message, :role) == "user" && origin["provider"] == "slack" &&
      source["connect_id"] == authority["connect_id"] &&
      source["channel_id"] == authority["approved_channel_id"] &&
      source["thread_ts"] == case_data["root_ts"] &&
      source["message_ts"] == case_data["input_message_ts"]
  end

  defp completed_calendar_source_check(message, cutoff_ms) do
    result =
      case value(message, :role) do
        "tool" ->
          %{
            "id" => value(message, :tool_call_id),
            "name" => value(message, :tool_name),
            "status" => value(message, :status),
            "input" => value(message, :input),
            "content" => value(message, :content),
            "started_at" => value(message, :started_at),
            "duration_ms" => value(message, :duration_ms)
          }

        "runtime" ->
          decoded =
            with content when is_binary(content) <- value(message, :content),
                 do: Jason.decode(content)

          case decoded do
            {:ok,
             %{
               "type" => "tool_call_completed",
               "status" => "completed",
               "error" => false,
               "result" => result
             }} ->
              result

            _ ->
              nil
          end

        _ ->
          nil
      end

    with %{"status" => "completed"} <- result,
         true <- result["name"] in ~w(mcp.list im.connects_list device.list),
         {:ok, input} when is_map(input) <- Jason.decode(result["input"] || "{}"),
         true <- unfiltered_capability_check?(result["name"], input),
         started when is_integer(started) <- result["started_at"],
         duration when is_integer(duration) <- result["duration_ms"],
         true <- started + duration <= cutoff_ms,
         body when is_binary(body) <- result["content"],
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         true <- decoded["next_cursor"] in [nil, ""] do
      Map.take(result, ~w(id name status content started_at duration_ms))
    else
      _ -> nil
    end
  end

  defp unfiltered_capability_check?("mcp.list", %{"kind" => "bindings"} = input),
    do: unfiltered_capability_check?("mcp.list", Map.delete(input, "kind"))

  defp unfiltered_capability_check?(_tool, input),
    do: Map.drop(input, ~w(limit cursor)) == %{}

  defp task_card_write?(request),
    do:
      get_in(request.params, ["metadata", "event_type"]) ==
        SalixIM.SlackTaskCard.metadata_event_type()

  defp assert_role_profiles!(state, profiles) do
    contracts = Agent.get(state, & &1.request_contracts)

    for contract <- contracts do
      expected =
        case contract.role do
          :triage -> RoleProfiles.triage_metadata(profiles.router)
          :router -> RoleProfiles.safe_metadata(profiles.router)
          :worker -> RoleProfiles.safe_metadata(profiles.worker)
        end

      assert contract.profile == expected
      assert is_nil(contract.worker_source_locator)
      assert contract.source_attribution_guidance == contract.role in [:router, :worker]
      assert contract.user_facing_answer_guidance == contract.role in [:router, :worker]
      assert contract.router_investigation_authorship == (contract.role == :router)
      assert contract.slack_participation_guidance == (contract.role == :router)
      refute contract.unconditional_worker_rewrite
    end
  end

  defp assert_source_images_reached_worker!(state, expected_ids \\ ~w(FCOLLAB007 FCOLLAB008)) do
    current = Agent.get(state, & &1)
    [task] = tasks(current.authority["group_id"])
    worker = task["task_worker_agent_id"]
    assert worker in current.worker_ids

    {:ok, messages} =
      Conversations.list_group_conversation_messages(
        current.authority["group_id"],
        task["conversation_id"],
        limit: 100
      )

    result =
      Enum.find(
        messages,
        &(get_in(&1, ["metadata", "triage_investigation_result", "worker_agent_id"]) == worker)
      )

    assert result && is_integer(result["created_at"])

    # Role-level request observation is only sufficient if this captured
    # case has no other active Worker. Do not credit a peer's image input.
    for other <- current.worker_ids -- [worker] do
      {:ok, sessions} = SalixAgent.Runtime.list_sessions(other, include_hidden: true)

      for %{"session_id" => session_id} <- sessions do
        {:ok, session} = InternalSessionStore.read(other, session_id)

        refute Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(value(&1, :role) == "assistant")
               )
      end
    end

    sources =
      SourceImageObserver.sources_before_result(
        current.source_image_requests,
        result["created_at"]
      )

    assert Map.keys(current.expected_source_images) |> Enum.sort() == Enum.sort(expected_ids)

    assert Enum.map(sources, & &1.file_id) |> Enum.sort() == Enum.sort(expected_ids),
           "all original screenshots must reach successful Worker native-image requests before its published answer"
  end

  defp observe_participation_return!(authority, worker_ids, root, state) do
    group = authority["group_id"]

    task =
      Live.eventually(
        fn ->
          case tasks(group) do
            [%{"status" => "ready_for_review"} = task] ->
              {:ok, task}

            [] ->
              :retry

            [%{"status" => "failed"} = task] ->
              flunk(
                "investigation failed: #{inspect(task["metadata"]["triage_investigation_state"])}"
              )

            [_active] ->
              :retry

            many ->
              flunk("expected one useful investigation, found #{length(many)} Tasks")
          end
        end,
        remaining_case_budget(state)
      )

    worker = task["task_worker_agent_id"]
    assert worker in worker_ids
    assert task["created_by_agent_id"] == authority["inbound_agent_id"]

    # A delivered completion can precede the Worker's final end_turn round.
    # Keep the original case deadline and capture the settled session as well.
    {:ok, worker_sessions} = SalixAgent.Runtime.list_sessions(worker, include_hidden: true)

    for %{"session_id" => session_id} <- worker_sessions do
      assert :ok =
               SalixAgent.TestSupport.await_session_quiet(
                 worker,
                 session_id,
                 remaining_case_budget(state)
               )
    end

    {:ok, router_session} =
      SalixIM.ProviderConnects.agent_group_router_session_id(authority["inbound_agent_id"], group)

    {:ok, messages} =
      Conversations.list_group_conversation_messages(group, task["conversation_id"], limit: 100)

    result =
      Enum.find(
        messages,
        &(get_in(&1, ["metadata", "triage_investigation_result", "worker_agent_id"]) == worker)
      )

    assert result, "the assigned Worker must complete through the canonical result owner"

    decision =
      get_in(result, ["metadata", "triage_investigation_result", "payload", "communication"])

    case InternalSessionStore.read(authority["inbound_agent_id"], router_session) do
      {:ok, session} ->
        assert SalixAgent.ProviderReplyObligation.blocking_count(session) == 0

      {:error, :not_found} ->
        # Silence need not create or activate a Router session.
        :ok

      error ->
        flunk("Router session state unavailable: #{inspect(error)}")
    end

    refute Enum.any?(Agent.get(state, & &1.request_contracts), &(&1.role == :router)),
           "initial investigation and publication must not require a Router model round"

    triage_calls = Enum.count(Agent.get(state, & &1.request_contracts), &(&1.role == :triage))
    assert triage_calls == 0

    requests = Agent.get(state, & &1.slack)
    initial = Agent.get(state, & &1.run["decision"])

    expected_effects =
      [initial["communication"], initial["companion_reaction"], decision]
      |> Enum.flat_map(fn
        %{"kind" => "reply", "text" => text} -> [{"chat.postMessage", text}]
        %{"kind" => "reaction", "emoji" => emoji} -> [{"reactions.add", emoji}]
        _ -> []
      end)

    actual_effects =
      Enum.map(requests, fn request ->
        {request.method, request.params["text"] || request.params["name"]}
      end)

    assert Enum.frequencies(actual_effects) == Enum.frequencies(expected_effects),
           "only the committed immediate participation and Worker completion may publish; no progress, cards or duplicate sends"

    for request <- requests do
      assert request.method in ["chat.postMessage", "reactions.add"]
      assert request.params["channel"] == authority["approved_channel_id"]

      if request.method == "chat.postMessage" do
        assert request.params["thread_ts"] == root

        refute get_in(request.params, ["metadata", "event_type"]) ==
                 SalixIM.SlackTaskCard.metadata_event_type(),
               "background evidence must not be automatically published as a Task card"

        assert String.trim(request.params["text"] || "") != ""
      end
    end

    case Agent.get(state, & &1.expected_route) do
      "silence" ->
        assert decision["kind"] == "silence"
        assert requests == []

      "participate" ->
        assert decision["kind"] in ~w(reply reaction silence)

      route when route in ["investigate", "answer"] ->
        # These captured requests still need an answer or a specific clarification.
        assert decision["kind"] == "reply"

        assert Enum.any?(
                 requests,
                 &(&1.method == "chat.postMessage" and &1.params["text"] == decision["text"])
               )
    end
  end

  defp observe_worker_return!(authority, worker_ids, root, state) do
    group = authority["group_id"]

    task =
      Live.eventually(
        fn ->
          case tasks(group) do
            [task] -> {:ok, task}
            [] -> :retry
            many -> flunk("expected one Task, found #{length(many)}")
          end
        end,
        180_000
      )

    worker = task["task_worker_agent_id"]
    assert worker in worker_ids
    assert task["created_by_agent_id"] == authority["inbound_agent_id"]

    first =
      Live.eventually(
        fn ->
          case Agent.get(
                 state,
                 &Enum.find(&1.slack, fn request -> request.method == "chat.postMessage" end)
               ) do
            nil -> :retry
            request -> {:ok, request}
          end
        end,
        180_000
      )

    assert first.task_at_write["status"] == "ready_for_review"
    result = Observer.worker_result_at_card_write(first.task_at_write["messages"], worker)
    assert result, "a complete Worker result must precede the first card"
    Observer.assert_native_worker_output!(first.params, result)

    {:ok, router_session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(authority["inbound_agent_id"], group)

    {:ok, sessions} = SalixAgent.Runtime.list_sessions(worker, include_hidden: true)

    for %{"session_id" => session_id} <- sessions do
      assert :ok =
               SalixAgent.TestSupport.await_session_quiet(
                 worker,
                 session_id,
                 remaining_case_budget(state)
               )
    end

    assert :ok =
             SalixAgent.TestSupport.await_session_quiet(
               authority["inbound_agent_id"],
               router_session_id,
               remaining_case_budget(state)
             )

    {:ok, router_session} =
      InternalSessionStore.read(authority["inbound_agent_id"], router_session_id)

    # Actor-local quiet can precede a durable async result's Session notification.
    # Observe each actual upload's own success, not a delay or a global idle claim.
    for call_id <-
          Observer.slack_upload_calls(SalixAgent.InternalSession.get(router_session, :messages)) do
      Live.eventually(
        fn ->
          {:ok, current} =
            InternalSessionStore.read(authority["inbound_agent_id"], router_session_id)

          case Observer.slack_upload_receipt(
                 SalixAgent.InternalSession.get(current, :messages),
                 call_id
               ) do
            :completed -> {:ok, :completed}
            :pending -> :retry
            :failed -> flunk("the Router's exact file upload must complete successfully")
          end
        end,
        remaining_case_budget(state)
      )
    end

    assert :ok =
             SalixAgent.TestSupport.await_session_quiet(
               authority["inbound_agent_id"],
               router_session_id,
               remaining_case_budget(state)
             )

    {:ok, router_session} =
      InternalSessionStore.read(authority["inbound_agent_id"], router_session_id)

    upload_receipts =
      Enum.map(
        Observer.slack_upload_calls(SalixAgent.InternalSession.get(router_session, :messages)),
        fn call_id ->
          status =
            Observer.slack_upload_receipt(
              SalixAgent.InternalSession.get(router_session, :messages),
              call_id
            )

          assert status == :completed
          %{tool_call_id: call_id, status: status}
        end
      )

    Agent.update(state, &Map.put(&1, :router_upload_receipts, upload_receipts))

    requests = Agent.get(state, & &1.slack)

    assert length(Enum.filter(requests, &(&1.method == "chat.postMessage"))) == 1

    card_methods = ["chat.postMessage", "chat.update"]

    upload_methods = [
      "files.getUploadURLExternal",
      "external_upload",
      "files.completeUploadExternal"
    ]

    allowed_methods =
      if Agent.get(state, & &1.requested_attachment),
        do: card_methods ++ upload_methods,
        else: card_methods

    for request <- requests, do: assert(request.method in allowed_methods)

    for request <- requests, request.method in card_methods do
      assert request.params["channel"] == authority["approved_channel_id"]
      if request.method == "chat.postMessage", do: assert(request.params["thread_ts"] == root)

      current_result =
        Observer.worker_result_at_card_write(request.task_at_write["messages"], worker)

      assert current_result
      Observer.assert_native_worker_output!(request.params, current_result)

      assert Observer.worker_returned_before_card_call?(
               SalixAgent.InternalSession.get(router_session, :messages),
               task["conversation_id"],
               current_result["message_id"]
             )
    end

    {:ok, messages} =
      Conversations.list_group_conversation_messages(group, task["conversation_id"], limit: 100)

    for {message, blocks} <- Observer.worker_attachments(messages, worker) do
      returned =
        Enum.find(SalixAgent.InternalSession.get(router_session, :messages), fn item ->
          source = value(item, :trusted_origin) || %{}

          source["conversation_id"] == task["conversation_id"] and
            source["message_id"] == message["message_id"]
        end)

      assert returned, "attachment Message must reach the Router"
      files = Observer.returned_files(value(returned, :content))
      assert length(files) == length(blocks)

      for {block, file} <- Enum.zip(blocks, files) do
        assert {:ok, body} = SalixStore.Blob.get(worker, block["blob_ref"])
        assert {:ok, ^body} = AgentWorkspace.read(authority["inbound_agent_id"], file["path"])
      end
    end
  end

  defp remaining_case_budget(state),
    do: max(Agent.get(state, & &1.deadline) - System.monotonic_time(:millisecond), 0)

  defp peer_review_and_revise!(case_data, authority, worker_ids, state) do
    group = authority["group_id"]
    router = authority["inbound_agent_id"]
    [original] = tasks(group)
    original_id = original["conversation_id"]
    worker = original["task_worker_agent_id"]
    reviewer = Enum.find(worker_ids, &(&1 != worker))
    {:ok, []} = SalixAgent.Runtime.list_sessions(reviewer, include_hidden: true)

    {:ok, baseline_messages} =
      Conversations.list_group_conversation_messages(group, original_id, limit: 100)

    assert length(baseline_messages) < 100, "baseline capture must not be truncated"
    baseline = Observer.worker_result_at_card_write(baseline_messages, worker)
    assert baseline

    {:ok, router_session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(router, group)

    {:ok, router_before} = InternalSessionStore.read(router, router_session_id)

    instruction = """
    Local experiment operational followup, not an original historical source message.
    Perform exactly one independent evidence review and one feedback/revision cycle
    for the existing Task #{original_id}, whose original Worker is #{worker}.
    Create one separate internal review Task assigned to the unused ordinary Worker
    #{reviewer}. Give it the original request and source coordinates from this Task.
    Ask it to inspect original material independently using its normal read tools,
    compare that evidence with the full existing answer (it may read the original
    Task), and return a complete review identifying supported claims, unsupported
    claims, missing evidence and any needed corrections. Do not supply expected
    factual conclusions. This is an internal review report, not a replacement
    user-facing answer. The reviewer is not a participant in the original Task.
    Wait for the reviewer's completed report; then relay the complete report to
    #{worker} in the original Task #{original_id}. Ask the original Worker to check
    the feedback against evidence and return its complete revised user-facing answer
    there, retaining supported content and honestly recording unresolved evidence.
    The revised answer should directly continue the original user's conversation;
    apply the corrections without copying the review checklist or audit format.
    Keep the same original Task and Worker. Do not run another review cycle or
    create replacement Tasks. The review Task is internal: do not publish its card
    or separate status replies. After the original Worker returns its complete
    answer and ready_for_review, refresh the original Task's native card in the
    existing source channel/thread. Preserve the complete authored answer.
    """

    Agent.update(state, fn current ->
      Map.merge(current, %{
        phase: :peer_review,
        provider_call_limit: current.provider_calls + 30,
        deadline: System.monotonic_time(:millisecond) + 300_000,
        peer_review: %{
          original_task_id: original_id,
          original_worker_id: worker,
          reviewer_id: reviewer,
          router_session_id: router_session_id,
          baseline_result_id: baseline["message_id"],
          baseline_messages: baseline_messages,
          baseline_provider_calls: current.provider_calls,
          baseline_slack_count: length(current.slack),
          baseline_router_message_count:
            length(SalixAgent.InternalSession.get(router_before, :messages)),
          operational_instruction: instruction,
          reviewer_selection: "test-driver-selected unused same-profile Worker",
          status: "running"
        }
      })
    end)

    assert {:ok, _} =
             SalixAgent.deliver(
               router,
               %{content: instruction, role: "user", session_id: router_session_id},
               source_message_id: "local-peer-review-#{case_data["id"]}-#{original_id}"
             )

    Live.eventually(
      fn ->
        assert length(tasks(group)) <= 2, "the trial permits only one additional review Task"

        revised_card =
          Agent.get(state, fn current ->
            Enum.find(current.slack, fn request ->
              task = request.task_at_write
              result = task && Observer.worker_result_at_card_write(task["messages"], worker)

              task && task["conversation_id"] == original_id && result &&
                result["message_id"] != baseline["message_id"]
            end)
          end)

        if revised_card, do: {:ok, revised_card}, else: :retry
      end,
      remaining_case_budget(state)
    )

    for agent <- [router, worker, reviewer],
        %{"session_id" => session_id} <-
          elem(SalixAgent.Runtime.list_sessions(agent, include_hidden: true), 1) do
      assert :ok =
               SalixAgent.TestSupport.await_session_quiet(
                 agent,
                 session_id,
                 remaining_case_budget(state)
               )
    end

    all_tasks = tasks(group)
    assert length(all_tasks) == 2
    reviewed_original = Enum.find(all_tasks, &(&1["conversation_id"] == original_id))
    review = Enum.find(all_tasks, &(&1["conversation_id"] != original_id))
    assert reviewed_original["task_worker_agent_id"] == worker
    assert review["task_worker_agent_id"] == reviewer
    assert review["created_by_agent_id"] == router
    assert review["status"] == "ready_for_review"
    assert reviewed_original["status"] == "ready_for_review"

    {:ok, review_messages} =
      Conversations.list_group_conversation_messages(
        group,
        review["conversation_id"],
        limit: 100
      )

    {:ok, original_messages} =
      Conversations.list_group_conversation_messages(
        group,
        original_id,
        limit: 100
      )

    assert length(review_messages) < 100 and length(original_messages) < 100,
           "trial Task capture must not be truncated"

    report = Observer.worker_result_at_card_write(review_messages, reviewer)
    revised = Observer.worker_result_at_card_write(original_messages, worker)
    assert report && revised
    refute revised["message_id"] == baseline["message_id"]
    {:ok, router_after} = InternalSessionStore.read(router, router_session_id)

    assert BridgeForTeams.TriagePeerReviewObservation.ordered_revision?(
             SalixAgent.InternalSession.get(router_after, :messages),
             review["conversation_id"],
             report["message_id"],
             original_id,
             revised["message_id"],
             length(SalixAgent.InternalSession.get(router_before, :messages))
           )

    current = Agent.get(state, & &1)
    assert current.provider_calls <= current.provider_call_limit

    assert remaining_case_budget(state) > 0,
           "review/revision phase exceeded its 300-second budget"

    for contract <- current.request_contracts, contract.role == :worker do
      assert contract.identity[:agent_id] in worker_ids

      assert is_binary(contract.identity[:session_id]),
             "missing identity, including any unattributed compaction, invalidates trial observation"
    end

    for request <- current.slack do
      assert request.method in ["chat.postMessage", "chat.update"]
      refute request.task_at_write["capture_may_be_truncated"]

      assert request.task_at_write["conversation_id"] == original_id,
             "review Task and status replies must not replace or add public surfaces"

      assert request.params["channel"] == authority["approved_channel_id"]

      if request.method == "chat.postMessage",
        do: assert(request.params["thread_ts"] == case_data["root_ts"])

      result = Observer.worker_result_at_card_write(request.task_at_write["messages"], worker)
      assert result
      Observer.assert_native_worker_output!(request.params, result)
    end

    {:ok, [%{"session_id" => reviewer_session_id}]} =
      SalixAgent.Runtime.list_sessions(reviewer, include_hidden: true)

    reviewer_inputs =
      Enum.filter(current.request_contracts, fn contract ->
        contract.identity[:agent_id] == reviewer and
          contract.identity[:session_id] == reviewer_session_id
      end)

    assert reviewer_inputs != [], "reviewer must have actual attributed assembled model inputs"
    assert Enum.all?(reviewer_inputs, &(&1.role == :worker and &1.phase == :peer_review))

    Agent.update(state, fn current ->
      Map.update!(
        current,
        :peer_review,
        &Map.merge(&1, %{
          status: "coordination_observed_content_review_pending",
          review_task_id: review["conversation_id"],
          reviewer_session_id: reviewer_session_id,
          review_report: report,
          revised_result: revised,
          added_provider_calls: current.provider_calls - &1.baseline_provider_calls
        })
      )
    end)
  end

  defp assert_original_file_returned!(authority, state, file_id) do
    expected = Agent.get(state, & &1.context.files[file_id].body)
    assert is_binary(expected) and byte_size(expected) > 0
    [task] = tasks(authority["group_id"])
    worker = task["task_worker_agent_id"]

    {:ok, messages} =
      Conversations.list_group_conversation_messages(
        authority["group_id"],
        task["conversation_id"],
        limit: 100
      )

    returned =
      messages
      |> Observer.worker_attachments(worker)
      |> Enum.flat_map(fn {_message, blocks} -> blocks end)

    assert Enum.any?(returned, fn block ->
             SalixStore.Blob.get(worker, block["blob_ref"]) == {:ok, expected}
           end),
           "the Worker must attach the unchanged captured transcript, not only a path, link or rewritten summary"

    Agent.update(state, &Map.put(&1, :original_attachment_bytes, byte_size(expected)))

    Observer.assert_slack_file_delivered!(
      Agent.get(state, & &1.slack),
      expected,
      authority["approved_channel_id"],
      Agent.get(state, & &1.root_ts)
    )

    Agent.update(state, &Map.put(&1, :external_original_attachment_bytes, byte_size(expected)))
  end

  defp emit_outcome(case_data, state, profiles, elapsed) do
    current = Agent.get(state, & &1)
    group = current.authority["group_id"]

    canonical =
      for task <- tasks(group) do
        {:ok, messages} =
          Conversations.list_group_conversation_messages(group, task["conversation_id"],
            limit: 100
          )

        %{task: task, messages: messages}
      end

    sessions =
      for agent_id <- [current.authority["inbound_agent_id"] | current.worker_ids],
          %{"session_id" => session_id} <-
            elem(SalixAgent.Runtime.list_sessions(agent_id, include_hidden: true), 1) do
        {:ok, session} = InternalSessionStore.read(agent_id, session_id)

        %{
          agent_id: agent_id,
          session_id: session_id,
          messages: SalixAgent.InternalSession.get(session, :messages)
        }
      end

    IO.puts(
      Jason.encode!(%{
        "triage_collaboration_outcome" => %{
          case_id: case_data["id"],
          expected_route: case_data["expected"]["route"],
          phase: Map.get(current, :phase),
          peer_review: Map.get(current, :peer_review),
          sample_kind: case_data["sample_kind"] || "captured_historical_request",
          source_authority_arm: Map.get(current, :source_authority_arm),
          source_authority_commands: Map.get(current, :source_authority_commands),
          source_case_id: case_data["source_case_id"],
          capture_boundary: case_data["capture_boundary"],
          original_attachment_bytes: Map.get(current, :original_attachment_bytes),
          router_upload_receipts: Map.get(current, :router_upload_receipts),
          direct_source_checks: Map.get(current, :direct_source_checks),
          external_original_attachment_bytes:
            Map.get(current, :external_original_attachment_bytes),
          title: case_data["title"],
          group: case_data["group"],
          entrypoint: Corpus.entrypoint(case_data),
          expected: case_data["expected"],
          cutoff_ts: case_data["cutoff_ts"],
          source_messages: current.context.source_messages,
          run: Map.get(current, :run),
          canonical_tasks: canonical,
          sessions: sessions,
          slack: current.slack,
          slack_reads: current.slack_reads,
          context_reads: current.context_reads,
          provider_responses: current.provider_responses,
          request_contracts: current.request_contracts,
          source_image_requests: Enum.reverse(current.source_image_requests),
          transport_events: Enum.reverse(current.transport_events),
          profiles: %{
            router: RoleProfiles.safe_metadata(profiles.router),
            worker: RoleProfiles.safe_metadata(profiles.worker)
          },
          elapsed_ms: elapsed,
          outcome: current.outcome,
          public_web_source:
            if(System.get_env("COMMA_TRIAGE_LIVE_WEB_API_KEY"),
              do: "current real read-only Exa search/contents; not historical replay",
              else: "frozen finite web capture; uncaptured results are unavailable"
            ),
          scope:
            if(Map.get(current, :peer_review_trial),
              do:
                "test-driver operational followup over local production chain; independent source acquisition, factual quality and complete feedback review pending; zero online writes",
              else:
                "local production chain with captured source transports; semantic and human/dashboard review pending; zero online writes"
            )
        }
      })
    )
  end

  defp tasks(group) do
    {:ok, %{"data" => conversations}} = Conversations.list_group_conversations(group, limit: 10)
    Enum.filter(conversations, &(&1["kind"] == "agent_task"))
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
