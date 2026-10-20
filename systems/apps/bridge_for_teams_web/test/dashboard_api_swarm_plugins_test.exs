defmodule BridgeForTeamsWeb.DashboardAPISwarmPluginsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Plugins API behind the React Agent Swarm Plugins page: the swarm's
  product plugins with their enablement and setup attention, one plugin's
  MCP servers and connections, Android admission, enable and disable,
  project plugin definitions, and the confirmed connect, reconnect and
  disconnect of plugin credentials. Swarm admins write; a swarm member's
  write is refused with a denied audit; someone outside the swarm gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{Memberships, Observability, Repo}

  defmodule PluginClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_tenant_config(_tenant_id, "android_control", _default) do
      case SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_plugins_android, %{}) do
        {:error, _reason} = error -> error
        config -> {:ok, config}
      end
    end

    def list_group_plugin_definitions(_tenant_id, _group_id) do
      notify(:list_group_plugin_definitions)

      case SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_plugins_error) do
        nil -> {:ok, definitions()}
        reason -> {:error, reason}
      end
    end

    def list_group_plugin_enablements(_tenant_id, _group_id) do
      notify(:list_group_plugin_enablements)
      {:ok, [%{"plugin_id" => "tenant.knowledge", "enabled" => true}]}
    end

    def group_plugin_runtime_projection(_tenant_id, _group_id) do
      notify(:group_plugin_runtime_projection)
      %{"plugin_ids" => [], "revision" => "rev-test"}
    end

    def create_tenant_plugin_definition(_tenant_id, attrs) do
      notify({:create_tenant_plugin, attrs})
      {:ok, Map.put(attrs, "plugin_id", "tenant.created")}
    end

    def update_tenant_plugin_definition(_tenant_id, plugin_id, attrs) do
      notify({:update_tenant_plugin, plugin_id, attrs})
      {:ok, Map.put(attrs, "plugin_id", plugin_id)}
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

    def list_group_oauth_bindings(_group_id) do
      notify(:list_group_oauth_bindings)
      SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_plugins_oauth_bindings, [])
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

    def configure_group_plugin_credentials(tenant, group, plugin, connection, values) do
      notify({:configure_credentials, tenant, group, plugin, connection, values})
      :ok
    end

    defp definitions do
      [
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
          "refs" => %{"skill_refs" => ["release-checklist"]},
          "setup" => %{"destination" => "project_skills"}
        },
        %{
          "plugin_id" => "android-control",
          "name" => "Android Control",
          "description" => "Operate Android",
          "owner_scope" => "system",
          "read_only" => true,
          "default_enabled" => false,
          "ui" => %{"classification" => "capability"},
          "refs" => %{"tool_refs" => ["env.android"]}
        },
        linear(),
        slack()
      ] ++ env(:swarm_plugins_credentials, []) ++ extra()
    end

    defp extra do
      for index <- 1..env(:swarm_plugins_extra, 0)//1 do
        %{
          "plugin_id" => "tenant.extra-#{index}",
          "name" => "Extra #{index}",
          "owner_scope" => "tenant",
          "refs" => %{"tool_refs" => ["extra.#{index}"]}
        }
      end
    end

    defp linear do
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
              "state" => env(:swarm_plugins_native_state, "not_connected")
            },
            %{
              "id" => "linear-managed",
              "kind" => "managed_oauth",
              "label" => "Linear OAuth",
              "state" => env(:swarm_plugins_managed_state, "not_connected")
            },
            %{
              "id" => "linear-composio",
              "kind" => "composio",
              "label" => "Linear via Composio",
              "state" => env(:swarm_plugins_composio_state, "external")
            }
          ],
          "mcps" => [
            %{
              "alias" => "linear",
              "placement" => "server",
              "auth_refs" => ["linear-native", "linear-managed"],
              "state" => env(:swarm_plugins_mcp_state, "waiting_for_oauth")
            }
          ]
        },
        "refs" => %{"tool_refs" => ["mcp.linear.*"]}
      }
    end

    defp slack do
      %{
        "plugin_id" => "slack",
        "name" => "Slack",
        "description" => "Workspace messaging through Slack",
        "owner_scope" => "system",
        "setup_status" => %{
          "type" => "integration",
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
              "state" => "not_connected"
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
        "refs" => %{"im_connect_requirements" => [%{"provider" => "slack"}]}
      }
    end

    defp env(key, default), do: SystemsRuntime.get_env(:bridge_for_teams_core, key, default)

    defp notify(message) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_plugins_test_pid) do
        SystemsRuntime.Proc.send(pid, message)
      end
    end
  end

  @entitled %{
    "version" => 2,
    "enabled" => true,
    "allowed_modes" => ["connected"],
    "allowed_profiles" => ["api30-phone"],
    "max_concurrent_leases" => 1,
    "max_lease_seconds" => 3600
  }

  setup %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Product",
        "slug" => "product"
      })

    put_env(:salix_client, PluginClient)
    put_env(:swarm_plugins_test_pid, SystemsRuntime.Proc.self())
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "list" do
    test "lists product plugins by name with enablement, editing and setup attention", %{
      conn: conn,
      org: org,
      project: project
    } do
      data = conn |> get(plugins_path(org, project)) |> json_response(200) |> data()

      settle_receive(:list_group_plugin_definitions)
      settle_receive(:list_group_plugin_enablements)
      settle_refute_receive(:group_plugin_runtime_projection)
      assert data["project"] == %{"id" => project.id, "name" => "Product", "role" => "admin"}

      # The internal MCP package is not a product plugin.
      assert Enum.map(data["plugins"], & &1["name"]) ==
               [
                 "Android Control",
                 "Core Search",
                 "Knowledge Pack",
                 "Linear",
                 "Release Helper",
                 "Slack"
               ]

      plugins = Map.new(data["plugins"], &{&1["plugin_id"], &1})

      assert %{"enabled" => true, "locked" => true, "toggleable" => false, "editable" => false} =
               plugins["system.search"]

      assert %{"enabled" => true, "locked" => false, "toggleable" => true, "editable" => false} =
               plugins["tenant.knowledge"]

      assert %{
               "enabled" => false,
               "toggleable" => true,
               "editable" => true,
               "owner_scope" => "group",
               "setup_destination" => "project_skills",
               "refs" => %{"skill_refs" => ["release-checklist"], "tool_refs" => []}
             } = plugins["group.release"]

      # Not admitted: visible, but its switch is off.
      assert %{"toggleable" => false, "enabled" => false} = plugins["android-control"]
      assert data["android"] == %{"status" => "ok", "entitled" => false}

      assert plugins["linear"]["attention"] == ["linear"]
      assert plugins["slack"]["attention"] == ["slack", "Slack messaging"]
      assert plugins["tenant.knowledge"]["attention"] == []

      put_env(:swarm_plugins_mcp_state, "ready_on_use")
      data = conn |> get(plugins_path(org, project)) |> json_response(200) |> data()
      assert Enum.find(data["plugins"], &(&1["plugin_id"] == "linear"))["attention"] == []
    end

    test "costs the same queries however many plugins Salix lists", %{
      conn: conn,
      org: org,
      project: project
    } do
      conn |> get(plugins_path(org, project)) |> json_response(200)
      small = query_count(conn, plugins_path(org, project))
      detail = query_count(conn, plugins_path(org, project, "/linear"))

      put_env(:swarm_plugins_extra, 200)
      data = conn |> get(plugins_path(org, project)) |> json_response(200) |> data()
      assert length(data["plugins"]) == 206
      assert query_count(conn, plugins_path(org, project)) == small
      assert query_count(conn, plugins_path(org, project, "/linear")) == detail
    end

    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      for path <- [plugins_path(org, project), plugins_path(org, project, "/linear")] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 build_conn() |> log_in_user(plain) |> get(path) |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn() |> log_in_user(user_fixture()) |> get(path) |> json_response(404)
      end
    end
  end

  describe "detail" do
    test "shows Linear's MCP server with its credentials and the standalone Composio one", %{
      conn: conn,
      org: org,
      project: project
    } do
      data = conn |> get(plugins_path(org, project, "/linear")) |> json_response(200) |> data()

      assert %{"plugin_id" => "linear", "name" => "Linear", "toggleable" => true} = data["plugin"]
      assert data["android"] == nil

      assert %{
               "mcps" => [
                 %{
                   "alias" => "linear",
                   "placement" => "server",
                   "state" => "waiting_for_oauth",
                   "connections" => [native, managed]
                 }
               ],
               "connections" => [composio]
             } = data["plugin"]["setup"]

      assert native == %{
               "id" => "linear-native",
               "kind" => "native_mcp_oauth",
               "label" => "Linear MCP OAuth",
               "state" => "not_connected",
               "dependent_mcps" => ["linear"],
               "action" => "connect",
               "disconnectable" => false,
               "integrations_href" => nil,
               "credential_setup" => nil
             }

      assert %{"kind" => "managed_oauth", "action" => "connect"} = managed

      assert %{"kind" => "composio", "state" => "external", "dependent_mcps" => []} = composio
    end

    test "a plugin the swarm cannot see answers without a plugin", %{
      conn: conn,
      org: org,
      project: project
    } do
      data = conn |> get(plugins_path(org, project, "/missing")) |> json_response(200) |> data()
      assert data["plugin"] == nil
      assert data["project"]["id"] == project.id
    end
  end

  describe "enablement" do
    test "the switch changes only the group enablement", %{conn: conn, org: org, project: project} do
      assert %{"notice" => "Plugin enabled."} =
               conn
               |> put(plugins_path(org, project, "/group.release/enablement"), %{
                 "enabled" => true
               })
               |> json_response(200)
               |> data()

      settle_receive({:enable_plugin, "group.release"})

      assert %{"notice" => "Plugin disabled."} =
               conn
               |> put(plugins_path(org, project, "/tenant.knowledge/enablement"), %{
                 "enabled" => false
               })
               |> json_response(200)
               |> data()

      settle_receive({:disable_plugin, "tenant.knowledge"})
      settle_refute_receive({:create_tenant_plugin, _})
      settle_refute_receive({:update_tenant_plugin, _, _})

      assert %{"error" => %{"code" => "invalid_enablement"}} =
               conn
               |> put(plugins_path(org, project, "/group.release/enablement"), %{
                 "enabled" => "on"
               })
               |> json_response(422)
    end

    test "Android needs tenant admission, read again when it is turned on", %{
      conn: conn,
      org: org,
      project: project
    } do
      path = plugins_path(org, project, "/android-control/enablement")

      assert %{
               "error" => %{
                 "code" => "android_not_entitled",
                 "message" => "Android connector access is not enabled for this organization."
               }
             } = conn |> put(path, %{"enabled" => true}) |> json_response(409)

      settle_refute_receive({:enable_plugin, "android-control"})
      put_env(:swarm_plugins_android, {:error, :timeout})

      assert %{
               "error" => %{
                 "code" => "android_unavailable",
                 "message" => "Android admission status is unavailable. Try again shortly."
               }
             } = conn |> put(path, %{"enabled" => true}) |> json_response(503)

      settle_refute_receive({:enable_plugin, "android-control"})
      put_env(:swarm_plugins_android, @entitled)

      assert %{"notice" => "Plugin enabled."} =
               conn |> put(path, %{"enabled" => true}) |> json_response(200) |> data()

      settle_receive({:enable_plugin, "android-control"})
      # The Devices page reads the same admission.
      assert %{"android" => %{"entitled" => true, "profiles" => ["api30-phone"]}} =
               conn
               |> get("/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/devices")
               |> json_response(200)
               |> data()

      # Turning it off needs no admission.
      put_env(:swarm_plugins_android, %{})

      assert %{"notice" => "Plugin disabled."} =
               conn |> put(path, %{"enabled" => false}) |> json_response(200) |> data()
    end
  end

  describe "project plugin definitions" do
    test "an admin creates and updates a project plugin with audits", %{
      conn: conn,
      org: org,
      project: project
    } do
      body = %{
        "name" => "Docs",
        "description" => "Project docs",
        "setup_destination" => "project_connections",
        "refs" => %{"tool_refs" => ["docs.search", %{"tool" => "docs.read"}], "skill_refs" => []}
      }

      assert %{"plugin_id" => "group.created", "notice" => "Plugin created: group.created."} =
               conn |> post(plugins_path(org, project), body) |> json_response(201) |> data()

      settle_receive({:create_group_plugin, attrs})
      assert attrs["name"] == "Docs"
      assert attrs["setup"] == %{"destination" => "project_connections"}
      assert attrs["refs"]["tool_refs"] == ["docs.search", %{"tool" => "docs.read"}]

      # Without refs an update keeps the plugin's capabilities.
      assert %{"notice" => "Plugin updated."} =
               conn
               |> put(plugins_path(org, project, "/group.release"), %{"name" => "Release"})
               |> json_response(200)
               |> data()

      settle_receive({:update_group_plugin, "group.release", update})
      assert update["name"] == "Release"
      refute Map.has_key?(update, "refs")

      assert [_] =
               Observability.list_audit_logs(org.id, action: "plugin.group_definition.created")

      assert [_] =
               Observability.list_audit_logs(org.id, action: "plugin.group_definition.updated")
    end
  end

  describe "connections" do
    test "native MCP OAuth starts at the provider and returns to the plugin page", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{"redirect_url" => "https://linear.app/oauth/authorize"} =
               conn
               |> post(connection_path(org, project, "linear", "linear-native", "connect"))
               |> json_response(200)
               |> data()

      settle_receive({:prepare_group_plugin_setup, "linear", "linear-native"})
      settle_receive({:start_linear_mcp_oauth, "mcpb-linear", params})

      assert params["redirect_after"] =~
               ~r{^http://[^/]+/orgs/#{org.slug}/projects/#{project.id}/plugins/linear$}

      assert params["scopes"] == ~w(read write openid email)
    end

    test "a connected native MCP reconnects and disconnects", %{
      conn: conn,
      org: org,
      project: project
    } do
      put_env(:swarm_plugins_native_state, "connected")
      put_env(:swarm_plugins_mcp_state, "ready_on_use")

      data = conn |> get(plugins_path(org, project, "/linear")) |> json_response(200) |> data()
      [%{"connections" => [native, _managed]}] = data["plugin"]["setup"]["mcps"]
      assert %{"action" => "reconnect", "disconnectable" => true} = native

      assert %{"redirect_url" => _} =
               conn
               |> post(connection_path(org, project, "linear", "linear-native", "connect"))
               |> json_response(200)
               |> data()

      settle_receive({:start_linear_mcp_oauth, "mcpb-linear", _params})

      assert %{"notice" => "Connection disconnected."} =
               conn
               |> post(connection_path(org, project, "linear", "linear-native", "disconnect"))
               |> json_response(200)
               |> data()

      settle_receive({:disconnect_linear_mcp_oauth, "mcpb-linear"})
    end
  end

  test "API token setup writes only for a swarm admin and never returns the token", %{
    conn: conn,
    org: org,
    project: project
  } do
    put_env(:swarm_plugins_credentials, [
      %{
        "plugin_id" => "x-twitter",
        "name" => "X",
        "owner_scope" => "system",
        "refs" => %{},
        "setup_status" => %{
          "type" => "integration",
          "mcps" => [],
          "connections" => [
            %{
              "id" => "x-token",
              "kind" => "mcp_api_key",
              "label" => "X",
              "state" => "not_connected",
              "config_key" => "X_BEARER_TOKEN",
              "credential_label" => "App-only Bearer Token",
              "help_url" => "https://docs.x.com/tools/mcp"
            }
          ]
        }
      }
    ])

    path = connection_path(org, project, "x-twitter", "x-token", "connect")
    values = %{"X_BEARER_TOKEN" => "test-only-token"}
    {member, _} = member_conn(org, project)
    member |> post(path, %{"config_values" => values}) |> json_response(403)
    settle_refute_receive({:configure_credentials, _, _, _, _, _})
    response = conn |> post(path, %{"config_values" => values}) |> json_response(200)
    assert data(response) == %{"notice" => "Connected"}
    tenant = org.salix_tenant_id
    group = project.salix_group_id
    settle_receive({:configure_credentials, ^tenant, ^group, "x-twitter", "x-token", ^values})
    settle_refute_receive({:prepare_group_plugin_setup, _, _})
  end

  describe "authorization" do
    test "a swarm member cannot write; each attempt is audited", %{org: org, project: project} do
      {member_conn, member} = member_conn(org, project)

      writes = [
        {:put, plugins_path(org, project, "/group.release/enablement"), %{"enabled" => true},
         "plugin.group_enablement.enabled"},
        {:post, plugins_path(org, project), %{"name" => "Docs"},
         "plugin.group_definition.created"},
        {:put, plugins_path(org, project, "/group.release"), %{"name" => "X"},
         "plugin.group_definition.updated"},
        {:post, connection_path(org, project, "linear", "linear-native", "connect"), %{},
         "plugin.setup.authorization_started"},
        {:post, connection_path(org, project, "linear", "linear-native", "disconnect"), %{},
         "connection.disconnect"}
      ]

      for {method, path, body, action} <- writes do
        assert %{
                 "error" => %{
                   "code" => "forbidden",
                   "message" => "Only Agent Swarm admins can manage plugins."
                 }
               } =
                 member_conn
                 |> dispatch(@endpoint, method, path, body)
                 |> json_response(403)

        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.actor_user_id == member.id
        assert audit.metadata["project_id"] == project.id
        assert audit.metadata["surface"] == "plugins"
      end

      settle_refute_receive({:enable_plugin, _})
      settle_refute_receive({:create_group_plugin, _})
      settle_refute_receive({:update_group_plugin, _, _})
      settle_refute_receive({:prepare_group_plugin_setup, _, _})
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      conn = get(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      path = plugins_path(org, project, "/group.release/enablement")

      assert_error_sent(403, fn -> put(conn, path, %{"enabled" => true}) end)
      settle_refute_receive({:enable_plugin, _})

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> put(path, %{"enabled" => true})
               |> json_response(200)
    end
  end

  defp plugins_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/plugins#{rest}"

  defp connection_path(org, project, plugin, connection, action),
    do: plugins_path(org, project, "/#{plugin}/connections/#{connection}/#{action}")

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp put_env(key, value) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, key)
    SystemsRuntime.put_env(:bridge_for_teams_core, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:bridge_for_teams_core, key),
        else: SystemsRuntime.put_env(:bridge_for_teams_core, key, previous)
    end)
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "swarm-plugins-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
