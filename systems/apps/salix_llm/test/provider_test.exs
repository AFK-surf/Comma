defmodule SalixLlm.ProviderTest do
  @moduledoc """
  The three provider protocols (willow `internal/llm/client.go` parity):
  anthropic → `/v1/messages` (x-api-key or auth-token Bearer), responses →
  `/responses` (Bearer), default → `/chat/completions` (Bearer) — each verified
  ON THE WIRE against a recording mock, plus per-call template overrides beating
  globals.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.Provider

  defmodule MockServer do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def set(path, resp), do: Agent.update(__MODULE__, &Map.put(&1, path, resp))

    def set_stream(path, body, chunk_size \\ 7),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:stream, chop(body, chunk_size)}))

    def set_sequence(path, resps),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:sequence, resps}))

    def set_delayed(path, delay_ms, resp),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:delay, delay_ms, resp}))

    def set_delayed_stream(path, first_chunk, delay_ms, remaining_chunks),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, path, {:delayed_stream, first_chunk, delay_ms, remaining_chunks})
        )

    def last, do: Agent.get(__MODULE__, & &1[:last])
    def count(path), do: Agent.get(__MODULE__, &(get_in(&1, [:counts, path]) || 0))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      Agent.update(__MODULE__, fn st ->
        st
        |> Map.put(:last, %{
          path: conn.request_path,
          headers: Map.new(conn.req_headers),
          body: Jason.decode!(raw),
          raw_body: raw
        })
        |> Map.update(:counts, %{conn.request_path => 1}, fn counts ->
          Map.update(counts, conn.request_path, 1, &(&1 + 1))
        end)
      end)

      resp =
        Agent.get_and_update(__MODULE__, fn st ->
          case st[conn.request_path] do
            {:sequence, [next | []]} ->
              {next, Map.put(st, conn.request_path, next)}

            {:sequence, [next | rest]} ->
              {next, Map.put(st, conn.request_path, {:sequence, rest})}

            resp ->
              {resp || %{}, st}
          end
        end)

      respond(conn, resp)
    end

    defp respond(conn, {:delay, delay_ms, resp}) do
      Process.sleep(delay_ms)
      respond(conn, resp)
    end

    defp respond(conn, {:delayed_stream, first_chunk, delay_ms, remaining_chunks}) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, first_chunk)
      Process.sleep(delay_ms)

      Enum.reduce(remaining_chunks, conn, fn piece, conn ->
        case chunk(conn, piece) do
          {:ok, conn} -> conn
          {:error, :closed} -> conn
        end
      end)
    end

    defp respond(conn, resp) do
      case resp do
        {:stream, chunks} ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          Enum.reduce(chunks, conn, fn piece, conn ->
            {:ok, conn} = chunk(conn, piece)
            conn
          end)

        {:status, status, body, headers} ->
          headers
          |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))

        {:status, status, body} when is_binary(body) ->
          send_resp(conn, status, body)

        {:status, status, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))

        resp ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))
      end
    end

    defp chop(body, size) when byte_size(body) <= size, do: [body]

    defp chop(body, size) do
      <<piece::binary-size(^size), rest::binary>> = body
      [piece | chop(rest, size)]
    end
  end

  setup do
    previous_request_timeout = Application.get_env(:salix_agent, :llm_request_timeout_ms)
    Application.delete_env(:salix_agent, :llm_request_timeout_ms)

    on_exit(fn ->
      case previous_request_timeout do
        nil -> Application.delete_env(:salix_agent, :llm_request_timeout_ms)
        timeout -> Application.put_env(:salix_agent, :llm_request_timeout_ms, timeout)
      end
    end)

    start_supervised!(MockServer)

    bandit =
      start_supervised!(
        {Bandit, plug: MockServer, port: 0, startup_log: false},
        id: :provider_test_mock_server
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  test "blocking and streaming providers honor the shared agent request timeout", %{base: base} do
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 50)
    previous_req_defaults = Req.default_options()
    Req.default_options(Keyword.put(previous_req_defaults, :max_retries, 0))
    on_exit(fn -> Req.default_options(previous_req_defaults) end)

    anthropic = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "auth_token" => "anth-token",
      "model" => "claude-haiku-4-5",
      "transport_retry" => false
    }

    chat = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "chat-key",
      "model" => "gpt-4o",
      "transport_retry" => false
    }

    responses = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "responses-key",
      "model" => "gpt-5.2",
      "transport_retry" => false
    }

    blocking_cases = [
      {"/v1/messages", anthropic, "anthropic",
       %{"content" => [%{"type" => "text", "text" => "late"}], "stop_reason" => "end_turn"}},
      {"/chat/completions", chat, "openai_chat",
       %{"choices" => [%{"message" => %{"content" => "late"}, "finish_reason" => "stop"}]}},
      {"/responses", responses, "openai_responses",
       %{
         "status" => "completed",
         "output" => [
           %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "late"}]}
         ]
       }}
    ]

    Enum.each(blocking_cases, fn {path, llm, provider, body} ->
      MockServer.set_delayed(path, 200, body)

      assert_transport_timeout(
        Provider.complete([%{role: "user", content: "wait"}], [], llm),
        provider
      )
    end)

    streaming_cases = [
      {"/v1/messages", anthropic, "anthropic",
       "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}\n\n"},
      {"/chat/completions", chat, "openai_chat",
       "data: {\"choices\":[{\"delta\":{\"content\":\"started\"},\"finish_reason\":null}]}\n\n"},
      {"/responses", responses, "openai_responses",
       "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"started\"}\n\n"}
    ]

    Enum.each(streaming_cases, fn {path, llm, provider, first_chunk} ->
      MockServer.set_delayed_stream(path, first_chunk, 200, [])
      {_recorder, on_delta} = recorder()

      assert_transport_timeout(
        Provider.complete_stream([%{role: "user", content: "wait"}], [], on_delta, llm),
        provider
      )
    end)

    MockServer.set_delayed("/responses/compact", 200, %{
      "status" => "completed",
      "output" => [%{"type" => "compaction", "encrypted_content" => "late"}]
    })

    assert_transport_timeout(
      Provider.compact_context([%{role: "user", content: "wait"}], [], responses),
      "openai_responses"
    )
  end

  test "a rate-limited provider's Retry-After rides the error, blocking and streaming", %{
    base: base
  } do
    MockServer.set(
      "/v1/messages",
      {:status, 429, %{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}},
       [{"retry-after", "7"}]}
    )

    llm = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "api_key" => "anth-key",
      "model" => "claude-opus-5",
      "transport_retry" => false
    }

    assert {:error, error} = Provider.complete([%{role: "user", content: "hi"}], [], llm)
    assert error["status"] == 429
    assert error["retryable"] == true
    assert error["retry_after_ms"] == 7_000

    assert {:error, streamed} =
             Provider.complete_stream([%{role: "user", content: "hi"}], [], fn _ -> :ok end, llm)

    assert streamed["status"] == 429
    assert streamed["retry_after_ms"] == 7_000

    MockServer.set("/v1/messages", {:status, 429, %{"error" => %{"message" => "slow down"}}})
    assert {:error, bare} = Provider.complete([%{role: "user", content: "hi"}], [], llm)
    refute Map.has_key?(bare, "retry_after_ms")
  end

  test "anthropic protocol: /v1/messages with x-api-key", %{base: base} do
    MockServer.set("/v1/messages", %{
      "content" => [%{"type" => "text", "text" => "anth"}],
      "stop_reason" => "end_turn"
    })

    llm = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "api_key" => "anth-key",
      "model" => "claude-haiku-4-5"
    }

    assert {:final, "anth"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.path == "/v1/messages"
    assert req.headers["x-api-key"] == "anth-key"
    assert req.body["model"] == "claude-haiku-4-5"
  end

  test "anthropic protocol can use auth_token as Bearer auth", %{base: base} do
    MockServer.set("/v1/messages", %{
      "content" => [%{"type" => "text", "text" => "anth"}],
      "stop_reason" => "end_turn"
    })

    llm = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "auth_token" => "anth-token",
      "model" => "kimi-for-coding"
    }

    assert {:final, "anth"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.path == "/v1/messages"
    assert req.headers["authorization"] == "Bearer anth-token"
    refute Map.has_key?(req.headers, "x-api-key")
  end

  test "chat-completions protocol (willow default): /chat/completions with Bearer", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "oai-key",
      "model" => "gpt-4o"
    }

    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.path == "/chat/completions"
    assert req.headers["authorization"] == "Bearer oai-key"
    assert req.body["model"] == "gpt-4o"
  end

  test "chat-completions sends a single system message at the beginning", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "oai-key",
      "model" => "doubao-pro"
    }

    assert {:final, "chat"} =
             Provider.complete(
               [
                 %{role: "summary", content: "Session prompt."},
                 %{role: "user", content: "hi"},
                 %{
                   role: "runtime",
                   kind: "runtime_message",
                   runtime_message_id: "runtime-1",
                   type: "wait_expired",
                   summary: "wait timeout reached"
                 },
                 %{role: "summary", content: "Re-evaluate every current request."}
               ],
               [],
               llm
             )

    # Strict providers reject a system message anywhere but index 0
    # ("System message must be at the beginning.").
    assert [%{"role" => "system", "content" => "Session prompt."} | rest] =
             MockServer.last().body["messages"]

    assert Enum.all?(rest, &(&1["role"] != "system"))
  end

  test "chat-completions sends explicit thinking mode and reasoning effort", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "provider-key",
      "model" => "deepseek-v4-flash",
      "thinking" => %{"type" => "enabled"},
      "reasoning_effort" => "max"
    }

    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.body["thinking"] == %{"type" => "enabled"}
    assert req.body["reasoning_effort"] == "max"
  end

  # Alibaba Model Studio rejects a blocking call to a reasoning-capable Qwen
  # model that omits enable_thinking entirely: "parameter.enable_thinking must be
  # set to false for non-streaming calls".
  test "chat-completions states enable_thinking on blocking Qwen requests", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    qwen = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "dashscope-key",
      "model" => "qwen3-235b-a22b"
    }

    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], qwen)
    assert MockServer.last().body["enable_thinking"] == false

    assert {:final, "chat"} =
             Provider.complete(
               [%{role: "user", content: "hi"}],
               [],
               %{qwen | "model" => "gpt-4o"}
             )

    refute Map.has_key?(MockServer.last().body, "enable_thinking")
  end

  test "chat-completions keeps configured thinking to streamed Qwen calls", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    # The same reasoning config the other protocols read — no Qwen-only switch.
    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "dashscope-key",
      "model" => "qwen3-235b-a22b",
      "reasoning_effort" => "high"
    }

    # Thinking is only valid on a stream, so the blocking call states false.
    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)
    assert MockServer.last().body["enable_thinking"] == false

    MockServer.set_stream("/chat/completions", """
    data:{"choices":[{"delta":{"content":"chat"}}]}

    data:[DONE]
    """)

    assert {:final, "chat"} =
             Provider.complete_stream([%{role: "user", content: "hi"}], [], fn _ -> :ok end, llm)

    assert MockServer.last().body["enable_thinking"] == true
  end

  test "chat-completions uses max_completion_tokens for newer OpenAI models", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "oai-key",
      "model" => "gpt-5-mini",
      "max_tokens" => 64
    }

    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.body["max_completion_tokens"] == 64
    refute Map.has_key?(req.body, "max_tokens")
  end

  test "chat-completions keeps max_tokens for legacy chat models", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "chat"}, "finish_reason" => "stop"}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "oai-key",
      "model" => "gpt-4o",
      "max_tokens" => 64
    }

    assert {:final, "chat"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    req = MockServer.last()
    assert req.body["max_tokens"] == 64
    refute Map.has_key?(req.body, "max_completion_tokens")
  end

  test "chat-completions tool calls parse into the LLM result shape", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [
        %{
          "message" => %{
            "content" => "calling",
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "echo", "arguments" => ~s({"text":"x"})}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    })

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "k"}

    assert {:assistant, "calling", [%{id: "c1", name: "echo", args: %{"text" => "x"}}]} =
             Provider.complete(
               [%{role: "user", content: "go"}],
               [
                 %{
                   "name" => "echo",
                   "description" => "d",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"text" => %{"type" => "string"}},
                     "required" => ["text"]
                   }
                 }
               ],
               llm
             )

    # tool defs went out in OpenAI function shape
    assert [%{"type" => "function", "function" => %{"name" => "echo"}}] =
             MockServer.last().body["tools"]
  end

  test "chat-completions preserves reasoning fields across tool-call replay", %{base: base} do
    reasoning_details = [
      %{
        "type" => "reasoning.text",
        "text" => "Need current date before weather.",
        "format" => "anthropic-claude-v1",
        "index" => 0
      }
    ]

    MockServer.set("/chat/completions", %{
      "choices" => [
        %{
          "message" => %{
            "content" => "checking",
            "reasoning_content" => "I need to call the date tool.",
            "reasoning_details" => reasoning_details,
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "get_date", "arguments" => "{}"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    })

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "k"}

    assert {:assistant, "checking", [%{id: "c1", name: "get_date", args: %{}}], meta} =
             Provider.complete(
               [%{role: "user", content: "weather tomorrow"}],
               [
                 %{
                   "name" => "get_date",
                   "description" => "d",
                   "input_schema" => %{"type" => "object", "properties" => %{}, "required" => []}
                 }
               ],
               llm
             )

    assert %{
             "reasoning_content" => "I need to call the date tool.",
             "reasoning_details" => ^reasoning_details
           } = meta["chat_message_extra"]

    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "done"}}]
    })

    {:final, "done"} =
      Provider.complete(
        [
          %{role: "user", content: "weather tomorrow"},
          %{
            role: "assistant",
            content: "checking",
            tool_calls: [%{"id" => "c1", "name" => "get_date", "args" => %{}}],
            provider_meta: meta
          },
          %{role: "tool", tool_call_id: "c1", content: "2026-06-24"}
        ],
        [
          %{
            "name" => "get_date",
            "description" => "d",
            "input_schema" => %{"type" => "object", "properties" => %{}, "required" => []}
          }
        ],
        llm
      )

    assistant =
      MockServer.last().body["messages"]
      |> Enum.find(&(&1["role"] == "assistant"))

    assert assistant["reasoning_content"] == "I need to call the date tool."
    assert assistant["reasoning_details"] == reasoning_details
  end

  test "responses protocol: /responses, function_call output parses", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "resp"}]},
        %{
          "type" => "function_call",
          "call_id" => "r1",
          "name" => "echo",
          "arguments" => ~s({"text":"y"})
        }
      ]
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "gpt-5.6-terra"
    }

    # tool-call turns carry provider meta: the raw output items for verbatim
    # replay (thinking preservation on newer OpenAI models).
    assert {:assistant, "resp", [%{id: "r1", name: "echo", args: %{"text" => "y"}}], meta} =
             Provider.complete(
               [%{role: "user", content: "go"}],
               [
                 %{
                   "name" => "echo",
                   "description" => "d",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"text" => %{"type" => "string"}},
                     "required" => ["text"]
                   }
                 }
               ],
               llm
             )

    assert [%{"type" => "message"}, %{"type" => "function_call"}] = meta["responses_items"]

    req = MockServer.last()
    assert req.path == "/responses"
    assert req.headers["authorization"] == "Bearer resp-key"
    # responses tools are flat (no nested function object)
    assert [%{"type" => "function", "name" => "echo"}] = req.body["tools"]
    # tool results travel as function_call_output items
    assert is_list(req.body["input"])
    refute Map.has_key?(req.body, "reasoning")
  end

  test "responses protocol passes configurable context management", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
      ]
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "gpt-5.6-terra",
      "store" => false,
      "include" => ["reasoning.encrypted_content"],
      "context_management" => [%{"type" => "compaction", "compact_threshold" => 200_000}],
      "reasoning" => %{"effort" => "medium"}
    }

    assert {:final, "ok"} = Provider.complete([%{role: "user", content: "go"}], [], llm)

    req = MockServer.last()
    assert req.body["store"] == false
    assert req.body["include"] == ["reasoning.encrypted_content"]
    assert req.body["reasoning"] == %{"effort" => "medium"}

    assert req.body["context_management"] == [
             %{"type" => "compaction", "compact_threshold" => 200_000}
           ]
  end

  test "responses protocol preserves an explicit GPT-5.6 reasoning context", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
      ]
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "gpt-5.6-terra",
      "reasoning" => %{context: "all_turns", effort: "medium"}
    }

    assert {:final, "ok"} = Provider.complete([%{role: "user", content: "go"}], [], llm)

    req = MockServer.last()

    assert req.body["reasoning"] == %{
             "context" => "all_turns",
             "effort" => "medium"
           }

    assert length(Regex.scan(~r/"context"\s*:/, req.raw_body)) == 1
  end

  test "responses protocol preserves server-side compaction output on final responses", %{
    base: base
  } do
    output = [
      %{"type" => "compaction", "id" => "cmp_1", "encrypted_content" => "cipher"},
      %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
    ]

    MockServer.set("/responses", %{"output" => output})

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model",
      "context_management" => [%{"type" => "compaction", "compact_threshold" => 200_000}]
    }

    assert {:final, "ok", %{"responses_items" => ^output}, %{}} =
             Provider.complete([%{role: "user", content: "go"}], [], llm)

    refute Map.has_key?(MockServer.last().body, "reasoning")
  end

  test "responses protocol normalizes compacted assistant messages for replay", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
      ]
    })

    compacted = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "remember this"}]
      },
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "input_text", "text" => "remembered"}]
      },
      %{"type" => "compaction", "id" => "cmp_1", "encrypted_content" => "cipher"}
    ]

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model"
    }

    assert {:final, "ok"} =
             Provider.complete(
               [
                 %{role: "provider_context", provider_meta: %{"responses_items" => compacted}},
                 %{role: "user", content: "continue"}
               ],
               [],
               llm
             )

    [user_item, assistant_item, %{"type" => "compaction"}, next_user] =
      MockServer.last().body["input"]

    assert [%{"type" => "input_text"}] = user_item["content"]
    assert [%{"type" => "output_text"}] = assistant_item["content"]
    assert %{"role" => "user", "content" => "continue"} = next_user
  end

  test "responses compact_context posts to /responses/compact", %{base: base} do
    compacted = [
      %{"type" => "compaction", "id" => "cmp_1", "encrypted_content" => "cipher"}
    ]

    MockServer.set("/responses/compact", %{
      "model" => "resp-model",
      "output" => compacted,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model",
      "context_management" => [%{"type" => "compaction", "compact_threshold" => 200_000}]
    }

    assert {:ok, ^compacted, %{"model" => "resp-model", "usage" => %{"total_tokens" => 12}}} =
             Provider.compact_context([%{role: "user", content: "go"}], [], llm)

    req = MockServer.last()
    assert req.path == "/responses/compact"
    assert [%{"role" => "user", "content" => "go"}] = req.body["input"]
    refute Map.has_key?(req.body, "context_management")
  end

  test "responses protocol sends a configured prompt_cache_key, compact does not", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
      ]
    })

    MockServer.set("/responses/compact", %{
      "model" => "resp-model",
      "output" => [%{"type" => "compaction", "id" => "cmp_1", "encrypted_content" => "c"}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model",
      "prompt_cache_key" => "3f2504e0-4f89-5d3a-9a0c-0305e82c3301"
    }

    assert {:final, "ok"} = Provider.complete([%{role: "user", content: "go"}], [], llm)
    assert MockServer.last().body["prompt_cache_key"] == "3f2504e0-4f89-5d3a-9a0c-0305e82c3301"

    assert {:ok, _, _} = Provider.compact_context([%{role: "user", content: "go"}], [], llm)
    refute Map.has_key?(MockServer.last().body, "prompt_cache_key")

    assert {:final, "ok"} =
             Provider.complete(
               [%{role: "user", content: "go"}],
               [],
               Map.delete(llm, "prompt_cache_key")
             )

    refute Map.has_key?(MockServer.last().body, "prompt_cache_key")
  end

  test "chat protocol sends a configured prompt_cache_key", %{base: base} do
    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
    })

    llm = %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "chat-key",
      "model" => "chat-model",
      "prompt_cache_key" => "3f2504e0-4f89-5d3a-9a0c-0305e82c3301"
    }

    assert {:final, "ok"} = Provider.complete([%{role: "user", content: "go"}], [], llm)
    assert MockServer.last().body["prompt_cache_key"] == "3f2504e0-4f89-5d3a-9a0c-0305e82c3301"
  end

  test "responses protocol lifts leading system messages into instructions", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Title"}]}
      ]
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model"
    }

    assert {:final, "Title"} =
             Provider.complete(
               [
                 %{role: "system", content: "You generate titles only."},
                 %{role: "summary", content: "Prior compacted context."},
                 %{role: "user", content: "draft the Q2 report"}
               ],
               [],
               llm
             )

    req = MockServer.last()
    assert req.body["instructions"] == "You generate titles only.\n\nPrior compacted context."
    assert [%{"role" => "user", "content" => "draft the Q2 report"}] = req.body["input"]
  end

  test "responses protocol receives Salix base prompt and call envelope schema", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Working"}]}
      ]
    })

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    disclosure =
      SalixAgent.ToolDisclosure.materialize(
        "worker",
        :internal,
        SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "agent-provider-test"})
      )

    prompt =
      SalixAgent.ToolPolicy.session_prompt(
        "worker",
        %{},
        "agent-provider-test",
        :internal,
        disclosure
      )

    messages =
      SalixAgent.ToolPolicy.prepend_prompt_snapshot([%{role: "user", content: "start"}], prompt)

    tools = SalixAgent.ToolPolicy.specs_for("worker")

    assert {:final, "Working"} = Provider.complete(messages, tools, llm)

    req = MockServer.last()

    assert req.body["instructions"] == String.trim(prompt)

    assert [%{"role" => "user", "content" => "start"}] = req.body["input"]

    call_tool = Enum.find(req.body["tools"], &(&1["name"] == "call"))
    assert %{"type" => "function", "parameters" => %{"properties" => props}} = call_tool
    assert props["tool"]["type"] == "string"
    assert props["params"]["type"] == "object"
  end

  test "anthropic protocol streams deltas through the provider", %{base: base} do
    MockServer.set_stream("/v1/messages", """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"an"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"th"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
    """)

    llm = %{"protocol" => "anthropic", "base_url" => base, "auth_token" => "anth-token"}
    {rec, on_delta} = recorder()

    assert {:final, "anth"} =
             Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)

    assert deltas(rec) == ["an", "th"]
    assert MockServer.last().body["stream"] == true
    assert MockServer.last().headers["authorization"] == "Bearer anth-token"
    refute Map.has_key?(MockServer.last().headers, "x-api-key")
  end

  test "chat-completions wire stream produces bounded TTFT and usage metrics", %{base: base} do
    previous_llm = Application.fetch_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, Provider)

    on_exit(fn ->
      case previous_llm do
        {:ok, llm} -> Application.put_env(:salix_agent, :llm, llm)
        :error -> Application.delete_env(:salix_agent, :llm)
      end
    end)

    MockServer.set_stream("/chat/completions", """
    data:{"choices":[{"delta":{"content":"ch"}}]}

    data:{"choices":[{"delta":{"content":"at"}}]}

    data:{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5,"prompt_tokens_details":{"cached_tokens":1,"cache_write_tokens":2}}}

    data:[DONE]
    """)

    reporter = Module.concat(__MODULE__, PlatformTelemetryReporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Salix.Telemetry.metrics(), start_async: false},
      id: :platform_telemetry_reporter
    )

    llm = [
      protocol: "chat_completions",
      base_url: base,
      api_key: "oai-key",
      model: "gpt-5.2",
      metering_disabled: true,
      billing_context: %{"surface" => "comma"}
    ]

    {rec, on_delta} = recorder()

    assert {:final, "chat", %{"usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}}} =
             SalixAgent.LLM.complete_stream(
               [%{role: "user", content: "hi"}],
               [],
               on_delta,
               llm
             )

    assert deltas(rec) == ["ch", "at"]
    assert MockServer.last().body["stream"] == true

    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

    assert metric_line(scrape, "salix_llm_ttft_seconds_count", %{
             "surface" => "comma",
             "provider" => "openai",
             "model_key" => "gpt-5.2",
             "outcome" => "ok"
           }) =~ ~r/ 1$/

    for {kind, value} <- [
          {"input", 3},
          {"output", 2},
          {"cache_read", 1},
          {"cache_write", 2}
        ] do
      assert metric_line(scrape, "salix_llm_tokens_total", %{
               "surface" => "comma",
               "provider" => "openai",
               "model_key" => "gpt-5.2",
               "kind" => kind
             }) =~ ~r/ #{value}$/
    end
  end

  test "chat-completions stream preserves reasoning deltas on tool calls", %{base: base} do
    MockServer.set_stream("/chat/completions", """
    data:{"choices":[{"delta":{"reasoning_content":"Need ","reasoning_details":[{"type":"reasoning.text","text":"Need date.","index":0}]}}]}

    data:{"choices":[{"delta":{"reasoning_content":"a date.","reasoning_details":[{"type":"reasoning.text","text":"Call tool.","index":1}],"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_date","arguments":""}}]}}]}

    data:{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}

    data:[DONE]
    """)

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}
    {rec, on_delta} = recorder()

    assert {:assistant, "", [%{id: "c1", name: "get_date", args: %{}}], meta} =
             Provider.complete_stream(
               [%{role: "user", content: "weather"}],
               [
                 %{
                   "name" => "get_date",
                   "description" => "d",
                   "input_schema" => %{"type" => "object", "properties" => %{}, "required" => []}
                 }
               ],
               on_delta,
               llm
             )

    assert deltas(rec) == []
    assert meta["chat_message_extra"]["reasoning_content"] == "Need a date."

    # The provider index is not a stable block identity. These are consecutive
    # text fragments, so replay retains the first block's metadata and joins the
    # streamed text.
    assert [
             %{
               "type" => "reasoning.text",
               "text" => "Need date.Call tool.",
               "index" => 0
             }
           ] = meta["chat_message_extra"]["reasoning_details"]
  end

  test "chat-completions stream preserves reasoning block order and boundaries", %{base: base} do
    MockServer.set_stream("/chat/completions", """
    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"First ","format":"openai-responses-v1","index":0}]}}]}

    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"part.","index":0}]}}]}

    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"A","signature":"SIG-A","index":0}]}}]}

    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"OPAQUE-1","id":"enc-1","index":0}]}}]}

    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"OPAQUE-2","id":"enc-2","index":0}],"content":"Done."}}]}

    data:{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"B","signature":"SIG-B","index":0}]}}]}

    data:[DONE]
    """)

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}
    {_rec, on_delta} = recorder()

    assert {:final, "Done.", meta, %{}} =
             Provider.complete_stream(
               [%{role: "user", content: "reason about this"}],
               [],
               on_delta,
               llm
             )

    assert meta["chat_message_extra"]["reasoning_details"] == [
             %{
               "type" => "reasoning.summary",
               "summary" => "First part.",
               "format" => "openai-responses-v1",
               "index" => 0
             },
             %{
               "type" => "reasoning.text",
               "text" => "A",
               "signature" => "SIG-A",
               "index" => 0
             },
             %{
               "type" => "reasoning.encrypted",
               "data" => "OPAQUE-1",
               "id" => "enc-1",
               "index" => 0
             },
             %{
               "type" => "reasoning.encrypted",
               "data" => "OPAQUE-2",
               "id" => "enc-2",
               "index" => 0
             },
             %{
               "type" => "reasoning.text",
               "text" => "B",
               "signature" => "SIG-B",
               "index" => 0
             }
           ]
  end

  test "chat-completions replays an explicit empty reasoning-details array", %{base: base} do
    MockServer.set_stream("/chat/completions", """
    data:{"choices":[{"delta":{"reasoning_details":[]}}]}

    data:{"choices":[{"delta":{"content":"Done."}}]}

    data:[DONE]
    """)

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}
    {_rec, on_delta} = recorder()

    assert {:final, "Done.", meta, %{}} =
             Provider.complete_stream(
               [%{role: "user", content: "reason about this"}],
               [],
               on_delta,
               llm
             )

    assert meta["chat_message_extra"]["reasoning_details"] == []

    MockServer.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "Acknowledged."}, "finish_reason" => "stop"}]
    })

    assert {:final, "Acknowledged."} =
             Provider.complete(
               [
                 %{role: "user", content: "reason about this"},
                 %{role: "assistant", content: "Done.", provider_meta: meta},
                 %{role: "user", content: "continue"}
               ],
               [],
               llm
             )

    assistant =
      MockServer.last().body["messages"]
      |> Enum.find(&(&1["role"] == "assistant"))

    assert Map.fetch!(assistant, "reasoning_details") == []
  end

  test "chat-completions streaming returns a controlled error for invalid base_url" do
    llm = %{"protocol" => "chat_completions", "base_url" => "", "api_key" => "oai-key"}
    {rec, on_delta} = recorder()

    assert {:error, %{"category" => "transport_error", "retryable" => true}} =
             Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)

    assert deltas(rec) == []
  end

  test "provider errors return structured LLM error tuples", %{base: base} do
    before_count = MockServer.count("/chat/completions")
    MockServer.set("/chat/completions", {:status, 502, %{"error" => %{"message" => "busy"}}})

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}
    {_rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "openai_chat",
              "retryable" => true,
              "status" => 502
            }} = Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)

    assert MockServer.count("/chat/completions") == before_count + 1
  end

  test "provider request timeout is retryable after transport retries are exhausted", %{
    base: base
  } do
    MockServer.set(
      "/chat/completions",
      {:status, 408, %{"error" => %{"message" => "request timeout"}}}
    )

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}
    {_rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "openai_chat",
              "retryable" => true,
              "status" => 408
            }} = Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)
  end

  test "provider context overflow is classified separately", %{base: base} do
    MockServer.set("/chat/completions", {
      :status,
      400,
      %{"error" => %{"code" => "context_length_exceeded", "message" => "too many tokens"}}
    })

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}

    assert {:error,
            %{
              "category" => "context_overflow",
              "provider" => "openai_chat",
              "retryable" => false,
              "status" => 400
            }} = Provider.complete([%{role: "user", content: "hi"}], [], llm)
  end

  test "chat-completions blocking provider errors return structured categories", %{base: base} do
    MockServer.set("/chat/completions", {:status, 401, %{"error" => %{"message" => "bad key"}}})

    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "oai-key"}

    assert {:error,
            %{
              "category" => "permanent_provider_error",
              "provider" => "openai_chat",
              "retryable" => false,
              "status" => 401
            }} = Provider.complete([%{role: "user", content: "hi"}], [], llm)
  end

  test "anthropic blocking context overflow returns structured error", %{base: base} do
    MockServer.set("/v1/messages", {
      :status,
      400,
      %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "prompt is too long: 233153 tokens > 200000 maximum"
        }
      }
    })

    llm = %{"protocol" => "anthropic", "base_url" => base, "auth_token" => "anth-token"}

    assert {:error,
            %{
              "category" => "context_overflow",
              "provider" => "anthropic",
              "retryable" => false,
              "status" => 400
            } = meta} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    assert meta["body"] =~ "prompt is too long"
  end

  test "anthropic blocking provider and transport errors return structured categories", %{
    base: base
  } do
    MockServer.set("/v1/messages", {
      :status,
      429,
      %{"type" => "error", "error" => %{"message" => "rate limited"}}
    })

    llm = %{"protocol" => "anthropic", "base_url" => base, "auth_token" => "anth-token"}

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "anthropic",
              "retryable" => true,
              "status" => 429
            }} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    closed_port_llm = %{
      "protocol" => "anthropic",
      "base_url" => "http://127.0.0.1:1",
      "auth_token" => "anth-token"
    }

    assert {:error,
            %{
              "category" => "transport_error",
              "provider" => "anthropic",
              "retryable" => true
            }} = Provider.complete([%{role: "user", content: "hi"}], [], closed_port_llm)
  end

  test "anthropic streaming provider errors return structured categories", %{base: base} do
    MockServer.set("/v1/messages", {
      :status,
      500,
      %{"type" => "error", "error" => %{"message" => "server busy"}}
    })

    llm = %{"protocol" => "anthropic", "base_url" => base, "auth_token" => "anth-token"}
    {rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "anthropic",
              "retryable" => true,
              "status" => 500
            }} = Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)

    assert deltas(rec) == []
  end

  test "anthropic streaming context overflow returns structured error", %{base: base} do
    MockServer.set("/v1/messages", {
      :status,
      400,
      Jason.encode!(%{
        "type" => "error",
        "error" => %{"message" => "input exceeds context limit"}
      })
    })

    llm = %{"protocol" => "anthropic", "base_url" => base, "auth_token" => "anth-token"}
    {rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "context_overflow",
              "provider" => "anthropic",
              "retryable" => false,
              "status" => 400
            }} = Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm)

    assert deltas(rec) == []
  end

  test "responses protocol streams deltas and preserves raw output metadata", %{base: base} do
    MockServer.set_stream("/responses", """
    event: response.output_text.delta
    data:{"type":"response.output_text.delta","delta":"re"}

    event: response.output_text.delta
    data:{"type":"response.output_text.delta","delta":"sp"}

    event: response.completed
    data:{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"resp"}]},{"type":"function_call","call_id":"r1","name":"echo","arguments":"{\\"text\\":\\"z\\"}"}]}}

    data:[DONE]
    """)

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "gpt-5.6-terra",
      "reasoning" => %{"effort" => "medium"}
    }

    {rec, on_delta} = recorder()

    assert {:assistant, "resp", [%{id: "r1", name: "echo", args: %{"text" => "z"}}], meta} =
             Provider.complete_stream(
               [%{role: "user", content: "go"}],
               [
                 %{
                   "name" => "echo",
                   "description" => "d",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"text" => %{"type" => "string"}},
                     "required" => ["text"]
                   }
                 }
               ],
               on_delta,
               llm
             )

    assert deltas(rec) == ["re", "sp"]
    assert [%{"type" => "message"}, %{"type" => "function_call"}] = meta["responses_items"]

    req = MockServer.last()
    assert req.path == "/responses"
    assert req.body["stream"] == true
    assert req.body["reasoning"] == %{"effort" => "medium"}
    assert [%{"type" => "function", "name" => "echo"}] = req.body["tools"]
  end

  test "responses stream request accepts a non-streaming JSON response", %{base: base} do
    MockServer.set("/responses", %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "json fallback"}]
        },
        %{
          "type" => "function_call",
          "call_id" => "r2",
          "name" => "echo",
          "arguments" => ~s({"text":"fallback"})
        }
      ]
    })

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}
    {rec, on_delta} = recorder()

    assert {:assistant, "json fallback",
            [%{id: "r2", name: "echo", args: %{"text" => "fallback"}}], meta} =
             Provider.complete_stream(
               [%{role: "user", content: "go"}],
               [
                 %{
                   "name" => "echo",
                   "description" => "d",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"text" => %{"type" => "string"}},
                     "required" => ["text"]
                   }
                 }
               ],
               on_delta,
               llm
             )

    assert deltas(rec) == []
    assert [%{"type" => "message"}, %{"type" => "function_call"}] = meta["responses_items"]
    assert MockServer.last().body["stream"] == true
  end

  test "responses incomplete context overflow returns structured error", %{base: base} do
    MockServer.set("/responses", %{
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_context_length_exceeded"},
      "output" => []
    })

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    assert {:error,
            %{
              "category" => "context_overflow",
              "provider" => "openai_responses",
              "provider_status" => "incomplete"
            }} = Provider.complete([%{role: "user", content: "go"}], [], llm)
  end

  test "responses incomplete output truncation returns the available assistant text", %{
    base: base
  } do
    MockServer.set("/responses", %{
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens_reached"},
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "partial answer"}]
        }
      ],
      "usage" => %{"input_tokens" => 2, "output_tokens" => 4}
    })

    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model"
    }

    assert {:final, "partial answer", meta} =
             Provider.complete([%{role: "user", content: "go"}], [], llm)

    assert meta["model"] == "resp-model"
  end

  @tag :recommendation_output_errors
  test "responses output limit rejects a tool batch instead of dispatching empty arguments", %{
    base: base
  } do
    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}
    partial = ~s({"tool":"recommendation.publish","params":{"snapshot":)

    valid = %{
      "type" => "function_call",
      "call_id" => "valid-sibling",
      "name" => "call",
      "arguments" => ~s({"tool":"help","params":{}})
    }

    truncated = %{valid | "call_id" => "truncated", "arguments" => partial}

    response = %{
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "output" => [valid, truncated]
    }

    MockServer.set("/responses", response)

    assert {:error, error} = Provider.complete([%{role: "user", content: "go"}], [], llm)
    assert error["category"] == "permanent_provider_error"
    assert error["reason"] == "output_token_limit"
    assert error["retryable"] == false
    assert error["message"] =~ "Max tokens"
    refute inspect(error) =~ "recommendation.publish"

    # The terminal event may omit output: the fragments still identify a tool
    # batch, and must not be mistaken for the text-only truncation exception.
    for terminal_output <- [[valid, truncated], []] do
      events = [
        %{"type" => "response.output_item.added", "item" => truncated},
        %{
          "type" => "response.incomplete",
          "response" => %{response | "output" => terminal_output}
        }
      ]

      MockServer.set_stream("/responses", responses_events(events))

      assert {:error, ^error} =
               Provider.complete_stream(
                 [%{role: "user", content: "go"}],
                 [],
                 fn _ -> :ok end,
                 llm
               )
    end

    # Even individually complete calls do not authorize dispatch of a batch
    # whose provider explicitly reports incomplete generation.
    MockServer.set("/responses", %{response | "output" => [valid]})
    assert {:error, ^error} = Provider.complete([%{role: "user", content: "go"}], [], llm)

    assert MockServer.count("/responses") == 4
  end

  @tag :recommendation_output_errors
  test "responses accepts explicit empty objects and preserves valid call order", %{base: base} do
    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    calls =
      for {id, args} <- [{"first", "{}"}, {"second", %{"key" => "value"}}] do
        %{"type" => "function_call", "call_id" => id, "name" => "echo", "arguments" => args}
      end

    response = %{"status" => "completed", "output" => calls}

    MockServer.set("/responses", response)

    assert {:assistant, "", parsed, _} =
             Provider.complete([%{role: "user", content: "go"}], [], llm)

    assert parsed == [
             %{id: "first", name: "echo", args: %{}},
             %{id: "second", name: "echo", args: %{"key" => "value"}}
           ]

    MockServer.set_stream(
      "/responses",
      responses_events([
        %{"type" => "response.completed", "response" => response}
      ])
    )

    assert {:assistant, "", ^parsed, _} =
             Provider.complete_stream([%{role: "user", content: "go"}], [], fn _ -> :ok end, llm)
  end

  @tag :recommendation_output_errors
  test "responses rejects malformed tool arguments even without an incomplete status", %{
    base: base
  } do
    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    for arguments <- [~s({"private":"do-not-leak), "", nil, "[]", "null", "42", [1], 42] do
      item = %{
        "type" => "function_call",
        "call_id" => "bad-call",
        "name" => "call",
        "arguments" => arguments
      }

      MockServer.set("/responses", %{"status" => "completed", "output" => [item]})

      assert {:error, error} = Provider.complete([%{role: "user", content: "go"}], [], llm)
      assert error["category"] == "permanent_provider_error"
      assert error["reason"] == "invalid_tool_arguments"
      assert error["retryable"] == false
      assert error["message"] =~ "complete JSON object"
      refute inspect(error) =~ "do-not-leak"

      # A dropped stream can leave only an added item, with no terminal event.
      MockServer.set_stream(
        "/responses",
        responses_events([
          %{"type" => "response.output_item.added", "item" => item}
        ])
      )

      assert {:error, ^error} =
               Provider.complete_stream(
                 [%{role: "user", content: "go"}],
                 [],
                 fn _ -> :ok end,
                 llm
               )
    end

    assert MockServer.count("/responses") == 16
  end

  @tag :recommendation_output_errors
  test "responses failed stream cannot dispatch a previously streamed tool call", %{base: base} do
    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    MockServer.set_stream(
      "/responses",
      responses_events([
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "call_id" => "c1",
            "name" => "call",
            "arguments" => ~s({"tool":"help","params":{}})
          }
        },
        %{
          "type" => "response.failed",
          "response" => %{
            "status" => "failed",
            "error" => %{"message" => "generation failed"}
          }
        }
      ])
    )

    assert {:error, %{"provider_status" => "failed", "retryable" => false}} =
             Provider.complete_stream([%{role: "user", content: "go"}], [], fn _ -> :ok end, llm)

    assert MockServer.count("/responses") == 1
  end

  @tag :recommendation_output_errors
  test "responses streaming text-only output limit preserves available text and usage", %{
    base: base
  } do
    llm = %{
      "protocol" => "responses",
      "base_url" => base,
      "api_key" => "resp-key",
      "model" => "resp-model"
    }

    MockServer.set_stream(
      "/responses",
      responses_events([
        %{"type" => "response.output_text.delta", "delta" => "partial answer"},
        %{
          "type" => "response.incomplete",
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "output" => [],
            "usage" => %{"input_tokens" => 2, "output_tokens" => 4}
          }
        }
      ])
    )

    assert {:final, "partial answer", meta} =
             Provider.complete_stream([%{role: "user", content: "go"}], [], fn _ -> :ok end, llm)

    assert meta["usage"]["completion_tokens"] == 4
  end

  defp responses_events(events),
    do: Enum.map_join(events, &("data: " <> Jason.encode!(&1) <> "\n\n"))

  test "responses empty completed output is a structured transport error", %{base: base} do
    MockServer.set("/responses", %{"status" => "completed", "output" => []})

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}

    assert {:error,
            %{
              "category" => "transport_error",
              "provider" => "openai_responses",
              "reason" => ":empty_response_output",
              "retryable" => true
            }} = Provider.complete([%{role: "user", content: "go"}], [], llm)

    MockServer.set_stream("/responses", """
    event: response.completed
    data: {"type":"response.completed","response":{"status":"completed","output":[]}}
    """)

    {rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "transport_error",
              "provider" => "openai_responses",
              "reason" => ":empty_response_output",
              "retryable" => true
            }} = Provider.complete_stream([%{role: "user", content: "go"}], [], on_delta, llm)

    assert deltas(rec) == []

    MockServer.set("/responses", %{
      "status" => "completed",
      "output" => [%{"type" => "message", "content" => []}]
    })

    assert {:final, ""} = Provider.complete([%{role: "user", content: "go"}], [], llm)
  end

  test "responses stream retries a transient error before receiving stream data", %{base: base} do
    MockServer.set_sequence("/responses", [
      {:status, 502, ""},
      {:stream,
       [
         """
         event: response.output_text.delta
         data:{"type":"response.output_text.delta","delta":"O"}

         event: response.output_text.delta
         data:{"type":"response.output_text.delta","delta":"K"}

         event: response.completed
         data:{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}}
         """
       ]}
    ])

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}
    {rec, on_delta} = recorder()

    assert {:final, "OK"} =
             Provider.complete_stream([%{role: "user", content: "go"}], [], on_delta, llm)

    assert deltas(rec) == ["O", "K"]
    assert MockServer.count("/responses") == 2
  end

  test "responses stream returns structured error after retries are exhausted", %{base: base} do
    MockServer.set_sequence("/responses", [
      {:status, 502, %{"error" => %{"message" => "busy-1"}}},
      {:status, 502, %{"error" => %{"message" => "busy-2"}}},
      {:status, 502, %{"error" => %{"message" => "busy-3"}}}
    ])

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}
    {rec, on_delta} = recorder()

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "openai_responses",
              "retryable" => true,
              "status" => 502
            }} = Provider.complete_stream([%{role: "user", content: "go"}], [], on_delta, llm)

    assert deltas(rec) == []
    assert MockServer.count("/responses") == 3
  end

  test "responses stream reconstructs when completed event has empty output", %{base: base} do
    MockServer.set_stream("/responses", """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"PO","output_index":0}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"NG","output_index":0}

    event: response.output_text.done
    data: {"type":"response.output_text.done","text":"PONG","output_index":0}

    event: response.output_item.done
    data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","text":"PONG"}],"role":"assistant"},"output_index":0}

    event: response.completed
    data: {"type":"response.completed","response":{"output":[]}}
    """)

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "resp-key"}
    {rec, on_delta} = recorder()

    assert {:final, "PONG"} =
             Provider.complete_stream([%{role: "user", content: "go"}], [], on_delta, llm)

    assert deltas(rec) == ["PO", "NG"]
  end

  test "tool-result round-trip shapes per protocol", %{base: base} do
    conversation = [
      %{role: "user", content: "go"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{"id" => "t1", "name" => "echo", "args" => %{}}]
      },
      %{role: "tool", tool_call_id: "t1", content: "result!"}
    ]

    MockServer.set("/chat/completions", %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    llm = %{"protocol" => "chat_completions", "base_url" => base, "api_key" => "k"}
    {:final, "ok"} = Provider.complete(conversation, [], llm)

    msgs = MockServer.last().body["messages"]

    assert Enum.any?(
             msgs,
             &(&1["role"] == "tool" and &1["tool_call_id"] == "t1" and &1["content"] == "result!")
           )

    assistant = Enum.find(msgs, &(&1["role"] == "assistant"))
    assert [%{"id" => "t1", "function" => %{"name" => "echo"}}] = assistant["tool_calls"]

    MockServer.set("/responses", %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
      ]
    })

    llm = %{"protocol" => "responses", "base_url" => base, "api_key" => "k"}
    {:final, "ok"} = Provider.complete(conversation, [], llm)

    input = MockServer.last().body["input"]
    assert Enum.any?(input, &(&1["type"] == "function_call" and &1["call_id"] == "t1"))
    assert Enum.any?(input, &(&1["type"] == "function_call_output" and &1["output"] == "result!"))
  end

  test "api_key_env resolves the key from the OS environment", %{base: base} do
    System.put_env("SALIX_TEST_TENANT_KEY", "env-key-123")
    on_exit(fn -> System.delete_env("SALIX_TEST_TENANT_KEY") end)

    MockServer.set("/v1/messages", %{
      "content" => [%{"type" => "text", "text" => "ok"}],
      "stop_reason" => "end_turn"
    })

    llm = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "api_key_env" => "SALIX_TEST_TENANT_KEY"
    }

    {:final, "ok"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    assert MockServer.last().headers["x-api-key"] == "env-key-123"
  end

  test "auth_token_env resolves the Bearer auth token from the OS environment", %{base: base} do
    System.put_env("SALIX_TEST_AUTH_TOKEN", "env-token-123")
    on_exit(fn -> System.delete_env("SALIX_TEST_AUTH_TOKEN") end)

    MockServer.set("/v1/messages", %{
      "content" => [%{"type" => "text", "text" => "ok"}],
      "stop_reason" => "end_turn"
    })

    llm = %{
      "protocol" => "anthropic",
      "base_url" => base,
      "auth_token_env" => "SALIX_TEST_AUTH_TOKEN"
    }

    {:final, "ok"} = Provider.complete([%{role: "user", content: "hi"}], [], llm)

    assert MockServer.last().headers["authorization"] == "Bearer env-token-123"
    refute Map.has_key?(MockServer.last().headers, "x-api-key")
  end

  defp metric_line(scrape, metric, labels) do
    Enum.find(String.split(scrape, "\n"), fn line ->
      String.starts_with?(line, metric <> "{") and
        Enum.all?(labels, fn {key, value} -> line =~ ~s(#{key}="#{value}") end)
    end)
  end

  defp assert_transport_timeout(result, provider) do
    assert {:error,
            %{
              "category" => "transport_error",
              "provider" => ^provider,
              "reason" => reason,
              "retryable" => true
            }} = result

    assert String.contains?(String.downcase(reason), "timeout")
  end

  defp recorder do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    on_delta = fn text -> Agent.update(rec, &[text | &1]) end
    {rec, on_delta}
  end

  defp deltas(rec), do: rec |> Agent.get(& &1) |> Enum.reverse()
end
