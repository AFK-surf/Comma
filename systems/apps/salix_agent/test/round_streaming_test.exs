defmodule SalixAgent.RoundStreamingTest do
  @moduledoc """
  Token deltas fan out via `SalixAgent.Notifier` while a round runs: the Round
  calls `LLM.complete_stream/3` with an `on_delta` that
  emits `{:delta, session_id, text}` per chunk, in order. Streaming is a pure
  side channel — the persisted transcript semantics must match the
  non-streaming path across either supported zero-wait terminal encoding, and
  impls without `complete_stream/3` fall back to `complete/2` with no deltas.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Server, Fleet, LLM}
  alias SalixAgent.LLM.Mock

  @pid_key {__MODULE__, :test_pid}
  @session_id "ses1_0000000000000000501"

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case :persistent_term.get({SalixAgent.RoundStreamingTest, :test_pid}, nil) do
        nil ->
          :ok

        pid ->
          send(pid, {:delta_seen, agent_id, event})

          case event do
            {:activity,
             %{
               "phase" => "execution",
               "status" => "running",
               "session_id" => session_id,
               "tool_call_id" => call_id
             }} ->
              {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)

              send(
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
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_notifier = Application.get_env(:salix_agent, :notifier)
    prev_llm = Application.get_env(:salix_agent, :llm)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :notifier, TestNotifier)
    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase(@pid_key)
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :notifier, prev_notifier)
      restore(:salix_agent, :llm, prev_llm)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

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
             200
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

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  # Drain the delta notifications for `agent` already in the mailbox (deltas are
  # sent synchronously during the round, which completed before settle returned).
  # Other Notifier events (e.g. `{:settled, _}` from the Server) are discarded.
  defp collect_deltas(agent) do
    receive do
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

  test "deltas fire per assistant turn across a tool round, in order", %{agent: a} do
    Mock.script([
      {:assistant, "let me use tools",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "all done now"}
    ])

    {:ok, _pid} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, "u1", %{content: "do work", session_id: @session_id})

    {:parked, _owned} = wake_and_settle(a, "all done now")

    texts = a |> collect_deltas() |> Enum.map(fn {@session_id, text} -> text end)
    # Both turns streamed, in order: turn-1 chunks then turn-2 chunks.
    assert Enum.join(texts) == "let me use tools" <> "all done now"
    assert length(texts) >= 4

    msgs = read_session!(a, @session_id).messages
    assert_completed_tool_round!(msgs, "t1")
    assert List.last(msgs).content == "all done now"

    # Before the dependency starts, the same intent CAS already holds the
    # assistant, model-facing running result and restart recovery record.
    assert_receive {:durable_tool_admission, ^a, "t1", admitted}
    assert admitted.async_tool_calls["t1"]["status"] == "running"

    assert Enum.any?(
             admitted.messages,
             &(&1[:role] == "tool" and &1[:tool_call_id] == "t1" and
                 &1[:status] == "async_running")
           )

    assert admitted.wait != nil
  end

  test "persisted transcript semantics match the non-streaming baseline", %{agent: a} do
    script = [
      {:assistant, "thinking out loud",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "the answer"}
    ]

    # Streaming run (Mock exports complete_stream/3).
    Mock.script(script)
    {:ok, _} = Fleet.ensure_started(a, create: true)
    {:ok, :created} = deliver(a, "u1", %{content: "go", session_id: @session_id})
    {:parked, _streamed} = wake_and_settle(a, "the answer")
    assert collect_deltas(a) != []

    # Baseline run on a fresh agent: same script, impl without complete_stream.
    Application.put_env(:salix_agent, :llm, BaselineLLM)
    Mock.script(script)
    b = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(b)
    {:ok, _} = Fleet.ensure_started(b, create: true)
    {:ok, :created} = deliver(b, "u1", %{content: "go", session_id: @session_id})
    {:parked, _baseline} = wake_and_settle(b, "the answer")

    # Fallback path: no deltas fired for the baseline agent.
    assert collect_deltas(b) == []

    streaming_messages = read_session!(a, @session_id).messages
    baseline_messages = read_session!(b, @session_id).messages

    assert_completed_tool_round!(streaming_messages, "t1")
    assert_completed_tool_round!(baseline_messages, "t1")

    # Streaming is a pure side channel. A zero-wait tool may already have
    # completed at yield(0), or it may persist async_running plus the exact
    # runtime terminal. Compare the full terminal semantics after canonicalizing
    # only those two supported storage encodings and per-run correlation fields.
    assert normalize_runtime_fields(streaming_messages) ==
             normalize_runtime_fields(baseline_messages)
  end

  test "dispatch falls back to complete/2 when the impl exports no complete_stream/3" do
    Application.put_env(:salix_agent, :llm, BaselineLLM)
    Mock.script([{:raw, {:final, "fallback reply"}}])

    me = self()

    result =
      LLM.complete_stream([%{role: "user", content: "hi"}], [], fn t ->
        send(me, {:unexpected_delta, t})
      end)

    assert result == {:final, "fallback reply"}
    refute_received {:unexpected_delta, _}
  end

  defp normalize_runtime_fields(messages) do
    terminal_results =
      Enum.reduce(messages, %{}, fn msg, results ->
        with "runtime" <- msg[:role],
             type when type in ["tool_call_completed", "tool_call_failed"] <- msg[:type],
             tool_call_id when is_binary(tool_call_id) <- msg[:source_tool_call_id],
             content when is_binary(content) <- msg[:content],
             {:ok, %{"result" => %{} = result}} <- Jason.decode(content) do
          Map.put(results, tool_call_id, result)
        else
          _ -> results
        end
      end)

    messages
    |> conversation_turns()
    |> Enum.reject(fn msg ->
      msg[:role] == "runtime" and Map.has_key?(terminal_results, msg[:source_tool_call_id])
    end)
    |> Enum.map(fn
      %{role: "tool", tool_call_id: tool_call_id} = msg ->
        terminal = Map.get(terminal_results, tool_call_id, msg)
        content = map_value(terminal, "content", :content) || msg[:content]
        output = map_value(terminal, "output", :output)

        %{
          role: "tool",
          tool_call_id: tool_call_id,
          tool_name: map_value(terminal, "name", :tool_name) || msg[:tool_name],
          input: map_value(terminal, "input", :input) || msg[:input],
          content: content,
          output: if(output == content, do: nil, else: output),
          status: map_value(terminal, "status", :status),
          error: map_value(terminal, "error", :error) == true,
          error_class: map_value(terminal, "error_class", :error_class),
          error_message: map_value(terminal, "error_message", :error_message),
          guidance_reason: map_value(terminal, "guidance_reason", :guidance_reason),
          diagnostic_visibility:
            map_value(terminal, "diagnostic_visibility", :diagnostic_visibility) ||
              msg[:diagnostic_visibility],
          public_summary: map_value(terminal, "public_summary", :public_summary),
          repair_outcome: map_value(terminal, "repair_outcome", :repair_outcome),
          visible_reply_origin: map_value(terminal, "visible_reply_origin", :visible_reply_origin)
        }

      msg ->
        # Accepted input retains its own copy of delivery timing. Preserve the
        # durable sequence, identity and payload; only receipt timing varies
        # between these otherwise equivalent runs.
        msg = normalize_accepted_input_timing(msg)

        msg =
          Map.drop(msg, [
            :id,
            :seq,
            :result_seq,
            :turn_id,
            :round_id,
            :request_id,
            :trace_id,
            :created_at,
            :delivered_at_ms,
            :input_time,
            :started_at,
            :completed_at,
            :duration_ms,
            :execution_timing,
            :request_input_through,
            :request_summary_sequence,
            :request_compacted_through,
            :do_not_send_to_llm,
            "do_not_send_to_llm"
          ])

        # Zero-wait terminal notifications carry the completed result as JSON,
        # including the same per-run timing fields that legacy synchronous tool
        # messages stored at the top level. Normalize those nested stamps too;
        # all semantic result bytes remain part of the equality assertion.
        if msg[:role] == "runtime" and is_binary(msg[:content]) do
          Map.update!(msg, :content, &normalize_runtime_json/1)
        else
          msg
        end
    end)
  end

  defp normalize_accepted_input_timing(%{accepted_input: {seq, kind, source_id, payload}} = msg) do
    payload = Map.delete(payload, "delivered_at_ms")

    payload =
      case payload do
        %{"input_time" => %{} = input_time} ->
          Map.put(payload, "input_time", Map.delete(input_time, "received_at"))

        _ ->
          payload
      end

    %{msg | accepted_input: {seq, kind, source_id, payload}}
  end

  defp normalize_accepted_input_timing(msg), do: msg

  defp conversation_turns(messages),
    do: Enum.reject(messages, &(&1[:content_kind] == "model_context"))

  defp assert_completed_tool_round!(messages, tool_call_id) do
    messages = conversation_turns(messages)

    tool =
      Enum.find(messages, fn msg ->
        msg[:role] == "tool" and msg[:tool_call_id] == tool_call_id
      end)

    assert tool != nil

    runtime =
      Enum.find(messages, fn msg ->
        msg[:role] == "runtime" and msg[:source_tool_call_id] == tool_call_id
      end)

    case runtime do
      nil ->
        assert Enum.map(messages, & &1.role) == ["user", "assistant", "tool", "assistant"]
        assert tool.status == "completed"

      runtime ->
        assert Enum.map(messages, & &1.role) == [
                 "user",
                 "assistant",
                 "tool",
                 "runtime",
                 "assistant"
               ]

        assert tool.status == "async_running"
        assert runtime.type == "tool_call_completed"

        tool_name = tool.tool_name
        assert {:ok, payload} = Jason.decode(runtime.content)

        assert %{
                 "type" => "tool_call_completed",
                 "status" => "completed",
                 "tool_call_id" => ^tool_call_id,
                 "tool_name" => ^tool_name,
                 "error" => false,
                 "source_refs" => %{
                   "tool_call_id" => ^tool_call_id,
                   "tool_name" => ^tool_name,
                   "status" => "completed"
                 },
                 "result" => %{
                   "id" => ^tool_call_id,
                   "name" => ^tool_name,
                   "status" => "completed",
                   "error" => false
                 }
               } = payload
    end
  end

  defp map_value(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp normalize_runtime_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> decoded |> drop_runtime_json_fields() |> Jason.encode!()
      {:error, _reason} -> content
    end
  end

  defp drop_runtime_json_fields(%{} = value) do
    value
    |> Map.drop(["started_at", "completed_at", "duration_ms", "execution_timing"])
    |> Map.new(fn {key, nested} -> {key, drop_runtime_json_fields(nested)} end)
  end

  defp drop_runtime_json_fields(value) when is_list(value),
    do: Enum.map(value, &drop_runtime_json_fields/1)

  defp drop_runtime_json_fields(value), do: value

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
