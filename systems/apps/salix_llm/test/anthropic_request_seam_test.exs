defmodule SalixLlm.AnthropicRequestSeamTest do
  use ExUnit.Case, async: false

  alias SalixLlm.Provider

  defmodule MockServer do
    @behaviour Plug
    import Plug.Conn
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{requests: [], responses: [], redirect?: false} end)

    def enable_redirect(server), do: Agent.update(server, &%{&1 | redirect?: true})

    @impl true
    def init(server), do: server

    @impl true
    def call(conn, server) do
      {:ok, raw_body, conn} = read_body(conn)

      {status, response, headers} =
        Agent.get_and_update(server, fn %{requests: requests, responses: responses} = state ->
          {{status, response, headers}, rest} =
            if state.redirect? and conn.request_path == "/v1/messages" do
              {{307, "", [{"location", "/redirected"}]}, responses}
            else
              {{status, response}, rest} = pop_response(responses)
              {{status, response, []}, rest}
            end

          request = %{raw_body: raw_body, headers: Map.new(conn.req_headers)}

          {{status, response, headers},
           %{
             state
             | requests: [Map.put(request, :path, conn.request_path) | requests],
               responses: rest
           }}
        end)

      conn =
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

      if response == "" do
        send_resp(conn, status, "")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(response))
      end
    end

    defp pop_response([response | rest]), do: {response, rest}

    defp pop_response([]) do
      {{200, %{"content" => [%{"type" => "text", "text" => "ok"}], "stop_reason" => "end_turn"}},
       []}
    end
  end

  setup do
    server = start_supervised!({MockServer, []})

    bandit =
      start_supervised!(
        {Bandit, plug: {MockServer, server}, port: 0, startup_log: false},
        id: :anthropic_request_seam_server
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, server: server, base_url: "http://127.0.0.1:#{port}"}
  end

  test "before_send observes the exact Anthropic JSON bytes sent", %{
    server: server,
    base_url: base_url
  } do
    owner = self()

    opts =
      base_opts(base_url)
      |> Map.put(:transport_retry, false)
      |> Map.put(:before_send, fn body ->
        send(owner, {:observed_body, body})
        :ok
      end)

    assert {:final, "ok"} = Provider.complete([%{role: "user", content: "hello"}], [], opts)
    assert_receive {:observed_body, observed_body}

    assert [%{raw_body: sent_body, headers: headers}] = requests(server)
    assert observed_body == sent_body
    assert headers["content-type"] == "application/json"
    assert %{"model" => "claude-test", "messages" => [_]} = Jason.decode!(observed_body)
  end

  test "transport_retry false sends a transient Anthropic failure exactly once", %{
    server: server,
    base_url: base_url
  } do
    Agent.update(server, &%{&1 | responses: [{500, %{"error" => "temporary"}}, {200, success()}]})

    assert {:error, %{"provider" => "anthropic", "status" => 500}} =
             Provider.complete(
               [%{role: "user", content: "hello"}],
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [_request] = requests(server)
  end

  test "Anthropic never follows a redirect with the observed POST body", %{
    server: server,
    base_url: base_url
  } do
    MockServer.enable_redirect(server)

    assert {:error, %{"provider" => "anthropic", "status" => 307}} =
             Provider.complete(
               [%{role: "user", content: "hello"}],
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [%{path: "/v1/messages"}] = requests(server)
  end

  test "invalid UTF-8 in transcript text is scrubbed instead of killing the request", %{
    server: server,
    base_url: base_url
  } do
    # Byte-truncated CJK: the corruption shape that used to raise
    # Jason.EncodeError before transport, wedging the session forever.
    truncated = binary_part("接入", 0, 4)

    messages = [
      %{role: "summary", content: "You are an agent. 通过 Slack " <> truncated},
      %{role: "user", content: "把我的电脑 " <> truncated}
    ]

    assert {:final, "ok"} =
             Provider.complete(
               messages,
               [],
               Map.put(base_opts(base_url), :transport_retry, false)
             )

    assert [%{raw_body: sent_body}] = requests(server)
    assert String.valid?(sent_body)
    decoded = Jason.decode!(sent_body)
    assert Jason.encode!(decoded["system"]) =~ "通过 Slack 接�"
    assert Jason.encode!(decoded["messages"]) =~ "接�"
  end

  defp requests(server), do: Agent.get(server, &Enum.reverse(&1.requests))

  defp success do
    %{"content" => [%{"type" => "text", "text" => "retried"}], "stop_reason" => "end_turn"}
  end

  defp base_opts(base_url) do
    %{
      "protocol" => "anthropic",
      "model" => "claude-test",
      "base_url" => base_url,
      "api_key" => "test-key"
    }
  end
end
