defmodule BridgeForTeamsWeb.Dashboard.MemberOnboardingLiveTest do
  @moduledoc """
  Dashboard onboarding flow: the welcome modal on first login, the floating
  quick-setup checklist (expand/collapse/celebrate, plus "Skip setup" which
  ends onboarding for good), the guided tour skeleton (skipping a step marks
  it done), step completion reacting to real actions (creating an Agent
  Swarm, saving an org OAuth app), and the member→admin OAuth reminder loop.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Agents, Memberships, Onboarding, OrgOAuthApps}

  # The overlays render in the LiveView shell. The organization Overview is
  # served by the React dashboard, so these tests land on another org page.

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
       %{conn: conn, org: org} do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/members")

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
    assert html =~ "0/3"
    # The tour points at the Agent Swarms nav entry for the swarm step.
    assert html =~ "onboarding-tour"
    assert html =~ "data-target=\"[data-tour=&#39;nav-swarms&#39;]\""
  end

  test "\"maybe later\" collapses the checklist into the pill", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")

    html = view |> element("button", "Maybe later") |> render_click()

    refute html =~ "onboarding-welcome"
    refute html =~ "onboarding-checklist"
    assert html =~ "onboarding-collapsed"

    html = view |> element("#onboarding-collapsed") |> render_click()
    assert html =~ "onboarding-checklist"
  end

  test "skip setup ends onboarding for good — nothing resurfaces", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")
    view |> element("button", "Start setup") |> render_click()

    html = view |> element("button", "Skip setup") |> render_click()
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-collapsed"

    # Gone for good on subsequent visits.
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-welcome"
    refute html =~ "onboarding-collapsed"
  end

  test "skipping a tour step marks it done and advances the tour",
       %{conn: conn, org: org, user: user} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")
    view |> element("button", "Start setup") |> render_click()

    # The tour starts on the swarm step; skipping it counts as done and the
    # tour moves on to the OAuth step (Settings nav entry).
    html = view |> element("button", "Skip this step") |> render_click()
    assert html =~ "1/3"
    assert html =~ "data-target=\"[data-tour=&#39;nav-settings&#39;]\""
    assert "swarm" in Onboarding.get_state(org.id, user.id).skipped_steps
  end

  test "creating an Agent Swarm completes the swarm step and advances the tour",
       %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")
    view |> element("button", "Start setup") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    view |> element("#new-project-button") |> render_click()

    html =
      view
      |> form("#new-project-form", project: %{name: "Billing", slug: "billing"})
      |> render_submit()

    assert html =~ "1/3"
    # Tour advanced to the OAuth step, pointing at the Settings nav entry.
    assert html =~ "data-target=\"[data-tour=&#39;nav-settings&#39;]\""
  end

  test "saving an OAuth app completes the oauth step immediately", %{conn: conn, org: org} do
    {:ok, _} = Onboarding.mark_welcome_seen(org.id, socket_user_id(conn), active_step: "oauth")

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")
    assert html =~ "0/3"

    html =
      view
      |> form("#oauth-form-github", oauth: %{client_id: "cid", client_secret: "sec"})
      |> render_submit()

    assert html =~ "1/3"
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

    [intended_router] = Agents.list_agents(intended_project.id, limit: 1, role: "router")

    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Onboarding.invalidate_oauth_cache(org.id)
    :ok = Onboarding.observe_connected(org.id, user.id)
    {:ok, _} = Onboarding.mark_welcome_seen(org.id, user.id, active_step: nil)

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/members")
    assert html =~ "Setup complete!"

    assert has_element?(
             view,
             "#onboarding-slack-context-cta[href='/orgs/#{org.slug}/triage/context?agent=#{intended_router.id}']",
             "Let Comma learn about your team"
           )

    use_slack_context_preview(false)
    {:ok, hidden_view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")
    refute has_element?(hidden_view, "#onboarding-slack-context-cta")

    snapshot = Onboarding.snapshot(org, user.id, "owner")
    assert snapshot.done_count == snapshot.total
    assert snapshot.all_done?

    html = view |> element("button", "Done") |> render_click()
    refute html =~ "onboarding-checklist"

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")
    refute html =~ "onboarding-checklist"
    refute html =~ "onboarding-welcome"
  end

  test "member flow: two steps, blocked connect step reminds the admins",
       %{conn: _conn, org: org, user: owner} do
    {member_conn, member} = member_conn(org)

    {:ok, view, html} = live(member_conn, ~p"/orgs/#{org.slug}/members")
    # Member welcome lists two steps, no OAuth step.
    assert html =~ "Create an Agent Swarm"
    refute html =~ "Configure OAuth clients"

    view |> element("button", "Start setup") |> render_click()

    # A member with a swarm but no org OAuth config is blocked on connect.
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Mine", "slug" => "mine"},
        creator_user_id: member.id
      )

    {:ok, view, html} =
      live(member_conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

    assert html =~ "1/2"
    assert html =~ "Waiting for an admin to configure OAuth"
    assert html =~ "Connect an account"
    assert html =~ "setup required"

    assert html =~
             "An organization admin must configure this OAuth app before accounts can be connected."

    html = view |> element("#onboarding-checklist button", "Remind the admins") |> render_click()
    assert html =~ "Admins reminded"

    # The admin sees the pending reminder on Settings → OAuth apps.
    admin_conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)
    {:ok, _view, html} = live(admin_conn, ~p"/orgs/#{org.slug}/settings/oauth")
    assert html =~ "oauth-reminders"
    assert html =~ "Li Na"
  end

  test "admins get the global OAuth-reminder toast until a client is configured",
       %{conn: conn, org: org, user: owner} do
    {member_conn, member} = member_conn(org)
    {:ok, _} = Onboarding.remind_admins(org.id, member.id)
    {:ok, _} = Onboarding.celebrate(org.id, owner.id)

    # Shows for the admin on any page (even with their own onboarding closed)…
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")
    assert html =~ "oauth-reminder-toast"
    assert html =~ "member is waiting for OAuth clients"

    # …but not on the OAuth settings page (the banner covers it there)…
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")
    refute html =~ "oauth-reminder-toast"
    assert html =~ "oauth-reminders"

    # …and not for members.
    {:ok, _view, html} = live(member_conn, ~p"/orgs/#{org.slug}/members")
    refute html =~ "oauth-reminder-toast"

    # Configuring a client clears it everywhere.
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Onboarding.invalidate_oauth_cache(org.id)
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")
    refute html =~ "oauth-reminder-toast"
  end

  defp socket_user_id(conn) do
    {:ok, %{user_id: user_id}} =
      BridgeForTeams.Auth.Sessions.fetch(
        Plug.Conn.get_session(conn, BridgeForTeamsWeb.Dashboard.Auth.session_token_key())
      )

    user_id
  end

  defp use_slack_context_preview(enabled?) do
    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :onboarding_preview, enabled?)
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    :ok
  end
end
