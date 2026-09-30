defmodule BridgeForTeamsWeb.Dashboard.HomeLiveTest do
  @moduledoc """
  Smoke test for the dashboard foundation: GET "/" while logged in renders the
  app shell + HomeLive, and an anonymous request is redirected to /login. Proves
  the endpoint, router, on_mount auth hook, layout, and HomeLive all wire up.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Agents, DashboardProjection, Memberships, Orgs}

  @icon "data:image/png;base64,iVBORw0KGgo="

  defmodule AnalyticsSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_conversations(group_id, _opts) do
      notify({:list_group_conversations, group_id})

      conversations =
        :bridge_for_teams_core
        |> Application.get_env(:analytics_test_conversations, %{})
        |> Map.get(group_id, [])

      {:ok, %{"data" => conversations}}
    end

    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}

    def billing_history(agent_id, tenant_id, _opts) do
      notify({:billing_history, agent_id, tenant_id})

      entries =
        :bridge_for_teams_core
        |> Application.get_env(:analytics_test_billing_histories, %{})
        |> Map.get({agent_id, tenant_id}, [])

      {:ok, %{"data" => entries}}
    end

    defp notify(message) do
      if pid = Application.get_env(:bridge_for_teams_core, :analytics_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule FailingAnalyticsSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_conversations(_group_id, _opts), do: raise("analytics unavailable")
    def billing_history(_agent_id, _tenant_id, _opts), do: raise("analytics unavailable")
    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}
  end

  defmodule SlowBillingAnalyticsSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_conversations(group_id, _opts) do
      notify({:list_group_conversations, group_id})
      {:ok, %{"data" => [%{"conversation_id" => "conv-slow-billing"}]}}
    end

    def billing_history(agent_id, tenant_id, _opts) do
      notify({:billing_history_started, self(), agent_id, tenant_id})

      receive do
        :release_slow_billing ->
          {:ok, %{"data" => [%{"input_tokens" => 999, "total_tokens" => 999}]}}
      after
        5_000 ->
          {:ok, %{"data" => [%{"input_tokens" => 999, "total_tokens" => 999}]}}
      end
    end

    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}

    defp notify(message) do
      if pid = Application.get_env(:bridge_for_teams_core, :analytics_test_pid) do
        send(pid, message)
      end
    end
  end

  test "GET / while logged in renders the shell and HomeLive", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, _view, html} = live(conn, ~p"/")

    # App shell: sidebar nav + topbar search affordance.
    assert html =~ "Home"
    assert html =~ "Organizations"
    assert html =~ "⌘K"
    assert html =~ ~s(id="dashboard-logout")
    assert html =~ "bottom-full"
    # Active org appears in the switcher.
    assert html =~ org.name
    # HomeLive content.
    assert html =~ "Welcome back"
    assert html =~ "Agent Swarms"
    assert html =~ "Agent Swarm activity"
    assert html =~ "Token usage"
  end

  test "GET / static render does not wait for Salix analytics", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Slow Analytics",
        "slug" => "slow-analytics"
      })

    [agent | _] = Agents.list_agents(project.id)

    with_analytics_client(
      conversations: %{project.salix_group_id => [%{"conversation_id" => "conv-slow"}]},
      billing_histories: %{{agent.salix_agent_id, org.salix_tenant_id} => []}
    )

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Welcome back"
    assert html =~ "Agent Swarm activity"
    assert html =~ "Loading"
    assert html =~ "..."

    refute_received {:list_group_conversations, _group_id}
    refute_received {:billing_history, _agent_id, _tenant_id}
  end

  test "GET / shows unavailable values when the analytics projection refresh failed", %{
    conn: conn
  } do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Failing Analytics",
        "slug" => "failing-analytics"
      })

    assert {:ok, _snapshot} =
             DashboardProjection.upsert_snapshot(project, %{
               refresh_error: "analytics unavailable"
             })

    with_analytics_client(client: FailingAnalyticsSalixClient)

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_until(view, &(&1 =~ "Unavailable" and &1 =~ "—"))

    assert html =~ ~r/Created.*?text-xl[^>]*>—<\/div>/s
    assert html =~ ~r/Total tokens.*?text-xl[^>]*>—<\/div>/s
    refute html =~ ~r/Created.*?text-xl[^>]*>0<\/div>/s
    refute html =~ ~r/Total tokens.*?text-xl[^>]*>0<\/div>/s
  end

  test "GET / shows project activity and token usage statistics", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, used_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Support",
        "slug" => "support"
      })

    {:ok, unused_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Backoffice",
        "slug" => "backoffice"
      })

    [usage_agent | _] = Agents.list_agents(used_project.id)
    usage_agent_id = usage_agent.salix_agent_id
    tenant_id = org.salix_tenant_id

    with_analytics_client(
      conversations: %{
        used_project.salix_group_id => [
          %{
            "conversation_id" => "conv-usage",
            "title" => "Usage backed conversation",
            "participants" => [
              %{"actor_type" => "user"},
              %{
                "actor_type" => "agent",
                "agent_id" => usage_agent_id
              }
            ]
          }
        ]
      },
      billing_histories: %{
        {usage_agent_id, tenant_id} => [
          %{
            "input_tokens" => 120,
            "output_tokens" => 45,
            "total_tokens" => 165,
            "cache_read_input_tokens" => 20
          }
        ]
      }
    )

    DashboardProjection.subscribe(used_project.id)
    DashboardProjection.subscribe(unused_project.id)

    {:ok, view, _html} = live(conn, ~p"/")

    group_id = used_project.salix_group_id
    assert_receive {:list_group_conversations, ^group_id}, 500
    assert_receive {:billing_history, ^usage_agent_id, ^tenant_id}, 500
    used_project_id = used_project.id
    unused_project_id = unused_project.id
    assert_receive {:dashboard_projection_refreshed, ^used_project_id}, 500
    assert_receive {:dashboard_projection_refreshed, ^unused_project_id}, 500

    html = render_until(view, &(&1 =~ "Support" and &1 =~ "165" and &1 =~ "1 task"))

    assert html =~ ~s(id="home-statistics")
    assert html =~ "Agent Swarm activity"
    assert html =~ "Created"
    assert html =~ "Used"
    assert html =~ "Unused"
    assert html =~ "Token usage"
    assert html =~ "Total tokens"
    assert html =~ "165"
    assert html =~ "Support"
    # ngettext: count of 1 renders the singular form.
    assert html =~ "1 task"
  end

  test "GET / degrades slow billing history without waiting for Salix timeout", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Slow Billing",
        "slug" => "slow-billing"
      })

    [agent | _] = Agents.list_agents(project.id)
    with_analytics_client(client: SlowBillingAnalyticsSalixClient)

    {:ok, view, _html} = live(conn, ~p"/")

    assert_receive {:billing_history_started, billing_pid, agent_id, tenant_id}, 500
    assert agent_id == agent.salix_agent_id
    assert tenant_id == org.salix_tenant_id

    started = System.monotonic_time(:millisecond)
    html = render_until(view, &(&1 =~ "Slow Billing" and &1 =~ "1 task"), 160)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 2_500
    assert html =~ "Total tokens"
    assert html =~ ~r/Total tokens.*?text-xl[^>]*>0<\/div>/s

    send(billing_pid, :release_slow_billing)
  end

  test "GET / only summarizes projects visible to ordinary org members", %{conn: conn} do
    user = user_fixture()
    org = org_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, _visible} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Visible Usage", "slug" => "visible-usage"},
        creator_user_id: user.id
      )

    {:ok, _hidden} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Hidden Usage",
        "slug" => "hidden-usage"
      })

    conn = log_in_user(conn, user)
    with_analytics_client(conversations: %{}, billing_histories: %{})

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_until(view, &(&1 =~ "Visible Usage"))

    assert html =~ "Visible Usage"
    refute html =~ "Hidden Usage"
  end

  test "anonymous GET / redirects to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login?return_to=%2F"}}} = live(conn, ~p"/")
  end

  test "anonymous GET / with an org slug preserves it for login", %{conn: conn} do
    org = org_fixture()

    conn = get(conn, "/?o=#{org.slug}")

    assert redirected_to(conn) == "/login?o=#{org.slug}&return_to=%2F%3Fo%3D#{org.slug}"
  end

  test "GET /login renders the SSO form for an anonymous user", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)
    assert html =~ "Bridge For Teams"
    assert html =~ "/images/bridge-icon-512.png"
    assert html =~ "Continue with SSO"
  end

  test "GET /login with an org slug renders the org login page", %{conn: conn} do
    org = org_fixture()
    {:ok, org} = Orgs.update_org(org, %{icon: @icon})

    conn = get(conn, "/login?o=#{org.slug}")
    html = html_response(conn, 200)

    assert html =~ org.name
    assert html =~ @icon
    assert html =~ ~s(name="org_slug")
    assert html =~ ~s(value="#{org.slug}")
    refute html =~ "Organization slug"
  end

  defp with_analytics_client(opts) do
    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    prev_conversations =
      Application.get_env(:bridge_for_teams_core, :analytics_test_conversations)

    prev_histories =
      Application.get_env(:bridge_for_teams_core, :analytics_test_billing_histories)

    prev_pid = Application.get_env(:bridge_for_teams_core, :analytics_test_pid)

    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      Keyword.get(opts, :client, AnalyticsSalixClient)
    )

    Application.put_env(:bridge_for_teams_core, :analytics_test_pid, self())

    Application.put_env(
      :bridge_for_teams_core,
      :analytics_test_conversations,
      Keyword.get(opts, :conversations, %{})
    )

    Application.put_env(
      :bridge_for_teams_core,
      :analytics_test_billing_histories,
      Keyword.get(opts, :billing_histories, %{})
    )

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      restore_env(:bridge_for_teams_core, :analytics_test_conversations, prev_conversations)
      restore_env(:bridge_for_teams_core, :analytics_test_billing_histories, prev_histories)
      restore_env(:bridge_for_teams_core, :analytics_test_pid, prev_pid)
    end)
  end

  defp render_until(view, predicate, attempts \\ 20)

  defp render_until(view, predicate, attempts) when attempts > 0 do
    html = render(view)

    if predicate.(html) do
      html
    else
      Process.sleep(25)
      render_until(view, predicate, attempts - 1)
    end
  end

  defp render_until(_view, _predicate, 0), do: flunk("timed out waiting for rendered update")

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
