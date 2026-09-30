defmodule SalixStore.ComposioTest do
  @moduledoc """
  Composio v3/v3.1 REST client: auth-config resolution (existing vs created
  managed), connect-link creation, connected-account list/get/delete, tool
  catalog search, tool execution, and authenticated provider proxying — driven through a Bandit/Plug mock API
  via the `:composio_base_url_override` seam. Covers header/body wire shapes,
  error-envelope mapping, and 404 handling.
  """
  use ExUnit.Case, async: false

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
            Process.sleep(milliseconds)
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
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

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

    prev = Application.get_env(:salix_store, :composio_base_url_override)
    Application.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:salix_store, :composio_base_url_override)
        val -> Application.put_env(:salix_store, :composio_base_url_override, val)
      end
    end)

    :ok
  end

  test "account discovery rejects a malformed success instead of reporting disconnection" do
    MockComposio.stub("GET", "/api/v3/connected_accounts", %{"unexpected" => []})

    assert {:error, :invalid_connected_accounts_response} =
             Composio.list_connected_accounts(@settings, "group")
  end

  test "account management does not retry a provider outage inside the install transaction" do
    MockComposio.stub(
      "GET",
      "/api/v3/connected_accounts",
      %{"error" => %{"message" => "unavailable"}},
      503
    )

    assert {:error, _} = Composio.list_connected_accounts(@settings, "group")
    assert length(MockComposio.requests("/api/v3/connected_accounts")) == 1
  end

  test "account management returns a timeout when the provider stalls" do
    MockComposio.stub("GET", "/api/v3/connected_accounts", {:delay, 9_000, %{"items" => []}})
    started = System.monotonic_time(:millisecond)
    assert {:error, message} = Composio.list_connected_accounts(@settings, "group")
    assert message =~ "timeout"
    assert System.monotonic_time(:millisecond) - started < 12_000
    assert length(MockComposio.requests("/api/v3/connected_accounts")) == 1
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

  test "ensure_auth_config creates a managed config when none exist" do
    MockComposio.stub("GET", "/api/v3/auth_configs", %{"items" => []})

    MockComposio.stub(
      "POST",
      "/api/v3/auth_configs",
      %{"auth_config" => %{"id" => "ac_new"}},
      201
    )

    assert {:ok, "ac_new"} = Composio.ensure_auth_config(@settings, "gmail")

    [_, create] = MockComposio.requests("/api/v3/auth_configs")
    assert create.method == "POST"
    assert create.body["toolkit"] == %{"slug" => "gmail"}
    assert create.body["auth_config"] == %{"type" => "use_composio_managed_auth"}
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

  test "create_connect_link omits a blank callback_url" do
    MockComposio.stub("POST", "/api/v3/connected_accounts/link", %{"redirect_url" => "u"}, 201)

    assert {:ok, _} = Composio.create_connect_link(@settings, "ac_live", "grp_1")

    [req] = MockComposio.requests("/api/v3/connected_accounts/link")
    refute Map.has_key?(req.body, "callback_url")
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

  test "list_connected_accounts_all follows cursors within an explicit page budget" do
    MockComposio.stub_query(
      "GET",
      "/api/v3/connected_accounts",
      %{"user_ids" => "grp_1", "limit" => "1"},
      %{"items" => [%{"id" => "ca_1"}], "next_cursor" => "cursor-2"}
    )

    MockComposio.stub_query(
      "GET",
      "/api/v3/connected_accounts",
      %{"user_ids" => "grp_1", "limit" => "1", "cursor" => "cursor-2"},
      %{"items" => [%{"id" => "ca_2"}], "next_cursor" => nil}
    )

    assert {:ok, [%{"id" => "ca_1"}, %{"id" => "ca_2"}]} =
             Composio.list_connected_accounts_all(@settings, "grp_1",
               page_limit: 1,
               max_pages: 2
             )

    assert length(MockComposio.requests("/api/v3/connected_accounts")) == 2
  end

  test "list_connected_accounts_all fails closed when a cursor exceeds the page budget" do
    MockComposio.stub_query(
      "GET",
      "/api/v3/connected_accounts",
      %{"user_ids" => "grp_1", "limit" => "1"},
      %{"items" => [%{"id" => "ca_1"}], "next_cursor" => "cursor-2"}
    )

    assert {:error, :connected_accounts_page_limit_exceeded} =
             Composio.list_connected_accounts_all(@settings, "grp_1",
               page_limit: 1,
               max_pages: 1
             )

    assert length(MockComposio.requests("/api/v3/connected_accounts")) == 1
  end

  test "list_connected_accounts_all fails closed on a malformed later page" do
    MockComposio.stub_query(
      "GET",
      "/api/v3/connected_accounts",
      %{"user_ids" => "grp_1", "limit" => "1"},
      %{"items" => [%{"id" => "ca_1"}], "next_cursor" => "cursor-2"}
    )

    MockComposio.stub_query(
      "GET",
      "/api/v3/connected_accounts",
      %{"user_ids" => "grp_1", "limit" => "1", "cursor" => "cursor-2"},
      %{"unexpected" => "shape"}
    )

    assert {:error, :invalid_connected_accounts_page} =
             Composio.list_connected_accounts_all(@settings, "grp_1",
               page_limit: 1,
               max_pages: 2
             )

    assert length(MockComposio.requests("/api/v3/connected_accounts")) == 2
  end

  test "structured error mode preserves connected-account HTTP retryability" do
    MockComposio.stub(
      "GET",
      "/api/v3/connected_accounts",
      %{"error" => %{"message" => "quota exceeded"}},
      429
    )

    assert {:error, {:http, 429}} =
             Composio.list_connected_accounts_all(@settings, "grp_1", error_mode: :structured)
  end

  test "structured error mode preserves connected-account transport retryability" do
    Application.put_env(
      :salix_store,
      :composio_base_url_override,
      "http://127.0.0.1:1"
    )

    assert {:error, {:transport, :econnrefused}} =
             Composio.list_connected_accounts_all(@settings, "grp_1", error_mode: :structured)
  end

  test "get_connected_account maps 404 to :not_found" do
    assert {:error, :not_found} = Composio.get_connected_account(@settings, "ca_missing")
  end

  test "delete_connected_account is :ok on success and on 404" do
    MockComposio.stub("DELETE", "/api/v3/connected_accounts/ca_1", %{"success" => true})

    assert :ok = Composio.delete_connected_account(@settings, "ca_1")
    assert :ok = Composio.delete_connected_account(@settings, "ca_gone")
  end

  test "list_toolkits passes search filters and unwraps items" do
    MockComposio.stub("GET", "/api/v3/toolkits", %{
      "items" => [%{"slug" => "googlecalendar", "name" => "Google Calendar"}]
    })

    assert {:ok, [%{"slug" => "googlecalendar"}]} =
             Composio.list_toolkits(@settings, search: "calendar", limit: 10)

    [req] = MockComposio.requests("/api/v3/toolkits")
    assert req.query == %{"search" => "calendar", "limit" => "10"}
  end

  # ---- tools ----

  test "list_tools passes catalog filters" do
    MockComposio.stub("GET", "/api/v3/tools", %{
      "items" => [%{"slug" => "GMAIL_FETCH_EMAILS", "name" => "Fetch emails"}]
    })

    assert {:ok, [%{"slug" => "GMAIL_FETCH_EMAILS"}]} =
             Composio.list_tools(@settings, toolkit: "gmail", query: "fetch", limit: 5)

    [req] = MockComposio.requests("/api/v3/tools")
    assert req.query == %{"toolkit_slug" => "gmail", "query" => "fetch", "limit" => "5"}
  end

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

  test "execute_tool keeps provider-level failure as {:ok, envelope}" do
    MockComposio.stub("POST", "/api/v3/tools/execute/GMAIL_FETCH_EMAILS", %{
      "data" => %{},
      "successful" => false,
      "error" => "insufficient scopes"
    })

    assert {:ok, %{"successful" => false, "error" => "insufficient scopes"}} =
             Composio.execute_tool(@settings, "GMAIL_FETCH_EMAILS", "grp_1", %{})
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

  test "proxy_execute preserves the native provider status and query wire shape" do
    MockComposio.stub(
      "POST",
      "/api/v3.1/tool_router/session/trs_1/proxy_execute",
      %{
        "status" => 410,
        "data" => %{"error" => %{"code" => 410, "message" => "sync token expired"}},
        "headers" => %{"content-type" => "application/json"}
      }
    )

    request = %{
      "toolkit_slug" => "googlecalendar",
      "endpoint" => "https://www.googleapis.com/calendar/v3/calendars/calendar/events",
      "method" => "GET",
      "parameters" => [
        %{"name" => "showDeleted", "type" => "query", "value" => "true"},
        %{"name" => "syncToken", "type" => "query", "value" => "sync-1"}
      ]
    }

    assert {:ok, %{"status" => 410, "data" => %{"error" => %{"code" => 410}}}} =
             Composio.proxy_execute(@settings, "trs_1", request)

    [sent] = MockComposio.requests("/api/v3.1/tool_router/session/trs_1/proxy_execute")
    assert sent.body == request
  end

  test "bounded proxy reads reject oversized bodies without returning partial mail" do
    MockComposio.stub("POST", "/api/v3.1/tool_router/session/trs_1/proxy_execute", %{
      "status" => 200,
      "data" => %{"body" => String.duplicate("x", 2048)}
    })

    assert {:error, :response_too_large} =
             Composio.proxy_execute(
               @settings,
               "trs_1",
               %{
                 "method" => "GET",
                 "endpoint" => "https://gmail.googleapis.com/gmail/v1/users/me/profile"
               },
               max_response_bytes: 512,
               error_mode: :structured
             )

    assert length(MockComposio.requests("/api/v3.1/tool_router/session/trs_1/proxy_execute")) == 1
  end

  test "structured Tool Router calls preserve redacted HTTP and transport failures" do
    MockComposio.stub(
      "POST",
      "/api/v3.1/tool_router/session",
      %{"error" => %{"message" => "temporary proxy outage"}},
      503
    )

    assert {:error, {:http, 503}} =
             Composio.create_proxy_session(
               @settings,
               "grp_1",
               "ca_calendar",
               "googlecalendar",
               error_mode: :structured
             )

    Application.put_env(
      :salix_store,
      :composio_base_url_override,
      "http://127.0.0.1:1"
    )

    assert {:error, {:transport, :econnrefused}} =
             Composio.proxy_execute(@settings, "trs_1", %{}, error_mode: :structured)
  end

  test "delete_proxy_session is idempotent" do
    MockComposio.stub(
      "DELETE",
      "/api/v3.1/tool_router/session/trs_1",
      %{"session_id" => "trs_1", "deleted" => true}
    )

    assert :ok = Composio.delete_proxy_session(@settings, "trs_1")
    assert :ok = Composio.delete_proxy_session(@settings, "already-gone")
  end

  # ---- error mapping ----

  test "non-2xx responses surface the error envelope message" do
    MockComposio.stub(
      "POST",
      "/api/v3/tools/execute/GMAIL_FETCH_EMAILS",
      %{"error" => %{"message" => "invalid api key"}},
      401
    )

    assert {:error, message} =
             Composio.execute_tool(@settings, "GMAIL_FETCH_EMAILS", "grp_1", %{})

    assert message =~ "HTTP 401"
    assert message =~ "invalid api key"
  end

  test "a blank api key fails before any request" do
    assert {:error, message} = Composio.list_connected_accounts(%{"api_key" => "  "}, "grp_1")
    assert message =~ "api_key is not configured"
  end
end
