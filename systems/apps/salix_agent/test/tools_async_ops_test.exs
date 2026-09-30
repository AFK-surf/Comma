defmodule SalixAgent.Tools.AsyncOpsTest do
  @moduledoc """
  Async-op lifecycle tools (`SalixAgent.Tools.AsyncOps`): direct-fun unit
  tests, wait events round-tripping through internal session state, and
  user-interaction tool completion through the owning session actor.
  """
  use ExUnit.Case, async: false

  defmodule ChangingEventsResult do
    defstruct [:events, :token, content: "done", status: "completed"]

    def fetch(result, :events) do
      key = {__MODULE__, result.token}
      read = Process.get(key, 0)
      Process.put(key, read + 1)
      if read == 0, do: {:ok, []}, else: Map.fetch(result, :events)
    end

    def fetch(result, key), do: Map.fetch(result, key)
  end

  alias SalixAgent.{DependencyJob, ToolDisclosure, Tools}
  alias SalixAgent.Tools.AsyncOps
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.{AsyncToolResults, Fleet, InternalSessionStore, Round, Server, Waits}
  alias SalixAgent.InternalSession.State, as: SessionState
  alias SalixAgent.LLM.Mock
  alias SalixStore.{Agent, Keys, RuntimeIds, S3}
  alias SalixStore.S3.Fake
  alias SalixStore.Timers, as: StoreTimers

  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  defmodule CapabilityRequestStoreStub do
    @moduledoc false
    @behaviour SalixAgent.CapabilityRequestStore

    @impl true
    def create_capability_request(attrs) do
      Process.sleep(Application.get_env(:salix_agent, :capability_request_store_test_delay_ms, 0))

      request =
        attrs
        |> Map.put_new("request_id", "req-#{System.unique_integer([:positive])}")
        |> Map.put_new("status", "pending")
        |> Map.put_new("response_payload", %{})

      send(Application.fetch_env!(:salix_agent, :capability_request_store_test_pid), {
        :created_capability_request,
        request
      })

      {:ok, request}
    end

    @impl true
    def cancel_capability_request(agent_id, session_id, tool_call_id, reason) do
      request = %{
        "source_agent_id" => agent_id,
        "source_session_id" => session_id,
        "tool_call_id" => tool_call_id,
        "status" => "cancelled",
        "cancel_reason" => reason
      }

      send(Application.fetch_env!(:salix_agent, :capability_request_store_test_pid), {
        :cancelled_capability_request,
        request
      })

      {:ok, request}
    end
  end

  defmodule RuntimeEnv do
    @moduledoc false
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"] || "test-device-runtime",
         "command" => config["command"] || "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id),
      do:
        {:ok,
         %{
           "status" => "unknown",
           "connector_run_id" => "test-connector-run",
           "device_id" => config["device_id"] || "test-device",
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  @ctx %{
    agent_id: "agt1_0000000000000000001_0000000000000000002_0000000000000000003",
    session_id: "ses1_0000000000000000802"
  }

  setup do
    prev_mod = Application.get_env(:salix_agent, :capability_request_store_mod)
    prev_pid = Application.get_env(:salix_agent, :capability_request_store_test_pid)
    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    prev_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)

    prev_capability_delay =
      Application.get_env(:salix_agent, :capability_request_store_test_delay_ms)

    Application.put_env(:salix_agent, :capability_request_store_mod, CapabilityRequestStoreStub)
    Application.put_env(:salix_agent, :capability_request_store_test_pid, self())
    Application.put_env(:salix_store, :s3_backend, Fake)

    start_or_reset_fake()

    on_exit(fn ->
      restore_env(:capability_request_store_mod, prev_mod)
      restore_env(:capability_request_store_test_pid, prev_pid)
      restore_store_env(:s3_backend, prev_store)
      restore_env(:group_context_mod, prev_group_context)
      restore_env(:runtime_environment_mod, prev_runtime_environment)
      restore_env(:external_runtime_driver, prev_external_runtime)
      restore_env(:capability_request_store_test_delay_ms, prev_capability_delay)
    end)

    :ok
  end

  defp reduce_session(events, session_id \\ "ses1_0000000000000000802") do
    "a"
    |> SalixAgent.InternalSession.new(session_id)
    |> SalixAgent.InternalSession.export()
    |> SessionData.apply_events(events)
  end

  defp seed_session(
         events,
         agent_id \\ SalixAgent.TestSupport.new_agent_id(),
         session_id \\ "ses1_0000000000000000802"
       ) do
    ensure_control_agent!(agent_id)
    {:ok, _session} = InternalSessionStore.prepare_commit(agent_id, session_id, events)
    %{agent_id: agent_id, session_id: session_id}
  end

  defp ensure_control_agent!(agent_id) do
    case SalixAgent.Control.get_record(agent_id) do
      {:ok, _agent} ->
        :ok

      {:error, :not_found} ->
        SalixAgent.TestSupport.create_control_agent!(agent_id)
        :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
  defp restore_store_env(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore_store_env(key, value), do: Application.put_env(:salix_store, key, value)

  defp start_or_reset_fake do
    case start_supervised(Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Fake.reset()
      {:error, :already_present} -> Fake.reset()
    end
  end

  # AgentServer now only routes internal work. The durable session store is the
  # assertion point after the per-session actor leaves queued/active states.
  defp wake_and_settle(agent_id) do
    Server.wake(agent_id)
    result = Server.info(agent_id)
    assert eventually(fn -> internal_sessions_settled?(agent_id) end, 200)
    result
  end

  defp internal_sessions_settled?(agent_id) do
    case SalixAgent.InternalSessionStore.list(agent_id) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _} ->
        false
    end
  end

  defp wait_payload(wait_id, deadline) do
    %{
      "wait_id" => wait_id,
      "reason" => "timer registration test",
      "timeout_seconds" => 60,
      "deadline_ms" => deadline,
      "source" => "wait_for"
    }
  end

  defp pending(session_id) do
    %{
      session_id: session_id,
      trace_ctx: %{turn_id: nil, round_id: nil, request_id: nil, trace_id: nil}
    }
  end

  defp result_with_wait(session_id, wait) do
    %{
      id: "call-" <> wait["wait_id"],
      name: "wait_for",
      content: Jason.encode!(%{"status" => "waiting", "wait_id" => wait["wait_id"]}),
      error: false,
      status: "ok",
      events: [Waits.event(session_id, wait)]
    }
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  describe "wait_for" do
    test "emits active wait_set with reason/deadline and returns waiting JSON" do
      args = %{"reason" => "compiling", "timeout_seconds" => 30}
      {content, [ev]} = AsyncOps.wait_for(args, @ctx)

      decoded = Jason.decode!(content)
      assert decoded["status"] == "waiting"
      assert decoded["reason"] == "compiling"
      assert decoded["timeout_seconds"] == 30
      assert is_binary(decoded["wait_id"])

      assert %{"type" => "wait_set", "session_id" => "ses1_0000000000000000802", "wait" => wait} =
               ev

      assert wait["wait_id"] == decoded["wait_id"]
      assert wait["reason"] == "compiling"
      assert wait["timeout_seconds"] == 30
      assert wait["source"] == "wait_for"
      assert is_integer(wait["deadline_ms"])
    end

    test "requires reason" do
      assert_raise RuntimeError, "'reason' is required", fn -> AsyncOps.wait_for(%{}, @ctx) end
    end

    test "validates timeout_seconds within 1..1800 (optional, default 60)" do
      for bad <- [0, 1801] do
        assert_raise RuntimeError, ~r/'timeout_seconds' must be between 1 and 1800/, fn ->
          AsyncOps.wait_for(
            %{"reason" => "r", "timeout_seconds" => bad},
            @ctx
          )
        end
      end

      # omitted timeout uses the recommended default and succeeds
      assert {_content, [_ev]} = AsyncOps.wait_for(%{"reason" => "r"}, @ctx)
    end

    test "session id comes from ctx only; args cannot retarget another session" do
      {_c, [ev]} =
        AsyncOps.wait_for(
          %{"reason" => "r", "session_id" => "s9"},
          @ctx
        )

      assert ev["session_id"] == "ses1_0000000000000000802"

      ctx = Map.put(@ctx, :session_id, "ses1_0000000000000000804")
      {_c, [ev]} = AsyncOps.wait_for(%{"reason" => "r"}, ctx)
      assert ev["session_id"] == "ses1_0000000000000000804"
    end
  end

  defp seed_timeout_session(timeouts, extra_tail \\ []) do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    wakes =
      Enum.flat_map(1..timeouts//1, fn i ->
        [
          %{
            id: i * 3,
            role: "runtime",
            type: "wait_expired",
            content: "wait timeout reached"
          },
          %{id: i * 3 + 1, role: "assistant", content: "", tool_calls: []},
          %{id: i * 3 + 2, role: "tool", tool_call_id: "c#{i}", content: "error: no such file"}
        ]
      end)

    messages = [%{id: 1, role: "user", content: "watch the deploy"}] ++ wakes ++ extra_tail

    base =
      SalixAgent.InternalSession.new(agent_id, "ses1_0000000000000000802", %{
        "created_at" => "2026-07-08T00:00:00Z"
      })

    state = %SessionState{
      SalixAgent.InternalSession.export(base)
      | messages: messages,
        next_message_id: 1000
    }

    :ok = InternalSessionStore.prepare_seed(agent_id, SalixAgent.InternalSession.open(state))
    %{agent_id: agent_id, session_id: "ses1_0000000000000000802"}
  end

  describe "wait_for activation budget" do
    setup do
      prev = Application.get_env(:salix_agent, :wait_for_activation_cap)
      on_exit(fn -> restore_env(:wait_for_activation_cap, prev) end)
      :ok
    end

    test "raises once consecutive wait timeouts reach the cap" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 3)
      ctx = seed_timeout_session(3)

      assert_raise RuntimeError, ~r/wait budget exhausted: 3 consecutive wait timeouts/, fn ->
        AsyncOps.wait_for(%{"reason" => "still waiting"}, ctx)
      end
    end

    test "waits below the cap succeed" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 3)
      ctx = seed_timeout_session(2)

      assert {_content, [_ev]} = AsyncOps.wait_for(%{"reason" => "still waiting"}, ctx)
    end

    test "sending a blocked update does not renew the timeout budget" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 3)

      for status <- ["completed", "failed"] do
        notification =
          SalixAgent.Waits.async_completion_content(
            %{"tool_call_id" => "blocked-update", "tool_name" => "im_api.internal.send_message"},
            %{"status" => status, "content" => "message delivery result"}
          )
          |> Jason.decode!()

        ctx =
          seed_timeout_session(3, [
            %{
              id: 900,
              role: "runtime",
              type: notification["type"],
              source_refs: notification["source_refs"],
              content: Jason.encode!(notification)
            },
            %{id: 901, role: "runtime", type: "wait_expired", content: "wait timeout reached"}
          ])

        assert_raise RuntimeError, ~r/wait budget exhausted: 4 consecutive wait timeouts/, fn ->
          AsyncOps.wait_for(%{"reason" => "waiting for the user to connect Slack"}, ctx)
        end
      end
    end

    test "a user or Worker reply after timeout exhaustion permits waiting for new work" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 3)

      for author <- ["user", "worker"] do
        ctx =
          seed_timeout_session(3, [
            %{
              id: 900,
              role: "user",
              content: "new information",
              source_refs: %{"from_role_label" => author}
            }
          ])

        assert {_content, [_ev]} = AsyncOps.wait_for(%{"reason" => "new background work"}, ctx)
      end
    end

    test "genuine external input resets the streak" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 3)

      ctx =
        seed_timeout_session(3, [
          %{
            id: 900,
            role: "runtime",
            type: "tool_call_completed",
            content: "background call finished"
          }
        ])

      assert {_content, [_ev]} = AsyncOps.wait_for(%{"reason" => "one more"}, ctx)
    end

    test "cap 0 disables the budget" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 0)
      ctx = seed_timeout_session(10)

      assert {_content, [_ev]} = AsyncOps.wait_for(%{"reason" => "unbounded"}, ctx)
    end

    test "fails open when the session cannot be read" do
      Application.put_env(:salix_agent, :wait_for_activation_cap, 1)

      assert {_content, [_ev]} =
               AsyncOps.wait_for(%{"reason" => "r"}, %{
                 agent_id: "no-such-agent",
                 session_id: "ses1_0000000000000000802"
               })
    end
  end

  describe "wait timer registration" do
    setup do
      prev = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, Fake)

      start_or_reset_fake()

      on_exit(fn -> restore_store_env(:s3_backend, prev) end)

      {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
    end

    test "tool result commit persists wait then registers wait timer", %{agent: agent} do
      ensure_control_agent!(agent)
      owned = %{agent_id: agent}
      lease = %Agent.Owned{agent_id: agent}
      deadline = System.system_time(:millisecond) + 60_000
      wait = wait_payload("wait-success", deadline)

      assert {:error, :agent_lease_not_session_runtime_context} =
               Round.commit_tool_results(lease, pending("ses1_0000000000000000802"), [
                 result_with_wait("ses1_0000000000000000802", wait)
               ])

      assert {:error, {:session_runtime_context_missing, "ses1_0000000000000000802"}} =
               Round.commit_tool_results(
                 %{agent_id: agent},
                 pending("ses1_0000000000000000802"),
                 [
                   result_with_wait("ses1_0000000000000000802", wait)
                 ]
               )

      assert {:error,
              {:session_runtime_context_mismatch, "ses1_0000000000000000802",
               "ses1_0000000000000000803"}} =
               Round.commit_tool_results(
                 %{agent_id: agent, session_id: "ses1_0000000000000000803"},
                 pending("ses1_0000000000000000802"),
                 [
                   result_with_wait("ses1_0000000000000000802", wait)
                 ]
               )

      assert {:ok, _owned} =
               Round.commit_tool_results(
                 runtime_context(owned),
                 pending("ses1_0000000000000000802"),
                 [
                   result_with_wait("ses1_0000000000000000802", wait)
                 ]
               )

      assert SalixAgent.InternalSession.get(
               read_session!(agent, "ses1_0000000000000000802"),
               :wait
             )["wait_id"] == "wait-success"

      assert {:ok, _} =
               S3.head(
                 Keys.timer(
                   agent,
                   "ses1_0000000000000000802",
                   "wait-success",
                   StoreTimers.minute_bucket(deadline)
                 )
               )
    end

    test "timer registration failure does not discard durable wait; activation re-registers it",
         %{
           agent: agent
         } do
      ensure_control_agent!(agent)
      owned = %{agent_id: agent}
      deadline = System.system_time(:millisecond) + 60_000
      wait = wait_payload("wait-failure", deadline)
      bucket = StoreTimers.minute_bucket(deadline)
      key = Keys.timer(agent, "ses1_0000000000000000802", "wait-failure", bucket)
      :ok = Fake.blackhole({:fail, 503, :put, key})

      assert {:ok, _owned} =
               Round.commit_tool_results(
                 runtime_context(owned),
                 pending("ses1_0000000000000000802"),
                 [
                   result_with_wait("ses1_0000000000000000802", wait)
                 ]
               )

      assert SalixAgent.InternalSession.get(
               read_session!(agent, "ses1_0000000000000000802"),
               :wait
             )["wait_id"] == "wait-failure"

      assert {:error, :not_found} = S3.head(key)

      :ok = Fake.clear_blackhole()
      :ok = SalixAgent.InternalSessionActor.wake(agent, "ses1_0000000000000000802")

      assert eventually(fn ->
               match?({:ok, _}, S3.head(key))
             end)
    end
  end

  describe "tool call management" do
    test "status/result read the current session tool call record and cancel emits events" do
      ctx =
        seed_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "t1",
            "tool_name" => "env.copy",
            "status" => "running"
          },
          Waits.event(
            "ses1_0000000000000000802",
            Waits.build("async tool still running", 20, "auto_wait", %{"tool_call_id" => "t1"})
          )
        ])

      status =
        AsyncOps.get_tool_call_status(%{"tool_call_id" => "t1"}, ctx)
        |> Jason.decode!()

      assert status["status"] == "running"
      assert status["tool_name"] == "env.copy"
      assert status["has_result"] == false
      assert status["has_error"] == false

      result =
        AsyncOps.get_tool_call_result(%{"tool_call_id" => "t1"}, ctx)
        |> Jason.decode!()

      assert result["status"] == "running"

      {content, [cancel, clear]} =
        AsyncOps.cancel_tool_call(
          %{"tool_call_id" => "t1", "reason" => "no longer needed"},
          ctx
        )

      assert Jason.decode!(content)["status"] == "cancelled"
      assert Jason.decode!(content)["reason"] == "no longer needed"

      assert_receive {:cancelled_capability_request,
                      %{
                        "source_agent_id" => source_agent_id,
                        "source_session_id" => "ses1_0000000000000000802",
                        "tool_call_id" => "t1",
                        "cancel_reason" => "no longer needed"
                      }}

      assert source_agent_id == ctx.agent_id

      assert cancel["type"] == "async_tool_call_cancelled"
      assert cancel["cancel_reason"] == "no longer needed"
      assert clear == %{"type" => "wait_clear", "session_id" => "ses1_0000000000000000802"}
    end

    test "cancel keeps auto wait when another tool in the same wait is still running" do
      ctx =
        seed_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "t1",
            "tool_name" => "env.copy",
            "status" => "running"
          },
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "t2",
            "tool_name" => "env.exec",
            "status" => "running"
          },
          Waits.event(
            "ses1_0000000000000000802",
            Waits.build("async tools still running", 20, "auto_wait", %{
              "tool_call_id" => "t1",
              "tool_call_ids" => ["t1", "t2"]
            })
          )
        ])

      {content, events} =
        AsyncOps.cancel_tool_call(
          %{"tool_call_id" => "t1", "reason" => "no longer needed"},
          ctx
        )

      assert Jason.decode!(content)["status"] == "cancelled"
      assert [%{"type" => "async_tool_call_cancelled"}] = events
    end

    test "status/result read external runtime tool call records through runtime facade" do
      Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)

      Application.put_env(
        :salix_agent,
        :external_runtime_driver,
        SalixAgent.ExternalRuntime.None
      )

      agent_id = SalixAgent.TestSupport.new_agent_id()

      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "test-device",
          "runtime_id" => "test-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

      assert {:ok, :external} =
               SalixAgent.ExternalAgentRuntime.stage_delivery(agent_id, %{
                 source_message_id: "external-async-source",
                 payload: %{
                   "session_id" => "ses1_0000000000000000802",
                   "role" => "user",
                   "content" => "external async input"
                 }
               })

      assert {:ok, _session} =
               SalixAgent.ExternalAgentRuntime.commit_session_events(
                 agent_id,
                 "ses1_0000000000000000802",
                 [
                   %{
                     "type" => "async_tool_call_started",
                     "session_id" => "ses1_0000000000000000802",
                     "tool_call_id" => "ext-t1",
                     "tool_name" => "env.copy",
                     "status" => "running"
                   }
                 ]
               )

      ctx = %{agent_id: agent_id, session_id: "ses1_0000000000000000802"}

      status =
        AsyncOps.get_tool_call_status(%{"tool_call_id" => "ext-t1"}, ctx)
        |> Jason.decode!()

      result =
        AsyncOps.get_tool_call_result(%{"tool_call_id" => "ext-t1"}, ctx)
        |> Jason.decode!()

      assert status["status"] == "running"
      assert status["tool_name"] == "env.copy"
      assert status["has_result"] == false
      assert status["has_error"] == false
      assert result["status"] == "running"

      assert {:error, :not_found} =
               SalixAgent.InternalSessionStore.read(agent_id, "ses1_0000000000000000802")
    end

    test "cancel does not create records for unknown tool calls" do
      content =
        AsyncOps.cancel_tool_call(
          %{"tool_call_id" => "missing", "reason" => "not needed"},
          seed_session([
            %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"}
          ])
        )

      assert Jason.decode!(content) == %{
               "status" => "not_found",
               "tool_call_id" => "missing"
             }
    end

    @tag :ifc_result_reader
    test "async result reader preserves the completed result audience" do
      label = %{"label" => ["scope|cnx1|C_PRIVATE"]}

      ctx =
        seed_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "source-read",
            "tool_name" => "meeting.preparation.read_team_memory",
            "status" => "running"
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "source-read",
            "result" => %{"content" => "private original", "ifc" => label}
          }
        ])

      assert {:tool_ifc, content, [], ^label} =
               AsyncOps.get_tool_call_result(%{"tool_call_id" => "source-read"}, ctx)

      assert Jason.decode!(content)["result"]["content"] == "private original"
    end

    test "cancel returns current terminal record without changing status" do
      ctx =
        seed_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "done",
            "tool_name" => "env.copy",
            "status" => "running"
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "done",
            "result" => %{"content" => "done"}
          }
        ])

      content =
        AsyncOps.cancel_tool_call(
          %{"tool_call_id" => "done", "reason" => "too late"},
          ctx
        )

      decoded = Jason.decode!(content)
      assert decoded["status"] == "completed"
      assert decoded["result"] == %{"content" => "done"}
    end

    test "status/result return cancelled after the cancellation event is committed" do
      ctx =
        seed_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "cancelled",
            "tool_name" => "script.run",
            "status" => "running"
          },
          %{
            "type" => "async_tool_call_cancelled",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "cancelled",
            "cancel_reason" => "handtest cancel"
          }
        ])

      status =
        AsyncOps.get_tool_call_status(
          %{"tool_call_id" => "cancelled"},
          ctx
        )
        |> Jason.decode!()

      result =
        AsyncOps.get_tool_call_result(
          %{"tool_call_id" => "cancelled"},
          ctx
        )
        |> Jason.decode!()

      assert status["status"] == "cancelled"
      assert result["status"] == "cancelled"
      assert result["cancel_reason"] == "handtest cancel"
    end

    test "requires tool_call_id" do
      assert_raise RuntimeError, "'tool_call_id' is required", fn ->
        AsyncOps.get_tool_call_status(%{}, @ctx)
      end
    end

    test "failed async completion notification is typed as failed" do
      content =
        Waits.async_completion_content(
          %{
            "tool_call_id" => "tool-failed",
            "tool_name" => "env.exec"
          },
          %{
            "status" => "failed",
            "error" => true,
            "content" => "boom"
          }
        )

      assert %{
               "type" => "tool_call_failed",
               "status" => "failed",
               "tool_call_id" => "tool-failed",
               "error" => true,
               "result" => %{"content" => "boom"}
             } = decoded = Jason.decode!(content)

      assert decoded["source_refs"]["tool_call_id"] == "tool-failed"
      assert decoded["message"] =~ "short error details are included"
    end

    test "async completion unwraps only canonical result-reader pages" do
      page_body = String.duplicate("quote:\" slash:\\ controls:\n雪🚀", 2_000)

      page = %{
        "encoding" => "json",
        "result_ref" => "trf1_0000000000000000007",
        "offset" => 42,
        "content" => page_body,
        "content_chars" => String.length(page_body),
        "total_chars" => 42 + String.length(page_body) + 1,
        "total_bytes" => byte_size(page_body) + 43,
        "sha256" => String.duplicate("c", 64),
        "next_offset" => 42 + String.length(page_body),
        "truncated" => true
      }

      result = %{
        "status" => "completed",
        "error" => false,
        "content" => Jason.encode!(%{"result_page" => page})
      }

      reader_notification =
        Waits.async_completion_content(
          %{
            "tool_call_id" => "reader-page",
            "tool_name" => "tool_call.get_result"
          },
          result
        )
        |> Jason.decode!()

      assert reader_notification["result_page"] == page
      assert reader_notification["result_page"]["result_ref"] == page["result_ref"]
      assert reader_notification["result_page"]["offset"] == 42
      assert String.length(reader_notification["result_page"]["content"]) > 16_000

      ordinary_notification =
        Waits.async_completion_content(
          %{"tool_call_id" => "ordinary-page", "tool_name" => "env.exec"},
          result
        )
        |> Jason.decode!()

      assert ordinary_notification["result_page"]["encoding"] == "json"
      assert ordinary_notification["result_page"]["offset"] == 0
      assert ordinary_notification["result_page"]["content_chars"] == 16_000
      refute Map.has_key?(ordinary_notification["result_page"], "result_ref")
    end

    test "async completion strips deferred telemetry from stored and visible results" do
      pending = %{
        "session_id" => "ses1_0000000000000000802",
        "tool_call_id" => "tool-completed",
        "tool_name" => "script.run"
      }

      result = %{
        "content" => "done",
        "status" => "completed",
        "error" => false,
        :tool_observations => [
          %{
            source_key: "js-host-secret",
            trace_id: "trace-secret",
            tenant_id: "tenant-secret",
            group_id: "group-secret",
            app_revision: "revision-secret"
          }
        ]
      }

      assert [
               %{"type" => "async_tool_call_completed", "result" => stored},
               %{"type" => "queue_append", "payload" => %{"content" => content}}
             ] = AsyncToolResults.internal_events(pending, result)

      refute Map.has_key?(stored, "tool_observations")
      refute inspect(stored) =~ "trace-secret"

      decoded = Jason.decode!(content)
      refute Map.has_key?(decoded["result"], "tool_observations")
      refute content =~ "trace-secret"
      refute content =~ "tenant-secret"
      refute content =~ "revision-secret"
    end

    test "external async completion delivery carries explicit runtime message type" do
      pending = %{
        "session_id" => "ses1_0000000000000000802",
        "tool_call_id" => "tool-1",
        "tool_name" => "env.exec"
      }

      assert [
               %{"type" => "async_tool_call_completed"},
               %{"type" => "wait_clear"},
               %{"role" => "runtime"} = notification
             ] =
               AsyncToolResults.external_events(pending, %{"content" => "done"}, 12)

      assert notification["runtime_message_type"] == "tool_call_completed"
      assert notification["message_id"] == 12
      assert Jason.decode!(notification["content"])["result"]["content"] == "done"

      assert [
               %{"type" => "async_tool_call_failed"},
               %{"type" => "wait_clear"},
               %{"role" => "runtime"} = failed
             ] =
               AsyncToolResults.external_events(
                 pending,
                 %{"error" => true, "content" => "boom"},
                 13
               )

      assert failed["runtime_message_type"] == "tool_call_failed"
      assert failed["message_id"] == 13
      assert Jason.decode!(failed["content"])["result"]["content"] == "boom"

      assert [
               %{"type" => "async_tool_call_failed", "error" => true},
               %{"type" => "wait_clear"},
               %{"role" => "runtime"} = failed
             ] =
               AsyncToolResults.external_events(
                 pending,
                 %{"status" => "failed", "content" => "boom"},
                 14
               )

      assert failed["runtime_message_type"] == "tool_call_failed"
      assert failed["message_id"] == 14
      assert Jason.decode!(failed["content"])["result"]["content"] == "boom"
    end
  end

  describe "permission.request" do
    test "creates the permission request and returns running result with auto wait" do
      {content, [started, wait_set]} =
        AsyncOps.request_permission(
          %{"capability" => "host_access", "description" => "run a local command"},
          @ctx
        )

      decoded = Jason.decode!(content)
      assert decoded["status"] == "running"
      assert decoded["capability"] == "host_access"
      assert decoded["request_id"]
      assert decoded["tool_call_id"] == started["tool_call_id"]
      assert decoded["tool_call_id"] == started["tool_call_id"]
      assert decoded["auto_wait_seconds"] == 120

      assert %{
               "type" => "async_tool_call_started",
               "session_id" => "ses1_0000000000000000802",
               "tool_name" => "permission.request",
               "status" => "running",
               "completion_mode" => "external_callback",
               "auto_wait_seconds" => 120
             } = started

      assert %{"wait" => wait} = wait_set
      assert wait["source"] == "auto_wait"
      assert wait["timeout_seconds"] == 120
      assert wait["tool_call_id"] == started["tool_call_id"]
      assert wait["tool_call_id"] == started["tool_call_id"]

      assert_receive {:created_capability_request, request}
      assert request["source_agent_id"] == @ctx.agent_id
      assert request["source_session_id"] == "ses1_0000000000000000802"
      assert request["tool_call_id"] == started["tool_call_id"]
      assert request["tool_call_id"] == started["tool_call_id"]
      assert request["request_type"] == "host_access"
      assert request["request_payload"]["host_access"]["capability"] == "host_access"
      assert request["request_payload"]["host_access"]["description"] == "run a local command"
    end

    test "requires capability" do
      assert_raise RuntimeError, "'capability' is required", fn ->
        AsyncOps.request_permission(%{}, @ctx)
      end
    end

    test "dispatcher merges multiple permission request auto waits into one session wait" do
      {results, pending} =
        Tools.execute_with_async_window(
          [
            %{
              id: "perm-a",
              name: "permission.request",
              args: %{"capability" => "host_access", "description" => "run a command"}
            },
            %{
              id: "perm-b",
              name: "permission.request",
              args: %{"capability" => "computer_use_start", "description" => "use computer"}
            }
          ],
          dispatcher_ctx(Map.put(@ctx, :session_id, "ses1_0000000000000000802"))
        )

      # Exact 0ms polling intentionally permits already-finished setup jobs to
      # inline while every still-live job returns immediately under a token.
      # Either shape must preserve the same ordered early results and merged
      # wait; drain any live jobs here so this unit test also proves ownership
      # is releasable without an actor.
      assert Enum.all?(pending, &(&1.tool_call_id in ["perm-a", "perm-b"]))
      assert Enum.map(results, & &1.status) == ["async_running", "async_running"]

      events = Enum.flat_map(results, & &1.events)
      assert 2 == Enum.count(events, &(&1["type"] == "async_tool_call_started"))
      [wait_set] = Enum.filter(events, &(&1["type"] == "wait_set"))

      assert wait_set["session_id"] == "ses1_0000000000000000802"
      assert wait_set["wait"]["source"] == "auto_wait"
      assert wait_set["wait"]["timeout_seconds"] == 120
      assert wait_set["wait"]["tool_call_id"] == "perm-a"
      assert wait_set["wait"]["tool_call_ids"] == ["perm-a", "perm-b"]

      assert_receive {:created_capability_request, %{"tool_call_id" => "perm-a"}}
      assert_receive {:created_capability_request, %{"tool_call_id" => "perm-b"}}

      Enum.each(pending, fn %{dependency_job: job} ->
        assert {:ok, %{status: "async_running"}} = DependencyJob.yield(job, 1_000)
      end)
    end
  end

  describe "location.request" do
    test "creates the location request and returns running JSON with auto wait" do
      {content, [started, wait_set]} =
        AsyncOps.request_location(%{"reason" => "find nearby cafes"}, @ctx)

      decoded = Jason.decode!(content)

      assert decoded["status"] == "running"
      assert decoded["message"] == "location request is pending"
      assert is_binary(decoded["request_id"])
      assert decoded["tool_call_id"] == started["tool_call_id"]
      assert decoded["tool_call_id"] == started["tool_call_id"]
      assert started["type"] == "async_tool_call_started"
      assert started["tool_name"] == "location.request"
      assert started["completion_mode"] == "external_callback"
      assert started["auto_wait_seconds"] == 120
      assert wait_set["wait"]["source"] == "auto_wait"
      assert wait_set["wait"]["timeout_seconds"] == 120
      assert wait_set["wait"]["tool_call_id"] == started["tool_call_id"]

      assert_receive {:created_capability_request, request}
      assert request["source_agent_id"] == @ctx.agent_id
      assert request["source_session_id"] == "ses1_0000000000000000802"
      assert request["tool_call_id"] == started["tool_call_id"]
      assert request["tool_call_id"] == started["tool_call_id"]
      assert request["request_type"] == "location"
      assert request["request_payload"] == %{"location" => %{"reason" => "find nearby cafes"}}
      assert is_integer(request["expires_at"])
    end

    test "requires reason; validates timeout_seconds within 1..1800" do
      assert_raise RuntimeError, "missing required parameter: reason", fn ->
        AsyncOps.request_location(%{}, @ctx)
      end

      assert_raise RuntimeError, ~r/timeout_seconds must be between 1 and 1800/, fn ->
        AsyncOps.request_location(%{"reason" => "r", "timeout_seconds" => 1801}, @ctx)
      end
    end
  end

  describe "defs/0" do
    test "exposes tool call lifecycle tools in registration order with 2-arity funs" do
      entries = AsyncOps.defs()
      names = Enum.map(entries, &SalixAgent.Tools.entry_name/1)

      assert names == [
               "question.request",
               "permission.request",
               "location.request",
               "tool_call.get_status",
               "tool_call.get_result",
               "tool_call.cancel"
             ]

      assert entries |> Enum.take(2) |> Enum.all?(&(SalixAgent.Tools.entry_safety(&1) == "write"))

      for entry <- entries do
        {desc, fun, auto_wait_seconds} =
          case entry do
            {_name, desc, fun, auto_wait_seconds} ->
              {desc, fun, auto_wait_seconds}

            {_name, desc, fun, auto_wait_seconds, _opts} ->
              {desc, fun, auto_wait_seconds}
          end

        assert is_binary(desc) and desc != ""
        assert is_function(fun, 2)
        assert auto_wait_seconds in [20, 120]
      end

      {"wait_for", desc, fun, auto_wait_seconds} = AsyncOps.wait_for_def()
      assert desc != ""
      assert is_function(fun, 2)
      assert auto_wait_seconds == 20
    end

    test "stored-result pages budget the complete escaped envelope and reassemble exactly" do
      result_json =
        Jason.encode!(%{
          "payload" => String.duplicate("quote:\" slash:\\ controls:\n\t multibyte:雪🚀 ", 25_000),
          "tail" => [true, false, nil]
        })

      result_ref = "tr1_opaque_test_ref"
      sha256 = result_json |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      record = %{
        "kind" => "tool_result",
        "result_ref" => result_ref,
        "result_json" => result_json,
        "result_bytes" => byte_size(result_json),
        "result_chars" => String.length(result_json),
        "result_sha256" => sha256,
        "tool_name" => "composio.execute",
        "status" => "completed",
        "is_error" => false
      }

      {chunks, nil, page_count} =
        Enum.reduce_while(1..100, {[], 0, 0}, fn _, {chunks, offset, page_count} ->
          envelope = AsyncToolResults.result_page_envelope(record, offset, 120_000)
          encoded_envelope = Jason.encode!(envelope)
          page = envelope["result_page"]

          assert byte_size(encoded_envelope) <= 120_000
          assert page["result_ref"] == result_ref
          assert page["offset"] == offset
          assert page["total_chars"] == String.length(result_json)
          assert page["total_bytes"] == byte_size(result_json)
          assert page["sha256"] == sha256
          assert page["content_chars"] == String.length(page["content"])
          assert String.valid?(page["content"])

          state = {[page["content"] | chunks], page["next_offset"], page_count + 1}

          if page["next_offset"], do: {:cont, state}, else: {:halt, state}
        end)

      assert page_count > 2
      assert chunks |> Enum.reverse() |> IO.iodata_to_binary() == result_json
    end

    test "tool_call.get_result requires exactly one lookup key" do
      assert_raise RuntimeError, ~r/exactly one/, fn ->
        AsyncOps.get_tool_call_result(%{}, @ctx)
      end

      assert_raise RuntimeError, ~r/exactly one/, fn ->
        AsyncOps.get_tool_call_result(
          %{"tool_call_id" => "legacy-call", "result_ref" => "tr1_opaque"},
          @ctx
        )
      end
    end

    test "result_ref storage failures stay explicit instead of becoming not_found" do
      session_key = Keys.agent_internal_runtime_session(@ctx.agent_id, @ctx.session_id)
      assert :ok = Fake.set_fault_for(self(), {:fail, 503, :get, session_key})

      assert_raise RuntimeError,
                   "stored tool result lookup failed: {:http, 503}",
                   fn ->
                     AsyncOps.get_tool_call_result(
                       %{"result_ref" => "trf1_0000000000000000001"},
                       @ctx
                     )
                   end
    end
  end

  describe "events round-trip through internal session state" do
    test "wait_for derives :waiting on an idle session; wait_clear returns it to :paused" do
      {_c, [set]} = AsyncOps.wait_for(%{"reason" => "waiting for permission"}, @ctx)

      clear = %{"type" => "wait_clear", "session_id" => "ses1_0000000000000000802"}

      base = [%{"type" => "session_created", "session_id" => "ses1_0000000000000000802"}]

      waiting = reduce_session(base ++ [set])
      assert waiting.wait["reason"] == "waiting for permission"
      assert waiting.status == :idle
      assert SessionData.query(waiting, :derived_state) == :waiting

      idle = reduce_session(base ++ [set, clear])
      assert idle.wait == nil
      assert idle.status == :idle
      assert SessionData.query(idle, :derived_state) == :paused
    end

    test "wait_for active wait derives :waiting" do
      {_c, [set]} = AsyncOps.wait_for(%{"reason" => "building"}, @ctx)

      session =
        reduce_session([
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          set
        ])

      assert SessionData.query(session, :derived_state) == :waiting
    end
  end

  describe "user-interaction async completion (Fake backend + session actor + Mock LLM)" do
    setup do
      SalixAgent.TestSupport.stop_all_agents()
      prev = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

      start_or_reset_fake()

      start_supervised!(Mock)
      prev_llm = Application.get_env(:salix_agent, :llm)
      Application.put_env(:salix_agent, :llm, Mock)

      agent = SalixAgent.TestSupport.new_agent_id()

      on_exit(fn ->
        SalixAgent.TestSupport.stop_all_agents()
        Application.put_env(:salix_store, :s3_backend, prev)
        restore_env(:llm, prev_llm)
      end)

      {:ok, agent: agent}
    end

    test "completion resolves tool call and wakes the session", %{agent: a} do
      # Make setup deterministically cross the exact 0ms poll so this test
      # covers both ownership handoff and the later external completion wake.
      Application.put_env(:salix_agent, :capability_request_store_test_delay_ms, 25)

      Mock.script([
        {:assistant, "requesting host access",
         [
           %{
             id: "request-host-access",
             name: "call",
             args: %{
               "tool" => "permission.request",
               "params" => %{
                 "capability" => "host_access",
                 "description" => "run a command"
               }
             }
           }
         ]},
        {:assistant, "waiting for permission completion",
         [
           %{
             id: "wait-for-permission",
             name: "wait_for",
             args: %{"reason" => "waiting for permission completion"}
           }
         ]},
        {:final, "permission completion handled"}
      ])

      ensure_control_agent!(a)
      {:ok, _server} = Fleet.ensure_started(a, create: false)

      {:ok, :created} =
        deliver(a, "u1", %{
          content: "do the protected thing",
          session_id: "ses1_0000000000000000802"
        })

      {:parked, _owned} = wake_and_settle(a)

      async_id = "request-host-access"

      assert eventually(fn ->
               session = read_session!(a, "ses1_0000000000000000802")

               match?(
                 {:ok, %{"status" => "running", "completion_mode" => "external_callback"}},
                 SalixAgent.InternalSession.lookup_async_call(session, async_id)
               ) and
                 SalixAgent.InternalSession.wait(session)["reason"] ==
                   "waiting for permission completion" and
                 Enum.any?(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1.role == "runtime" and &1[:source_tool_call_id] == async_id and
                       &1.type == "tool_call_handoff")
                 )
             end)

      session = read_session!(a, "ses1_0000000000000000802")
      assert SalixAgent.InternalSession.status(session) == :idle
      assert SalixAgent.InternalSession.derived_state(session) == :waiting

      result_content = Jason.encode!(%{"status" => "approved", "capability" => "host_access"})

      assert {:ok, %{"status" => "completed", "tool_call_id" => ^async_id}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 "ses1_0000000000000000802",
                 async_id,
                 %{
                   "content" => result_content,
                   "output" => result_content,
                   "status" => "completed",
                   "error" => false
                 },
                 %{"tool_call_id" => "request-host-access", "tool_name" => "permission.request"}
               )

      assert eventually(fn ->
               with {:ok, s} <-
                      SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000802"),
                    {:ok, %{"status" => "completed"}} <-
                      SalixAgent.InternalSession.lookup_async_call(s, async_id) do
                 is_nil(SalixAgent.InternalSession.wait(s)) and
                   SalixAgent.InternalSession.status(s) == :idle and
                   SalixAgent.InternalSession.derived_state(s) == :paused and
                   Enum.any?(
                     SalixAgent.InternalSession.get(s, :messages),
                     &(&1.role == "runtime" and &1[:source_tool_call_id] == async_id and
                         &1.type == "tool_call_completed")
                   ) and
                   Enum.any?(
                     SalixAgent.InternalSession.get(s, :messages),
                     &(&1.role == "assistant" and
                         &1.content == "permission completion handled")
                   )
               else
                 _ -> false
               end
             end)

      {:ok, session} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000802")

      assert {:ok, %{"status" => "completed"}} =
               SalixAgent.InternalSession.lookup_async_call(session, async_id)

      [notification] =
        Enum.filter(
          SalixAgent.InternalSession.get(session, :messages),
          &(&1.role == "runtime" and &1[:source_tool_call_id] == async_id and
              &1.type == "tool_call_completed")
        )

      assert notification.runtime_message_id == "tool-call-result:" <> async_id
      assert notification.type == "tool_call_completed"
      assert Jason.decode!(notification.content)["result"]["content"] == result_content
    end

    @tag :ifc_result_reader
    test "result_ref reads canonical JSON only from its owning session", %{agent: a} do
      ensure_control_agent!(a)

      owner_session_id = "ses1_0000000000000000802"
      other_session_id = "ses1_0000000000000000803"
      result_ref = "trf1_0000000000000000001"
      result_json = Jason.encode!(String.duplicate("quoted:\" control:\n snow:雪 ", 12_000))

      result_sha256 =
        result_json |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      source_ifc = %{"label" => ["scope|cnx1|C_PRIVATE"]}

      assert {:ok, candidate} =
               SalixAgent.ToolResultProjection.prepare(
                 %{
                   id: "sync-large-result",
                   name: "composio.execute",
                   content: Jason.decode!(result_json),
                   ifc: source_ifc
                 },
                 result_ref
               )

      stored_event =
        SalixAgent.ToolResultProjection.stored_event(candidate)
        |> Map.put("session_id", owner_session_id)
        |> Map.put("stored_at_ms", 1)

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, owner_session_id, [
                 %{"type" => "session_created", "session_id" => owner_session_id},
                 stored_event
               ])

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, other_session_id, [
                 %{"type" => "session_created", "session_id" => other_session_id}
               ])

      result =
        execute_tool_sync!(a, owner_session_id, "tool_call.get_result", %{
          "result_ref" => result_ref,
          "offset" => 0,
          "limit" => 10_000
        })

      assert result.ifc == source_ifc
      {:ok, source_label} = SalixIFC.Codec.decode_label(result.ifc["label"])
      {:ok, other_recipient} = SalixIFC.Codec.decode_label(["scope|cnx1|@U_B"])

      facts =
        SalixIFC.Codec.decode_facts(%{
          "membership" => %{
            "scope|cnx1|C_PRIVATE" => %{"members" => ["provider_user|cnx1|U_A"]},
            "scope|cnx1|@U_B" => %{"members" => ["provider_user|cnx1|U_B"]}
          }
        })

      refute SalixIFC.readers_subset?(other_recipient, source_label, facts)

      assert {:error, :tool_result_ref_conflict} =
               InternalSessionStore.prepare_commit(a, owner_session_id, [
                 Map.put(stored_event, "ifc", %{"label" => ["public"]})
               ])

      page = Jason.decode!(result.content)["result_page"]
      assert page["result_ref"] == result_ref
      assert page["content"] == String.slice(result_json, 0, 10_000)
      assert page["total_chars"] == String.length(result_json)
      assert page["total_bytes"] == byte_size(result_json)
      assert page["sha256"] == result_sha256

      not_found =
        execute_tool_sync!(a, other_session_id, "tool_call.get_result", %{
          "result_ref" => result_ref
        })

      assert Jason.decode!(not_found.content) == %{
               "status" => "not_found",
               "result_ref" => result_ref
             }

      old_ref = "trf1_0000000000000000002"

      assert {:ok, _} =
               InternalSessionStore.prepare_commit(a, owner_session_id, [
                 stored_event |> Map.put("result_ref", old_ref) |> Map.delete("ifc")
               ])

      old_result =
        execute_tool_sync!(a, owner_session_id, "tool_call.get_result", %{"result_ref" => old_ref})

      [labelled_old] =
        SalixAgent.IFC.Check.stamp_results(
          [old_result],
          [%{name: "tool_call.get_result", args: %{"result_ref" => old_ref}}],
          %{ifc: %{"source_scope" => ["public"], "items" => []}}
        )

      assert labelled_old.ifc["label"] == ["agent_private"]
    end

    test "oversized failed completion stays bounded and is readable through result pages", %{
      agent: a
    } do
      ensure_control_agent!(a)
      Mock.script([{:final, "large result handled"}])

      session_id = "ses1_0000000000000000802"
      tool_call_id = "large-result"
      large_error = String.duplicate("failure-", 137_500)

      failed_result = %{
        "content" => "command failed",
        "error_message" => large_error,
        "status" => "failed",
        "error" => true
      }

      pending = %{
        "session_id" => session_id,
        "tool_call_id" => tool_call_id,
        "tool_name" => "env.exec"
      }

      assert [_, %{"type" => "wait_clear"}, %{"role" => "runtime"} = external_notification] =
               AsyncToolResults.external_events(pending, failed_result, 42)

      assert byte_size(Jason.encode!(external_notification)) < 100_000

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "env.exec",
            "status" => "running",
            "completion_mode" => "external_callback"
          }
        ])

      assert {:ok, %{"status" => "failed", "tool_call_id" => ^tool_call_id}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 session_id,
                 tool_call_id,
                 failed_result,
                 %{"tool_call_id" => tool_call_id, "tool_name" => "env.exec"}
               )

      assert eventually(fn ->
               SalixAgent.InternalSession.get(read_session!(a, session_id), :messages)
               |> Enum.any?(&(&1.role == "runtime" and &1.source_tool_call_id == tool_call_id))
             end)

      notification =
        SalixAgent.InternalSession.get(read_session!(a, session_id), :messages)
        |> Enum.find(&(&1.role == "runtime" and &1.source_tool_call_id == tool_call_id))
        |> Map.fetch!(:content)
        |> Jason.decode!()

      assert byte_size(Jason.encode!(notification)) < 100_000
      assert notification["result_page"]["encoding"] == "json"
      assert notification["result_page"]["offset"] == 0
      assert notification["result_page"]["next_offset"] > 0

      default_result =
        execute_tool_sync!(a, session_id, "tool_call.get_result", %{
          "tool_call_id" => tool_call_id
        })

      assert default_result.error
      assert default_result.diagnostic_visibility == "model_only"
      assert byte_size(default_result.content) <= 120_000
      default_page = Jason.decode!(default_result.content)["result_page"]
      assert default_page["offset"] == 0
      assert default_page["content_chars"] < 120_000
      assert default_page["next_offset"] == default_page["content_chars"]

      first_result =
        execute_tool_sync!(a, session_id, "tool_call.get_result", %{
          "tool_call_id" => tool_call_id,
          "offset" => 0,
          "limit" => 1_000
        })

      assert byte_size(first_result.content) < 100_000
      first = Jason.decode!(first_result.content)
      assert first["result_page"]["offset"] == 0
      assert String.length(first["result_page"]["content"]) == 1_000
      assert first["result_page"]["next_offset"] == 1_000

      second_result =
        execute_tool_sync!(a, session_id, "tool_call.get_result", %{
          "tool_call_id" => tool_call_id,
          "offset" => first["result_page"]["next_offset"],
          "limit" => 1_000
        })

      assert byte_size(second_result.content) < 100_000
      second = Jason.decode!(second_result.content)
      assert second["result_page"]["offset"] == 1_000

      encoded_result =
        read_session!(a, session_id)
        |> SalixAgent.InternalSession.lookup_async_call(tool_call_id)
        |> then(fn {:ok, record} -> record["result"] end)
        |> Jason.encode!()

      expected_sha256 = :crypto.hash(:sha256, encoded_result) |> Base.encode16(case: :lower)
      assert default_page["total_bytes"] == byte_size(encoded_result)
      assert default_page["sha256"] == expected_sha256

      assert first["result_page"]["content"] <> second["result_page"]["content"] ==
               String.slice(encoded_result, 0, 2_000)

      {chunks, nil} =
        Enum.reduce_while(1..10, {[], 0}, fn _, {chunks, offset} ->
          result =
            execute_tool_sync!(a, session_id, "tool_call.get_result", %{
              "tool_call_id" => tool_call_id,
              "offset" => offset,
              "limit" => 120_000
            })

          assert byte_size(result.content) <= 120_000
          page = Jason.decode!(result.content)["result_page"]
          next_offset = page["next_offset"]
          state = {[page["content"] | chunks], next_offset}

          if next_offset, do: {:cont, state}, else: {:halt, state}
        end)

      assert chunks |> Enum.reverse() |> IO.iodata_to_binary() == encoded_result
    end

    test "surface async completion rejects direct input side effects", %{agent: a} do
      ensure_control_agent!(a)
      {:ok, _server} = Fleet.ensure_started(a, create: false)

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000802", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "bad-side-effect",
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_mode" => "external_callback"
          }
        ])

      assert {:error, {:invalid_tool_side_effect_event, "delivery"}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 "ses1_0000000000000000802",
                 "bad-side-effect",
                 %{
                   "content" => "done",
                   "status" => "completed",
                   "events" => [
                     %{
                       "type" => "delivery",
                       "session_id" => "ses1_0000000000000000802",
                       "content" => "pollution"
                     }
                   ]
                 },
                 %{"tool_name" => "permission.request"}
               )

      {:ok, session} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000802")

      assert SalixAgent.InternalSession.get(session, :async_tool_calls)["bad-side-effect"][
               "status"
             ] == "running"

      refute Enum.any?(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:content] == "pollution")
             )

      assert {:error, {:invalid_tool_side_effect_event, "queue_append"}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 "ses1_0000000000000000802",
                 "bad-side-effect",
                 %{
                   "content" => "done",
                   "status" => "completed",
                   "events" => [
                     %{
                       "type" => "queue_append",
                       "session_id" => "ses1_0000000000000000802",
                       "kind" => "user_message",
                       "dedupe_key" => "tool-pollution",
                       "payload" => %{"content" => "pollution"}
                     }
                   ]
                 },
                 %{"tool_name" => "permission.request"}
               )

      {:ok, session} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000802")

      assert SalixAgent.InternalSession.get(session, :async_tool_calls)["bad-side-effect"][
               "status"
             ] == "running"

      refute Enum.any?(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
               payload = item["payload"] || %{}
               payload["content"] == "pollution"
             end)
    end

    test "side-effect validation checks selected events without serializing unrelated result fields" do
      dangerous = [%{"type" => "queue_consume", "queue_id" => 1}]

      assert :ok =
               SalixAgent.ToolSideEffects.validate_results([
                 %{"events" => dangerous, events: [], diagnostic: self()}
               ])

      for empty <- [false, nil] do
        assert {:error, {:invalid_tool_side_effect_event, "queue_consume"}} =
                 SalixAgent.ToolSideEffects.validate_results([
                   %{"events" => dangerous, events: empty, diagnostic: make_ref()}
                 ])
      end

      for type <- ["archive_advance", "session_stamp"] do
        assert {:error, {:invalid_tool_side_effect_event, ^type}} =
                 SalixAgent.ToolSideEffects.validate_events([%{"type" => type}])
      end

      assert :ok =
               SalixAgent.ToolSideEffects.validate_results([
                 %{"events" => [%{"type" => "provider_extension", "content" => "retained"}]}
               ])
    end

    test "surface async completion cannot retire accepted input", %{agent: a} do
      ensure_control_agent!(a)
      {:ok, _server} = Fleet.ensure_started(a, create: false)
      session_id = "ses1_0000000000000000802"

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "retirement-side-effect",
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_mode" => "external_callback"
          },
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "accepted-before-tool-result",
            "wake" => false,
            "payload" => %{"content" => "keep this accepted work"}
          }
        ])

      {:ok, before} = InternalSessionStore.read(a, session_id)
      [accepted] = SalixAgent.InternalSession.get(before, :input_queue)

      results =
        for event <- [
              %{"type" => "queue_consume", "queue_id" => accepted["queue_id"]},
              %{"type" => "queue_ack", "queue_ack_id" => accepted["queue_id"]},
              %{~c"type" => "queue_consume", "queue_id" => accepted["queue_id"]},
              %{[~c"ty", "pe"] => "queue_consume", "queue_id" => accepted["queue_id"]},
              %{
                "type" => "session_event",
                :type => "queue_consume",
                "queue_id" => accepted["queue_id"]
              }
            ],
            do: %{"content" => "done", "status" => "completed", "events" => [event]}

      changing_result = %ChangingEventsResult{
        events: [%{"type" => "queue_consume", "queue_id" => accepted["queue_id"]}],
        token: "changing-events-#{System.unique_integer([:positive])}"
      }

      for payload <- results ++ [changing_result] do
        result =
          SalixAgent.complete_async_tool_call(
            a,
            session_id,
            "retirement-side-effect",
            payload,
            %{"tool_name" => "permission.request"}
          )

        {:ok, durable} = InternalSessionStore.read(a, session_id)

        assert accepted in SalixAgent.InternalSession.get(durable, :input_queue) or
                 Enum.any?(SalixAgent.InternalSession.get(durable, :messages), fn message ->
                   message[:accepted_input] == accepted
                 end)

        assert {:error, {:invalid_tool_side_effect_event, type}} = result
        assert type in ["queue_consume", "queue_ack"]

        assert SalixAgent.InternalSession.get(durable, :async_tool_calls)[
                 "retirement-side-effect"
               ]["status"] == "running"
      end

      ordinary_result =
        %ChangingEventsResult{events: [], token: "ordinary", content: "retained result"}
        |> Map.put("__struct__", "application data")

      assert {:ok, %{"status" => "completed"}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 session_id,
                 "retirement-side-effect",
                 ordinary_result,
                 %{"tool_name" => "permission.request"}
               )

      {:ok, durable} = InternalSessionStore.read(a, session_id)

      assert {:ok, completed} =
               SalixAgent.InternalSession.lookup_async_call(durable, "retirement-side-effect")

      assert completed["result"]["content"] == "retained result"
      assert completed["result"]["__struct__"] == "application data"
    end

    test "surface async completion registers timers for wait_set side effects", %{agent: a} do
      ensure_control_agent!(a)
      {:ok, _server} = Fleet.ensure_started(a, create: false)

      wait_id = "async-result-wait-#{System.unique_integer([:positive])}"
      deadline_ms = System.system_time(:millisecond) + 60_000

      wait = %{
        "wait_id" => wait_id,
        "reason" => "wait after async result",
        "timeout_seconds" => 60,
        "deadline_ms" => deadline_ms
      }

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000802", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000802"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000802",
            "tool_call_id" => "async-wait",
            "tool_name" => "SlowTool",
            "status" => "running",
            "completion_mode" => "external_callback"
          }
        ])

      assert {:ok, %{"status" => "completed", "tool_call_id" => "async-wait"}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 "ses1_0000000000000000802",
                 "async-wait",
                 %{
                   "content" => "done",
                   "status" => "completed",
                   "events" => [
                     %{
                       "type" => "wait_set",
                       "session_id" => "ses1_0000000000000000802",
                       "wait" => wait
                     }
                   ]
                 },
                 %{"tool_name" => "SlowTool"}
               )

      assert {:ok, timers} =
               StoreTimers.sweep(StoreTimers.minute_bucket(deadline_ms), deadline_ms)

      assert Enum.any?(timers, fn timer ->
               timer["timer_id"] == wait_id and
                 timer["agent_id"] == a and
                 timer["session_id"] == "ses1_0000000000000000802" and
                 timer["source_message_id"] ==
                   "wait-timeout:ses1_0000000000000000802:#{wait_id}"
             end)
    end

    test "stored async result keeps identical content and output only once" do
      content = String.duplicate("linear-result-", 20_000)

      stored =
        AsyncToolResults.stored_result(%{
          "content" => content,
          "output" => content,
          "status" => "completed",
          "error" => false
        })

      assert stored["content"] == content
      refute Map.has_key?(stored, "output")
      assert byte_size(Jason.encode!(stored)) < byte_size(content) + 100

      assert AsyncToolResults.stored_result(%{
               "content" => "model-visible",
               "output" => "distinct trace output"
             })["output"] == "distinct trace output"
    end
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp runtime_context(%{agent_id: agent_id}),
    do: %{agent_id: agent_id, session_id: "ses1_0000000000000000802"}

  defp dispatcher_ctx(ctx) do
    ctx = Map.merge(%{role: "worker", runtime_kind: :external}, ctx)
    ctx = SalixAgent.TestSupport.with_plugin_projection(ctx)
    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :external, ctx))
  end

  defp execute_tool_sync!(agent_id, session_id, tool_name, attrs) do
    call = %{
      id: "sync-#{tool_name}-#{System.unique_integer([:positive])}",
      name: tool_name,
      args: attrs
    }

    [result] =
      Tools.execute(
        [call],
        dispatcher_ctx(%{agent_id: agent_id, session_id: session_id})
      )

    result
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
