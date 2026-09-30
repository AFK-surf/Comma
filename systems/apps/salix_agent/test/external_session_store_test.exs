Code.require_file("../../bridge_for_teams_web/e2e/external_session_fixture.exs", __DIR__)

defmodule SalixAgent.ExternalSessionStoreTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    AsyncToolResults,
    DependencyJob,
    ExternalAgentRuntime,
    ExternalSessionActor,
    ExternalSessionRecords,
    ExternalSessionStatus,
    ExternalSessionStore,
    SessionToolExecution,
    SessionWorkIndex,
    Waits
  }

  alias SalixStore.{Compute, Keys, RuntimeIds, S3, Timers, ULID}

  defmodule LegacyExternalSessionStatusV1 do
    @moduledoc false

    alias SalixStore.{Keys, S3}

    # This is the exact schema/read/update fence shipped at reviewed base
    # ab1003d1a5eee91630a7063d87463ede6bb6df46. Keeping the legacy reader in
    # the test makes the cross-version incompatibility executable without
    # loading two production modules with the same name.
    @schema_version 1
    @starting_timeout_seconds 30
    @work_states ~w(running settled failed)
    @statuses ~w(idle starting running waiting failed unknown)

    def get(agent_id, session_id) do
      with {:ok, %{body: body}} <- S3.get(key(agent_id, session_id)),
           {:ok, status} <- Jason.decode(body),
           :ok <- validate(status, session_id) do
        {:ok, status}
      end
    end

    def dispatch_started(agent_id, session_id, dispatch_id, connector_run_id, timestamp) do
      update(agent_id, session_id, fn current ->
        current
        |> Map.put("dispatch_id", dispatch_id)
        |> Map.put("connector_run_id", connector_run_id)
        |> Map.put("execution_id", nil)
        |> Map.put("source_work_state", nil)
        |> Map.put("status", "starting")
        |> Map.put("work_status", "starting")
        |> Map.put("status_updated_at", timestamp)
        |> Map.put("starting_expires_at", timestamp + @starting_timeout_seconds)
        |> Map.delete("issue")
        |> Map.delete("message")
      end)
    end

    defp update(agent_id, session_id, fun) do
      path = key(agent_id, session_id)

      with {:ok, %{body: body, etag: etag}} <- S3.get(path),
           {:ok, current} <- Jason.decode(body),
           :ok <- validate(current, session_id),
           next <- fun.(current),
           :ok <- validate(next, session_id),
           {:ok, _} <- S3.put(path, Jason.encode!(next), if_match: etag) do
        {:ok, next}
      end
    end

    defp validate(status, session_id) do
      cond do
        status["schema_version"] != @schema_version ->
          {:error, :invalid_external_session_status}

        status["session_id"] != session_id ->
          {:error, :session_id_mismatch}

        status["status"] not in @statuses ->
          {:error, :invalid_external_session_status}

        status["source_work_state"] not in [nil | @work_states] ->
          {:error, :invalid_external_session_status}

        not valid_message?(status["message"]) ->
          {:error, :invalid_external_session_status}

        true ->
          :ok
      end
    end

    defp valid_message?(nil), do: true

    defp valid_message?(message) when is_binary(message),
      do: String.valid?(message) and String.trim(message) != "" and byte_size(message) <= 300

    defp valid_message?(_message), do: false

    defp key(agent_id, session_id),
      do: Keys.agent_external_runtime_session_status(agent_id, session_id)
  end

  @runtime_pid_key {__MODULE__, :runtime_pid}
  @runtime_availability_key {__MODULE__, :runtime_availability}
  @blocked_notification_key {__MODULE__, :blocked_notification}
  @session_id "ses1_0000000000000000801"
  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  # Same contract as @eventually_budget_ms below, for the other half of this
  # file's waits: an `assert_receive` ceiling is a scheduling margin, not a
  # latency assertion. Every one of these waits on work that is already in
  # flight, and the assertion returns the moment the message lands — so a wider
  # ceiling costs nothing on a passing run and is only ever spent on a run that
  # was going to fail. The 1s ceiling was tight enough that a loaded runner
  # tripped it while the system was behaving, which is #866's rotating flake:
  # it lands as "no matching message after 1000ms" in whichever test happened
  # to be descheduled, never twice in the same place.
  @receive_budget_ms 5_000

  defmodule RuntimeEnv do
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(%{"kind" => "compute_workload"} = config, _, _) do
      {:ok,
       Map.merge(config, %{"runtime_instance_id" => "test-instance", "connection_epoch" => "1"})}
    end

    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      case :persistent_term.get({__MODULE__, :resolution_error}, nil) do
        nil ->
          resolved_binding(config)

        {:once, reason} ->
          :persistent_term.erase({__MODULE__, :resolution_error})
          {:error, reason}

        reason ->
          {:error, reason}
      end
    end

    defp resolved_binding(config) do
      binding = %{
        "kind" => "external",
        "provider" => config["provider"],
        "device_id" => "test-device",
        "connector_id" => "test-connector",
        "connector_run_id" => "test-connector-run",
        "runtime_id" => "test-runtime",
        "device_runtime_id" => config["device_runtime_id"],
        "command" => "codex"
      }

      case :persistent_term.get({__MODULE__, :carrier_provider}, nil) do
        provider when is_binary(provider) -> {:ok, Map.put(binding, "carrier_provider", provider)}
        _ -> {:ok, binding}
      end
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      status =
        :persistent_term.get(
          {SalixAgent.ExternalSessionStoreTest, :runtime_availability},
          %{"status" => "ready"}
        )

      {:ok,
       Map.merge(
         %{
           "connector_run_id" => "test-connector-run",
           "device_runtime_id" => config["device_runtime_id"]
         },
         status
       )}
    end
  end

  defmodule LiveLlmResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id) do
      {:ok, :persistent_term.get({__MODULE__, :config})}
    end
  end

  defmodule ConsultationLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, %{})

    @impl true
    def complete(messages, tools, opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:consultation_llm, self(), messages, tools, opts})

      receive do
        {:consultation_reply, result} -> result
      after
        5_000 -> {:error, :test_timeout}
      end
    end
  end

  defmodule BlockingRuntime do
    @behaviour SalixAgent.ExternalRuntime

    @impl true
    def run(request) do
      owner = :persistent_term.get({SalixAgent.ExternalSessionStoreTest, :runtime_pid})
      send(owner, {:runtime_request, self(), request})

      receive do
        {:runtime_return, response} -> response
      after
        5_000 -> {:error, :test_timeout}
      end
    end
  end

  defmodule MigrationRuntime do
    @behaviour SalixAgent.ExternalRuntime
    @impl true
    defdelegate run(request), to: BlockingRuntime

    @impl true
    def migration(request) do
      owner = :persistent_term.get({SalixAgent.ExternalSessionStoreTest, :runtime_pid})
      send(owner, {:migration_request, request.action, request.binding, request.params})
      key = {__MODULE__, :progress}
      all_progress = :persistent_term.get(key, %{})
      session_id = request.params["session_id"]
      progress = Map.get(all_progress, session_id, %{})

      save = fn field ->
        :persistent_term.put(
          key,
          Map.put(all_progress, session_id, Map.put(progress, field, true))
        )
      end

      cond do
        request.params["cancel"] == true ->
          {:ok, %{"phase" => "cancelled"}}

        request.action == "prepare" ->
          {:ok, %{"phase" => "prepared"}}

        request.action == "export" ->
          {:ok, %{"data" => "fixture", "offset" => 0, "done" => true}}

        request.action == "import" and request.params["activate"] == true ->
          if progress[:activation_failed] do
            {:ok, %{"phase" => "activated"}}
          else
            save.(:activation_failed)
            {:error, :target_install_interrupted}
          end

        request.action == "import" ->
          save.(:staged)
          {:ok, %{"phase" => "staged", "next_offset" => 7}}

        request.action == "retire" ->
          save.(:retired)
          {:error, :lost_retire_reply}

        request.action == "discard" ->
          {:ok, %{"phase" => "discarded"}}

        request.action == "status" and request.binding["kind"] == "compute_workload" ->
          {:ok,
           %{"phase" => if(progress[:staged], do: "staged", else: "absent"), "next_offset" => 0}}

        request.action == "status" ->
          {:ok, %{"phase" => if(progress[:retired], do: "retired", else: "prepared")}}
      end
    end
  end

  defmodule BlockingNotifier do
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case :persistent_term.get(
             {SalixAgent.ExternalSessionStoreTest, :blocked_notification},
             nil
           ) do
        %{owner: owner, event: ^event} ->
          ref = make_ref()
          send(owner, {:notification_blocked, self(), ref, agent_id, event})

          receive do
            {:release_notification, ^ref} -> :ok
          after
            5_000 -> :ok
          end

        _other ->
          :ok
      end
    end
  end

  defmodule OAuthStub do
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(agent_id) do
      with {:ok, agent} <- SalixAgent.AgentControl.get_record(agent_id) do
        {:ok, %{tenant: agent["tenant_id"], group_id: agent["group_id"]}}
      end
    end

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule PreconditionOnceS3 do
    @behaviour SalixStore.S3

    @armed_key {__MODULE__, :armed_key}

    def arm(key), do: :persistent_term.put(@armed_key, key)
    def disarm, do: :persistent_term.erase(@armed_key)

    @impl true
    def put(key, body, opts) do
      if :persistent_term.get(@armed_key, nil) == key do
        disarm()
        {:error, :precondition_failed}
      else
        SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  defmodule ConcurrentDelayS3 do
    @behaviour SalixStore.S3

    @delay_key {__MODULE__, :delay}

    def arm(keys, delay_ms, operation \\ :get) do
      counters = :atomics.new(2, signed: false)
      :persistent_term.put(@delay_key, {operation, MapSet.new(keys), delay_ms, counters})
    end

    def disarm, do: :persistent_term.erase(@delay_key)

    def max_concurrency do
      {_operation, _keys, _delay_ms, counters} = :persistent_term.get(@delay_key)
      :atomics.get(counters, 2)
    end

    @impl true
    def put(key, body, opts) do
      maybe_delay(:put, key)
      SalixStore.S3.Fake.put(key, body, opts)
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    def get(key, opts) do
      maybe_delay(:get, key)
      SalixStore.S3.Fake.get(key, opts)
    end

    defp maybe_delay(operation, key) do
      case :persistent_term.get(@delay_key, nil) do
        {^operation, keys, delay_ms, counters} ->
          if MapSet.member?(keys, key) do
            current = :atomics.add_get(counters, 1, 1)
            record_max_concurrency(counters, current)

            try do
              Process.sleep(delay_ms)
            after
              :atomics.sub_get(counters, 1, 1)
            end
          end

        nil ->
          :ok

        {_other_operation, _keys, _delay_ms, _counters} ->
          :ok
      end
    end

    defp record_max_concurrency(counters, current) do
      previous = :atomics.get(counters, 2)

      cond do
        current <= previous ->
          :ok

        :atomics.compare_exchange(counters, 2, previous, current) == :ok ->
          :ok

        true ->
          record_max_concurrency(counters, current)
      end
    end

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  setup do
    previous_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    previous_external_runtime_driver =
      Application.get_env(:salix_agent, :external_runtime_driver)

    previous_oauth_store = Application.get_env(:salix_agent, :oauth_store_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:salix_agent, :external_runtime_driver, BlockingRuntime)
    Application.put_env(:salix_agent, :notifier, BlockingNotifier)
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStub)
    :persistent_term.put(@runtime_pid_key, self())
    :persistent_term.put(@runtime_availability_key, %{"status" => "ready"})
    :persistent_term.erase({RuntimeEnv, :resolution_error})
    :persistent_term.erase({RuntimeEnv, :carrier_provider})
    :persistent_term.erase({MigrationRuntime, :progress})
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase({RuntimeEnv, :resolution_error})
      :persistent_term.erase({RuntimeEnv, :carrier_provider})
      :persistent_term.erase(@runtime_pid_key)
      :persistent_term.erase(@runtime_availability_key)
      :persistent_term.erase(@blocked_notification_key)
      :persistent_term.erase({MigrationRuntime, :progress})
      restore_env(:runtime_environment_mod, previous_runtime_environment)
      restore_env(:external_runtime_driver, previous_external_runtime_driver)
      restore_env(:notifier, previous_notifier)
      restore_env(:oauth_store_mod, previous_oauth_store)
    end)

    :ok
  end

  test "Conversation admission atomically tracks independent sources across a lost CAS reply" do
    {agent_id, pid, _agent} = start_external_session()

    source = %{
      "participant_id" => "participant-a",
      "conversation_id" => "conversation-a",
      "generation" => @session_id,
      "start_seq" => 0,
      "seq" => 1
    }

    entry = %{
      source_message_id: "source-a",
      conversation_source: source,
      payload: %{
        "session_id" => @session_id,
        "role" => "user",
        "content" => "first",
        "no_wake" => true
      }
    }

    key = Keys.agent_external_runtime_session(agent_id, @session_id)
    # Create the Session before injecting ambiguity at its input CAS.
    assert {:ok, :committed} = stage(pid, "existing", "already admitted", no_wake: true)
    S3.Fake.set_fault({:ambiguous_after, :put, key})
    assert {:error, {:ambiguous, :injected}} = ExternalSessionActor.stage_delivery(pid, entry)
    assert {:ok, :duplicate} = ExternalSessionActor.stage_delivery(pid, entry)
    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["conversation_sources"]["participant-a"]["seq"] == 1
    assert Enum.count(state["input_message_queue"], &(&1["content"] == "first")) == 1

    other = %{
      entry
      | source_message_id: "source-b",
        conversation_source: %{
          source
          | "participant_id" => "participant-b",
            "conversation_id" => "conversation-b"
        }
    }

    assert {:ok, :committed} = ExternalSessionActor.stage_delivery(pid, other)
    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert map_size(state["conversation_sources"]) == 2
    gap = %{entry | conversation_source: Map.put(source, "seq", 3)}
    assert {:error, :conversation_source_gap} = ExternalSessionActor.stage_delivery(pid, gap)
  end

  @tag :dashboard_fixture
  test "dashboard fixture reuses the Session owner and drains dispatch before setting wait" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "dashboard-activation", "workflow activation")
    assert_receive {:runtime_request, runtime_pid, _request}, 1_000

    fixture =
      Task.async(fn ->
        BridgeForTeamsWeb.E2E.ExternalSessionFixture.accept_activation_and_wait!(
          agent_id,
          @session_id,
          agent["tenant_id"],
          agent["runtime_config"],
          "dashboard-activation-wait"
        )
      end)

    on_exit(fn -> if Process.alive?(fixture.pid), do: Process.exit(fixture.pid, :kill) end)

    assert eventually(fn ->
             match?(
               {:ok, %{"input_message_queue" => []}},
               ExternalSessionStore.get_session_record(agent_id, @session_id)
             )
           end)

    # The old seed order returned while this failed dispatch was still in flight.
    assert Task.yield(fixture, 50) == nil
    assert Process.alive?(pid)
    send(runtime_pid, {:runtime_return, {:error, :disconnected}})
    assert {:ok, _state} = Task.await(fixture, 1_000)

    assert {:ok,
            %{
              "state" => "active",
              "wait" => %{"reason" => "External Session fixture awaiting dependency"}
            }} =
             ExternalAgentRuntime.get_session_activity(agent, @session_id)

    assert {:ok, %{"wait" => %{"wait_id" => "dashboard-activation-wait"}}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    refute_receive {:runtime_request, _, _}
  end

  @tag :dashboard_fixture
  test "dashboard fixture starts a missing owner and accepts its retained activation" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "dashboard-retained-activation", "workflow activation", no_wake: true)

    :ok = GenServer.stop(pid, :normal)

    assert {:ok, _state} =
             BridgeForTeamsWeb.E2E.ExternalSessionFixture.accept_activation_and_wait!(
               agent_id,
               @session_id,
               agent["tenant_id"],
               agent["runtime_config"],
               "dashboard-retained-wait"
             )

    # Reseeding the same activation must preserve the wait without dispatching
    # an empty turn through the now-existing owner.
    assert {:ok, _state} =
             BridgeForTeamsWeb.E2E.ExternalSessionFixture.accept_activation_and_wait!(
               agent_id,
               @session_id,
               agent["tenant_id"],
               agent["runtime_config"],
               "dashboard-retained-wait"
             )

    assert {:ok,
            %{
              "input_message_queue" => [],
              "wait" => %{"wait_id" => "dashboard-retained-wait"}
            }} = ExternalSessionStore.get_session_record(agent_id, @session_id)

    refute_receive {:runtime_request, _, _}
  end

  @tag :dashboard_fixture
  test "dashboard fixture fails within its deadline without completing a busy session" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "dashboard-busy-activation", "workflow activation")
    assert_receive {:runtime_request, runtime_pid, request}, 1_000

    assert {:ok, :accepted, _state} =
             ExternalSessionActor.accept_session(pid, %{
               "token_hash" => get_in(request.binding, ["runtime_capability", "token_hash"]),
               "queue_snapshot" => queued_inputs(request.input_messages)
             })

    started = System.monotonic_time(:millisecond)

    assert_raise RuntimeError, ~r/#{@session_id}.*activity=busy/, fn ->
      BridgeForTeamsWeb.E2E.ExternalSessionFixture.wait_for_dependency!(
        pid,
        @session_id,
        "must-not-be-set",
        50
      )
    end

    assert System.monotonic_time(:millisecond) - started < 500
    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    refute state["wait"]
    send(runtime_pid, {:runtime_return, {:error, :disconnected}})
    assert eventually(fn -> not ExternalSessionActor.busy?(pid) end)
  end

  test "migration freezes dispatch while preserving input and commits only forward" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "migration-first", "before freeze", no_wake: true)
    source = agent["runtime_config"]
    target = Map.put(source, "device_runtime_id", "target-runtime")
    attrs = %{"source" => source, "target" => target}
    assert {:ok, frozen} = ExternalSessionActor.migration_command(pid, "move-1", :begin, attrs)
    deadline = frozen["migration"]["deadline"]
    assert {:ok, repeated} = ExternalSessionActor.migration_command(pid, "move-1", :begin, attrs)
    assert repeated["migration"]["deadline"] == deadline
    assert {:ok, :committed} = stage(pid, "migration-second", "during freeze", no_wake: true)
    assert {:ok, records} = ExternalSessionStore.load_records(agent_id, @session_id)

    assert {:error, :session_migration_in_progress} =
             ExternalSessionStore.begin_session(
               agent_id,
               @session_id,
               agent["tenant_id"],
               source,
               records
             )

    assert {:error, :invalid_migration_transition} =
             ExternalSessionActor.migration_command(pid, "move-1", :commit)

    assert {:ok, _} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" => %{"reason" => "approval pending"}
               },
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "migration-background",
                 "tool_name" => "local.background",
                 "status" => "running",
                 "started_at" => 100
               }
             ])

    assert {:error, :migration_obligations_pending} =
             ExternalSessionActor.migration_command(pid, "move-1", :staged)

    assert {:ok, _} =
             ExternalSessionActor.commit_session_events(pid, [
               %{"type" => "wait_clear", "session_id" => @session_id}
             ])

    assert {:error, :migration_obligations_pending} =
             ExternalSessionActor.migration_command(pid, "move-1", :staged)

    assert {:ok, _} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_completed",
                 "session_id" => @session_id,
                 "tool_call_id" => "migration-background",
                 "result" => %{"content" => "done"},
                 "completed_at" => 200
               }
             ])

    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-1", :staged)
    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-1", :retiring)

    assert {:error, :invalid_migration_transition} =
             ExternalSessionActor.migration_command(pid, "move-1", :cancel)

    assert {:ok, committed} = ExternalSessionActor.migration_command(pid, "move-1", :commit)
    assert committed["runtime"]["binding"] == target

    assert Enum.map(committed["input_message_queue"], & &1["content"]) == [
             "before freeze",
             "during freeze"
           ]

    assert {:ok, :committed} = stage(pid, "migration-third", "after commit", no_wake: true)
    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-1", :commit)
  end

  test "Connected Runtime input and birth continue for a non-Compute group before Group handoff" do
    marker = "group_compute_authority_v1"

    %{rows: previous} =
      SalixStore.Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [
        marker
      ])

    SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [marker])

    on_exit(fn ->
      case previous do
        [[evidence]] ->
          SalixStore.Repo.query!(
            "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence",
            [marker, evidence]
          )

        [] ->
          SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [marker])
      end
    end)

    {_agent_id, pid, agent} = start_external_session("connected_runtime")
    assert {:ok, :committed} = stage(pid, "pre-handoff-input", "retained input", no_wake: true)

    assert {:ok, _binding} =
             ExternalSessionActor.begin_session(pid, agent["tenant_id"], agent["runtime_config"])
  end

  test "migration coordinator preserves the queue through lost retirement and target install replies" do
    Application.put_env(:salix_agent, :external_runtime_driver, MigrationRuntime)
    {agent_id, pid, agent} = start_external_session()
    target = migration_compute_target(agent)

    run = fn opts ->
      action =
        cond do
          opts[:cancel] -> "cancel"
          opts[:repair] -> "repair"
          true -> "step"
        end

      SalixAgent.Release.session_migration(action, %{
        "agent_id" => agent_id,
        "tenant_id" => agent["tenant_id"],
        "target" => target,
        "operation_id" => "coordinate"
      })
    end

    assert {:ok, :committed} =
             stage(pid, "coordinator-input", "preserve accepted input", no_wake: true)

    assert {:ok, source_binding} =
             ExternalSessionActor.begin_session(pid, agent["tenant_id"], agent["runtime_config"])

    source_token = get_in(source_binding, ["runtime_capability", "token"])
    assert {:ok, _} = ExternalSessionStore.validate_runtime_capability(source_token)

    assert {:ok, %{phase: "staged"}} = run.([])
    assert {:ok, :committed} = stage(pid, "coordinator-during-freeze", "accepted while frozen")

    assert {:error, :session_creation_frozen} =
             SalixAgent.AgentControl.reserve_external_session(
               agent_id,
               "ses1_0000000000000000802"
             )

    assert {:ok, %{transferred: 7}} = run.([])
    assert {:ok, %{phase: "retiring"}} = run.([])
    assert {:error, {:retire_outcome_unknown, :lost_retire_reply}} = run.([])
    assert {:error, :migration_requires_forward_repair} = run.(cancel: true)
    assert {:error, :target_install_interrupted} = run.([])
    assert {:ok, frozen} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert frozen["migration"]["phase"] == "retiring"
    assert frozen["runtime"]["binding"] == agent["runtime_config"]

    assert Enum.map(frozen["input_message_queue"], & &1["content"]) == [
             "preserve accepted input",
             "accepted while frozen"
           ]

    assert {:ok, %{phase: "committed", complete: false}} = run.(repair: true)

    assert {:error, :unauthorized} =
             ExternalSessionStore.validate_runtime_capability(source_token)

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    assert request.binding["workload_id"] == target["workload_id"]
    assert {:ok, %{phase: "committed", complete: false}} = run.([])
    assert {:ok, %{phase: "committed", complete: true}} = run.([])
    assert {:ok, completed} = SalixAgent.AgentControl.get_record(agent_id)
    assert completed["runtime_config"]["workload_id"] == target["workload_id"]
    assert completed["session_admission"] == nil

    assert {:ok, status} =
             SalixAgent.Release.session_migration("status", %{
               "agent_id" => agent_id,
               "tenant_id" => agent["tenant_id"]
             })

    assert status.admission == nil
    assert status.binding["workload_id"] == target["workload_id"]
    assert [%{session_id: @session_id, migration: %{"phase" => "committed"}}] = status.sessions
    assert status.next == nil

    assert {:error, :not_found} =
             SalixAgent.Release.session_migration("status", %{
               "agent_id" => agent_id,
               "tenant_id" => "ten1_0000000000000000001"
             })

    send(runtime_pid, {:runtime_return, {:error, :test_finished}})
  end

  test "partial Session completion leaves the Agent frozen and cannot cancel the batch" do
    Application.put_env(:salix_agent, :external_runtime_driver, MigrationRuntime)
    {agent_id, first, agent} = start_external_session()
    target = migration_compute_target(agent)
    second_id = "ses1_0000000000000000802"

    {:ok, second} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: second_id,
        process_on_init: false
      )

    for {pid, id, input} <- [{first, @session_id, "first"}, {second, second_id, "second"}] do
      assert {:ok, :committed} = stage(pid, input, input, no_wake: true, session_id: id)

      assert {:ok, _} =
               ExternalSessionActor.begin_session(
                 pid,
                 agent["tenant_id"],
                 agent["runtime_config"]
               )
    end

    run = fn opts ->
      SalixAgent.ExternalSessionMigration.run(
        agent_id,
        agent["tenant_id"],
        target,
        "partial-batch",
        opts
      )
    end

    assert {:error, :invalid_migration_operation} =
             SalixAgent.ExternalSessionMigration.run(
               agent_id,
               agent["tenant_id"],
               target,
               "invalid/op"
             )

    assert {:ok, unfrozen} = SalixAgent.AgentControl.get_record(agent_id)
    assert unfrozen["session_admission"] == nil

    committed_id =
      Enum.reduce_while(1..12, nil, fn _, _ ->
        case run.([]) do
          {:ok, %{phase: "committed", session_id: id}} -> {:halt, id}
          {:ok, _} -> {:cont, nil}
          {:error, {:retire_outcome_unknown, :lost_retire_reply}} -> {:cont, nil}
          {:error, :target_install_interrupted} -> {:cont, nil}
          error -> flunk("migration did not progress: #{inspect(error)}")
        end
      end)

    assert committed_id in [@session_id, second_id]
    remaining_id = if committed_id == @session_id, do: second_id, else: @session_id
    assert {:ok, remaining} = ExternalSessionStore.get_session_record(agent_id, remaining_id)
    assert remaining["migration"] == nil
    assert remaining["runtime"]["binding"] == agent["runtime_config"]
    assert length(remaining["input_message_queue"]) == 1
    assert {:ok, partial} = SalixAgent.AgentControl.get_record(agent_id)
    assert partial["runtime_config"] == agent["runtime_config"]
    assert partial["session_admission"]["operation_id"] == "partial-batch"
    assert {:error, :migration_requires_forward_repair} = run.(cancel: true)

    assert {:error, :session_creation_frozen} =
             SalixAgent.AgentControl.reserve_external_session(
               agent_id,
               "ses1_0000000000000000803"
             )
  end

  test "unmigratable cleanup permanently archives before exact source discard" do
    Application.put_env(:salix_agent, :external_runtime_driver, MigrationRuntime)
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "discard-input", "approved abandoned input", no_wake: true)

    assert {:ok, _} =
             ExternalSessionActor.begin_session(pid, agent["tenant_id"], agent["runtime_config"])

    assert {:ok, result} =
             SalixAgent.Release.session_migration("archive_unmigratable", %{
               "agent_id" => agent_id,
               "tenant_id" => agent["tenant_id"],
               "operation_id" => "discard-unmigratable-1",
               "source" => agent["runtime_config"],
               "session_id" => @session_id
             })

    assert result.phase == "discarded"
    assert result.session_id == @session_id
    assert {:ok, archived} = SalixAgent.AgentControl.get_record(agent_id)
    assert archived["permanent_archive"] == true

    assert_receive {:migration_request, "discard", binding, params}, @receive_budget_ms
    assert binding["device_runtime_id"] == agent["runtime_config"]["device_runtime_id"]
    assert params["session_id"] == @session_id
    assert params["destination"] == "permanent-archive:" <> agent_id

    assert {:ok, status} =
             SalixAgent.Release.session_migration("status", %{
               "agent_id" => agent_id,
               "tenant_id" => agent["tenant_id"]
             })

    assert [%{session_id: @session_id}] = status.sessions

    assert {:error, :archive_discard_scope_mismatch} =
             SalixAgent.Release.session_migration("archive_unmigratable", %{
               "agent_id" => agent_id,
               "tenant_id" => agent["tenant_id"],
               "operation_id" => "discard-wrong-source",
               "source" => Map.put(agent["runtime_config"], "device_runtime_id", "wrong"),
               "session_id" => @session_id
             })
  end

  test "migration cancellation resumes the source and releases Agent creation admission" do
    Application.put_env(:salix_agent, :external_runtime_driver, MigrationRuntime)
    {agent_id, pid, agent} = start_external_session()
    target = migration_compute_target(agent)

    run = fn opts ->
      SalixAgent.ExternalSessionMigration.run(
        agent_id,
        agent["tenant_id"],
        target,
        "cancel-batch",
        opts
      )
    end

    assert {:ok, :committed} = stage(pid, "cancel-input", "return to source", no_wake: true)
    assert {:ok, %{phase: "staged"}} = run.([])
    assert {:ok, :committed} = stage(pid, "cancel-during-freeze", "accepted while frozen")
    assert {:ok, %{phase: "checking_cancellation"}} = run.(cancel: true)
    assert {:ok, %{phase: "cancelled", complete: false}} = run.([])
    assert {:ok, %{phase: "cancelled", complete: true}} = run.([])
    assert {:ok, %{phase: "cancelled", complete: true}} = run.([])
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    assert request.binding["device_runtime_id"] == @device_runtime_id

    assert {:ok, _} =
             SalixAgent.AgentControl.reserve_external_session(
               agent_id,
               "ses1_0000000000000000802"
             )

    assert {:ok, _} =
             SalixAgent.AgentControl.release_external_session(
               agent_id,
               "ses1_0000000000000000802"
             )

    send(runtime_pid, {:runtime_return, {:error, :test_finished}})
  end

  test "migration retries an input rejected by the sealed source on its target" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "migration-rejected", "keep this input")
    assert_receive {:runtime_request, runtime_pid, _request}, @receive_budget_ms
    source = agent["runtime_config"]
    target = Map.put(source, "device_runtime_id", "target-runtime")

    assert {:ok, _} =
             ExternalSessionActor.migration_command(pid, "move-retry", :begin, %{
               "source" => source,
               "target" => target
             })

    assert {:error, :migration_dispatch_ack_pending} =
             ExternalSessionActor.migration_command(pid, "move-retry", :staged)

    send(runtime_pid, {:runtime_return, {:error, :session_migration_frozen}})
    assert eventually(fn -> :sys.get_state(pid).pending_external == nil end)
    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-retry", :staged)
    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-retry", :retiring)
    assert {:ok, _} = ExternalSessionActor.migration_command(pid, "move-retry", :commit)
    ExternalSessionActor.wake(agent_id, @session_id)
    assert_receive {:runtime_request, target_pid, request}, @receive_budget_ms
    assert request.binding["device_runtime_id"] == "target-runtime"
    assert Enum.any?(request.input_messages, &(&1["content"] == "keep this input"))
    send(target_pid, {:runtime_return, {:error, :test_finished}})
  end

  test "state stores the exact binding and pending input without native runtime state" do
    {agent_id, pid, _agent} = start_external_session()
    trusted_origin = %{"provider" => "internal", "message_id" => "msg-test"}

    assert {:ok, :committed} =
             stage(pid, "input-1", "context",
               no_wake: true,
               trusted_origin: trusted_origin
             )

    key = Keys.agent_external_runtime_session(agent_id, @session_id)
    assert key == "agents/#{agent_id}/external_runtime/sessions/#{@session_id}.json"
    assert {:ok, %{body: body}} = S3.get(key)
    assert {:ok, state} = Jason.decode(body)

    assert %{
             "binding" => %{
               "kind" => "external",
               "provider" => "codex",
               "device_runtime_id" => @device_runtime_id
             }
           } = state["runtime"]

    refute Map.has_key?(state["runtime"], "payload")

    assert [
             %{
               "id" => input_id,
               "content" => "context",
               "trusted_origin" => ^trusted_origin
             }
           ] = state["input_message_queue"]

    assert ULID.valid?(input_id)
    refute Map.has_key?(state, "messages")
    refute Map.has_key?(state, "last_accepted_message_id")
    refute Map.has_key?(state, "codex_thread_id")
    # The delivery dedupe ledger is a deliberate part of the state contract
    # since #870: recorded atomically with the enqueue, permanent.
    assert state["input_dedupe"] == ["input-1"]
    refute Map.has_key?(state, "status")
    refute Map.has_key?(state, "last_error")
    refute Map.has_key?(state["runtime"]["binding"], "connector_run_id")

    assert {:ok, public_session} = ExternalSessionStore.get_session(agent_id, @session_id)

    refute get_in(public_session, [
             "input_message_queue",
             Access.at(0),
             "trusted_origin"
           ])

    refute get_in(public_session, [
             "input_message_queue",
             Access.at(0),
             "trusted_origin_source_message_ids"
           ])
  end

  test "memory consultation reads committed records with the Router model and no native input" do
    {_agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-memory-consultation", "execution-memory-consultation")

    router_id = configure_consultation_llm!(agent)

    snapshot = :sys.get_state(pid).records.last_id

    consultation =
      Task.async(fn ->
        ExternalSessionActor.consult(
          pid,
          "Which deployment did this Session choose?",
          "memory-consultation-test",
          router_id,
          5_000
        )
      end)

    assert_receive {:consultation_llm, llm_pid, messages, [], llm_opts}, @receive_budget_ms
    assert llm_opts["model"] == "router-authorized-model"
    assert Enum.any?(messages, &String.contains?(&1.content, "execution-memory-consultation"))

    assert List.last(messages) == %{
             role: "user",
             content: "Which deployment did this Session choose?"
           }

    refute_receive {:runtime_request, _, _}, 50

    send(llm_pid, {:consultation_reply, {:final, "The committed record says blue."}})

    assert {:ok,
            %{
              "status" => "answered",
              "answer" => "The committed record says blue.",
              "source_scope" => "salix_session_records",
              "source_snapshot" => %{
                "schema" => "salix.external-session-records.v1",
                "watermark" => ^snapshot,
                "record_ids" => record_ids
              },
              "truncated" => false
            }} = Task.await(consultation, 1_000)

    assert snapshot in record_ids
  end

  test "memory consultation freezes records before an older replay backfills the segment" do
    {agent_id, pid, agent} = start_external_session()
    router_id = configure_consultation_llm!(agent)
    cache = :sys.get_state(pid).records
    first_id = "00000000000000000000000001"
    replay_id = "00000000000000000000000002"
    last_id = "00000000000000000000000003"

    record = fn id, content ->
      %{
        "id" => id,
        "agent_id" => agent_id,
        "session_id" => @session_id,
        "type" => "runtime.event",
        "data" => %{"event" => %{"type" => "message", "content" => content}},
        "created_at" => 1
      }
    end

    assert {:ok, frozen_cache, [:committed, :committed]} =
             ExternalSessionRecords.append(
               agent_id,
               @session_id,
               cache,
               [record.(first_id, "first"), record.(last_id, "last")]
             )

    :sys.replace_state(pid, &%{&1 | records: frozen_cache})

    consultation =
      Task.async(fn ->
        ExternalSessionActor.consult(
          pid,
          "Which records were present at invocation?",
          "memory-consultation-backfill-snapshot",
          router_id,
          5_000
        )
      end)

    assert_receive {:consultation_llm, llm_pid, [_instruction, snapshot_text, _question], [],
                    _opts},
                   @receive_budget_ms

    assert snapshot_text.content =~ first_id
    assert snapshot_text.content =~ last_id
    refute snapshot_text.content =~ replay_id

    assert {:ok, _new_cache, [:committed]} =
             ExternalSessionRecords.settle_replay(
               agent_id,
               @session_id,
               frozen_cache,
               [record.(replay_id, "late backfill")]
             )

    send(llm_pid, {:consultation_reply, {:final, "Only the frozen records were used."}})

    assert {:ok,
            %{
              "status" => "answered",
              "source_snapshot" => %{
                "watermark" => ^last_id,
                "record_ids" => [^first_id, ^last_id]
              }
            }} = Task.await(consultation, 1_000)
  end

  test "memory consultation reports no_answer without interpreting missing records" do
    {_agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-memory-no-answer", "execution-memory-no-answer")

    router_id = configure_consultation_llm!(agent)

    consultation =
      Task.async(fn ->
        ExternalSessionActor.consult(
          pid,
          "What was the deployment color?",
          "memory-consultation-no-answer",
          router_id,
          5_000
        )
      end)

    assert_receive {:consultation_llm, llm_pid, _messages, [], _opts}, @receive_budget_ms
    send(llm_pid, {:consultation_reply, {:final, "NO_ANSWER"}})

    assert {:ok,
            %{
              "status" => "no_answer",
              "source_scope" => "salix_session_records",
              "truncated" => false
            }} = Task.await(consultation, 1_000)
  end

  test "memory consultation bounds normalized text without cutting a record" do
    {agent_id, pid, agent} = start_external_session()
    router_id = configure_consultation_llm!(agent)
    cache = :sys.get_state(pid).records

    {records, _last_id} =
      Enum.map_reduce(1..256, cache.last_id, fn index, previous_id ->
        id = ULID.generate(previous_id)

        record = %{
          "id" => id,
          "agent_id" => agent_id,
          "session_id" => @session_id,
          "type" => "runtime.event",
          "data" => %{
            "event" => %{
              "type" => "tool_result",
              "index" => index,
              "content" => String.duplicate(Integer.to_string(rem(index, 10)), 3_000)
            }
          },
          "created_at" => index
        }

        {record, id}
      end)

    assert {:ok, bounded_cache, statuses} =
             ExternalSessionRecords.append(agent_id, @session_id, cache, records)

    assert Enum.all?(statuses, &(&1 == :committed))
    :sys.replace_state(pid, &%{&1 | records: bounded_cache})

    consultation =
      Task.async(fn ->
        ExternalSessionActor.consult(
          pid,
          "What do the tool results show?",
          "memory-consultation-truncated",
          router_id,
          5_000
        )
      end)

    assert_receive {:consultation_llm, llm_pid, [_instruction, snapshot, _question], [], _opts},
                   @receive_budget_ms

    assert byte_size(snapshot.content) <= 512 * 1024

    assert Enum.all?(
             String.split(snapshot.content, "\n", trim: true),
             &match?({:ok, _}, Jason.decode(&1))
           )

    send(llm_pid, {:consultation_reply, {:final, "Recent complete records were retained."}})

    assert {:ok, %{"status" => "answered", "truncated" => true}} =
             Task.await(consultation, 1_000)
  end

  test "memory consultation is one-at-a-time and drops a timed-out LLM response" do
    {_agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-memory-timeout", "execution-memory-timeout")

    router_id = configure_consultation_llm!(agent)

    consultation =
      Task.async(fn ->
        ExternalSessionActor.consult(
          pid,
          "Recall after the deadline?",
          "memory-consultation-timeout",
          router_id,
          5_000
        )
      end)

    assert_receive {:consultation_llm, llm_pid, _messages, [], _opts}, @receive_budget_ms

    assert {:error, :busy} =
             ExternalSessionActor.consult(
               pid,
               "Second question",
               "memory-consultation-busy",
               router_id,
               1_000
             )

    %{consultation_job: %{dependency_job: %DependencyJob{token: token}}} = :sys.get_state(pid)
    send(pid, {:dependency_job_timeout, token})

    assert Task.await(consultation, 1_000) == {:error, :timeout}
    assert :sys.get_state(pid).consultation_job == nil

    send(llm_pid, {:consultation_reply, {:final, "This answer arrived too late."}})
    Process.sleep(20)
    assert :sys.get_state(pid).consultation_job == nil
  end

  test "every external session persistence mints a non-reusable storage revision" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "revision-1", "first", no_wake: true)

    assert {:ok, %{"storage_revision" => revision_1}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert is_binary(revision_1) and revision_1 != ""

    assert {:ok, :committed} = stage(pid, "revision-2", "second", no_wake: true)

    assert {:ok, %{"storage_revision" => revision_2}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert revision_2 != revision_1

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    assert :ok = S3.delete(state_key)
    assert {:ok, :committed} = stage(pid, "revision-3", "recreated", no_wake: true)

    assert {:ok, %{"storage_revision" => revision_3}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert revision_3 not in [revision_1, revision_2]
  end

  test "external activity revision distinguishes same-timestamp monitored ABA and ignores duplicates" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "activity-revision", "seed", no_wake: true)

    assert {:ok, initial} = ExternalSessionStatus.get(agent_id, @session_id)
    timestamp = initial["status_updated_at"]
    initial_revision = initial["activity_revision"]
    first_record = ULID.generate()
    settled_record = ULID.generate(first_record)

    assert is_binary(initial_revision) and initial_revision != ""

    assert {:ok, %{"status" => "starting"}} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-activity-revision",
               "connector-run-activity-revision",
               timestamp
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-activity-revision", "execution-activity-revision", "running")
               |> Map.put("created_at", timestamp),
               first_record,
               "connector-run-activity-revision"
             )

    assert {:ok, restopped} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-activity-revision", "execution-activity-revision", "settled")
               |> Map.put("created_at", timestamp),
               settled_record,
               "connector-run-activity-revision"
             )

    assert restopped["status"] == "idle"
    assert restopped["status_updated_at"] == timestamp
    assert is_binary(restopped["activity_revision"])
    refute restopped["activity_revision"] == initial_revision

    assert {:ok, duplicate} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-activity-revision", "execution-activity-revision", "settled")
               |> Map.put("created_at", timestamp),
               settled_record,
               "connector-run-activity-revision"
             )

    assert duplicate["activity_revision"] == restopped["activity_revision"]

    quota_record = ULID.generate(settled_record)
    runtime_failed_record = ULID.generate(quota_record)

    assert {:ok, active} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-error-revision",
               "connector-run-error-revision",
               timestamp
             )

    assert {:ok, quota_failure} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-error-revision", "execution-error-revision", "failed")
               |> Map.put("created_at", timestamp)
               |> Map.put("issue", "quota_exhausted"),
               quota_record,
               "connector-run-error-revision"
             )

    assert {:ok, runtime_failure} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-error-revision", "execution-error-revision", "failed")
               |> Map.put("created_at", timestamp)
               |> Map.put("issue", "runtime_failed"),
               runtime_failed_record,
               "connector-run-error-revision"
             )

    assert active["status_updated_at"] == timestamp
    assert quota_failure["status_updated_at"] == timestamp
    assert runtime_failure["status_updated_at"] == timestamp

    assert length(
             Enum.uniq([
               active["activity_revision"],
               quota_failure["activity_revision"],
               runtime_failure["activity_revision"]
             ])
           ) == 3
  end

  test "reading a legacy external status certifies one exact snapshot before exposing a version" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "legacy-activity-revision", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert {:ok, %{body: body}} = S3.get(status_key)
    assert {:ok, current} = Jason.decode(body)

    legacy =
      current
      |> Map.put("schema_version", 1)
      |> Map.delete("activity_revision")

    assert {:ok, _} = S3.put(status_key, Jason.encode!(legacy))

    assert {:ok, certified} = ExternalSessionStatus.get(agent_id, @session_id)
    assert certified["schema_version"] == 2
    assert is_binary(certified["activity_revision"])
    assert certified["activity_revision"] != ""

    assert {:ok, %{body: persisted_body}} = S3.get(status_key)
    assert {:ok, persisted} = Jason.decode(persisted_body)
    assert persisted["schema_version"] == 2
    assert persisted["activity_revision"] == certified["activity_revision"]
  end

  test "a legacy external writer cannot continue after the head certifies its shared status" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "legacy-writer-cutover", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert {:ok, %{body: body}} = S3.get(status_key)

    legacy =
      body
      |> Jason.decode!()
      |> Map.put("schema_version", 1)
      |> Map.delete("activity_revision")

    assert {:ok, _} = S3.put(status_key, Jason.encode!(legacy))

    assert {:ok, %{"schema_version" => 1}} =
             LegacyExternalSessionStatusV1.get(agent_id, @session_id)

    assert {:ok, %{"schema_version" => 1, "status" => "starting"}} =
             LegacyExternalSessionStatusV1.dispatch_started(
               agent_id,
               @session_id,
               "legacy-dispatch-before-cutover",
               "legacy-connector-run",
               System.system_time(:second)
             )

    assert {:ok, %{"schema_version" => 2}} = ExternalSessionStatus.get(agent_id, @session_id)

    assert {:error, :invalid_external_session_status} =
             LegacyExternalSessionStatusV1.get(agent_id, @session_id)

    assert {:error, :invalid_external_session_status} =
             LegacyExternalSessionStatusV1.dispatch_started(
               agent_id,
               @session_id,
               "legacy-dispatch-after-cutover",
               "legacy-connector-run",
               System.system_time(:second)
             )
  end

  test "legacy failed status without an issue rotates before becoming active" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "legacy-failed-activity-revision", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert {:ok, %{body: body}} = S3.get(status_key)
    assert {:ok, current} = Jason.decode(body)

    legacy =
      current
      |> Map.put("schema_version", 1)
      |> Map.put("status", "failed")
      |> Map.put("work_status", "failed")
      |> Map.delete("activity_revision")
      |> Map.delete("issue")

    assert {:ok, _} = S3.put(status_key, Jason.encode!(legacy))
    assert {:ok, certified} = ExternalSessionStatus.get(agent_id, @session_id)
    assert certified["status"] == "failed"
    refute Map.has_key?(certified, "issue")

    assert {:ok, active} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-legacy-failed-revision",
               "connector-run-legacy-failed-revision",
               certified["status_updated_at"]
             )

    assert active["status"] == "starting"
    refute active["activity_revision"] == certified["activity_revision"]
  end

  test "legacy failed status normalizes blank and padded terminal issues for activity fencing" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "legacy-normalized-failed-activity-revision", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)

    Enum.each(["   ", " runtime_failed "], fn legacy_issue ->
      assert {:ok, %{body: body}} = S3.get(status_key)
      assert {:ok, current} = Jason.decode(body)

      legacy =
        current
        |> Map.put("schema_version", 1)
        |> Map.put("status", "failed")
        |> Map.put("work_status", "failed")
        |> Map.put("issue", legacy_issue)
        |> Map.delete("activity_revision")

      assert {:ok, _} = S3.put(status_key, Jason.encode!(legacy))
      assert {:ok, certified} = ExternalSessionStatus.get(agent_id, @session_id)

      assert {:ok, active} =
               ExternalSessionStatus.dispatch_started(
                 agent_id,
                 @session_id,
                 "dispatch-normalized-failed-revision-#{String.trim(legacy_issue)}",
                 "connector-run-normalized-failed-revision-#{String.trim(legacy_issue)}",
                 certified["status_updated_at"]
               )

      refute active["activity_revision"] == certified["activity_revision"]
    end)
  end

  test "a malformed v2 external status without its revision fails closed" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "missing-activity-revision", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert {:ok, %{body: body}} = S3.get(status_key)
    assert {:ok, current} = Jason.decode(body)

    malformed = Map.delete(current, "activity_revision")
    assert {:ok, _} = S3.put(status_key, Jason.encode!(malformed))

    assert {:error, :invalid_external_session_status} =
             ExternalSessionStatus.get(agent_id, @session_id)
  end

  test "creating an external session invalidates exact-session activity subscribers" do
    {agent_id, pid, agent} = start_external_session()

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_activity_updated, @session_id}
    })

    stage_task =
      Task.async(fn ->
        stage(pid, "input-session-created", "context", no_wake: true)
      end)

    assert_receive {:notification_blocked, notifier_pid, ref, ^agent_id,
                    {:session_activity_updated, @session_id}},
                   @receive_budget_ms

    assert {:ok, %{"state" => "stopped"}} =
             SalixAgent.Runtime.get_session_activity(agent, @session_id)

    send(notifier_pid, {:release_notification, ref})
    :persistent_term.erase(@blocked_notification_key)
    assert {:ok, :committed} = Task.await(stage_task)
  end

  test "lost readiness notification resumes durable input after actor restart without a Session timer" do
    {agent_id, pid, agent} = start_external_session()

    :persistent_term.put(
      {RuntimeEnv, :resolution_error},
      {:bad_request, "runtime_config.device_runtime_id not found"}
    )

    assert {:ok, :committed} = stage(pid, "offline-input", "keep this work")

    assert eventually(fn ->
             {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
             is_map(state["runtime_wait"])
           end)

    {:ok, parked} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert Enum.any?(parked["input_message_queue"], &(&1["content"] == "keep this work"))
    assert ExternalSessionStore.work_reasons(parked) == ["runtime_wait"]
    {:ok, [marker]} = SessionWorkIndex.list(agent_id)
    assert is_nil(marker["recover_after_ms"])
    assert marker["device_runtime_id"] == @device_runtime_id
    refute SessionWorkIndex.immediate_recovery_reasons?(marker["reasons"])

    for _ <- 1..3 do
      ExternalSessionActor.wake(agent_id, @session_id)
      :sys.get_state(pid)
      :sys.get_state(pid)
    end

    {:ok, after_wakes} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert after_wakes["work_index_token"] == parked["work_index_token"]
    refute_receive {:runtime_request, _, _}, 50

    {:ok, %{records: []}} = SessionWorkIndex.list_discovery()
    {:ok, %{records: []}} = SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
    {:ok, %{records: [candidate]}} = SessionWorkIndex.list_discovery(group_id: agent["group_id"])
    assert candidate["session_id"] == @session_id

    {:ok, %{records: []}} =
      SessionWorkIndex.list_due_discovery(System.system_time(:millisecond) + 600_000)

    assert SalixAgent.SessionWorkRecovery.sweep().scanned == 0

    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               process_on_init: false
             )

    :persistent_term.erase({RuntimeEnv, :resolution_error})

    wrong_device =
      SalixAgent.SessionWorkRecovery.sweep(
        session_work_group_id: agent["group_id"],
        session_work_device_id: "another-device"
      )

    assert wrong_device.rewoken == []
    refute_receive {:runtime_request, _, _}, 50

    # The notification listener is absent. Durable publication must suffice.
    now = System.system_time(:second)

    assert :ok =
             SalixEnv.RuntimeTargets.observe(%{
               "tenant_id" => SalixStore.Ids.tenant_id_from_agent!(agent_id),
               "group_id" => agent["group_id"],
               "device_id" => "test-device",
               "status" => "connected",
               "meta" => %{
                 "agent_runtimes" => [
                   %{
                     "provider" => "codex",
                     "device_runtime_id" => @device_runtime_id,
                     "ready" => true,
                     "auth_ready" => true,
                     "native_server_startable" => true,
                     "version_detected" => true,
                     "readiness_checked_at" => now,
                     "readiness_valid_until" => now + 300
                   }
                 ]
               }
             })

    resumed = SalixAgent.SessionWorkRecovery.sweep()

    assert resumed.failed == 0
    assert resumed.rewoken != []
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    SalixAgent.SessionWorkRecovery.sweep()
    SalixAgent.SessionWorkRecovery.sweep()
    refute_receive {:runtime_request, _, _}, 50
    send(runtime_pid, {:runtime_return, accepted(request, %{"thread_id" => "after-reconnect"})})

    assert eventually(fn ->
             {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
             state["input_message_queue"] == [] and is_nil(state["runtime_wait"])
           end)

    GenServer.stop(restarted, :normal)
  end

  test "readiness racing wait registration is rechecked without another notification" do
    {agent_id, pid, _agent} = start_external_session()

    :persistent_term.put(
      {RuntimeEnv, :resolution_error},
      {:once, {:bad_request, "runtime_config.device_runtime_id is not ready"}}
    )

    assert {:ok, :committed} = stage(pid, "ready-race", "resume after readiness race")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
    refute_receive {:runtime_request, _, _}, 50
  end

  test "waiting for a runtime keeps an earlier tool wait discoverable" do
    {agent_id, pid, _agent} = start_external_session()

    :persistent_term.put(
      {RuntimeEnv, :resolution_error},
      {:bad_request, "runtime_config.device_runtime_id is not ready"}
    )

    assert {:ok, :committed} = stage(pid, "offline-with-wait", "keep queued input")

    assert eventually(fn ->
             {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
             is_map(state["runtime_wait"])
           end)

    deadline_ms = System.system_time(:millisecond) + 60_000
    wait = %{"wait_id" => "independent-tool-wait", "deadline_ms" => deadline_ms}

    assert {:ok, state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{"type" => "wait_set", "session_id" => @session_id, "wait" => wait}
             ])

    assert state["wait"] == wait
    assert is_nil(state["runtime_wait"]["deadline_ms"])
    {:ok, [marker]} = SessionWorkIndex.list(agent_id)
    assert marker["recover_after_ms"] == deadline_ms
    assert Enum.sort(marker["reasons"]) == ["runtime_wait", "wait_deadline"]
    assert queue(agent_id) != []
    refute_receive {:runtime_request, _, _}, 50
  end

  test "actor sends the complete queue and ACK commits its SessionRecords" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-1", "context", no_wake: true)
    assert {:ok, :committed} = stage(pid, "input-2", "run")

    assert_receive {:runtime_request, runtime_pid, first}, @receive_budget_ms
    assert Enum.map(queued_inputs(first.input_messages), & &1["content"]) == ["context", "run"]
    assert Enum.any?(first.input_messages, &(&1["type"] == "time_context"))
    refute inspect(first.input_messages) =~ "do_not_send_to_llm"
    refute Map.has_key?(first, :runtime_payload)

    send(runtime_pid, {:runtime_return, accepted(first, %{"thread_id" => "thread-1"})})

    assert eventually(fn ->
             case ExternalSessionStore.get_session_record(agent_id, @session_id) do
               {:ok, %{"input_message_queue" => [], "runtime" => runtime}} ->
                 not Map.has_key?(runtime, "payload")

               _ ->
                 false
             end
           end)

    assert {:ok, %{"messages" => messages}} =
             ExternalSessionStore.get_session_messages(agent_id, @session_id)

    assert Enum.map(messages, & &1["content"]) == Enum.map(first.input_messages, & &1["content"])
  end

  test "prepared context reserves IDs while another input arrives before ACK" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "future-clock", "context", no_wake: true)
    key = Keys.agent_external_runtime_session(agent_id, @session_id)
    {:ok, %{body: body, etag: etag}} = S3.get(key)
    state = Jason.decode!(body)
    # A clock rollback makes ULID allocation deterministic above this frontier.
    [input] = state["input_message_queue"]

    state =
      Map.put(state, "input_message_queue", [Map.put(input, "id", "70000000000000000000000000")])

    {:ok, _} = S3.put(key, Jason.encode!(state), if_match: etag)
    assert {:ok, :committed} = stage(pid, "first-run", "run")
    assert_receive {:runtime_request, first_pid, first}, @receive_budget_ms
    assert {:ok, :committed} = stage(pid, "arrived-before-ack", "next")
    last_prepared_id = first.input_messages |> Enum.map(& &1["id"]) |> Enum.max()
    assert List.last(queue(agent_id))["id"] > last_prepared_id
    send(first_pid, {:runtime_return, accepted(first, %{})})
    assert_receive {:runtime_request, second_pid, second}, @receive_budget_ms
    send(second_pid, {:runtime_return, accepted(second, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"messages" => messages}} =
             ExternalSessionStore.get_session_messages(agent_id, @session_id)

    assert Enum.map(messages, & &1["content"]) ==
             Enum.map(first.input_messages ++ second.input_messages, & &1["content"])
  end

  test "fresh ordinary input expands a failed batch and adopts only its new prepared context" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "ordinary-first", "first")
    assert_receive {:runtime_request, first_pid, first}, @receive_budget_ms
    send(first_pid, {:runtime_return, {:error, :native_rejected}})

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
               ExternalSessionStore.get_session_status(agent, @session_id)
             )
           end)

    assert {:ok, :committed} = stage(pid, "ordinary-next", "next")
    assert_receive {:runtime_request, expanded_pid, expanded}, @receive_budget_ms
    refute expanded.dispatch_id == first.dispatch_id
    assert Enum.map(queued_inputs(expanded.input_messages), & &1["content"]) == ["first", "next"]
    refute inspect(expanded.input_messages) =~ "do_not_send_to_llm"

    [old_input, new_input] = queue(agent_id)
    old_prepared = get_in(old_input, ["do_not_send_to_llm", "prepared_activation"])
    new_prepared = get_in(new_input, ["do_not_send_to_llm", "prepared_activation"])
    assert old_prepared["provider_state"]["time_context"]["source_cursor"] == "ordinary-first"
    assert new_prepared["provider_state"]["time_context"]["source_cursor"] == "ordinary-next"
    old_notice_ids = Enum.map(old_prepared["messages"], & &1["id"])
    assert new_input["id"] > Enum.max(old_notice_ids)
    assert Enum.all?(new_prepared["messages"], &(&1["id"] > new_input["id"]))
    refute Enum.any?(expanded.input_messages, &(&1["id"] in old_notice_ids))

    send(expanded_pid, {:runtime_return, accepted(expanded, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["context_provider_states"] == new_prepared["provider_state"]

    assert {:ok, %{"messages" => messages}} =
             ExternalSessionStore.get_session_messages(agent_id, @session_id)

    assert Enum.map(messages, & &1["content"]) ==
             Enum.map(expanded.input_messages, & &1["content"])

    ids = Enum.map(messages, & &1["id"])
    assert length(ids) == length(Enum.uniq(ids))
    refute inspect(messages) =~ "do_not_send_to_llm"
  end

  test "external Router dispatches queued provider sources one activation at a time" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    _agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "router",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "test-device",
          "runtime_id" => "test-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

    assert {:ok, records} = ExternalSessionStore.load_records(agent_id, @session_id)

    provider_delivery = fn source_message_id, thread_ts, content ->
      %{
        "source_message_id" => source_message_id,
        "payload" => %{
          "session_id" => @session_id,
          "role" => "user",
          "content" => content,
          "trusted_origin" => slack_origin(source_message_id, thread_ts)
        }
      }
    end

    meeting_source = "im_provider:slack:slack-1:event-meeting"
    unrelated_source = "im_provider:slack:slack-1:event-unrelated"

    assert {:ok, :external, _state, records} =
             ExternalSessionStore.stage_delivery(
               agent_id,
               provider_delivery.(
                 meeting_source,
                 "1788502784.380329",
                 "https://meet.google.com/nus-bxnr-wgt join"
               ),
               records
             )

    assert {:ok, :external, _state, _records} =
             ExternalSessionStore.stage_delivery(
               agent_id,
               provider_delivery.(unrelated_source, "1788502784.112249", "这个"),
               records
             )

    assert {:ok, _pid} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               process_on_init: true
             )

    assert_receive {:runtime_request, first_runtime_pid, first}, 1_000

    assert Enum.map(queued_inputs(first.input_messages), & &1["source_message_id"]) == [
             meeting_source
           ]

    first_time = Enum.find(first.input_messages, &(&1["type"] == "time_context"))
    assert first_time["content_kind"] == "model_context"
    assert first_time["content"] =~ meeting_source
    refute first_time["content"] =~ unrelated_source
    assert {:ok, before_ack} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert before_ack["context_provider_states"] == %{}
    send(first_runtime_pid, {:runtime_return, accepted(first, %{})})

    assert_receive {:runtime_request, second_runtime_pid, second}, 1_000

    assert Enum.map(queued_inputs(second.input_messages), & &1["source_message_id"]) == [
             unrelated_source
           ]

    second_time = Enum.find(second.input_messages, &(&1["type"] == "time_context"))
    assert second_time["content"] =~ unrelated_source
    refute second_time["content"] =~ meeting_source
    send(second_runtime_pid, {:runtime_return, accepted(second, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "public async tool results and uncertain summaries omit trusted origin" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-private", "pending", no_wake: true)

    trusted_origin = %{
      "provider" => "internal",
      "conversation_id" => "conv-private",
      "message_id" => "msg-private"
    }

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "async-private",
                 "tool_name" => "env.copy",
                 "status" => "running",
                 "trusted_origin" => trusted_origin,
                 "trusted_origin_source_message_ids" => ["source-private"]
               },
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" => %{
                   "wait_id" => "wait-private",
                   "deadline_ms" => System.system_time(:millisecond) + 60_000,
                   "trusted_origin" => trusted_origin,
                   "trusted_origin_source_message_ids" => ["source-private"]
                 }
               }
             ])

    assert {:ok, async_call} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, "async-private")

    refute String.contains?(inspect(async_call), "trusted_origin")

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert :ok = S3.delete(status_key)

    assert {:ok, summary} = ExternalSessionStore.get_session_summary(agent, @session_id)
    refute String.contains?(inspect(summary), "trusted_origin")
  end

  test "message acceptance stays starting until matching native lifecycle evidence" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-pending", "pending", no_wake: true)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, :committed} = stage(pid, "input-run", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    assert request.agent_id == agent_id

    assert {:ok, %{"status" => "starting"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    send(runtime_pid, {:runtime_return, accepted(request, %{"thread_id" => "thread-1"})})
    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"status" => "starting"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    capability = request.binding["runtime_capability"]

    identity = %{
      "dispatch_id" => request.dispatch_id,
      "execution_id" => "execution-test"
    }

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" =>
                 Map.merge(identity, %{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/started",
                   "state" => "inProgress",
                   "work_state" => "running"
                 })
             })

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    :persistent_term.put(@runtime_availability_key, %{
      "status" => "ready",
      "connector_run_id" => "test-connector-run-2"
    })

    assert {:ok,
            %{
              "status" => "unknown",
              "issue" => "runtime_observation_lost"
            }} = ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok,
            %{
              "state" => "error",
              "issue" => "runtime_observation_lost"
            }} = SalixAgent.Runtime.get_session_activity(agent, @session_id)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => "test-connector-run-2",
               "event" =>
                 Map.merge(identity, %{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "connector/reconnected",
                   "state" => "running",
                   "work_state" => "running"
                 })
             })

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    :persistent_term.put(@runtime_availability_key, %{
      "status" => "unavailable",
      "issue" => "authentication_required",
      "connector_run_id" => "test-connector-run-2"
    })

    assert {:ok,
            %{
              "status" => "running",
              "runtime_availability" => %{"status" => "unavailable"}
            }} = ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => "test-connector-run-2",
               "event" =>
                 Map.merge(identity, %{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/completed",
                   "state" => "completed",
                   "work_state" => "settled"
                 })
             })

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "Connector event batches validate once and bound ordered tail and replay storage work" do
    {agent_id, pid, agent, capability, request} =
      start_running_execution("input-event-batch", "execution-event-batch")

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    event_ids =
      Enum.reduce(1..64, [records_cache.last_id], fn _, ids ->
        [ULID.generate(List.first(ids)) | ids]
      end)
      |> Enum.drop(-1)
      |> Enum.reverse()

    params_list =
      event_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {event_id, index} ->
        %{
          "capability_token" => capability["token"],
          "event_id" => event_id,
          "event" => %{
            "provider" => "codex",
            "type" => "message",
            "role" => "assistant",
            "content" => "batch event #{index}",
            "created_at" => System.system_time(:second) + index
          }
        }
      end)

    backfill_event_id = Enum.at(event_ids, 31)
    initial_params_list = Enum.reject(params_list, &(&1["event_id"] == backfill_event_id))

    segment_prefix = Keys.agent_external_runtime_session_segments_prefix(agent_id, @session_id)
    capability_key = Keys.ctl_runtime_capability(capability["token_hash"])
    :ok = S3.Fake.reset_read_log()
    :ok = S3.Fake.reset_put_log()

    assert results =
             SalixAgent.ExternalAgentRuntime.handle_connector_events(
               request.binding["connector_run_id"],
               initial_params_list,
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )

    assert results == List.duplicate({:ok, %{"ok" => true}}, 63)

    segment_reads =
      Enum.filter(S3.Fake.read_log(), fn
        {:get, key} -> String.starts_with?(key, segment_prefix)
        _other -> false
      end)

    segment_puts = Enum.filter(S3.Fake.put_log(), &String.starts_with?(&1, segment_prefix))
    assert segment_reads |> length() == 1
    assert segment_puts |> length() == 1
    assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, capability_key})) == 1

    # A lost Connector response replays already-durable records and can include
    # a genuine older backfill. Even when object storage is moderately slow,
    # one bounded batch must settle both without timing out the exact owner.
    assert {:ok, replay_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    replay_segment_keys =
      event_ids
      |> Enum.map(fn event_id ->
        replay_cache.segments
        |> Enum.reverse()
        |> Enum.find(&(&1.first <= event_id))
        |> Map.fetch!(:key)
      end)
      |> Enum.uniq()

    :ok = S3.Fake.reset_read_log()
    :ok = S3.Fake.blackhole({:delay, 80, :get, :any})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    replay_results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    :ok = S3.Fake.clear_blackhole()

    assert replay_results == List.duplicate({:ok, %{"ok" => true}}, 64)

    replay_segment_reads =
      Enum.filter(S3.Fake.read_log(), fn
        {:get, key} -> key in replay_segment_keys
        _other -> false
      end)

    # Duplicate classification and the genuinely missing backfill share one
    # read, with at most one merged write, per affected segment.
    assert length(replay_segment_reads) == length(replay_segment_keys)

    # A long offline interval can leave a whole ordered batch genuinely absent
    # behind a later durable record. The exact Session owner must settle that
    # backfill within its bounded deadline as one storage operation per affected
    # segment, rather than one read/modify/write per event.
    assert {:ok, backfill_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    backfill_event_ids =
      Enum.reduce(1..65, [backfill_cache.last_id], fn _, ids ->
        [ULID.generate(List.first(ids)) | ids]
      end)
      |> Enum.drop(-1)
      |> Enum.reverse()

    backfill_params_list =
      backfill_event_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {event_id, index} ->
        %{
          "capability_token" => capability["token"],
          "event_id" => event_id,
          "event" => %{
            "provider" => "codex",
            "type" => "message",
            "role" => "assistant",
            "content" => "missing backfill event #{index}",
            "created_at" => System.system_time(:second) + 100 + index
          }
        }
      end)

    {missing_backfill, [later_durable]} = Enum.split(backfill_params_list, 64)

    assert [{:ok, %{"ok" => true}}] =
             SalixAgent.ExternalAgentRuntime.handle_connector_events(
               request.binding["connector_run_id"],
               [later_durable],
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )

    assert {:ok, backfill_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    backfill_segment_keys =
      missing_backfill
      |> Enum.map(fn %{"event_id" => event_id} ->
        backfill_cache.segments
        |> Enum.reverse()
        |> Enum.find(&(&1.first <= event_id))
        |> Map.fetch!(:key)
      end)
      |> Enum.uniq()

    :ok = S3.Fake.reset_read_log()
    :ok = S3.Fake.reset_put_log()
    :ok = S3.Fake.blackhole({:delay, 80, :get, :any})

    missing_backfill_results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        missing_backfill,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    :ok = S3.Fake.clear_blackhole()

    assert missing_backfill_results == List.duplicate({:ok, %{"ok" => true}}, 64)

    backfill_segment_reads =
      Enum.filter(S3.Fake.read_log(), fn
        {:get, key} -> key in backfill_segment_keys
        _other -> false
      end)

    assert length(backfill_segment_reads) == length(backfill_segment_keys)

    backfill_segment_puts =
      Enum.filter(S3.Fake.put_log(), &(&1 in backfill_segment_keys))

    assert length(backfill_segment_puts) == length(backfill_segment_keys)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 250)

    runtime_event_ids =
      records
      |> Enum.filter(&(&1["type"] == "runtime.event"))
      |> Enum.map(& &1["id"])

    assert Enum.all?(event_ids ++ backfill_event_ids, &(&1 in runtime_event_ids))

    # A long-lived Session can have old Connector events interleaved with enough
    # other records that one 64-item replay touches many storage segments. Keep
    # the same real owner path and storage latency used above, but spread one
    # genuinely missing event across each of 50 production-sized segments. The
    # whole exact-Session partition must still settle before its bounded owner
    # deadline instead of collapsing every item to owner_unavailable.
    assert :ok = GenServer.stop(pid, :normal, 1_000)
    assert {:ok, multisegment_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    {blocks, _last_id} =
      Enum.map_reduce(1..50, multisegment_cache.last_id, fn segment_index, last_id ->
        {ids, last_id} =
          Enum.map_reduce(1..257, last_id, fn _offset, previous_id ->
            id = ULID.generate(previous_id)
            {id, id}
          end)

        missing_id = Enum.at(ids, 128)

        filler_records =
          ids
          |> List.delete_at(128)
          |> Enum.with_index(1)
          |> Enum.map(fn {id, record_index} ->
            %{
              "id" => id,
              "agent_id" => agent_id,
              "session_id" => @session_id,
              "type" => "test.segment_filler",
              "data" => %{
                "segment" => segment_index,
                "record" => record_index
              }
            }
          end)

        {%{missing_id: missing_id, filler_records: filler_records}, last_id}
      end)

    filler_records = Enum.flat_map(blocks, & &1.filler_records)

    assert {:ok, _multisegment_cache, filler_statuses} =
             ExternalSessionRecords.append(
               agent_id,
               @session_id,
               multisegment_cache,
               filler_records
             )

    assert length(filler_statuses) == 50 * 256
    assert Enum.all?(filler_statuses, &(&1 == :committed))

    {:ok, _pid} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: @session_id,
        process_on_init: false
      )

    multisegment_params =
      Enum.with_index(blocks, 1)
      |> Enum.map(fn {%{missing_id: event_id}, index} ->
        connector_message(capability, event_id, "multi-segment replay event #{index}")
      end)

    assert {:ok, multisegment_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    multisegment_keys =
      Enum.map(multisegment_params, fn %{"event_id" => event_id} ->
        multisegment_cache.segments
        |> Enum.reverse()
        |> Enum.find(&(&1.first <= event_id))
        |> Map.fetch!(:key)
      end)

    assert length(Enum.uniq(multisegment_keys)) == 50

    :ok = S3.Fake.reset_read_log()
    ConcurrentDelayS3.arm(multisegment_keys, 300)
    Application.put_env(:salix_store, :s3_backend, ConcurrentDelayS3)

    on_exit(fn ->
      ConcurrentDelayS3.disarm()
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    multisegment_results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        multisegment_params,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    max_segment_concurrency = ConcurrentDelayS3.max_concurrency()
    ConcurrentDelayS3.disarm()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    assert multisegment_results == List.duplicate({:ok, %{"ok" => true}}, 50)
    assert max_segment_concurrency == 4

    multisegment_reads =
      Enum.filter(S3.Fake.read_log(), fn
        {:get, key} -> key in multisegment_keys
        _other -> false
      end)

    assert length(multisegment_reads) == length(multisegment_keys)
  end

  test "Connector replay preserves per-item ACKs when a later segment read fails" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution("input-partial-replay", "execution-partial-replay")

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    event_ids =
      Enum.reduce(1..320, [records_cache.last_id], fn _, ids ->
        [ULID.generate(List.first(ids)) | ids]
      end)
      |> Enum.drop(-1)
      |> Enum.reverse()

    params_list =
      event_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {event_id, index} ->
        connector_message(capability, event_id, "partial replay event #{index}")
      end)

    missing_params = [Enum.at(params_list, 99), Enum.at(params_list, 279)]
    missing_ids = MapSet.new(missing_params, & &1["event_id"])
    durable_params = Enum.reject(params_list, &MapSet.member?(missing_ids, &1["event_id"]))

    Enum.each(Enum.chunk_every(durable_params, 64), fn params ->
      assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
               request.binding["connector_run_id"],
               params,
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             ) == List.duplicate({:ok, %{"ok" => true}}, length(params))
    end)

    assert {:ok, replay_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    [early_segment_key, late_segment_key] =
      Enum.map(missing_params, fn %{"event_id" => event_id} ->
        replay_cache.segments
        |> Enum.reverse()
        |> Enum.find(&(&1.first <= event_id))
        |> Map.fetch!(:key)
      end)

    refute early_segment_key == late_segment_key
    :ok = S3.Fake.set_fault({:fail, 503, :get, late_segment_key})

    assert [{:ok, %{"ok" => true}}, {:error, _retryable}] =
             SalixAgent.ExternalAgentRuntime.handle_connector_events(
               request.binding["connector_run_id"],
               missing_params,
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 400)

    record_ids = MapSet.new(records, & &1["id"])
    assert MapSet.member?(record_ids, Enum.at(missing_params, 0)["event_id"])
    refute MapSet.member?(record_ids, Enum.at(missing_params, 1)["event_id"])
  end

  test "Connector batch ACKs durable lifecycle records without projecting every intermediate state" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution("input-batched-lifecycle", "execution-batched-lifecycle")

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    {event_ids, _last_id} =
      Enum.map_reduce(1..64, records_cache.last_id, fn _index, previous_id ->
        event_id = ULID.generate(previous_id)
        {event_id, event_id}
      end)

    params_list =
      connector_lifecycle_batch(
        capability,
        request.dispatch_id,
        "execution-batched-lifecycle",
        event_ids
      )

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    ConcurrentDelayS3.arm([status_key], 120, :get)
    Application.put_env(:salix_store, :s3_backend, ConcurrentDelayS3)

    on_exit(fn ->
      ConcurrentDelayS3.disarm()
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    ConcurrentDelayS3.disarm()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    # SegmentLog settlement precedes lifecycle projection. Once those records
    # are durable, status projection latency must not turn the whole exact
    # Session partition into owner_unavailable/retry responses.
    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    durable_ids = MapSet.new(records, & &1["id"])
    assert Enum.all?(event_ids, &MapSet.member?(durable_ids, &1))

    latest_event_id = List.last(event_ids)

    assert eventually(
             fn ->
               match?(
                 {:ok,
                  %{
                    "status" => "idle",
                    "source_work_state" => "settled",
                    "projection_watermark" => ^latest_event_id
                  }},
                 ExternalSessionStatus.get(agent_id, @session_id)
               )
             end,
             3_000
           )

    assert results == List.duplicate({:ok, %{"ok" => true}}, 64)

    # A lost transport response may replay the same durable batch. Once the
    # latest lifecycle fact is already projected, the replay is pure ACK: it
    # must not rewrite either the authoritative Session state or its derived
    # public status.
    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    :ok = S3.Fake.reset_put_log()

    assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
             request.binding["connector_run_id"],
             params_list,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           ) == List.duplicate({:ok, %{"ok" => true}}, 64)

    refute state_key in S3.Fake.put_log()
    refute status_key in S3.Fake.put_log()
  end

  test "Connector batch retries only the effective unresolved lifecycle projection" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution(
        "input-unresolved-lifecycle",
        "execution-unresolved-lifecycle"
      )

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    {event_ids, _last_id} =
      Enum.map_reduce(1..4, records_cache.last_id, fn _index, previous_id ->
        event_id = ULID.generate(previous_id)
        {event_id, event_id}
      end)

    params_list =
      connector_lifecycle_batch(
        capability,
        request.dispatch_id,
        "execution-unresolved-lifecycle",
        event_ids
      )

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    :ok = S3.Fake.clear_blackhole()

    # Every runtime event was durable before the transient projection outage
    # was reported. Only the final lifecycle fact remains unresolved; its
    # siblings are subsumed and must not be replayed.
    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    durable_ids = MapSet.new(records, & &1["id"])
    assert Enum.all?(event_ids, &MapSet.member?(durable_ids, &1))

    assert [{:ok, %{"ok" => true}}] =
             SalixAgent.ExternalAgentRuntime.handle_connector_events(
               request.binding["connector_run_id"],
               [List.last(params_list)],
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )

    latest_event_id = List.last(event_ids)

    assert {:ok,
            %{
              "status" => "idle",
              "source_work_state" => "settled",
              "projection_watermark" => ^latest_event_id
            }} = ExternalSessionStatus.get(agent_id, @session_id)

    assert Enum.drop(results, -1) == List.duplicate({:ok, %{"ok" => true}}, 3)
    assert match?({:error, _retryable}, List.last(results))
  end

  test "Connector status read failure retains the lifecycle event for the current execution" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution(
        "input-status-read-failure",
        "execution-current-read-failure"
      )

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)
    current_event_id = ULID.generate(records_cache.last_id)
    other_event_id = ULID.generate(current_event_id)
    timestamp = System.system_time(:second)

    params_list = [
      %{
        "capability_token" => capability["token"],
        "event_id" => current_event_id,
        "event" =>
          lifecycle(request.dispatch_id, "execution-current-read-failure", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => other_event_id,
        "event" =>
          lifecycle(request.dispatch_id, "execution-other-read-failure", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 1
          })
      }
    ]

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)

    # Existing v2 Session state written before execution-exact targets were
    # persisted has a durable watermark but no execution_id. Preserve that
    # production upgrade shape so the bounded exact-record recovery path is
    # exercised even though fresh writes now carry the identity directly.
    assert {:ok, %{body: body, etag: etag}} = S3.get(state_key)
    assert {:ok, legacy_state} = Jason.decode(body)

    legacy_state =
      update_in(legacy_state, ["status_projection_target"], &Map.delete(&1, "execution_id"))

    assert {:ok, _etag} = S3.put(state_key, Jason.encode!(legacy_state), if_match: etag)

    assert {:ok, state_before_failure} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    refute get_in(state_before_failure, ["status_projection_target", "execution_id"])
    :ok = S3.Fake.blackhole({:fail, 503, :get, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    projection_log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        send(
          self(),
          {:status_read_failure_results,
           SalixAgent.ExternalAgentRuntime.handle_connector_events(
             request.binding["connector_run_id"],
             params_list,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           )}
        )
      end)

    assert_receive {:status_read_failure_results, results}, @receive_budget_ms
    assert projection_log =~ "mapping=projection_read_failed"
    refute projection_log =~ "mapping=other"

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    durable_ids = MapSet.new(records, & &1["id"])
    assert MapSet.member?(durable_ids, current_event_id)
    assert MapSet.member?(durable_ids, other_event_id)

    retry_params =
      params_list
      |> Enum.zip(results)
      |> Enum.flat_map(fn
        {params, {:error, _retryable}} -> [params]
        {_params, {:ok, %{"ok" => true}}} -> []
      end)

    assert length(retry_params) == 1

    assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
             request.binding["connector_run_id"],
             retry_params,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           ) == [{:ok, %{"ok" => true}}]

    assert {:ok,
            %{
              "status" => "idle",
              "source_work_state" => "settled",
              "projection_watermark" => ^current_event_id
            }} = ExternalSessionStatus.get(agent_id, @session_id)
  end

  test "Connector lifecycle coalescing fences a delayed different execution" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution(
        "input-execution-fence",
        "execution-current-fence"
      )

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)
    current_event_id = ULID.generate(records_cache.last_id)
    delayed_event_id = ULID.generate(current_event_id)
    timestamp = System.system_time(:second)

    params_list = [
      %{
        "capability_token" => capability["token"],
        "event_id" => current_event_id,
        "event" =>
          lifecycle(request.dispatch_id, "execution-current-fence", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => delayed_event_id,
        "event" =>
          lifecycle(request.dispatch_id, "execution-delayed-fence", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 1
          })
      }
    ]

    assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
             request.binding["connector_run_id"],
             params_list,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           ) == List.duplicate({:ok, %{"ok" => true}}, 2)

    assert {:ok,
            %{
              "status" => "idle",
              "execution_id" => "execution-current-fence",
              "projection_watermark" => ^current_event_id
            }} = ExternalSessionStatus.get(agent_id, @session_id)
  end

  test "Connector replay preserves ACKs when a later older-segment create fails" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution("input-partial-create", "execution-partial-create")

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    params_list =
      Enum.map(1..64, fn index ->
        event_id = index |> Integer.to_string() |> String.pad_leading(26, "0")

        connector_message(
          capability,
          event_id,
          "partial create #{index}: " <> String.duplicate("x", 16_000)
        )
      end)

    assert List.last(params_list)["event_id"] < List.first(records_cache.segments).first

    # The first create lands; the next affected segment's create fails. Results
    # must retain ACKs for the records already durable in the first segment.
    :ok = S3.Fake.set_fault({:delay, 0, :put, :any})
    :ok = S3.Fake.set_fault({:fail, 503, :put, :any})

    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    assert Enum.any?(results, &match?({:ok, %{"ok" => true}}, &1))
    assert Enum.any?(results, &match?({:error, _}, &1))

    accepted_ids =
      params_list
      |> Enum.zip(results)
      |> Enum.flat_map(fn
        {%{"event_id" => event_id}, {:ok, %{"ok" => true}}} -> [event_id]
        _ -> []
      end)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    durable_ids = MapSet.new(records, & &1["id"])
    assert Enum.all?(accepted_ids, &MapSet.member?(durable_ids, &1))
  end

  test "Connector replay settles disjoint older-segment creates inside the owner deadline" do
    {agent_id, _pid, agent, capability, request} =
      start_running_execution("input-parallel-create", "execution-parallel-create")

    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)

    params_list =
      Enum.map(1..64, fn index ->
        event_id = index |> Integer.to_string() |> String.pad_leading(26, "0")

        connector_message(
          capability,
          event_id,
          "parallel create #{index}: " <> String.duplicate("x", 16_000)
        )
      end)

    assert List.last(params_list)["event_id"] < List.first(records_cache.segments).first

    segment_prefix = Keys.agent_external_runtime_session_segments_prefix(agent_id, @session_id)
    possible_segment_keys = Enum.map(params_list, &(segment_prefix <> &1["event_id"] <> ".jsonl"))

    ConcurrentDelayS3.arm(possible_segment_keys, 1_900, :put)
    Application.put_env(:salix_store, :s3_backend, ConcurrentDelayS3)

    on_exit(fn ->
      ConcurrentDelayS3.disarm()
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        request.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    max_segment_concurrency = ConcurrentDelayS3.max_concurrency()
    ConcurrentDelayS3.disarm()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    assert results == List.duplicate({:ok, %{"ok" => true}}, 64)
    assert max_segment_concurrency == 2
  end

  test "a blocked external Session owner does not prevent another Session in the same Connector batch from committing" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "worker",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "test-device",
          "runtime_id" => "test-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

    slow_session_id = SalixStore.Ids.new_session_id()
    fast_session_id = SalixStore.Ids.new_session_id()

    {slow_pid, slow_capability, slow_request} =
      start_running_session(agent_id, slow_session_id, "slow")

    {_fast_pid, fast_capability, fast_request} =
      start_running_session(agent_id, fast_session_id, "fast")

    slow_event_id = next_record_id(agent_id, slow_session_id)
    fast_event_id = next_record_id(agent_id, fast_session_id)

    params = [
      connector_message(slow_capability, slow_event_id, "slow-owner-event"),
      connector_message(fast_capability, fast_event_id, "independent-session-event")
    ]

    :ok = :sys.suspend(slow_pid)

    task =
      Task.async(fn ->
        SalixAgent.ExternalAgentRuntime.handle_connector_events(
          slow_request.binding["connector_run_id"],
          params,
          %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
        )
      end)

    try do
      assert eventually(fn ->
               case ExternalSessionStore.session_records(
                      agent,
                      fast_session_id,
                      limit: 100
                    ) do
                 {:ok, %{"records" => records}} ->
                   Enum.any?(records, &(&1["id"] == fast_event_id))

                 _ ->
                   false
               end
             end),
             "a blocked Session owner prevented an independent Session from committing"
    after
      :ok = :sys.resume(slow_pid)
      assert [{:ok, %{"ok" => true}}, {:ok, %{"ok" => true}}] = Task.await(task, 5_000)
    end

    assert slow_request.binding["connector_run_id"] ==
             fast_request.binding["connector_run_id"]

    timed_out_slow_event_id = next_record_id(agent_id, slow_session_id)
    independently_settled_event_id = next_record_id(agent_id, fast_session_id)
    :ok = :sys.suspend(slow_pid)

    timeout_results =
      try do
        SalixAgent.ExternalAgentRuntime.handle_connector_events(
          slow_request.binding["connector_run_id"],
          [
            connector_message(
              slow_capability,
              timed_out_slow_event_id,
              "timed-out-owner-event"
            ),
            connector_message(
              fast_capability,
              independently_settled_event_id,
              "independently-settled-event"
            )
          ],
          %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
        )
      after
        :ok = :sys.resume(slow_pid)
      end

    assert [{:error, _retryable}, {:ok, %{"ok" => true}}] = timeout_results

    assert {:ok, %{"records" => fast_records}} =
             ExternalSessionStore.session_records(agent, fast_session_id, limit: 100)

    assert Enum.any?(fast_records, &(&1["id"] == independently_settled_event_id))
  end

  test "starting expires to unknown and matching late evidence can recover it" do
    {agent_id, pid, agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-late", "pending", no_wake: true)

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-late",
               "test-connector-run",
               timestamp - 31
             )

    assert {:ok,
            %{
              "status" => "unknown",
              "issue" => "native_start_unconfirmed"
            }} = ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               %{
                 "dispatch_id" => "dispatch-late",
                 "execution_id" => "execution-late",
                 "work_state" => "running"
               },
               ULID.generate(),
               "test-connector-run"
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "starting deadline invalidates exact-session activity subscribers" do
    previous_timeout =
      Application.get_env(:salix_agent, :external_runtime_starting_timeout_seconds)

    Application.put_env(:salix_agent, :external_runtime_starting_timeout_seconds, 1)

    on_exit(fn ->
      restore_env(:external_runtime_starting_timeout_seconds, previous_timeout)
    end)

    {_agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-starting-deadline", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_activity_updated, @session_id}
    })

    assert_receive {:notification_blocked, notifier_pid, ref, _agent_id,
                    {:session_activity_updated, @session_id}},
                   @receive_budget_ms

    assert {:ok,
            %{
              "state" => "error",
              "issue" => "native_start_unconfirmed"
            }} = SalixAgent.Runtime.get_session_activity(agent, @session_id)

    send(notifier_pid, {:release_notification, ref})
    :persistent_term.erase(@blocked_notification_key)
    send(runtime_pid, {:runtime_return, accepted(request, %{})})
  end

  test "starting deadline does not invalidate a lifecycle that already advanced" do
    previous_timeout =
      Application.get_env(:salix_agent, :external_runtime_starting_timeout_seconds)

    Application.put_env(:salix_agent, :external_runtime_starting_timeout_seconds, 1)

    on_exit(fn ->
      restore_env(:external_runtime_starting_timeout_seconds, previous_timeout)
    end)

    {_agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-starting-advanced", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               %{
                 "connector_run_id" => request.binding["connector_run_id"],
                 "event" =>
                   lifecycle(request.dispatch_id, "execution-starting-advanced", "running")
               }
             )

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_activity_updated, @session_id}
    })

    refute_receive {:notification_blocked, _notifier_pid, _ref, _agent_id,
                    {:session_activity_updated, @session_id}},
                   1_500

    :persistent_term.erase(@blocked_notification_key)
    send(runtime_pid, {:runtime_return, accepted(request, %{})})
  end

  test "native running evidence may arrive before message acceptance" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-event-first", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               %{
                 "connector_run_id" => request.binding["connector_run_id"],
                 "event" =>
                   lifecycle(request.dispatch_id, "execution-event-first", "running")
                   |> Map.merge(%{
                     "type" => "status",
                     "provider" => "codex",
                     "name" => "turn/started"
                   })
               }
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert [%{"content" => "run"}] = queue(agent_id)

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => request.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "connector event validation preserves transient capability and session lookup failures" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-capability-lookup", "seed", no_wake: true)

    assert {:ok, binding} =
             ExternalSessionActor.begin_session(
               pid,
               agent["tenant_id"],
               agent["runtime_config"]
             )

    capability = binding["runtime_capability"]
    token = capability["token"]
    capability_key = Keys.ctl_runtime_capability(capability["token_hash"])

    assert {:ok, persisted_capability} =
             ExternalSessionStore.validate_runtime_capability(token)

    assert {:error, :stale_connector_transport_generation} =
             ExternalSessionStore.validate_runtime_capability_scope(
               persisted_capability,
               binding["connector_run_id"] <> "-reconnected",
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )

    assert :ok = S3.Fake.set_fault({:fail, 503, :get, capability_key})

    assert {:error, {:capability_lookup_failed, {:http, 503}}} =
             ExternalSessionStore.validate_runtime_capability(token)

    session_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    assert :ok = S3.Fake.set_fault({:fail, 503, :get, session_key})

    assert {:error, {:external_session_lookup_failed, {:http, 503}}} =
             ExternalSessionStore.validate_connector_event(
               binding["connector_run_id"],
               %{
                 "capability_token" => token,
                 "event_id" => ULID.generate(),
                 "event" => %{
                   "created_at" => System.system_time(:second),
                   "provider" => "codex",
                   "type" => "status",
                   "state" => "running"
                 }
               },
               %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
             )
  end

  test "duplicate event retries a missing projection without rolling back newer lifecycle" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-projection-failure", "run")
    assert_receive {:runtime_request, _runtime_pid, request}, @receive_budget_ms

    # `created_at` is pinned exactly as the connector pins it
    # (`forwardRuntimeExecutionEvent` stamps it once, before enqueue, so a
    # reconnect replays the same value). Without it the store falls back to
    # `now()` at SECOND granularity, which lands in the runtime-event identity
    # comparison — the replay below would settle as a duplicate only while
    # both commits happen inside the same wall-clock second, and conflict
    # otherwise. That is the second mechanism behind #866: on a loaded runner
    # the retry slipped into the next second and the test failed with
    # `:external_session_record_conflict`.
    params = %{
      "event_id" => ULID.generate(),
      "connector_run_id" => request.binding["connector_run_id"],
      "event" =>
        lifecycle(request.dispatch_id, "execution-projection-failure", "running")
        |> Map.merge(%{
          "type" => "status",
          "provider" => "codex",
          "name" => "turn/started",
          "created_at" => 1_750_000_000
        })
    }

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, {:http, 503}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               params
             )

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               params
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    settled_event_id = ULID.generate(params["event_id"])

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               %{
                 "event_id" => settled_event_id,
                 "connector_run_id" => request.binding["connector_run_id"],
                 "event" =>
                   lifecycle(
                     request.dispatch_id,
                     "execution-projection-failure",
                     "settled"
                   )
               }
             )

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               Map.put(params, "connector_run_id", "test-connector-run-2")
             )

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  # The boundary the test above depends on, asserted on purpose instead of
  # left to timing: `connector_run_id` is excluded from the runtime-event
  # identity comparison so a reconnect replay dedupes, but every other field
  # still counts — `created_at` included. A caller that lets the server stamp
  # it (omits it from the event) therefore gets a conflict on replay rather
  # than a duplicate. No production caller does: the Go connector stamps
  # `created_at` once at enqueue and replays carry it. If that ever changes,
  # this test is the one that says what is being traded away.
  test "a same-id runtime event with a different created_at is a conflict, not a duplicate" do
    {_agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-created-at-identity", "run")
    assert_receive {:runtime_request, _runtime_pid, request}, @receive_budget_ms

    capability = request.binding["runtime_capability"]
    event_id = ULID.generate()

    event = fn created_at ->
      %{
        "event_id" => event_id,
        "connector_run_id" => request.binding["connector_run_id"],
        "event" =>
          lifecycle(request.dispatch_id, "execution-created-at-identity", "running")
          |> Map.merge(%{
            "type" => "status",
            "provider" => "codex",
            "name" => "turn/started",
            "created_at" => created_at
          })
      }
    end

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, event.(1_750_000_000))

    # Same id, same everything else, replayed under a new connector run: a
    # duplicate, because connector_run_id is excluded from the comparison.
    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               capability,
               Map.put(event.(1_750_000_000), "connector_run_id", "test-connector-run-2")
             )

    # Same id, one second later: not the same record.
    assert {:error, :external_session_record_conflict} =
             ExternalSessionActor.commit_connector_event(pid, capability, event.(1_750_000_001))
  end

  test "matching lifecycle recovers after the starting projection write fails" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-start-failure-seed", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, :committed} = stage(pid, "input-start-failure", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    :ok = S3.Fake.clear_blackhole()

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => request.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(
               pid,
               request.binding["runtime_capability"],
               %{
                 "connector_run_id" => request.binding["connector_run_id"],
                 "event" => lifecycle(request.dispatch_id, "execution-start-failure", "running")
               }
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "matching dispatch failure recovers after the starting projection write fails" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-start-error-seed", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, :committed} = stage(pid, "input-start-error", "run")
    assert_receive {:runtime_request, runtime_pid, _request}, @receive_budget_ms
    :ok = S3.Fake.clear_blackhole()

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_activity_updated, @session_id}
    })

    send(runtime_pid, {:runtime_return, {:error, :native_rejected}})

    assert_receive {:notification_blocked, notifier_pid, ref, ^agent_id,
                    {:session_activity_updated, @session_id}},
                   @receive_budget_ms

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 10)

    assert %{"type" => "session.error"} = List.last(records)

    activity_at_invalidation = SalixAgent.Runtime.get_session_activity(agent, @session_id)
    send(notifier_pid, {:release_notification, ref})
    :persistent_term.erase(@blocked_notification_key)

    assert {:ok, %{"state" => "error", "issue" => "runtime_failed"}} =
             activity_at_invalidation
  end

  test "old dispatch and out-of-order records cannot overwrite current work" do
    {agent_id, pid, _agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-order", "pending", no_wake: true)
    first_record = ULID.generate()
    second_record = ULID.generate(first_record)

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-current",
               "connector-run-current",
               timestamp
             )

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_accepted(
               agent_id,
               @session_id,
               "dispatch-current",
               "execution-current",
               timestamp
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-current", "execution-current", "running"),
               second_record,
               "connector-run-current"
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-current", "execution-current", "settled"),
               first_record,
               "connector-run-current"
             )

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-steer",
               "connector-run-current",
               timestamp + 1
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.dispatch_failed(
               agent_id,
               @session_id,
               "dispatch-steer",
               timestamp + 1
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-current", "execution-current", "settled"),
               ULID.generate(second_record),
               "connector-run-current"
             )

    settled_record = ULID.generate(second_record)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-steer", "execution-current", "settled"),
               settled_record,
               "connector-run-current"
             )

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStatus.dispatch_failed(
               agent_id,
               @session_id,
               "dispatch-steer",
               timestamp + 1
             )

    assert {:ok, %{"status" => "starting", "execution_id" => nil}} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-next",
               "connector-run-current",
               timestamp + 2
             )

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_accepted(
               agent_id,
               @session_id,
               "dispatch-next",
               "execution-next",
               timestamp + 2
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-next", "execution-next", "running"),
               ULID.generate(settled_record),
               "connector-run-current"
             )

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-steer", "execution-current", "settled"),
               ULID.generate(settled_record),
               "connector-run-current"
             )
  end

  test "matching terminal detail is retained and the next dispatch clears it" do
    {agent_id, pid, _agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-detail", "pending", no_wake: true)

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-detail",
               "connector-run-detail",
               timestamp
             )

    assert {:ok,
            %{
              "status" => "failed",
              "issue" => "quota_exhausted",
              "message" => "Codex account usage quota is exhausted."
            }} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-detail", "execution-detail", "failed")
               |> Map.merge(%{
                 "issue" => "quota_exhausted",
                 "message" => "Codex account usage quota is exhausted."
               }),
               ULID.generate(),
               "connector-run-detail"
             )

    assert {:ok, next} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-next",
               "connector-run-detail",
               timestamp + 1
             )

    assert next["status"] == "starting"
    refute Map.has_key?(next, "issue")
    refute Map.has_key?(next, "message")
  end

  test "abandoned recovery terminal event lands as recovery_exhausted through the wire path" do
    {_agent_id, pid, agent, capability, request} =
      start_running_execution("input-recovery-exhausted", "execution-recovery-exhausted")

    # The interruption-time exit lands first with the generic classification —
    # the phase real recovery obligations occupy before abandonment.
    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" =>
                 lifecycle(request.dispatch_id, "execution-recovery-exhausted", "failed")
                 |> Map.merge(%{
                   "type" => "error",
                   "provider" => "codex",
                   "issue" => "runtime_failed",
                   "message" => "Codex runtime execution failed."
                 })
             })

    assert {:ok, %{"status" => "failed", "issue" => "runtime_failed"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    # The later abandonment event must supersede the projected terminal detail.
    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" =>
                 lifecycle(request.dispatch_id, "execution-recovery-exhausted", "failed")
                 |> Map.merge(%{
                   "type" => "error",
                   "provider" => "codex",
                   "issue" => "recovery_exhausted",
                   "message" => "Codex session recovery attempts were exhausted."
                 })
             })

    assert {:ok,
            %{
              "status" => "failed",
              "issue" => "recovery_exhausted",
              "message" => "Codex session recovery attempts were exhausted."
            }} = ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, %{"state" => "error", "issue" => "recovery_exhausted"}} =
             SalixAgent.Runtime.get_session_activity(agent, @session_id)
  end

  test "only durable wait changes idle session to waiting" do
    {agent_id, pid, _agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-wait", "pending", no_wake: true)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "async_tool_call", "status" => "running"}],
               timestamp
             )

    assert {:ok, %{"status" => "waiting"}} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_set", "wait" => %{"reason" => "user_input"}}],
               timestamp + 1
             )

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_clear"}],
               timestamp + 2
             )
  end

  test "stale wait projections cannot overwrite a newer wait transition" do
    {agent_id, pid, _agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-wait-watermark", "pending", no_wake: true)

    set_watermark = ULID.generate()
    clear_watermark = ULID.generate(set_watermark)
    replacement_watermark = ULID.generate(clear_watermark)

    assert {:ok,
            %{
              "status" => "waiting",
              "wait" => %{"reason" => "old wait"},
              "wait_projection_watermark" => ^set_watermark
            }} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_set", "wait" => %{"reason" => "old wait"}}],
               timestamp,
               set_watermark
             )

    assert {:ok,
            %{
              "status" => "idle",
              "wait" => nil,
              "wait_projection_watermark" => ^clear_watermark
            }} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_clear"}],
               timestamp + 1,
               clear_watermark
             )

    assert {:ok,
            %{
              "status" => "idle",
              "wait" => nil,
              "wait_projection_watermark" => ^clear_watermark
            }} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_set", "wait" => %{"reason" => "stale replay"}}],
               timestamp,
               set_watermark
             )

    assert {:ok,
            %{
              "status" => "waiting",
              "wait" => %{"reason" => "replacement wait"},
              "wait_projection_watermark" => ^replacement_watermark
            }} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_set", "wait" => %{"reason" => "replacement wait"}}],
               timestamp + 2,
               replacement_watermark
             )

    assert {:ok,
            %{
              "status" => "waiting",
              "wait" => %{"reason" => "replacement wait"},
              "wait_projection_watermark" => ^replacement_watermark
            }} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_clear"}],
               timestamp + 1,
               clear_watermark
             )
  end

  test "external async completion clears the durable and projected auto wait" do
    {agent_id, pid, agent} = start_external_session()
    call_id = "external-completion-clears-wait"

    assert {:ok, :committed} =
             stage(pid, "external-completion-wait-seed", "pending", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => "local.background",
                 "status" => "running",
                 "started_at" => System.system_time(:millisecond)
               },
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" =>
                   Waits.build("tool is running", 20, "auto_wait", %{
                     "tool_call_id" => call_id
                   })
               }
             ])

    assert {:ok, %{"status" => "waiting"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    events =
      AsyncToolResults.external_events(
        %{session_id: @session_id, tool_call_id: call_id, tool_name: "local.background"},
        %{id: call_id, content: "finished", error: false, status: "completed"}
      )

    assert Enum.map(events, & &1["type"]) == [
             "async_tool_call_completed",
             "wait_clear",
             "delivery"
           ]

    assert {:ok, %{"wait" => nil}} =
             ExternalSessionActor.commit_session_events(pid, events)

    assert {:ok, %{"status" => "idle"} = status} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    refute Map.has_key?(status, "wait")

    assert {:ok, %{"status" => "completed"}} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)
  end

  test "external callback handoff clears projected setup wait and keeps exact call running" do
    {agent_id, pid, agent} = start_external_session()
    call_id = "external-handoff-clears-wait"

    assert {:ok, :committed} =
             stage(pid, "external-handoff-wait-seed", "pending", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => "permission.request",
                 "status" => "running",
                 "started_at" => System.system_time(:millisecond)
               },
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" =>
                   Waits.build("tool setup is running", 20, "auto_wait", %{
                     "tool_call_id" => call_id
                   })
               }
             ])

    pending = %{
      session_id: @session_id,
      tool_call_id: call_id,
      tool_name: "permission.request"
    }

    callback_wait =
      Waits.build("approval is pending", 120, "auto_wait", %{"tool_call_id" => call_id})

    result = %{
      id: call_id,
      name: "permission.request",
      status: "async_running",
      content: "approval URL: https://example.test/approve",
      error: false,
      events: [
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session_id,
          "tool_call_id" => call_id,
          "tool_name" => "permission.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "started_at" => System.system_time(:millisecond)
        },
        Waits.event(@session_id, callback_wait)
      ]
    }

    assert {:ok, events, _observed_result} =
             SessionToolExecution.commit_async(
               agent_id,
               @session_id,
               :external,
               pending,
               result
             )

    assert Enum.map(events, & &1["type"]) == [
             "async_tool_call_started",
             "wait_set",
             "wait_clear",
             "delivery"
           ]

    assert %{
             "runtime_message_type" => "tool_call_handoff",
             "source_tool_call_id" => ^call_id
           } = List.last(events)

    assert {:ok, %{"wait" => nil}} =
             ExternalSessionActor.commit_session_events(pid, events)

    assert {:ok, %{"status" => "idle"} = status} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    refute Map.has_key?(status, "wait")

    assert {:ok,
            %{
              "status" => "running",
              "completion_mode" => "external_callback"
            }} = ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)
  end

  test "callback terminal wins when process-local setup returns a late callback handoff" do
    previous_tenant_limit =
      Application.get_env(:salix_agent, :dependency_max_children_per_tenant)

    Application.put_env(:salix_agent, :dependency_max_children_per_tenant, 4)

    on_exit(fn ->
      restore_env(:dependency_max_children_per_tenant, previous_tenant_limit)
    end)

    {agent_id, pid, agent} = start_external_session()
    call_id = "external-callback-terminal-before-handoff"
    tool_name = "permission.request"
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(agent_id)

    assert {:ok, :committed} =
             stage(pid, "external-callback-race-seed", "pending", no_wake: true)

    setup_wait =
      Waits.build("tool setup is running", 20, "auto_wait", %{"tool_call_id" => call_id})

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => tool_name,
                 "status" => "running",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               },
               Waits.event(@session_id, setup_wait)
             ])

    callback_wait =
      Waits.build("approval is pending", 120, "auto_wait", %{"tool_call_id" => call_id})

    late_handoff = callback_handoff(call_id, tool_name, callback_wait)

    exact_jobs =
      for _message_kind <- [:result, :timeout, :down] do
        {job, dependency_pid, ^late_handoff} =
          install_external_dependency_pending(pid, agent_id, call_id, tool_name, late_handoff)

        %{job: job, pid: dependency_pid, monitor: Process.monitor(dependency_pid)}
      end

    unrelated_call_id = "external-callback-unrelated-owner"
    unrelated_tool_name = "unrelated.background"
    unrelated_handoff = callback_handoff(unrelated_call_id, unrelated_tool_name)

    {unrelated_job, unrelated_pid, ^unrelated_handoff} =
      install_external_dependency_pending(
        pid,
        agent_id,
        unrelated_call_id,
        unrelated_tool_name,
        unrelated_handoff
      )

    unrelated_monitor = Process.monitor(unrelated_pid)
    retained_ref = make_ref()
    unrelated_retained_ref = make_ref()

    retained_pending = %{
      session_id: @session_id,
      tool_call_id: call_id,
      tool_name: tool_name
    }

    unrelated_retained_pending = %{
      session_id: @session_id,
      tool_call_id: unrelated_call_id,
      tool_name: unrelated_tool_name
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | pending_external: %{test_hold: true},
          pending_async_tool_commits:
            state.pending_async_tool_commits
            |> Map.put(retained_ref, %{
              pending: retained_pending,
              result: late_handoff
            })
            |> Map.put(unrelated_retained_ref, %{
              pending: unrelated_retained_pending,
              result: unrelated_handoff
            })
      }
    end)

    on_exit(fn ->
      Enum.each(exact_jobs, fn %{job: job, pid: child, monitor: monitor} ->
        :ok = DependencyJob.cancel(job)
        if Process.alive?(child), do: Process.exit(child, :kill)
        Process.demonitor(monitor, [:flush])
      end)

      :ok = DependencyJob.cancel(unrelated_job)
      if Process.alive?(unrelated_pid), do: Process.exit(unrelated_pid, :kill)
      Process.demonitor(unrelated_monitor, [:flush])
    end)

    terminal_result = %{
      "content" => "permission approved",
      "output" => "permission approved",
      "status" => "completed",
      "error" => false
    }

    assert {:ok, %{"status" => "completed", "tool_call_id" => ^call_id}} =
             ExternalSessionActor.complete_async_tool_call(
               pid,
               call_id,
               terminal_result,
               %{"tool_name" => tool_name}
             )

    assert {:ok, %{"status" => "completed"} = terminal} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

    assert {:ok, %{"records" => records_before_handoff}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    wait_sets_before_handoff =
      Enum.count(records_before_handoff, fn record ->
        record["type"] == "session.wait_set" and
          get_in(record, ["data", "wait", "tool_call_id"]) == call_id
      end)

    state_after_callback = :sys.get_state(pid)
    exact_tokens = Enum.map(exact_jobs, & &1.job.token)

    assert Enum.all?(
             exact_tokens,
             &(not Map.has_key?(state_after_callback.pending_async_tools, &1))
           )

    refute Map.has_key?(state_after_callback.pending_async_tool_commits, retained_ref)

    assert Map.has_key?(state_after_callback.pending_async_tools, unrelated_job.token)
    assert Map.has_key?(state_after_callback.pending_async_tool_commits, unrelated_retained_ref)

    unrelated_pending = state_after_callback.pending_async_tools[unrelated_job.token]

    unrelated_retained =
      state_after_callback.pending_async_tool_commits[unrelated_retained_ref]

    Enum.each(exact_jobs, fn %{pid: child, monitor: monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, @receive_budget_ms
    end)

    refute_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated_pid, _reason}, 50

    replacements =
      for _slot <- 1..3 do
        assert {:ok, replacement} =
                 DependencyJob.start(
                   :tool,
                   tenant_id,
                   fn -> Process.sleep(:infinity) end,
                   timeout_ms: 60_000
                 )

        replacement
      end

    on_exit(fn -> Enum.each(replacements, &DependencyJob.cancel/1) end)

    assert {:error, :dependency_saturated} =
             DependencyJob.start(
               :tool,
               tenant_id,
               fn -> :unexpected_admission end,
               timeout_ms: 60_000
             )

    assert {:ok, state_before_stale} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert {:ok, %{"records" => records_before_stale}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    [result_job, timeout_job, down_job] = exact_jobs

    send(pid, {:dependency_job_result, result_job.job.token, late_handoff})
    send(pid, {:dependency_job_timeout, timeout_job.job.token})
    send(pid, {:dependency_job_down, down_job.job.token, :stale_dependency_exit})
    send(pid, {:retry_async_tool_commit, retained_ref, 1})

    state_after_stale_messages = :sys.get_state(pid)

    assert {:ok, after_late_handoff} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

    assert after_late_handoff == terminal

    assert {:ok, state_after_stale} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert state_after_stale == state_before_stale
    assert state_after_stale["wait"] == nil

    assert Enum.count(state_after_stale["input_message_queue"], fn entry ->
             entry["type"] == "tool_call_completed" and
               entry["source_tool_call_id"] == call_id
           end) == 1

    refute Enum.any?(state_after_stale["input_message_queue"], fn entry ->
             entry["type"] == "tool_call_handoff" and
               entry["source_tool_call_id"] == call_id
           end)

    assert {:ok, %{"records" => records_after_handoff}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    assert records_after_handoff == records_before_stale

    assert Enum.count(records_after_handoff, fn record ->
             record["type"] == "session.wait_set" and
               get_in(record, ["data", "wait", "tool_call_id"]) == call_id
           end) == wait_sets_before_handoff

    refute Enum.any?(records_after_handoff, fn record ->
             record["type"] == "session.async_tool_call_started" and
               get_in(record, ["data", "tool_call_id"]) == call_id and
               get_in(record, ["data", "completion_mode"]) == "external_callback"
           end)

    assert Enum.all?(exact_tokens, fn token ->
             not Map.has_key?(state_after_stale_messages.pending_async_tools, token)
           end)

    refute Map.has_key?(state_after_stale_messages.pending_async_tool_commits, retained_ref)

    assert state_after_stale_messages.pending_async_tools[unrelated_job.token] ==
             unrelated_pending

    assert state_after_stale_messages.pending_async_tool_commits[unrelated_retained_ref] ==
             unrelated_retained
  end

  test "an already-resolved callback idempotently revokes exact external owners" do
    {agent_id, pid, agent} = start_external_session()
    call_id = "external-already-resolved-owner"
    tool_name = "permission.request"

    assert {:ok, :committed} =
             stage(pid, "external-already-resolved-seed", "pending", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => tool_name,
                 "status" => "running",
                 "completion_mode" => "process_local",
                 "started_at" => 100
               },
               %{
                 "type" => "async_tool_call_completed",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "result" => %{"content" => "already complete"},
                 "error" => false,
                 "completed_at" => 200
               }
             ])

    late_handoff = callback_handoff(call_id, tool_name)

    {job, dependency_pid, ^late_handoff} =
      install_external_dependency_pending(pid, agent_id, call_id, tool_name, late_handoff)

    dependency_ref = Process.monitor(dependency_pid)
    retained_ref = make_ref()

    retained_pending = %{
      session_id: @session_id,
      tool_call_id: call_id,
      tool_name: tool_name
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | pending_external: %{test_hold: true},
          pending_async_tool_commits:
            Map.put(state.pending_async_tool_commits, retained_ref, %{
              pending: retained_pending,
              result: late_handoff
            })
      }
    end)

    on_exit(fn ->
      :ok = DependencyJob.cancel(job)
      if Process.alive?(dependency_pid), do: Process.exit(dependency_pid, :kill)
      Process.demonitor(dependency_ref, [:flush])
    end)

    duplicate_result = %{
      "content" => "duplicate callback",
      "output" => "duplicate callback",
      "status" => "completed",
      "error" => false
    }

    assert {:ok, %{"status" => "resolved", "tool_call_id" => ^call_id}} =
             ExternalSessionActor.complete_async_tool_call(
               pid,
               call_id,
               duplicate_result,
               %{"tool_name" => tool_name}
             )

    state_after_first_duplicate = :sys.get_state(pid)
    refute Map.has_key?(state_after_first_duplicate.pending_async_tools, job.token)
    refute Map.has_key?(state_after_first_duplicate.pending_async_tool_commits, retained_ref)

    assert_receive {:DOWN, ^dependency_ref, :process, ^dependency_pid, _reason},
                   @receive_budget_ms

    assert {:ok, terminal_before_stale} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

    assert {:ok, state_before_stale} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert {:ok, %{"records" => records_before_stale}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    assert {:ok, %{"status" => "resolved", "tool_call_id" => ^call_id}} =
             ExternalSessionActor.complete_async_tool_call(
               pid,
               call_id,
               duplicate_result,
               %{"tool_name" => tool_name}
             )

    send(pid, {:dependency_job_result, job.token, late_handoff})
    send(pid, {:dependency_job_timeout, job.token})
    send(pid, {:dependency_job_down, job.token, :stale_dependency_exit})
    send(pid, {:retry_async_tool_commit, retained_ref, 1})
    state_after_stale_messages = :sys.get_state(pid)

    assert state_after_stale_messages.pending_async_tools ==
             state_after_first_duplicate.pending_async_tools

    assert state_after_stale_messages.pending_async_tool_commits ==
             state_after_first_duplicate.pending_async_tool_commits

    assert {:ok, ^terminal_before_stale} =
             ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

    assert {:ok, ^state_before_stale} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert {:ok, %{"records" => ^records_before_stale}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)
  end

  test "a legitimate surface handoff keeps its process-local external owner" do
    {agent_id, pid, _agent} = start_external_session()
    call_id = "external-running-surface-handoff-owner"
    tool_name = "permission.request"

    assert {:ok, :committed} =
             stage(pid, "external-running-handoff-seed", "pending", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => tool_name,
                 "status" => "running",
                 "completion_mode" => "process_local",
                 "started_at" => 100
               }
             ])

    callback_wait =
      Waits.build("approval is pending", 120, "auto_wait", %{"tool_call_id" => call_id})

    handoff = callback_handoff(call_id, tool_name, callback_wait)

    {job, dependency_pid, ^handoff} =
      install_external_dependency_pending(pid, agent_id, call_id, tool_name, handoff)

    dependency_ref = Process.monitor(dependency_pid)

    :sys.replace_state(pid, fn state ->
      %{state | pending_external: %{test_hold: true}}
    end)

    on_exit(fn ->
      :ok = DependencyJob.cancel(job)
      if Process.alive?(dependency_pid), do: Process.exit(dependency_pid, :kill)
      Process.demonitor(dependency_ref, [:flush])
    end)

    assert {:ok, %{"status" => "running", "tool_call_id" => ^call_id}} =
             ExternalSessionActor.complete_async_tool_call(
               pid,
               call_id,
               handoff,
               %{"tool_name" => tool_name}
             )

    actor_state = :sys.get_state(pid)
    assert Map.has_key?(actor_state.pending_async_tools, job.token)
    refute_receive {:DOWN, ^dependency_ref, :process, ^dependency_pid, _reason}, 100

    assert {:ok,
            %{
              "status" => "running",
              "completion_mode" => "external_callback"
            }} = ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)
  end

  test "late starts cannot overwrite completed failed or cancelled external tool calls" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "external-terminal-monotonicity-seed", "pending", no_wake: true)

    terminal_cases = [
      {"completed", "async_tool_call_completed",
       %{
         "result" => %{"content" => "completed result"},
         "error" => false,
         "completed_at" => 101
       }},
      {"failed", "async_tool_call_failed",
       %{
         "result" => %{"content" => "failed result"},
         "error" => true,
         "error_class" => "permission_denied",
         "error_message" => "permission denied",
         "completed_at" => 202
       }},
      {"cancelled", "async_tool_call_cancelled",
       %{"cancel_reason" => "user cancelled", "cancelled_at" => 303}}
    ]

    Enum.each(terminal_cases, fn {status, event_type, terminal_fields} ->
      call_id = "external-terminal-monotonicity-#{status}"

      assert {:ok, _state} =
               ExternalSessionActor.commit_session_events(pid, [
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => @session_id,
                   "tool_call_id" => call_id,
                   "tool_name" => "permission.request",
                   "input" => Jason.encode!(%{"capability" => "host_access"}),
                   "status" => "running",
                   "completion_mode" => "process_local",
                   "started_at" => 100
                 },
                 terminal_fields
                 |> Map.merge(%{
                   "type" => event_type,
                   "session_id" => @session_id,
                   "tool_call_id" => call_id
                 })
               ])

      assert {:ok, %{"status" => ^status} = terminal} =
               ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

      assert {:ok, _state} =
               ExternalSessionActor.commit_session_events(pid, [
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => @session_id,
                   "tool_call_id" => call_id,
                   "tool_name" => "late.replacement",
                   "input" => Jason.encode!(%{"late" => true}),
                   "status" => "running",
                   "completion_mode" => "external_callback",
                   "started_at" => 999,
                   "auto_wait_seconds" => 120
                 }
               ])

      assert {:ok, after_late_start} =
               ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

      assert after_late_start == terminal
    end)
  end

  test "external terminal wait clear rebases after a concurrent settled projection" do
    assert_wait_clear_projection_cas_race(:terminal)
  end

  test "external callback handoff wait clear rebases after a concurrent settled projection" do
    assert_wait_clear_projection_cas_race(:handoff)
  end

  test "durable waits and running async calls produce the right recovery discovery shape" do
    {agent_id, pid, _agent} = start_external_session()
    deadline_ms = System.system_time(:millisecond) + 60_000

    assert {:ok, :committed} =
             stage(pid, "recovery-discovery-seed", "seed external session state", no_wake: true)

    assert {:ok, seed_state, _wait_cas_base} =
             ExternalSessionStore.get_session_record_with_etag(agent_id, @session_id)

    assert {:ok, wait_state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" => %{
                   "wait_id" => "external-wait",
                   "reason" => "wait for external input",
                   "deadline_ms" => deadline_ms
                 }
               }
             ])

    assert ExternalSessionStore.work_reasons(wait_state) == ["wait_deadline"]

    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [wait_discovery], next: nil}} =
             SessionWorkIndex.list_due_discovery(deadline_ms)

    assert wait_discovery["runtime_kind"] == "external"
    assert wait_discovery["base_revision"] == seed_state["storage_revision"]
    refute Map.has_key?(wait_discovery, "cas_base")
    assert wait_discovery["recover_after_ms"] == deadline_ms

    assert {:ok, _wait_state, callback_cas_base} =
             ExternalSessionStore.get_session_record_with_etag(agent_id, @session_id)

    assert {:ok, callback_state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{"type" => "wait_clear", "session_id" => @session_id},
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "external-callback",
                 "tool_name" => "callback.tool",
                 "completion_mode" => "external_callback",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert ExternalSessionStore.work_reasons(callback_state) == [
             "external_callback_tool_call"
           ]

    assert {:ok,
            [
              %{
                "cas_base" => ^callback_cas_base,
                "reasons" => ["external_callback_tool_call"]
              }
            ]} =
             SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

    assert {:ok, _callback_state, _process_local_cas_base} =
             ExternalSessionStore.get_session_record_with_etag(agent_id, @session_id)

    assert {:ok, process_local_state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_completed",
                 "session_id" => @session_id,
                 "tool_call_id" => "external-callback",
                 "completed_at" => System.system_time(:millisecond)
               },
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "process-local",
                 "tool_name" => "local.tool",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert ExternalSessionStore.work_reasons(process_local_state) == [
             "process_local_background_tool_run"
           ]

    assert {:ok, %{records: [process_local_discovery], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert process_local_discovery["runtime_kind"] == "external"
    assert process_local_discovery["base_revision"] == callback_state["storage_revision"]
    refute Map.has_key?(process_local_discovery, "cas_base")
    assert process_local_discovery["recover_after_ms"] == nil
  end

  test "a rejected external state CAS discards only its uncommitted discovery generation" do
    {agent_id, pid, _agent} = start_external_session()
    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)

    assert {:ok, :committed} =
             stage(pid, "rejected-external-seed", "create stable external state", no_wake: true)

    event = %{
      "type" => "async_tool_call_started",
      "session_id" => @session_id,
      "tool_call_id" => "rejected-external-attempt",
      "tool_name" => "local.tool",
      "completion_mode" => "process_local",
      "started_at" => System.system_time(:millisecond)
    }

    PreconditionOnceS3.arm(state_key)
    Application.put_env(:salix_store, :s3_backend, PreconditionOnceS3)

    on_exit(fn ->
      PreconditionOnceS3.disarm()
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    assert {:error, :stale_external_session_state} =
             ExternalSessionActor.commit_session_events(pid, [event])

    assert {:ok,
            [
              %{
                "session_id" => @session_id,
                "reasons" => ["process_local_background_tool_run"]
              }
            ]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, committed} = ExternalSessionActor.commit_session_events(pid, [event])
    live_token = committed["work_index_token"]

    assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [%{"token" => ^live_token}], next: nil}} =
             SessionWorkIndex.list_discovery()
  end

  test "a rejected external state CAS keeps the committed generation's local work index" do
    {agent_id, pid, _agent} = start_external_session()
    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)

    assert {:ok, :committed} =
             stage(pid, "committed-external-seed", "create the external session", no_wake: true)

    committed_event = %{
      "type" => "async_tool_call_started",
      "session_id" => @session_id,
      "tool_call_id" => "committed-eager-generation",
      "tool_name" => "local.tool",
      "completion_mode" => "process_local",
      "started_at" => System.system_time(:millisecond)
    }

    assert {:ok, committed} =
             ExternalSessionActor.commit_session_events(pid, [committed_event])

    live_token = committed["work_index_token"]
    assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [%{"token" => ^live_token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    losing_event = %{committed_event | "tool_call_id" => "losing-attempt"}

    PreconditionOnceS3.arm(state_key)
    Application.put_env(:salix_store, :s3_backend, PreconditionOnceS3)

    on_exit(fn ->
      PreconditionOnceS3.disarm()
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    assert {:error, :stale_external_session_state} =
             ExternalSessionActor.commit_session_events(pid, [losing_event])

    assert {:ok, %{"work_index_token" => ^live_token}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert {:ok, %{records: [%{"token" => ^live_token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert {:ok, [%{"session_id" => @session_id}]} = SessionWorkIndex.list(agent_id)
  end

  test "malformed external waits fail closed before records, state, or discovery change" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "malformed-wait-seed", "seed external session state", no_wake: true)

    assert {:ok, state_before} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert {:ok, %{"records" => records_before}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    invalid_waits = [
      %{"wait_id" => "string-deadline", "deadline_ms" => "1000"},
      %{"wait_id" => "zero-deadline", "deadline_ms" => 0},
      %{"wait_id" => "negative-deadline", "deadline_ms" => -1},
      %{"wait_id" => "nil-deadline", "deadline_ms" => nil}
    ]

    for wait <- invalid_waits do
      assert {:error, :invalid_wait} =
               ExternalSessionActor.commit_session_events(pid, [
                 %{"type" => "wait_set", "session_id" => @session_id, "wait" => wait}
               ])

      assert {:ok, ^state_before} =
               ExternalSessionStore.get_session_record(agent_id, @session_id)

      assert {:ok, %{"records" => ^records_before}} =
               ExternalSessionStore.session_records(agent, @session_id, limit: 100)

      assert {:ok, []} = SessionWorkIndex.list(agent_id)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
    end
  end

  test "external actor restart re-arms a future durable wait without dispatching it" do
    {agent_id, pid, _agent} = start_external_session()
    wait_id = "future-restart-wait"
    deadline_ms = System.system_time(:millisecond) + 60_000
    timer_key = Keys.timer(agent_id, @session_id, wait_id, Timers.minute_bucket(deadline_ms))

    assert {:ok, :committed} =
             stage(pid, "future-restart-seed", "seed external session state", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" => %{
                   "wait_id" => wait_id,
                   "reason" => "stay asleep until the deadline",
                   "deadline_ms" => deadline_ms
                 }
               }
             ])

    assert {:ok, _timer} = S3.get(timer_key)
    assert :ok = S3.delete(timer_key)
    assert {:error, :not_found} = S3.get(timer_key)
    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000
             )

    assert eventually(fn -> match?({:ok, _timer}, S3.get(timer_key)) end)
    refute_receive {:runtime_request, _runtime_pid, _request}, 100
    assert Process.alive?(restarted)
  end

  test "external actor restart materializes one overdue wait notification" do
    {agent_id, pid, _agent} = start_external_session()
    wait_id = "overdue-restart-wait"
    deadline_ms = System.system_time(:millisecond) - 60_000
    timer_key = Keys.timer(agent_id, @session_id, wait_id, Timers.minute_bucket(deadline_ms))
    source_id = "wait-timeout:#{@session_id}:#{wait_id}"

    assert {:ok, :committed} =
             stage(pid, "overdue-restart-seed", "seed external session state", no_wake: true)

    wait = %{
      "wait_id" => wait_id,
      "reason" => "deadline elapsed while the actor was asleep",
      "deadline_ms" => deadline_ms
    }

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{"type" => "wait_set", "session_id" => @session_id, "wait" => wait}
             ])

    assert :ok = S3.delete(timer_key)
    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000
             )

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    wait_messages =
      Enum.filter(request.input_messages, fn message ->
        message["source_message_id"] == source_id and message["type"] == "wait_expired"
      end)

    assert length(wait_messages) == 1

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["wait"] == nil
    assert Enum.count(state["input_message_queue"], &(&1["source_message_id"] == source_id)) == 1

    assert {:ok, delivery} = Waits.timeout_delivery(@session_id, wait)
    assert {:ok, :ignored} = ExternalSessionActor.stage_wait_timeout(restarted, delivery)

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert Enum.count(state["input_message_queue"], &(&1["source_message_id"] == source_id)) == 1

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "external actor restart fails process-local async once and preserves callbacks" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "async-restart-seed", "seed external session state", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "callback-stays-running",
                 "tool_name" => "oauth.wait",
                 "completion_mode" => "external_callback",
                 "started_at" => System.system_time(:millisecond)
               },
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "local-dies-with-actor",
                 "tool_name" => "local.background",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000
             )

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert Enum.count(
             request.input_messages,
             &(&1["source_tool_call_id"] == "local-dies-with-actor")
           ) == 1

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["async_tool_calls"]["callback-stays-running"]["status"] == "running"
    assert state["async_tool_calls"]["local-dies-with-actor"]["status"] == "failed"

    assert state["async_tool_calls"]["local-dies-with-actor"]["error_class"] ==
             "runtime_restarted"

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
    assert :ok = GenServer.stop(restarted, :normal)

    assert {:ok, restarted_again} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000
             )

    refute_receive {:runtime_request, _runtime_pid, _request}, 100

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["async_tool_calls"]["callback-stays-running"]["status"] == "running"
    assert state["async_tool_calls"]["local-dies-with-actor"]["status"] == "failed"
    assert Process.alive?(restarted_again)
  end

  test "external actor retains a process-local terminal across transient session commit failure" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "async-terminal-retry-seed", "seed external session state", no_wake: true)

    # Clear passive-start recovery before the process-local call is installed.
    # Subsequent wakes exercise the live actor rather than restart repair.
    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    assert eventually(fn -> not :sys.get_state(pid).startup_recovery_pending end)

    call_id = "external-terminal-retries"

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => "local.background",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    {job, dependency_pid, result} = install_external_dependency_pending(pid, agent_id, call_id)
    token = job.token
    key = Keys.agent_external_runtime_session(agent_id, @session_id)

    :ok = S3.Fake.set_fault({:fail, 503, :put, key})
    send(pid, {:dependency_job_result, job.token, result})

    state = :sys.get_state(pid)
    assert state.pending_async_tools == %{}

    assert %{^token => %{pending: retained, result: ^result}} =
             state.pending_async_tool_commits

    refute Map.has_key?(retained, :dependency_job)
    refute Map.has_key?(retained, :ref)
    refute Map.has_key?(retained, :pid)

    # A raced actor-owned timeout cannot replace the already accepted result.
    send(pid, {:dependency_job_timeout, job.token})

    assert %{^token => %{result: ^result}} =
             :sys.get_state(pid).pending_async_tool_commits

    # Recovery can keep waking this same live actor while storage is healthy
    # again; the retained result must land without requiring actor restart.
    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)

    assert eventually(
             fn ->
               with {:ok, state} <- ExternalSessionStore.get_session_record(agent_id, @session_id) do
                 get_in(state, ["async_tool_calls", call_id, "status"]) == "completed" and
                   Process.alive?(pid) and :sys.get_state(pid).pending_async_tool_commits == %{}
               else
                 _ -> false
               end
             end,
             2_500
           )

    send(dependency_pid, :release)
  end

  test "first explicit wake repairs process-local async work after passive restart" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "passive-repair-seed", "seed external session state", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "local-dies-before-passive-wake",
                 "tool_name" => "local.background",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000,
               process_on_init: false
             )

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)

    assert eventually(fn ->
             with {:ok, state} <-
                    ExternalSessionStore.get_session_record(agent_id, @session_id) do
               get_in(state, ["async_tool_calls", "local-dies-before-passive-wake", "status"]) ==
                 "failed"
             else
               _ -> false
             end
           end)

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert Enum.count(
             request.input_messages,
             &(&1["source_tool_call_id"] == "local-dies-before-passive-wake")
           ) == 1

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert :ok = GenServer.stop(restarted, :normal)
  end

  test "stage delivery repairs process-local async work before passive dispatch" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "passive-stage-repair-seed", "seed external session state", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "local-dies-before-passive-stage",
                 "tool_name" => "local.background",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000,
               process_on_init: false
             )

    assert {:ok, :committed} =
             stage(restarted, "passive-stage-delivery", "dispatch only after durable repair")

    send(restarted, :process)
    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert Enum.count(
             request.input_messages,
             &(&1["source_tool_call_id"] == "local-dies-before-passive-stage")
           ) == 1

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["async_tool_calls"]["local-dies-before-passive-stage"]["status"] == "failed"

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert :ok = GenServer.stop(restarted, :normal)
  end

  test "passive startup repair retries a transient workspace read instead of fabricating failure" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "passive-repair-retry-seed", "seed external session state", no_wake: true)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "local-repair-read-retries",
                 "tool_name" => "local.background",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000,
               process_on_init: false
             )

    :ok =
      S3.Fake.set_fault({:fail, 503, :get, Keys.agent_workspace_state(agent_id)})

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    refute_receive {:runtime_request, _runtime_pid, _request}, 100

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["async_tool_calls"]["local-repair-read-retries"]["status"] == "running"

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert Enum.count(
             request.input_messages,
             &(&1["source_tool_call_id"] == "local-repair-read-retries")
           ) == 1

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert state["async_tool_calls"]["local-repair-read-retries"]["status"] == "failed"

    assert state["async_tool_calls"]["local-repair-read-retries"]["error_class"] ==
             "runtime_restarted"

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert :ok = GenServer.stop(restarted, :normal)
  end

  test "wait mutations do not masquerade as native progress while running" do
    {agent_id, pid, _agent} = start_external_session()
    timestamp = System.system_time(:second)
    assert {:ok, :committed} = stage(pid, "input-running-wait", "pending", no_wake: true)

    assert {:ok, _status} =
             ExternalSessionStatus.dispatch_started(
               agent_id,
               @session_id,
               "dispatch-running-wait",
               "test-connector-run",
               timestamp
             )

    assert {:ok, %{"status" => "running", "status_updated_at" => ^timestamp}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle("dispatch-running-wait", "execution-running-wait", "running")
               |> Map.put("created_at", timestamp),
               ULID.generate(),
               "test-connector-run"
             )

    assert {:ok, %{"status" => "running", "status_updated_at" => ^timestamp}} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_set", "wait" => %{"reason" => "user_input"}}],
               timestamp + 1
             )

    assert {:ok, %{"status" => "running", "status_updated_at" => ^timestamp}} =
             ExternalSessionStatus.apply_events(
               agent_id,
               @session_id,
               [%{"type" => "wait_clear"}],
               timestamp + 2
             )
  end

  test "connector observation loss invalidates only volatile work" do
    running = %{
      "schema_version" => 1,
      "session_id" => @session_id,
      "status" => "running",
      "work_status" => "running",
      "status_updated_at" => 1,
      "connector_run_id" => "old-run"
    }

    assert %{"status" => "unknown", "issue" => "runtime_observation_lost"} =
             ExternalSessionStatus.public(running, %{
               "status" => "ready",
               "connector_run_id" => "new-run",
               "updated_at" => 2
             })

    idle = %{running | "status" => "idle", "work_status" => "idle"}

    assert %{"status" => "idle"} =
             ExternalSessionStatus.public(idle, %{
               "status" => "disconnected",
               "updated_at" => 3
             })
  end

  test "fresh provider input releases a failed prefix one source at a time" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} =
             stage(pid, "input-failed", "retry me",
               trusted_origin: slack_origin("input-failed", "1788502784.380329")
             )

    assert_receive {:runtime_request, runtime_pid, failed_request}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, {:error, :native_rejected}})

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
               ExternalSessionStore.get_session_status(agent, @session_id)
             )
           end)

    assert [%{"content" => "retry me"}] = queue(agent_id)

    # A recovery wake queued while the failed dependency was in flight must
    # not immediately redispatch the identical queue fence and erase the
    # terminal observation. Fresh durable input changes that full-queue fence,
    # but the retried activation still owns only the first provider source.
    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    refute_receive {:runtime_request, _runtime_pid, _request}, 250

    assert {:ok, :committed} =
             stage(pid, "input-retry", "retry now",
               trusted_origin: slack_origin("input-retry", "1788502784.112249")
             )

    assert_receive {:runtime_request, retry_runtime_pid, retry_request}, @receive_budget_ms
    assert retry_request.dispatch_id == failed_request.dispatch_id
    assert retry_request.input_messages == failed_request.input_messages

    assert retry_request.input_messages
           |> Enum.filter(&(&1["role"] == "user"))
           |> Enum.map(& &1["content"]) == ["retry me"]

    send(retry_runtime_pid, {:runtime_return, accepted(retry_request, %{})})

    assert_receive {:runtime_request, second_runtime_pid, second_request}, @receive_budget_ms
    refute second_request.dispatch_id == failed_request.dispatch_id
    assert [%{"content" => "retry now"}] = queued_inputs(second_request.input_messages)

    send(second_runtime_pid, {:runtime_return, accepted(second_request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "a terminal dispatch stays retryable when its failure record cannot commit" do
    {agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-failure-commit-retry", "retry same batch")
    assert_receive {:runtime_request, runtime_pid, failed_request}, @receive_budget_ms

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, state_key})
    :ok = S3.Fake.reset_put_log()
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    send(runtime_pid, {:runtime_return, {:error, :native_rejected}})

    assert eventually(fn ->
             state = :sys.get_state(pid)
             state_key in S3.Fake.put_log() and is_nil(state.failed_dispatch_id)
           end)

    assert [%{"content" => "retry same batch"}] = queue(agent_id)
    :ok = S3.Fake.clear_blackhole()

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    assert_receive {:runtime_request, retry_runtime_pid, retry_request}, @receive_budget_ms
    assert retry_request.dispatch_id == failed_request.dispatch_id
    assert retry_request.input_messages == failed_request.input_messages
    assert [%{"content" => "retry same batch"}] = queued_inputs(retry_request.input_messages)

    send(retry_runtime_pid, {:runtime_return, accepted(retry_request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "actor restart releases a terminal failed-dispatch fence" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-failed-restart", "retry after restart")
    assert_receive {:runtime_request, runtime_pid, failed_request}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, {:error, :native_rejected}})

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
               ExternalSessionStore.get_session_status(agent, @session_id)
             )
           end)

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    refute_receive {:runtime_request, _runtime_pid, _request}, 250
    assert :ok = GenServer.stop(pid, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: agent_id,
               session_id: @session_id,
               idle_ms: 5_000,
               process_on_init: false
             )

    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    assert_receive {:runtime_request, retry_runtime_pid, retry_request}, @receive_budget_ms
    assert retry_request.dispatch_id == failed_request.dispatch_id
    assert retry_request.input_messages == failed_request.input_messages
    assert [%{"content" => "retry after restart"}] = queued_inputs(retry_request.input_messages)

    send(retry_runtime_pid, {:runtime_return, accepted(retry_request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
    assert :ok = GenServer.stop(restarted, :normal)
  end

  test "a failed steer keeps the observed native execution running and remains dispatchable" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-first", "first")
    assert_receive {:runtime_request, runtime_pid, first}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, accepted(first, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)

    capability = first.binding["runtime_capability"]

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => first.binding["connector_run_id"],
               "event" =>
                 lifecycle(first.dispatch_id, "execution-test", "running")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/started",
                   "state" => "inProgress"
                 })
             })

    assert {:ok, :committed} = stage(pid, "input-steer", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, {:error, :steer_rejected}})

    assert eventually(fn ->
             case ExternalSessionStore.session_records(agent, @session_id, limit: 10) do
               {:ok, %{"records" => records}} ->
                 match?(%{"type" => "session.error"}, List.last(records))

               _other ->
                 false
             end
           end)

    # The error record and native status projection are owned by separate
    # durable objects; observing the append does not make the projection
    # synchronously visible.
    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "running"}},
               ExternalSessionStore.get_session_status(agent, @session_id)
             )
           end)

    assert [%{"content" => "steer"}] = queue(agent_id)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 10)

    assert %{"type" => "session.error", "data" => %{"terminal" => false}} =
             List.last(records)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => first.binding["connector_run_id"],
               "event" =>
                 lifecycle(steer.dispatch_id, "execution-test", "settled")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/completed",
                   "state" => "completed"
                 })
             })

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    # Recovery after the old execution settles must be able to resend the
    # retained steer batch. Only terminal dispatch failures install the
    # actor-local same-batch fence.
    assert :ok = ExternalSessionActor.wake(agent_id, @session_id)
    assert_receive {:runtime_request, retry_runtime_pid, retry_request}, @receive_budget_ms
    assert retry_request.dispatch_id == steer.dispatch_id
    assert [%{"content" => "steer"}] = queued_inputs(retry_request.input_messages)

    send(retry_runtime_pid, {:runtime_return, accepted(retry_request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "a steer accepted as a new execution can publish its terminal lifecycle" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-steer-old", "first")
    assert_receive {:runtime_request, runtime_pid, first}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => first.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    capability = first.binding["runtime_capability"]

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => first.binding["connector_run_id"],
               "event" =>
                 lifecycle(first.dispatch_id, "execution-old", "running")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/started",
                   "state" => "inProgress"
                 })
             })

    assert {:ok, :committed} = stage(pid, "input-steer-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => steer.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => steer.binding["connector_run_id"],
               "event" =>
                 lifecycle(steer.dispatch_id, "execution-new", "settled")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/completed",
                   "state" => "completed"
                 })
             })

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "activity source scope advances with a new dispatch before acceptance" do
    {agent_id, pid, agent, capability, first} =
      start_running_execution("slack-source-old", "execution-source-old")

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => first.binding["connector_run_id"],
               "event" => lifecycle(first.dispatch_id, "execution-source-old", "settled")
             })

    assert {:ok, :committed} = stage(pid, "slack-source-new", "new dispatch")
    assert_receive {:runtime_request, runtime_pid, _request}, @receive_budget_ms

    assert {:ok,
            %{
              "state" => "active",
              "_active_source_message_ids" => ["slack-source-new"]
            }} = SalixAgent.Runtime.get_session_activity(agent, @session_id)

    send(runtime_pid, {:runtime_return, {:error, :test_cleanup}})
    assert eventually(fn -> queue(agent_id) != [] end)
  end

  test "activity source scope advances at an in-flight steer boundary" do
    {agent_id, pid, agent, _capability, _first} =
      start_running_execution("slack-steer-old", "execution-steer-source-old")

    assert {:ok, :committed} = stage(pid, "slack-steer-new", "steer")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    assert {:ok,
            %{
              "state" => "active",
              "_active_source_message_ids" => ["slack-steer-new"]
            }} = SalixAgent.Runtime.get_session_activity(agent, @session_id)

    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"_active_source_message_ids" => ["slack-steer-new"]}} =
             SalixAgent.Runtime.get_session_activity(agent, @session_id)
  end

  test "a new steer execution remains retryable when its first lifecycle status read fails" do
    {agent_id, pid, agent, capability, _first} =
      start_running_execution("input-steer-read-old", "execution-steer-read-old")

    assert {:ok, :committed} = stage(pid, "input-steer-read-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => steer.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)
    event_id = ULID.generate(records_cache.last_id)
    created_at = System.system_time(:second)

    event =
      lifecycle(steer.dispatch_id, "execution-steer-read-new", "settled")
      |> Map.merge(%{
        "type" => "status",
        "provider" => "codex",
        "name" => "turn/completed",
        "state" => "completed",
        "created_at" => created_at
      })

    params = %{
      "capability_token" => capability["token"],
      "event_id" => event_id,
      "event" => event
    }

    meta = %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :get, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, {:http, 503}} =
             ExternalAgentRuntime.handle_connector_event(
               steer.binding["connector_run_id"],
               params,
               meta
             )

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    assert Enum.count(records, &(&1["id"] == event_id)) == 1

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"ok" => true}} =
             ExternalAgentRuntime.handle_connector_event(
               steer.binding["connector_run_id"],
               params,
               meta
             )

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    assert Enum.count(records, &(&1["id"] == event_id)) == 1

    assert {:ok,
            %{
              "status" => "idle",
              "execution_id" => "execution-steer-read-new"
            }} = ExternalSessionStatus.get(agent_id, @session_id)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "a new dispatch installs its first execution before a later foreign lifecycle fact" do
    {agent_id, pid, agent, capability, _first} =
      start_running_execution(
        "input-steer-first-execution-old",
        "execution-steer-first-execution-old"
      )

    assert {:ok, :committed} = stage(pid, "input-steer-first-execution-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => steer.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)
    first_event_id = ULID.generate(records_cache.last_id)
    current_terminal_event_id = ULID.generate(first_event_id)
    delayed_event_id = ULID.generate(current_terminal_event_id)
    timestamp = System.system_time(:second)

    params_list = [
      %{
        "capability_token" => capability["token"],
        "event_id" => first_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-first-execution-new", "running")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/started",
            "state" => "inProgress",
            "created_at" => timestamp
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => current_terminal_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-first-execution-new", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 1
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => delayed_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-delayed-foreign", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 2
          })
      }
    ]

    assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
             steer.binding["connector_run_id"],
             params_list,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           ) == List.duplicate({:ok, %{"ok" => true}}, 3)

    assert {:ok,
            %{
              "status" => "idle",
              "execution_id" => "execution-steer-first-execution-new",
              "projection_watermark" => ^current_terminal_event_id
            }} = ExternalSessionStatus.get(agent_id, @session_id)
  end

  test "a new dispatch status-read failure retries only its first execution's latest fact" do
    {agent_id, pid, agent, capability, _first} =
      start_running_execution(
        "input-steer-read-first-old",
        "execution-steer-read-first-old"
      )

    assert {:ok, :committed} = stage(pid, "input-steer-read-first-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => steer.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    assert {:ok, records_cache} = ExternalSessionRecords.load(agent_id, @session_id)
    first_event_id = ULID.generate(records_cache.last_id)
    foreign_event_id = ULID.generate(first_event_id)
    current_terminal_event_id = ULID.generate(foreign_event_id)
    timestamp = System.system_time(:second)

    params_list = [
      %{
        "capability_token" => capability["token"],
        "event_id" => first_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-read-first-new", "running")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/started",
            "state" => "inProgress",
            "created_at" => timestamp
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => foreign_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-read-foreign", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 1
          })
      },
      %{
        "capability_token" => capability["token"],
        "event_id" => current_terminal_event_id,
        "event" =>
          lifecycle(steer.dispatch_id, "execution-steer-read-first-new", "settled")
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => "turn/completed",
            "state" => "completed",
            "created_at" => timestamp + 2
          })
      }
    ]

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :get, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(
        steer.binding["connector_run_id"],
        params_list,
        %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
      )

    assert {:ok, %{"records" => durable_records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 100)

    durable_ids = MapSet.new(durable_records, & &1["id"])

    assert MapSet.subset?(
             MapSet.new([first_event_id, foreign_event_id, current_terminal_event_id]),
             durable_ids
           )

    :ok = S3.Fake.clear_blackhole()

    retry_params =
      params_list
      |> Enum.zip(results)
      |> Enum.flat_map(fn
        {params, {:error, _retryable}} -> [params]
        {_params, {:ok, %{"ok" => true}}} -> []
      end)

    assert Enum.map(retry_params, & &1["event_id"]) == [current_terminal_event_id]

    assert SalixAgent.ExternalAgentRuntime.handle_connector_events(
             steer.binding["connector_run_id"],
             retry_params,
             %{"tenant_id" => agent["tenant_id"], "group_id" => agent["group_id"]}
           ) == [{:ok, %{"ok" => true}}]

    assert {:ok,
            %{
              "status" => "idle",
              "execution_id" => "execution-steer-read-first-new",
              "projection_watermark" => ^current_terminal_event_id
            }} = ExternalSessionStatus.get(agent_id, @session_id)
  end

  test "a Connector ACK preserves the last observed execution until native lifecycle evidence" do
    {agent_id, pid, agent, _capability, _first} =
      start_running_execution("input-steer-projection-old", "execution-steer-projection-old")

    assert {:ok, :committed} = stage(pid, "input-steer-projection-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => steer.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "connector lifecycle logs distinguish an applied terminal event from a superseded dispatch" do
    {agent_id, pid, agent, capability, request} =
      start_running_execution("input-lifecycle-observation", "execution-lifecycle-observation")

    handler = {__MODULE__, make_ref()}
    owner = self()

    assert :ok =
             :telemetry.attach(
               handler,
               [:salix, :external_status_projection, :result],
               fn _event, _measurements, metadata, _config ->
                 send(owner, {:status_projection_result, metadata.outcome})
               end,
               nil
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    ignored_log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, %{"ok" => true}} =
                 ExternalSessionActor.commit_connector_event(pid, capability, %{
                   "connector_run_id" => request.binding["connector_run_id"],
                   "event" =>
                     lifecycle(
                       "dispatch-superseded",
                       "execution-lifecycle-observation",
                       "settled"
                     )
                     |> Map.merge(%{
                       "type" => "status",
                       "provider" => "codex",
                       "name" => "turn/completed",
                       "state" => "completed"
                     })
                 })
      end)

    assert_receive {:status_projection_result, :ok}, @receive_budget_ms

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert ignored_log =~ "event=external_session_lifecycle_observation"
    assert ignored_log =~ "source=connector_event"
    assert ignored_log =~ "mapping=ignored_dispatch_mismatch"
    assert ignored_log =~ "agent_id=#{agent_id}"
    assert ignored_log =~ "session_id=#{@session_id}"
    assert ignored_log =~ "dispatch_id=dispatch-superseded"
    assert ignored_log =~ "execution_id=execution-lifecycle-observation"
    assert ignored_log =~ "status=running"

    applied_log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, %{"ok" => true}} =
                 ExternalSessionActor.commit_connector_event(pid, capability, %{
                   "connector_run_id" => request.binding["connector_run_id"],
                   "event" =>
                     lifecycle(
                       request.dispatch_id,
                       "execution-lifecycle-observation",
                       "settled"
                     )
                     |> Map.merge(%{
                       "type" => "status",
                       "provider" => "codex",
                       "name" => "turn/completed",
                       "state" => "completed"
                     })
                 })
      end)

    assert_receive {:status_projection_result, :ok}, @receive_budget_ms

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert applied_log =~ "event=external_session_lifecycle_observation"
    assert applied_log =~ "source=connector_event"
    assert applied_log =~ "mapping=applied"
    assert applied_log =~ "dispatch_id=#{request.dispatch_id}"
    assert applied_log =~ "execution_id=execution-lifecycle-observation"
    assert applied_log =~ "work_state=settled"
    assert applied_log =~ "status=idle"
    assert applied_log =~ "issue=none"
  end

  test "connector lifecycle logs a stale watermark without changing the current status" do
    {agent_id, _pid, _agent, _capability, request} =
      start_running_execution("input-stale-observation", "execution-stale-observation")

    stale_record = ULID.generate()
    newer_record = ULID.generate(stale_record)

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle(request.dispatch_id, "execution-stale-observation", "running"),
               newer_record,
               request.binding["connector_run_id"]
             )

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, %{"status" => "running"}} =
                 ExternalSessionStatus.apply_runtime_event(
                   agent_id,
                   @session_id,
                   lifecycle(request.dispatch_id, "execution-stale-observation", "settled"),
                   stale_record,
                   request.binding["connector_run_id"]
                 )
      end)

    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "mapping=ignored_stale_watermark"
    assert log =~ "record_id=#{stale_record}"
    assert log =~ "status=running"
  end

  test "connector lifecycle logs a projection-target write failure" do
    {agent_id, pid, agent, capability, request} =
      start_running_execution("input-target-write-failure", "execution-target-write-failure")

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, state_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:error, {:http, 503}} =
                 ExternalSessionActor.commit_connector_event(pid, capability, %{
                   "connector_run_id" => request.binding["connector_run_id"],
                   "event" =>
                     lifecycle(
                       request.dispatch_id,
                       "execution-target-write-failure",
                       "settled"
                     )
                 })
      end)

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "mapping=target_write_failed"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "session_id=#{@session_id}"
    assert log =~ "dispatch_id=#{request.dispatch_id}"
    assert log =~ "execution_id=execution-target-write-failure"
  end

  test "connector lifecycle logs a status projection write failure" do
    {agent_id, pid, agent, capability, request} =
      start_running_execution(
        "input-projection-write-failure",
        "execution-projection-write-failure"
      )

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:error, {:http, 503}} =
                 ExternalSessionActor.commit_connector_event(pid, capability, %{
                   "connector_run_id" => request.binding["connector_run_id"],
                   "event" =>
                     lifecycle(
                       request.dispatch_id,
                       "execution-projection-write-failure",
                       "settled"
                     )
                 })
      end)

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "mapping=projection_failed"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "session_id=#{@session_id}"
    assert log =~ "dispatch_id=#{request.dispatch_id}"
    assert log =~ "execution_id=execution-projection-write-failure"
  end

  test "terminal external runtime failure logs its reason and resulting failed status" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-runtime-timeout", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_updated, @session_id}
    })

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        send(runtime_pid, {:runtime_return, {:error, :timeout}})

        assert_receive {:notification_blocked, notifier_pid, ref, ^agent_id,
                        {:session_updated, @session_id}},
                       @receive_budget_ms

        assert {:ok, %{"status" => "failed", "issue" => "runtime_failed"}} =
                 ExternalSessionStore.get_session_status(agent, @session_id)

        send(notifier_pid, {:release_notification, ref})
      end)

    :persistent_term.erase(@blocked_notification_key)

    assert log =~ "event=external_runtime_dispatch_failed"
    assert log =~ "source=server_dispatch"
    assert log =~ "reason_class=timeout"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "session_id=#{@session_id}"
    assert log =~ "dispatch_id=#{request.dispatch_id}"
    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "source=server_dispatch_failure"
    assert log =~ "mapping=applied"
    assert log =~ "terminal=true"
    assert log =~ "status=failed"
    assert log =~ "issue=runtime_failed"
  end

  test "direct terminal failure logs the applied runtime_failed fact after status persistence" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-direct-failure", "run", no_wake: true)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, _state} =
                 ExternalAgentRuntime.fail_session(agent_id, @session_id, :native_failed)

        assert {:ok, %{"status" => "failed", "issue" => "runtime_failed"}} =
                 ExternalSessionStore.get_session_status(agent, @session_id)
      end)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 20)

    assert %{"id" => record_id, "type" => "session.error"} = List.last(records)
    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "source=server_dispatch_failure"
    assert log =~ "mapping=applied"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "session_id=#{@session_id}"
    assert log =~ "record_id=#{record_id}"
    assert log =~ "terminal=true"
    assert log =~ "status=failed"
    assert log =~ "issue=runtime_failed"
    refute log =~ "dispatch_id="
    refute log =~ "execution_id="
  end

  test "direct terminal failure emits no applied observation when status persistence fails" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-direct-failure-write", "run", no_wake: true)
    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, _state} =
                 ExternalAgentRuntime.fail_session(agent_id, @session_id, :native_failed)
      end)

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    refute log =~ "event=external_session_lifecycle_observation"
    refute log =~ "mapping=applied"
  end

  test "steer runtime failure is logged without falsely claiming a failed status transition" do
    {agent_id, pid, agent, _capability, _running_request} =
      start_running_execution("input-steer-timeout-old", "execution-steer-timeout-old")

    assert {:ok, :committed} = stage(pid, "input-steer-timeout-new", "steer")
    assert_receive {:runtime_request, runtime_pid, steer}, @receive_budget_ms

    :persistent_term.put(@blocked_notification_key, %{
      owner: self(),
      event: {:session_updated, @session_id}
    })

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        send(runtime_pid, {:runtime_return, {:error, :timeout}})

        assert_receive {:notification_blocked, notifier_pid, ref, ^agent_id,
                        {:session_updated, @session_id}},
                       @receive_budget_ms

        assert {:ok, %{"status" => "running"}} =
                 ExternalSessionStore.get_session_status(agent, @session_id)

        send(notifier_pid, {:release_notification, ref})
      end)

    :persistent_term.erase(@blocked_notification_key)

    assert log =~ "event=external_runtime_dispatch_failed"
    assert log =~ "reason_class=timeout"
    assert log =~ "dispatch_id=#{steer.dispatch_id}"
    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "source=server_dispatch_failure"
    assert log =~ "mapping=ignored_non_terminal"
    assert log =~ "terminal=false"
    assert log =~ "status=running"
    assert log =~ "issue=none"
  end

  test "external runtime failure observation classifies but never logs raw failure details" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-runtime-redaction", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    secret = "runtime-secret-that-must-not-be-logged"

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        send(
          runtime_pid,
          {:runtime_return,
           {:error,
            {:invalid_external_runtime_input_response,
             %{"token_hash" => secret, "message" => secret}}}}
        )

        assert eventually(fn ->
                 match?(
                   {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
                   ExternalSessionStore.get_session_status(agent, @session_id)
                 )
               end)
      end)

    assert log =~ "event=external_runtime_dispatch_failed"
    assert log =~ "reason_class=invalid_response"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "dispatch_id=#{request.dispatch_id}"
    refute log =~ secret
    refute log =~ "token_hash"
    refute log =~ "message="
  end

  test "unwrapped invalid runtime return never logs its native payload" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-invalid-runtime-redaction", "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    marker = "unwrapped-runtime-secret-that-must-not-be-logged"

    invalid = %{
      "message" => marker,
      "token" => marker,
      "native_payload" => %{"prompt" => marker, "command" => marker}
    }

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        send(runtime_pid, {:runtime_return, invalid})

        assert eventually(fn ->
                 match?(
                   {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
                   ExternalSessionStore.get_session_status(agent, @session_id)
                 )
               end)
      end)

    assert log =~ "event=external_runtime_dispatch_failed"
    assert log =~ "reason_class=other"
    assert log =~ "agent_id=#{agent_id}"
    assert log =~ "dispatch_id=#{request.dispatch_id}"
    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "source=server_dispatch_failure"
    assert log =~ "mapping=applied"
    assert log =~ "status=failed"
    assert log =~ "issue=runtime_failed"
    refute log =~ marker
    refute log =~ "native_payload"
    refute log =~ "\"prompt\""
    refute log =~ "\"command\""
    refute log =~ "\"token\""
    refute log =~ "\"message\""
  end

  test "invalid lifecycle work state is ignored without logging its raw value" do
    {agent_id, _pid, agent, _capability, request} =
      start_running_execution("input-invalid-work-state", "execution-invalid-work-state")

    secret = "invalid-work-state-secret"

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert {:ok, %{"status" => "running"}} =
                 ExternalSessionStatus.apply_runtime_event(
                   agent_id,
                   @session_id,
                   %{
                     "dispatch_id" => request.dispatch_id,
                     "execution_id" => "execution-invalid-work-state",
                     "work_state" => %{"message" => secret}
                   },
                   ULID.generate(),
                   request.binding["connector_run_id"]
                 )
      end)

    assert {:ok, %{"status" => "running"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert log =~ "event=external_session_lifecycle_observation"
    assert log =~ "mapping=ignored_invalid_work_state"
    assert log =~ "work_state=other"
    refute log =~ secret
    refute log =~ "message="
  end

  test "a failed wait projection stays unknown when its telemetry handler fails" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-wait-projection", "pending", no_wake: true)

    handler = {__MODULE__, make_ref()}
    owner = self()

    assert :ok =
             :telemetry.attach(
               handler,
               [:salix, :external_status_projection, :result],
               fn _event, _measurements, metadata, _config ->
                 send(owner, {:status_projection_result, metadata.outcome})
                 raise "injected telemetry handler failure"
               end,
               nil
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, %{"wait" => %{"reason" => "user_input"}}} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "created_at" => System.system_time(:second),
                 "wait" => %{
                   "wait_id" => "wait-projection",
                   "reason" => "user_input",
                   "deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               }
             ])

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert_receive {:status_projection_result, :failed}, @receive_budget_ms
  end

  test "non-status event batches do not emit a status projection write outcome" do
    {_agent_id, pid, _agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-telemetry-noop", "pending", no_wake: true)

    handler = {__MODULE__, make_ref()}
    owner = self()

    assert :ok =
             :telemetry.attach(
               handler,
               [:salix, :external_status_projection, :result],
               fn _event, _measurements, metadata, _config ->
                 send(owner, {:status_projection_result, metadata.outcome})
               end,
               nil
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{"type" => "trace", "name" => "does-not-change-status"}
             ])

    refute_receive {:status_projection_result, _outcome}, 100
  end

  test "an ambiguous durable wait batch never publishes an intermediate wait" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-wait-batch", "pending", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, status_key})

    assert {:ok, %{"wait" => nil}} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "created_at" => System.system_time(:second) - 1,
                 "wait" => %{
                   "wait_id" => "wait-batch",
                   "reason" => "temporary",
                   "deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               },
               %{
                 "type" => "wait_clear",
                 "created_at" => System.system_time(:second)
               }
             ])

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "a durable completion never leaves the public status at running" do
    {agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-complete-projection", "execution-complete-projection")

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, _state} = ExternalSessionActor.complete_session(pid, %{})
    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "a durable failure never leaves the public status at running" do
    {agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-fail-projection", "execution-fail-projection")

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, _state} = ExternalSessionActor.fail_session(pid, :native_failed, %{})
    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "dispatch does not proceed while its starting status is silently stale" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-start-projection-seed", "seed", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.blackhole({:fail, 503, :put, status_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, :committed} = stage(pid, "input-start-projection", "run")
    assert_receive {:runtime_request, runtime_pid, _request}, @receive_budget_ms
    :ok = S3.Fake.clear_blackhole()
    observed = ExternalSessionStore.get_session_status(agent, @session_id)
    send(runtime_pid, {:runtime_return, {:error, :test_cleanup}})

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} = observed
  end

  test "replacing a durable wait refreshes the public status timestamp" do
    {_agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-wait-replace", "pending", no_wake: true)
    first_at = System.system_time(:second) - 2
    replaced_at = first_at + 1

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "created_at" => first_at,
                 "wait" => %{
                   "wait_id" => "wait-old",
                   "reason" => "first",
                   "deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               }
             ])

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "created_at" => replaced_at,
                 "wait" => %{
                   "wait_id" => "wait-new",
                   "reason" => "replacement",
                   "deadline_ms" => System.system_time(:millisecond) + 120_000
                 }
               }
             ])

    assert {:ok,
            %{
              "status" => "waiting",
              "status_updated_at" => ^replaced_at,
              "wait" => %{"wait_id" => "wait-new", "reason" => "replacement"}
            }} = ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "a delayed old wait does not erase a newer terminal failure issue" do
    {_agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-failed-old-wait", "execution-failed-old-wait")

    old_wait_at = System.system_time(:second) - 10
    assert {:ok, _state} = ExternalSessionActor.fail_session(pid, :native_failed, %{})

    assert {:ok, %{"status" => "failed", "issue" => "runtime_failed"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "wait_set",
                 "created_at" => old_wait_at,
                 "wait" => %{
                   "wait_id" => "old-wait",
                   "reason" => "approval",
                   "deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               }
             ])

    assert {:ok, %{"status" => "failed", "issue" => "runtime_failed"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "terminal projection timestamp is the timestamp of its durable session fact" do
    {_agent_id, pid, agent, _capability, _request} =
      start_running_execution("input-terminal-timestamp", "execution-terminal-timestamp")

    :ok = :sys.suspend(S3.Fake)

    on_exit(fn ->
      try do
        :sys.resume(S3.Fake)
      catch
        :exit, _reason -> :ok
      end
    end)

    completion = Task.async(fn -> ExternalSessionActor.complete_session(pid, %{}) end)
    Process.sleep(1_100)
    :ok = :sys.resume(S3.Fake)
    assert {:ok, _state} = Task.await(completion, 2_000)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(agent, @session_id, limit: 20)

    assert %{
             "type" => "session.status",
             "created_at" => source_at,
             "data" => %{"created_at" => source_at, "state" => "stopped"}
           } = List.last(records)

    assert {:ok, %{"status" => "idle", "status_updated_at" => ^source_at}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "a newer projection for the same execution satisfies an older durable target" do
    {agent_id, pid, agent, capability, request} =
      start_running_execution("input-newer-projection", "execution-newer-projection")

    assert {:ok, running_state} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    running_target = running_state["status_projection_target"]

    terminal_event =
      lifecycle(request.dispatch_id, "execution-newer-projection", "settled")
      |> Map.merge(%{
        "type" => "status",
        "provider" => "codex",
        "name" => "turn/completed",
        "state" => "completed"
      })

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" => terminal_event
             })

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(state_key)
    assert {:ok, terminal_state} = Jason.decode(body)

    assert running_target["dispatch_id"] ==
             get_in(terminal_state, ["status_projection_target", "dispatch_id"])

    assert running_target["execution_id"] ==
             get_in(terminal_state, ["status_projection_target", "execution_id"])

    assert running_target["watermark"] <
             get_in(terminal_state, ["status_projection_target", "watermark"])

    lagging_state = Map.put(terminal_state, "status_projection_target", running_target)
    assert {:ok, _etag} = S3.put(state_key, Jason.encode!(lagging_state), if_match: etag)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)
  end

  test "status query reads the materialized object without scanning records" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-status-read", "pending", no_wake: true)
    _ = :sys.get_state(pid)
    :ok = SalixStore.S3.Fake.reset_read_log()

    send(pid, :process)
    _ = :sys.get_state(pid)

    assert {:ok, %{"status" => "idle"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    reads = SalixStore.S3.Fake.read_log()

    assert length(reads) <= 3
    assert {:get, status_key} in reads
    assert Enum.all?(reads, &(&1 in [{:get, state_key}, {:get, status_key}]))
  end

  test "missing status stays unknown without scanning and a new dispatch recovers it" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-missing-status", "pending", no_wake: true)

    state_key = Keys.agent_external_runtime_session(agent_id, @session_id)
    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert :ok = S3.delete(status_key)
    :ok = S3.Fake.reset_read_log()

    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    reads = S3.Fake.read_log()
    assert Enum.all?(reads, &(&1 in [{:get, state_key}, {:get, status_key}]))

    assert {:ok, :committed} = stage(pid, "input-new-dispatch", "run")
    assert_receive {:runtime_request, runtime_pid, _request}, @receive_budget_ms

    assert {:ok, %{"status" => "starting"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    send(runtime_pid, {:runtime_return, {:error, :test_cleanup}})
  end

  test "canonical activity treats a missing status projection as read uncertainty" do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, "input-activity-uncertain", "pending", no_wake: true)

    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    assert :ok = S3.delete(status_key)

    assert {:error, _reason} =
             SalixAgent.Runtime.get_session_activity(agent, @session_id)
  end

  @tag :skip
  test "ACK removes only its in-flight snapshot when new input arrives" do
    {agent_id, pid, _agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-1", "context", no_wake: true)
    assert {:ok, :committed} = stage(pid, "input-2", "run")

    assert_receive {:runtime_request, runtime_pid, first}, @receive_budget_ms
    assert Enum.map(queued_inputs(first.input_messages), & &1["content"]) == ["context", "run"]
    assert Enum.any?(first.input_messages, &(&1["type"] == "time_context"))
    refute inspect(first.input_messages) =~ "do_not_send_to_llm"
    refute Map.has_key?(first, :runtime_payload)

    assert {:ok, :committed} = stage(pid, "input-3", "arrived while sending")
    send(runtime_pid, {:runtime_return, accepted(first, %{"thread_id" => "thread-1"})})

    assert_receive {:runtime_request, runtime_pid, second}, @receive_budget_ms
    assert Enum.map(second.input_messages, & &1["content"]) == ["arrived while sending"]
    refute Map.has_key?(second, :runtime_payload)

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert Enum.map(state["input_message_queue"], & &1["content"]) == ["arrived while sending"]

    send(runtime_pid, {:runtime_return, accepted(second, %{"thread_id" => "thread-1"})})
    assert eventually(fn -> queue(agent_id) == [] end)
  end

  test "session keeps its exact runtime binding" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-1", "first", no_wake: true)
    assert {:ok, :committed} = stage(pid, "input-2", "same runtime", no_wake: true)

    different_runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => "other-device",
      "runtime_id" => "other-runtime",
      "device_runtime_id" =>
        RuntimeIds.device_runtime_id("other-device", "codex", "other-runtime")
    }

    {:ok, _agent} =
      SalixAgent.Control.configure(agent_id, %{"runtime_config" => different_runtime})

    assert {:error, :external_session_read_only} =
             stage(pid, "input-3", "different runtime", no_wake: true)

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)

    assert get_in(state, ["runtime", "binding", "device_runtime_id"]) ==
             agent["runtime_config"]["device_runtime_id"]
  end

  test "Compute candidate comes from the Session binding after the Agent changes target" do
    {agent_id, pid, agent} = start_external_session()
    prefix = "candidate-" <> ULID.generate()

    fixture =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.create(
        prefix,
        "candidate-project",
        agent["group_id"],
        "codex",
        agent["tenant_id"]
      )

    other =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.add_workload(
        fixture,
        prefix <> "-other",
        "codex"
      )

    original_id = fixture.workload.id
    rebound_id = other.workload.id

    runtime = %{
      "kind" => "compute_workload",
      "workload_id" => original_id,
      "runtime_spec" => %{"provider" => "codex"},
      "owner_scope" => %{"type" => "project", "id" => "candidate-project"},
      "binding_revision" => 1
    }

    assert {:ok, _} =
             SalixAgent.Control.rebind_external_worker(
               agent_id,
               agent["tenant_id"],
               Map.delete(runtime, "binding_revision"),
               0,
               "candidate-initial"
             )

    assert {:ok, :committed} = stage(pid, "compute-input", "retained work", no_wake: true)
    assert {:ok, _} = ExternalSessionActor.begin_session(pid, agent["tenant_id"], runtime)

    assert {:ok, _} =
             SalixAgent.Control.rebind_external_worker(
               agent_id,
               agent["tenant_id"],
               runtime |> Map.delete("binding_revision") |> Map.put("workload_id", rebound_id),
               1,
               "candidate-rebound"
             )

    assert {:ok, state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => "original-background-call",
                 "tool_name" => "local.tool",
                 "completion_mode" => "process_local",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    token = state["work_index_token"]

    assert {:ok, %{records: [%{"token" => ^token, "workload_id" => ^original_id}]}} =
             SessionWorkIndex.list_discovery(workload_id: original_id)

    assert {:ok, %{records: []}} = SessionWorkIndex.list_discovery(workload_id: rebound_id)
    assert {:ok, [marker]} = SessionWorkIndex.list(agent_id)
    refute Map.has_key?(marker, "workload_id")
  end

  test "Compute dispatch fills a missing runtime model from the live Agent template" do
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm_resolver, LiveLlmResolver)

    :persistent_term.put(
      {LiveLlmResolver, :config},
      %{"model" => "gpt-5.5", "provider" => "openai", "reasoning_effort" => "high"}
    )

    on_exit(fn ->
      :persistent_term.erase({LiveLlmResolver, :config})
      restore_env(:llm_resolver, previous_resolver)
    end)

    {agent_id, pid, agent} = start_external_session()
    prefix = "live-model-" <> ULID.generate()

    fixture =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.create(
        prefix,
        "live-model-project",
        agent["group_id"],
        "pi",
        agent["tenant_id"]
      )

    runtime = %{
      "kind" => "compute_workload",
      "workload_id" => fixture.workload.id,
      "runtime_spec" => %{"provider" => "pi"},
      "owner_scope" => %{"type" => "project", "id" => "live-model-project"},
      "binding_revision" => 1
    }

    assert {:ok, _} =
             SalixAgent.Control.rebind_external_worker(
               agent_id,
               agent["tenant_id"],
               Map.delete(runtime, "binding_revision"),
               0,
               "live-model-initial"
             )

    assert {:ok, :committed} = stage(pid, "live-model-input", "retained work", no_wake: true)
    assert {:ok, binding} = ExternalSessionActor.begin_session(pid, agent["tenant_id"], runtime)

    assert binding["runtime_spec"] == %{
             "provider" => "pi",
             "model" => "gpt-5.5",
             "model_provider" => "openai",
             "reasoning_effort" => "high"
           }

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert get_in(state, ["runtime", "binding", "runtime_spec"]) == %{"provider" => "pi"}
  end

  test "runtime events and accepted input share one SessionRecord stream" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-1", "message")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, accepted(request, %{})})

    assert eventually(fn ->
             match?(
               {:ok, %{"input_message_queue" => []}},
               ExternalSessionStore.get_session_record(agent_id, @session_id)
             )
           end)

    assert {:ok, binding} =
             ExternalSessionActor.begin_session(
               pid,
               agent["tenant_id"],
               agent["runtime_config"]
             )

    token_hash = binding["runtime_capability"]["token_hash"]

    assert {:ok, _session, %{"type" => "runtime.event"}} =
             ExternalSessionActor.append_event(pid, %{
               "token_hash" => token_hash,
               "event" => %{"method" => "thread/status/changed"}
             })

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(%{"agent_id" => agent_id}, @session_id,
               limit: 10
             )

    assert [
             %{"type" => "message", "data" => %{"content" => "message"}},
             %{"type" => "runtime.event"}
           ] = Enum.reject(records, &(get_in(&1, ["data", "content_kind"]) == "model_context"))
  end

  test "ambiguous segment creation is confirmed by exact body" do
    {agent_id, _pid, _agent} = start_external_session()
    id = ULID.generate()

    record = %{
      "id" => id,
      "agent_id" => agent_id,
      "session_id" => @session_id,
      "type" => "runtime.event",
      "data" => %{"event" => %{"type" => "status", "state" => "running"}},
      "created_at" => 1
    }

    assert {:ok, cache} = ExternalSessionRecords.load(agent_id, @session_id)
    prefix = Keys.agent_external_runtime_session_segments_prefix(agent_id, @session_id)
    SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, prefix <> id <> ".jsonl"})

    assert {:ok, cache, [:duplicate]} =
             ExternalSessionRecords.append(agent_id, @session_id, cache, [record])

    assert {:ok, stored} = ExternalSessionRecords.all(agent_id, @session_id, cache)
    assert stored == [record]
  end

  test "segment objects land on the key Keys derives for them" do
    {agent_id, _pid, _agent} = start_external_session()
    id = ULID.generate()

    record = %{
      "id" => id,
      "agent_id" => agent_id,
      "session_id" => @session_id,
      "type" => "runtime.event",
      "data" => %{"event" => %{"type" => "status", "state" => "running"}},
      "created_at" => 1
    }

    assert {:ok, cache} = ExternalSessionRecords.load(agent_id, @session_id)

    assert {:ok, _cache, [:committed]} =
             ExternalSessionRecords.append(agent_id, @session_id, cache, [record])

    # SegmentLog derives segment keys itself (prefix <> encoded id <> suffix), so
    # nothing in the serving path calls this helper any more. Pin the two together:
    # a change to either side that silently moved existing objects out of reach
    # would otherwise only surface as data that has gone missing.
    expected = Keys.agent_external_runtime_session_segment(agent_id, @session_id, id)
    assert {:ok, %{body: body}} = S3.get(expected)
    assert body =~ id
  end

  test "pending input keeps its order when a later runtime event is committed first" do
    {agent_id, pid, agent} = start_external_session()

    assert {:ok, :committed} = stage(pid, "input-1", "before event", no_wake: true)
    [queued] = queue(agent_id)

    assert {:ok, binding} =
             ExternalSessionActor.begin_session(
               pid,
               agent["tenant_id"],
               agent["runtime_config"]
             )

    token_hash = binding["runtime_capability"]["token_hash"]

    assert {:ok, _session, %{"type" => "runtime.event"} = event_record} =
             ExternalSessionActor.append_event(pid, %{
               "token_hash" => token_hash,
               "event" => %{"method" => "thread/status/changed"}
             })

    assert queued["id"] < event_record["id"]
    assert {:ok, :committed} = stage(pid, "input-2", "after event")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms
    send(runtime_pid, {:runtime_return, accepted(request, %{})})
    assert eventually(fn -> queue(agent_id) == [] end)

    assert {:ok, %{"records" => records}} =
             ExternalSessionStore.session_records(%{"agent_id" => agent_id}, @session_id,
               limit: 10
             )

    assert [
             %{"type" => "message", "data" => %{"content" => "before event"}},
             %{"type" => "runtime.event"},
             %{"type" => "message", "data" => %{"content" => "after event"}}
           ] = Enum.reject(records, &(get_in(&1, ["data", "content_kind"]) == "model_context"))
  end

  test "records roll over into ordered segments and page backward with one ULID" do
    {agent_id, pid, agent} = start_external_session()

    # commit_session_events reads the session record, which start_external_session
    # does not create on its own: stage one input and open the runtime binding so
    # the state object exists before events are committed.
    assert {:ok, :committed} = stage(pid, "input-1", "seed", no_wake: true)

    assert {:ok, _binding} =
             ExternalSessionActor.begin_session(
               pid,
               agent["tenant_id"],
               agent["runtime_config"]
             )

    events =
      Enum.map(1..257, fn index ->
        %{"type" => "status", "status" => "sample-#{index}", "created_at" => index}
      end)

    assert {:ok, _state} = ExternalSessionActor.commit_session_events(pid, events)

    prefix = Keys.agent_external_runtime_session_segments_prefix(agent_id, @session_id)
    assert {:ok, segments} = S3.list_all(prefix)
    assert length(segments) == 2

    assert {:ok, %{"records" => last, "has_more" => true, "next_before" => before}} =
             ExternalSessionStore.session_records(%{"agent_id" => agent_id}, @session_id,
               limit: 2
             )

    assert Enum.map(last, &get_in(&1, ["data", "status"])) == ["sample-256", "sample-257"]
    assert ULID.valid?(before)

    assert {:ok, %{"records" => previous}} =
             ExternalSessionStore.session_records(%{"agent_id" => agent_id}, @session_id,
               limit: 2,
               before: before
             )

    assert Enum.map(previous, &get_in(&1, ["data", "status"])) == ["sample-254", "sample-255"]
  end

  @tag :skip
  test "session listing ignores retired hex-key state objects" do
    {agent_id, _pid, _agent} = start_external_session()
    prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)

    assert {:ok, _} =
             S3.put(
               prefix <> String.duplicate("a", 64) <> ".json",
               Jason.encode!(%{"legacy" => true})
             )

    assert {:ok, [state]} = ExternalSessionStore.list_sessions(agent_id)
    assert state["session_id"] == @session_id
  end

  defp migration_compute_target(agent) do
    alias SalixStore.{AgentVMM, Compute, Repo}
    suffix = Ecto.UUID.generate()

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "migration-registration-" <> suffix,
        tenant_id: agent["tenant_id"],
        group_id: agent["group_id"],
        device_id: "migration-device-" <> suffix,
        enrollment_token: String.duplicate("e", 32)
      })

    registration
    |> Ecto.Changeset.change(status: "ready", desired_enabled: true)
    |> Repo.update!()

    {:ok, pool} =
      Compute.create_pool(%{
        id: "migration-pool-" <> suffix,
        tenant_id: agent["tenant_id"],
        name: "migration",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process"]
      })

    project_id = "migration-project-" <> suffix

    {:ok, environment} =
      Compute.create_environment(%{
        id: "migration-environment-" <> suffix,
        tenant_id: agent["tenant_id"],
        owner_type: "project",
        owner_id: project_id,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "migration-binding-" <> suffix,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id
      })

    binding |> Ecto.Changeset.change(status: "available") |> Repo.update!()

    {:ok, allocation} =
      Compute.allocate(%{
        id: "migration-allocation-" <> suffix,
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded")

    allocation
    |> Ecto.Changeset.change(
      provider_observation:
        Map.merge(allocation.provider_observation, %{
          "current_container" => %{
            "id" => "migration-container-" <> suffix,
            "instance_id" => "migration-instance-" <> suffix
          },
          "container_status" => "running"
        })
    )
    |> Repo.update!()

    {:ok, workload} =
      Compute.create_workload(%{
        id: "migration-workload-" <> suffix,
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        template_key: "external.codex",
        generation: 1,
        capability_requirements: ["runtime_exec", "runtime_process"]
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "migration-runtime-" <> suffix,
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, _} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")

    %{
      "kind" => "compute_workload",
      "workload_id" => workload.id,
      "runtime_spec" => %{"provider" => "codex"},
      "owner_scope" => %{"type" => "project", "id" => project_id}
    }
  end

  defp start_external_session(runtime_kind \\ "external") do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    runtime = %{
      "kind" => runtime_kind,
      "provider" => "codex",
      "device_id" => "test-device",
      "runtime_id" => "test-runtime",
      "device_runtime_id" => @device_runtime_id
    }

    runtime =
      if runtime_kind == "connected_runtime" do
        Map.merge(runtime, %{
          "binding_revision" => 1,
          "owner_scope" => %{
            "type" => "group",
            "id" => SalixStore.Ids.group_id_from_agent!(agent_id)
          }
        })
      else
        runtime
      end

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "worker",
        "runtime_config" => runtime
      })

    {:ok, pid} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: @session_id,
        process_on_init: false
      )

    {agent_id, pid, agent}
  end

  defp assert_wait_clear_projection_cas_race(wake_kind) do
    suffix = Atom.to_string(wake_kind)
    execution_id = "execution-wait-clear-cas-#{suffix}"

    {agent_id, pid, agent, _capability, request} =
      start_running_execution("input-wait-clear-cas-#{suffix}", execution_id)

    call_id = "wait-clear-cas-#{suffix}"
    tool_name = if wake_kind == :terminal, do: "local.background", else: "permission.request"

    assert {:ok, _state} =
             ExternalSessionActor.commit_session_events(pid, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => call_id,
                 "tool_name" => tool_name,
                 "status" => "running",
                 "started_at" => System.system_time(:millisecond)
               },
               %{
                 "type" => "wait_set",
                 "session_id" => @session_id,
                 "wait" =>
                   Waits.build("tool setup is running", 20, "auto_wait", %{
                     "tool_call_id" => call_id
                   })
               }
             ])

    assert {:ok, %{"status" => "running", "wait" => %{} = projected_wait}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    assert projected_wait["source"] == "auto_wait"

    events = projection_race_wake_events(wake_kind, agent_id, call_id, tool_name)
    status_key = Keys.agent_external_runtime_session_status(agent_id, @session_id)
    :ok = S3.Fake.set_fault({:pause, :put, status_key})

    commit_task =
      Task.async(fn -> ExternalSessionActor.commit_session_events(pid, events) end)

    on_exit(fn ->
      if S3.Fake.paused?(), do: S3.Fake.release_pause()
      if Process.alive?(commit_task.pid), do: Task.shutdown(commit_task, :brutal_kill)
    end)

    assert eventually(&S3.Fake.paused?/0)

    assert {:ok, %{"status_projection_target" => target}} =
             ExternalSessionStore.get_session_record(agent_id, @session_id)

    clear_watermark = target["wait_watermark"]
    assert is_binary(clear_watermark)
    assert target["watermark"] == clear_watermark

    settled_record = ULID.generate(clear_watermark)

    assert {:ok, %{"status" => "waiting", "wait" => %{} = still_projected}} =
             ExternalSessionStatus.apply_runtime_event(
               agent_id,
               @session_id,
               lifecycle(request.dispatch_id, execution_id, "settled"),
               settled_record,
               request.binding["connector_run_id"],
               target
             )

    assert still_projected["source"] == "auto_wait"

    # The lifecycle write is globally current but cannot certify the separate
    # wait target while the older clear PUT is parked.
    assert {:ok, %{"status" => "unknown", "issue" => "runtime_status_unknown"}} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    :ok = S3.Fake.release_pause()
    assert {:ok, %{"wait" => nil}} = Task.await(commit_task, 5_000)

    assert {:ok,
            %{
              "status" => "idle",
              "wait" => nil,
              "projection_watermark" => ^settled_record,
              "wait_projection_watermark" => ^clear_watermark
            }} = ExternalSessionStatus.get(agent_id, @session_id)

    assert {:ok, %{"status" => "idle"} = public_status} =
             ExternalSessionStore.get_session_status(agent, @session_id)

    refute Map.has_key?(public_status, "wait")

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    assert is_nil(state["wait"])
    assert get_in(state, ["status_projection_target", "wait_watermark"]) == clear_watermark

    expected_runtime_type =
      if wake_kind == :terminal, do: "tool_call_completed", else: "tool_call_handoff"

    assert Enum.count(state["input_message_queue"], fn entry ->
             entry["type"] == expected_runtime_type and
               entry["source_tool_call_id"] == call_id
           end) == 1

    case wake_kind do
      :terminal ->
        assert {:ok, %{"status" => "completed"}} =
                 ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)

      :handoff ->
        assert {:ok,
                %{
                  "status" => "running",
                  "completion_mode" => "external_callback"
                }} = ExternalSessionStore.get_async_tool_call(agent_id, @session_id, call_id)
    end
  end

  defp projection_race_wake_events(:terminal, _agent_id, call_id, tool_name) do
    AsyncToolResults.external_events(
      %{session_id: @session_id, tool_call_id: call_id, tool_name: tool_name},
      %{id: call_id, content: "finished", error: false, status: "completed"}
    )
  end

  defp projection_race_wake_events(:handoff, agent_id, call_id, tool_name) do
    pending = %{session_id: @session_id, tool_call_id: call_id, tool_name: tool_name}

    callback_wait =
      Waits.build("approval is pending", 120, "auto_wait", %{"tool_call_id" => call_id})

    result = %{
      id: call_id,
      name: tool_name,
      status: "async_running",
      content: "approval URL: https://example.test/approve",
      error: false,
      events: [
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session_id,
          "tool_call_id" => call_id,
          "tool_name" => tool_name,
          "status" => "running",
          "completion_mode" => "external_callback",
          "started_at" => System.system_time(:millisecond)
        },
        Waits.event(@session_id, callback_wait)
      ]
    }

    assert {:ok, events, _observed_result} =
             SessionToolExecution.commit_async(
               agent_id,
               @session_id,
               :external,
               pending,
               result
             )

    events
  end

  defp install_external_dependency_pending(pid, agent_id, call_id) do
    result = %{
      "tool_call_id" => call_id,
      "status" => "completed",
      "content" => "terminal payload",
      "output" => "terminal payload"
    }

    install_external_dependency_pending(pid, agent_id, call_id, "local.background", result)
  end

  defp install_external_dependency_pending(pid, agent_id, call_id, tool_name, result) do
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(agent_id)

    {:ok, job} =
      DependencyJob.start(
        :tool,
        tenant_id,
        fn ->
          receive do
            :release -> result
          end
        end,
        timeout_ms: 60_000
      )

    pending = %{
      agent_id: agent_id,
      session_id: @session_id,
      tool_call_id: call_id,
      tool_name: tool_name,
      call: %{id: call_id, name: tool_name, args: %{}},
      task: nil,
      started_at: System.monotonic_time(:millisecond),
      dependency_job: job,
      ref: job.ref,
      pid: job.pid
    }

    :sys.replace_state(pid, fn state ->
      %{state | pending_async_tools: Map.put(state.pending_async_tools, job.token, pending)}
    end)

    {job, job.pid, result}
  end

  defp callback_handoff(call_id, tool_name, wait \\ nil) do
    events = [
      %{
        "type" => "async_tool_call_started",
        "session_id" => @session_id,
        "tool_call_id" => call_id,
        "tool_name" => tool_name,
        "status" => "running",
        "completion_mode" => "external_callback",
        "started_at" => System.system_time(:millisecond)
      }
    ]

    events = if is_map(wait), do: events ++ [Waits.event(@session_id, wait)], else: events

    %{
      id: call_id,
      name: tool_name,
      status: "async_running",
      content: "approval URL: https://example.test/approve",
      output: "approval URL: https://example.test/approve",
      error: false,
      events: events
    }
  end

  defp stage(pid, source_id, content, opts \\ []) do
    payload =
      %{
        "session_id" => Keyword.get(opts, :session_id, @session_id),
        "role" => "user",
        "content" => content,
        "no_wake" => Keyword.get(opts, :no_wake, false)
      }
      |> then(fn payload ->
        case Keyword.get(opts, :trusted_origin) do
          origin when is_map(origin) -> Map.put(payload, "trusted_origin", origin)
          _ -> payload
        end
      end)

    ExternalSessionActor.stage_delivery(pid, %{
      "source_message_id" => source_id,
      "payload" => payload
    })
  end

  defp slack_origin(source_message_id, thread_ts) do
    %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "source_message_id" => source_message_id,
      "provider_context" => %{
        "connect_id" => "slack-1",
        "channel_id" => "C-thread-race",
        "thread_ts" => thread_ts,
        "message_ts" => thread_ts
      }
    }
  end

  defp queue(agent_id) do
    {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    state["input_message_queue"]
  end

  defp start_running_execution(source_id, execution_id) do
    {agent_id, pid, agent} = start_external_session()
    assert {:ok, :committed} = stage(pid, source_id, "run")
    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => request.dispatch_id}}}
    )

    assert eventually(fn -> queue(agent_id) == [] end)
    capability = request.binding["runtime_capability"]

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" =>
                 lifecycle(request.dispatch_id, execution_id, "running")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/started",
                   "state" => "inProgress"
                 })
             })

    {agent_id, pid, agent, capability, request}
  end

  defp start_running_session(agent_id, session_id, suffix) do
    {:ok, pid} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: session_id,
        process_on_init: false
      )

    assert {:ok, :committed} =
             ExternalSessionActor.stage_delivery(pid, %{
               "source_message_id" => "input-#{suffix}",
               "payload" => %{
                 "session_id" => session_id,
                 "role" => "user",
                 "content" => "run #{suffix}",
                 "no_wake" => false
               }
             })

    assert_receive {:runtime_request, runtime_pid, request}, @receive_budget_ms

    send(
      runtime_pid,
      {:runtime_return, {:accepted, %{"dispatch_id" => request.dispatch_id}}}
    )

    assert eventually(fn ->
             case ExternalSessionStore.get_session_record(agent_id, session_id) do
               {:ok, %{"input_message_queue" => []}} -> true
               _ -> false
             end
           end)

    capability = request.binding["runtime_capability"]

    assert {:ok, %{"ok" => true}} =
             ExternalSessionActor.commit_connector_event(pid, capability, %{
               "connector_run_id" => request.binding["connector_run_id"],
               "event" =>
                 lifecycle(request.dispatch_id, "execution-#{suffix}", "running")
                 |> Map.merge(%{
                   "type" => "status",
                   "provider" => "codex",
                   "name" => "turn/started",
                   "state" => "inProgress"
                 })
             })

    {pid, capability, request}
  end

  defp next_record_id(agent_id, session_id) do
    {:ok, records} = ExternalSessionRecords.load(agent_id, session_id)
    ULID.generate(records.last_id)
  end

  defp connector_message(capability, event_id, content) do
    %{
      "capability_token" => capability["token"],
      "event_id" => event_id,
      "event" => %{
        "provider" => "codex",
        "type" => "message",
        "role" => "assistant",
        "content" => content,
        "created_at" => System.system_time(:second)
      }
    }
  end

  defp connector_lifecycle_batch(capability, dispatch_id, execution_id, event_ids) do
    timestamp = System.system_time(:second)
    event_count = length(event_ids)

    event_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {event_id, index} ->
      terminal? = index == event_count
      work_state = if terminal?, do: "settled", else: "running"

      %{
        "capability_token" => capability["token"],
        "event_id" => event_id,
        "event" =>
          lifecycle(dispatch_id, execution_id, work_state)
          |> Map.merge(%{
            "provider" => "codex",
            "type" => "status",
            "name" => if(terminal?, do: "turn/completed", else: "turn/started"),
            "state" => if(terminal?, do: "completed", else: "inProgress"),
            "created_at" => timestamp + index
          })
      }
    end)
  end

  defp accepted(request, _payload), do: {:accepted, %{"dispatch_id" => request.dispatch_id}}

  defp lifecycle(dispatch_id, execution_id, work_state) do
    %{
      "dispatch_id" => dispatch_id,
      "execution_id" => execution_id,
      "work_state" => work_state
    }
  end

  # Bounded wait for an asynchronous settle that is already in flight. The
  # budget is a scheduling margin, not a latency assertion: the poll returns
  # the moment the condition holds, so a wider ceiling costs nothing on a
  # passing system and is only spent on a run that was going to fail anyway.
  # The old ceiling was 100 retries x 10ms = 1s, tight enough that a loaded
  # CI runner tripped it while the system was behaving — one of the two
  # mechanisms behind #866's rotating flake.
  @eventually_budget_ms 5_000
  @eventually_poll_ms 10

  defp eventually(fun, budget_ms \\ @eventually_budget_ms),
    do: eventually_until(fun, System.monotonic_time(:millisecond) + budget_ms)

  defp eventually_until(fun, deadline_ms) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(@eventually_poll_ms)
        eventually_until(fun, deadline_ms)
    end
  end

  defp configure_consultation_llm!(agent) do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    router_id = SalixStore.Ids.new_agent_id(agent["group_id"])

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => agent["tenant_id"],
      "group_id" => agent["group_id"],
      "role" => "router",
      "runtime_config" => %{"kind" => "internal"}
    })

    Application.put_env(:salix_agent, :llm, ConsultationLLM)
    Application.put_env(:salix_agent, :llm_resolver, LiveLlmResolver)
    :persistent_term.put({ConsultationLLM, :owner}, self())

    :persistent_term.put(
      {LiveLlmResolver, :config},
      %{"model" => "router-authorized-model", "provider" => "test"}
    )

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({ConsultationLLM, :owner})
      :persistent_term.erase({LiveLlmResolver, :config})
    end)

    router_id
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
  # Context is appended to the actual dispatch, not inserted into the source queue.
  defp queued_inputs(messages),
    do: Enum.reject(messages, &(&1["content_kind"] == "model_context"))
end
