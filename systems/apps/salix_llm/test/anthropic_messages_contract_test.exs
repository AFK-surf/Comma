defmodule SalixLlm.AnthropicMessagesContractTest do
  @moduledoc """
  Contract coverage for the Anthropic Messages (`POST {base}/v1/messages`)
  support that the agent-round clients and the site proxy share.

  The cases here are the ones where the wire protocol disagrees with the
  transport's happy path: a request that is fully configured by the template
  (`thinking`, `default_headers`, a `base_url` with a trailing slash), and the
  three ways the API fails while still answering HTTP 200 — an `error` event on
  an open stream, a `tool_use` whose arguments never finish, and
  `stop_reason: "refusal"`. None of those may surface as assistant output.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.{Convert, SiteProxy, Stream, Streaming}

  defmodule MockServer do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def set(resp), do: Agent.update(__MODULE__, &Map.put(&1, :resp, resp))

    def set_stream(body, chunk_size \\ 9),
      do: Agent.update(__MODULE__, &Map.put(&1, :resp, {:stream, chop(body, chunk_size)}))

    def last, do: Agent.get(__MODULE__, & &1[:last])

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      Agent.update(
        __MODULE__,
        &Map.put(&1, :last, %{
          path: conn.request_path,
          headers: Map.new(conn.req_headers),
          body: Jason.decode!(raw)
        })
      )

      case Agent.get(__MODULE__, & &1[:resp]) do
        {:stream, chunks} ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          Enum.reduce(chunks, conn, fn piece, conn ->
            {:ok, conn} = chunk(conn, piece)
            conn
          end)

        {:raw, status, body} ->
          send_resp(conn, status, body)

        resp ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp || %{}))
      end
    end

    defp chop(body, size) when byte_size(body) <= size, do: [body]

    defp chop(body, size) do
      <<piece::binary-size(^size), rest::binary>> = body
      [piece | chop(rest, size)]
    end
  end

  setup do
    start_supervised!(MockServer)

    bandit =
      start_supervised!({Bandit, plug: MockServer, port: 0, startup_log: false},
        id: :anthropic_contract_mock
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    # A trailing slash is a legal base_url; the OpenAI protocols and the site
    # proxy already trim it, so the Messages clients must too.
    {:ok, base: "http://127.0.0.1:#{port}/"}
  end

  defp llm(base, extra \\ %{}) do
    Map.merge(
      %{
        "protocol" => "anthropic",
        "model" => "claude-opus-4-8",
        "base_url" => base,
        "api_key" => "test-key"
      },
      extra
    )
  end

  defp text_response(text) do
    %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}
  end

  # ---- request construction ----

  describe "request construction" do
    test "a base_url with a trailing slash still resolves to /v1/messages", %{base: base} do
      MockServer.set(text_response("ok"))

      assert {:final, "ok"} =
               SalixLlm.Anthropic.complete([%{role: "user", content: "hi"}], [], llm(base))

      assert MockServer.last().path == "/v1/messages"
    end

    test "template default_headers and thinking reach the provider", %{base: base} do
      MockServer.set(text_response("ok"))

      opts =
        llm(base, %{
          "default_headers" => %{"anthropic-beta" => "context-1m-2025-08-07"},
          "thinking" => %{"type" => "adaptive"}
        })

      assert {:final, "ok"} =
               SalixLlm.Anthropic.complete([%{role: "user", content: "hi"}], [], opts)

      req = MockServer.last()
      assert req.headers["anthropic-beta"] == "context-1m-2025-08-07"
      assert req.headers["anthropic-version"] == "2023-06-01"
      assert req.body["thinking"] == %{"type" => "adaptive"}
    end

    test "cache breakpoints are placed on the wire, and can be turned off", %{base: base} do
      MockServer.set(text_response("ok"))
      conversation = [%{role: "user", content: "hi"}]

      assert {:final, "ok"} =
               SalixLlm.Anthropic.complete(conversation, [], llm(base, %{"system" => nil}))

      req = MockServer.last().body

      assert [%{"type" => "text", "cache_control" => %{"type" => "ephemeral"}}] =
               req["messages"]
               |> hd()
               |> Map.get("content")

      assert {:final, "ok"} =
               SalixLlm.Anthropic.complete(
                 conversation,
                 [],
                 llm(base, %{"prompt_caching" => false})
               )

      assert [%{"role" => "user", "content" => "hi"}] = MockServer.last().body["messages"]
    end

    test "thinking is omitted when the template does not configure it", %{base: base} do
      MockServer.set(text_response("ok"))

      assert {:final, "ok"} =
               SalixLlm.Anthropic.complete([%{role: "user", content: "hi"}], [], llm(base))

      refute Map.has_key?(MockServer.last().body, "thinking")
    end

    test "streaming shares the same URL, headers, and thinking config", %{base: base} do
      MockServer.set_stream(~s(data: {"type":"message_stop"}\n\n))

      opts =
        llm(base, %{
          "default_headers" => %{"anthropic-beta" => "fine-grained-tool-streaming-2025-05-14"},
          "thinking" => %{"type" => "adaptive"}
        })

      Streaming.complete_stream([%{role: "user", content: "hi"}], [], fn _ -> :ok end, llm: opts)

      req = MockServer.last()
      assert req.path == "/v1/messages"
      assert req.headers["anthropic-beta"] == "fine-grained-tool-streaming-2025-05-14"
      assert req.headers["anthropic-version"] == "2023-06-01"
      assert req.body["thinking"] == %{"type" => "adaptive"}
      assert req.body["stream"] == true
    end

    test "streaming omits whitespace-only assistant text while replaying its tool call", %{
      base: base
    } do
      MockServer.set_stream(~s(data: {"type":"message_stop"}\n\n))

      messages = [
        %{role: "user", content: "inspect the workspace"},
        %{
          role: "assistant",
          content: "\n\n",
          tool_calls: [
            %{"id" => "tc_1", "name" => "call", "args" => %{"tool" => "fs.list"}}
          ]
        },
        %{role: "tool", tool_call_id: "tc_1", content: "[]"}
      ]

      Streaming.complete_stream(messages, [], fn _ -> :ok end, llm: llm(base))

      assistant =
        MockServer.last().body["messages"]
        |> Enum.find(&(&1["role"] == "assistant"))

      assert [
               %{
                 "type" => "tool_use",
                 "id" => "tc_1",
                 "name" => "call",
                 "input" => %{"tool" => "fs.list"}
               }
             ] = assistant["content"]
    end

    # "messages: at least one message is required" (HTTP 400). The round right
    # after a compaction carries no conversation turn at all — the live context
    # is the summary, and the prompt snapshot and end-of-turn reminder are
    # system-authored too — so the whole request used to fold into `system`.
    test "a transcript of only system-authored context still sends a message", %{base: base} do
      MockServer.set_stream(~s(data: {"type":"message_stop"}\n\n))

      messages = [
        %{role: "summary", content: "ROUTER PROMPT"},
        %{role: "summary", content: "<compacted-context>what happened</compacted-context>"},
        %{role: "system", content: "<end-of-turn>settle this round</end-of-turn>"}
      ]

      Streaming.complete_stream(messages, [], fn _ -> :ok end, llm: llm(base))

      body = MockServer.last().body

      assert [%{"role" => "user", "content" => content}] = body["messages"]
      assert content =~ "<end-of-turn>settle this round</end-of-turn>"

      assert [%{"type" => "text", "text" => system}] = body["system"]
      assert system =~ "ROUTER PROMPT"
      assert system =~ "<compacted-context>what happened</compacted-context>"
    end
  end

  # ---- HTTP 200 that is not an assistant turn ----

  describe "failures that answer HTTP 200" do
    test "a 200 that is not a Messages body is a typed error, not a crash", %{base: base} do
      MockServer.set({:raw, 200, "<html>upstream gateway</html>"})

      assert {:error, %{"category" => "permanent_provider_error", "provider" => "anthropic"}} =
               SalixLlm.Anthropic.complete([%{role: "user", content: "hi"}], [], llm(base))
    end

    test "an error event on an open stream is a provider error, not an empty turn", %{base: base} do
      body = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8"}}

      event: error
      data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      """

      MockServer.set_stream(body)

      assert {:error,
              %{
                "category" => "retryable_provider_error",
                "provider" => "anthropic",
                "retryable" => true,
                "status" => 529
              }} =
               Streaming.complete_stream(
                 [%{role: "user", content: "hi"}],
                 [],
                 fn _ -> :ok end,
                 llm: llm(base)
               )
    end

    test "a mid-stream overflow error keeps its context_overflow category" do
      body = """
      data: {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1200000 tokens"}}
      """

      assert {:error, %{"category" => "context_overflow", "retryable" => false}} =
               Stream.decode(body)
    end

    test "an unrecognized error type still fails closed as a provider error" do
      body = ~s(data: {"type":"error","error":{"type":"brand_new_error","message":"nope"}}\n)

      assert {:error, %{"category" => "retryable_provider_error", "status" => 500}} =
               Stream.decode(body)
    end

    test "truncated tool_use arguments fail closed instead of raising" do
      body = """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"echo"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"text\\":\\"par"}}

      data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}
      """

      assert {:error, %{"category" => "permanent_provider_error", "provider" => "anthropic"}} =
               Stream.decode(body)
    end

    test "a tool_use with no argument deltas still decodes as empty arguments" do
      body = """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"ping"}}

      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
      """

      assert {:assistant, "", [%{id: "t1", name: "ping", args: %{}}]} = Stream.decode(body)
    end

    test "stop_reason refusal is a declined request, not an empty final turn" do
      resp = %{
        "content" => [],
        "stop_reason" => "refusal",
        "stop_details" => %{"type" => "refusal", "category" => "cyber"}
      }

      assert {:error, %{"category" => "provider_refusal", "provider" => "anthropic"} = meta} =
               Convert.parse_response(resp)

      assert meta["details"] =~ "cyber"
      refute SalixAgent.LLM.Error.retryable?(meta)
    end
  end

  # ---- trace metadata ----

  test "a streamed turn reports the model the provider actually served" do
    body = """
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":11}}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
    """

    assert {:final, "hi", trace} = Stream.decode(body)
    assert trace["model"] == "claude-opus-4-8"
    assert trace["usage"]["prompt_tokens"] == 11
    assert trace["usage"]["completion_tokens"] == 3
  end

  # ---- site proxy (OpenAI-shaped site API over the Messages endpoint) ----

  describe "site proxy" do
    test "an auth_token template authenticates with Bearer, not an empty x-api-key", %{base: base} do
      MockServer.set(text_response("site"))

      opts = %{
        "protocol" => "anthropic",
        "model" => "claude-opus-4-8",
        "base_url" => base,
        "auth_token" => "anth-token"
      }

      assert {:ok, resp} = SiteProxy.complete(opts, %{messages: [%{"role" => "user"}]})
      assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == "site"

      req = MockServer.last()
      assert req.path == "/v1/messages"
      assert req.headers["authorization"] == "Bearer anth-token"
      refute Map.has_key?(req.headers, "x-api-key")
    end

    test "an error event on an open stream ends the stream as a failure", %{base: base} do
      body = """
      data: {"type":"message_start","message":{"id":"msg_1"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}

      data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      """

      MockServer.set_stream(body)
      {:ok, rec} = Agent.start_link(fn -> [] end)

      result =
        SiteProxy.stream(llm(base), %{messages: [%{"role" => "user", "content" => "hi"}]}, fn c ->
          Agent.update(rec, &[c | &1])
        end)

      assert {:error, {:stream_error, %{"type" => "overloaded_error"}}, _usage} = result
      # The chunks before the failure were already delivered; the caller decides
      # not to send `[DONE]` for a stream that ended this way.
      assert Agent.get(rec, & &1) != []
    end

    test "refusal maps onto the OpenAI-shaped content_filter finish reason", %{base: base} do
      MockServer.set(%{"content" => [], "stop_reason" => "refusal"})

      assert {:ok, resp} = SiteProxy.complete(llm(base), %{messages: [%{"role" => "user"}]})
      assert get_in(resp, ["choices", Access.at(0), "finish_reason"]) == "content_filter"
    end
  end
end
