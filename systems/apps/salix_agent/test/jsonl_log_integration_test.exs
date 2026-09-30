defmodule SalixAgent.JsonlLogIntegrationTest do
  @moduledoc """
  Verbose JSONL logging across a full agent cycle: with `--log-file` enabled,
  a delivery → tool round → explicit terminal round → settle → park run
  emits one line per agent step (claim, wake, llm request/response,
  tool start/end, commits, settle), in order, with credentials never logged.
  """
  use ExUnit.Case, async: false

  alias CommaLog
  alias SalixAgent.{Fleet, Server}
  alias SalixAgent.InternalSession
  alias SalixAgent.LLM.Mock

  @session_id "ses1_0000000000000000101"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, Mock)

    path = Path.join(System.tmp_dir!(), "salix-e2e-#{System.unique_integer([:positive])}.jsonl")
    :ok = CommaLog.enable(path)

    on_exit(fn ->
      CommaLog.disable()
      File.rm(path)
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id(), path: path}
  end

  defp events(path) do
    CommaLog.flush()

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "a full delivery → tool round → settle cycle logs every step", %{agent: a, path: path} do
    Mock.script([
      {:assistant, "using a tool",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "done"}
    ])

    SalixAgent.TestSupport.create_control_agent!(a)
    {:ok, _pid} = Fleet.ensure_started(a, create: false)
    {:ok, :created} = deliver(a, "u1", %{content: "hi", session_id: @session_id})
    Server.wake(a)
    {:parked, _owned} = Server.info(a)

    assert eventually(
             fn ->
               internal_sessions_settled?(a) and
                 Enum.any?(
                   read_session!(a).messages,
                   &(&1.role == "assistant" and &1.content == "done")
                 )
             end,
             200
           )

    all = events(path)
    mine = Enum.filter(all, &(&1["agent_id"] == a))
    names = Enum.map(mine, & &1["event"])

    # AgentServer settles the routing cycle; the per-session actor owns the
    # round. Assert the routing and round order separately.
    assert order_of(names, "server_claimed") < order_of(names, "round_start")
    assert order_of(names, "round_start") < order_of(names, "llm_request")
    assert order_of(names, "llm_request") < order_of(names, "llm_response")
    assert order_of(names, "llm_response") < order_of(names, "tool_start")
    assert "tool_end" in names
    assert order_of(names, "tool_start") < order_of(names, "tool_end")

    # server_absorb / absorb_delivery retired with the staged protocol (§3.4):
    # the delivery's durable record is the session commit carrying a
    # "delivery" event, asserted below.

    # Two LLM turns (business tool + explicit terminal), both with
    # request/response pairs.
    assert Enum.count(names, &(&1 == "llm_request")) == 2
    responses = Enum.filter(mine, &(&1["event"] == "llm_response"))
    assert Enum.map(responses, & &1["kind"]) == ["assistant", "assistant"]
    [assistant_resp, terminal_resp] = responses
    assert [%{"name" => "call"}] = assistant_resp["tool_calls"]
    assert terminal_resp["content"] == "done"
    assert [%{"name" => "end_turn"}] = terminal_resp["tool_calls"]

    # The tool execution carries args, result content and timing.
    tool_end = Enum.find(mine, &(&1["event"] == "tool_end"))
    assert tool_end["tool"] == "help"
    assert tool_end["tool_call_id"] == "t1"
    assert Jason.decode!(tool_end["content"])["name"] == "fs.read_file"
    assert tool_end["error"] == false
    assert is_integer(tool_end["duration_ms"])

    # Every journal commit is logged with its event types.
    commits = Enum.filter(mine, &(&1["event"] == "store_commit"))
    assert Enum.all?(commits, &(&1["result"] == "ok"))

    assert Enum.any?(commits, fn commit ->
             types = commit["event_types"] || []
             "assistant" in types and "activity_status" in types
           end)

    # Zero-wait dispatch commits the early tool result together with its
    # async ownership boundary. The commit may therefore carry lifecycle and
    # wait events beside the tool result; it must still include that result.
    assert Enum.any?(commits, &("tool_result" in &1["event_types"]))

    assert Enum.any?(commits, &("delivery" in &1["event_types"]))
  end

  test "store_create and store_claim are logged for a new agent", %{agent: a, path: path} do
    SalixAgent.TestSupport.create_control_agent!(a)
    {:ok, _pid} = Fleet.ensure_started(a, create: false)
    _ = Server.info(a)

    mine = Enum.filter(events(path), &(&1["agent_id"] == a))
    assert Enum.any?(mine, &(&1["event"] == "store_create" and &1["result"] == "ok"))
    assert Enum.any?(mine, &(&1["event"] == "server_claimed"))
  end

  defp internal_sessions_settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(sessions, &(InternalSession.derived_state(&1) not in [:queued, :active]))

      {:error, _} ->
        false
    end
  end

  defp read_session!(agent) do
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent, @session_id)
    session
  end

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp order_of(names, name) do
    case Enum.find_index(names, &(&1 == name)) do
      nil -> flunk("expected event #{name}, got: #{inspect(names)}")
      idx -> idx
    end
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
