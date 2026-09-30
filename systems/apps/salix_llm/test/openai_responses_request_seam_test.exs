defmodule SalixLlm.OpenAIResponsesRequestSeamTest do
  use ExUnit.Case, async: false

  alias SalixLlm.Provider

  defmodule MockServer do
    import Plug.Conn
    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(fn ->
          %{count: 0, raw_bodies: [], paths: [], response: nil, redirect?: false}
        end)

    def count(server), do: Agent.get(server, & &1.count)
    def raw_bodies(server), do: Agent.get(server, &Enum.reverse(&1.raw_bodies))
    def paths(server), do: Agent.get(server, &Enum.reverse(&1.paths))
    def set_response(server, response), do: Agent.update(server, &%{&1 | response: response})
    def enable_redirect(server), do: Agent.update(server, &%{&1 | redirect?: true})
    def init(server), do: server

    def call(conn, server) do
      {:ok, raw_body, conn} = read_body(conn)

      {count, response, redirect?} =
        Agent.get_and_update(server, fn state ->
          count = state.count + 1

          {{count, state.response, state.redirect?},
           %{
             state
             | count: count,
               raw_bodies: [raw_body | state.raw_bodies],
               paths: [conn.request_path | state.paths]
           }}
        end)

      if redirect? and conn.request_path == "/responses" do
        conn
        |> put_resp_header("location", "/redirected")
        |> send_resp(307, "")
      else
        {status, body} =
          case response do
            nil when count == 1 ->
              {500, %{"error" => %{"message" => "temporary"}}}

            nil ->
              success_response("retried")

            configured ->
              configured
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    end

    def success_response(text) do
      {200,
       %{
         "output" => [
           %{
             "type" => "message",
             "content" => [%{"type" => "output_text", "text" => text}]
           }
         ]
       }}
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    server = start_supervised!({MockServer, []})

    bandit =
      start_supervised!(
        {Bandit, plug: {MockServer, server}, port: 0, startup_log: false},
        id: :openai_responses_request_seam_server
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, server: server, base_url: "http://127.0.0.1:#{port}"}
  end

  test "resident Responses requests preserve history prefixes through HTTP transport", %{
    server: server,
    base_url: base_url
  } do
    alias SalixVerifiedKernel.Session
    MockServer.set_response(server, MockServer.success_response("ok"))

    opts = %{
      "protocol" => "responses",
      "model" => "test",
      "base_url" => base_url,
      "api_key" => "test",
      :transport_retry => false
    }

    {protocol, cfg} = Provider.request_config(opts)
    initial = Session.new("cache-agent", "cache-session") |> Session.export()

    catalog =
      Session.query(Session.open(initial), :provider_request_part, {:turn_reminder_catalog})

    user = %{id: 1, role: "user", content: "A stable user request"}

    assistant = %{
      id: 2,
      role: "assistant",
      content: "",
      tool_calls: [%{id: "read-1", name: "read", args: %{}}]
    }

    result = %{id: 3, role: "tool", tool_call_id: "read-1", content: "Stable read result"}

    histories = [
      [user],
      [user, assistant, result],
      [user, assistant, result, %{id: 4, role: "user", content: "Continue"}]
    ]

    bodies =
      for history <- histories do
        state =
          initial
          |> Map.merge(%{
            system_prompt: "Stable prompt\n\n" <> catalog,
            messages: history,
            provider_reply_obligations: %{"target" => %{"provider" => "slack", "channel" => "C1"}}
          })
          |> Session.open()

        body =
          Session.query(
            state,
            :provider_dispatch,
            {nil, false, nil, %{}, false, protocol, cfg, [], "complete"}
          )

        assert {:final, "ok"} =
                 Provider.complete({:encoded_provider_request, protocol, body}, [], opts)

        body
      end

    assert MockServer.raw_bodies(server) == bodies
    [first, second, third] = Enum.map(bodies, &Jason.decode!/1)
    assert first["instructions"] == second["instructions"]
    assert second["instructions"] == third["instructions"]
    assert Enum.drop(first["input"], -1) == Enum.take(second["input"], 1)
    assert Enum.drop(second["input"], -1) == Enum.take(third["input"], 3)
    assert Enum.at(second["input"], 2)["type"] == "function_call_output"
    assert Enum.at(third["input"], 3)["role"] == "user"
    assert Enum.all?([first, second, third], &(List.last(&1["input"])["role"] == "developer"))
  end

  test "blocking and streaming preserve reported usage and actual model", %{
    server: server,
    base_url: base_url
  } do
    {200, body} = MockServer.success_response("ok")

    opts = %{
      "protocol" => "responses",
      "model" => "gpt-requested",
      "base_url" => base_url,
      "api_key" => "test",
      :transport_retry => false
    }

    for usage <- [
          nil,
          %{
            "input_tokens" => 100,
            "output_tokens" => 40,
            "input_tokens_details" => %{"cached_tokens" => 0},
            "output_tokens_details" => %{"reasoning_tokens" => 30}
          }
        ] do
      MockServer.set_response(
        server,
        {200, Map.merge(body, %{"model" => "gpt-returned", "usage" => usage})}
      )

      for result <- [
            Provider.complete([%{role: "user", content: "hello"}], [], opts),
            Provider.complete_stream(
              [%{role: "user", content: "hello"}],
              [],
              fn _ -> :ok end,
              opts
            )
          ] do
        if usage do
          meta = elem(result, tuple_size(result) - 1)
          assert meta["model"] == "gpt-returned"
          assert meta["usage"]["usage_reported"]
          assert meta["usage"]["reasoning_tokens"] == 30
          assert meta["usage"]["cache_read_tokens_reported"]
        else
          assert {:final, "ok"} = result
        end
      end
    end
  end

  test "transport_retry false sends a transient Responses failure exactly once", %{
    server: server,
    base_url: base_url
  } do
    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false
    }

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "openai_responses",
              "status" => 500
            }} = Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert MockServer.count(server) == 1
  end

  test "Responses never follows a redirect with the observed POST body", %{
    server: server,
    base_url: base_url
  } do
    MockServer.enable_redirect(server)

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false
    }

    assert {:error, %{"provider" => "openai_responses", "status" => 307}} =
             Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert MockServer.paths(server) == ["/responses"]
    assert MockServer.count(server) == 1
  end

  test "before_send observes the exact JSON bytes sent to OpenAI Responses", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_response(server, MockServer.success_response("ok"))
    owner = self()

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false,
      :before_send => fn body ->
        send(owner, {:observed_body, body})
        :ok
      end
    }

    assert {:final, "ok"} =
             Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert_receive {:observed_body, observed_body}, 100
    assert [sent_body] = MockServer.raw_bodies(server)
    assert observed_body == sent_body
    assert %{"model" => "gpt-test", "input" => [_]} = Jason.decode!(observed_body)
  end

  test "Responses maps the request-scoped strict schema to text.format", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_response(server, MockServer.success_response(~s({"action":"silence"})))

    response_format = %{
      "type" => "json_schema",
      "name" => "comma_triage_decision_v1",
      "strict" => true,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["action"],
        "properties" => %{"action" => %{"type" => "string", "enum" => ["silence"]}}
      }
    }

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      "response_format" => response_format,
      :transport_retry => false
    }

    assert {:final, ~s({"action":"silence"})} =
             Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert [sent_body] = MockServer.raw_bodies(server)
    assert %{"text" => %{"format" => ^response_format}} = Jason.decode!(sent_body)
  end

  test "invalid UTF-8 in transcript text is scrubbed instead of killing the request", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_response(server, MockServer.success_response("ok"))
    truncated = binary_part("接入", 0, 4)

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false
    }

    assert {:final, "ok"} =
             Provider.complete([%{role: "user", content: "把我的电脑 " <> truncated}], [], llm_opts)

    assert [sent_body] = MockServer.raw_bodies(server)
    assert String.valid?(sent_body)
    assert Jason.encode!(Jason.decode!(sent_body)["input"]) =~ "把我的电脑 接�"
  end

  test "invalid UTF-8 in replayed function-call args is scrubbed before the converter encodes them",
       %{server: server, base_url: base_url} do
    MockServer.set_response(server, MockServer.success_response("ok"))
    truncated = binary_part("接入", 0, 4)

    messages = [
      %{role: "user", content: "look this up"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{"id" => "call_1", "name" => "lookup", "args" => %{"query" => "把我的电脑 " <> truncated}}
        ]
      },
      %{role: "tool", tool_call_id: "call_1", content: "done"},
      %{role: "user", content: "and now?"}
    ]

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false
    }

    assert {:final, "ok"} = Provider.complete(messages, [], llm_opts)

    assert [sent_body] = MockServer.raw_bodies(server)
    assert String.valid?(sent_body)

    call_item =
      sent_body
      |> Jason.decode!()
      |> Map.fetch!("input")
      |> Enum.find(&(&1["type"] == "function_call"))

    assert Jason.decode!(call_item["arguments"])["query"] == "把我的电脑 接�"
  end

  test "provider-unsafe Chat function history is projected before a Responses request is sent",
       %{server: server, base_url: base_url} do
    MockServer.set_response(server, MockServer.success_response("ok"))

    messages = [
      %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{
            "id" => "legacy-call",
            "name" => "im_api.internal.read_conversation",
            "args" => %{"repair_context" => "redacted"}
          }
        ]
      },
      %{role: "tool", tool_call_id: "legacy-call", content: ~s({"status":"resolved"})},
      %{role: "user", content: "continue"}
    ]

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key",
      :transport_retry => false
    }

    assert {:final, "ok"} = Provider.complete(messages, [], llm_opts)

    assert [sent_body] = MockServer.raw_bodies(server)
    input = Jason.decode!(sent_body)["input"]

    refute Enum.any?(input, &(&1["type"] in ["function_call", "function_call_output"]))

    assert Enum.any?(input, fn item ->
             item["role"] == "system" and
               item["content"] =~ "im_api.internal.read_conversation"
           end)
  end
end
