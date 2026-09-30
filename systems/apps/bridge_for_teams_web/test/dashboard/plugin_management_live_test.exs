defmodule BridgeForTeamsWeb.Dashboard.PluginManagementLiveTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Accounts}

  defmodule PluginClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def get_tenant_config(_tenant_id, "android_control", _default) do
      case Application.get_env(:bridge_for_teams_core, :plugin_management_android_control, %{}) do
        {:error, _reason} = error -> error
        config -> {:ok, config}
      end
    end

    def list_tenant_plugin_definitions(_tenant_id), do: definitions()

    def create_tenant_plugin_definition(_tenant_id, attrs) do
      notify({:create_tenant_plugin, attrs})
      {:ok, Map.put(attrs, "plugin_id", "tenant.created")}
    end

    def update_tenant_plugin_definition(_tenant_id, plugin_id, attrs) do
      notify({:update_tenant_plugin, plugin_id, attrs})
      {:ok, Map.put(attrs, "plugin_id", plugin_id)}
    end

    def list_group_plugin_definitions(_tenant_id, _group_id) do
      notify(:list_group_plugin_definitions)
      definitions()
    end

    def list_group_plugin_enablements(_tenant_id, _group_id) do
      notify(:list_group_plugin_enablements)
      [%{"plugin_id" => "tenant.knowledge", "enabled" => true}]
    end

    def group_plugin_runtime_projection(_tenant_id, _group_id) do
      notify(:group_plugin_runtime_projection)
      %{"plugin_ids" => ["system.search", "tenant.knowledge"], "revision" => "rev-test"}
    end

    def create_group_plugin_definition(_tenant_id, _group_id, attrs) do
      notify({:create_group_plugin, attrs})
      {:ok, Map.put(attrs, "plugin_id", "group.created")}
    end

    def update_group_plugin_definition(_tenant_id, _group_id, plugin_id, attrs) do
      notify({:update_group_plugin, plugin_id, attrs})
      {:ok, Map.put(attrs, "plugin_id", plugin_id)}
    end

    def enable_group_plugin(_tenant_id, _group_id, plugin_id) do
      notify({:enable_plugin, plugin_id})
      {:ok, %{"plugin_id" => plugin_id, "enabled" => true}}
    end

    def disable_group_plugin(_tenant_id, _group_id, plugin_id) do
      notify({:disable_plugin, plugin_id})
      {:ok, %{"plugin_id" => plugin_id, "enabled" => false}}
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def list_runtime_auth_requests(_group_id, _tenant_id, _opts),
      do: {:ok, %{"requests" => [], "next_cursor" => nil}}

    def list_group_oauth_bindings(_group_id) do
      notify(:list_group_oauth_bindings)
      Application.get_env(:bridge_for_teams_core, :plugin_management_oauth_bindings, [])
    end

    def slack_manifest(app_name) do
      %{
        "manifest" => %{"display_information" => %{"name" => app_name}},
        "redirect_url" => "https://example.test/slack/oauth/callback",
        "events_url" => "https://example.test/slack/events"
      }
    end

    def prepare_group_plugin_setup(_tenant_id, _group_id, plugin_id, connection_id) do
      notify({:prepare_group_plugin_setup, plugin_id, connection_id})

      connection =
        case connection_id do
          "linear-native" ->
            %{
              "id" => connection_id,
              "kind" => "native_mcp_oauth",
              "scopes" => ~w(read write openid email)
            }

          "linear-managed" ->
            %{
              "id" => connection_id,
              "kind" => "managed_oauth",
              "provider" => "linear",
              "alias" => "linear",
              "scopes" => ["read"]
            }

          "linear-composio" ->
            %{"id" => connection_id, "kind" => "composio", "toolkit" => "linear"}
        end

      bindings =
        if connection_id == "linear-native",
          do: [%{"binding_id" => "mcpb-linear", "alias" => "linear"}],
          else: []

      {:ok, %{"bindings" => bindings, "connection" => connection}}
    end

    def start_remote_mcp_authorization(_tenant_id, _group_id, binding_id, params) do
      notify({:start_linear_mcp_oauth, binding_id, params})
      {:ok, %{"authorization_url" => "https://linear.app/oauth/authorize"}}
    end

    def disconnect_remote_mcp_authorization(_tenant_id, _group_id, binding_id) do
      notify({:disconnect_linear_mcp_oauth, binding_id})
      :ok
    end

    def list_oauth_provider_apps(_tenant_id) do
      [
        %{
          "provider" => "linear",
          "source" => "default",
          "client_id" => "linear-client-id",
          "client_secret_configured" => true
        }
      ]
    end

    def start_oauth_authorization(_tenant_id, _group_id, "linear", params) do
      notify({:start_linear_oauth, params})
      {:ok, %{"authorization_url" => "https://linear.app/oauth/authorize", "state" => "state"}}
    end

    def create_composio_connect_link(_tenant_id, _group_id, "linear", params) do
      notify({:start_linear_composio, params})
      {:ok, %{"redirect_url" => "https://connect.composio.dev/linear"}}
    end

    defp definitions do
      base = [
        %{
          "plugin_id" => "system.search",
          "name" => "Core Search",
          "description" => "Required system search",
          "owner_scope" => "system",
          "locked" => true,
          "read_only" => true,
          "setup" => %{"type" => "integration"},
          "refs" => %{"tool_refs" => ["search.web"]}
        },
        %{
          "plugin_id" => "system.mcp-management",
          "name" => "MCP Management",
          "description" => "Internal MCP capability package",
          "owner_scope" => "system",
          "locked" => true,
          "read_only" => true,
          "refs" => %{"tool_refs" => ["mcp.list"]}
        },
        %{
          "plugin_id" => "tenant.knowledge",
          "name" => "Knowledge Pack",
          "description" => "Organization-owned knowledge tools",
          "owner_scope" => "tenant",
          "refs" => %{
            "tool_refs" => ["knowledge.query"],
            "oauth_requirements" => [%{"provider" => "notion", "scopes" => ["read"]}]
          },
          "setup" => %{"destination" => "org_oauth"}
        },
        %{
          "plugin_id" => "group.release",
          "name" => "Release Helper",
          "description" => "Project-owned release automation",
          "owner_scope" => "group",
          "refs" => %{"skill_refs" => ["release-checklist"]}
        }
      ]

      base =
        if Application.get_env(:bridge_for_teams_core, :android_plugin_live_test, false) do
          base ++
            [
              %{
                "plugin_id" => "android-control",
                "name" => "Android Control",
                "description" => "Operate Android",
                "owner_scope" => "system",
                "read_only" => true,
                "default_enabled" => false,
                "ui" => %{"classification" => "capability"},
                "refs" => %{"tool_refs" => ["env.android"]}
              }
            ]
        else
          base
        end

      if Application.get_env(:bridge_for_teams_core, :linear_plugin_live_test, false) do
        base ++
          [
            %{
              "plugin_id" => "linear",
              "name" => "Linear",
              "description" => "Linear issues and projects",
              "owner_scope" => "system",
              "ui" => %{"brand" => "linear"},
              "setup_status" => %{
                "type" => "integration",
                "default_connection" => "linear-native",
                "connections" => [
                  %{
                    "id" => "linear-native",
                    "kind" => "native_mcp_oauth",
                    "label" => "Linear MCP OAuth",
                    "state" =>
                      Application.get_env(
                        :bridge_for_teams_core,
                        :linear_plugin_native_state,
                        "not_connected"
                      )
                  },
                  %{
                    "id" => "linear-managed",
                    "kind" => "managed_oauth",
                    "label" => "Linear OAuth",
                    "credential_env_var" => "LINEAR_ACCESS_TOKEN",
                    "state" =>
                      Application.get_env(
                        :bridge_for_teams_core,
                        :linear_plugin_managed_state,
                        "not_connected"
                      )
                  },
                  %{
                    "id" => "linear-composio",
                    "kind" => "composio",
                    "label" => "Linear via Composio",
                    "state" => "external"
                  }
                ],
                "mcps" => [
                  %{
                    "alias" => "linear",
                    "placement" => "server",
                    "auth_refs" => ["linear-native", "linear-managed"],
                    "state" =>
                      Application.get_env(
                        :bridge_for_teams_core,
                        :linear_plugin_mcp_state,
                        "waiting_for_oauth"
                      )
                  }
                ]
              },
              "refs" => %{
                "tool_refs" => ["mcp.linear.*"],
                "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000004"}],
                "oauth_requirements" => [%{"provider" => "linear", "alias" => "linear"}]
              }
            },
            %{
              "plugin_id" => "slack",
              "name" => "Slack",
              "description" => "Workspace messaging through Slack",
              "owner_scope" => "system",
              "ui" => %{"brand" => "slack"},
              "setup_status" => %{
                "type" => "integration",
                "default_connection" => "slack-im",
                "connections" => [
                  %{
                    "id" => "slack-im",
                    "kind" => "im_connect",
                    "label" => "Slack messaging",
                    "provider" => "slack",
                    "state" => "not_connected"
                  },
                  %{
                    "id" => "slack-managed",
                    "kind" => "managed_oauth",
                    "label" => "Slack OAuth",
                    "mcp_alias" => "slack",
                    "credential_env_var" => "SLACK_USER_TOKEN",
                    "state" => "not_connected"
                  },
                  %{
                    "id" => "slack-composio",
                    "kind" => "composio",
                    "label" => "Slack via Composio",
                    "state" => "external"
                  }
                ],
                "mcps" => [
                  %{
                    "alias" => "slack",
                    "placement" => "server",
                    "auth_ref" => "slack-managed",
                    "state" => "waiting_for_oauth"
                  }
                ]
              },
              "refs" => %{
                "tool_refs" => ["im_api.slack.*", "mcp.slack.*"],
                "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000008"}],
                "im_connect_requirements" => [%{"provider" => "slack"}]
              }
            }
          ]
      else
        base
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:bridge_for_teams_core, :plugin_management_test_pid) do
        send(pid, message)
      end
    end
  end

  setup %{conn: conn} do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, PluginClient)
    Application.put_env(:bridge_for_teams_core, :plugin_management_test_pid, self())

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, previous_client)
      Application.delete_env(:bridge_for_teams_core, :plugin_management_test_pid)
      Application.delete_env(:bridge_for_teams_core, :android_plugin_live_test)
      Application.delete_env(:bridge_for_teams_core, :plugin_management_android_control)
      Application.delete_env(:bridge_for_teams_core, :linear_plugin_live_test)
      Application.delete_env(:bridge_for_teams_core, :linear_plugin_mcp_state)
      Application.delete_env(:bridge_for_teams_core, :linear_plugin_native_state)
      Application.delete_env(:bridge_for_teams_core, :linear_plugin_managed_state)
      Application.delete_env(:bridge_for_teams_core, :plugin_management_oauth_bindings)
    end)

    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Product",
        "slug" => "product"
      })

    %{conn: conn, user: user, org: org, project: project}
  end

  test "organization page separates owned definitions from the read-only system catalog", %{
    conn: conn,
    org: org
  } do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/plugins")

    assert html =~ "Knowledge Pack"
    refute html =~ "Core Search"
    refute html =~ "Release Helper"
    refute has_element?(view, "[role='switch']")
    assert has_element?(view, "button[aria-label='Edit Knowledge Pack']")

    html =
      view
      |> element("button[phx-value-catalog='system']")
      |> render_click()

    assert html =~ "Core Search"
    refute html =~ "MCP Management"
    refute html =~ "Knowledge Pack"
    refute has_element?(view, "button[aria-label='Edit Core Search']")
  end

  test "organization editor is contextual and submits object refs without a caller plugin id", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/plugins")

    refute has_element?(view, "#org-plugin-editor")
    view |> element("button", "New organization plugin") |> render_click()

    assert has_element?(view, "#org-plugin-editor")
    assert has_element?(view, "#org-plugin-editor [phx-hook='PluginRefsEditor']")
    assert has_element?(view, "#org-plugin-editor input[name='refs_json']")
    refute has_element?(view, "#org-plugin-editor input[name='plugin_id']")

    render_submit(view, "create_tenant_plugin", %{
      "name" => "Docs Assistant",
      "description" => "Searches project documentation",
      "setup_destination" => "org_oauth",
      "refs_json" => "[]"
    })

    assert has_element?(view, "#org-plugin-editor [role='alert']", "Refs JSON must be an object.")
    assert has_element?(view, "#org-plugin-editor input[name='name'][value='Docs Assistant']")

    refs = %{
      "tool_refs" => ["docs.search"],
      "oauth_requirements" => [%{"provider" => "notion", "scopes" => ["read"]}]
    }

    render_submit(view, "create_tenant_plugin", %{
      "name" => "Docs Assistant",
      "description" => "Searches project documentation",
      "setup_destination" => "org_oauth",
      "refs_json" => Jason.encode!(refs)
    })

    assert_receive {:create_tenant_plugin, attrs}
    assert attrs["owner_scope"] == "tenant"
    assert attrs["refs"] == refs
    refute Map.has_key?(attrs, "plugin_id")
    refute has_element?(view, "#org-plugin-editor")
  end

  test "project page shows one plugin inventory and limits editing to project definitions", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    assert_receive :list_group_plugin_definitions
    assert_receive :list_group_plugin_enablements
    refute_receive :group_plugin_runtime_projection
    assert html =~ "Core Search"
    assert html =~ "Knowledge Pack"
    assert html =~ "Release Helper"
    refute html =~ "MCP Management"
    assert html =~ "2 enabled"
    assert html =~ "1 disabled"
    assert has_element?(view, "#project-plugins")
    refute has_element?(view, "#project-plugins-required")
    refute has_element?(view, "#project-plugins-optional")
    assert render(view) |> then(&Regex.scan(~r/role="switch"/, &1)) |> length() == 3
    assert has_element?(view, "[role='switch'][aria-label='Core Search is required'][disabled]")
    assert has_element?(view, "button[aria-label='Edit Release Helper']")
    refute has_element?(view, "button[aria-label='Edit Knowledge Pack']")
    refute has_element?(view, "button[aria-label='Edit Core Search']")
  end

  test "project search, source and state filters narrow the inventory", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    html =
      view
      |> form("form[phx-change='filter_project_plugins']", %{
        "query" => "release",
        "source" => "group"
      })
      |> render_change()

    assert html =~ "Release Helper"
    refute html =~ "Knowledge Pack"
    refute html =~ "Core Search"

    view
    |> form("form[phx-change='filter_project_plugins']", %{"query" => "", "source" => "all"})
    |> render_change()

    html = view |> element("button[phx-value-state='enabled']") |> render_click()
    assert html =~ "Core Search"
    assert html =~ "Knowledge Pack"
    refute html =~ "Release Helper"
  end

  test "project enablement switch mutates only group enablement", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    view
    |> element("[role='switch'][aria-label='Enable Release Helper']")
    |> render_click()

    assert_receive {:enable_plugin, "group.release"}
    refute_receive {:create_tenant_plugin, _}
    refute_receive {:update_tenant_plugin, _, _}
  end

  test "Android plugin is visible but cannot be enabled without tenant admission", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :android_plugin_live_test, true)

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    assert has_element?(view, "#project-plugins-android-control")

    assert has_element?(
             view,
             "#project-plugins-android-control [role='switch'][disabled]"
           )

    {:ok, _detail, html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/android-control")

    assert html =~ "Not available for this organization"
    assert html =~ "Contact your platform administrator"

    render_click(view, "enable_plugin", %{"id" => "android-control"})
    refute_receive {:enable_plugin, "android-control"}

    {:ok, _devices, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")
    assert html =~ "Android setup is unavailable"
  end

  test "entitled admin can enable Android and see connector setup status", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :android_plugin_live_test, true)

    Application.put_env(:bridge_for_teams_core, :plugin_management_android_control, %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 3600
    })

    {:ok, plugins, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/android-control")

    assert render(plugins) =~ "Available to this organization"

    plugins
    |> element("#android-plugin-status button", "Enable for this Agent Swarm")
    |> render_click()

    assert_receive {:enable_plugin, "android-control"}

    {:ok, _devices, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")
    assert html =~ "Android setup"
    assert html =~ "Allowed profiles: api30-phone"
    assert html =~ "Ask your platform administrator to register an Android connector"
  end

  test "Android enablement rechecks tenant admission when submitted", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :android_plugin_live_test, true)

    Application.put_env(:bridge_for_teams_core, :plugin_management_android_control, %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 3600
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/android-control")

    Application.put_env(:bridge_for_teams_core, :plugin_management_android_control, %{})

    render_click(view, "enable_plugin", %{"id" => "android-control"})

    refute_receive {:enable_plugin, "android-control"}
    assert render(view) =~ "Android connector access is not enabled"
  end

  test "Android enablement reports an unavailable admission authority", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :android_plugin_live_test, true)

    Application.put_env(
      :bridge_for_teams_core,
      :plugin_management_android_control,
      {:error, :timeout}
    )

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/android-control")

    assert html =~ "Enablement unavailable"
    assert html =~ "Android admission status is unavailable"
    refute html =~ "Not available for this organization"
    refute html =~ "Contact your platform administrator"

    render_click(view, "enable_plugin", %{"id" => "android-control"})

    refute_receive {:enable_plugin, "android-control"}
    assert render(view) =~ "Android admission status is unavailable"
  end

  test "Linear detail shows all connection kinds and starts native MCP OAuth", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    detail_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear"
    assert has_element?(view, "a[href='#{detail_path}']")
    assert has_element?(view, "#plugin-icon-linear[data-plugin-icon='linear'] svg")
    assert render(view) =~ "linear needs setup"
    refute render(view) =~ "Linear MCP OAuth"
    refute has_element?(view, "#project-plugins-linear a[href*='/connections']")
    refute has_element?(view, "#project-plugins-linear a[href*='/oauth']")

    linear_row = view |> element("#project-plugins-linear") |> render()
    refute linear_row =~ "1 tool"
    refute linear_row =~ "1 MCP reference"
    refute linear_row =~ "1 OAuth requirement"

    Application.put_env(:bridge_for_teams_core, :linear_plugin_mcp_state, "ready_on_use")
    {:ok, ready_view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")
    refute render(ready_view) =~ "linear needs setup"

    Application.put_env(
      :bridge_for_teams_core,
      :linear_plugin_mcp_state,
      "waiting_for_oauth"
    )

    {:ok, view, _html} = live(conn, detail_path)

    assert has_element?(view, "#project-plugin-detail")
    refute has_element?(view, "#project-header")
    assert has_element?(view, "[role='switch'][aria-label$='Linear']")
    refute has_element?(view, "#project-plugin-detail code")
    assert has_element?(view, "#plugin-components")
    assert has_element?(view, "#plugin-connection-linear-native")
    assert has_element?(view, "#plugin-mcp-linear", "MCP Server")
    assert has_element?(view, "#plugin-mcp-linear #plugin-connection-linear-native")
    assert has_element?(view, "#plugin-mcp-linear #plugin-connection-linear-managed")
    assert has_element?(view, "#plugin-components #plugin-connection-linear-composio")
    assert has_element?(view, "#plugin-connection-status-linear-native", "Not connected")
    assert has_element?(view, "#plugin-connection-status-linear-managed", "Not connected")
    refute has_element?(view, "#plugin-setup-required")

    assert has_element?(
             view,
             "#plugin-connection-status-linear-composio",
             "Direct API connection"
           )

    assert has_element?(view, "#plugin-mcp-status-linear", "Waiting for OAuth")

    view |> element("#connect-plugin") |> render_click()

    assert has_element?(view, "#connection-detail-modal", "Linear MCP OAuth")
    assert has_element?(view, "#connection-detail-modal", "Dependent MCP servers")

    assert {:error, {:redirect, %{to: "https://linear.app/oauth/authorize"}}} =
             view |> element("#continue-connection") |> render_click()

    assert_receive {:prepare_group_plugin_setup, "linear", "linear-native"}
    assert_receive {:start_linear_mcp_oauth, "mcpb-linear", params}
    assert params["redirect_after"] =~ "/orgs/#{org.slug}/projects/#{project.id}/plugins"
    assert params["scopes"] == ~w(read write openid email)
  end

  test "messaging product plugin opens its provider side panel in place", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)

    detail_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/slack"
    {:ok, view, _html} = live(conn, detail_path)

    assert has_element?(view, "#plugin-components")
    assert has_element?(view, "#plugin-mcp-slack", "MCP Server")
    assert has_element?(view, "#plugin-mcp-slack #plugin-connection-slack-managed")
    assert has_element?(view, "#plugin-connection-slack-im", "Messaging connection")
    refute has_element?(view, "#plugin-setup-required")

    view |> element("#connect-plugin") |> render_click()
    refute has_element?(view, "#connection-detail-modal")
    assert has_element?(view, "#integration-setup-panel", "Slack")
    assert has_element?(view, "#create-slack-connect-form")
  end

  test "connected native MCP exposes reconnect and confirmed disconnect", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)
    Application.put_env(:bridge_for_teams_core, :linear_plugin_native_state, "connected")
    Application.put_env(:bridge_for_teams_core, :linear_plugin_mcp_state, "ready_on_use")

    detail_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear"
    {:ok, view, _html} = live(conn, detail_path)

    assert has_element?(view, "#reconnect-plugin-linear-native", "Reconnect")
    assert has_element?(view, "#disconnect-plugin-linear-native", "Disconnect")

    view |> element("#reconnect-plugin-linear-native") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "current credential stays active")

    {:ok, view, _html} = live(conn, detail_path)

    view |> element("#disconnect-plugin-linear-native") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "dependent MCP servers")
    assert has_element?(view, "#continue-connection", "Disconnect")

    view |> element("#continue-connection") |> render_click()

    assert_receive {:prepare_group_plugin_setup, "linear", "linear-native"}
    assert_receive {:disconnect_linear_mcp_oauth, "mcpb-linear"}
    assert render(view) =~ "Connection disconnected."
  end

  test "plugin managed OAuth and Composio connections reuse the shared detail modal", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)
    detail_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear"
    {:ok, view, _html} = live(conn, detail_path)

    view |> element("#connect-plugin-linear-managed") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "Managed OAuth")

    assert {:error, {:redirect, %{to: "https://linear.app/oauth/authorize"}}} =
             view |> element("#continue-connection") |> render_click()

    assert_receive {:start_linear_oauth, %{"alias" => "linear", "scopes" => ["read"]}}

    {:ok, view, _html} = live(conn, detail_path)

    view |> element("#connect-plugin-linear-composio") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "Composio direct API")

    assert {:error, {:redirect, %{to: "https://connect.composio.dev/linear"}}} =
             view |> element("#continue-connection") |> render_click()

    assert_receive {:start_linear_composio, %{"callback_url" => callback_url}}
    assert callback_url =~ "/orgs/#{org.slug}/projects/#{project.id}/plugins"
  end

  test "connected managed OAuth configures an unready MCP while reconnect still authorizes",
       %{
         conn: conn,
         org: org,
         project: project
       } do
    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)
    Application.put_env(:bridge_for_teams_core, :linear_plugin_managed_state, "connected")
    Application.put_env(:bridge_for_teams_core, :linear_plugin_mcp_state, "waiting_for_oauth")

    Application.put_env(:bridge_for_teams_core, :plugin_management_oauth_bindings, [
      %{
        "provider" => "linear",
        "alias" => "linear",
        "enabled" => true,
        "status" => "active",
        "scopes" => ["read", "write"]
      }
    ])

    detail_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear"
    {:ok, view, _html} = live(conn, detail_path)

    view |> element("#connect-plugin-linear-managed", "Connect") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "Linear OAuth")
    refute render(view) =~ "reused"

    view |> element("#continue-connection") |> render_click()

    assert_receive {:prepare_group_plugin_setup, "linear", "linear-managed"}
    assert_receive :list_group_oauth_bindings
    refute_receive {:start_linear_oauth, _params}
    refute has_element?(view, "#connection-detail-modal")
    assert render(view) =~ "Connected"

    Application.put_env(:bridge_for_teams_core, :linear_plugin_mcp_state, "ready_on_use")
    {:ok, view, _html} = live(conn, detail_path)

    view |> element("#reconnect-plugin-linear-managed") |> render_click()
    assert has_element?(view, "#connection-detail-modal", "current credential stays active")

    assert {:error, {:redirect, %{to: "https://linear.app/oauth/authorize"}}} =
             view |> element("#continue-connection") |> render_click()

    assert_receive {:start_linear_oauth, %{"alias" => "linear", "scopes" => ["read"]}}
  end

  test "new plugin surfaces are fully translated for Simplified Chinese", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    {:ok, _view, org_html} = live(conn, ~p"/orgs/#{org.slug}/plugins")
    assert org_html =~ "组织插件"
    assert org_html =~ "系统目录"
    assert org_html =~ "管理启停"
    assert org_html =~ "新建组织插件"

    {:ok, _view, project_html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

    assert project_html =~ "选择此 Agent Swarm 可以使用的产品。"
    assert project_html =~ "2 个已启用 · 1 个已停用"

    Application.put_env(:bridge_for_teams_core, :linear_plugin_live_test, true)

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear")

    refute html =~ "组件"
    assert html =~ "原生 MCP OAuth"
    assert html =~ "等待 OAuth"
    assert html =~ "连接"

    Application.put_env(:bridge_for_teams_core, :linear_plugin_native_state, "connected")
    Application.put_env(:bridge_for_teams_core, :linear_plugin_mcp_state, "ready_on_use")

    {:ok, _view, connected_html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear")

    assert connected_html =~ "重新连接"
    assert connected_html =~ "断开连接"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
