defmodule BridgeForTeams.TriageInvestigationTransportsTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.TriageInvestigationTransports, as: Transports
  alias BridgeForTeams.TriageInvestigationTransports.UnavailableError

  @settings [
    {:req, :default_options},
    {:salix_agent, :exa_api_key},
    {:salix_agent, :exa_base_url},
    {:salix_agent, :env_dispatch},
    {:salix_agent, :mcp_provider_mod},
    {:salix_store, :agent_vmm_host_http_client},
    {:bridge_for_teams_core, :triage_investigation_transport_capture}
  ]

  setup do
    previous = snapshot()
    owner = self()

    on_exit(fn -> restore(previous) end)

    adapter = fn request ->
      send(owner, {:original_adapter, request.method, URI.to_string(request.url), request.into})
      response = Req.Response.new(status: 200, body: "ordinary transport")

      if is_function(request.into, 2) do
        {:cont, result} = request.into.({:data, "provider stream"}, {request, response})
        result
      else
        {request, response}
      end
    end

    Req.default_options(adapter: adapter, retry: false, receive_timeout: 1_234)
    :ok
  end

  test "normal search and page-read methods reach the bounded local Exa fixture" do
    owner = self()

    install!(fn request ->
      send(owner, {:exa, request})

      Req.Response.json(%{
        "results" => [
          %{
            "title" => "Fixture source",
            "url" => "https://source.test/report",
            "text" => "Local fact"
          }
        ]
      })
    end)

    assert SalixAgent.Tools.web_search(%{"query" => "investigation question"}, %{}) =~
             "Local fact"

    assert_receive {:exa,
                    %{
                      method: :post,
                      path: "/search",
                      json: %{"query" => "investigation question"}
                    }}

    assert %{"results" => [%{"text" => "Local fact"}]} =
             SalixAgent.Tools.Web.exa_contents(%{"urls" => ["https://source.test/report"]}, %{})
             |> Jason.decode!()

    assert_receive {:exa,
                    %{
                      method: :post,
                      path: "/contents",
                      json: %{"urls" => ["https://source.test/report"]}
                    }}

    assert {:ok, %{status: 200}} =
             Req.request(
               method: :post,
               url: "https://api.exa.ai/search",
               json: %{query: "direct"}
             )

    assert_receive {:exa, %{path: "/search", json: %{"query" => "direct"}}}
    refute_receive {:original_adapter, _, _, _}
  end

  test "selected model endpoints preserve the original adapter and streaming; Slack stays local" do
    install!()

    stream = fn {:data, data}, {request, response} ->
      {:cont, {request, %{response | body: data}}}
    end

    assert {:ok, %{body: "provider stream"}} =
             Req.post("https://router.model.test/v1/responses", json: %{}, into: stream)

    assert_receive {:original_adapter, :post, "https://router.model.test/v1/responses", ^stream}

    assert {:ok, %{body: "ordinary transport"}} =
             Req.post("https://worker.model.test/v1/chat/completions", json: %{})

    assert_receive {:original_adapter, :post, "https://worker.model.test/v1/chat/completions",
                    nil}

    assert {:ok, %{body: "ordinary transport"}} =
             Req.get("http://127.0.0.1:49123/api/conversations.replies")

    assert_receive {:original_adapter, :get, "http://127.0.0.1:49123/api/conversations.replies",
                    nil}
  end

  test "explicit public-web mode passes only real search/contents through the ordinary tool adapter" do
    owner = self()

    Req.default_options(
      adapter: fn request ->
        assert Req.Request.get_header(request, "x-api-key") == ["local-public-web-canary"]
        send(owner, {:public_read, request.method, URI.to_string(request.url)})

        {request,
         Req.Response.json(%{
           "results" => [
             %{
               "title" => "Read source",
               "url" => "https://source.test",
               "text" => "Retrieved body"
             }
           ]
         })}
      end,
      retry: false
    )

    install!(fn _ -> flunk("real web probe must not use frozen results") end,
      live_exa_api_key: "local-public-web-canary",
      capture: &send(owner, {:capture, &1})
    )

    assert SalixAgent.Tools.web_search(%{"query" => "public source question"}, %{}) =~
             "Retrieved body"

    assert_receive {:public_read, :post, "https://api.exa.ai/search"}

    assert SalixAgent.Tools.Web.exa_contents(%{"urls" => ["https://source.test"]}, %{}) =~
             "Retrieved body"

    assert_receive {:public_read, :post, "https://api.exa.ai/contents"}
    assert_receive {:capture, %{disposition: :public_web_read} = event}
    refute inspect(event) =~ "canary"

    for {method, url} <- [
          {:delete, "https://api.exa.ai/contents"},
          {:post, "https://api.exa.ai/websets"},
          {:post, "https://slack.com/api/chat.postMessage"},
          {:post, "https://foreign.test"}
        ] do
      assert {:error, %UnavailableError{}} = Req.request(method: method, url: url, json: %{})
    end

    refute_receive {:public_read, _, _}
  end

  test "foreign destinations, other listener ports and unsupported model operations fail" do
    owner = self()
    install!(fn _ -> {:error, :unseeded_source} end, capture: &send(owner, {:capture, &1}))

    for url <- [
          "https://foreign.test/read?token=private",
          "http://127.0.0.1:49124/api/chat.postMessage",
          "https://router.model.test/v1/unseeded",
          "https://api.exa.ai/unseeded"
        ] do
      assert {:error, %UnavailableError{message: message}} = Req.post(url, json: %{})
      assert message =~ "test fixture unavailable"
      refute message =~ "private"
    end

    assert {:error, %UnavailableError{}} = Req.get("https://router.model.test/v1/responses")
    assert {:error, %UnavailableError{}} = Req.post("https://api.exa.ai/contents", json: %{})
    refute_receive {:original_adapter, _, _, _}

    assert_receive {:capture, event}

    assert event == %{
             surface: :http,
             disposition: :unavailable,
             method: :post,
             origin: "https://foreign.test"
           }
  end

  test "redirects from an allowed endpoint cannot reach a foreign destination" do
    owner = self()

    Req.default_options(
      adapter: fn request ->
        send(owner, :allowed_redirect_request)

        {request,
         Req.Response.new(status: 307, headers: [{"location", "https://foreign.test/redirect"}])}
      end,
      retry: false
    )

    install!()

    assert {:error, %UnavailableError{}} =
             Req.post("https://router.model.test/v1/responses", json: %{})

    assert_receive :allowed_redirect_request
    refute_receive :allowed_redirect_request
  end

  test "the global adapter also applies to ordinary requests from async tool children" do
    owner = self()

    install!(fn request ->
      send(owner, {:child_exa, request.json})
      Req.Response.json(%{"results" => []})
    end)

    assert {:ok, %{status: 200}} =
             Task.async(fn -> Req.post("https://api.exa.ai/search", json: %{query: "child"}) end)
             |> Task.await()

    assert_receive {:child_exa, %{"query" => "child"}}
    refute_receive {:original_adapter, _, _, _}
  end

  test "device, MCP creation/execution and Compute HTTP seams cannot start host work" do
    install!()

    assert {:ok, []} = SalixAgent.EnvDispatch.list_envs("fixture-agent")

    assert {:ok, %{devices: [], next_cursor: nil}} =
             SalixAgent.EnvDispatch.list_devices("fixture-agent", limit: 10)

    for {operation, arity} <- SalixAgent.EnvDispatch.behaviour_info(:callbacks),
        operation not in [:list_envs, :list_devices] do
      assert {:error, {:test_fixture_unavailable, :environment, ^operation}} =
               apply(SalixAgent.EnvDispatch, operation, List.duplicate("unseeded", arity))
    end

    mcp = Application.fetch_env!(:salix_agent, :mcp_provider_mod)
    assert {:ok, []} = mcp.list_bindings("fixture-agent")
    assert {:ok, []} = mcp.dynamic_disclosure_entries("fixture-agent")

    for {operation, arity} <- SalixAgent.Tools.MCP.behaviour_info(:callbacks),
        operation not in [
          :provider_state,
          :dynamic_disclosure_entries,
          :list_bindings,
          :list_definitions
        ] do
      assert {:error, {:test_fixture_unavailable, :mcp, ^operation}} =
               apply(mcp, operation, List.duplicate("unseeded", arity))
    end

    compute = Application.fetch_env!(:salix_store, :agent_vmm_host_http_client)

    assert {:error, {:test_fixture_unavailable, :compute_host, :post}} =
             compute.post("unused", %{})

    assert {:error, {:test_fixture_unavailable, :compute_host, :post_import}} =
             compute.post_import("unused", [])

    refute_receive {:original_adapter, _, _, _}
  end

  test "cleanup restores exact prior configuration, including absent keys and nil values" do
    Application.delete_env(:salix_agent, :exa_base_url)
    Application.put_env(:salix_agent, :mcp_provider_mod, nil)
    previous = snapshot()
    plugin_store = Application.fetch_env(:salix_agent, :plugin_store_mod)
    cleanup = install!()

    assert Req.default_options()[:receive_timeout] == 1_234
    assert Application.fetch_env(:salix_agent, :plugin_store_mod) == plugin_store
    cleanup.()
    assert snapshot() == previous
  end

  defp install!(exa \\ fn _ -> {:error, :unseeded_source} end, opts \\ []) do
    cleanup =
      Transports.install!(
        Keyword.merge(
          [
            llm_base_urls: ["https://router.model.test/v1", "https://worker.model.test/v1"],
            slack_base_url: "http://127.0.0.1:49123/api",
            exa: exa
          ],
          opts
        )
      )

    on_exit(cleanup)
    cleanup
  end

  defp snapshot,
    do: Enum.map(@settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

  defp restore(settings) do
    Enum.each(settings, fn
      {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      {app, key, :error} -> Application.delete_env(app, key)
    end)
  end
end
