defmodule SalixWeb.Dashboard.IMLiveTest do
  @moduledoc "Dashboard IM connects, config, router session links and memory links."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixIM.Conversations
  alias SalixIM.ProviderConnects

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "IM"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  defp create_router_connect_fixture do
    suffix = System.unique_integer([:positive])
    app_id = "A-IM-OVERVIEW-#{suffix}"

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "IM Overview #{suffix}"}, tenant_id())
    gid = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => gid,
          "role" => "router",
          "name" => "IM Router"
        },
        tenant_id()
      )

    {:ok, _group} = Salix.Control.Groups.update(gid, %{"router_agent_id" => agent["agent_id"]})

    {:ok, connect} =
      ProviderConnects.create_slack_im_connect(tenant_id(), gid, %{
        "app_name" => "Bridge",
        "app_id" => app_id,
        "client_id" => "client-im-overview-#{suffix}",
        "client_secret" => "secret-im-overview-#{suffix}",
        "signing_secret" => "signing-im-overview-#{suffix}"
      })

    {:ok, router_conversation} = SalixIM.RouterConversationInput.ensure(gid)

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(
        gid,
        router_conversation["conversation_id"]
      )

    session_id = router_participant_session_id(participants, agent["agent_id"])

    {:ok, _delivery} =
      SalixAgent.deliver(
        agent["agent_id"],
        %{session_id: session_id, role: "user", content: "Bridge chat", no_wake: true},
        source_message_id: "im-live-session-#{suffix}"
      )

    {:ok, _file} =
      SalixAgent.Workspace.write(agent["agent_id"], "/memory/semantic/user.md", "router memory")

    %{group: group, agent: agent, connect: connect, app_id: app_id, session_id: session_id}
  end

  defp router_participant_session_id(participants, agent_id) do
    participants
    |> Enum.find_value(fn
      %{"actor_type" => "agent", "agent_id" => ^agent_id, "payload" => %{"session_id" => sid}} ->
        sid

      _ ->
        nil
    end)
  end

  test "im index renders group provider connects and router session links" do
    %{app_id: app_id, agent: agent, group: group, session_id: session_id} =
      create_router_connect_fixture()

    {:ok, _v, html} = live(authed_conn(), "/dash/im")
    assert html =~ "IM connects"
    assert html =~ "IM Overview"
    assert html =~ app_id
    assert html =~ "Router session"
    assert html =~ "/dash/agents/#{agent["agent_id"]}/sessions/#{session_id}"
    assert html =~ "Router memory"
    assert html =~ "/dash/agents/#{agent["agent_id"]}/files/memory"
    assert html =~ "Group IM"
    assert html =~ "/dash/groups/#{group["group_id"]}?tab=im"
  end

  test "im config saves a valid JSON document" do
    {:ok, view, _html} = live(authed_conn(), "/dash/im-config")

    html =
      view
      |> form("form[phx-submit=save]", %{"config" => ~s({"slack":{"bot_token":"xoxb-1"}})})
      |> render_submit()

    assert html =~ "IM config saved"
    {:ok, cfg} = Salix.Control.Tenants.get_config(tenant_id(), "im_integrations", %{})
    assert cfg["slack"]["bot_token"] == "xoxb-1"
  end

  test "im config rejects invalid JSON" do
    {:ok, view, _html} = live(authed_conn(), "/dash/im-config")
    html = view |> form("form[phx-submit=save]", %{"config" => "{bad"}) |> render_submit()
    assert html =~ "valid JSON object"
  end
end
