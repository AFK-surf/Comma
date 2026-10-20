defmodule SalixAgent.SessionDependencyLivenessTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Actor-level regressions for user-owned dependency liveness.

  These tests deliberately use dependencies which do not return before the
  actor-owned deadline. Storage remains healthy: the boundary under test is
  only user-selected LLM work.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore
  }

  alias SalixStore.S3

  @deadline_ms 100

  defmodule ControlTemplateResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)
  end

  defmodule DeadlineLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM
    require SystemsClock

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      cond do
        "fresh after timeout" in contents ->
          SystemsRuntime.Proc.send(owner, {:fresh_llm_started, SystemsRuntime.Proc.self()})

          SystemsClock.vreceive do
            {:release_fresh_llm, response} -> response
          after
            2_000 -> {:final, "fresh provider escaped the actor deadline"}
          end

        "raise llm" in contents ->
          raise "provider adapter failed"

        "hang normal llm" in contents ->
          SystemsRuntime.Proc.send(owner, {:normal_llm_started, SystemsRuntime.Proc.self()})

          SystemsClock.vreceive do
            {:release_normal_llm, response} -> response
          after
            2_000 -> {:final, "provider escaped the actor deadline"}
          end

        true ->
          {:final, "unexpected input"}
      end
    end

    # The hanging call streams one delta first: the deadline then kills an
    # attempt that had produced content, which the actor must still report.
    @impl true
    def complete_stream(messages, tools, on_delta) do
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      if "hang normal llm" in contents or "raise llm" in contents,
        do: on_delta.("partial answer ")

      complete(messages, tools)
    end
  end

  defmodule ObservabilityCollector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(fact), do: forward({:run_observation, fact})

    @impl true
    def llm_attempt(fact), do: forward({:attempt_observation, fact})

    defp forward(message) do
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}, nil) do
        pid when SystemsRuntime.Proc.is_process(pid) -> SystemsRuntime.Proc.send(pid, message)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule DeadlineCompactionLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM
    require SystemsClock

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(_messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:compaction_llm_started, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        {:release_compaction_llm, response} -> response
      after
        2_000 ->
          {:final, "<compaction-summary>provider escaped the actor deadline</compaction-summary>"}
      end
    end

    @impl true
    def complete(messages, tools, _opts), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts), do: complete(messages, tools)
  end

  defmodule SaturatingLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM
    require SystemsClock

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      cond do
        "other tenant fast" in contents ->
          SystemsRuntime.Proc.send(owner, {:other_tenant_llm_started, SystemsRuntime.Proc.self()})
          {:final, "other tenant completed"}

        "same tenant lane one" in contents ->
          block(owner, :lane_one)

        "same tenant lane two" in contents ->
          block(owner, :lane_two)

        true ->
          {:final, "unexpected input"}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    defp block(owner, lane) do
      SystemsRuntime.Proc.send(owner, {:saturating_llm_started, lane, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        :release_saturating_llm -> {:final, "released #{lane}"}
      after
        10_000 -> {:final, "unbounded #{lane}"}
      end
    end
  end

  defmodule HangingMCPProvider do
    @moduledoc false

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)
    def provider_state(_agent_id), do: {:ok, %{}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => "mcp.liveness.hang",
           "summary" => "Blocking user-owned MCP dependency used by liveness tests.",
           "manual" => "Blocking user-owned MCP dependency used by liveness tests.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def call_tool(_agent_id, "liveness", "hang", _args, _ctx) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:hanging_mcp_started, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :release_hanging_mcp -> {:ok, %{"content" => "released"}}
        {:release_hanging_mcp, response} -> response
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for key <- [
            :llm,
            :llm_resolver,
            :summarizer,
            :session_actor_idle_ms,
            :dependency_job_timeout_ms,
            :dependency_max_children,
            :dependency_max_children_per_tenant,
            :mcp_provider_mod,
            :capability_request_store_mod,
            :agent_observability_mod,
            :llm_request_timeout_ms,
            :router_llm_request_timeout_ms
          ],
          into: %{},
          do: {key, SystemsRuntime.get_env(:salix_agent, key)}

    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    SystemsRuntime.delete_env(:salix_agent, :summarizer)
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 2_000)

    SystemsRuntime.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: @deadline_ms,
      compaction: @deadline_ms
    })

    SystemsRuntime.put_env(:salix_agent, :dependency_max_children, 2)
    SystemsRuntime.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)

    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, ObservabilityCollector)
    ObservabilityCollector.set_owner(SystemsRuntime.Proc.self())
    DeadlineLLM.set_owner(SystemsRuntime.Proc.self())
    DeadlineCompactionLLM.set_owner(SystemsRuntime.Proc.self())
    SaturatingLLM.set_owner(SystemsRuntime.Proc.self())
    HangingMCPProvider.set_owner(SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store)

      Enum.each(previous, fn {key, value} ->
        restore_env(:salix_agent, key, value)
      end)

      for module <- [
            ObservabilityCollector,
            DeadlineLLM,
            DeadlineCompactionLLM,
            SaturatingLLM,
            HangingMCPProvider
          ] do
        SystemsRuntime.PersistentTerm.erase({module, :owner})
      end
    end)

    :ok
  end

  test "never-returning normal LLM times out durably, resumes queued input, and ignores a late result" do
    SystemsRuntime.put_env(:salix_agent, :llm, DeadlineLLM)

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001811"

    assert {:ok, :committed} =
             stage_internal(agent_id, session_id, "normal-hang", "hang normal llm")

    # Waiting for the call must not move the clock past its deadline.
    dependency_pid = await_started(:normal_llm_started)
    actor_pid = off_clock(fn -> internal_actor_pid!(agent_id, session_id) end)

    %{pending_llm: %{dependency_job: %{token: stale_token}}} =
      off_clock(fn -> :sys.get_state(actor_pid, :infinity) end)

    assert {:ok, :committed} =
             stage_internal(agent_id, session_id, "normal-fresh", "fresh after timeout")

    # The actor consumed the mailbox edge while the first LLM owned the
    # activation. The durable dirty bit must survive until that blocker clears;
    # a completion path is not allowed to reconstruct this wake by accident.
    assert eventually(fn -> :sys.get_state(actor_pid, :infinity).wake_pending end)

    assert eventually(fn ->
             dependency_failure?(agent_id, session_id, "dependency_timeout")
           end)

    # The killed attempt is reported by the actor, with what the round had
    # received from it: one streamed delta, no transport body (a fake provider
    # never goes through SalixLlm.Http), and the lost run beside it.
    settle_receive({:attempt_observation, killed})
    assert killed.outcome == "killed"
    assert killed.attempt == 1
    assert killed.max_attempts == SalixAgent.Round.llm_request_max_attempts()
    assert killed.reason == "dependency_timeout"
    assert killed.session_id == session_id
    assert killed.salix_agent_id == agent_id
    assert killed.content_deltas == 1
    assert is_integer(killed.first_content_ms)
    assert killed.received_bytes == nil
    assert killed.received_chunks == nil
    assert killed.duration_ms >= div(@deadline_ms, 2)
    settle_receive({:run_observation, %{status: "actor_failed", session_id: ^session_id}})
    replacement_dependency_pid = await_started(:fresh_llm_started)

    %{pending_llm: %{dependency_job: %{token: current_token}}} =
      off_clock(fn -> :sys.get_state(actor_pid, :infinity) end)

    refute current_token == stale_token

    # A malformed identity must not crash the actor or consume the live owner.
    SystemsRuntime.Proc.send(
      actor_pid,
      {:dependency_job_result, "not-a-reference", {{:final, "invalid answer"}, 1, %{}}}
    )

    %{pending_llm: %{dependency_job: %{token: ^current_token}}} =
      off_clock(fn -> :sys.get_state(actor_pid, :infinity) end)

    # Inject the exact DependencyJob result protocol from the timed-out token
    # while its replacement is current. It cannot clear or commit the new job.
    SystemsRuntime.Proc.send(
      actor_pid,
      {:dependency_job_result, stale_token, {{:final, "stale late answer"}, 1, %{}}}
    )

    %{pending_llm: %{dependency_job: %{token: ^current_token}}} =
      off_clock(fn -> :sys.get_state(actor_pid, :infinity) end)

    SystemsRuntime.Proc.send(dependency_pid, {:release_normal_llm, {:final, "stale late answer"}})

    SystemsRuntime.Proc.send(
      replacement_dependency_pid,
      {:release_fresh_llm, done_response("fresh answer after timeout")}
    )

    assert eventually(fn ->
             assistant_content?(agent_id, session_id, "fresh answer after timeout")
           end)

    session = read_internal!(agent_id, session_id)

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "assistant" and &1.content == "stale late answer")
           )

    assert :sys.get_state(actor_pid, :infinity).pending_llm == nil
  end

  test "one tenant's dependency saturation preserves another tenant and core control" do
    SystemsRuntime.put_env(:salix_agent, :llm, SaturatingLLM)

    # This case exercises admission isolation, not the 100 ms deadline used by
    # the timeout cases above. Keep the first tenant slot alive long enough for
    # both queued actors to reach admission even on a loaded CI scheduler.
    SystemsRuntime.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: 5_000,
      compaction: @deadline_ms
    })

    saturated_agent = create_internal_agent!()
    other_agent = create_internal_agent!()

    lane_one_session = "ses1_0000000000000001821"
    lane_two_session = "ses1_0000000000000001822"
    other_session = "ses1_0000000000000001823"

    assert {:ok, :committed} =
             stage_internal(
               saturated_agent,
               lane_one_session,
               "saturation-one",
               "same tenant lane one"
             )

    settle_receive({:saturating_llm_started, :lane_one, first_dependency_pid})

    assert {:ok, :committed} =
             stage_internal(
               saturated_agent,
               lane_two_session,
               "saturation-two",
               "same tenant lane two"
             )

    assert {:ok, :committed} =
             stage_internal(other_agent, other_session, "other-tenant", "other tenant fast")

    assert eventually(fn ->
             assistant_content?(other_agent, other_session, "other tenant completed")
           end)

    # The second dependency for one tenant is rejected at admission instead
    # of consuming the global slot reserved for unrelated work.
    refute_received {:saturating_llm_started, :lane_two, _pid}

    assert eventually(fn ->
             dependency_failure?(saturated_agent, lane_two_session, "dependency_saturated")
           end)

    assert {:ok, :committed} =
             InternalSessionFleet.stage_control(
               saturated_agent,
               lane_two_session,
               %{
                 payload: %{
                   kind: "session_update",
                   session_id: lane_two_session,
                   name: "core control remained live"
                 }
               },
               timeout: 500
             )

    assert SalixAgent.InternalSession.get(
             read_internal!(saturated_agent, lane_two_session),
             :name
           ) ==
             "core control remained live"

    SystemsRuntime.Proc.send(first_dependency_pid, :release_saturating_llm)
  end

  # Recovery and deliveries wake a session as hints, here every 50 ms. The
  # session whose Tenant has no slot asks again after a wait that doubles
  # from 100 ms to 5 s, not on each hint.
  test "a session whose Tenant slots are taken asks again with growing waits" do
    SystemsRuntime.put_env(:salix_agent, :llm, SaturatingLLM)

    SystemsRuntime.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: 60_000,
      compaction: @deadline_ms
    })

    agent = create_internal_agent!()
    holding_session = "ses1_0000000000000001831"
    waiting_session = "ses1_0000000000000001832"

    assert {:ok, :committed} =
             stage_internal(agent, holding_session, "backoff-one", "same tenant lane one")

    settle_receive({:saturating_llm_started, :lane_one, holder})
    attach_telemetry([[:salix, :dependency_job, :stop]])

    assert {:ok, :committed} =
             stage_internal(agent, waiting_session, "backoff-two", "same tenant lane two")

    # An activation asks at most twice at one time: its speculative call,
    # and the call that follows its fence.
    asked_at =
      Enum.flat_map(0..160, fn step ->
        if step > 0, do: settle_after(50)
        asked = refusals_at(SystemsClock.system_time(:millisecond))
        _ = InternalSessionFleet.wake(agent, waiting_session)
        asked
      end)
      |> Enum.uniq()

    assert length(asked_at) in 3..7,
           "asked at #{length(asked_at)} times in 8 s: #{inspect(asked_at)}"

    waits = asked_at |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert waits == Enum.sort(waits) and waits == Enum.uniq(waits), inspect(waits)

    # A freed slot must wake this actor even though its next retry is still
    # seconds away. Settling alone does not advance the clock to that timer.
    released_at = SystemsClock.system_time(:millisecond)
    SystemsRuntime.Proc.send(holder, :release_saturating_llm)
    settle()
    assert_received {:saturating_llm_started, :lane_two, second}
    assert SystemsClock.system_time(:millisecond) == released_at
    SystemsRuntime.Proc.send(second, :release_saturating_llm)
  end

  test "a capacity hint from a retired wait cannot bypass the current admission backoff" do
    SystemsRuntime.put_env(:salix_agent, :llm, SaturatingLLM)
    SystemsRuntime.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 60_000})
    agent = create_internal_agent!()
    holding_session = "ses1_0000000000000001833"
    waiting_session = "ses1_0000000000000001834"

    assert {:ok, :committed} =
             stage_internal(agent, holding_session, "stale-capacity-one", "same tenant lane one")

    settle_receive({:saturating_llm_started, :lane_one, holder})
    attach_telemetry([[:salix, :dependency_job, :stop]])

    assert {:ok, :committed} =
             stage_internal(agent, waiting_session, "stale-capacity-two", "same tenant lane two")

    settle()
    actor = off_clock(fn -> internal_actor_pid!(agent, waiting_session) end)

    %{admission_retry_timer: {retired_token, _}} =
      off_clock(fn -> :sys.get_state(actor, :infinity) end)

    settle_after(100)

    %{admission_retry_timer: {current_token, _}} =
      off_clock(fn -> :sys.get_state(actor, :infinity) end)

    refute current_token == retired_token
    refusals_at(SystemsClock.system_time(:millisecond))
    SystemsRuntime.Proc.send(actor, {:dependency_capacity_available, retired_token})
    settle()

    assert refusals_at(SystemsClock.system_time(:millisecond)) == []
    refute_received {:saturating_llm_started, :lane_two, _}

    SystemsRuntime.Proc.send(holder, :release_saturating_llm)
    settle()
    assert_received {:saturating_llm_started, :lane_two, second}
    SystemsRuntime.Proc.send(second, :release_saturating_llm)
  end

  defmodule InterruptedCapabilityStore do
    def create_capability_request(attrs) do
      agent_id = attrs["source_agent_id"] || attrs[:source_agent_id]
      session_id = attrs["source_session_id"] || attrs[:source_session_id]
      id = attrs["tool_call_id"] || attrs[:tool_call_id]
      {:ok, session} = InternalSessionStore.read(agent_id, session_id)
      admission = SalixAgent.InternalSession.lookup_async_call(session, id)
      {:ok, request} = SalixAgent.CapabilityRequests.create_capability_request(attrs)

      canonical = %{
        "status" => "completed",
        "content" => "location persisted before handoff",
        "error" => false
      }

      {:ok, _} =
        SalixAgent.CapabilityRequests.reconcile_capability_request(
          agent_id,
          session_id,
          id,
          canonical
        )

      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:capability_created_before_handoff, SystemsRuntime.Proc.self(), admission, request}
      )

      SystemsRuntime.Proc.receive do
        :return_handoff -> {:ok, request}
      end
    end

    def reconcile_capability_request(agent_id, session_id, id, result),
      do:
        SalixAgent.CapabilityRequests.reconcile_capability_request(
          agent_id,
          session_id,
          id,
          result
        )
  end

  defmodule UnexpectedDirectLLM do
    def complete(_messages, _tools) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({InterruptedCapabilityStore, :owner}),
        :unexpected_direct_model_wake
      )

      {:final, "unexpected direct model wake"}
    end

    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  test "direct capability admission survives a request completion before its callback handoff" do
    SystemsRuntime.put_env(
      :salix_agent,
      :capability_request_store_mod,
      InterruptedCapabilityStore
    )

    SystemsRuntime.put_env(:salix_agent, :llm, UnexpectedDirectLLM)

    SystemsRuntime.PersistentTerm.put(
      {InterruptedCapabilityStore, :owner},
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.PersistentTerm.erase({InterruptedCapabilityStore, :owner}) end)
    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001825"

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    {:ok, original_actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        InternalSessionActor.execute_tool(original_actor, "location.request", %{
          "reason" => "weather"
        })
      end)

    settle_receive({:capability_created_before_handoff, creator, {:ok, admission}, request})
    id = request["tool_call_id"]
    assert admission["tool_call_id"] == id
    assert admission["status"] == "running"
    assert admission["completion_owner"] == "direct_poll"
    # Before request creation, admission is still locally owned work.
    refute admission["completion_mode"] == "external_callback"

    # Neither the tool handoff nor its result reaches the execution caller.
    creator_monitor = SystemsRuntime.Proc.monitor(creator)
    SystemsRuntime.Proc.exit(caller, :kill)
    SystemsRuntime.Proc.exit(original_actor, :kill)
    SystemsRuntime.Proc.exit(creator, :kill)
    settle_receive({:DOWN, ^caller_monitor, :process, ^caller, _})
    settle_receive({:DOWN, ^creator_monitor, :process, ^creator, _})
    {:ok, before_recovery} = InternalSessionStore.read(agent_id, session_id)

    assert {:ok, %{"status" => "running"}} =
             SalixAgent.InternalSession.lookup_async_call(before_recovery, id)

    {:ok, actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    :ok = InternalSessionActor.wake(agent_id, session_id)

    assert eventually(fn ->
             case SalixAgent.InternalSession.lookup_async_call(
                    read_internal!(agent_id, session_id),
                    id
                  ) do
               {:ok, %{"status" => "completed"}} -> true
               _ -> false
             end
           end)

    _ = :sys.get_state(actor, :infinity)
    recovered = read_internal!(agent_id, session_id)

    assert {:ok,
            %{
              "completion_owner" => "direct_poll",
              "result" => %{"content" => "location persisted before handoff"}
            }} =
             SalixAgent.InternalSession.lookup_async_call(recovered, id)

    assert SalixAgent.InternalSession.work_reasons(recovered) == []
    assert SalixAgent.InternalSession.get(recovered, :input_queue) == []
    assert SalixAgent.InternalSession.get(recovered, :messages) == []
    settle_refute_receive(:unexpected_direct_model_wake, 100)
  end

  @tag :inline_direct_receipt
  test "inline direct capability result survives a lost final session commit" do
    SystemsRuntime.put_env(:salix_agent, :llm, UnexpectedDirectLLM)

    SystemsRuntime.PersistentTerm.put(
      {InterruptedCapabilityStore, :owner},
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.PersistentTerm.erase({InterruptedCapabilityStore, :owner}) end)
    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001826"

    tenant_id =
      agent_id |> SalixStore.Ids.group_id_from_agent!() |> SalixStore.Ids.tenant_id_from_group!()

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    {:ok, actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    # A real occupied tenant slot makes the capability return inline, without
    # relying on scheduler timing to win the zero-wait completion fast path.
    {:ok, occupied} =
      SalixAgent.DependencyJob.start(
        :tool,
        tenant_id,
        fn ->
          SystemsRuntime.Proc.receive do
            :release -> :ok
          end
        end,
        timeout_ms: 10_000
      )

    on_exit(fn -> SalixAgent.DependencyJob.cancel(occupied) end)
    owner = SystemsRuntime.Proc.self()

    :sys.replace_state(
      actor,
      fn data ->
        result =
          SalixAgent.SessionToolExecution.execute(
            agent_id,
            session_id,
            :internal,
            [],
            "location.request",
            %{"reason" => "weather"}
          )

        SystemsRuntime.Proc.send(owner, {:inline_before_session_commit, result})
        # Stop at the actual execute/actor-commit seam: discard only the returned
        # session events, retaining everything execute durably wrote itself.
        data
      end,
      :infinity
    )

    settle_receive({:inline_before_session_commit, {:ok, result, [], _events, _observed}})
    id = result.id
    assert result.error_class == "dependency_saturated"

    assert {:ok, %{"status" => "running", "completion_owner" => "direct_poll"}} =
             SalixAgent.InternalSession.lookup_async_call(
               read_internal!(agent_id, session_id),
               id
             )

    :ok = SalixAgent.DependencyJob.cancel(occupied)

    :ok = InternalSessionActor.wake(agent_id, session_id)

    assert eventually(fn ->
             case SalixAgent.InternalSession.lookup_async_call(
                    read_internal!(agent_id, session_id),
                    id
                  ) do
               {:ok, %{"status" => "failed"}} -> true
               _ -> false
             end
           end)

    recovered = read_internal!(agent_id, session_id)

    assert {:ok, %{"error_class" => "dependency_saturated", "completion_owner" => "direct_poll"}} =
             SalixAgent.InternalSession.lookup_async_call(recovered, id)

    assert SalixAgent.InternalSession.get(recovered, :messages) == []
    assert SalixAgent.InternalSession.get(recovered, :input_queue) == []
    settle_refute_receive(:unexpected_direct_model_wake, 100)
  end

  defp create_internal_agent! do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    agent_id
  end

  defp stage_internal(agent_id, session_id, source_message_id, content) do
    result =
      InternalSessionFleet.stage_delivery(agent_id, session_id, %{
        source_message_id: source_message_id,
        payload: %{
          session_id: session_id,
          role: "user",
          content: content,
          created_at: SystemsClock.system_time(:second)
        }
      })

    :ok = InternalSessionActor.wake(agent_id, session_id)
    result
  end

  defp internal_actor_pid!(agent_id, session_id) do
    [{pid, _}] =
      Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id))

    pid
  end

  defp dependency_failure?(agent_id, session_id, reason_fragment) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
          event["kind"] == "llm_call_failed" and
            String.contains?(inspect(event), reason_fragment)
        end)

      {:error, _reason} ->
        false
    end
  end

  defp assistant_content?(agent_id, session_id, content) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(
          SalixAgent.InternalSession.get(session, :messages),
          &(&1.role == "assistant" and &1.content == content)
        )

      {:error, _reason} ->
        false
    end
  end

  defp read_internal!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp done_response(content) do
    {:assistant, content,
     [
       %{
         id:
           "dependency_liveness_end_turn_#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}",
         name: "end_turn",
         args: %{"outcome" => "done"}
       }
     ]}
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:telemetry, event, measurements, metadata})
  end

  # The model admissions refused so far, each at the clock time it was read.
  defp refusals_at(now) do
    SystemsRuntime.Proc.receive do
      {:telemetry, [:salix, :dependency_job, :stop], _, %{kind: :llm, outcome: :saturated}} ->
        [now | refusals_at(now)]
    after
      0 -> []
    end
  end

  # The driven clock moves to the next timer whenever this test settles or
  # blocks in a call while the system is idle. Between a dependency's start
  # and the reads of its pending job, that next timer is the job's own
  # deadline. This helper waits in a plain receive instead, which leaves the
  # clock where it is; the test's timeout bounds it.
  defp await_started(tag) do
    SystemsRuntime.Proc.receive do
      {^tag, pid} -> pid
    end
  end

  defp off_clock(read) do
    test = SystemsRuntime.Proc.self()
    ref = SystemsRuntime.Proc.make_ref()
    SystemsRuntime.Proc.spawn(fn -> SystemsRuntime.Proc.send(test, {ref, read.()}) end)

    SystemsRuntime.Proc.receive do
      {^ref, value} -> value
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
