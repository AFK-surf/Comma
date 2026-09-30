defmodule SalixAgent.ModelDiscoveryTest do
  use ExUnit.Case, async: true
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
          conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)

          Enum.reduce_while(1..25, conn, fn _, conn ->
            Process.sleep(1000)

            case chunk(conn, " ") do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
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
    state = start_supervised!({Agent, fn -> %{mode: :normal, calls: []} end})

    server =
      start_supervised!(
        {Bandit, plug: {Provider, state}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      state: state,
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

  test "Anthropic pagination and image metadata share the saved runtime URL", %{
    input: input,
    state: state
  } do
    Agent.update(state, &%{&1 | mode: :pages})
    assert {:ok, result} = ModelDiscovery.discover(Map.put(input, "protocol", "anthropic"))
    refute String.ends_with?(result["base_url"], "/v1")
    assert Enum.map(result["data"], & &1["id"]) == ["first", "second"]
    assert hd(result["data"])["supports_images"] == true
    refute result["truncated"]
    assert length(Agent.get(state, & &1.calls)) == 2

    for {path, _, headers} <- Agent.get(state, & &1.calls) do
      assert path == "/v1/models"
      assert {"x-api-key", "discovery-secret"} in headers
      refute List.keymember?(headers, "authorization", 0)
    end
  end

  test "stops repeated pagination after five requests", %{input: input, state: state} do
    Agent.update(state, &%{&1 | mode: :endless})

    assert {:ok, %{"truncated" => true}} =
             ModelDiscovery.discover(Map.put(input, "protocol", "anthropic"))

    assert length(Agent.get(state, & &1.calls)) == 5
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

  test "ignores malformed model entries", %{input: input, state: state} do
    Agent.update(state, &%{&1 | mode: :malformed})
    assert {:ok, %{"data" => [%{"id" => "valid"}]}} = ModelDiscovery.discover(input)
  end

  test "a slow stream returns an actionable timeout within the overall budget", %{
    input: input,
    state: state
  } do
    Agent.update(state, &%{&1 | mode: :slow})
    started = System.monotonic_time(:millisecond)
    assert {:error, :model_discovery_timeout} = ModelDiscovery.discover(input)
    assert System.monotonic_time(:millisecond) - started < 18_000
    assert length(Agent.get(state, & &1.calls)) == 1
  end

  test "requires a fresh key and a plain endpoint", %{input: input, state: state} do
    for changes <- [
          %{"api_key" => ""},
          %{"base_url" => "https://user:secret@example.com"},
          %{"base_url" => "https://example.com?key=secret"},
          %{"protocol" => "unsupported"},
          %{"template_id" => "foreign"}
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
