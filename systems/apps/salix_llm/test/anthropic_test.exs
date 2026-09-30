defmodule SalixLlm.AnthropicTest do
  @moduledoc """
  The Anthropic client: message conversion, response parsing,
  SSE-stream decoding, and `complete/2` against a mock Messages API server.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.{Convert, Stream, Anthropic}

  defmodule TransientAnthropic do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, raw_body, conn} = read_body(conn)
      send(test_pid, {:anthropic_request, raw_body})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "temporary"}}))
    end
  end

  describe "Convert.to_anthropic/1" do
    test "maps user, assistant+tool_calls, tool, and summary messages" do
      messages = [
        %{role: "summary", content: "earlier context"},
        %{role: "user", content: "hello"},
        %{
          role: "assistant",
          content: "calling",
          tool_calls: [%{"id" => "t1", "name" => "echo", "args" => %{"text" => "hi"}}]
        },
        %{role: "tool", tool_call_id: "t1", content: "hi"}
      ]

      {system, msgs} = Convert.to_anthropic(messages)
      assert system == "earlier context"
      assert [user, assistant, tool] = msgs
      assert user == %{"role" => "user", "content" => "hello"}

      assert %{"role" => "assistant", "content" => blocks} = assistant
      assert Enum.any?(blocks, &(&1["type"] == "text"))
      tu = Enum.find(blocks, &(&1["type"] == "tool_use"))
      assert tu["id"] == "t1" and tu["name"] == "echo" and tu["input"] == %{"text" => "hi"}

      assert %{
               "role" => "user",
               "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "hi"}]
             } = tool
    end
  end

  describe "Convert.parse_response/1" do
    test "text-only response → :final" do
      resp = %{
        "content" => [%{"type" => "text", "text" => "the answer"}],
        "stop_reason" => "end_turn"
      }

      assert {:final, "the answer"} = Convert.parse_response(resp)
    end

    test "tool_use response → :assistant with tool calls" do
      resp = %{
        "content" => [
          %{"type" => "text", "text" => "let me check"},
          %{"type" => "tool_use", "id" => "t9", "name" => "echo", "input" => %{"text" => "x"}}
        ],
        "stop_reason" => "tool_use"
      }

      assert {:assistant, "let me check", [%{id: "t9", name: "echo", args: %{"text" => "x"}}]} =
               Convert.parse_response(resp)
    end
  end

  describe "Stream.decode/1" do
    test "reassembles text + tool_use from an SSE body" do
      sse = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1"}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}

      event: content_block_start
      data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"echo","input":{}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"text\\":"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"hi\\"}"}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

      event: message_stop
      data: {"type":"message_stop"}
      """

      assert {:assistant, "Hello there", [%{id: "t1", name: "echo", args: %{"text" => "hi"}}]} =
               Stream.decode(sse)
    end

    test "text-only stream → :final" do
      sse = """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
      """

      assert {:final, "done"} = Stream.decode(sse)
    end
  end

  describe "complete/3 against a mock server" do
    # No cluster-wide config: the provider config arrives per call (the
    # agent's template-resolved llm_opts).
    setup do
      start_supervised!(SalixLlm.MockAnthropic)
      # Randomized port avoids collisions with stray listeners across runs.
      port = start_bandit_retry!(fn p -> {Bandit, plug: SalixLlm.MockAnthropic, port: p} end)

      llm_opts = %{
        "protocol" => "anthropic",
        "model" => "claude-opus-4-8",
        "base_url" => "http://127.0.0.1:#{port}",
        "api_key" => "test-key"
      }

      {:ok, llm_opts: llm_opts}
    end

    test "sends a well-formed request and parses a tool_use response", %{llm_opts: llm_opts} do
      SalixLlm.MockAnthropic.set(%{
        "content" => [
          %{"type" => "tool_use", "id" => "tA", "name" => "echo", "input" => %{"text" => "yo"}}
        ],
        "stop_reason" => "tool_use"
      })

      result =
        Anthropic.complete(
          [%{role: "user", content: "use echo"}],
          [echo_tool_spec()],
          llm_opts
        )

      assert {:assistant, _text, [%{id: "tA", name: "echo"}]} = result

      # the outgoing request carried the model, converted message, and a tool def
      req = SalixLlm.MockAnthropic.last_request()
      assert req["model"] == "claude-opus-4-8"
      # max_tokens is the API-mandated default when the template doesn't set it
      assert req["max_tokens"] == 4096
      # The conversation tail carries the rolling cache breakpoint, which
      # promotes the string turn to block form (see SalixLlm.CacheBreakpoints).
      assert [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "use echo", "cache_control" => _}]
               }
             ] = req["messages"]

      assert [%{"name" => "echo", "input_schema" => _}] = req["tools"]
    end

    test "parses a text-only response as :final", %{llm_opts: llm_opts} do
      SalixLlm.MockAnthropic.set(%{
        "content" => [%{"type" => "text", "text" => "all done"}],
        "stop_reason" => "end_turn"
      })

      assert {:final, "all done"} =
               Anthropic.complete([%{role: "user", content: "hi"}], [], llm_opts)
    end

    test "maps generic reasoning effort to Anthropic output_config", %{llm_opts: llm_opts} do
      SalixLlm.MockAnthropic.set(%{
        "content" => [%{"type" => "text", "text" => "bounded"}],
        "stop_reason" => "end_turn"
      })

      assert {:final, "bounded"} =
               Anthropic.complete(
                 [%{role: "user", content: "classify"}],
                 [],
                 Map.put(llm_opts, "reasoning_effort", "low")
               )

      assert SalixLlm.MockAnthropic.last_request()["output_config"] == %{"effort" => "low"}
    end

    test "before_send observes the exact JSON bytes sent to Anthropic", %{llm_opts: llm_opts} do
      SalixLlm.MockAnthropic.set(%{
        "content" => [%{"type" => "text", "text" => "observed"}],
        "stop_reason" => "end_turn"
      })

      owner = self()

      llm_opts =
        Map.put(llm_opts, :before_send, fn body ->
          send(owner, {:observed_anthropic_body, body})
          :ok
        end)

      assert {:final, "observed"} =
               Anthropic.complete([%{role: "user", content: "hi"}], [], llm_opts)

      assert_receive {:observed_anthropic_body, observed_body}, 100
      assert Jason.decode!(observed_body) == SalixLlm.MockAnthropic.last_request()
    end

    test "transport_retry false sends a transient Anthropic failure exactly once" do
      bandit =
        start_supervised!(
          {Bandit, plug: {TransientAnthropic, self()}, port: 0, startup_log: false},
          id: :transient_anthropic
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

      llm_opts = %{
        "protocol" => "anthropic",
        "model" => "claude-test",
        "base_url" => "http://127.0.0.1:#{port}",
        "api_key" => "test-key",
        :transport_retry => false
      }

      assert {:error, %{"provider" => "anthropic", "status" => 500}} =
               Anthropic.complete([%{role: "user", content: "hi"}], [], llm_opts)

      assert_receive {:anthropic_request, _body}, 100
      refute_receive {:anthropic_request, _body}, 100
    end
  end

  defp echo_tool_spec do
    %{
      "name" => "echo",
      "description" => "echo text",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    }
  end

  # Bind Bandit on a random port, retrying on collisions across suites.
  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40000 + :erlang.phash2(make_ref(), 20000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
