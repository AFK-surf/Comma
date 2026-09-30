defmodule SalixLlm.OpenAIChatRequestSeamTest do
  @moduledoc """
  The blocking OpenAI Chat boundary exposes the exact immutable JSON bytes that
  will be sent and lets request-scoped callers disable Req transport retries.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.Provider

  defmodule MockServer do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{requests: [], responses: [], redirect?: false} end)

    def set_responses(server, responses) when is_list(responses) do
      Agent.update(server, &%{&1 | responses: responses})
    end

    def requests(server), do: Agent.get(server, &Enum.reverse(&1.requests))
    def enable_redirect(server), do: Agent.update(server, &%{&1 | redirect?: true})

    def init(server), do: server

    def call(conn, server) do
      {:ok, raw_body, conn} = read_body(conn)

      response =
        Agent.get_and_update(server, fn state ->
          {response, rest} =
            if state.redirect? and conn.request_path == "/chat/completions" do
              {{307, "", [{"location", "/redirected"}]}, state.responses}
            else
              {response, rest} = pop_response(state.responses)
              {{elem(response, 0), elem(response, 1), []}, rest}
            end

          request = %{
            path: conn.request_path,
            headers: Map.new(conn.req_headers),
            raw_body: raw_body
          }

          {response, %{state | requests: [request | state.requests], responses: rest}}
        end)

      {status, body, headers} = response

      conn =
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

      if body == "" do
        send_resp(conn, status, "")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    end

    defp pop_response([response | rest]), do: {response, rest}
    defp pop_response([]), do: {{200, success_body()}, []}

    defp success_body do
      %{"choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}]}
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    server = start_supervised!({MockServer, []})

    bandit =
      start_supervised!(
        {Bandit, plug: {MockServer, server}, port: 0, startup_log: false},
        id: :openai_chat_request_seam_server
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    {:ok, server: server, base_url: "http://127.0.0.1:#{port}"}
  end

  test "before_send observes the exact JSON bytes sent to OpenAI Chat", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_responses(server, [
      {200, %{"choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}]}}
    ])

    owner = self()

    format = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "content",
        "strict" => true,
        "schema" => %{
          "type" => "object",
          "properties" => %{"title" => %{"type" => "string"}},
          "required" => ["title"],
          "additionalProperties" => false
        }
      }
    }

    llm_opts =
      base_opts(base_url)
      |> Map.put("response_format", format)
      |> Map.put(:before_send, fn body ->
        send(owner, {:observed_body, body})
        :ok
      end)

    assert {:final, "ok"} =
             Provider.complete(
               [%{role: "user", content: "hello"}],
               [%{"name" => "lookup", "description" => "Look up a fact", "input_schema" => %{}}],
               llm_opts
             )

    assert_receive {:observed_body, observed_body}, 100
    assert [%{raw_body: sent_body, headers: headers}] = MockServer.requests(server)
    assert observed_body == sent_body
    assert Jason.decode!(sent_body)["response_format"] == format
    assert headers["content-type"] == "application/json"

    assert %{"model" => "gpt-test", "messages" => [_], "tools" => [_]} =
             Jason.decode!(observed_body)
  end

  test "transport_retry false sends a transient failure exactly once", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_responses(server, [
      {500, %{"error" => %{"message" => "temporary"}}},
      {200,
       %{"choices" => [%{"message" => %{"content" => "retried"}, "finish_reason" => "stop"}]}}
    ])

    llm_opts = Map.put(base_opts(base_url), :transport_retry, false)

    assert {:error,
            %{
              "category" => "retryable_provider_error",
              "provider" => "openai_chat",
              "status" => 500
            }} = Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert [_request] = MockServer.requests(server)
  end

  test "Chat Completions never follows a redirect with the observed POST body", %{
    server: server,
    base_url: base_url
  } do
    MockServer.enable_redirect(server)

    assert {:error, %{"provider" => "openai_chat", "status" => 307}} =
             Provider.complete(
               [%{role: "user", content: "hello"}],
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [%{path: "/chat/completions"}] = MockServer.requests(server)
  end

  test "the default path retains transient transport retries", %{
    server: server,
    base_url: base_url
  } do
    MockServer.set_responses(server, [
      {500, %{"error" => %{"message" => "temporary"}}},
      {200,
       %{"choices" => [%{"message" => %{"content" => "retried"}, "finish_reason" => "stop"}]}}
    ])

    assert {:final, "retried"} =
             Provider.complete([%{role: "user", content: "hello"}], [], base_opts(base_url))

    assert [_first_attempt, _retry] = MockServer.requests(server)
  end

  test "before_send rejection fails closed without an HTTP request", %{
    server: server,
    base_url: base_url
  } do
    llm_opts = Map.put(base_opts(base_url), :before_send, fn _body -> {:error, :rejected} end)

    assert {:error,
            %{
              "category" => "configuration_error",
              "provider" => "openai_chat",
              "retryable" => false,
              "reason" => reason
            }} = Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert reason =~ "before_send_rejected"
    assert MockServer.requests(server) == []
  end

  test "before_send exception is a typed failure and sends no HTTP", %{
    server: server,
    base_url: base_url
  } do
    llm_opts =
      Map.put(base_opts(base_url), :before_send, fn _body -> raise "observer failed" end)

    assert {:error,
            %{
              "category" => "configuration_error",
              "provider" => "openai_chat",
              "retryable" => false,
              "reason" => reason
            }} = Provider.complete([%{role: "user", content: "hello"}], [], llm_opts)

    assert reason =~ "before_send_raised"
    assert MockServer.requests(server) == []
  end

  test "invalid UTF-8 in transcript text is scrubbed instead of killing the request", %{
    server: server,
    base_url: base_url
  } do
    truncated = binary_part("接入", 0, 4)

    assert {:final, "ok"} =
             Provider.complete(
               [%{role: "user", content: "把我的电脑 " <> truncated}],
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [%{raw_body: sent_body}] = MockServer.requests(server)
    assert String.valid?(sent_body)
    assert Jason.encode!(Jason.decode!(sent_body)["messages"]) =~ "把我的电脑 接�"
  end

  test "invalid UTF-8 in replayed tool-call args is scrubbed before the converter encodes them",
       %{server: server, base_url: base_url} do
    MockServer.set_responses(server, [
      {200, %{"choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}]}}
    ])

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

    assert {:final, "ok"} =
             Provider.complete(
               messages,
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [%{raw_body: sent_body}] = MockServer.requests(server)
    assert String.valid?(sent_body)

    assistant =
      sent_body
      |> Jason.decode!()
      |> Map.fetch!("messages")
      |> Enum.find(&(&1["role"] == "assistant" and &1["tool_calls"]))

    assert [%{"function" => %{"arguments" => args_json}}] = assistant["tool_calls"]
    assert Jason.decode!(args_json)["query"] == "把我的电脑 接�"
  end

  defp base_opts(base_url) do
    %{
      "protocol" => "chat_completions",
      "model" => "gpt-test",
      "base_url" => base_url,
      "api_key" => "test-key"
    }
  end
end
