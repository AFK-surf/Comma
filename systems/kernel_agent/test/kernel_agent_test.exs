defmodule KernelAgentTest do
  use ExUnit.Case, async: false

  alias KernelAgent.LLM.Script
  alias KernelAgent.Session

  @send "im_api.internal.send_message"

  setup context do
    root = Path.join(System.tmp_dir!(), "kernel_agent_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, llm} = Script.start_link(context[:script] || [])
    %{root: root, llm: llm}
  end

  defp start(%{root: root, llm: llm}, opts \\ []) do
    start_supervised!({Session, [root: root, llm: {:script, llm}] ++ opts}, id: make_ref())
  end

  defp reply_params(conversation, text),
    do: %{
      "connect_id" => "internal",
      "conversation_id" => conversation,
      "content" => [%{"type" => "text", "text" => text}]
    }

  # The conversation named in the newest user message's header.
  defp current_conversation(messages) do
    %{content: content} = messages |> Enum.filter(&(&1[:role] == "user")) |> List.last()
    [_, conversation] = Regex.run(~r/^\[conversation ([^\]]+)\]/, content)
    conversation
  end

  # A model that answers the current conversation in one response.
  defp echo do
    fn messages ->
      conversation = current_conversation(messages)

      Script.end_turn(%{
        "tool" => @send,
        "params" => reply_params(conversation, "hi #{conversation}")
      })
    end
  end

  defp status(agent), do: SalixVerifiedKernel.Session.get(Session.state(agent), :status)
  defp field(agent, name), do: SalixVerifiedKernel.Session.get(Session.state(agent), name)

  test "a reply in end_turn is sent to the source and settles the turn in one model call", ctx do
    Script.push(ctx.llm, [echo()])
    agent = start(ctx)

    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 1
    assert status(agent) == :idle
    assert field(agent, :last_ack_message_id) == field(agent, :next_message_id) - 1
  end

  test "each conversation gets its own reply from the one session", ctx do
    Script.push(ctx.llm, [echo(), echo()])
    agent = start(ctx)

    assert :committed = KernelAgent.send(agent, "alice", "hello")
    assert :committed = KernelAgent.send(agent, "bob", "hello")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert [%{"text" => "hi bob"}] = KernelAgent.messages(ctx.root, "bob")
    assert length(Script.requests(ctx.llm)) == 2
  end

  test "a reply to another conversation is refused and the turn stays open", ctx do
    Script.push(ctx.llm, [
      Script.end_turn(%{"tool" => @send, "params" => reply_params("bob", "wrong place")}),
      echo()
    ])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert KernelAgent.messages(ctx.root, "bob") == []
    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 2
  end

  test "tool rounds run until the model ends the turn", ctx do
    Script.push(ctx.llm, [
      Script.call("fs.write", %{"path" => "notes/a.txt", "content" => "remember"}),
      Script.call("fs.read", %{"path" => "notes/a.txt"}),
      fn messages ->
        assert %{content: "remember"} =
                 messages |> Enum.filter(&(&1[:role] == "tool")) |> List.last()

        Script.end_turn(%{"tool" => @send, "params" => reply_params("alice", "saved")})
      end
    ])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "save a note")
    :ok = Session.await_idle(agent)

    assert File.read!(Path.join([ctx.root, "workspace", "notes", "a.txt"])) == "remember"
    assert [%{"text" => "saved"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 3
  end

  test "a duplicate source message is admitted once", ctx do
    Script.push(ctx.llm, [echo()])
    agent = start(ctx)

    assert :committed = KernelAgent.send(agent, "alice", "hello", source_message_id: "m1")
    assert :duplicate = KernelAgent.send(agent, "alice", "hello", source_message_id: "m1")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
  end

  test "a session killed during a model round recovers on restart", ctx do
    # The session dies while its first model call is in flight.
    test = self()
    Script.push(ctx.llm, [fn _ -> send(test, :in_round) && Process.sleep(:infinity) end, echo()])
    Process.flag(:trap_exit, true)
    {:ok, agent} = Session.start_link(root: ctx.root, llm: {:script, ctx.llm})

    assert :committed = KernelAgent.send(agent, "alice", "hello")
    assert_receive :in_round, 5_000
    Process.exit(agent, :kill)
    assert_receive {:EXIT, ^agent, :killed}, 5_000

    agent = start(ctx)
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert status(agent) == :idle
  end

  test "a session killed during a tool call repairs the call on restart", ctx do
    # The tool reads a FIFO, so it blocks until the test writes to it.
    workspace = Path.join(ctx.root, "workspace")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("mkfifo", [Path.join(workspace, "pipe")])

    Script.push(ctx.llm, [
      Script.call("fs.read", %{"path" => "pipe"}),
      fn messages ->
        assert Enum.any?(messages, &(&1[:role] == "tool" and &1.content =~ "did not complete"))
        echo().(messages)
      end
    ])

    Process.flag(:trap_exit, true)
    {:ok, agent} = Session.start_link(root: ctx.root, llm: {:script, ctx.llm})
    assert :committed = KernelAgent.send(agent, "alice", "read the pipe")

    # The file server holds the read, so the unblocking write must not use it.
    # Opening the FIFO read-write never blocks.
    server = Process.whereis(:file_server_2)

    wait_until(fn ->
      Process.info(server, :current_function) ==
        {:current_function, {:prim_file, :read_file_nif, 1}}
    end)

    Process.exit(agent, :kill)
    assert_receive {:EXIT, ^agent, :killed}, 5_000
    :os.cmd(~c"echo late 1<> '#{Path.join(workspace, "pipe")}'")

    agent = start(ctx)
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert status(agent) == :idle
  end

  defp wait_until(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  test "a retryable model failure retries and then answers", ctx do
    {:error, meta} =
      SalixVerifiedKernel.Provider.call(
        :http_error,
        {"anthropic", 529, ~s({"error":{"message":"overloaded"}})}
      )

    Script.push(ctx.llm, [{:error, meta}, echo()])
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 10)
    on_exit(fn -> Application.delete_env(:salix_agent, :llm_activation_retry_base_ms) end)

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")

    assert eventually(fn -> KernelAgent.messages(ctx.root, "alice") != [] end)
    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 2
  end

  test "input from another conversation arrives while a model call runs", ctx do
    test = self()
    {:ok, gate} = Agent.start_link(fn -> nil end)

    slow = fn messages ->
      send(test, :in_round)
      wait_open(gate)
      echo().(messages)
    end

    Script.push(ctx.llm, [slow, echo(), echo()])
    agent = start(ctx)

    assert :committed = KernelAgent.send(agent, "alice", "hello")
    assert_receive :in_round, 5_000
    # The session admits bob's input while alice's model call is in flight.
    assert :committed = KernelAgent.send(agent, "bob", "hello")
    Agent.update(gate, fn _ -> :open end)
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert [%{"text" => "hi bob"}] = KernelAgent.messages(ctx.root, "bob")
    # Alice's response stays current: queued input is not yet in the transcript.
    assert Enum.map(Script.requests(ctx.llm), &current_conversation/1) == ["alice", "bob"]
  end

  test "a standalone send does not end the turn; end_turn without reply does", ctx do
    Script.push(ctx.llm, [
      Script.call(@send, reply_params("alice", "working on it")),
      Script.end_turn()
    ])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "working on it"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 2
    assert field(agent, :last_ack_message_id) == field(agent, :next_message_id) - 1
  end

  test "plain final text is not a reply; the kernel asks for a decision", ctx do
    Script.push(ctx.llm, [{:final, "hi alice"}, echo()])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert length(Script.requests(ctx.llm)) == 2
  end

  test "the round budget parks the session and sends one failure notice", ctx do
    Application.put_env(:salix_agent, :input_round_cap, 3)
    on_exit(fn -> Application.delete_env(:salix_agent, :input_round_cap) end)
    busy = for n <- 1..10, do: Script.call("fs.list", %{"path" => ".", "n" => n})
    Script.push(ctx.llm, busy)

    agent = start(ctx)
    File.mkdir_p!(Path.join(ctx.root, "workspace"))
    assert :committed = KernelAgent.send(agent, "alice", "loop forever")
    :ok = Session.await_idle(agent)

    assert length(Script.requests(ctx.llm)) == 3
    assert [%{"text" => notice}] = KernelAgent.messages(ctx.root, "alice")
    assert notice =~ "couldn't complete this request"
    assert status(agent) == :idle
  end

  test "the HTTP provider path: kernel-encoded request, kernel-parsed response", ctx do
    reply = %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-test",
      "stop_reason" => "tool_use",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "end_turn",
          "input" => %{
            "outcome" => "done",
            "reply" => %{"tool" => @send, "params" => reply_params("alice", "hi over http")}
          }
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    {port, _server} = KernelAgent.FakeProvider.start([{200, JSON.encode!(reply)}])

    llm =
      {:http,
       %{
         "protocol" => "anthropic",
         "model" => "claude-test",
         "base_url" => "http://127.0.0.1:#{port}",
         "api_key" => "test-key",
         "max_tokens" => 256
       }}

    agent = start_supervised!({Session, root: ctx.root, llm: llm}, id: make_ref())
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert_received {:provider_request, headers, body}
    assert headers["x-api-key"] == "test-key"
    request = JSON.decode!(body)
    assert request["model"] == "claude-test"
    assert Enum.map(request["tools"], & &1["name"]) == ["call", "end_turn"]

    assert [%{"role" => "user", "content" => [%{"text" => "[conversation alice] hello"}]} | _] =
             request["messages"]

    assert [%{"text" => "hi over http"}] = KernelAgent.messages(ctx.root, "alice")
  end

  test "an HTTP provider error is classified by the kernel and retried", ctx do
    ok = %{
      "id" => "msg_2",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-test",
      "stop_reason" => "tool_use",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_2",
          "name" => "end_turn",
          "input" => %{
            "outcome" => "done",
            "reply" => %{"tool" => @send, "params" => reply_params("alice", "recovered")}
          }
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    {port, _server} =
      KernelAgent.FakeProvider.start([
        {529, ~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})},
        {200, JSON.encode!(ok)}
      ])

    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 10)
    on_exit(fn -> Application.delete_env(:salix_agent, :llm_activation_retry_base_ms) end)

    llm =
      {:http,
       %{
         "protocol" => "anthropic",
         "model" => "claude-test",
         "base_url" => "http://127.0.0.1:#{port}",
         "api_key" => "k"
       }}

    agent = start_supervised!({Session, root: ctx.root, llm: llm}, id: make_ref())
    assert :committed = KernelAgent.send(agent, "alice", "hello")

    assert eventually(fn -> KernelAgent.messages(ctx.root, "alice") != [] end)
    assert [%{"text" => "recovered"}] = KernelAgent.messages(ctx.root, "alice")
  end

  defp overflow do
    {:error, overflow} =
      SalixVerifiedKernel.Provider.call(
        :http_error,
        {"anthropic", 400, ~s({"error":{"message":"prompt is too long"}})}
      )

    {:error, overflow}
  end

  defp summary(text), do: {:final, "<compaction-summary>#{text}</compaction-summary>"}

  defp user_texts(request),
    do: for(%{role: "user", content: content} <- request, do: content)

  # A turn that ends with a reply and reports its prompt size.
  defp echo_with_usage(tokens) do
    fn messages ->
      {:assistant, text, calls} = echo().(messages)
      {:assistant, text, calls, nil, %{"usage" => %{"input_tokens" => tokens}}}
    end
  end

  # The kernel asks for compaction when the observed prompt passes 0.9 of the
  # window. The summary replaces the earlier turn, and the new input stays
  # verbatim.
  test "a prompt near the context window compacts before the next round", ctx do
    Script.push(ctx.llm, [
      echo_with_usage(9_500),
      summary("alice said hello and got a reply"),
      echo()
    ])

    agent = start(ctx, context_tokens: 10_000)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)
    assert :committed = KernelAgent.send(agent, "alice", "again")
    :ok = Session.await_idle(agent)

    [_first, compaction, round] = Script.requests(ctx.llm)
    assert List.last(user_texts(compaction)) =~ "<compaction-summary>"
    assert field(agent, :summary) =~ "alice said hello and got a reply"
    assert Enum.any?(round, &(&1[:role] == "summary"))
    assert user_texts(round) == ["[conversation alice] again"]
    assert [_, %{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
  end

  # Each response records the compaction generation of its request, so usage
  # after a summary triggers the next compaction.
  test "automatic compaction runs again after the first summary", ctx do
    Script.push(ctx.llm, [
      echo_with_usage(9_500),
      summary("first"),
      echo_with_usage(9_500),
      summary("second"),
      echo_with_usage(9_500)
    ])

    agent = start(ctx, context_tokens: 10_000)

    for text <- ["one", "two", "three"] do
      assert :committed = KernelAgent.send(agent, "alice", text)
      :ok = Session.await_idle(agent)
    end

    assert length(Script.requests(ctx.llm)) == 5
    assert field(agent, :summary_sequence) == 2
    assert field(agent, :summary) =~ "second"
    assert length(KernelAgent.messages(ctx.root, "alice")) == 3
  end

  # After an overflow the kernel asks for one recovery. The session compacts
  # the finished history, and the next request fits.
  test "a context overflow compacts the session and the request runs again", ctx do
    Script.push(ctx.llm, [echo(), overflow(), summary("an earlier greeting"), echo()])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)
    assert :committed = KernelAgent.send(agent, "alice", "again")
    :ok = Session.await_idle(agent)

    assert length(Script.requests(ctx.llm)) == 4
    assert field(agent, :summary) =~ "an earlier greeting"
    assert [_, %{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
    assert status(agent) == :idle
  end

  # A summary without its tags is an invalid answer. The kernel does not
  # retry it: it writes the recovery summary, which points to the raw
  # transcript, and the round runs.
  test "a summary without tags is replaced by the recovery summary", ctx do
    Script.push(ctx.llm, [echo_with_usage(9_500), {:final, "no tags here"}, echo()])

    agent = start(ctx, context_tokens: 10_000)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)
    assert :committed = KernelAgent.send(agent, "alice", "again")
    :ok = Session.await_idle(agent)

    assert field(agent, :summary) =~ "System recovery summary"
    assert field(agent, :summary) =~ "Failure category: invalid_compaction_summary."
    assert [_, %{"text" => "hi alice"}] = KernelAgent.messages(ctx.root, "alice")
  end

  # Over HTTP the kernel encodes the compaction request for the provider:
  # the same system prompt and tools as a round, and the instruction last.
  test "compaction over the HTTP provider path", ctx do
    turn = fn id, text, tokens ->
      %{
        "id" => id,
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-test",
        "stop_reason" => "tool_use",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_" <> id,
            "name" => "end_turn",
            "input" => %{
              "outcome" => "done",
              "reply" => %{"tool" => @send, "params" => reply_params("alice", text)}
            }
          }
        ],
        "usage" => %{"input_tokens" => tokens, "output_tokens" => 5}
      }
    end

    summary = %{
      "id" => "msg_s",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-test",
      "stop_reason" => "end_turn",
      "content" => [
        %{"type" => "text", "text" => "<compaction-summary>a greeting</compaction-summary>"}
      ],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
    }

    {port, _server} =
      KernelAgent.FakeProvider.start([
        {200, JSON.encode!(turn.("1", "first", 9_500))},
        {200, JSON.encode!(summary)},
        {200, JSON.encode!(turn.("2", "second", 30))}
      ])

    llm =
      {:http,
       %{
         "protocol" => "anthropic",
         "model" => "claude-test",
         "base_url" => "http://127.0.0.1:#{port}",
         "api_key" => "test-key",
         "max_tokens" => 256
       }}

    agent =
      start_supervised!({Session, root: ctx.root, llm: llm, context_tokens: 10_000},
        id: make_ref()
      )

    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)
    assert :committed = KernelAgent.send(agent, "alice", "again")
    :ok = Session.await_idle(agent)

    assert_received {:provider_request, _headers, _first}
    assert_received {:provider_request, _headers, compaction}
    compaction = JSON.decode!(compaction)
    assert Enum.map(compaction["tools"], & &1["name"]) == ["call", "end_turn"]
    assert compaction["system"] != nil
    %{"role" => "user", "content" => content} = List.last(compaction["messages"])
    assert inspect(content) =~ "<compaction-summary>"

    assert field(agent, :summary) =~ "a greeting"
    assert [_, %{"text" => "second"}] = KernelAgent.messages(ctx.root, "alice")
  end

  # Fresh input is never summarized. When nothing else can be compacted, the
  # recovery makes no progress, and the kernel ends the request with a
  # model-failure notice instead of sending the same request again.
  test "an overflow that compaction cannot reduce ends the request", ctx do
    Script.push(ctx.llm, List.duplicate(overflow(), 10))

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert length(Script.requests(ctx.llm)) == 1
    assert status(agent) == :idle
    assert [%{"text" => notice}] = KernelAgent.messages(ctx.root, "alice")
    assert notice =~ "model service could not continue"
  end

  test "a failed tool operation is a tool result, not a runtime crash", ctx do
    Script.push(ctx.llm, [
      Script.call("fs.write", %{"path" => ".", "content" => "x"}),
      fn messages ->
        assert %{status: "error"} = messages |> Enum.filter(&(&1[:role] == "tool")) |> List.last()
        Script.end_turn(%{"tool" => @send, "params" => reply_params("alice", "could not write")})
      end
    ])

    agent = start(ctx)
    File.mkdir_p!(Path.join(ctx.root, "workspace"))
    assert :committed = KernelAgent.send(agent, "alice", "write the workspace root")
    :ok = Session.await_idle(agent)

    assert [%{"text" => "could not write"}] = KernelAgent.messages(ctx.root, "alice")
  end

  # A workspace link to an outside file is not followed: the read does not
  # reach the model, and the write does not change the file.
  test "fs operations do not follow a symbolic link out of the workspace", ctx do
    outside = Path.join(ctx.root, "outside.txt")
    workspace = Path.join(ctx.root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(workspace, "link"))
    File.mkdir_p!(Path.join(ctx.root, "outside_dir"))
    File.ln_s!(Path.join(ctx.root, "outside_dir"), Path.join(workspace, "dir"))

    Script.push(ctx.llm, [
      Script.call("fs.read", %{"path" => "link"}),
      Script.call("fs.write", %{"path" => "dir/new.txt", "content" => "x"}),
      Script.end_turn(%{"tool" => @send, "params" => reply_params("alice", "refused")})
    ])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "read the link")
    :ok = Session.await_idle(agent)

    # The model sees each result as an error, and never the outside content.
    [_, after_read, after_write] = Script.requests(ctx.llm)
    last_tool = fn request -> request |> Enum.filter(&(&1[:role] == "tool")) |> List.last() end
    assert %{status: "error", tool_name: "fs.read"} = last_tool.(after_read)
    assert %{status: "error", tool_name: "fs.write"} = last_tool.(after_write)
    refute inspect(Script.requests(ctx.llm)) =~ "secret"

    errors = for %{role: "tool", content: c} <- field(agent, :messages), do: c
    assert Enum.count(errors, &(&1 =~ "path crosses a symbolic link")) == 2
    assert File.read!(outside) == "secret"
    refute File.exists?(Path.join([ctx.root, "outside_dir", "new.txt"]))
    assert [%{"text" => "refused"}] = KernelAgent.messages(ctx.root, "alice")
  end

  # A crashed model call is lost, as in production: the kernel records the
  # failure at the round's transcript position, and the session idles
  # instead of sending the same request again. The next input processes the
  # session again: the failed turn runs first, then the new input.
  @tag :capture_log
  test "a crashed model call is recorded, and the next input runs again", ctx do
    Script.push(ctx.llm, [fn _ -> raise "provider client crashed" end, echo(), echo()])

    agent = start(ctx)
    assert :committed = KernelAgent.send(agent, "alice", "hello")
    :ok = Session.await_idle(agent)

    assert KernelAgent.messages(ctx.root, "alice") == []
    assert length(Script.requests(ctx.llm)) == 1
    assert status(agent) == :idle
    assert Enum.any?(field(agent, :events), &(&1["kind"] == "llm_call_failed"))

    assert :committed = KernelAgent.send(agent, "alice", "again")
    :ok = Session.await_idle(agent)

    assert [_crashed, retried, next] = Script.requests(ctx.llm)
    assert user_texts(retried) == ["[conversation alice] hello"]
    assert List.last(user_texts(next)) == "[conversation alice] again"

    assert [%{"text" => "hi alice"}, %{"text" => "hi alice"}] =
             KernelAgent.messages(ctx.root, "alice")
  end

  defp wait_open(gate) do
    if Agent.get(gate, & &1) == :open, do: :ok, else: Process.sleep(5) && wait_open(gate)
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end
end
