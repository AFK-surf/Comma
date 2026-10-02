defmodule BridgeForTeamsWeb.Dashboard.MemberOnboardingLiveTest do
  @moduledoc """
  Dashboard onboarding flow: the welcome modal on first login, the floating
  quick-setup checklist (expand/collapse/celebrate, plus "Skip setup" which
  ends onboarding for good), the guided tour skeleton (skipping a step marks
  it done), step completion reacting to real actions (creating an Agent
  Swarm, saving an org OAuth app), the member→admin OAuth reminder loop, and
  the same checklist on the React Overview (`/dashboard/api/v1/orgs/:org/onboarding`).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Onboarding, OrgOAuthApps}

  # The overlays render in the LiveView shell. Every org page is the React
  # dashboard, so the overlays show on an Agent Swarm page: an owner with a
  # swarm has the swarm step done. An owner without one sees the checklist on
  # the React Overview, read from the onboarding API.

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    Onboarding.invalidate_oauth_cache(org.id)
    %{conn: conn, user: user, org: org}
  end

  defp member_conn(org) do
    member = user_fixture(%{name: "Li Na"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {log_in_user(Phoenix.ConnTest.build_conn(), member), member}
  end

  test "first visit shows the welcome modal; starting the tour reveals the checklist",
       %{conn: conn, org: org, user: user} do
    {:ok, view, html} = live(conn, owner_page(org, user))

    assert html =~ "onboarding-welcome"
    assert html =~ "Start setup"
    # Owner flow lists all three steps.
    assert html =~ "Create an Agent Swarm"
    assert html =~ "Configure OAuth clients"
    assert html =~ "Connect a third-party account"

    html = view |> element("button", "Start setup") |> render_click()

    refute html =~ "onboarding-welcome"
    assert html =~ "onboarding-checklist"
    assert html =~ "Quick setup"
    assert html =~ "1/3"
    # The swarm step is done, so the tour points at Settings for OAuth.
    assert html =~ "onboarding-tour"
    assert html =~ "data-target=\"[data-tour=&#39;nav-settings&#39;]\""
  end

  test "\"maybe later\" collapses the checklist into the pill",
       %{conn: conn, org: org, user: user} do
    {:ok, view, _html} = live(conn, owner_page(org, user))

    html = view |> element("button", "Maybe later") |> render_click()

    refute html =~ "onboarding-welcome"
    refute html =~ "onboarding-checklist"
    assert html =~ "onboarding-collapsed"

    html = view |> element("#onboarding-collapsed") |> render_click()
    assert html =~ "onboarding-checklist"
  end

  test "skip setup ends onboarding for good — nothing resurfaces",
       %{conn: conn, org: org, user: user} do
    page = owner_page(org, user)
    {:ok, view, _html} = live(conn, page)
    view |> element("button", "Start setup") |> render_click()

    html = view |> element("button", "Skip setup") |> render_click()
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-collapsed"

    # Gone for good on subsequent visits.
    {:ok, _view, html} = live(conn, page)
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-welcome"
    refute html =~ "onboarding-collapsed"
  end

  test "skipping a tour step marks it done and advances the tour",
       %{conn: conn, org: org, user: user} do
    {:ok, view, _html} = live(conn, owner_page(org, user))
    view |> element("button", "Start setup") |> render_click()

    # The tour starts on the OAuth step; skipping it counts as done.
    html = view |> element("button", "Skip this step") |> render_click()
    assert html =~ "2/3"
    refute html =~ "data-target=\"[data-tour=&#39;nav-settings&#39;]\""
    assert "oauth" in Onboarding.get_state(org.id, user.id).skipped_steps
  end

  test "creating an Agent Swarm completes the swarm step and advances the tour",
       %{conn: conn, org: org, user: user} do
    {:ok, _} = Onboarding.mark_welcome_seen(org.id, user.id, active_step: "swarm")
    refute Onboarding.snapshot(org, user.id, "owner").done["swarm"]

    # The Agent Swarms page creates through the dashboard API.
    assert %{"ok" => true, "data" => %{"id" => project_id}} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{"name" => "Billing"})
             |> json_response(201)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project_id}/plugins")
    assert html =~ "1/3"
    # Tour advanced to the OAuth step, pointing at the Settings nav entry.
    assert html =~ "data-target=\"[data-tour=&#39;nav-settings&#39;]\""
  end

  test "saving an OAuth app completes the oauth step immediately",
       %{conn: conn, org: org, user: user} do
    {:ok, _} = Onboarding.mark_welcome_seen(org.id, socket_user_id(conn), active_step: "oauth")
    page = owner_page(org, user)

    {:ok, _view, html} = live(conn, page)
    assert html =~ "1/3"

    # Settings → Integrations saves through the dashboard API, which drops the
    # cached "no OAuth app" answer so the checklist sees the new app at once.
    assert %{"ok" => true} =
             conn
             |> put(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/integrations/oauth/github", %{
               "client_id" => "cid",
               "client_secret" => "sec"
             })
             |> json_response(200)

    {:ok, _view, html} = live(conn, page)
    assert html =~ "2/3"
  end

  test "all steps done shows the completion card; celebrating hides the widget for good",
       %{conn: conn, org: org, user: user} do
    {:ok, intended_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Zulu", "slug" => "zulu"},
        creator_user_id: user.id
      )

    {:ok, _alphabetically_first_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Alpha",
        "slug" => "alpha"
      })

    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Onboarding.invalidate_oauth_cache(org.id)
    :ok = Onboarding.observe_connected(org.id, user.id)
    {:ok, _} = Onboarding.mark_welcome_seen(org.id, user.id, active_step: nil)

    page = ~p"/orgs/#{org.slug}/projects/#{intended_project.id}/plugins"
    {:ok, view, html} = live(conn, page)
    assert html =~ "Setup complete!"

    # The Slack history import is not part of the React Slack triage yet, so
    # its call to action stays hidden even with the preview on.
    assert Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)[
             :onboarding_preview
           ]

    refute html =~ "Let Comma learn about your team"

    snapshot = Onboarding.snapshot(org, user.id, "owner")
    assert snapshot.done_count == snapshot.total
    assert snapshot.all_done?

    html = view |> element("button", "Done") |> render_click()
    refute html =~ "onboarding-checklist"

    {:ok, _view, html} = live(conn, page)
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-welcome"
  end

  test "member flow: two steps, blocked connect step reminds the admins",
       %{conn: _conn, org: org, user: owner} do
    {member_conn, member} = member_conn(org)
    connections = member_page(org, member, "connections")

    {:ok, view, html} = live(member_conn, connections)
    # Member welcome lists two steps, no OAuth step.
    assert html =~ "Create an Agent Swarm"
    refute html =~ "Configure OAuth clients"

    view |> element("button", "Start setup") |> render_click()

    # A member with a swarm but no org OAuth config is blocked on connect.
    {:ok, view, html} = live(member_conn, connections)

    assert html =~ "1/2"
    assert html =~ "Waiting for an admin to configure OAuth"
    assert html =~ "Connect an account"
    assert html =~ "setup required"

    assert html =~
             "An organization admin must configure this OAuth app before accounts can be connected."

    html = view |> element("#onboarding-checklist button", "Remind the admins") |> render_click()
    assert html =~ "Admins reminded"

    # The admin sees the waiting member on Settings → Integrations.
    admin_conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)

    assert %{"names" => ["Li Na"], "truncated" => false} =
             admin_conn
             |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/integrations")
             |> json_response(200)
             |> get_in(["data", "oauth", "waiting_members"])
  end

  test "admins get the global OAuth-reminder toast until a client is configured",
       %{conn: conn, org: org, user: owner} do
    {member_conn, member} = member_conn(org)
    {:ok, _} = Onboarding.remind_admins(org.id, member.id)
    {:ok, _} = Onboarding.celebrate(org.id, owner.id)

    # Shows for the admin on any page (even with their own onboarding closed)…
    page = owner_page(org, owner)
    {:ok, _view, html} = live(conn, page)
    assert html =~ "oauth-reminder-toast"
    assert html =~ "member is waiting for OAuth clients"

    # …it links to Settings → Integrations, which lists the waiting members…
    assert html =~ ~s(href="/orgs/#{org.slug}/settings/integrations")

    # …and not for members.
    {:ok, _view, html} = live(member_conn, member_page(org, member, "plugins"))
    refute html =~ "oauth-reminder-toast"

    # Configuring a client clears it everywhere.
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Onboarding.invalidate_oauth_cache(org.id)
    {:ok, _view, html} = live(conn, page)
    refute html =~ "oauth-reminder-toast"
  end

  describe "React Overview checklist" do
    test "an owner without an Agent Swarm sees the swarm step; creating one advances it",
         %{conn: conn, org: org, user: user} do
      path = ~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding"

      assert %{
               "active" => true,
               "steps" => [
                 %{"id" => "swarm", "done" => false},
                 %{"id" => "oauth", "done" => false},
                 %{"id" => "connect", "done" => false}
               ],
               "first_project_id" => nil
             } = conn |> get(path) |> json_response(200) |> Map.fetch!("data")

      assert %{"data" => %{"id" => project_id}} =
               conn
               |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{"name" => "Billing"})
               |> json_response(201)

      assert %{
               "active" => true,
               "steps" => [%{"id" => "swarm", "done" => true} | _],
               "first_project_id" => ^project_id
             } = conn |> get(path) |> json_response(200) |> Map.fetch!("data")

      # Skipping ends onboarding for good, in the LiveView shell too.
      assert %{"active" => false} =
               conn
               |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding/dismiss")
               |> json_response(200)
               |> Map.fetch!("data")

      assert Onboarding.get_state(org.id, user.id).dismissed_at
      assert %{"active" => false} = conn |> get(path) |> json_response(200) |> Map.fetch!("data")

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project_id}/plugins")
      refute html =~ "onboarding-checklist"
      refute html =~ "onboarding-welcome"
    end

    test "a member gets the member steps; finishing them is acknowledged, not skipped",
         %{org: org} do
      {member_conn, member} = member_conn(org)
      path = ~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding"

      assert %{"steps" => [%{"id" => "swarm"}, %{"id" => "connect"}]} =
               member_conn |> get(path) |> json_response(200) |> Map.fetch!("data")

      {:ok, _} = Onboarding.skip_step(org.id, member.id, "swarm")
      :ok = Onboarding.observe_connected(org.id, member.id)

      assert %{"active" => false} =
               member_conn
               |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding/dismiss")
               |> json_response(200)
               |> Map.fetch!("data")

      state = Onboarding.get_state(org.id, member.id)
      assert state.celebrated_at
      assert is_nil(state.dismissed_at)
    end
  end

  defp owner_page(org, owner) do
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Ops", "slug" => "ops-#{System.unique_integer([:positive])}"},
        creator_user_id: owner.id
      )

    ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"
  end

  defp member_page(org, member, page) do
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Mine", "slug" => "mine"},
        creator_user_id: member.id
      )

    ~p"/orgs/#{org.slug}/projects/#{project.id}/#{page}"
  end

  defp socket_user_id(conn) do
    {:ok, %{user_id: user_id}} =
      BridgeForTeams.Auth.Sessions.fetch(
        Plug.Conn.get_session(conn, BridgeForTeamsWeb.Dashboard.Auth.session_token_key())
      )

    user_id
  end
end
