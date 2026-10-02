defmodule BridgeForTeamsWeb.DashboardAPIPluginsTest do
  @moduledoc """
  The Plugins API behind the React page at `/orgs/:org/plugins`: the catalog
  of organization plugins and system product plugins, creating and updating
  organization plugins with their audit, the owner/admin rule, Salix outages
  as `runtime_unavailable`, CSRF protection, and a query count that does not
  grow with the catalog.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Observability}

  defmodule PluginClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_tenant_plugin_definitions(_tenant_id) do
      case Application.get_env(:bridge_for_teams_web, :plugins_api_error) do
        nil -> {:ok, Application.get_env(:bridge_for_teams_web, :plugins_api_definitions, [])}
        reason -> {:error, reason}
      end
    end

    def create_tenant_plugin_definition(_tenant_id, attrs) do
      send(self(), {:create_tenant_plugin, attrs})
      reply(Map.put(attrs, "plugin_id", "tenant.created"))
    end

    def update_tenant_plugin_definition(_tenant_id, plugin_id, attrs) do
      send(self(), {:update_tenant_plugin, plugin_id, attrs})
      reply(Map.put(attrs, "plugin_id", plugin_id))
    end

    defp reply(definition) do
      case Application.get_env(:bridge_for_teams_web, :plugins_api_error) do
        nil -> {:ok, definition}
        reason -> {:error, reason}
      end
    end
  end

  @definitions [
    %{
      "plugin_id" => "system.search",
      "name" => "Core Search",
      "owner_scope" => "system",
      "read_only" => true,
      "setup" => %{"type" => "integration"},
      "refs" => %{"tool_refs" => ["search.web"]}
    },
    %{
      "plugin_id" => "system.mcp-management",
      "name" => "MCP Management",
      "owner_scope" => "system",
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
      "owner_scope" => "group",
      "refs" => %{"skill_refs" => ["release-checklist"]}
    }
  ]

  setup %{conn: conn} do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, PluginClient)
    Application.put_env(:bridge_for_teams_web, :plugins_api_definitions, @definitions)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      Application.delete_env(:bridge_for_teams_web, :plugins_api_definitions)
      Application.delete_env(:bridge_for_teams_web, :plugins_api_error)
    end)

    register_and_log_in_user(%{conn: conn})
  end

  describe "GET /dashboard/api/v1/orgs/:org/plugins" do
    test "lists organization plugins and system product plugins only",
         %{conn: conn, org: org} do
      data = conn |> get(plugins_path(org)) |> json_response(200) |> data()

      assert data["viewer"] == %{"can_manage" => true}
      assert Enum.map(data["plugins"], & &1["plugin_id"]) == ~w(system.search tenant.knowledge)

      [search, knowledge] = data["plugins"]
      assert search["editable"] == false
      assert knowledge["editable"] == true
      assert knowledge["setup_destination"] == "org_oauth"
      assert "org_oauth" in knowledge["setup_targets"]

      assert knowledge["refs"]["oauth_requirements"] == [
               %{"provider" => "notion", "scopes" => ["read"]}
             ]

      assert knowledge["refs"]["skill_refs"] == []
    end

    test "members read the catalog but may not manage it", %{org: org} do
      member = add_member(org, "member")
      member_conn = log_in_user(build_conn(), member)

      assert %{"viewer" => %{"can_manage" => false}, "plugins" => [_, _]} =
               member_conn |> get(plugins_path(org)) |> json_response(200) |> data()

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> post(plugins_path(org), %{"name" => "Docs", "refs" => %{}})
               |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> put(plugin_path(org, "tenant.knowledge"), %{"name" => "Renamed"})
               |> json_response(403)

      refute_received {:create_tenant_plugin, _}
      refute_received {:update_tenant_plugin, _, _}
    end

    test "a Salix outage is runtime_unavailable", %{conn: conn, org: org} do
      for reason <- [:unavailable, :timeout] do
        Application.put_env(:bridge_for_teams_web, :plugins_api_error, reason)

        assert %{"error" => %{"code" => "runtime_unavailable"}} =
                 conn |> get(plugins_path(org)) |> json_response(503)

        assert %{"error" => %{"code" => "runtime_unavailable"}} =
                 conn
                 |> post(plugins_path(org), %{"name" => "Docs", "refs" => %{}})
                 |> json_response(503)
      end
    end

    test "costs the same queries however large the catalog is", %{conn: conn, org: org} do
      small = query_count(conn, plugins_path(org))

      many =
        for n <- 1..30 do
          %{"plugin_id" => "tenant.p#{n}", "name" => "P#{n}", "owner_scope" => "tenant"}
        end

      Application.put_env(:bridge_for_teams_web, :plugins_api_definitions, many)
      assert query_count(conn, plugins_path(org)) == small
    end

    test "answers 404 to a non-member", %{org: org} do
      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(user_fixture())
               |> get(plugins_path(org))
               |> json_response(404)
    end
  end

  describe "writes" do
    test "creates an organization plugin from object refs without a caller plugin id",
         %{conn: conn, org: org, user: user} do
      refs = %{
        "tool_refs" => ["docs.search"],
        "oauth_requirements" => [%{"provider" => "notion", "scopes" => ["read"]}]
      }

      assert %{"plugin_id" => "tenant.created", "name" => "Docs Assistant", "editable" => true} =
               conn
               |> post(plugins_path(org), %{
                 "name" => " Docs Assistant ",
                 "description" => "Searches project documentation",
                 "setup_destination" => "org_oauth",
                 "refs" => refs,
                 "plugin_id" => "caller.chosen"
               })
               |> json_response(201)
               |> data()

      assert_received {:create_tenant_plugin, attrs}
      assert attrs["owner_scope"] == "tenant"
      assert attrs["name"] == "Docs Assistant"
      assert attrs["refs"] == refs
      assert attrs["setup"] == %{"destination" => "org_oauth"}
      refute Map.has_key?(attrs, "plugin_id")

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "plugin.tenant_definition.created")

      assert audit.actor_user_id == user.id
    end

    test "updates an organization plugin and keeps its refs when none are sent",
         %{conn: conn, org: org} do
      assert %{"plugin_id" => "tenant.knowledge", "name" => "Knowledge"} =
               conn
               |> put(plugin_path(org, "tenant.knowledge"), %{
                 "name" => "Knowledge",
                 "description" => ""
               })
               |> json_response(200)
               |> data()

      assert_received {:update_tenant_plugin, "tenant.knowledge", attrs}
      refute Map.has_key?(attrs, "refs")
      refute Map.has_key?(attrs, "setup")
    end

    test "rejects malformed refs and setup destinations before calling Salix",
         %{conn: conn, org: org} do
      for {body, message} <- [
            {%{"refs" => ["docs.search"]}, "Refs JSON must be an object."},
            {%{"refs" => %{"tool_refs" => "docs.search"}},
             "Each capability category must be an array."},
            {%{"refs" => %{}, "setup_destination" => "elsewhere"},
             "Choose a valid setup destination."}
          ] do
        assert %{"error" => %{"code" => "invalid_plugin", "message" => ^message}} =
                 conn
                 |> post(plugins_path(org), Map.put(body, "name", "Docs"))
                 |> json_response(422)
      end

      refute_received {:create_tenant_plugin, _}
    end

    test "passes on Salix's validation message", %{conn: conn, org: org} do
      Application.put_env(
        :bridge_for_teams_web,
        :plugins_api_error,
        {:bad_request, "name is required"}
      )

      assert %{"error" => %{"code" => "invalid_plugin", "message" => "name is required"}} =
               conn
               |> post(plugins_path(org), %{"name" => "", "refs" => %{}})
               |> json_response(422)
    end

    test "need the page's CSRF token", %{conn: conn, org: org} do
      conn = get(conn, ~p"/orgs/#{org.slug}/plugins")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn -> post(conn, plugins_path(org), %{"name" => "No token"}) end)
      refute_received {:create_tenant_plugin, _}

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(plugins_path(org), %{"name" => "With token", "refs" => %{}})
               |> json_response(201)
    end
  end

  defp plugins_path(org), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/plugins"
  defp plugin_path(org, id), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/plugins/#{id}"
  defp data(%{"data" => data}), do: data

  defp add_member(org, role) do
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
    user
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "plugins-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
