defmodule SalixAgent.RoundStreamingTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Token deltas fan out via `SalixAgent.Notifier` while a round runs: the Round
  calls `LLM.complete_stream/3` with an `on_delta` that
  emits `{:delta, session_id, text}` per chunk, in order. Streaming is a pure
  side channel — the persisted transcript semantics must match the
  non-streaming path across either supported zero-wait terminal encoding, and
  impls without `complete_stream/3` fall back to `complete/2` with no deltas.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{Server, Fleet, LLM}
  alias SalixAgent.LLM.Mock

  @pid_key {__MODULE__, :test_pid}
  @session_id "ses1_0000000000000000501"

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case SystemsRuntime.PersistentTerm.get({SalixAgent.RoundStreamingTest, :test_pid}, nil) do
        nil ->
          :ok

        pid ->
          SystemsRuntime.Proc.send(pid, {:delta_seen, agent_id, event})

          case event do
            {:activity,
             %{
               "phase" => "execution",
               "status" => "running",
               "session_id" => session_id,
               "tool_call_id" => call_id
             }} ->
              {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)

              SystemsRuntime.Proc.send(
                pid,
                {:durable_tool_admission, agent_id, call_id,
                 SalixAgent.InternalSession.export(session)}
              )

            _ ->
              :ok
          end
      end

      :ok
    end
  end

  defmodule BaselineLLM do
    @moduledoc false
    # Only `complete/2` — no `complete_stream/3` exported. Used both as the
    # non-streaming transcript baseline and to exercise the dispatch fallback.
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: SalixAgent.LLM.Mock.complete(messages, tools)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :notifier, TestNotifier)
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :notifier, prev_notifier)
      restore(:salix_agent, :llm, prev_llm)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, val), do: SystemsRuntime.put_env(app, key, val)

  defp wake_and_settle(agent, expected_final) do
    Server.wake(agent)
    result = Server.info(agent)

    assert eventually(
             fn ->
               internal_sessions_settled?(agent) and
                 Enum.any?(
                   read_session!(agent, @session_id).messages,
                   &(&1.role == "assistant" and &1.content == expected_final)
                 )
             end,
             3000
           )

    result
  end

  defp internal_sessions_settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _} ->
        false
    end
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  # Drain the delta notifications for `agent` already in the mailbox (deltas are
  # sent synchronously during the round, which completed before settle returned).
  # Other Notifier events (e.g. `{:settled, _}` from the Server) are discarded.
  defp collect_deltas(agent) do
    SystemsRuntime.Proc.receive do
      {:delta_seen, ^agent, {:delta, sid, text}} -> [{sid, text} | collect_deltas(agent)]
      {:delta_seen, ^agent, _other} -> collect_deltas(agent)
    after
      0 -> []
    end
  end

  test "deltas arrive in order and concatenate to the final assistant content", %{agent: a} do
    Mock.script([{:final, "hello back, streamed"}])
    {:ok, _pid} = Fleet.ensure_started(a, create: true)

    {:ok, :created} = deliver(a, "u1", %{content: "hi", session_id: @session_id})
    {:parked, _owned} = wake_and_settle(a, "hello back, streamed")

    deltas = collect_deltas(a)
    assert length(deltas) in 2..3
    assert Enum.all?(deltas, &match?({@session_id, _}, &1))

    texts = Enum.map(deltas, fn {@session_id, text} -> text end)
    assert Enum.join(texts) == "hello back, streamed"

    # Streaming preserves the user/assistant turns and adopts complete context notices.
    session = read_session!(a, @session_id)

    assert Enum.any?(
             session.messages,
             &(&1[:type] == "time_context" and &1[:content_kind] == "model_context")
           )

    assert Enum.map(conversation_turns(session.messages), & &1.role) == ["user", "assistant"]
    assert List.last(session.messages).content == "hello back, streamed"
    assert session.status == :idle
  end

  defp conversation_turns(messages),
    do: Enum.reject(messages, &(&1[:content_kind] == "model_context"))

  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)
    session
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
