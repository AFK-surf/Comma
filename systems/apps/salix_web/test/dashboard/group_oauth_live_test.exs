defmodule SalixWeb.Dashboard.GroupOAuthLiveTest do
  @moduledoc "Agent groups, tabs, and OAuth provider apps via LiveView."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Group OAuth"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  test "create a group from the index" do
    {:ok, view, _html} = live(authed_conn(), "/dash/groups")
    render_click(element(view, "button[phx-click=new]"))

    {:ok, _show, html} =
      view
      |> form("#new-group form", %{"name" => "CI Group"})
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "CI Group"
  end

  test "group tabs render without crashing" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "TabGroup"}, tenant_id())
    gid = group["group_id"]

    assert {:ok, _v, html} = live(authed_conn(), "/dash/groups/#{gid}")
    assert html =~ "TabGroup"

    assert {:ok, _v, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=oauth")
    assert html =~ "No OAuth bindings"

    assert {:ok, _v, _html} = live(authed_conn(), "/dash/groups/#{gid}?tab=router")
    assert {:ok, _v, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=im")
    assert html =~ "IM connects"

    assert {:ok, _v, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=conversations")
    assert html =~ "Conversations"
  end

  test "router tab renders CJK message previews the LiveView socket can encode" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "RouterPreviewGroup"}, tenant_id())
    gid = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => gid, "role" => "router", "name" => "Router CI"},
        tenant_id()
      )

    {:ok, _group} =
      Salix.Control.Groups.update(gid, %{"router_agent_id" => agent["agent_id"]}, tenant_id())

    # 121 bytes, so the 120-byte preview budget lands inside the 40th character.
    {:ok, _} =
      SalixIM.RouterConversationInput.append_user_message(gid, %{
        "content" => "x" <> String.duplicate("中", 40),
        "user_id" => "u-router-preview"
      })

    {:ok, view, dead_html} = live(authed_conn(), "/dash/groups/#{gid}?tab=router")
    assert String.valid?(dead_html)

    connected_html = render(view)
    assert String.valid?(connected_html)

    # A byte-truncated preview crashes this serializer on every diff, which the
    # browser sees as an endless LiveView reconnect loop rather than an error.
    reply = %Phoenix.Socket.Reply{
      topic: "lv:1",
      ref: "1",
      status: :ok,
      payload: %{"rendered" => %{"0" => connected_html}}
    }

    assert Phoenix.Socket.V2.JSONSerializer.encode!(reply)
  end

  test "group conversations tab creates and messages an owner-managed conversation" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "ConversationGroup"}, tenant_id())
    gid = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => gid,
          "role" => "router",
          "name" => "Router CI"
        },
        tenant_id()
      )

    {:ok, group} =
      Salix.Control.Groups.update(
        gid,
        %{"router_agent_id" => agent["agent_id"]},
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=conversations")

    assert html =~ "No conversations"

    html =
      view
      |> form("#group-conversation-form", %{"title" => "Dashboard conversation"})
      |> render_submit()

    assert {:ok, %{"data" => [conversation]}} =
             SalixIM.Conversations.list_group_conversations(gid)

    conversation_id = conversation["conversation_id"]

    assert SalixStore.Ids.valid_conversation_id?(conversation_id)
    assert html =~ "Dashboard conversation"
    assert html =~ conversation_id

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(gid, conversation_id)

    assert length(participants) == 2
    assert Enum.all?(participants, &SalixStore.Ids.valid_participant_id?(&1["participant_id"]))

    router_participant =
      Enum.find(
        participants,
        &(&1["actor_type"] == "agent" and &1["agent_id"] == agent["agent_id"])
      )

    session_id = get_in(router_participant, ["payload", "session_id"])

    assert html =~ "Participants"
    assert html =~ "Router CI"
    assert html =~ "/dash/agents/#{agent["agent_id"]}/sessions/#{session_id}"

    html =
      view
      |> form("form[phx-submit=send-conversation]", %{
        "conversation_id" => conversation_id,
        "text" => "from dashboard"
      })
      |> render_submit()

    assert html =~ "from dashboard"

    assert {:ok, %{"messages" => messages}} =
             SalixIM.Conversations.get_group_conversation_with_messages(gid, conversation_id)

    assert [message] =
             Enum.filter(messages, fn message ->
               message["actor_type"] == "user" and
                 message["content"] == [%{"text" => "from dashboard", "type" => "text"}]
             end)

    assert SalixStore.Ids.valid_message_id?(message["message_id"])
    assert message["participant_id"] in Enum.map(participants, & &1["participant_id"])
    assert message["actor_type"] == "user"
    assert group["router_agent_id"] == agent["agent_id"]
  end

  test "assign a router agent from the group overview" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "RouterGroup"}, tenant_id())
    gid = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => gid,
          "role" => "router",
          "name" => "Router CI"
        },
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/groups/#{gid}")
    assert html =~ "Router CI"

    html =
      view
      |> form("form[phx-submit=set-router-agent]", %{"router_agent_id" => agent["agent_id"]})
      |> render_submit()

    assert html =~ "Router agent updated"
    assert {:ok, %{"router_agent_id" => router_agent_id}} = Salix.Control.Groups.get(gid)
    assert router_agent_id == agent["agent_id"]
  end

  test "toggle Worker memory consultation from the group overview" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "MemoryGroup"}, tenant_id())
    gid = group["group_id"]

    {:ok, view, _html} = live(authed_conn(), "/dash/groups/#{gid}")
    assert has_element?(view, "#memory-ask-worker-toggle:not(:checked)")
    assert render(view) =~ "Disabled by default"

    html = view |> element("#memory-ask-worker-toggle") |> render_click()
    assert html =~ "Worker memory consultation enabled."
    assert has_element?(view, "#memory-ask-worker-toggle:checked")

    assert {:ok, %{"memory_ask_worker_enabled" => true}} =
             Salix.Control.Groups.get(gid, tenant_id())

    html = view |> element("#memory-ask-worker-toggle") |> render_click()
    assert html =~ "Worker memory consultation disabled."
    assert has_element?(view, "#memory-ask-worker-toggle:not(:checked)")

    assert {:ok, %{"memory_ask_worker_enabled" => false}} =
             Salix.Control.Groups.get(gid, tenant_id())
  end

  test "toggle VFS control commands from the group overview" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "VFSGroup"}, tenant_id())
    gid = group["group_id"]

    {:ok, view, _html} = live(authed_conn(), "/dash/groups/#{gid}")
    assert has_element?(view, "#control-command-vfs-toggle:not(:checked)")
    assert render(view) =~ "Disabled by default"

    html = view |> element("#control-command-vfs-toggle") |> render_click()
    assert html =~ "VFS control commands enabled."
    assert has_element?(view, "#control-command-vfs-toggle:checked")

    assert {:ok, %{"control_command_vfs_enabled" => true}} =
             Salix.Control.Groups.get(gid, tenant_id())

    html = view |> element("#control-command-vfs-toggle") |> render_click()
    assert html =~ "VFS control commands disabled."
    assert has_element?(view, "#control-command-vfs-toggle:not(:checked)")

    assert {:ok, %{"control_command_vfs_enabled" => false}} =
             Salix.Control.Groups.get(gid, tenant_id())
  end

  test "oauth provider apps list and save" do
    {:ok, view, html} = live(authed_conn(), "/dash/oauth")
    provider = hd(SalixStore.OAuth.Adapters.supported())
    assert html =~ provider

    html =
      view
      |> form("#oauth-form-#{provider}", %{
        "client_id" => "ci-client-id",
        "client_secret" => "ci-secret"
      })
      |> render_submit()

    assert html =~ "#{provider} saved"
    assert {:ok, _} = Salix.Control.OAuthApps.get(tenant_id(), provider)
  end

  test "group oauth tab disables and enables a binding without deleting it" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "OAuthBindingGroup"}, tenant_id())
    gid = group["group_id"]
    provider = hd(SalixStore.OAuth.Adapters.supported())
    connection_id = "conn-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    :ok =
      SalixStore.OAuth.put(connection_id, %{
        "connection_id" => connection_id,
        "tenant" => tenant_id(),
        "provider" => provider,
        "provider_account_id" => "acct-live",
        "provider_account_name" => "Live Account",
        "access_token" => "secret-token",
        "refresh_token" => "secret-refresh",
        "scopes" => ["read"],
        "status" => "active",
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, binding, _previous_connection_id} =
      Salix.Control.OAuthBindings.put(tenant_id(), gid, provider, "work", connection_id)

    {:ok, view, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=oauth")
    assert html =~ "Live Account"
    assert has_element?(view, "button[phx-click='set-binding-enabled']", "Disable")

    html =
      view
      |> element(
        "button[phx-click='set-binding-enabled'][phx-value-binding='#{binding["binding_id"]}']",
        "Disable"
      )
      |> render_click()

    assert html =~ "Binding updated."
    assert html =~ "disabled"
    assert has_element?(view, "button[phx-click='set-binding-enabled']", "Enable")
    assert [disabled] = Salix.Control.OAuthBindings.list(gid)
    assert disabled["binding_id"] == binding["binding_id"]
    assert disabled["enabled"] == false
    assert disabled["connection_id"] == connection_id

    html =
      view
      |> element(
        "button[phx-click='set-binding-enabled'][phx-value-binding='#{binding["binding_id"]}']",
        "Enable"
      )
      |> render_click()

    assert html =~ "Binding updated."
    assert [enabled] = Salix.Control.OAuthBindings.list(gid)
    assert enabled["binding_id"] == binding["binding_id"]
    assert enabled["enabled"] == true
    assert enabled["connection_id"] == connection_id
  end
end
