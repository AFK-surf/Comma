defmodule SalixAgent.InternalSessionAsyncTerminalTest do
  require SystemsRuntime.Proc

  # Each test's world starts from the same store: its database's baseline,
  # an empty S3 fake, a new id allocator, which mints ids on the world's
  # clock, and an empty plugin catalog cache of the control plane (worlds
  # mint the same ids, so a catalog cached in one would serve the next). The
  # test parks a write in the fake and releases it from the world. No Loop
  # runs here: the loops host starts no spinfoam process, whose replies would
  # come at real times. The control plane's triage receipt recovery, which
  # lists the fake's receipts on its own schedule, stops.
  use SystemsSim.Case,
    reset: &SalixStore.RepoTestSetup.reset!/0,
    host: [
      {SalixStore.Supervisor, SalixStore.S3.Fake},
      {SalixStore.Supervisor, SalixStore.Ids},
      {SalixWeb.Supervisor, Salix.Control.PluginCatalogCache}
    ],
    apps: [:salix_agent],
    env: [salix_agent: [spinfoam_cmd: :disabled]],
    timeout: 120_000,
    max_steps: 20_000

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{
    DependencyJob,
    InternalAgentRuntime,
    InternalSessionActor,
    InternalSessionFleet
  }

  alias SalixAgent.InternalSessionStore
  alias SalixStore.Keys

  @session "ses1_0000000000000000930"

  defmodule RecordAwareResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)

    @impl true
    def resolve_record(agent),
      do: SalixAgent.AgentModel.resolve_llm(agent)
  end

  defmodule FailingRecordResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:error, :round_config_unavailable}

    @impl true
    def resolve_record(_agent), do: {:error, :round_config_unavailable}
  end

  defmodule GatedMetering do
    def before_llm_call(_fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:billing_waiting, SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive do
        :allow_billing -> :ok
        :deny_billing -> {:error, :denied}
      after
        5_000 -> {:error, :test_timeout}
      end
    end

    def after_llm_call(_), do: :ok
  end

  defmodule BlockingCaptureLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      SystemsRuntime.Proc.send(
        owner,
        {:activation_llm_request, SystemsRuntime.Proc.self(), messages, tools}
      )

      SystemsRuntime.Proc.receive do
        :release_activation_llm ->
          {:assistant, "done",
           [
             %{
               id: "roundtrip-test-end-turn",
               name: "end_turn",
               args: %{"outcome" => "done"}
             }
           ]}
      after
        5_000 -> {:error, %{reason: :activation_test_timeout}}
      end
    end
  end

  defmodule TimedCaptureLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      SystemsRuntime.Proc.send(
        owner,
        {:timed_activation_llm_request, SystemsRuntime.Proc.self(),
         SystemsClock.monotonic_time(:microsecond), messages, tools}
      )

      SystemsRuntime.Proc.receive do
        :release_activation_llm ->
          {:assistant, "done",
           [
             %{
               id: "roundtrip-timed-test-end-turn",
               name: "end_turn",
               args: %{"outcome" => "done"}
             }
           ]}
      after
        5_000 -> {:error, %{reason: :activation_test_timeout}}
      end
    end
  end

  defmodule PhaseCollector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def round_phase(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :async_phase_test_pid),
        {:phase, fact}
      )

      :ok
    end
  end

  defmodule TimedPluginStore do
    def runtime_projection(%{"group_id" => group_id}) do
      with {:ok, _object} <-
             SalixStore.S3.get("test/async-roundtrip/plugins/#{group_id}.json") do
        {:ok, SalixAgent.TestSupport.plugin_projection()}
      end
    end
  end

  defmodule MissingPluginStore do
    def runtime_projection(_), do: {:error, :not_found}
  end

  defmodule UnavailablePluginStore do
    def runtime_projection(_), do: {:error, :unavailable}
  end

  defmodule TimedS3 do
    @behaviour SalixStore.S3

    def child_spec(opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(opts) do
      SystemsRuntime.Agent.start_link(
        fn ->
          %{
            delay_ms: Keyword.fetch!(opts, :delay_ms),
            delay_keys: Keyword.fetch!(opts, :delay_keys),
            events: []
          }
        end,
        name: __MODULE__
      )
    end

    def reset, do: SystemsRuntime.Agent.update(__MODULE__, &%{&1 | events: []})

    def events,
      do:
        SystemsRuntime.Agent.get(__MODULE__, &Enum.sort_by(&1.events, fn event -> event.seq end))

    @impl true
    def put(key, body, opts),
      do: trace(:put, key, fn -> SalixStore.S3.Fake.put(key, body, opts) end)

    @impl true
    def put_stream(key, stream, opts),
      do: trace(:put_stream, key, fn -> SalixStore.S3.Fake.put_stream(key, stream, opts) end)

    @impl true
    def get(key, opts), do: trace(:get, key, fn -> SalixStore.S3.Fake.get(key, opts) end)

    @impl true
    def stream(key, opts), do: trace(:stream, key, fn -> SalixStore.S3.Fake.stream(key, opts) end)

    @impl true
    def head(key), do: trace(:head, key, fn -> SalixStore.S3.Fake.head(key) end)

    @impl true
    def delete(key, opts),
      do: trace(:delete, key, fn -> SalixStore.S3.Fake.delete(key, opts) end)

    @impl true
    def list(prefix, opts),
      do: trace(:list, prefix, fn -> SalixStore.S3.Fake.list(prefix, opts) end)

    @impl true
    def multipart_create(key, opts),
      do:
        trace(:multipart_create, key, fn ->
          SalixStore.S3.Fake.multipart_create(key, opts)
        end)

    @impl true
    def multipart_upload_part(key, upload_id, part_number, body),
      do:
        trace(:multipart_upload_part, key, fn ->
          SalixStore.S3.Fake.multipart_upload_part(key, upload_id, part_number, body)
        end)

    @impl true
    def multipart_complete(key, upload_id, parts),
      do:
        trace(:multipart_complete, key, fn ->
          SalixStore.S3.Fake.multipart_complete(key, upload_id, parts)
        end)

    @impl true
    def multipart_abort(key, upload_id),
      do:
        trace(:multipart_abort, key, fn ->
          SalixStore.S3.Fake.multipart_abort(key, upload_id)
        end)

    @impl true
    def multipart_uploads(prefix, opts),
      do:
        trace(:multipart_uploads, prefix, fn ->
          SalixStore.S3.Fake.multipart_uploads(prefix, opts)
        end)

    defp trace(operation, key, fun) do
      seq = SystemsRuntime.Proc.unique_integer([:positive, :monotonic])
      started_at = SystemsClock.monotonic_time(:microsecond)

      {delay_ms, delayed?} =
        SystemsRuntime.Agent.get(__MODULE__, fn state ->
          delayed? =
            state.delay_keys == :all or
              (is_struct(state.delay_keys, MapSet) and MapSet.member?(state.delay_keys, key))

          {state.delay_ms, delayed?}
        end)

      if delayed?, do: SystemsClock.sleep(delay_ms)
      result = fun.()
      finished_at = SystemsClock.monotonic_time(:microsecond)

      SystemsRuntime.Agent.update(__MODULE__, fn state ->
        event = %{
          seq: seq,
          operation: operation,
          key: key,
          started_at: started_at,
          finished_at: finished_at
        }

        %{state | events: [event | state.events]}
      end)

      result
    end
  end

  setup context do
    old_authorization = SystemsRuntime.get_env(:salix_agent, :storage_authorization_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    on_exit(fn -> restore_env(:storage_authorization_mod, old_authorization) end)
    SalixAgent.TestSupport.stop_all_agents()
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{"type" => "session_created", "session_id" => @session, "name" => "Async terminal"},
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => "call-terminal",
          "tool_name" => Map.get(context, :tool_name, "env.exec"),
          "status" => "running",
          "started_at" => 1_000
        }
      ])

    # This suite deliberately leaves an actor mid-retry; a completion commit
    # wakes a round, so a stray actor surviving into the next test would eat
    # that test's scripted LLM response. Stop them at the boundary.
    on_exit(fn -> SalixAgent.TestSupport.stop_all_agents() end)

    {:ok, agent_id: agent_id}
  end

  defp actor_pid(agent_id) do
    {:ok, _} =
      InternalSessionFleet.ensure_started(agent_id, @session, process_on_init: false)

    [{pid, _}] =
      SystemsRuntime.Registry.lookup(
        SalixAgent.Registry,
        InternalSessionActor.key(agent_id, @session)
      )

    # Ownership is published before the root finishes its claim. Drain its
    # startup busy? probe before installing the terminal-completion fixture.
    assert {:parked, _owned} = SalixAgent.Server.info(agent_id)

    pid
  end

  defp pending(agent_id) do
    %{
      session_id: @session,
      tool_call_id: "call-terminal",
      tool_name: "env.exec",
      agent_id: agent_id,
      role: "worker",
      billing_context: %{
        "billing_account_id" => "test-roundtrip-billing-account",
        "tenant_id" => SalixStore.Ids.tenant_id_from_agent!(agent_id),
        "group_id" => SalixStore.Ids.group_id_from_agent!(agent_id)
      },
      actor_type: "tool",
      task: nil,
      started_at: 1_000
    }
  end

  defp result do
    %{
      "tool_call_id" => "call-terminal",
      "status" => "completed",
      "content" => "terminal payload",
      "output" => "terminal payload",
      "events" => [%{"type" => "vfs_delete", "path" => "/completed-command.tmp"}]
    }
  end

  for {outcome, command_result} <- [
        {"approved",
         %{"status" => "completed", "exit_code" => 0, "stdout" => "0\n", "stderr" => ""}},
        {"cancelled",
         %{
           "status" => "completed",
           "exit_code" => 1,
           "stdout" => "",
           "stderr" => "User canceled. (-128)"
         }},
        {"timeout",
         %{
           "status" => "timeout",
           "exit_code" => -1,
           "stdout" => "",
           "stderr" => "timed out after 180s"
         }}
      ] do
    @tag tool_name: "env.exec"
    @command_result command_result
    test "native authorization #{outcome} preserves the command result in one async completion",
         %{agent_id: agent_id} do
      pid = actor_pid(agent_id)

      SystemsRuntime.Server.replace_state(
        pid,
        fn state -> %{state | pending_llm: %{test_hold: true}} end,
        :infinity
      )

      content = Jason.encode!(@command_result)

      terminal =
        Map.merge(result(), %{"content" => content, "output" => content, "error" => false})

      {job, _} =
        install_dependency_pending(pid, agent_id, fn -> terminal end, tool_name: "env.exec")

      assert {:ok, before} = SalixAgent.InternalSessionStore.read(agent_id, @session)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(before, "call-terminal")

      SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, terminal})

      assert eventually(fn ->
               {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)

               match?(
                 {:ok, %{"status" => "completed"}},
                 SalixAgent.InternalSession.lookup_async_call(state, "call-terminal")
               )
             end)

      # A repeated delivery of the same job result must not produce another terminal notification.
      SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, terminal})
      SystemsRuntime.Server.get_state(pid, :infinity)

      {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)

      [notification] =
        Enum.filter(SalixAgent.InternalSession.get(state, :input_queue), fn item ->
          get_in(item, ["payload", "runtime_message_id"]) == "tool-call-result:call-terminal"
        end)

      payload = notification |> get_in(["payload", "content"]) |> Jason.decode!()
      assert Jason.decode!(payload["result"]["content"]) == @command_result
    end
  end

  test "async settlement joins workspace durability with the work marker before session CAS", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    workspace_key = Keys.agent_workspace_state(agent_id)
    work_marker_key = Keys.agent_session_work_index(agent_id, :internal, @session)
    session_key = Keys.agent_internal_runtime_session(agent_id, @session)

    # Hold the next activation out of this settlement-only assertion. The
    # dependency completion still runs in the owning Session actor.
    SystemsRuntime.Server.replace_state(
      pid,
      fn state ->
        %{state | pending_llm: %{test_hold: true}}
      end,
      :infinity
    )

    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, workspace_key})

    on_exit(fn ->
      if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
        do: SalixStore.S3.Fake.release_pause()
    end)

    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, result()})

    assert eventually(&SalixStore.S3.Fake.paused?/0)

    # Once the workspace read has fixed the idempotent result identity, the
    # workspace PUT and marker PUT are independent prerequisites. The marker
    # must be able to land while the workspace PUT response is still parked.
    assert eventually(fn ->
             work_marker_key in SalixStore.S3.Fake.put_log()
           end)

    # Publication still joins both prerequisites: no Session CAS may cross
    # the durability fence until the workspace branch completes.
    refute session_key in SalixStore.S3.Fake.put_log()

    assert :ok = SalixStore.S3.Fake.release_pause()

    assert eventually(fn ->
             session_key in SalixStore.S3.Fake.put_log()
           end)
  end

  test "a retryable session-commit failure keeps the only terminal copy and lands it once", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    key = Keys.agent_internal_runtime_session(agent_id, @session)

    # One retryable storage failure on the session object: the terminal must
    # be retained and retried, never dropped — it is the only durable copy.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    SystemsRuntime.Proc.send(
      pid,
      {:retry_async_tool_commit, SystemsRuntime.Proc.make_ref(), pending(agent_id), result(), 0}
    )

    assert eventually(fn ->
             case InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-terminal") do
               {:ok, %{"status" => "completed"}} -> true
               _ -> false
             end
           end)

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

             Enum.count(
               SalixAgent.InternalSession.get(session, :messages) || [],
               &materialized_terminal?/1
             ) == 1 and
               not Enum.any?(
                 SalixAgent.InternalSession.get(session, :input_queue) || [],
                 &queued_terminal?/1
               )
           end)

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    record =
      session
      |> SalixAgent.InternalSession.get(:messages)
      |> Enum.find(&materialized_terminal?/1)

    assert {queue_id, "runtime_message", _dedupe, payload} = record[:accepted_input]
    assert queue_id > 0
    assert queued_terminal?(%{"payload" => payload})

    assert Enum.count(
             SalixAgent.InternalSession.get(session, :async_results),
             &(&1["tool_call_id"] == "call-terminal")
           ) == 1

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :async_results),
             &(&1["kind"] == "tool_result")
           )

    refute Enum.any?(
             Map.keys(SalixAgent.InternalSession.get(session, :async_result_refs)),
             &SalixStore.Ids.valid_tool_result_ref?/1
           )

    operation_id =
      SalixAgent.WorkspaceEvents.operation_id(
        "async-tool-result",
        agent_id,
        @session,
        "call-terminal"
      )

    assert {:ok, staged_small_result} =
             SalixAgent.AgentWorkspace.operation_result(agent_id, operation_id)

    refute Map.has_key?(staged_small_result, "_tool_result_projection")
  end

  test "a large zero-wait terminal atomically stores its source and sends one budgeted capsule",
       %{
         agent_id: agent_id
       } do
    pid = actor_pid(agent_id)
    key = Keys.agent_internal_runtime_session(agent_id, @session)

    # Match the production Composio route while retaining the suite's real
    # actor-owned dependency scheduling/terminal commit seam.
    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent_id, @session, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session,
                 "tool_call_id" => "call-terminal",
                 "tool_name" => "composio.execute",
                 "status" => "running",
                 "started_at" => 1_000
               }
             ])

    # The canonical content alone remains below 120KB. The complete unpaged
    # runtime message list (base completion fields + JSON escaping + outer
    # list) crosses the cap, proving the decision is envelope-based rather
    # than a content-length shortcut.
    canonical_content =
      Jason.encode!(%{
        "messages" => [
          %{
            "id" => "gmail-message-1",
            "subject" => "production-shaped Gmail result",
            "payload" => String.duplicate("x", 119_250)
          }
        ]
      })

    large_result = %{
      "tool_call_id" => "call-terminal",
      "name" => "composio.execute",
      "events" => [%{"type" => "vfs_delete", "path" => "/completed-command.tmp"}],
      "status" => "completed",
      "content" => canonical_content,
      "output" => canonical_content,
      "error" => false
    }

    {job, _dependency_pid} =
      install_dependency_pending(pid, agent_id, fn -> large_result end,
        tool_name: "composio.execute"
      )

    # Keep the committed wake in the queue so this test, rather than a mocked
    # LLM, materializes and measures the exact provider-facing runtime row.
    SystemsRuntime.Server.replace_state(
      pid,
      fn state ->
        %{state | pending_llm: %{test_hold: true}}
      end,
      :infinity
    )

    # Workspace staging succeeds, then the whole session batch fails once.
    # There must be no state where only the canonical source or only its
    # capsule is durable in the session journal.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})
    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, large_result})

    assert eventually(fn ->
             map_size(SystemsRuntime.Server.get_state(pid, :infinity).pending_async_tool_commits) ==
               1
           end)

    operation_id =
      SalixAgent.WorkspaceEvents.operation_id(
        "async-tool-result",
        agent_id,
        @session,
        "call-terminal"
      )

    assert eventually(fn ->
             match?(
               {:ok, %{"_tool_result_projection" => %{"result_ref" => _}}},
               SalixAgent.AgentWorkspace.operation_result(agent_id, operation_id)
             )
           end)

    assert {:ok,
            %{
              "_tool_result_projection" => %{
                "result_ref" => staged_ref,
                "stored_at_ms" => staged_at_ms
              }
            }} =
             SalixAgent.AgentWorkspace.operation_result(agent_id, operation_id)

    assert SalixStore.Ids.valid_tool_result_ref?(staged_ref)
    assert is_integer(staged_at_ms)

    assert {:ok, before_retry} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    refute Map.has_key?(
             SalixAgent.InternalSession.get(before_retry, :async_result_refs),
             staged_ref
           )

    refute Enum.any?(
             SalixAgent.InternalSession.get(before_retry, :async_results),
             &(&1["result_ref"] == staged_ref)
           )

    # Exercise the real restart planner, which reads the staged workspace
    # operation and delegates reconstruction to SessionToolExecution. It must
    # reuse the first attempt's identity rather than minting a repair ref.
    {recovery_events, _next_id} = SalixAgent.Repair.plan_session(before_retry)

    assert %{
             "type" => "tool_result_stored",
             "result_ref" => ^staged_ref,
             "stored_at_ms" => ^staged_at_ms
           } = Enum.find(recovery_events, &(&1["type"] == "tool_result_stored"))

    assert %{
             "completed_at" => ^staged_at_ms
           } =
             Enum.find(recovery_events, fn event ->
               event["type"] in ["async_tool_call_completed", "async_tool_call_failed"] and
                 event["tool_call_id"] == "call-terminal"
             end)

    recovery_notification =
      Enum.find(recovery_events, fn event ->
        event["type"] == "queue_append" and event["kind"] == "runtime_message"
      end)

    assert %{"stored_result" => true, "result_ref" => ^staged_ref} =
             recovery_notification
             |> get_in(["payload", "content"])
             |> Jason.decode!()

    assert recovery_notification["created_at"] == div(staged_at_ms, 1_000)

    assert eventually(fn ->
             with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, @session),
                  {:ok, stored} <-
                    SalixAgent.InternalSession.lookup_async_call(session, staged_ref),
                  {:ok, terminal} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               stored["kind"] == "tool_result" and
                 stored["stored_at_ms"] == staged_at_ms and
                 terminal["kind"] == "async_result"
             else
               _ -> false
             end
           end)

    assert {:ok, committed} = SalixAgent.InternalSessionStore.read(agent_id, @session)
    assert {:ok, stored} = SalixAgent.InternalSession.lookup_async_call(committed, staged_ref)

    assert {:ok, terminal} =
             SalixAgent.InternalSession.lookup_async_call(committed, "call-terminal")

    assert stored["stored_at_ms"] == staged_at_ms
    assert terminal["completed_at"] == staged_at_ms

    assert stored["result_json"] == Jason.encode!(canonical_content)
    assert stored["result_bytes"] == byte_size(stored["result_json"])
    assert stored["result_chars"] == String.length(stored["result_json"])

    assert stored["result_bytes"] <
             SalixAgent.ToolResultProjection.model_envelope_max_bytes()

    assert stored["result_sha256"] ==
             :crypto.hash(:sha256, stored["result_json"])
             |> Base.encode16(case: :lower)

    terminal_capsule = Jason.decode!(terminal["result"]["content"])
    assert terminal_capsule["stored_result"] == true
    assert terminal_capsule["result_ref"] == staged_ref
    refute Map.has_key?(terminal_capsule, "result_page")

    assert [queued] =
             Enum.filter(SalixAgent.InternalSession.get(committed, :input_queue) || [], fn item ->
               get_in(item, ["payload", "runtime_message_id"]) ==
                 "tool-call-result:call-terminal"
             end)

    runtime_capsule = queued |> get_in(["payload", "content"]) |> Jason.decode!()
    assert runtime_capsule["stored_result"] == true
    assert runtime_capsule["result_ref"] == staged_ref
    refute Map.has_key?(runtime_capsule, "result")
    refute Map.has_key?(runtime_capsule, "result_page")

    {materialize_events, _wake?, hwm} =
      SalixAgent.InternalSession.materialize_pending_input_events(
        committed,
        length(SalixAgent.InternalSession.get(committed, :input_queue) || [])
      )

    assert {:ok, materialized} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session,
               materialize_events,
               hwm: hwm
             )

    runtime_message =
      materialized
      |> SalixAgent.Compaction.context()
      |> Enum.find(fn message ->
        (message[:runtime_message_id] || message["runtime_message_id"]) ==
          "tool-call-result:call-terminal"
      end)

    assert is_map(runtime_message)

    assert runtime_message
           |> then(&Jason.encode!([&1]))
           |> byte_size() <= SalixAgent.ToolResultProjection.model_envelope_max_bytes()

    full_content =
      SalixAgent.Waits.async_completion_content(
        %{"tool_call_id" => "call-terminal", "tool_name" => "composio.execute"},
        large_result,
        %{"result" => SalixAgent.AsyncToolResults.stored_result(large_result)}
      )

    assert runtime_message
           |> Map.put(:content, full_content)
           |> then(&Jason.encode!([&1]))
           |> byte_size() > SalixAgent.ToolResultProjection.model_envelope_max_bytes()
  end

  test "a staged large terminal keeps its ref when repair exhaustion suppresses notification", %{
    agent_id: agent_id
  } do
    private_diagnostic = String.duplicate("private provider failure ", 6_000)
    result_ref = SalixStore.Ids.new_tool_result_ref()
    stored_at_ms = 1_700_000_000_123

    failed_result = %{
      "tool_call_id" => "call-terminal",
      "name" => "env.exec",
      "status" => "failed",
      "content" => private_diagnostic,
      "output" => private_diagnostic,
      "error" => true,
      "error_class" => "provider_error",
      "error_message" => private_diagnostic
    }

    staged_result =
      Map.put(failed_result, "_tool_result_projection", %{
        "result_ref" => result_ref,
        "stored_at_ms" => stored_at_ms
      })

    # This test plans events directly, so keep the owner passive and prevent
    # SessionWorkRecovery from mutating the same fixture between snapshots.
    assert {:ok, %{"_tool_result_projection" => staged_projection}} =
             SalixAgent.WorkspaceEvents.commit_result(
               agent_id,
               @session,
               staged_result,
               SalixAgent.AsyncToolResults.operation_source(:internal),
               store_result: true,
               process_on_init: false
             )

    assert staged_projection == %{
             "result_ref" => result_ref,
             "stored_at_ms" => stored_at_ms
           }

    assert {:ok, exhausted} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session,
               SalixAgent.VisibleReplyPolicy.transition_events(
                 {:exhausted, SalixAgent.VisibleReplyPolicy.repair_budget()},
                 @session,
                 0
               )
             )

    assert SalixAgent.InternalSession.visible_reply_repair_exhausted?(exhausted)

    assert {:ok, events, _observed_result} =
             SalixAgent.SessionToolExecution.commit_async(
               agent_id,
               @session,
               :internal,
               pending(agent_id),
               failed_result
             )

    assert [stored_event] = Enum.filter(events, &(&1["type"] == "tool_result_stored"))
    assert stored_event["result_ref"] == result_ref
    assert stored_event["stored_at_ms"] == stored_at_ms
    assert stored_event["result_json"] == Jason.encode!(private_diagnostic)

    assert [terminal_event] =
             Enum.filter(events, &(&1["type"] == "async_tool_call_failed"))

    assert terminal_event["completed_at"] == stored_at_ms
    assert terminal_event["result"]["content"] == terminal_event["error_message"]

    assert %{"stored_result" => true, "result_ref" => ^result_ref} =
             Jason.decode!(terminal_event["result"]["content"])

    refute Enum.any?(events, &(&1["type"] == "queue_append"))
    refute String.contains?(inspect(events), "_tool_result_projection")

    committed = SalixAgent.InternalSession.apply_events(exhausted, events)
    assert {:ok, stored} = SalixAgent.InternalSession.lookup_async_call(committed, result_ref)
    assert stored["result_json"] == Jason.encode!(private_diagnostic)

    assert {:ok, terminal} =
             SalixAgent.InternalSession.lookup_async_call(committed, "call-terminal")

    assert terminal["completed_at"] == stored_at_ms
  end

  test "a stale retry never resurrects a completion beside a durable cancellation", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)

    # The call is cancelled through the reducer's own terminal event first.
    {:ok, cancelled} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{
          "type" => "async_tool_call_cancelled",
          "session_id" => @session,
          "tool_call_id" => "call-terminal",
          "completed_at" => 2_000
        }
      ])

    assert {:ok, %{"status" => "cancelled"}} =
             SalixAgent.InternalSession.lookup_async_call(
               cancelled,
               "call-terminal"
             )

    queue_before = length(SalixAgent.InternalSession.get(cancelled, :input_queue) || [])

    # A retry captured before the cancellation now fires. It must be dropped:
    # re-committing would enqueue a completion notification beside the
    # durable cancelled terminal.
    SystemsRuntime.Proc.send(
      pid,
      {:retry_async_tool_commit, SystemsRuntime.Proc.make_ref(), pending(agent_id), result(), 1}
    )

    _ = SystemsRuntime.Server.get_state(pid, :infinity)

    {:ok, after_retry} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    assert {:ok, %{"status" => "cancelled"}} =
             SalixAgent.InternalSession.lookup_async_call(
               after_retry,
               "call-terminal"
             )

    assert length(SalixAgent.InternalSession.get(after_retry, :input_queue) || []) == queue_before

    # Cancellation is the ONE terminal: no completion record was resurrected
    # beside it, and no completion notification was enqueued.
    terminals =
      Enum.filter(
        SalixAgent.InternalSession.get(after_retry, :async_results),
        &(&1["tool_call_id"] == "call-terminal")
      )

    assert [%{"status" => "cancelled"}] = terminals
  end

  test "process-local completion can hand the same call to an external callback without terminalizing it",
       %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    handoff_result = handoff_result()

    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, handoff_result})

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

             with {:ok, call} <-
                    SalixAgent.InternalSession.lookup_async_call(
                      session,
                      "call-terminal"
                    ) do
               call["status"] == "running" and
                 call["completion_mode"] == "external_callback" and
                 handoff_notification_committed?(session)
             else
               _ -> false
             end
           end)

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

             Enum.count(
               SalixAgent.InternalSession.get(session, :messages) || [],
               &materialized_handoff?/1
             ) == 1 and
               not Enum.any?(
                 SalixAgent.InternalSession.get(session, :input_queue) || [],
                 &queued_handoff?/1
               )
           end)

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :async_results),
             &(&1["tool_call_id"] == "call-terminal")
           )

    assert SystemsRuntime.Server.get_state(pid, :infinity).pending_async_tools == %{}
  end

  test "a callback terminal absorbs a late process-local handoff", %{agent_id: agent_id} do
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "callback terminal observed"}])

    on_exit(fn ->
      :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)

      if previous_llm,
        do: SystemsRuntime.put_env(:salix_agent, :llm, previous_llm),
        else: SystemsRuntime.delete_env(:salix_agent, :llm)
    end)

    pid = actor_pid(agent_id)
    late_handoff = handoff_result(wait?: true)

    {job, dependency_pid} =
      install_dependency_pending(pid, agent_id, fn -> late_handoff end)

    dependency_ref = SystemsRuntime.Proc.monitor(dependency_pid)

    # Keep the setup dependency parked while the host resolves the exact
    # durable call through the actor's callback surface.
    assert {:ok, %{"status" => "completed", "tool_call_id" => "call-terminal"}} =
             InternalSessionActor.complete_async_tool_call(
               pid,
               "call-terminal",
               result(),
               %{"tool_call_id" => "call-terminal", "tool_name" => "env.exec"}
             )

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

             match?(
               {:ok, %{"status" => "completed"}},
               SalixAgent.InternalSession.lookup_async_call(
                 session,
                 "call-terminal"
               )
             ) and terminal_notification_count(session) == 1
           end)

    {:ok, terminal_session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    assert {:ok, terminal_record} =
             SalixAgent.InternalSession.lookup_async_call(
               terminal_session,
               "call-terminal"
             )

    terminal_refs = SalixAgent.InternalSession.get(terminal_session, :async_result_refs)
    terminal_results = SalixAgent.InternalSession.get(terminal_session, :async_results)

    # The callback terminal synchronously revokes the original setup owner.
    # A result that was already queued with the old token is now stale.
    settle_receive({:DOWN, ^dependency_ref, :process, ^dependency_pid, _reason})
    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, late_handoff})
    _ = SystemsRuntime.Server.get_state(pid, :infinity)

    {:ok, after_handoff} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    assert {:ok, ^terminal_record} =
             SalixAgent.InternalSession.lookup_async_call(
               after_handoff,
               "call-terminal"
             )

    assert SalixAgent.InternalSession.get(after_handoff, :async_result_refs) == terminal_refs
    assert SalixAgent.InternalSession.get(after_handoff, :async_results) == terminal_results

    refute Map.has_key?(
             SalixAgent.InternalSession.get(after_handoff, :async_tool_calls),
             "call-terminal"
           )

    assert terminal_notification_count(after_handoff) == 1
    assert handoff_notification_count(after_handoff) == 0

    assert SalixAgent.InternalSession.wait(after_handoff) ==
             SalixAgent.InternalSession.wait(terminal_session)

    assert SystemsRuntime.Server.get_state(pid, :infinity).pending_async_tools == %{}
  end

  # A wake=true runtime notification may still be queued or may already have
  # been materialized into the durable transcript by the live actor. Both are
  # the same committed handoff; checking both avoids racing that queue drain.
  defp handoff_notification_committed?(session) do
    queued? =
      Enum.any?(SalixAgent.InternalSession.get(session, :input_queue) || [], &queued_handoff?/1)

    materialized? =
      Enum.any?(
        SalixAgent.InternalSession.get(session, :messages) || [],
        &materialized_handoff?/1
      )

    queued? or materialized?
  end

  defp queued_handoff?(entry) do
    payload = entry["payload"] || %{}

    payload["runtime_message_id"] == "tool-call-handoff:call-terminal" and
      payload["type"] == "tool_call_handoff" and
      payload["source_tool_call_id"] == "call-terminal" and
      String.contains?(payload["content"] || "", "example.test/approve")
  end

  defp materialized_handoff?(message) do
    runtime_message_id = message[:runtime_message_id] || message["runtime_message_id"]
    type = message[:type] || message["type"]
    source_tool_call_id = message[:source_tool_call_id] || message["source_tool_call_id"]
    content = message[:content] || message["content"] || ""

    runtime_message_id == "tool-call-handoff:call-terminal" and
      type == "tool_call_handoff" and
      source_tool_call_id == "call-terminal" and
      String.contains?(content, "example.test/approve")
  end

  defp handoff_notification_count(session) do
    Enum.count(SalixAgent.InternalSession.get(session, :input_queue) || [], &queued_handoff?/1) +
      Enum.count(
        SalixAgent.InternalSession.get(session, :messages) || [],
        &materialized_handoff?/1
      )
  end

  defp queued_terminal?(entry) do
    payload = entry["payload"] || %{}

    payload["runtime_message_id"] == "tool-call-result:call-terminal" and
      payload["type"] == "tool_call_completed" and
      payload["source_tool_call_id"] == "call-terminal" and
      String.contains?(payload["content"] || "", "terminal payload")
  end

  defp materialized_terminal?(message) do
    runtime_message_id = message[:runtime_message_id] || message["runtime_message_id"]
    type = message[:type] || message["type"]
    source_tool_call_id = message[:source_tool_call_id] || message["source_tool_call_id"]
    content = message[:content] || message["content"] || ""

    runtime_message_id == "tool-call-result:call-terminal" and
      type == "tool_call_completed" and
      source_tool_call_id == "call-terminal" and
      String.contains?(content, "terminal payload")
  end

  defp terminal_notification_count(session) do
    Enum.count(SalixAgent.InternalSession.get(session, :input_queue) || [], &queued_terminal?/1) +
      Enum.count(
        SalixAgent.InternalSession.get(session, :messages) || [],
        &materialized_terminal?/1
      )
  end

  defp handoff_result(opts \\ []) do
    events = [
      %{
        "type" => "async_tool_call_started",
        "session_id" => @session,
        "tool_call_id" => "call-terminal",
        "tool_name" => "permission.request",
        "status" => "running",
        "completion_mode" => "external_callback",
        "started_at" => SystemsClock.system_time(:millisecond)
      }
    ]

    events =
      if Keyword.get(opts, :wait?, false) do
        events ++
          [
            %{
              "type" => "wait_set",
              "session_id" => @session,
              "wait" => %{
                "wait_id" => "late-handoff-wait",
                "reason" => "waiting for a callback that already arrived"
              }
            }
          ]
      else
        events
      end

    %{
      id: "call-terminal",
      name: "permission.request",
      status: "async_running",
      content: "approval URL: https://example.test/approve",
      output: "approval URL: https://example.test/approve",
      error: false,
      events: events
    }
  end

  defp install_dependency_pending(pid, agent_id, result_fun \\ &result/0, opts \\ [])
       when is_function(result_fun, 0) and is_list(opts) do
    tool_name = Keyword.get(opts, :tool_name, "env.exec")
    tool_call_id = Keyword.get(opts, :tool_call_id, "call-terminal")
    trace_ctx = Keyword.get(opts, :trace_ctx)

    {:ok, job} =
      DependencyJob.start(
        :tool,
        "test-terminal-tenant",
        fn ->
          SystemsRuntime.Proc.receive do
            :release -> result_fun.()
          end
        end,
        timeout_ms: 60_000
      )

    dependency_pending =
      pending(agent_id)
      |> Map.merge(%{
        tool_name: tool_name,
        tool_call_id: tool_call_id,
        dependency_job: job,
        ref: job.ref,
        pid: job.pid,
        call: %{id: tool_call_id, name: tool_name, args: %{}}
      })
      |> then(fn p -> if trace_ctx, do: Map.put(p, :trace_ctx, trace_ctx), else: p end)

    SystemsRuntime.Server.replace_state(
      pid,
      fn state ->
        %{
          state
          | pending_async_tools: Map.put(state.pending_async_tools, job.token, dependency_pending)
        }
      end,
      :infinity
    )

    {job, job.pid}
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

  test "terminal storage failure gates speculative response until the retained result commits",
       %{
         agent_id: agent_id
       } do
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    previous_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    SystemsRuntime.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    SystemsRuntime.PersistentTerm.put({BlockingCaptureLLM, :owner}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      SystemsRuntime.PersistentTerm.erase({BlockingCaptureLLM, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    token = job.token
    session_key = Keys.agent_internal_runtime_session(agent_id, @session)
    accepted_result = result()

    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, session_key})
    SystemsRuntime.Proc.send(pid, {:dependency_job_result, token, accepted_result})

    state = SystemsRuntime.Server.get_state(pid, :infinity)
    assert state.pending_async_tools == %{}

    assert %{^token => %{pending: retained, result: ^accepted_result}} =
             state.pending_async_tool_commits

    assert {:ok, %{"status" => "running"}} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-terminal")

    settle_receive({:activation_llm_request, speculative_pid, speculative_messages, _})
    assert Enum.count(speculative_messages, &(&1[:source_tool_call_id] == "call-terminal")) == 1
    SystemsRuntime.Proc.send(speculative_pid, :release_activation_llm)

    # Computation may finish, but its result stays behind the failed fence.
    # A retry must retain the tool outcome and must not dispatch another model.
    SystemsRuntime.Proc.send(pid, {:retry_async_tool_commit, token, retained, accepted_result, 1})

    assert %{^token => %{result: ^accepted_result}} =
             SystemsRuntime.Server.get_state(pid, :infinity).pending_async_tool_commits

    settle_refute_receive({:activation_llm_request, _, _, _}, 200)
    assert SystemsRuntime.Proc.alive?(speculative_pid)
    assert SystemsRuntime.Server.get_state(pid, :infinity).pending_llm.pid == speculative_pid

    :ok = SalixStore.S3.Fake.clear_blackhole()
    SystemsRuntime.Proc.send(pid, {:retry_async_tool_commit, token, retained, accepted_result, 2})

    settle_receive({:activation_llm_request, llm_pid, messages, _tools})

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(llm_pid),
        do: SystemsRuntime.Proc.send(llm_pid, :release_activation_llm)
    end)

    assert Enum.count(messages, &(&1[:source_tool_call_id] == "call-terminal")) == 1
    assert SystemsRuntime.Server.get_state(pid, :infinity).pending_async_tool_commits == %{}

    assert {:ok, %{"status" => "completed"} = terminal} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-terminal")

    assert String.contains?(inspect(terminal), "terminal payload")
    settle_refute_receive({:activation_llm_request, _, _, _}, 100)
    SystemsRuntime.Proc.send(llm_pid, :release_activation_llm)
  end

  @tag :session_optimization
  test "a mutation-free non-replayable terminal keeps its full result in the Session receipt", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    SystemsRuntime.Server.replace_state(pid, &%{&1 | pending_llm: %{test_hold: true}}, :infinity)
    content = String.duplicate("retained command output ", 10_000)

    terminal =
      result()
      |> Map.delete("events")
      |> Map.merge(%{"content" => content, "output" => content, "name" => "env.exec"})

    {job, _} =
      install_dependency_pending(pid, agent_id, fn -> terminal end, tool_name: "env.exec")

    workspace = Keys.agent_workspace_state(agent_id)
    :ok = SalixStore.S3.Fake.reset_put_log()
    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, terminal})
    SystemsRuntime.Server.get_state(pid, :infinity)
    {:ok, session} = InternalSessionStore.read(agent_id, @session)
    {:ok, call} = SalixAgent.InternalSession.lookup_async_call(session, "call-terminal")
    assert call["status"] == "completed"
    refute workspace in SalixStore.S3.Fake.put_log()
    sources = SalixAgent.InternalSession.get(session, :async_results)

    assert Enum.any?(sources, fn record ->
             is_binary(record["result_json"]) and String.contains?(record["result_json"], content)
           end)

    # Restart consumes the terminal receipt. It does not execute the command again.
    assert {[], _} = SalixAgent.Repair.plan_session(session)
  end

  test "async result becomes durable while next-round billing is still pending", %{
    agent_id: agent_id
  } do
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    previous_meter = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    SystemsRuntime.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, GatedMetering)
    SystemsRuntime.PersistentTerm.put({BlockingCaptureLLM, :owner}, SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put({GatedMetering, :owner}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_metering_mod, previous_meter)
      SystemsRuntime.PersistentTerm.erase({BlockingCaptureLLM, :owner})
      SystemsRuntime.PersistentTerm.erase({GatedMetering, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _} = install_dependency_pending(pid, agent_id)
    SystemsRuntime.Proc.send(pid, {:dependency_job_result, job.token, result()})
    settle_receive({:billing_waiting, billing})

    assert eventually(fn ->
             with {:ok, session} <- InternalSessionStore.read(agent_id, @session),
                  {:ok, %{"status" => "completed"}} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               true
             else
               _ -> false
             end
           end)

    settle_refute_receive({:activation_llm_request, _, _, _}, 50)
    SystemsRuntime.Proc.send(billing, :allow_billing)
    settle_receive({:activation_llm_request, llm, _, _})
    SystemsRuntime.Proc.send(llm, :release_activation_llm)
  end
end
