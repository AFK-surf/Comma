defmodule SalixAgent.InternalSessionAsyncTerminalTest do
  use ExUnit.Case, async: false

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
    def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)

    @impl true
    def resolve_record(agent),
      do: SalixAgent.Templates.resolve_llm_for_template(agent["template_id"])
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
      send(:persistent_term.get({__MODULE__, :owner}), {:billing_waiting, self()})

      receive do
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
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:activation_llm_request, self(), messages, tools})

      receive do
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
      owner = :persistent_term.get({__MODULE__, :owner})

      send(
        owner,
        {:timed_activation_llm_request, self(), System.monotonic_time(:microsecond), messages,
         tools}
      )

      receive do
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
      send(Application.fetch_env!(:salix_agent, :async_phase_test_pid), {:phase, fact})
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
      Agent.start_link(
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

    def reset, do: Agent.update(__MODULE__, &%{&1 | events: []})
    def events, do: Agent.get(__MODULE__, &Enum.sort_by(&1.events, fn event -> event.seq end))

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
      seq = System.unique_integer([:positive, :monotonic])
      started_at = System.monotonic_time(:microsecond)

      {delay_ms, delayed?} =
        Agent.get(__MODULE__, fn state ->
          delayed? =
            state.delay_keys == :all or
              (is_struct(state.delay_keys, MapSet) and MapSet.member?(state.delay_keys, key))

          {state.delay_ms, delayed?}
        end)

      if delayed?, do: Process.sleep(delay_ms)
      result = fun.()
      finished_at = System.monotonic_time(:microsecond)

      Agent.update(__MODULE__, fn state ->
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
    old_authorization = Application.get_env(:salix_agent, :storage_authorization_mod)

    Application.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    on_exit(fn -> restore_env(:storage_authorization_mod, old_authorization) end)
    SalixAgent.TestSupport.stop_all_agents()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
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
      Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, @session))

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
      :sys.replace_state(pid, fn state -> %{state | pending_llm: %{test_hold: true}} end)

      content = Jason.encode!(@command_result)

      terminal =
        Map.merge(result(), %{"content" => content, "output" => content, "error" => false})

      {job, _} =
        install_dependency_pending(pid, agent_id, fn -> terminal end, tool_name: "env.exec")

      assert {:ok, before} = SalixAgent.InternalSessionStore.read(agent_id, @session)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(before, "call-terminal")

      send(pid, {:dependency_job_result, job.token, terminal})

      assert eventually(fn ->
               {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)

               match?(
                 {:ok, %{"status" => "completed"}},
                 SalixAgent.InternalSession.lookup_async_call(state, "call-terminal")
               )
             end)

      # A repeated delivery of the same job result must not produce another terminal notification.
      send(pid, {:dependency_job_result, job.token, terminal})
      :sys.get_state(pid)

      {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)

      [notification] =
        Enum.filter(SalixAgent.InternalSession.get(state, :input_queue), fn item ->
          get_in(item, ["payload", "runtime_message_id"]) == "tool-call-result:call-terminal"
        end)

      payload = notification |> get_in(["payload", "content"]) |> Jason.decode!()
      assert Jason.decode!(payload["result"]["content"]) == @command_result
    end
  end

  test "settling a background result emits its pickup and commit as phase facts", %{
    agent_id: agent_id
  } do
    prev = Application.get_env(:salix_agent, :agent_observability_mod)
    Application.put_env(:salix_agent, :agent_observability_mod, PhaseCollector)
    Application.put_env(:salix_agent, :async_phase_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :agent_observability_mod, prev),
        else: Application.delete_env(:salix_agent, :agent_observability_mod)

      Application.delete_env(:salix_agent, :async_phase_test_pid)
    end)

    pid = actor_pid(agent_id)

    # Hold the continuation out: only the settlement path is under test. A
    # held actor is "blocked", so no parallel config build starts and no
    # async_config fact is owed.
    :sys.replace_state(pid, fn state -> %{state | pending_llm: %{test_hold: true}} end)

    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    send(pid, {:dependency_job_result, job.token, Map.put(result(), "duration_ms", 250)})

    assert_receive {:phase,
                    %{
                      phase: "async_pickup",
                      session_id: @session,
                      salix_agent_id: ^agent_id,
                      actor_type: "tool",
                      started_at: pickup_at,
                      duration_ms: pickup_ms
                    }},
                   5_000

    assert_receive {:phase,
                    %{phase: "async_commit", started_at: commit_at, source_key: commit_key}},
                   5_000

    refute_received {:phase, %{phase: "async_config"}}

    # The pickup starts at the tool's completion instant — its recorded
    # start (1_000 in the fixture) plus the duration it measured — and the
    # commit starts where the pickup ended.
    assert DateTime.to_unix(pickup_at, :millisecond) == 1_250
    assert DateTime.to_unix(commit_at, :millisecond) >= 1_250 + pickup_ms

    # The fact's identity carries the tool call, not just the round.
    assert commit_key =~ "call-terminal"
  end

  test "two background tools of one round settle as two distinct phase facts each", %{
    agent_id: agent_id
  } do
    prev = Application.get_env(:salix_agent, :agent_observability_mod)
    Application.put_env(:salix_agent, :agent_observability_mod, PhaseCollector)
    Application.put_env(:salix_agent, :async_phase_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :agent_observability_mod, prev),
        else: Application.delete_env(:salix_agent, :agent_observability_mod)

      Application.delete_env(:salix_agent, :async_phase_test_pid)
    end)

    # A second running background call in the same session and, through
    # the shared trace context, the same round.
    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => "call-terminal-2",
          "tool_name" => "env.exec",
          "status" => "running",
          "started_at" => 1_000
        }
      ])

    pid = actor_pid(agent_id)
    :sys.replace_state(pid, fn state -> %{state | pending_llm: %{test_hold: true}} end)

    trace = %{round_id: "round-two-tools", trace_id: "trace-two-tools"}
    result_b = Map.put(result(), "tool_call_id", "call-terminal-2")
    {job_a, _} = install_dependency_pending(pid, agent_id, &result/0, trace_ctx: trace)

    {job_b, _} =
      install_dependency_pending(pid, agent_id, fn -> result_b end,
        trace_ctx: trace,
        tool_call_id: "call-terminal-2"
      )

    send(pid, {:dependency_job_result, job_a.token, result()})
    send(pid, {:dependency_job_result, job_b.token, result_b})

    assert_receive {:phase,
                    %{phase: "async_commit", round_id: "round-two-tools", source_key: key_a}},
                   5_000

    assert_receive {:phase,
                    %{phase: "async_commit", round_id: "round-two-tools", source_key: key_b}},
                   5_000

    assert Enum.sort([key_a, key_b]) == [
             "round-two-tools:async_commit:call-terminal",
             "round-two-tools:async_commit:call-terminal-2"
           ]
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
    :sys.replace_state(pid, fn state ->
      %{state | pending_llm: %{test_hold: true}}
    end)

    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, workspace_key})

    on_exit(fn ->
      if Process.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
        do: SalixStore.S3.Fake.release_pause()
    end)

    send(pid, {:dependency_job_result, job.token, result()})

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

    send(pid, {:retry_async_tool_commit, make_ref(), pending(agent_id), result(), 0})

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
    :sys.replace_state(pid, fn state ->
      %{state | pending_llm: %{test_hold: true}}
    end)

    # Workspace staging succeeds, then the whole session batch fails once.
    # There must be no state where only the canonical source or only its
    # capsule is durable in the session journal.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})
    send(pid, {:dependency_job_result, job.token, large_result})

    assert eventually(fn ->
             map_size(:sys.get_state(pid).pending_async_tool_commits) == 1
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

  test "a large failed zero-wait terminal budgets the repair-phase runtime message", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    key = Keys.agent_internal_runtime_session(agent_id, @session)

    private_diagnostic =
      Jason.encode!(%{
        "category" => "provider_error",
        "details" => String.duplicate("private provider failure ", 24_000)
      })

    failed_result = %{
      "tool_call_id" => "call-terminal",
      "name" => "env.exec",
      "events" => [%{"type" => "vfs_delete", "path" => "/completed-command.tmp"}],
      "status" => "failed",
      "content" => private_diagnostic,
      "output" => private_diagnostic,
      "error" => true,
      "error_class" => "provider_error",
      "error_message" => private_diagnostic
    }

    {job, _dependency_pid} =
      install_dependency_pending(pid, agent_id, fn -> failed_result end)

    :sys.replace_state(pid, fn state ->
      %{state | pending_llm: %{test_hold: true}}
    end)

    # Stage the complete failure first, then fail the owner CAS once. Recovery
    # must reuse the staged identity and still project against the repair phase
    # that the final event batch creates.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})
    send(pid, {:dependency_job_result, job.token, failed_result})

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

    assert {:ok, before_retry} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    refute Map.has_key?(
             SalixAgent.InternalSession.get(before_retry, :async_result_refs),
             staged_ref
           )

    {recovery_events, _next_id} = SalixAgent.Repair.plan_session(before_retry)

    assert %{
             "type" => "tool_result_stored",
             "result_ref" => ^staged_ref,
             "stored_at_ms" => ^staged_at_ms
           } = Enum.find(recovery_events, &(&1["type"] == "tool_result_stored"))

    recovered = SalixAgent.InternalSession.apply_events(before_retry, recovery_events)
    assert SalixAgent.InternalSession.visible_reply_phase(recovered) == {:repair_required, 0}

    assert eventually(fn ->
             with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, @session),
                  {:ok, stored} <-
                    SalixAgent.InternalSession.lookup_async_call(session, staged_ref),
                  {:ok, terminal} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               stored["kind"] == "tool_result" and
                 terminal["status"] == "failed" and
                 stored["stored_at_ms"] == staged_at_ms and
                 terminal["completed_at"] == staged_at_ms
             else
               _ -> false
             end
           end)

    assert {:ok, committed} = SalixAgent.InternalSessionStore.read(agent_id, @session)
    assert SalixAgent.VisibleReplyPolicy.phase(committed) == {:repair_required, 0}

    assert {:ok, stored} = SalixAgent.InternalSession.lookup_async_call(committed, staged_ref)
    assert stored["result_json"] == Jason.encode!(private_diagnostic)

    assert [queued] =
             Enum.filter(SalixAgent.InternalSession.get(committed, :input_queue) || [], fn item ->
               get_in(item, ["payload", "runtime_message_id"]) ==
                 "tool-call-result:call-terminal"
             end)

    assert %{"stored_result" => true, "result_ref" => ^staged_ref} =
             queued
             |> get_in(["payload", "content"])
             |> Jason.decode!()

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

    refute String.contains?(
             runtime_message[:content] || runtime_message["content"],
             String.slice(private_diagnostic, 0, 256)
           )
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
    send(pid, {:retry_async_tool_commit, make_ref(), pending(agent_id), result(), 1})
    _ = :sys.get_state(pid)

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

  test "result identity retires before a failed terminal commit and ignores its timeout", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    key = Keys.agent_internal_runtime_session(agent_id, @session)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    token = job.token

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})
    send(pid, {:dependency_job_result, job.token, result()})

    state = :sys.get_state(pid)
    assert state.pending_async_tools == %{}

    assert %{^token => %{pending: retained, result: retained_result}} =
             state.pending_async_tool_commits

    refute Map.has_key?(retained, :dependency_job)
    refute Map.has_key?(retained, :ref)
    assert retained_result == result()

    # The timer was already retired. Even if its mailbox message races after
    # the first commit failure, it cannot replace the retained success.
    send(pid, {:dependency_job_timeout, job.token})

    assert %{^token => %{result: ^retained_result}} =
             :sys.get_state(pid).pending_async_tool_commits

    assert eventually(fn ->
             case InternalAgentRuntime.get_async_tool_call(
                    agent_id,
                    @session,
                    "call-terminal"
                  ) do
               {:ok, %{"status" => "completed"} = terminal} ->
                 String.contains?(inspect(terminal), "terminal payload")

               _ ->
                 false
             end
           end)
  end

  test "timeout identity retires before a failed terminal commit and ignores a late result", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    key = Keys.agent_internal_runtime_session(agent_id, @session)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    token = job.token

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})
    send(pid, {:dependency_job_timeout, job.token})

    state = :sys.get_state(pid)
    assert state.pending_async_tools == %{}

    assert %{^token => %{pending: retained, result: timeout_result}} =
             state.pending_async_tool_commits

    refute Map.has_key?(retained, :dependency_job)
    assert String.contains?(inspect(timeout_result), "dependency_timeout")

    # A provider result arriving after the actor-owned deadline cannot replace
    # the timeout terminal retained for storage retry.
    send(pid, {:dependency_job_result, job.token, result()})

    assert %{^token => %{result: ^timeout_result}} =
             :sys.get_state(pid).pending_async_tool_commits

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

             Enum.any?(SalixAgent.InternalSession.get(session, :async_results), fn terminal ->
               terminal["tool_call_id"] == "call-terminal" and
                 String.contains?(inspect(terminal), "dependency_timeout") and
                 not String.contains?(inspect(terminal), "terminal payload")
             end)
           end)
  end

  test "process-local completion can hand the same call to an external callback without terminalizing it",
       %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    handoff_result = handoff_result()

    send(pid, {:dependency_job_result, job.token, handoff_result})

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

    assert :sys.get_state(pid).pending_async_tools == %{}
  end

  test "a callback terminal absorbs a late process-local handoff", %{agent_id: agent_id} do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "callback terminal observed"}])

    on_exit(fn ->
      :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)

      if previous_llm,
        do: Application.put_env(:salix_agent, :llm, previous_llm),
        else: Application.delete_env(:salix_agent, :llm)
    end)

    pid = actor_pid(agent_id)
    late_handoff = handoff_result(wait?: true)

    {job, dependency_pid} =
      install_dependency_pending(pid, agent_id, fn -> late_handoff end)

    dependency_ref = Process.monitor(dependency_pid)

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
    assert_receive {:DOWN, ^dependency_ref, :process, ^dependency_pid, _reason}, 1_000
    send(pid, {:dependency_job_result, job.token, late_handoff})
    _ = :sys.get_state(pid)

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

    assert :sys.get_state(pid).pending_async_tools == %{}
  end

  test "a callback terminal revokes every old producer before its archived pointer retires", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    late_handoff = handoff_result(wait?: true)

    jobs =
      for _message_kind <- [:result, :timeout, :down] do
        {job, _dependency_pid} =
          install_dependency_pending(pid, agent_id, fn -> late_handoff end)

        job
      end

    Enum.each(jobs, fn job ->
      on_exit(fn -> DependencyJob.cancel(job) end)
    end)

    retained_ref = make_ref()

    retained_pending =
      pending(agent_id)
      |> Map.put(:call, %{id: "call-terminal", name: "env.exec", args: %{}})

    # Keep the actor from consuming the callback notification itself. The
    # test drives the real notification materialization/ack and archive
    # boundaries below, while the callback handler still owns and must revoke
    # the process-local producers in one mailbox turn.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | pending_llm: %{test_hold: true},
          pending_async_tool_commits:
            Map.put(state.pending_async_tool_commits, retained_ref, %{
              pending: retained_pending,
              result: late_handoff
            })
      }
    end)

    assert {:ok, %{"status" => "completed", "tool_call_id" => "call-terminal"}} =
             InternalSessionActor.complete_async_tool_call(
               pid,
               "call-terminal",
               result(),
               %{"tool_call_id" => "call-terminal", "tool_name" => "env.exec"}
             )

    state_after_callback = :sys.get_state(pid)
    producers_after_callback = matching_pending_refs(state_after_callback, "call-terminal")

    retained_after_callback =
      matching_retained_refs(state_after_callback, "call-terminal")

    producer_processes_stopped_after_callback =
      eventually(fn -> Enum.all?(jobs, &(not Process.alive?(&1.pid))) end)

    assert {:ok, callback_session} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    assert {:ok, %{"status" => "completed"}} =
             SalixAgent.InternalSession.lookup_async_call(callback_session, "call-terminal")

    assert terminal_notification_count(callback_session) == 1

    # Consume the callback notification through the real queue materializer,
    # including queue_ack, then acknowledge its stable transcript message.
    {materialize_events, true, hwm} =
      SalixAgent.InternalSession.materialize_pending_input_events(callback_session)

    assert {:ok, materialized} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session,
               materialize_events,
               hwm: hwm
             )

    terminal_message =
      Enum.find(
        SalixAgent.InternalSession.get(materialized, :messages) || [],
        &materialized_terminal?/1
      )

    assert is_map(terminal_message)
    terminal_message_id = terminal_message[:id] || terminal_message["id"]

    assert {:ok, acked} =
             InternalSessionStore.prepare_commit(agent_id, @session, [
               %{
                 "type" => "ack",
                 "session_id" => @session,
                 "last_ack_message_id" => terminal_message_id
               }
             ])

    assert SalixAgent.InternalSession.get(acked, :input_queue) == []
    assert SalixAgent.InternalSession.last_ack_message_id(acked) == terminal_message_id

    compacted_seq = SalixAgent.InternalSession.covered_seq(acked, terminal_message_id)

    assert {:ok, compacted} =
             InternalSessionStore.prepare_commit(agent_id, @session, [
               %{
                 "type" => "compaction",
                 "session_id" => @session,
                 "summary" => "callback terminal consumed",
                 "compacted_through" => terminal_message_id,
                 "compacted_seq" => compacted_seq,
                 "summary_sequence" =>
                   (SalixAgent.InternalSession.get(acked, :summary_sequence) || 0) + 1
               }
             ])

    refute Map.has_key?(
             SalixAgent.InternalSession.get(compacted, :async_result_refs),
             "call-terminal"
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(compacted, :async_results),
             &(&1["tool_call_id"] == "call-terminal")
           )

    assert {:ok, :archived} = archive_compacted_in_owner(pid, agent_id)
    assert {:ok, archived} = SalixAgent.InternalSessionStore.read(agent_id, @session)
    assert SalixAgent.InternalSession.get(archived, :async_results) == []

    refute Map.has_key?(
             SalixAgent.InternalSession.get(archived, :async_result_refs),
             "call-terminal"
           )

    assert SalixAgent.InternalSession.lookup_async_call(archived, "call-terminal") == :not_found

    assert {:ok, archived_records} =
             InternalSessionStore.archived_records(agent_id, archived)

    assert [archived_terminal] =
             Enum.filter(archived_records, fn record ->
               record.kind == "async_result" and
                 record.data["tool_call_id"] == "call-terminal"
             end)

    assert archived_terminal.data["status"] == "completed"

    [result_job, timeout_job, down_job] = jobs

    # These messages were already in flight before the callback won. After
    # pointer retirement durable lookup is intentionally :not_found, so only
    # synchronous actor-owner revocation can keep all three continuations
    # stale and suppress their whole handoff/terminal batches.
    send(pid, {:dependency_job_result, result_job.token, late_handoff})
    _ = :sys.get_state(pid)
    {:ok, after_result} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    send(pid, {:dependency_job_timeout, timeout_job.token})
    send(pid, {:dependency_job_down, down_job.token, :stale_dependency_exit})
    send(pid, {:retry_async_tool_commit, retained_ref, retained_pending, late_handoff, 1})
    final_actor_state = :sys.get_state(pid)
    {:ok, after_all_stale} = SalixAgent.InternalSessionStore.read(agent_id, @session)

    assert producers_after_callback == []
    assert retained_after_callback == []
    assert producer_processes_stopped_after_callback

    assert SalixAgent.InternalSession.lookup_async_call(after_result, "call-terminal") ==
             :not_found

    assert SalixAgent.InternalSession.wait(after_result) == nil
    assert handoff_notification_count(after_result) == 0

    assert SalixAgent.InternalSession.lookup_async_call(after_all_stale, "call-terminal") ==
             :not_found

    refute Map.has_key?(
             SalixAgent.InternalSession.get(after_all_stale, :async_tool_calls),
             "call-terminal"
           )

    refute Enum.any?(
             SalixAgent.InternalSession.get(after_all_stale, :async_results),
             &(&1["tool_call_id"] == "call-terminal")
           )

    assert SalixAgent.InternalSession.wait(after_all_stale) == nil
    assert handoff_notification_count(after_all_stale) == 0
    assert terminal_notification_count(after_all_stale) == 0
    assert matching_pending_refs(final_actor_state, "call-terminal") == []
    assert matching_retained_refs(final_actor_state, "call-terminal") == []

    assert {:ok, records_after_stale} =
             InternalSessionStore.archived_records(agent_id, after_all_stale)

    assert Enum.count(records_after_stale, fn record ->
             record.kind == "async_result" and
               record.data["tool_call_id"] == "call-terminal" and
               record.data["status"] == "completed"
           end) == 1

    assert Enum.count(records_after_stale, fn record ->
             record.kind == "message" and
               record.data["runtime_message_id"] == "tool-call-result:call-terminal"
           end) == 1
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
        "started_at" => System.system_time(:millisecond)
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
          receive do
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

    :sys.replace_state(pid, fn state ->
      %{
        state
        | pending_async_tools: Map.put(state.pending_async_tools, job.token, dependency_pending)
      }
    end)

    {job, job.pid}
  end

  defp matching_pending_refs(state, tool_call_id) do
    for {ref, pending} <- state.pending_async_tools,
        pending[:session_id] == @session,
        pending[:tool_call_id] == tool_call_id,
        do: ref
  end

  defp matching_retained_refs(state, tool_call_id) do
    for {ref, %{pending: pending}} <- state.pending_async_tool_commits,
        pending[:session_id] == @session,
        pending[:tool_call_id] == tool_call_id,
        do: ref
  end

  defp archive_compacted_in_owner(pid, agent_id) do
    test_pid = self()
    reply_ref = make_ref()

    :sys.replace_state(pid, fn state ->
      send(
        test_pid,
        {reply_ref, InternalSessionStore.archive_compacted(agent_id, @session)}
      )

      state
    end)

    receive do
      {^reply_ref, result} -> result
    after
      1_000 -> {:error, :archive_owner_timeout}
    end
  end

  defp eventually(fun, attempts \\ 60) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(100)
        {:cont, false}
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

  test "terminal storage failure gates speculative response until the retained result commits",
       %{
         agent_id: agent_id
       } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    token = job.token
    session_key = Keys.agent_internal_runtime_session(agent_id, @session)
    accepted_result = result()

    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, session_key})
    send(pid, {:dependency_job_result, token, accepted_result})

    state = :sys.get_state(pid)
    assert state.pending_async_tools == %{}

    assert %{^token => %{pending: retained, result: ^accepted_result}} =
             state.pending_async_tool_commits

    assert {:ok, %{"status" => "running"}} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-terminal")

    assert_receive {:activation_llm_request, speculative_pid, speculative_messages, _}, 2_000
    assert Enum.count(speculative_messages, &(&1[:source_tool_call_id] == "call-terminal")) == 1
    send(speculative_pid, :release_activation_llm)

    # Computation may finish, but its result stays behind the failed fence.
    # A retry must retain the tool outcome and must not dispatch another model.
    send(pid, {:retry_async_tool_commit, token, retained, accepted_result, 1})

    assert %{^token => %{result: ^accepted_result}} =
             :sys.get_state(pid).pending_async_tool_commits

    refute_receive {:activation_llm_request, _, _, _}, 200
    assert Process.alive?(speculative_pid)
    assert :sys.get_state(pid).pending_llm.pid == speculative_pid

    :ok = SalixStore.S3.Fake.clear_blackhole()
    send(pid, {:retry_async_tool_commit, token, retained, accepted_result, 2})

    assert_receive {:activation_llm_request, llm_pid, messages, _tools}, 2_000

    on_exit(fn ->
      if Process.alive?(llm_pid), do: send(llm_pid, :release_activation_llm)
    end)

    assert Enum.count(messages, &(&1[:source_tool_call_id] == "call-terminal")) == 1
    assert :sys.get_state(pid).pending_async_tool_commits == %{}

    assert {:ok, %{"status" => "completed"} = terminal} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-terminal")

    assert String.contains?(inspect(terminal), "terminal payload")
    refute_receive {:activation_llm_request, _, _, _}, 100
    send(llm_pid, :release_activation_llm)
  end

  @tag :session_optimization
  test "a mutation-free non-replayable terminal keeps its full result in the Session receipt", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    :sys.replace_state(pid, &%{&1 | pending_llm: %{test_hold: true}})
    content = String.duplicate("retained command output ", 10_000)

    terminal =
      result()
      |> Map.delete("events")
      |> Map.merge(%{"content" => content, "output" => content, "name" => "env.exec"})

    {job, _} =
      install_dependency_pending(pid, agent_id, fn -> terminal end, tool_name: "env.exec")

    workspace = Keys.agent_workspace_state(agent_id)
    :ok = SalixStore.S3.Fake.reset_put_log()
    send(pid, {:dependency_job_result, job.token, terminal})
    :sys.get_state(pid)
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

  @tag tool_name: "fs.list_files"
  test "replayable read continuation persists its result and activation without workspace bookkeeping",
       %{
         agent_id: agent_id
       } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    # Real tool admission leaves an auto-wait until the queued completion is materialized.
    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{
          "type" => "wait_set",
          "session_id" => @session,
          "wait" => %{
            "source" => "auto_wait",
            "tool_call_id" => "call-terminal",
            "deadline_ms" => System.system_time(:millisecond) + 60_000
          }
        }
      ])

    pid = actor_pid(agent_id)

    {job, _dependency_pid} =
      install_dependency_pending(pid, agent_id, &result/0, tool_name: "fs.list_files")

    session_key = Keys.agent_internal_runtime_session(agent_id, @session)
    workspace_key = Keys.agent_workspace_state(agent_id)
    marker_key = Keys.agent_session_work_index(agent_id, :internal, @session)

    :ok = SalixStore.S3.Fake.reset_read_log()
    :ok = SalixStore.S3.Fake.reset_put_log()
    # A coalesced wake behind the terminal is the same pending processing work.
    :ok = :sys.suspend(pid)
    :sys.replace_state(pid, &%{&1 | process_scheduled: true, wake_pending: true})
    send(pid, {:dependency_job_result, job.token, Map.delete(result(), "events")})
    send(pid, :process)
    :ok = :sys.resume(pid)

    assert_receive {:activation_llm_request, llm_pid, messages, _tools}, 2_000
    assert Enum.any?(messages, &(&1[:source_tool_call_id] == "call-terminal"))

    on_exit(fn ->
      if Process.alive?(llm_pid), do: send(llm_pid, :release_activation_llm)
    end)

    # Provider admission precedes persistence. This owner call joins the
    # in-flight fence before inspecting the final storage operations.
    assert :sys.get_state(pid).pending_llm.pid == llm_pid
    # A second owner barrier also drains notifications queued during the fence.
    assert %InternalSessionStore.Revision{} = :sys.get_state(pid).revision
    reads = SalixStore.S3.Fake.read_log()
    puts = SalixStore.S3.Fake.put_log()

    assert Enum.count(reads, &(&1 == {:get, session_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, workspace_key})) == 0
    assert Enum.count(puts, &(&1 == workspace_key)) == 0
    assert Enum.count(puts, &(&1 == marker_key)) == 1
    assert Enum.count(puts, &(&1 == session_key)) == 1

    send(llm_pid, :release_activation_llm)
  end

  test "a skill-writing result resolves next-round configuration after the skill commit", %{
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(agent_id)
    group_skill_key = Keys.ctl_skill_scope_group(group_id)

    assert {:ok, skill_event} =
             SalixAgent.SkillStore.prepare_group_create(
               %{agent_id: agent_id, group_id: group_id, tenant_id: tenant_id},
               %{
                 "skill_id" => "async-terminal-skill",
                 "name" => "Async Terminal Skill",
                 "description" => "Created by the completing tool result."
               }
             )

    terminal_result = Map.put(result(), "events", [skill_event])
    pid = actor_pid(agent_id)

    {job, _dependency_pid} =
      install_dependency_pending(pid, agent_id, fn -> terminal_result end,
        tool_name: "skill.create"
      )

    :ok = SalixStore.S3.Fake.reset_read_log()
    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, group_skill_key})

    on_exit(fn ->
      if Process.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
        do: SalixStore.S3.Fake.release_pause()
    end)

    send(pid, {:dependency_job_result, job.token, terminal_result})
    assert eventually(&SalixStore.S3.Fake.paused?/0)

    # The first catalog read prepares the skill commit. Configuration started
    # here would add a second read of the old projection while that commit is
    # still parked. Keep this result on the ordinary fresh-read path instead.
    Process.sleep(100)
    assert Enum.count(SalixStore.S3.Fake.read_log(), &(&1 == {:get, group_skill_key})) == 1

    assert :ok = SalixStore.S3.Fake.release_pause()
    assert_receive {:activation_llm_request, llm_pid, messages, _tools}, 2_000
    assert Jason.encode!(messages) =~ "Async Terminal Skill"

    assert {:ok, scope} = SalixAgent.SkillStore.read_scope(:group, group_id)
    assert Map.has_key?(scope.skills, "async-terminal-skill")

    send(llm_pid, :release_activation_llm)
  end

  test "async continuation preserves an actor-owned visible reply retry fence", %{
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    retry_token = make_ref()
    timer_ref = Process.send_after(pid, {:session_retry, retry_token}, 60_000)

    on_exit(fn -> Process.cancel_timer(timer_ref) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_retry_timer: {retry_token, timer_ref},
          session_recovery:
            SalixAgent.InternalSession.Recovery.round_failure(
              nil,
              {:visible_reply_append_retry, :unavailable}
            ).checkpoint
      }
    end)

    send(pid, {:dependency_job_result, job.token, result()})

    assert eventually(fn ->
             with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, @session),
                  {:ok, %{"status" => "completed"}} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               true
             else
               _ -> false
             end
           end)

    # Settlement may set the level-triggered wake bit, but it must not bypass
    # the older retry timer and enter a new LLM round early.
    assert %{wake_pending: true, pending_llm: nil} = :sys.get_state(pid)
    refute_receive {:activation_llm_request, _llm_pid, _messages, _tools}, 250

    Process.cancel_timer(timer_ref)
    send(pid, {:session_retry, retry_token})

    assert_receive {:activation_llm_request, llm_pid, messages, _tools}, 2_000
    assert Enum.any?(messages, &(&1[:source_tool_call_id] == "call-terminal"))
    send(llm_pid, :release_activation_llm)
  end

  test "an async result's activation keeps the recovery checkpoint for the result commit", %{
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    checkpoint =
      SalixAgent.InternalSession.Recovery.round_failure(
        nil,
        {:visible_reply_append_retry, :unavailable}
      ).checkpoint

    :sys.replace_state(pid, &%{&1 | session_recovery: checkpoint})
    send(pid, {:dependency_job_result, job.token, result()})

    # The next round's model call starts beside the activation fence. The
    # landed fence leaves the retry state to the result commit.
    assert_receive {:activation_llm_request, llm_pid, _messages, _tools}, 2_000
    assert %{session_recovery: ^checkpoint} = :sys.get_state(pid)
    send(llm_pid, :release_activation_llm)
  end

  test "async result becomes durable while next-round billing is still pending", %{
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_meter = Application.get_env(:salix_agent, :llm_metering_mod)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_metering_mod, GatedMetering)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())
    :persistent_term.put({GatedMetering, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_metering_mod, previous_meter)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
      :persistent_term.erase({GatedMetering, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _} = install_dependency_pending(pid, agent_id)
    send(pid, {:dependency_job_result, job.token, result()})
    assert_receive {:billing_waiting, billing}, 2_000

    assert eventually(fn ->
             with {:ok, session} <- InternalSessionStore.read(agent_id, @session),
                  {:ok, %{"status" => "completed"}} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               true
             else
               _ -> false
             end
           end)

    refute_receive {:activation_llm_request, _, _, _}, 50
    send(billing, :allow_billing)
    assert_receive {:activation_llm_request, llm, _, _}, 2_000
    send(llm, :release_activation_llm)
  end

  test "speculative configuration failure cannot roll back terminal durability", %{
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, FailingRecordResolver)
    :persistent_term.put({BlockingCaptureLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      :persistent_term.erase({BlockingCaptureLLM, :owner})
    end)

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)
    send(pid, {:dependency_job_result, job.token, result()})

    assert eventually(fn ->
             with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, @session),
                  {:ok, %{"status" => "completed"}} <-
                    SalixAgent.InternalSession.lookup_async_call(session, "call-terminal") do
               SalixAgent.InternalSession.status(session) == :idle
             else
               _ -> false
             end
           end)

    refute_receive {:activation_llm_request, _llm_pid, _messages, _tools}, 250
  end

  test "async continuation overlaps the provider with persistence after configuration and IFC admission",
       %{
         agent_id: agent_id
       } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    previous_plugin_store = Application.get_env(:salix_agent, :plugin_store_mod)
    previous_ifc_facts = Application.get_env(:salix_agent, :ifc_facts_mod)
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(agent_id)
    template_id = "tmpl-#{agent_id}"
    plugin_key = "test/async-roundtrip/plugins/#{group_id}.json"
    session_key = Keys.agent_internal_runtime_session(agent_id, @session)
    workspace_key = Keys.agent_workspace_state(agent_id)
    marker_key = Keys.agent_session_work_index(agent_id, :internal, @session)
    group_key = Keys.ctl_group(group_id)
    im_connects_prefix = Keys.ctl_im_connects_prefix(group_id)
    mcp_bindings_prefix = Keys.ctl_mcp_group_bindings_prefix(tenant_id, group_id)

    config_keys = [
      Keys.ctl_template(template_id),
      plugin_key,
      Keys.ctl_skill_scope_global(),
      Keys.ctl_skill_scope_tenant(tenant_id),
      Keys.ctl_skill_scope_group(group_id),
      Keys.ctl_skill_scope_agent(agent_id)
    ]

    assert {:ok, agent_record} = SalixAgent.Control.get_record(agent_id)
    assert {:ok, _actor} = SalixAgent.AgentActor.ensure_started(agent_record)
    assert {:ok, _} = SalixStore.S3.Fake.put(plugin_key, "{}", [])

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent_id, @session, [
               %{
                 "type" => "transcript_seed",
                 "session_id" => @session,
                 "source_id" => "roundtrip-wave-test",
                 "created_at" => System.system_time(:second),
                 "entries" => [
                   %{
                     "role" => "runtime",
                     "content" => String.duplicate("runtime context ", 11_500),
                     "dedupe_key" => "roundtrip-wave-test-runtime-context"
                   }
                 ]
               }
             ])

    pid = actor_pid(agent_id)
    {job, _dependency_pid} = install_dependency_pending(pid, agent_id)

    start_supervised!({TimedS3, delay_ms: 40, delay_keys: :all})
    Application.put_env(:salix_store, :s3_backend, TimedS3)
    Application.put_env(:salix_agent, :llm, TimedCaptureLLM)
    Application.put_env(:salix_agent, :llm_resolver, RecordAwareResolver)
    Application.put_env(:salix_agent, :plugin_store_mod, TimedPluginStore)
    Application.put_env(:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts)
    :persistent_term.put({TimedCaptureLLM, :owner}, self())
    SalixAgent.SkillProjection.invalidate_cache()
    TimedS3.reset()

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      restore_env(:llm, previous_llm)
      restore_env(:llm_resolver, previous_resolver)
      restore_env(:plugin_store_mod, previous_plugin_store)
      restore_env(:ifc_facts_mod, previous_ifc_facts)
      :persistent_term.erase({TimedCaptureLLM, :owner})
    end)

    send(pid, {:dependency_job_result, job.token, result()})

    assert_receive {:timed_activation_llm_request, llm_pid, provider_at, messages, tools}, 5_000
    assert Enum.any?(messages, &(&1[:source_tool_call_id] == "call-terminal"))
    assert byte_size(Jason.encode!(%{messages: messages, tools: tools})) > 240 * 1024

    on_exit(fn ->
      if Process.alive?(llm_pid), do: send(llm_pid, :release_activation_llm)
    end)

    assert :sys.get_state(pid).pending_llm.pid == llm_pid
    events = TimedS3.events()
    session_get = only_event(events, :get, session_key)
    workspace_get = only_event(events, :get, workspace_key)
    workspace_put = only_event(events, :put, workspace_key)
    activation_marker = only_event(events, :put, marker_key)
    activation_put = only_event(events, :put, session_key)
    assert session_get.finished_at <= workspace_get.started_at
    assert workspace_get.finished_at <= workspace_put.started_at
    assert max_finished([workspace_put, activation_marker]) <= activation_put.started_at
    assert overlap?([workspace_put, activation_marker])

    # Cold initialization reads every static configuration input; subsequent
    # reads belong to the background refresh and may finish after the fence.
    for key <- config_keys do
      assert [_ | _] = events_for(events, :get, key)
    end

    assert [_ | _] = events_for(events, :list, im_connects_prefix)
    assert [_ | _] = events_for(events, :list, mcp_bindings_prefix)
    assert [_ | _] = events_for(events, :get, group_key)
    assert provider_at >= session_get.finished_at
    send(llm_pid, :release_activation_llm)
  end

  defp only_event(events, operation, key) do
    assert [event] = events_for(events, operation, key)
    event
  end

  defp events_for(events, operation, key) do
    Enum.filter(events, &(&1.operation == operation and &1.key == key))
  end

  defp overlap?(events), do: max_started(events) < min_finished(events)
  defp min_started(events), do: events |> Enum.map(& &1.started_at) |> Enum.min()
  defp max_started(events), do: events |> Enum.map(& &1.started_at) |> Enum.max()
  defp min_finished(events), do: events |> Enum.map(& &1.finished_at) |> Enum.min()
  defp max_finished(events), do: events |> Enum.map(& &1.finished_at) |> Enum.max()
end
