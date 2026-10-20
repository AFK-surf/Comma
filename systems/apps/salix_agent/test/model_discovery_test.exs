defmodule SalixAgent.ModelDiscoveryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.ModelDiscovery

  defmodule Provider do
    import Plug.Conn
    def init(state), do: state

    def call(conn, state) do
      conn = fetch_query_params(conn)

      mode =
        Agent.get_and_update(state, fn s ->
          {s.mode,
           %{s | calls: [{conn.request_path, conn.query_params, conn.req_headers} | s.calls]}}
        end)

      case mode do
        :slow ->
          conn =
            conn
            |> put_resp_header("connection", "close")
            |> put_resp_content_type("application/json")
            |> send_chunked(200)

          Enum.reduce_while(1..25, conn, fn _, conn ->
            SystemsClock.sleep(1000)

            case chunk(conn, " ") do
              {:ok, conn} ->
                Agent.update(state, &Map.update!(&1, :chunks, fn count -> count + 1 end))
                {:cont, conn}

              {:error, _} ->
                {:halt, conn}
            end
          end)

        :unauthorized ->
          send_resp(conn, 401, "secret-provider-error")

        :redirect ->
          conn |> put_resp_header("location", "/stolen") |> send_resp(302, "")

        :large ->
          send_resp(conn, 200, String.duplicate("x", 2_000_001))

        :invalid ->
          send_resp(conn, 200, "not json")

        :malformed ->
          json(conn, %{
            "data" => [nil, 12, %{"id" => %{}}, %{"id" => "valid", "capabilities" => [1]}]
          })

        :pages ->
          id = if conn.query_params["after_id"], do: "second", else: "first"

          json(conn, %{
            "data" => [
              %{
                "id" => id,
                "capabilities" => %{
                  "image_input" => %{"supported" => true}
                }
              }
            ],
            "has_more" => id == "first",
            "last_id" => id
          })

        :endless ->
          id = (conn.query_params["after_id"] || "") <> "x"
          json(conn, %{"data" => [%{"id" => id}], "has_more" => true, "last_id" => id})

        _ ->
          json(conn, %{
            "data" => [
              %{"id" => "o3"},
              %{"id" => "custom-model", "name" => "Friendly Model", "owned_by" => "anthropic"},
              %{"id" => "qwen3.8-max", "name" => "Qwen: Custom name"}
            ],
            "api_key" => "should-not-be-returned"
          })
      end
    end

    defp json(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  setup do
    state = start_supervised!({Agent, fn -> %{mode: :normal, calls: [], chunks: 0} end})

    server =
      start_supervised!(
        {Bandit, plug: {Provider, state}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      state: state,
      server: server,
      input: %{"base_url" => "http://127.0.0.1:#{port}/v1", "api_key" => "discovery-secret"}
    }
  end

  test "discovers model choices without returning credentials",
       %{input: input, state: state} do
    assert {:ok, result} = ModelDiscovery.discover(input)
    assert result["protocol"] == "chat_completions"
    assert Enum.map(result["data"], & &1["id"]) == ["o3", "custom-model", "qwen3.8-max"]
    assert Enum.at(result["data"], 1)["name"] == "Friendly Model"
    assert Enum.at(result["data"], 1)["vendor"] == "anthropic"
    assert hd(result["data"])["vendor"] == "openai"
    assert Enum.at(result["data"], 2)["name"] == "Qwen: Custom name"
    assert Enum.at(result["data"], 2)["vendor"] == "qwen"
    refute Jason.encode!(result) =~ "secret"
    refute Map.has_key?(result, "api_key")
    assert [{"/v1/models", %{}, headers}] = Agent.get(state, & &1.calls)
    assert {"authorization", "Bearer discovery-secret"} in headers
  end

  test "bounds response bodies and reports failures without provider content or redirecting keys",
       %{input: input, state: state} do
    for {mode, expected} <- [
          unauthorized: :model_discovery_unauthorized,
          redirect: :model_discovery_unavailable,
          large: :model_discovery_too_large,
          invalid: :model_discovery_invalid_response
        ] do
      Agent.update(state, &%{&1 | mode: mode, calls: []})
      assert {:error, ^expected} = ModelDiscovery.discover(input)
      assert length(Agent.get(state, & &1.calls)) == 1
    end
  end

  test "requires a usable key when one is given, and a plain endpoint", %{
    input: input,
    state: state
  } do
    for changes <- [
          %{"api_key" => "   "},
          %{"base_url" => "https://user:secret@example.com"},
          %{"base_url" => "https://example.com?key=secret"},
          %{"protocol" => "unsupported"}
        ] do
      assert {:error, :invalid_model_configuration} =
               ModelDiscovery.discover(Map.merge(input, changes))
    end

    assert Agent.get(state, & &1.calls) == []

    assert {:ok, %{"protocol" => "anthropic", "base_url" => "https://api.anthropic.com"}} =
             ModelDiscovery.connection(%{
               "base_url" => "https://api.anthropic.com/v1/",
               "api_key" => "key"
             })

    assert {:ok, %{"protocol" => "responses", "base_url" => "https://api.openai.com/v1"}} =
             ModelDiscovery.connection(%{
               "base_url" => "https://api.openai.com",
               "api_key" => "key"
             })
  end
end
