# Manual E2E for docs/agent-runtime.md.
#
# Required:
#   SALIX_CONNECT_BIN=/tmp/salix-connect-comma31
#   SALIX_S3_BUCKET=<fresh minio bucket>
# Optional for real local providers:
#   COMMA31_RUNTIME_AUTH_HOME=$HOME
#   MIX_ENV=dev mix run scripts/comma31_external_runtime_manual_e2e.exs

defmodule Comma31ExternalRuntimeManualE2E do
  alias Salix.Control.{Groups, Tenants}
  alias SalixAgent.ExternalAgentRuntime

  @timeout_ms 180_000

  def start_recovery! do
    # Unit-test configuration disables these production owners. This transport
    # rehearsal needs their real lease, LISTEN, and catch-up behavior.
    for child <- [SalixCluster.Recovery, SalixCluster.SessionWorkNotificationListener] do
      if is_nil(Process.whereis(child)) do
        {:ok, _} = Supervisor.start_child(SalixCluster.Supervisor, child)
      end
    end
  end

  def run do
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)
    Process.put(:comma31_capability_mismatches, [])

    bin = System.fetch_env!("SALIX_CONNECT_BIN")
    provider = System.get_env("COMMA31_RUNTIME_PROVIDER", "codex")
    assert!(provider in ~w(codex pi kimi claude), "supported runtime provider")
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "comma31-runtime-#{suffix}")
    File.mkdir_p!(root)

    try do
      tenant_id = create_tenant!()
      tenant_key = tenant_api_key!(tenant_id)

      {:ok, group} = Groups.create(%{"name" => "COMMA31 Manual"}, tenant_id)
      group_id = group["group_id"]

      {:ok, agent} =
        SalixAgent.Control.create(
          %{
            "group_id" => group_id,
            "name" => "COMMA31 #{provider} worker",
            "role" => "worker",
            "system_prompt" => worker_prompt()
          },
          tenant_id
        )

      agent_id = agent["agent_id"]
      alias_name = "comma31-#{provider}"
      token = connector_token!(tenant_id, group_id, alias_name)
      first_connector = start_connector!(bin, token, root, alias_name, provider)

      {conversation_id, session_id, capability_hash, first_connector_run_id} =
        try do
          env = wait_for_connected!(group_id, alias_name)
          verify_configured_runtime!(tenant_id, group_id, alias_name, provider)
          runtime = wait_for_runtime!(group_id, alias_name, provider)
          device_id = runtime_value!(runtime, "device_id")
          runtime_id = runtime_value!(runtime, "runtime_id")
          device_runtime_id = runtime_value!(runtime, "device_runtime_id")

          if observability?() do
            exercise_runtime_observability!(
              tenant_key,
              group_id,
              env,
              runtime,
              root
            )
          end

          runtime_config =
            %{
              "kind" => "external",
              "provider" => provider,
              "device_id" => device_id,
              "runtime_id" => runtime_id,
              "device_runtime_id" => device_runtime_id
            }
            |> then(fn config ->
              if provider == "kimi",
                do: Map.put(config, "reasoning_effort", "high"),
                else: config
            end)

          {:ok, _agent} =
            SalixAgent.Control.configure(agent_id, %{"runtime_config" => runtime_config})

          conversation =
            create_conversation!(tenant_key, group_id, agent_id, "comma31-primary-#{suffix}")

          conversation_id = nonblank!(conversation["conversation_id"], "conversation_id")

          assert!(
            SalixStore.Ids.valid_conversation_id?(conversation_id),
            "owner assigned canonical conversation_id"
          )

          session_id = agent_session_id!(tenant_key, group_id, conversation_id, agent_id)

          runtime_probe_replay_handler =
            if observability?() and
                 System.get_env("COMMA31_RUNTIME_OBSERVABILITY_REVIEW_CASE") not in [
                   "legacy",
                   "malformed"
                 ],
               do: attach_runtime_probe_replay_observer!()

          IO.puts(
            "COMMA31 manual E2E: group=#{group_id} agent=#{agent_id} connector_run=#{env["connector_run_id"]} device_runtime=#{device_runtime_id}"
          )

          send_user_message!(
            tenant_key,
            group_id,
            conversation_id,
            "single-1",
            "COMMA31_SINGLE: send one visible internal reply containing COMMA31_REPLY_SINGLE."
          )

          wait_for_session_status!(agent_id, session_id, "starting")

          first_runtime = wait_connector_accepted!(agent_id, session_id)
          assert_session_active_after_acceptance!(agent_id, session_id)

          if observability?() do
            assert_runtime_sessions!(tenant_key, group_id, env, runtime, session_id)

            if runtime_probe_replay_handler,
              do: assert_no_runtime_probe_replay!(runtime_probe_replay_handler)

            File.write!(System.fetch_env!("SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_GATE"), "run\n")
          end

          wait_for_session_status!(agent_id, session_id, "running")

          if observability?() do
            assert_runtime_sessions!(tenant_key, group_id, env, runtime, session_id)
          end

          wait_for_visible_reply!(tenant_key, group_id, conversation_id, "COMMA31_REPLY_SINGLE")

          if System.get_env("COMMA31_OVERSIZED_RUNTIME_EVENT_E2E") == "1" do
            wait_for_event_content!(agent_id, session_id, "oversized-result", 15_000)
          end

          wait_for_session_status!(agent_id, session_id, "idle")

          if observability?() do
            assert_runtime_sessions!(tenant_key, group_id, env, runtime, session_id)
          end

          assert_session_workspace!(root, session_id)

          capability_hash =
            first_runtime["runtime_capability_token_hash"]
            |> nonblank!("runtime capability after first input")

          isolated_conversation =
            create_conversation!(
              tenant_key,
              group_id,
              agent_id,
              "comma31-isolated-#{suffix}"
            )

          isolated_conversation_id =
            nonblank!(isolated_conversation["conversation_id"], "isolated conversation_id")

          assert!(
            SalixStore.Ids.valid_conversation_id?(isolated_conversation_id),
            "owner assigned canonical isolated conversation_id"
          )

          isolated_session_id =
            agent_session_id!(
              tenant_key,
              group_id,
              isolated_conversation_id,
              agent_id
            )

          send_user_message!(
            tenant_key,
            group_id,
            isolated_conversation_id,
            "isolated-1",
            "COMMA31_ISOLATED: reply visibly with COMMA31_REPLY_ISOLATED."
          )

          wait_for_visible_reply!(
            tenant_key,
            group_id,
            isolated_conversation_id,
            "COMMA31_REPLY_ISOLATED"
          )

          wait_connector_accepted!(agent_id, isolated_session_id)
          assert_session_workspace!(root, isolated_session_id)

          assert!(
            session_workspace(root, session_id) != session_workspace(root, isolated_session_id),
            "different Salix sessions use different workspaces"
          )

          wait_for_event_content!(agent_id, isolated_session_id, "COMMA31_REPLY_ISOLATED")
          refute_event_content!(agent_id, session_id, "COMMA31_REPLY_ISOLATED")

          send_user_message!(
            tenant_key,
            group_id,
            conversation_id,
            "seq-1",
            "COMMA31_SEQ_1: reply visibly with COMMA31_REPLY_SEQ_1."
          )

          wait_for_visible_reply!(tenant_key, group_id, conversation_id, "COMMA31_REPLY_SEQ_1")
          wait_for_session_status!(agent_id, session_id, "idle")
          assert_same_capability!(agent_id, session_id, capability_hash)

          reconnect_trigger = System.get_env("SALIX_TEST_RUNTIME_RECONNECT_TRIGGER")

          if reconnect_trigger do
            File.rm(reconnect_trigger)
            File.rm(reconnect_trigger <> ".waiting")

            send_user_message!(
              tenant_key,
              group_id,
              conversation_id,
              "reconnect-tool",
              "COMMA31_RECONNECT_TOOL: reply visibly with COMMA31_REPLY_RECONNECT."
            )

            wait_for_file!(reconnect_trigger <> ".waiting")
            wait_for_session_status!(agent_id, session_id, "running")
          end

          :ok = SalixEnv.Bridge.stop_local_owner(env["transport_id"])

          reconnected_env =
            wait_for_reconnected!(group_id, alias_name, env["connector_run_id"])

          IO.puts(
            "COMMA31 transport reconnected: before=#{env["connector_run_id"]} after=#{reconnected_env["connector_run_id"]}"
          )

          if observability?() do
            reconnected_runtime = wait_for_runtime!(group_id, alias_name, provider)

            assert_runtime_sessions!(
              tenant_key,
              group_id,
              reconnected_env,
              reconnected_runtime,
              session_id
            )
          end

          if reconnect_trigger do
            wait_for_session_status!(agent_id, session_id, "running")
            File.write!(reconnect_trigger, "continue\n")

            wait_for_visible_reply!(
              tenant_key,
              group_id,
              conversation_id,
              "COMMA31_REPLY_RECONNECT"
            )

            wait_for_session_status!(agent_id, session_id, "idle")

            assert_same_capability!(agent_id, session_id, capability_hash)
          end

          send_user_message!(
            tenant_key,
            group_id,
            conversation_id,
            "seq-2",
            "COMMA31_SEQ_2: reply visibly with COMMA31_REPLY_SEQ_2 and remember COMMA31_SEQ_1 happened."
          )

          wait_for_visible_reply!(tenant_key, group_id, conversation_id, "COMMA31_REPLY_SEQ_2")

          assert_same_capability!(agent_id, session_id, capability_hash)

          {conversation_id, session_id, capability_hash, reconnected_env["connector_run_id"]}
        after
          stop_connector(first_connector)
        end

      offline_conversation =
        create_conversation!(
          tenant_key,
          group_id,
          agent_id,
          "comma31-offline-catchup-#{suffix}"
        )

      offline_conversation_id =
        nonblank!(offline_conversation["conversation_id"], "offline catch-up conversation_id")

      offline_session_id =
        agent_session_id!(
          tenant_key,
          group_id,
          offline_conversation_id,
          agent_id
        )

      send_user_message!(
        tenant_key,
        group_id,
        offline_conversation_id,
        "offline-catchup",
        "COMMA31_OFFLINE_CATCHUP: reply visibly with COMMA31_REPLY_OFFLINE_CATCHUP."
      )

      wait_for_server_queued_input!(agent_id, offline_session_id)

      second_connector = start_connector!(bin, token, root, alias_name, provider)

      try do
        second_env =
          wait_for_reconnected!(group_id, alias_name, first_connector_run_id)

        # Accepted verification survives a Server transport reconnect within
        # one Connector process. A new Connector process intentionally owns a
        # fresh proof generation, so the harness performs another explicit
        # verification before expecting dispatch readiness.
        verify_configured_runtime!(tenant_id, group_id, alias_name, provider)
        second_runtime = wait_for_runtime!(group_id, alias_name, provider)

        IO.puts(
          "COMMA31 connector restarted: before=#{first_connector_run_id} after=#{second_env["connector_run_id"]}"
        )

        wait_for_visible_reply!(
          tenant_key,
          group_id,
          offline_conversation_id,
          "COMMA31_REPLY_OFFLINE_CATCHUP",
          20_000
        )

        wait_connector_accepted!(agent_id, offline_session_id)
        assert_session_workspace!(root, offline_session_id)

        if observability?() do
          assert_runtime_sessions!(
            tenant_key,
            group_id,
            second_env,
            second_runtime,
            session_id
          )
        end

        send_user_message!(
          tenant_key,
          group_id,
          conversation_id,
          "concurrent-a",
          "COMMA31_CONCURRENT_A: wait about 8 seconds, then reply visibly with COMMA31_REPLY_CONCURRENT_A."
        )

        Process.sleep(1_000)

        send_user_message!(
          tenant_key,
          group_id,
          conversation_id,
          "concurrent-b",
          "COMMA31_CONCURRENT_B: reply visibly with COMMA31_REPLY_CONCURRENT_B."
        )

        wait_for_session_work_state!(agent_id, session_id, "running")
        wait_for_visible_reply!(tenant_key, group_id, conversation_id, "COMMA31_REPLY_CONCURRENT_A")
        wait_for_visible_reply!(tenant_key, group_id, conversation_id, "COMMA31_REPLY_CONCURRENT_B")

        assert_same_capability!(agent_id, session_id, capability_hash)

        session = wait_for_session_events!(agent_id, session_id)

        event_types =
          session["events"]
          |> Enum.map(&get_in(&1, ["data", "event", "type"]))

        assert!("message" in event_types, "standard message event recorded")
        assert!("status" in event_types, "standard status event recorded")

        operations =
          session["events"]
          |> Enum.map(&get_in(&1, ["data", "event"]))
          |> Enum.filter(&(&1["type"] == "operation"))

        assert!(operations != [], "standard operation event recorded")

        assert!(
          Enum.all?(operations, &(&1["operation_id"] not in [nil, ""])),
          "operation ids recorded"
        )

        assert!(
          Enum.all?(operations, &(&1["status"] not in [nil, ""])),
          "operation statuses recorded"
        )

        assert!(Enum.any?(operations, &Map.has_key?(&1, "input")), "operation input recorded")
        assert!(Enum.any?(operations, &Map.has_key?(&1, "output")), "operation output recorded")

        assert!(
          Enum.all?(session["events"], fn record ->
            not Map.has_key?(get_in(record, ["data", "event"]) || %{}, "native")
          end),
          "native provider envelopes are not persisted"
        )

        messages = list_messages!(tenant_key, group_id, conversation_id)

        assert!(
          Enum.all?(agent_messages(messages), &(&1["actor_type"] == "agent")),
          "conversation visible agent messages are only tool side effects"
        )

        assert!(
          Process.get(:comma31_capability_mismatches, []) == [],
          "same external session binding keeps one runtime capability"
        )

        if observability?() do
          assert_runtime_sessions!(tenant_key, group_id, second_env, second_runtime, session_id)
          stop_connector(second_connector)

          wait_for_environment_status!(
            tenant_id,
            group_id,
            second_env["device_id"],
            "disconnected"
          )

          assert_runtime_sessions_now!(
            tenant_key,
            group_id,
            second_env,
            second_runtime,
            session_id,
            "last_observed"
          )

          review_case = System.get_env("COMMA31_RUNTIME_OBSERVABILITY_REVIEW_CASE")

          if review_case != "malformed" do
            exercise_legacy_connector_snapshot!(
              tenant_key,
              tenant_id,
              group_id,
              second_env,
              second_runtime,
              token,
              alias_name,
              root
            )
          end

          if review_case != "legacy" do
            exercise_invalid_runtime_metadata!(
              tenant_key,
              tenant_id,
              group_id,
              second_env,
              second_runtime,
              token,
              alias_name,
              root,
              session_id
            )
          end

          third_connector = start_connector!(bin, token, root, alias_name, provider)

          try do
            third_env =
              wait_for_reconnected!(group_id, alias_name, second_env["connector_run_id"])

            third_runtime = wait_for_runtime!(group_id, alias_name, provider)

            assert_runtime_sessions!(
              tenant_key,
              group_id,
              third_env,
              third_runtime,
              session_id
            )

            normal_exit_gate = System.fetch_env!("SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_GATE")
            File.write!(normal_exit_gate, "exit\n")

            send_user_message!(
              tenant_key,
              group_id,
              conversation_id,
              "normal-exit",
              "COMMA31_NORMAL_EXIT: reply visibly with COMMA31_REPLY_NORMAL_EXIT."
            )

            wait_for_visible_reply!(
              tenant_key,
              group_id,
              conversation_id,
              "COMMA31_REPLY_NORMAL_EXIT"
            )

            assert_runtime_session_absent!(
              tenant_key,
              group_id,
              third_env,
              third_runtime,
              session_id
            )
          after
            stop_connector(third_connector)
          end
        end

        if provider == "codex" and
             System.get_env("COMMA31_FLEETSUP_COLD_START_E2E") == "1" do
          exercise_fleetsup_cold_start_recovery!(%{
            bin: bin,
            connector: second_connector,
            previous_connector_run_id: second_env["connector_run_id"],
            token: token,
            root: root,
            alias_name: alias_name,
            provider: provider,
            tenant_key: tenant_key,
            tenant_id: tenant_id,
            group_id: group_id,
            agent_id: agent_id,
            suffix: suffix
          })
        end

        if observability?(), do: IO.puts("CONNECTOR_RUNTIME_OBSERVABILITY_E2E: PASS")
        IO.puts("COMMA31_EXTERNAL_RUNTIME_E2E: PASS provider=#{provider}")
        IO.puts("COMMA31_MANUAL_E2E: PASS")
      after
        stop_connector(second_connector)
      end
    after
      File.rm_rf(root)
    end
  rescue
    e ->
      IO.puts("COMMA31_MANUAL_E2E: FAIL #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
      System.halt(1)
  end

  # With a checkpoint path, the harness starts a second BEAM process against
  # the same stores. Otherwise this case restarts only the node-local owners.
  defp exercise_fleetsup_cold_start_recovery!(ctx) do
    device_id = connected_env(ctx.group_id, ctx.alias_name) |> Map.fetch!("device_id")
    stop_connector(ctx.connector)

    wait_for_environment_status!(
      ctx.tenant_id,
      ctx.group_id,
      device_id,
      "disconnected"
    )

    conversation =
      create_conversation!(
        ctx.tenant_key,
        ctx.group_id,
        ctx.agent_id,
        "comma31-fleetsup-cold-start-#{ctx.suffix}"
      )

    conversation_id = nonblank!(conversation["conversation_id"], "cold-start conversation_id")

    session_id =
      agent_session_id!(
        ctx.tenant_key,
        ctx.group_id,
        conversation_id,
        ctx.agent_id
      )

    send_user_message!(
      ctx.tenant_key,
      ctx.group_id,
      conversation_id,
      "fleetsup-cold-start",
      "COMMA31_FLEETSUP_COLD_START: reply visibly with COMMA31_REPLY_FLEETSUP_COLD_START."
    )

    wait_for_server_queued_input!(ctx.agent_id, session_id)

    {:ok, session_actor} =
      SalixAgent.ExternalSessionFleet.ensure_started(
        ctx.agent_id,
        session_id,
        process_on_init: false
      )

    tool_call_id = "fleetsup-process-local-#{ctx.suffix}"

    {:ok, seeded} =
      SalixAgent.ExternalSessionActor.commit_session_events(session_actor, [
        %{
          "type" => "async_tool_call_started",
          "session_id" => session_id,
          "tool_call_id" => tool_call_id,
          "tool_name" => "mcp.linear.get_diff",
          "completion_mode" => "process_local",
          "started_at" => System.system_time(:millisecond)
        }
      ])

    reasons = SalixAgent.ExternalSessionStore.work_reasons(seeded)

    assert!(
      "runtime_wait" in reasons and
        "process_local_background_tool_run" in reasons and
        seeded["input_message_queue"] != [],
      "cold-start fixture retains queued input and process-local async work"
    )

    :ok = SalixAgent.Fleet.stop_existing(ctx.agent_id, reason: :normal, timeout: 5_000)

    wait_until!("node-local agent/session owners stopped", 5_000, fn ->
      if Registry.lookup(SalixAgent.Registry, ctx.agent_id) == [] and
           Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(ctx.agent_id)) == [] and
           Registry.lookup(
             SalixAgent.Registry,
             SalixAgent.ExternalSessionActor.key(ctx.agent_id, session_id)
           ) == [] do
        true
      end
    end)

    checkpoint = System.get_env("COMMA31_SERVER_RESTART_FILE")

    resume =
      Map.merge(Map.delete(ctx, :connector), %{
        session_id: session_id,
        conversation_id: conversation_id,
        tool_call_id: tool_call_id,
        prior_os_pid: System.pid()
      })

    if is_binary(checkpoint) and checkpoint != "" do
      File.write!(checkpoint, :erlang.term_to_binary(resume))
      File.chmod!(checkpoint, 0o600)
      IO.puts("COMMA31_SERVER_RESTART: CHECKPOINT")
      System.halt(0)
    end

    resume_cold_start!(resume)
  end

  def resume_server!(checkpoint) do
    ctx = checkpoint |> File.read!() |> :erlang.binary_to_term([:safe])
    assert!(ctx.prior_os_pid != System.pid(), "server resumed in a different OS process")

    try do
      resume_cold_start!(ctx)
      IO.puts("COMMA31_SERVER_RESTART_E2E: PASS")
      IO.puts("COMMA31_EXTERNAL_RUNTIME_E2E: PASS provider=#{ctx.provider}")
    after
      File.rm(checkpoint)
      File.rm_rf(ctx.root)
    end
  end

  defp resume_cold_start!(ctx) do
    session_id = ctx.session_id
    conversation_id = ctx.conversation_id
    tool_call_id = ctx.tool_call_id
    {:ok, pending} = SalixAgent.ExternalSessionStore.get_session_record(ctx.agent_id, session_id)
    assert!(pending["input_message_queue"] != [], "restart retained accepted input")

    connector =
      start_connector!(ctx.bin, ctx.token, ctx.root, ctx.alias_name, ctx.provider)

    try do
      _env =
        wait_for_reconnected!(
          ctx.group_id,
          ctx.alias_name,
          ctx.previous_connector_run_id
        )

      wait_until!("cold-start external Session actor", 10_000, fn ->
        case Registry.lookup(
               SalixAgent.Registry,
               SalixAgent.ExternalSessionActor.key(ctx.agent_id, session_id)
             ) do
          [{pid, _}] -> pid
          [] -> nil
        end
      end)

      assert_fleet_supervisor_responsive!()

      wait_for_visible_reply!(
        ctx.tenant_key,
        ctx.group_id,
        conversation_id,
        "COMMA31_REPLY_FLEETSUP_COLD_START",
        20_000
      )

      wait_connector_accepted!(ctx.agent_id, session_id)

      {:ok, repaired} =
        SalixAgent.ExternalSessionStore.get_session_record(ctx.agent_id, session_id)

      assert!(
        get_in(repaired, ["async_tool_calls", tool_call_id, "status"]) == "failed",
        "cold-start recovery makes the lost process-local tool terminal"
      )

      SalixAgent.SessionWorkRecovery.sweep()
      SalixAgent.SessionWorkRecovery.sweep()
      Process.sleep(500)

      replies =
        list_messages!(ctx.tenant_key, ctx.group_id, conversation_id)
        |> agent_messages()
        |> Enum.filter(&(message_text(&1) =~ "COMMA31_REPLY_FLEETSUP_COLD_START"))

      assert!(length(replies) == 1, "repeated recovery produced exactly one visible reply")
      assert!(is_nil(repaired["runtime_wait"]), "successful dispatch cleared runtime wait")
      IO.puts("COMMA31_FLEETSUP_COLD_START_E2E: PASS")
    after
      stop_connector(connector)
    end
  end

  defp assert_fleet_supervisor_responsive! do
    task = Task.async(fn -> DynamicSupervisor.count_children(SalixAgent.FleetSup) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, %{active: active}} when is_integer(active) ->
        :ok

      nil ->
        raise("FleetSup stopped responding while an external Session actor cold-started")

      other ->
        raise("FleetSup health probe failed: #{inspect(other)}")
    end
  end

  defp exercise_runtime_observability!(tenant_key, group_id, env, runtime, root) do
    device_id = runtime_value!(runtime, "device_id")
    device_runtime_id = runtime_value!(runtime, "device_runtime_id")
    path = runtime_path(group_id, device_id, device_runtime_id)

    initial_sessions = req!(tenant_key, :get, path <> "/sessions", nil)
    assert!(initial_sessions.status == 200, "runtime sessions endpoint is available")
    assert_runtime_session_response!(initial_sessions.body)
    assert!(initial_sessions.body["session_ids"] == [], "runtime session snapshot starts empty")
    assert!(req!(tenant_key, :get, path <> "/work", nil).status == 404, "legacy /work is absent")

    public_env =
      req!(tenant_key, :get, "/v1/runtime/groups/#{group_id}/environments/#{device_id}", nil)

    assert!(public_env.status == 200, "read public environment")
    health = public_env.body["connector_health"]

    expected_health_fields =
      ~w(
        schema_version observed_at process_started_at request_inflight request_capacity
        runtime_proxy_inflight runtime_proxy_capacity managed_processes
        resumable_runtime_sessions recoverable_runtime_sessions pending_input_batches
        pending_runtime_events
      )

    assert!(
      is_map(health) and Enum.sort(Map.keys(health)) == Enum.sort(expected_health_fields),
      "bounded connector health snapshot"
    )

    assert!(
      Enum.all?(health, fn {_key, value} -> is_integer(value) end),
      "numeric connector health"
    )

    public_runtime =
      Enum.find(
        public_env.body["device_runtimes"],
        &(&1["device_runtime_id"] == device_runtime_id)
      )

    assert!(not Map.has_key?(public_runtime, "command"), "public runtime hides command")

    assert!(
      not Map.has_key?(public_runtime, "identity_material"),
      "public runtime hides identity"
    )

    assert!(
      not Map.has_key?(public_runtime, "last_error"),
      "public runtime hides diagnostic error"
    )

    handler = "connector-runtime-observability-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :runtime_probe, :stop],
        fn _event, _measurements, metadata, owner ->
          if metadata.trigger == "operator", do: send(owner, {:runtime_probe_observed, metadata})
        end,
        parent
      )

    try do
      gate = System.fetch_env!("SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE")
      log = System.fetch_env!("SALIX_TEST_FAKE_CODEX_LOG")
      starts = fake_codex_starts(log)
      account_reads = fake_codex_calls(log, "account/read")
      File.rm!(gate)

      tasks =
        for body <- [%{}, %{"command" => "/tmp/evil", "identity_material" => "/tmp/evil"}] do
          Task.async(fn ->
            response = req!(tenant_key, :post, path <> "/probe", body)
            send(parent, {:runtime_probe_response, response})
            response
          end)
        end

      wait_until!(
        "single runtime account/read",
        30_000,
        fn ->
          if fake_codex_calls(log, "account/read") == account_reads + 1, do: true
        end,
        10
      )

      Process.sleep(100)

      assert!(
        fake_codex_starts(log) == starts,
        "same-target probes reuse the long-lived app-server"
      )

      assert!(
        fake_codex_calls(log, "account/read") == account_reads + 1,
        "same-target probes singleflight one account/read"
      )

      assert!(
        match?(
          {:ok, %{"kind" => "dir"}},
          SalixEnv.Connector.Live.request(env["connector_run_id"], "stat", %{"path" => "."})
        ),
        "normal connector request progresses during runtime probe"
      )

      Process.sleep(750)

      assert!(
        match?(%{}, connected_env(group_id, env_alias(env))),
        "heartbeats remain live during runtime probe"
      )

      File.write!(gate, "ready\n")

      receive do
        {:runtime_probe_observed, %{provider: "codex"}} -> :ok
        {:runtime_probe_response, _response} -> raise("probe response arrived before metadata")
      after
        30_000 -> raise("operator probe metadata was not observed")
      end

      for task <- tasks do
        response = Task.await(task, 30_000)
        assert!(response.status == 200, "operator runtime probe succeeds")

        assert!(
          not Map.has_key?(response.body, "identity_material"),
          "probe response hides identity"
        )

        assert!(
          not Map.has_key?(response.body, "command"),
          "probe request cannot override target"
        )
      end

      assert!(fake_codex_starts(log) == starts, "singleflight starts no replacement app-server")

      assert!(
        fake_codex_calls(log, "account/read") == account_reads + 1,
        "singleflight runs one native account/read"
      )

      assert!(
        req!(tenant_key, :post, String.replace(path, device_runtime_id, "unknown"), %{}).status ==
          404,
        "unknown runtime is tenant-scoped"
      )

      other_tenant = create_tenant!()
      other_key = tenant_api_key!(other_tenant)

      assert!(
        req!(other_key, :post, path <> "/probe", %{}).status == 404,
        "cross-tenant runtime probe is hidden"
      )

      assert!(
        req!(other_key, :get, path <> "/sessions", nil).status == 404,
        "cross-tenant runtime sessions are hidden"
      )

      auth_marker = System.fetch_env!("SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS")
      File.write!(auth_marker, "fail\n")
      unavailable = req!(tenant_key, :post, path <> "/probe", %{})

      assert!(
        unavailable.status == 200 and unavailable.body["auth_ready"] == false and
          unavailable.body["ready"] == false,
        "dynamic auth loss is reported without reconnect"
      )

      unavailable_public =
        wait_for_public_runtime_status!(
          tenant_key,
          group_id,
          device_id,
          device_runtime_id,
          "unavailable"
        )

      assert!(unavailable_public["issue"] == "authentication_required", "canonical auth issue")

      File.rm!(auth_marker)
      recovered = req!(tenant_key, :post, path <> "/probe", %{})

      assert!(
        recovered.status == 200 and recovered.body["ready"] == true,
        "operator probe recovers runtime readiness"
      )

      workspace_root = Path.join([root, "home", ".comma", "workspaces"])
      File.rm_rf!(workspace_root)
      File.write!(workspace_root, "temporarily unavailable\n")

      workspace_unavailable = req!(tenant_key, :post, path <> "/probe", %{})

      assert!(
        workspace_unavailable.status == 200 and
          workspace_unavailable.body["readiness_issue"] == "workspace_unavailable" and
          workspace_unavailable.body["ready"] == false,
        "Connector reports workspace readiness loss without reconnect"
      )

      workspace_unavailable_public =
        wait_for_public_runtime_status!(
          tenant_key,
          group_id,
          device_id,
          device_runtime_id,
          "unavailable"
        )

      assert!(
        workspace_unavailable_public["issue"] == "workspace_unavailable",
        "canonical public runtime projection preserves workspace_unavailable: #{inspect(workspace_unavailable_public)}"
      )

      File.rm!(workspace_root)
      workspace_recovered = req!(tenant_key, :post, path <> "/probe", %{})

      assert!(
        workspace_recovered.status == 200 and workspace_recovered.body["ready"] == true,
        "operator probe recovers workspace readiness"
      )

      IO.puts("CONNECTOR_RUNTIME_WORKSPACE_ISSUE_E2E: PASS")
    after
      :telemetry.detach(handler)
    end
  end

  defp attach_runtime_probe_replay_observer! do
    handler = "connector-runtime-probe-replay-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :runtime_probe, :stop],
        fn _event, _measurements, metadata, target ->
          send(target, {:runtime_probe_replayed, metadata})
        end,
        owner
      )

    handler
  end

  defp assert_no_runtime_probe_replay!(handler) do
    receive do
      {:runtime_probe_replayed, metadata} ->
        raise("cached session metadata replayed runtime probe telemetry: #{inspect(metadata)}")
    after
      100 -> :ok
    end

    :telemetry.detach(handler)
  end

  defp assert_runtime_sessions!(tenant_key, group_id, env, runtime, session_id) do
    path = runtime_path(group_id, env["device_id"], runtime_value!(runtime, "device_runtime_id"))

    wait_until!(
      "Connector-held runtime session #{session_id}",
      @timeout_ms,
      fn ->
        response = req!(tenant_key, :get, path <> "/sessions", nil)

        if response.status == 200 and session_id in response.body["session_ids"] do
          assert_runtime_session_response!(response.body)
          response.body
        end
      end,
      25
    )
  end

  defp assert_runtime_session_absent!(tenant_key, group_id, env, runtime, session_id) do
    path = runtime_path(group_id, env["device_id"], runtime_value!(runtime, "device_runtime_id"))

    wait_until!(
      "Connector durable forget removes #{session_id}",
      @timeout_ms,
      fn ->
        response = req!(tenant_key, :get, path <> "/sessions", nil)

        if response.status == 200 and session_id not in response.body["session_ids"] do
          assert_runtime_session_response!(response.body)
          response.body
        end
      end,
      25
    )
  end

  defp assert_legacy_runtime_sessions_not_reported!(tenant_key, group_id, env, runtime) do
    path = runtime_path(group_id, env["device_id"], runtime_value!(runtime, "device_runtime_id"))
    response = req!(tenant_key, :get, path <> "/sessions", nil)

    assert!(
      response.status == 200 and response.body["observation_status"] == "not_reported" and
        response.body["session_ids"] == [],
      "legacy Connector must not promote an older session snapshot to current: #{inspect(response.body)}"
    )
  end

  defp exercise_legacy_connector_snapshot!(
         tenant_key,
         tenant_id,
         group_id,
         prior_env,
         runtime,
         token,
         alias_name,
         root
       ) do
    ready = Path.join(root, "legacy-connector-ready")

    connector =
      start_runtime_metadata_connector!(
        System.fetch_env!("SALIX_CONNECT_TEST_HELPER"),
        "legacy",
        token,
        alias_name,
        ready
      )

    try do
      env = wait_for_reconnected!(group_id, alias_name, prior_env["connector_run_id"])
      wait_for_file!(ready)
      device_id = env["device_id"]

      wait_until!("legacy connector metadata persisted", @timeout_ms, fn ->
        private_device_capability?(
          tenant_id,
          group_id,
          device_id,
          "legacy_runtime_observability_e2e"
        )
      end)

      assert_legacy_runtime_sessions_not_reported!(tenant_key, group_id, env, runtime)
    after
      stop_connector(connector)
    end

    wait_for_environment_status!(tenant_id, group_id, prior_env["device_id"], "disconnected")
  end

  defp exercise_invalid_runtime_metadata!(
         tenant_key,
         tenant_id,
         group_id,
         prior_env,
         runtime,
         token,
         alias_name,
         root,
         session_id
       ) do
    ready = Path.join(root, "invalid-metadata-ready")
    gate = Path.join(root, "invalid-metadata-gate")
    sent = Path.join(root, "invalid-metadata-sent")
    File.rm(gate)
    File.rm(sent)

    connector =
      start_runtime_metadata_connector!(
        System.fetch_env!("SALIX_CONNECT_TEST_HELPER"),
        "malformed",
        token,
        alias_name,
        ready,
        [
          {"IDENTITY", runtime_value!(runtime, "identity_material")},
          {"SESSION_IDS", session_id},
          {"GATE", gate},
          {"SENT", sent}
        ]
      )

    try do
      env = wait_for_reconnected!(group_id, alias_name, prior_env["connector_run_id"])
      wait_for_file!(ready)
      device_id = env["device_id"]

      wait_until!("valid runtime metadata persisted", @timeout_ms, fn ->
        with true <-
               private_device_capability?(
                 tenant_id,
                 group_id,
                 device_id,
                 "valid_runtime_metadata_e2e"
               ),
             %{status: 200, body: %{"session_ids" => [^session_id]}} <-
               req!(
                 tenant_key,
                 :get,
                 runtime_path(
                   group_id,
                   env["device_id"],
                   runtime_value!(runtime, "device_runtime_id")
                 ) <> "/sessions",
                 nil
               ) do
          true
        else
          _ -> nil
        end
      end)

      {:ok, before} = SalixEnv.Registry.get_device(tenant_id, group_id, env["device_id"])
      before_updated_at = before["updated_at"]
      File.write!(gate, "send\n")
      wait_for_file!(sent)

      wait_until!("post-malformed heartbeat persisted", @timeout_ms, fn ->
        case SalixEnv.Registry.get_device(tenant_id, group_id, env["device_id"]) do
          {:ok, %{"updated_at" => updated_at}} when updated_at > before_updated_at -> true
          _ -> nil
        end
      end)

      {:ok, current} = private_device_record(tenant_id, group_id, device_id)

      response =
        req!(
          tenant_key,
          :get,
          runtime_path(
            group_id,
            env["device_id"],
            runtime_value!(runtime, "device_runtime_id")
          ) <> "/sessions",
          nil
        )

      assert!(
        get_in(current, ["meta", "capabilities", "invalid_runtime_metadata_e2e"]) != true and
          response.status == 200 and response.body["session_ids"] == [session_id],
        "malformed runtime metadata must retain the prior atomic snapshot: #{inspect(%{env: current, sessions: response.body})}"
      )
    after
      stop_connector(connector)
    end

    wait_for_environment_status!(tenant_id, group_id, prior_env["device_id"], "disconnected")
  end

  defp assert_runtime_sessions_now!(tenant_key, group_id, env, runtime, session_id, observation) do
    path = runtime_path(group_id, env["device_id"], runtime_value!(runtime, "device_runtime_id"))
    response = req!(tenant_key, :get, path <> "/sessions", nil)
    assert_runtime_session_response!(response.body)

    assert!(
      response.status == 200 and session_id in response.body["session_ids"] and
        response.body["observation_status"] == observation,
      "runtime session after disconnect is #{observation}: #{inspect(response.body)}"
    )
  end

  defp assert_runtime_session_response!(body) do
    assert!(
      Enum.sort(Map.keys(body)) ==
        Enum.sort(
          ~w(connector_status device_id device_runtime_id observation_status observed_at session_count session_ids truncated)
        ),
      "runtime session API exposes only the bounded public contract"
    )

    forbidden =
      ~w(agent_id task_id conversation_id lifecycle status native_thread_id command identity_material workspace token payload dispatch_id execution_id)

    assert!(
      Enum.all?(forbidden, &(not contains_key?(body, &1))),
      "runtime session API redacts task, lifecycle, native, and recovery fields"
    )
  end

  defp contains_key?(value, key) when is_map(value) do
    Map.has_key?(value, key) or Enum.any?(Map.values(value), &contains_key?(&1, key))
  end

  defp contains_key?(value, key) when is_list(value),
    do: Enum.any?(value, &contains_key?(&1, key))

  defp contains_key?(_value, _key), do: false

  defp wait_for_environment_status!(tenant_id, group_id, device_id, status) do
    wait_until!("environment #{device_id} is #{status}", @timeout_ms, fn ->
      case SalixEnv.Control.get_environment(device_id, group_id, tenant_id) do
        {:ok, %{"status" => ^status} = env} -> env
        _ -> nil
      end
    end)
  end

  defp wait_for_public_runtime_status!(tenant_key, group_id, device_id, device_runtime_id, status) do
    wait_until!(
      "public runtime status #{status}",
      30_000,
      fn ->
        response =
          req!(tenant_key, :get, "/v1/runtime/groups/#{group_id}/environments/#{device_id}", nil)

        if response.status == 200 do
          Enum.find(
            response.body["device_runtimes"],
            &(&1["device_runtime_id"] == device_runtime_id and &1["status"] == status)
          )
        end
      end,
      25
    )
  end

  defp runtime_path(group_id, device_id, device_runtime_id),
    do: "/v1/runtime/groups/#{group_id}/environments/#{device_id}/runtimes/#{device_runtime_id}"

  defp fake_codex_starts(path) do
    fake_codex_calls(path, "start")
  end

  defp fake_codex_calls(path, method) do
    path |> File.read!() |> String.split("\n") |> Enum.count(&(&1 == method))
  end

  defp observability?, do: System.get_env("COMMA31_RUNTIME_OBSERVABILITY") == "1"

  defp worker_prompt do
    """
    You are an external coding worker running inside Salix.

    Incoming session context includes an "Inbound message source" context block for internal Comma conversation messages:
    provider: internal
    conversation_id: <id>
    message_id: <id>
    from_participant_id: <id>

    For every user message, send exactly one visible reply to that conversation by running:
      salix tool call im_api.internal.send_message --json '{"connect_id":"internal","conversation_id":"<conversation_id>","content":[{"type":"text","text":"<reply text>"}]}'

    Read the conversation_id from the latest source context block for the user message.
    Include the requested COMMA31_REPLY_* token exactly in the visible reply text.
    Ordinary assistant text is not a visible Comma conversation reply; use the salix CLI.
    """
  end

  defp assert_session_workspace!(root, session_id) do
    workspace = session_workspace(root, session_id)
    assert!(File.dir?(workspace), "connector allocated external session workspace")
    workspace
  end

  defp session_workspace(root, session_id),
    do: Path.join([root, "home", ".comma", "workspaces", session_id])

  defp create_tenant! do
    case Tenants.create(%{"name" => "COMMA31 Manual"}) do
      {:ok, %{"tenant_id" => tenant_id}} -> tenant_id
      other -> raise("tenant setup failed: #{inspect(other)}")
    end
  end

  defp tenant_api_key!(tenant_id) do
    case Tenants.create_api_key(tenant_id, %{"name" => "comma31-manual"}) do
      {:ok, %{"key" => key}} -> key
      other -> raise("tenant api key setup failed: #{inspect(other)}")
    end
  end

  defp connector_token!(tenant_id, group_id, alias_name) do
    case SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
           "name" => alias_name,
           "alias" => alias_name,
           "expires_in_seconds" => 3600
         }) do
      {:ok, %{"token" => token}} -> token
      other -> raise("connector token setup failed: #{inspect(other)}")
    end
  end

  defp start_connector!(bin, token, root, alias_name, provider) do
    server = SalixWeb.Application.base_url()
    home = Path.join(root, "home")
    auth_home = System.get_env("COMMA31_RUNTIME_AUTH_HOME", "") |> String.trim()

    auth_env =
      if auth_home == "" do
        []
      else
        [
          {~c"CODEX_HOME", String.to_charlist(Path.join(auth_home, ".codex"))},
          {~c"PI_CODING_AGENT_DIR", String.to_charlist(Path.join(auth_home, ".pi/agent"))},
          {~c"KIMI_CODE_HOME", String.to_charlist(Path.join(auth_home, ".kimi-code"))}
        ]
      end

    File.mkdir_p!(home)

    Port.open({:spawn_executable, bin}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      env: [{~c"HOME", String.to_charlist(home)} | auth_env],
      args: [
        "--server",
        server,
        "--connector-token",
        token,
        "--name",
        "COMMA31 #{provider} #{alias_name}",
        "--alias",
        alias_name,
        "--root",
        root,
        "--reconnect=true",
        "--system-info-interval",
        "0"
      ]
    ])
  end

  defp start_runtime_metadata_connector!(helper, mode, token, alias_name, ready, opts \\ []) do
    File.rm(ready)

    extra_env =
      Enum.map(opts, fn {key, value} ->
        {String.to_charlist("SALIX_TEST_RUNTIME_METADATA_#{key}"), String.to_charlist(value)}
      end)

    Port.open({:spawn_executable, helper}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      env: [
        {~c"SALIX_TEST_RUNTIME_METADATA_CONNECTOR", String.to_charlist(mode)},
        {~c"SALIX_TEST_RUNTIME_METADATA_SERVER",
         String.to_charlist(SalixWeb.Application.base_url())},
        {~c"SALIX_TEST_RUNTIME_METADATA_TOKEN", String.to_charlist(token)},
        {~c"SALIX_TEST_RUNTIME_METADATA_ALIAS", String.to_charlist(alias_name)},
        {~c"SALIX_TEST_RUNTIME_METADATA_READY", String.to_charlist(ready)}
        | extra_env
      ],
      args: ["-test.run=^TestHelperRuntimeMetadataConnector$", "-test.v"]
    ])
  end

  defp stop_connector(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      _ -> :ok
    end
  end

  defp wait_for_connected!(group_id, alias_name) do
    wait_until!("connector connected", @timeout_ms, fn ->
      connected_env(group_id, alias_name)
    end)
  end

  defp wait_for_file!(path) do
    wait_until!("runtime waiting for connector reconnect", @timeout_ms, fn ->
      if File.exists?(path), do: true
    end)
  end

  defp wait_for_reconnected!(group_id, alias_name, previous_connector_run_id) do
    wait_until!("connector reconnected", @timeout_ms, fn ->
      case connected_env(group_id, alias_name) do
        %{"connector_run_id" => connector_run_id} = env
        when connector_run_id != previous_connector_run_id ->
          env

        _ ->
          nil
      end
    end)
  end

  defp env_alias(env), do: get_in(env, ["meta", "alias"]) || env["alias"]

  defp wait_for_runtime!(group_id, alias_name, provider) do
    wait_until!("connector #{provider} runtime", @timeout_ms, fn ->
      case connected_env(group_id, alias_name) do
        %{} = env -> provider_runtime(env, provider)
        _ -> nil
      end
    end)
  end

  defp verify_configured_runtime!(tenant_id, group_id, alias_name, provider) do
    if System.get_env("COMMA31_VERIFY_CONFIGURED_RUNTIME") == "1" do
      {env, runtime} =
        wait_until!("configured #{provider} runtime inventory", @timeout_ms, fn ->
          case connected_env(group_id, alias_name) do
            %{} = env ->
              case Enum.find(env_runtimes(env), &(runtime_value(&1, "provider") == provider)) do
                %{} = runtime ->
                  if get_in(env, ["meta", "runtime_auth_generation"]) ==
                       env["connection_generation"] and
                       get_in(env, ["meta", "capabilities", "runtime_auth_v1"]) == true,
                     do: {env, runtime}

                _ ->
                  nil
              end

            _ ->
              nil
          end
        end)

      attrs = %{
        actor_id: "comma31-e2e-admin",
        project_id: group_id,
        device_id: nonblank!(env["device_id"], "device_id"),
        runtime_id: runtime_value!(runtime, "device_runtime_id"),
        group_id: group_id,
        tenant_id: tenant_id,
        backend: "openrouter"
      }

      case SalixEnv.Control.runtime_auth(:verify, attrs) do
        {:ok, %{"status" => "authenticated"}} -> :ok
        other -> raise("configured #{provider} verification failed: #{inspect(other)}")
      end
    end
  end

  defp connected_env(group_id, alias_name) do
    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, envs} -> Enum.find(envs, &(env_alias(&1) == alias_name))
      _ -> nil
    end
  end

  defp provider_runtime(env, provider) do
    env
    |> env_runtimes()
    |> Enum.find(fn runtime ->
      runtime_value(runtime, "provider") == provider and
        runtime_value(runtime, "ready") == true and
        runtime_value(runtime, "device_runtime_id") not in [nil, ""]
    end)
  end

  defp env_runtimes(env) do
    case get_in(env, ["meta", "agent_runtimes"]) || env["agent_runtimes"] do
      runtimes when is_list(runtimes) -> runtimes
      _ -> []
    end
  end

  defp runtime_value(runtime, key) when is_map(runtime) do
    Map.get(runtime, key) || Map.get(runtime, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(runtime, key)
  end

  defp runtime_value!(runtime, key), do: nonblank!(runtime_value(runtime, key), key)

  defp create_conversation!(tenant_key, group_id, agent_id, request_id) do
    resp =
      req!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations",
        %{
          "client_request_id" => request_id,
          "title" => "COMMA31 Manual Conversation",
          "participants" => [
            %{
              "actor_type" => "user",
              "user_id" => "manual-user",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"}
            },
            %{
              "actor_type" => "agent",
              "agent_id" => agent_id,
              "role_label" => "agent",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"}
            }
          ]
        }
      )

    assert!(
      resp.status == 201,
      "create conversation status #{resp.status}: #{inspect(resp.body)}"
    )

    resp.body
  end

  defp agent_session_id!(tenant_key, group_id, conversation_id, agent_id) do
    response =
      req!(
        tenant_key,
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/participants",
        nil
      )

    assert!(response.status == 200, "list conversation participants")

    response.body
    |> Map.fetch!("participants")
    |> Enum.find_value(fn participant ->
      if participant["agent_id"] == agent_id do
        get_in(participant, ["payload", "session_id"])
      end
    end)
    |> nonblank!("agent participant session_id")
  end

  defp send_user_message!(tenant_key, group_id, conversation_id, request_id, text) do
    resp =
      req!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        %{
          "client_request_id" => request_id,
          "content" => [%{"type" => "text", "text" => text}]
        }
      )

    assert!(resp.status == 201, "send #{request_id} status #{resp.status}: #{inspect(resp.body)}")
    assert!(resp.body["delivery_status"] == "queued", "send #{request_id} queued")
  end

  defp list_messages!(tenant_key, group_id, conversation_id) do
    resp =
      req!(
        tenant_key,
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages?limit=500",
        nil
      )

    assert!(resp.status == 200, "list messages status #{resp.status}: #{inspect(resp.body)}")
    resp.body
  end

  defp wait_for_visible_reply!(
         tenant_key,
         group_id,
         conversation_id,
         token,
         timeout_ms \\ @timeout_ms
       ) do
    wait_until!("visible reply #{token}", timeout_ms, fn ->
      messages = list_messages!(tenant_key, group_id, conversation_id)
      Enum.find(agent_messages(messages), &(message_text(&1) =~ token))
    end)
  end

  defp wait_connector_accepted!(agent_id, session_id) do
    wait_until!(
      "connector input accepted #{session_id}",
      @timeout_ms,
      fn ->
        case ExternalAgentRuntime.get_session(agent_id, session_id) do
          {:ok, %{"input_message_queue" => []} = runtime} ->
            assert!(
              not Map.has_key?(runtime["runtime"], "payload"),
              "Server must not own native runtime identity"
            )

            runtime

          _ ->
            nil
        end
      end,
      25
    )
  end

  defp wait_for_server_queued_input!(agent_id, session_id) do
    wait_until!(
      "Server retained offline input #{session_id}",
      15_000,
      fn ->
        case SalixAgent.ExternalSessionStore.get_session_record(agent_id, session_id) do
          {:ok, %{"input_message_queue" => [_ | _], "runtime_wait" => wait} = runtime}
          when is_map(wait) ->
            runtime

          _ ->
            nil
        end
      end,
      25
    )
  end

  defp wait_for_session_status!(agent_id, session_id, expected) do
    wait_until!(
      "session #{session_id} status #{expected}",
      @timeout_ms,
      fn ->
        case SalixAgent.Runtime.get_session_status(agent_id, session_id) do
          {:ok, %{"status" => "queued"}} ->
            raise("external session exposed queued status")

          {:ok, %{"status" => ^expected} = status} ->
            status

          {:ok, %{"status" => observed}} ->
            Process.put({:last_session_status, session_id}, observed)
            nil

          other ->
            Process.put({:last_session_status, session_id}, inspect(other))
            nil
        end
      end,
      25
    )
  rescue
    error ->
      reraise RuntimeError,
              [
                message:
                  "#{Exception.message(error)}; last status: #{inspect(Process.get({:last_session_status, session_id}))}"
              ],
              __STACKTRACE__
  end

  defp assert_session_active_after_acceptance!(agent_id, session_id) do
    case SalixAgent.Runtime.get_session_status(agent_id, session_id) do
      {:ok, %{"status" => status}} when status in ["starting", "running"] ->
        :ok

      {:ok, %{"status" => "queued"}} ->
        raise("external session exposed queued status")

      other ->
        raise("session #{session_id} became inactive after message acceptance: #{inspect(other)}")
    end
  end

  defp assert_same_capability!(agent_id, session_id, expected_hash) do
    runtime = wait_connector_accepted!(agent_id, session_id)

    if runtime["runtime_capability_token_hash"] != expected_hash do
      mismatches = Process.get(:comma31_capability_mismatches, [])

      Process.put(
        :comma31_capability_mismatches,
        [{session_id, runtime["runtime_capability_token_hash"]} | mismatches]
      )
    end

    runtime
  end

  defp wait_for_session_events!(agent_id, session_id) do
    wait_until!("session runtime events #{session_id}", @timeout_ms, fn ->
      case ExternalAgentRuntime.get_session(agent_id, session_id) do
        {:ok, %{"events" => events} = session} when is_list(events) and events != [] ->
          session

        _ ->
          nil
      end
    end)
  end

  defp wait_for_session_work_state!(agent_id, session_id, expected) do
    wait_until!("session runtime work state #{expected} #{session_id}", @timeout_ms, fn ->
      case ExternalAgentRuntime.get_session(agent_id, session_id) do
        {:ok, %{"events" => events}} when is_list(events) ->
          Enum.find(events, fn record ->
            get_in(record, ["data", "event", "work_state"]) == expected
          end)

        _ ->
          nil
      end
    end)
  end

  defp wait_for_event_content!(agent_id, session_id, content, timeout_ms \\ @timeout_ms) do
    wait_until!("session event content #{content}", timeout_ms, fn ->
      case ExternalAgentRuntime.get_session(agent_id, session_id) do
        {:ok, %{"events" => events}} when is_list(events) ->
          Enum.find(events, fn record ->
            event = get_in(record, ["data", "event"]) || %{}
            event_content(event) =~ content
          end)

        _ ->
          nil
      end
    end)
  end

  defp refute_event_content!(agent_id, session_id, content) do
    {:ok, %{"events" => events}} = ExternalAgentRuntime.get_session(agent_id, session_id)

    assert!(
      Enum.all?(events, fn record ->
        event = get_in(record, ["data", "event"]) || %{}
        not (event_content(event) =~ content)
      end),
      "runtime events stay in their Salix session"
    )
  end

  defp event_content(event), do: Jason.encode!(event)

  defp req!(tenant_key, method, path, nil) do
    Req.request!(
      method: method,
      url: SalixWeb.Application.base_url() <> path,
      headers: headers(tenant_key)
    )
  end

  defp req!(tenant_key, method, path, body) do
    Req.request!(
      method: method,
      url: SalixWeb.Application.base_url() <> path,
      headers: headers(tenant_key),
      json: body
    )
  end

  defp headers(tenant_key), do: [{"authorization", "Bearer " <> tenant_key}]

  defp private_device_capability?(tenant_id, group_id, device_id, capability) do
    case private_device_record(tenant_id, group_id, device_id) do
      {:ok, record} -> get_in(record, ["meta", "capabilities", capability]) == true
      {:error, _reason} -> false
    end
  end

  defp private_device_record(tenant_id, group_id, device_id) do
    case SalixEnv.Registry.get_device(tenant_id, group_id, device_id) do
      {:ok,
       %{
         "tenant_id" => ^tenant_id,
         "group_id" => ^group_id,
         "device_id" => ^device_id,
         "meta" => %{
           "tenant_id" => ^tenant_id,
           "group_id" => ^group_id,
           "device_id" => ^device_id
         }
       } = record} ->
        {:ok, record}

      {:ok, _mismatched} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp agent_messages(messages) do
    Enum.filter(messages, fn message ->
      message["actor_type"] == "agent"
    end)
  end

  defp message_text(message) do
    message["content"]
    |> List.wrap()
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp wait_until!(label, timeout_ms, fun, interval_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until!(label, deadline, fun, interval_ms)
  end

  defp do_wait_until!(label, deadline, fun, interval_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          raise("timed out waiting for #{label}")
        else
          Process.sleep(interval_ms)
          do_wait_until!(label, deadline, fun, interval_ms)
        end

      false ->
        if System.monotonic_time(:millisecond) > deadline do
          raise("timed out waiting for #{label}")
        else
          Process.sleep(interval_ms)
          do_wait_until!(label, deadline, fun, interval_ms)
        end

      value ->
        value
    end
  end

  defp assert!(true, _label), do: :ok
  defp assert!(false, label), do: raise("assertion failed: #{label}")

  defp nonblank!(value, _label) when is_binary(value) and value != "", do: value
  defp nonblank!(_value, label), do: raise("#{label} is blank")
end

Comma31ExternalRuntimeManualE2E.start_recovery!()

case System.get_env("COMMA31_SERVER_RESTART_FILE") do
  path when is_binary(path) and path != "" ->
    if File.exists?(path),
      do: Comma31ExternalRuntimeManualE2E.resume_server!(path),
      else: Comma31ExternalRuntimeManualE2E.run()

  _ ->
    Comma31ExternalRuntimeManualE2E.run()
end
