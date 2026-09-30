defmodule SalixWeb.LocalOAuthMockTest do
  use ExUnit.Case, async: false

  test "runtime toggle installs and restores the local Composio provider boundary" do
    keys = [
      {:salix_web, :local_oauth_mock},
      {:salix_web, :local_recommendation_mock},
      {:salix_web, :public_base_url},
      {:salix_web, :composio_client_mod},
      {:salix_web, :composio_settings_mod},
      {:salix_agent, :composio_client_mod},
      {:salix_agent, :composio_store_mod},
      {:salix_store, :oauth_endpoint_overrides},
      {:salix_mcp, :remote_target_overrides},
      {:salix_mcp, :private_http_target_allowlist}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(:salix_web, :local_oauth_mock, false)
    Application.put_env(:salix_web, :local_recommendation_mock, false)
    Application.put_env(:salix_web, :public_base_url, "http://127.0.0.1:4000")
    Application.put_env(:salix_store, :oauth_endpoint_overrides, %{"custom" => %{}})
    Application.put_env(:salix_mcp, :remote_target_overrides, %{"custom" => "https://x"})
    Application.put_env(:salix_mcp, :private_http_target_allowlist, ["https://x"])
    Application.put_env(:salix_web, :composio_client_mod, OriginalWebClient)
    Application.put_env(:salix_web, :composio_settings_mod, OriginalWebSettings)
    Application.put_env(:salix_agent, :composio_client_mod, OriginalAgentClient)
    Application.put_env(:salix_agent, :composio_store_mod, OriginalAgentStore)

    on_exit(fn ->
      _ = SalixWeb.LocalOAuthMock.set_enabled(false)
      Enum.each(previous, fn {{app, key}, value} -> restore_env(app, key, value) end)
    end)

    assert %{available: true, enabled: false} = SalixWeb.LocalOAuthMock.status()

    assert {:ok, %{available: true, enabled: true}} =
             SalixWeb.LocalOAuthMock.set_enabled(true)

    assert get_in(
             Application.fetch_env!(:salix_store, :oauth_endpoint_overrides),
             ["github", "authorize_url"]
           ) == "http://127.0.0.1:4000/v1/local-oauth/github/authorize"

    assert Application.fetch_env!(:salix_mcp, :remote_target_overrides)["remote:notion"] ==
             "http://127.0.0.1:4000/v1/local-oauth/mcp/resource"

    assert Application.fetch_env!(:salix_web, :composio_client_mod) ==
             SalixWeb.LocalComposioMock

    assert Application.fetch_env!(:salix_web, :composio_settings_mod) ==
             SalixWeb.LocalComposioMock

    assert Application.fetch_env!(:salix_agent, :composio_client_mod) ==
             SalixWeb.LocalComposioMock

    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-local")

    assert Enum.any?(accounts, &(get_in(&1, ["toolkit", "slug"]) == "linear"))

    assert {:ok, %{available: true, enabled: false}} =
             SalixWeb.LocalOAuthMock.set_enabled(false)

    assert Application.fetch_env!(:salix_store, :oauth_endpoint_overrides) == %{"custom" => %{}}

    assert Application.fetch_env!(:salix_mcp, :remote_target_overrides) == %{
             "custom" => "https://x"
           }

    assert Application.fetch_env!(:salix_mcp, :private_http_target_allowlist) == ["https://x"]

    assert Application.fetch_env!(:salix_web, :composio_client_mod) == OriginalWebClient
    assert Application.fetch_env!(:salix_web, :composio_settings_mod) == OriginalWebSettings
    assert Application.fetch_env!(:salix_agent, :composio_client_mod) == OriginalAgentClient
    assert Application.fetch_env!(:salix_agent, :composio_store_mod) == OriginalAgentStore
  end

  test "local Composio lists production tool slugs and answers provider-faithful data" do
    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-recommendation")

    linear = Enum.find(accounts, &(get_in(&1, ["toolkit", "slug"]) == "linear"))

    assert {:ok, [tool]} =
             SalixWeb.LocalComposioMock.list_tools(%{}, toolkit: "linear", limit: 4)

    assert tool["slug"] == "LINEAR_RUN_QUERY_OR_MUTATION"
    assert %{"type" => "object"} = tool["input_parameters"]

    assert tool["input_parameters"]["required"] == [
             "query_or_mutation",
             "variables"
           ]

    assert {:ok, %{"successful" => true, "data" => %{"issues" => %{"nodes" => [first | _]}}}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               tool["slug"],
               "group-recommendation",
               %{
                 "query_or_mutation" => "query { issues { nodes { url } } }",
                 "variables" => %{}
               },
               connected_account_id: linear["id"]
             )

    assert first["identifier"] == "COMMA-143"
    assert first["url"] == "https://linear.app/comma/issue/COMMA-143"
  end

  test "local Slack search matches carry a permalink consistent with a recent timestamp" do
    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-slack")

    slack = Enum.find(accounts, &(get_in(&1, ["toolkit", "slug"]) == "slack"))

    assert {:ok, %{"successful" => true, "data" => data}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               "SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY",
               "group-slack",
               %{"query" => "after:2026-08-27"},
               connected_account_id: slack["id"]
             )

    assert %{"messages" => %{"matches" => [match | _]}} = data
    assert %{"id" => channel_id} = match["channel"]

    assert match["permalink"] ==
             "https://comma-local.slack.com/archives/#{channel_id}/p" <>
               String.replace(match["ts"], ".", "")

    {seconds, _micro} = Integer.parse(match["ts"])
    assert System.os_time(:second) - seconds < 24 * 60 * 60
  end

  test "proxy reads resolve one Slack message, channel, and author for the link preview" do
    assert {:ok, session} =
             SalixWeb.LocalComposioMock.create_proxy_session(
               %{},
               "user-local",
               "local-group-slack-slack",
               "slack"
             )

    ts = "1786900000.000200"

    # The link preview's first session request binds the permalink workspace.
    assert {:ok, %{"status" => 200, "data" => auth}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/auth.test"
             })

    assert auth == %{
             "ok" => true,
             "url" => "https://comma-local.slack.com/",
             "team" => "Comma Local",
             "user" => "local",
             "team_id" => "TCOMMALOCAL",
             "user_id" => "UCOMMALOCAL"
           }

    assert {:ok, %{"status" => 200, "data" => history}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" =>
                 "https://slack.com/api/conversations.history?channel=C01234567" <>
                   "&latest=#{ts}&inclusive=true&limit=1"
             })

    # The fixture ts regenerates now-relative on every read, so the message
    # must echo the requested `latest` ts for stored permalinks to resolve.
    assert %{"ok" => true, "messages" => [message]} = history
    assert message["ts"] == ts
    assert message["user"] == "U_COMMA_DANA"
    assert message["text"] =~ "0.9 release"
    refute Map.has_key?(message, "permalink")

    assert {:ok, %{"status" => 200, "data" => %{"ok" => true, "messages" => [launch]}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" =>
                 "https://slack.com/api/conversations.history?channel=C0LAUNCH89&latest=#{ts}"
             })

    assert launch["user"] == "U_COMMA_MILO"

    assert {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "channel_not_found"}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" =>
                 "https://slack.com/api/conversations.history?channel=C0MISSING&latest=#{ts}"
             })

    # Thread replies read like history: the per-channel fixture message with
    # the requested `latest` ts echoed, so reply permalinks keep resolving.
    assert {:ok, %{"status" => 200, "data" => %{"ok" => true, "messages" => [reply]}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" =>
                 "https://slack.com/api/conversations.replies?channel=C01234567" <>
                   "&ts=1786899000.000100&latest=#{ts}&inclusive=true&limit=1"
             })

    assert reply["ts"] == ts
    assert reply["user"] == "U_COMMA_DANA"

    assert {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "channel_not_found"}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" =>
                 "https://slack.com/api/conversations.replies?channel=C0MISSING&latest=#{ts}"
             })

    assert {:ok, %{"status" => 200, "data" => channel_info}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/conversations.info?channel=C01234567"
             })

    assert %{"ok" => true, "channel" => %{"id" => "C01234567", "name" => "release"}} =
             channel_info

    assert {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "channel_not_found"}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/conversations.info?channel=C0MISSING"
             })

    assert {:ok, %{"status" => 200, "data" => %{"ok" => true, "user" => dana}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/users.info?user=U_COMMA_DANA"
             })

    assert dana["name"] == "dana"
    assert dana["real_name"] == "Dana Wu"
    assert dana["profile"]["display_name"] == "dana"
    assert String.starts_with?(dana["profile"]["image_72"], "https://avatars.slack-edge.com/")

    assert {:ok, %{"status" => 200, "data" => %{"ok" => true, "user" => milo}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/users.info?user=U_COMMA_MILO"
             })

    assert milo["real_name"] == "Milo Chen"

    assert {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "user_not_found"}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "slack",
               "method" => "GET",
               "endpoint" => "https://slack.com/api/users.info?user=U_NOBODY"
             })

    assert :ok = SalixWeb.LocalComposioMock.delete_proxy_session(%{}, session)
  end

  test "proxy reads resolve one Drive file with the requested id echoed" do
    file_id = "1AnotherLocalDriveFile_qW3eR5tY7uI9oP1aS3dF5g"

    assert {:ok, session} =
             SalixWeb.LocalComposioMock.create_proxy_session(
               %{},
               "user-local",
               "local-group-drive-googledrive",
               "googledrive"
             )

    assert {:ok, %{"status" => 200, "data" => file}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "googledrive",
               "method" => "GET",
               "endpoint" =>
                 "https://www.googleapis.com/drive/v3/files/#{file_id}" <>
                   "?fields=id,name,mimeType,modifiedTime,webViewLink,owners,size"
             })

    assert file["id"] == file_id
    assert file["name"] == "Launch brief"
    assert file["mimeType"] == "application/vnd.google-apps.document"
    assert file["webViewLink"] == "https://docs.google.com/document/d/#{file_id}/edit"
    assert [%{"displayName" => "Dana Wu"}] = file["owners"]

    # Google Docs files have no size, and Google omits absent fields.
    refute Map.has_key?(file, "size")

    assert {:ok, %{"status" => 404, "data" => %{}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "googledrive",
               "method" => "GET",
               "endpoint" => "https://www.googleapis.com/drive/v3/files/#{file_id}/permissions"
             })

    assert :ok = SalixWeb.LocalComposioMock.delete_proxy_session(%{}, session)
  end

  test "proxy reads keep resolving calendar events and 404 unknown endpoints" do
    assert {:ok, session} =
             SalixWeb.LocalComposioMock.create_proxy_session(
               %{},
               "user-local",
               "local-group-cal-googlecalendar"
             )

    assert {:ok, %{"status" => 200, "data" => event}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "googlecalendar",
               "method" => "GET",
               "endpoint" =>
                 "https://www.googleapis.com/calendar/v3/calendars/local%40comma.test/events/evt123"
             })

    assert event["id"] == "evt123"
    assert event["summary"] == "Launch review"

    assert {:ok, %{"status" => 404, "data" => %{}}} =
             SalixWeb.LocalComposioMock.proxy_execute(%{}, session, %{
               "toolkit_slug" => "gmail",
               "method" => "GET",
               "endpoint" => "https://mail.google.com/anything"
             })
  end

  test "local Composio rejects arguments missing a tool's required inputs" do
    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-required")

    linear = Enum.find(accounts, &(get_in(&1, ["toolkit", "slug"]) == "linear"))
    notion = Enum.find(accounts, &(get_in(&1, ["toolkit", "slug"]) == "notion"))

    assert {:ok, %{"successful" => false, "error" => linear_error}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               "LINEAR_RUN_QUERY_OR_MUTATION",
               "group-required",
               %{"query" => "recent activity"},
               connected_account_id: linear["id"]
             )

    assert linear_error =~ "query_or_mutation"

    assert {:ok, %{"successful" => false, "error" => variables_error}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               "LINEAR_RUN_QUERY_OR_MUTATION",
               "group-required",
               %{"query_or_mutation" => "query { issues { nodes { url } } }"},
               connected_account_id: linear["id"]
             )

    assert variables_error =~ "variables"

    # The retired row_id argument no longer satisfies Composio's
    # NOTION_FETCH_ROW contract, which identifies the row as page_id.
    assert {:ok, %{"successful" => false, "error" => notion_error}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               "NOTION_FETCH_ROW",
               "group-required",
               %{"row_id" => "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812"},
               connected_account_id: notion["id"]
             )

    assert notion_error =~ "page_id"
  end

  test "local Composio fails unimplemented tools as a structured provider error" do
    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-unimplemented")

    slack = Enum.find(accounts, &(get_in(&1, ["toolkit", "slug"]) == "slack"))

    assert {:ok, %{"successful" => false, "error" => error}} =
             SalixWeb.LocalComposioMock.execute_tool(
               %{},
               "SLACK_SEND_MESSAGE",
               "group-unimplemented",
               %{},
               connected_account_id: slack["id"]
             )

    assert error =~ "SLACK_SEND_MESSAGE"
    assert error =~ "SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY"
  end

  test "local MCP returns source-specific inline links" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "comma_local_search",
        "arguments" => %{
          "query" => "recent activity for the Comma Center briefing",
          "source" => "linear"
        }
      }
    }

    conn =
      Plug.Test.conn(
        "POST",
        "/v1/local-oauth/mcp/resource",
        Jason.encode!(request)
      )
      |> SalixWeb.LocalOAuthMock.call([])

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    [content] = get_in(response, ["result", "content"])
    payload = Jason.decode!(content["text"])
    [first_issue | _] = payload["items"]

    assert first_issue["title"] == "Review COMMA-143"

    assert first_issue["parts"] == [
             %{"kind" => "markdown", "text" => "Review "},
             %{
               "kind" => "inline-link",
               "link" => %{
                 "href" => "https://linear.app/comma/issue/COMMA-143",
                 "label" => "COMMA-143"
               }
             }
           ]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
