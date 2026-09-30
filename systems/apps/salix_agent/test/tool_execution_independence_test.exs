defmodule SalixAgent.ToolExecutionIndependenceTest do
  @moduledoc """
  Calls in one assistant turn are independent unless the runtime has an
  explicit dependency between them. A pending lookup must not become a
  turn-wide barrier for an outbound call, and tool results remain in the
  model's original call order even when execution completes out of order.

  The delayed lookup reproduces the incident shape deterministically: its
  zero-time async admission result is `async_running`, while the outbound call
  still reaches the provider exactly once.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{
    InternalSessionFleet,
    InternalSessionStore,
    SessionToolDispatch,
    ToolDisclosure,
    VisibleReplyPolicy
  }

  @session_id "ses1_0000000000000000902"

  # Long enough that the tool is certainly still running when the zero-time
  # poll happens, which is what makes "undecided" deterministic here.
  @undecided_sleep_ms 1_000

  defmodule FunLLM do
    @moduledoc "Scriptable LLM where each turn is a fun of (messages, tools)."
    @behaviour SalixAgent.LLM
    use Elixir.Agent

    def start_link(_), do: Elixir.Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def script(funs), do: Elixir.Agent.update(__MODULE__, fn _ -> funs end)

    @impl true
    def complete(messages, tools) do
      case Elixir.Agent.get_and_update(__MODULE__, fn
             [f | rest] -> {f, rest}
             [] -> {nil, []}
           end) do
        nil -> {:final, "script exhausted"}
        fun -> fun.(messages, tools)
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  defmodule TestMCPProvider do
    @moduledoc "Delayed read plus an independently executable write."

    def provider_state(_agent_id), do: {:ok, %{}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         entry("lookup", "read"),
         entry("send_notice", "write")
       ]}
    end

    # Tagged with `agent_id`, and that is not cosmetic. The blocked case leaves
    # a 1s task still running when its test ends; this function reads the
    # target pid at SEND time, by which point `on_exit` has restored it and the
    # next test's `setup` has installed ITS pid. Untagged, that straggler
    # satisfies the next test's `assert_receive` — measured: a companion test
    # that ran no tools at all still passed. Every test gets a fresh
    # `new_agent_id()`, so matching on it closes the channel.
    def call_tool(agent_id, "egress", tool, _args, _ctx) do
      Process.sleep(sleep_ms(tool))

      case Application.get_env(:salix_agent, :tool_independence_test_pid) do
        pid when is_pid(pid) -> send(pid, {:mcp_executed, agent_id, tool})
        _ -> :ok
      end

      {:ok, %{"content" => "#{tool} executed", "status" => "completed"}}
    end

    defp entry(tool, safety) do
      %{
        "name" => "mcp.egress.#{tool}",
        "summary" => "Fake MCP tool with a declared safety class.",
        "manual" => "Fake MCP tool with a declared safety class.",
        "safety" => safety,
        "input_schema" => %{"type" => "object", "properties" => %{}}
      }
    end

    defp sleep_ms("lookup"),
      do: Application.get_env(:salix_agent, :tool_independence_test_lookup_sleep_ms, 0)

    defp sleep_ms(_tool), do: 0
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_mcp = Application.get_env(:salix_agent, :mcp_provider_mod)
    prev_sleep = Application.get_env(:salix_agent, :tool_independence_test_lookup_sleep_ms)
    prev_pid = Application.get_env(:salix_agent, :tool_independence_test_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(FunLLM)
    Application.put_env(:salix_agent, :llm, FunLLM)
    Application.put_env(:salix_agent, :mcp_provider_mod, TestMCPProvider)
    Application.put_env(:salix_agent, :tool_independence_test_pid, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore(:llm, prev_llm)
      restore(:mcp_provider_mod, prev_mcp)
      restore(:tool_independence_test_lookup_sleep_ms, prev_sleep)
      restore(:tool_independence_test_pid, prev_pid)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant_id,
      group_id: group_id,
      role: "worker"
    })

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "session_created",
          "session_id" => @session_id,
          "platform" => "raft"
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "content" => "look it up and tell them"
        }
      ])

    {:ok, agent: agent, context: %{agent_id: agent, session_id: @session_id}}
  end

  test "a pending read does not prevent an independent write in the same turn",
       %{agent: agent, context: context} do
    ack_setup_input!(agent, @session_id)

    Application.put_env(
      :salix_agent,
      :tool_independence_test_lookup_sleep_ms,
      @undecided_sleep_ms
    )

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "checking, then telling them",
         [
           mcp_call("egress-lookup-1", "lookup"),
           mcp_call("egress-send-1", "send_notice")
         ]}
      end
    ])

    assert {:ok, _context, {:async_tools_started, pending}} =
             InternalSessionFleet.run_round(agent, @session_id, context,
               __round_run_delegate__: true
             )

    assert Enum.any?(pending, &(&1.tool_call_id == "egress-lookup-1"))
    assert_receive {:mcp_executed, ^agent, "send_notice"}, 2_000
    refute_receive {:mcp_executed, ^agent, "send_notice"}, 100

    [lookup, send] = committed_tool_results(agent)

    assert lookup.tool_call_id == "egress-lookup-1"
    assert lookup.status == "async_running"
    assert lookup.diagnostic_visibility == "none"

    assert send.tool_call_id == "egress-send-1"
    refute send.status == "guidance"
    refute Map.get(send, :guidance_reason) == "egress_dependency_failed"
    refute Map.get(send, :repair_outcome) == "deferred_visible_side_effect"
  end

  test "Inspector dispatch refuses generic MCP even with a stale ordinary disclosure", %{
    agent: agent
  } do
    context =
      tool_ctx(agent)
      |> Map.put(:inspector_policy, SalixAgent.TestSupport.inspector_policy())

    [result] = SessionToolDispatch.execute([mcp_call("inspector-bypass", "send_notice")], context)
    assert %{error: true, error_class: "forbidden", events: []} = result
    refute_received {:mcp_executed, ^agent, _}
  end

  test "a write before a delayed read retains original result order", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, @session_id)

    Application.put_env(
      :salix_agent,
      :tool_independence_test_lookup_sleep_ms,
      @undecided_sleep_ms
    )

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "telling them and checking",
         [
           mcp_call("egress-send-first", "send_notice"),
           mcp_call("egress-lookup-second", "lookup")
         ]}
      end
    ])

    assert {:ok, _context, {:async_tools_started, pending}} =
             InternalSessionFleet.run_round(agent, @session_id, context,
               __round_run_delegate__: true
             )

    assert Enum.any?(pending, &(&1.tool_call_id == "egress-lookup-second"))
    assert_receive {:mcp_executed, ^agent, "send_notice"}, 2_000

    [send, lookup] = committed_tool_results(agent)
    assert send.tool_call_id == "egress-send-first"
    assert lookup.tool_call_id == "egress-lookup-second"
    refute send.status == "guidance"
    assert lookup.status == "async_running"
  end

  test "get_result queries a running call once without cancelling an independent write", %{
    agent: agent
  } do
    target_call_id = "already-running-tool"

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, @session_id, [
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_id,
                 "tool_call_id" => target_call_id,
                 "tool_name" => "env.exec",
                 "status" => "running",
                 "completion_mode" => "external_callback",
                 "started_at" => System.system_time(:millisecond)
               }
             ])

    [query, send] =
      SessionToolDispatch.execute(
        [
          %{
            id: "query-running-tool",
            name: "call",
            args: %{
              "tool" => "tool_call.get_result",
              "params" => %{"tool_call_id" => target_call_id}
            }
          },
          mcp_call("send-beside-query", "send_notice")
        ],
        tool_ctx(agent)
      )

    assert query.status == "completed"

    assert Jason.decode!(query.content) == %{
             "message" => "tool call has not completed yet",
             "status" => "running",
             "tool_call_id" => target_call_id
           }

    assert send.status == "completed"
    assert_receive {:mcp_executed, ^agent, "send_notice"}, 2_000
    refute_receive {:mcp_executed, ^agent, "send_notice"}, 100

    assert {:ok, session} = InternalSessionStore.read(agent, @session_id)

    assert {:ok, %{"status" => "running"}} =
             SalixAgent.InternalSession.lookup_async_call(session, target_call_id)
  end

  test "a corrected write executes in repair and returns its real receipt", %{agent: agent} do
    ctx =
      agent
      |> tool_ctx()
      |> Map.put(:visible_reply_phase, {:repair_required, 0})
      |> Map.put(:visible_reply_guard, {:repair_required, 0, 1, 1})

    [result] =
      SessionToolDispatch.execute(
        [mcp_call("egress-repair-send", "send_notice")],
        ctx
      )

    assert result.status == "completed"
    assert result.content =~ "send_notice executed"
    refute Map.get(result, :repair_outcome) == "validated_visible_side_effect"
    assert VisibleReplyPolicy.transition({:repair_required, 0}, [result]) == :completed
    assert_receive {:mcp_executed, ^agent, "send_notice"}, 2_000
    refute_receive {:mcp_executed, ^agent, "send_notice"}, 100
  end

  defp mcp_call(id, tool),
    do: %{id: id, name: "call", args: %{"tool" => "mcp.egress.#{tool}", "params" => %{}}}

  defp committed_tool_results(agent) do
    {:ok, session} = InternalSessionStore.read(agent, @session_id)

    session
    |> SalixAgent.InternalSession.get(:messages)
    |> Enum.filter(&(&1[:role] == "tool"))
    |> Enum.sort_by(& &1[:id])
  end

  defp tool_ctx(agent_id) do
    ctx =
      %{
        agent_id: agent_id,
        session_id: @session_id,
        role: "worker",
        runtime_kind: :internal,
        llm_tool_envelope: true
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end

  defp ack_setup_input!(agent_id, session_id) do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "ack", "session_id" => session_id, "last_ack_message_id" => 1}
      ])
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)
end
