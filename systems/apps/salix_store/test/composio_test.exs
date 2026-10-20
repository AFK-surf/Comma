defmodule SalixStore.ComposioTest do
  @moduledoc """
  Composio v3/v3.1 REST client: auth-config resolution (existing vs created
  managed), connect-link creation, connected-account list/get/delete, tool
  catalog search, tool execution, and authenticated provider proxying — driven through a Bandit/Plug mock API
  via the `:composio_base_url_override` seam. Covers header/body wire shapes,
  error-envelope mapping, and 404 handling.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.Composio
  alias __MODULE__.MockComposio

  @settings %{"api_key" => "ck_test", "base_url" => ""}

  test "trigger discovery, scoped pagination and management use the provider wire contract" do
    MockComposio.stub("GET", "/api/v3.1/triggers_types", %{
      "items" => [%{"slug" => "GMAIL_NEW_GMAIL_MESSAGE"}],
      "next_cursor" => "next"
    })

    MockComposio.stub("GET", "/api/v3.1/triggers_types/GMAIL_NEW_GMAIL_MESSAGE", %{
      "config" => %{},
      "payload" => %{}
    })

    MockComposio.stub("GET", "/api/v3.1/trigger_instances/active", %{
      "items" => [],
      "next_cursor" => "page2"
    })

    MockComposio.stub("PATCH", "/api/v3.1/trigger_instances/manage/ti_test", %{
      "status" => "success"
    })

    MockComposio.stub("DELETE", "/api/v3.1/trigger_instances/manage/ti_test", %{
      "status" => "success"
    })

    assert {:ok, %{"next_cursor" => "next"}} = Composio.list_trigger_types(@settings, "gmail")

    assert {:ok, %{"config" => %{}}} =
             Composio.get_trigger_type(@settings, "GMAIL_NEW_GMAIL_MESSAGE")

    assert {:ok, %{"next_cursor" => "page2"}} =
             Composio.list_triggers(@settings, "group-1", cursor: "page1", trigger_id: "ti_test")

    assert [%{query: query}] = MockComposio.requests("/api/v3.1/trigger_instances/active")

    assert query == %{
             "user_ids" => "group-1",
             "limit" => "50",
             "cursor" => "page1",
             "trigger_ids" => "ti_test",
             "show_disabled" => "true"
           }

    for action <- ["enable", "disable", "delete"],
        do: assert({:ok, _} = Composio.manage_trigger(@settings, "group-1", "ti_test", action))

    assert [
             %{body: %{"status" => "enable", "user_id" => "group-1"}},
             %{body: %{"status" => "disable"}},
             %{method: "DELETE"}
           ] = MockComposio.requests("/api/v3.1/trigger_instances/manage/ti_test")
  end

  # ---- mock Composio server ----

  defmodule MockComposio do
    @moduledoc "Plug impersonating the Composio API; canned responses keyed by {method, path}."
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

    def stub(method, path, body, status \\ 200) do
      Agent.update(__MODULE__, fn st ->
        put_in(st, [:responses, {method, path}], {status, body})
      end)
    end

    def stub_query(method, path, query, body, status \\ 200) do
      Agent.update(__MODULE__, fn st ->
        put_in(st, [:responses, {method, path, query}], {status, body})
      end)
    end

    def requests(path),
      do: Agent.get(__MODULE__, & &1.requests) |> Enum.filter(&(&1.path == path))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      body_params =
        case raw do
          "" -> %{}
          _ -> Jason.decode!(raw)
        end

      Agent.update(__MODULE__, fn st ->
        req = %{
          path: conn.request_path,
          method: conn.method,
          query: conn.query_params,
          body: body_params,
          headers: conn.req_headers
        }

        %{st | requests: st.requests ++ [req]}
      end)

      {status, body} =
        Agent.get(__MODULE__, fn st ->
          st.responses[{conn.method, conn.request_path, conn.query_params}] ||
            st.responses[{conn.method, conn.request_path}]
        end) ||
          {404, %{"error" => %{"message" => "no stub for #{conn.method} #{conn.request_path}"}}}

      body =
        case body do
          {:delay, milliseconds, value} ->
            SystemsClock.sleep(milliseconds)
            value

          value ->
            value
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(
             {Bandit, plug: MockComposio, port: p, ip: {127, 0, 0, 1}},
             id: {:bandit_retry, p}
           ) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind mock composio server"
  end

  setup do
    start_supervised!(MockComposio)
    port = start_bandit_retry!()

    prev = SystemsRuntime.get_env(:salix_store, :composio_base_url_override)
    SystemsRuntime.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      case prev do
        nil -> SystemsRuntime.delete_env(:salix_store, :composio_base_url_override)
        val -> SystemsRuntime.put_env(:salix_store, :composio_base_url_override, val)
      end
    end)

    :ok
  end

  # ---- auth configs ----

  test "ensure_auth_config returns the first usable existing config" do
    MockComposio.stub("GET", "/api/v3/auth_configs", %{
      "items" => [
        %{"id" => "ac_disabled", "is_disabled" => true},
        %{"id" => "ac_live", "is_disabled" => false}
      ]
    })

    assert {:ok, "ac_live"} = Composio.ensure_auth_config(@settings, "gmail")

    [req] = MockComposio.requests("/api/v3/auth_configs")
    assert req.query == %{"toolkit_slug" => "gmail"}
    assert {"x-api-key", "ck_test"} in req.headers
  end

  test "Google Admin requires a configured custom OAuth app" do
    MockComposio.stub("GET", "/api/v3/auth_configs", %{"items" => []})

    assert {:error, :google_admin_custom_oauth_required} =
             Composio.ensure_auth_config(@settings, "google_admin")

    assert Enum.map(MockComposio.requests("/api/v3/auth_configs"), & &1.method) == ["GET"]
  end

  # ---- connect links ----

  test "create_connect_link posts auth_config_id/user_id/callback_url" do
    MockComposio.stub(
      "POST",
      "/api/v3/connected_accounts/link",
      %{
        "redirect_url" => "https://connect.composio.dev/link/ln_1",
        "connected_account_id" => "ca_1",
        "expires_at" => "2026-07-05T00:00:00Z"
      },
      201
    )

    assert {:ok, %{"redirect_url" => "https://connect.composio.dev/link/ln_1"}} =
             Composio.create_connect_link(@settings, "ac_live", "grp_1",
               callback_url: "https://comma.example/done"
             )

    [req] = MockComposio.requests("/api/v3/connected_accounts/link")

    assert req.body == %{
             "auth_config_id" => "ac_live",
             "user_id" => "grp_1",
             "callback_url" => "https://comma.example/done"
           }
  end

  # ---- connected accounts ----

  test "list_connected_accounts filters by user id and unwraps items" do
    MockComposio.stub("GET", "/api/v3/connected_accounts", %{
      "items" => [%{"id" => "ca_1", "status" => "ACTIVE"}]
    })

    assert {:ok, [%{"id" => "ca_1"}]} = Composio.list_connected_accounts(@settings, "grp_1")

    [req] = MockComposio.requests("/api/v3/connected_accounts")
    assert req.query == %{"user_ids" => "grp_1"}
  end

  # ---- tools ----

  test "execute_tool posts user_id + arguments and returns the raw envelope" do
    MockComposio.stub("POST", "/api/v3/tools/execute/GMAIL_FETCH_EMAILS", %{
      "data" => %{"messages" => []},
      "successful" => true,
      "error" => nil,
      "log_id" => "log_1"
    })

    assert {:ok, %{"successful" => true, "data" => %{"messages" => []}}} =
             Composio.execute_tool(
               @settings,
               "GMAIL_FETCH_EMAILS",
               "grp_1",
               %{"max_results" => 5},
               connected_account_id: "ca_1",
               version: "20260915_00"
             )

    [req] = MockComposio.requests("/api/v3/tools/execute/GMAIL_FETCH_EMAILS")

    assert req.body == %{
             "user_id" => "grp_1",
             "arguments" => %{"max_results" => 5},
             "connected_account_id" => "ca_1",
             "version" => "20260915_00"
           }
  end

  # ---- authenticated proxy ----

  test "create_proxy_session pins the Google toolkit and connected account" do
    MockComposio.stub(
      "POST",
      "/api/v3.1/tool_router/session",
      %{"session_id" => "trs_1", "config" => %{}},
      201
    )

    assert {:ok, "trs_1"} =
             Composio.create_proxy_session(@settings, "grp_1", "ca_calendar")

    [request] = MockComposio.requests("/api/v3.1/tool_router/session")

    assert request.body == %{
             "user_id" => "grp_1",
             "toolkits" => %{"enable" => ["googlecalendar"]},
             "connected_accounts" => %{"googlecalendar" => ["ca_calendar"]},
             "manage_connections" => %{"enable" => false},
             "workbench" => %{"enable" => false}
           }
  end

  # ---- error mapping ----
end
