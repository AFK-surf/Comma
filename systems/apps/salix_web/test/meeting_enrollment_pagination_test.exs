defmodule Salix.Bindings.MeetingEnrollmentPaginationTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingEnrollment
  alias Salix.Control.ComposioSettings
  alias SalixStore.{Ids, Keys}

  @proxy_session_path "/api/v3.1/tool_router/session"
  @proxy_execute_path "/api/v3.1/tool_router/session/trs-enrollment-pagination/proxy_execute"

  defmodule MockExternalHTTP do
    @moduledoc false
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

    def stub(method, path, key, body, status \\ 200) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:responses, {method, path, key}], {status, body})
      end)
    end

    def requests,
      do: Agent.get(__MODULE__, & &1.requests)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      body =
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      key = response_key(conn.request_path, conn.query_params, body)

      Agent.update(__MODULE__, fn state ->
        request = %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_params,
          body: body
        }

        %{state | requests: state.requests ++ [request]}
      end)

      {status, response} =
        Agent.get(__MODULE__, & &1.responses[{conn.method, conn.request_path, key}]) ||
          {404, %{"error" => %{"message" => "no stub for #{conn.request_path} #{inspect(key)}"}}}

      response = if is_function(response, 1), do: response.(body), else: response

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end

    defp response_key("/api/v3/connected_accounts", query, _body),
      do: query["cursor"] || ""

    defp response_key("/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", _query, body),
      do:
        {body["connected_account_id"],
         get_in(body, ["arguments", "page_token"]) ||
           get_in(body, ["arguments", "pageToken"]) || ""}

    defp response_key(_path, _query, _body), do: ""
  end

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      composio_url: Application.get_env(:salix_store, :composio_base_url_override),
      slack_url: Application.get_env(:salix_im, :slack_api_base_url)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    start_supervised!(MockExternalHTTP)
    port = start_bandit_retry!()
    base_url = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_store, :composio_base_url_override, base_url)
    Application.put_env(:salix_im, :slack_api_base_url, base_url <> "/api")

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, _} =
             SalixStore.S3.put(
               Keys.ctl_group(group_id),
               Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant_id}),
               if_none_match: "*"
             )

    assert {:ok, _settings} = ComposioSettings.put(tenant_id, %{"api_key" => "ck-test"})
    seed_connect(tenant_id, group_id)
    stub_channel()

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_store, :composio_base_url_override, previous.composio_url)
      restore_env(:salix_im, :slack_api_base_url, previous.slack_url)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  test "selects a calendar found only on a later connected-account page", %{group_id: group_id} do
    stub_accounts("", [account("ca-1", group_id)], "accounts-page-2")
    stub_accounts("accounts-page-2", [account("ca-2", group_id)], nil)
    stub_calendars("ca-1", "", [%{"id" => "other", "summary" => "Other"}], nil)
    stub_calendars("ca-2", "", [%{"id" => "comma", "summary" => "Comma Event"}], nil)
    stub_source_lifecycle(group_id, "ca-2")

    assert {:ok, resolved} = MeetingEnrollment.resolve(entry())

    assert [
             %{
               "account_id" => "ca-2",
               "calendar_id" => "comma",
               "source_id" => source_id,
               "time_zone" => "UTC"
             }
           ] = resolved["calendars"]

    assert Ids.valid_calendar_source_id?(source_id)

    account_requests =
      Enum.filter(MockExternalHTTP.requests(), &(&1.path == "/api/v3/connected_accounts"))

    assert Enum.map(account_requests, & &1.query["cursor"]) == [nil, "accounts-page-2"]
  end

  test "a duplicate name on a later calendar page remains ambiguous", %{group_id: group_id} do
    stub_accounts("", [account("ca-1", group_id)], nil)

    stub_calendars(
      "ca-1",
      "",
      [%{"id" => "comma-a", "summary" => "Comma Event"}],
      "calendars-page-2"
    )

    stub_calendars(
      "ca-1",
      "calendars-page-2",
      [%{"id" => "comma-b", "summary" => "Comma Event"}],
      nil
    )

    assert {:error, {:calendar_ambiguous, "Comma Event"}} = MeetingEnrollment.resolve(entry())

    calendar_requests =
      Enum.filter(
        MockExternalHTTP.requests(),
        &(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS")
      )

    assert Enum.map(calendar_requests, &get_in(&1, [:body, "arguments", "page_token"])) == [
             nil,
             "calendars-page-2"
           ]
  end

  test "foreign accounts are rejected before their calendar catalog is read", %{
    group_id: group_id
  } do
    stub_accounts("", [account("ca-foreign", group_id <> "-other")], nil)

    assert {:error, :calendar_enrollment_no_active_account} = MeetingEnrollment.resolve(entry())

    refute Enum.any?(MockExternalHTTP.requests(), fn request ->
             request.path == "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS"
           end)
  end

  test "too many active accounts fail before any calendar tool call", %{group_id: group_id} do
    accounts = Enum.map(1..11, &account("ca-#{&1}", group_id))
    stub_accounts("", accounts, nil)

    assert {:error, :calendar_enrollment_too_many_active_accounts} =
             MeetingEnrollment.resolve(entry())

    refute Enum.any?(MockExternalHTTP.requests(), fn request ->
             request.path == "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS"
           end)
  end

  test "calendar page budget is shared across all active accounts", %{group_id: group_id} do
    stub_accounts("", [account("ca-1", group_id), account("ca-2", group_id)], nil)

    Enum.each(0..5, fn index ->
      token = if index == 0, do: "", else: "ca-1-page-#{index}"
      next_token = if index == 5, do: nil, else: "ca-1-page-#{index + 1}"
      stub_calendars("ca-1", token, [], next_token)
    end)

    Enum.each(0..3, fn index ->
      token = if index == 0, do: "", else: "ca-2-page-#{index}"
      stub_calendars("ca-2", token, [], "ca-2-page-#{index + 1}")
    end)

    assert {:error, {:calendar_enrollment_list, :page_limit_exceeded}} =
             MeetingEnrollment.resolve(entry())

    calendar_requests =
      Enum.filter(
        MockExternalHTTP.requests(),
        &(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS")
      )

    assert length(calendar_requests) == 10
  end

  test "calendar discovery fails closed at the finite page budget", %{group_id: group_id} do
    stub_accounts("", [account("ca-1", group_id)], nil)

    Enum.each(0..9, fn index ->
      token = if index == 0, do: "", else: "calendar-page-#{index}"
      next_token = "calendar-page-#{index + 1}"

      stub_calendars(
        "ca-1",
        token,
        [%{"id" => "calendar-#{index}", "summary" => "Other #{index}"}],
        next_token
      )
    end)

    assert {:error, {:calendar_enrollment_list, :page_limit_exceeded}} =
             MeetingEnrollment.resolve(entry())

    calendar_requests =
      Enum.filter(
        MockExternalHTTP.requests(),
        &(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS")
      )

    assert length(calendar_requests) == 10
    refute Enum.any?(MockExternalHTTP.requests(), &(&1.path == "/api/conversations.list"))
  end

  defp entry do
    %{"connect_id" => "slack-primary", "channel" => "#botarena", "calendars" => ["Comma Event"]}
  end

  defp seed_connect(tenant_id, group_id) do
    record = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "slack-primary",
      "provider" => "slack",
      "workspace_id" => "T-primary",
      "workspace_name" => "primary",
      "bot_token" => "xoxb-test",
      "oauth_completed_at" => 1,
      "created_at" => 100,
      "updated_at" => 100
    }

    assert {:ok, _record} =
             SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, "slack-primary"), record)
  end

  defp stub_accounts(cursor, accounts, next_cursor) do
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts", cursor, %{
      "items" => accounts,
      "next_cursor" => next_cursor
    })
  end

  defp stub_calendars(account_id, page_token, calendars, next_page_token) do
    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      {account_id, page_token},
      %{
        "successful" => true,
        "data" => %{"calendars" => calendars, "next_page_token" => next_page_token}
      }
    )
  end

  defp stub_channel do
    MockExternalHTTP.stub("POST", "/api/conversations.list", "", %{
      "ok" => true,
      "channels" => [%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}]
    })
  end

  defp stub_source_lifecycle(group_id, account_id) do
    MockExternalHTTP.stub(
      "GET",
      "/api/v3/connected_accounts/#{account_id}",
      "",
      account(account_id, group_id)
    )

    MockExternalHTTP.stub(
      "POST",
      @proxy_session_path,
      "",
      %{"session_id" => "trs-enrollment-pagination", "config" => %{}},
      201
    )

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      "",
      &calendar_proxy_response/1
    )

    MockExternalHTTP.stub(
      "DELETE",
      @proxy_session_path <> "/trs-enrollment-pagination",
      "",
      %{"session_id" => "trs-enrollment-pagination", "deleted" => true}
    )

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
      "",
      fn body ->
        %{
          "successful" => true,
          "data" => %{
            "id" => get_in(body, ["arguments", "id"]),
            "resourceId" => "resource-#{account_id}",
            "expiration" => System.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1_000
          }
        }
      end
    )

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_LIST",
      "",
      %{"successful" => true, "data" => %{"items" => [], "nextSyncToken" => "sync-1"}}
    )
  end

  defp calendar_proxy_response(request) do
    endpoint = request["endpoint"] || ""

    if String.ends_with?(endpoint, "/events") do
      %{"status" => 200, "data" => %{"items" => [], "nextSyncToken" => "sync-1"}}
    else
      [calendar_id] =
        Regex.run(~r{/calendars/([^/]+)$}, endpoint, capture: :all_but_first)

      %{
        "status" => 200,
        "data" => %{
          "id" => URI.decode(calendar_id),
          "summary" => "Comma Event",
          "timeZone" => "UTC"
        }
      }
    end
  end

  defp account(id, user_id) do
    %{
      "id" => id,
      "user_id" => user_id,
      "status" => "ACTIVE",
      "toolkit" => %{"slug" => "googlecalendar"}
    }
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(
             {Bandit, plug: MockExternalHTTP, port: port, ip: {127, 0, 0, 1}},
             id: {:meeting_enrollment_pagination_bandit, port}
           ) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind meeting enrollment pagination server"
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
