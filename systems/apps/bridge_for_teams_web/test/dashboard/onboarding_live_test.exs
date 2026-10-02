defmodule BridgeForTeamsWeb.Dashboard.OnboardingLiveTest do
  @moduledoc """
  First-run onboarding: the `:require_onboarded` gate bounces fresh users from
  the dashboard to `/onboarding`, the three steps advance and persist, and
  finishing (or skipping) opens the gate.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{Repo, UserOnboardings}
  alias BridgeForTeams.Schema.UserOnboarding

  defp log_in_fresh_owner(%{conn: conn}) do
    %{user: user, org: org} = org_with_owner_fixture()
    %{conn: log_in_user(conn, user, onboarded: false), user: user, org: org}
  end

  test "gate: a fresh user is redirected from / to /onboarding", %{conn: conn} do
    %{conn: conn} = log_in_fresh_owner(%{conn: conn})

    assert redirected_to(get(conn, ~p"/")) == "/onboarding"
  end

  test "the retired tasks step URL resumes the wizard", %{conn: conn} do
    %{conn: conn} = log_in_fresh_owner(%{conn: conn})

    assert redirected_to(get(conn, "/onboarding/tasks")) == "/onboarding"
  end

  test "gate: CLI device login is exempt", %{conn: conn} do
    %{conn: conn} = log_in_fresh_owner(%{conn: conn})

    assert conn |> get(~p"/cli/device-login") |> html_response(200) =~ ~s(<div id="root"></div>)
  end

  test "gate: Settings → Composio is exempt so admins can configure the key mid-onboarding",
       %{conn: conn} do
    %{conn: conn, org: org} = log_in_fresh_owner(%{conn: conn})

    # The integrations step's "Configure in Settings" link lands here.
    assert conn |> get(~p"/orgs/#{org.slug}/settings/composio") |> html_response(200) =~
             ~s(<div id="root"></div>)

    assert conn |> get(~p"/orgs/#{org.slug}/settings/integrations") |> html_response(200)

    # Every other settings page stays gated.
    assert conn |> get(~p"/orgs/#{org.slug}/settings") |> redirected_to() == "/onboarding"
  end

  test "an onboarded user is redirected away from /onboarding", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/onboarding")
  end

  test "entering onboarding auto-creates an owned swarm for a user who owns none", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})
    assert BridgeForTeams.Projects.default_project_for_user(org.id, user.id) == nil

    {:ok, _view, _html} = live(conn, ~p"/onboarding")

    # The mount created a swarm the user OWNS (creator admin ACL), so the
    # integrations step has somewhere for its connections to land.
    owned = BridgeForTeams.Projects.default_project_for_user(org.id, user.id)
    assert owned != nil
    assert owned.created_by_user_id == user.id

    # Idempotent: re-entering the flow never creates a second swarm.
    {:ok, _view, _html} = live(conn, ~p"/onboarding")
    assert length(BridgeForTeams.Projects.list_projects(org.id)) == 1
  end

  test "capabilities step renders groups and Continue advances to profile", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})

    {:ok, view, html} = live(conn, ~p"/onboarding")
    assert html =~ "Manage Your Inbox"
    assert html =~ "Stay informed"
    assert html =~ "Agent Memory"

    render_click(view, "toggle_capability", %{"key" => "inbox.draft_replies"})
    render_click(view, "save_capabilities", %{})
    assert_patch(view, "/onboarding/profile")

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.current_step == "profile"
    assert onboarding.capabilities["inbox.draft_replies"] == false
    assert onboarding.capabilities["meetings.meeting_briefing"] == true
  end

  test "profile step shows identity and real org contacts", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})
    teammate = user_fixture(%{name: "Terry Teammate"})
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, teammate.id, "member")

    {:ok, _view, html} = live(conn, ~p"/onboarding/profile")

    assert html =~ "Professional Identity"
    assert html =~ "Key Contacts Sample"
    assert html =~ user.email
    assert html =~ "Terry Teammate"
    assert html =~ teammate.email
    assert html =~ "Writing Style Reference"

    # Nothing is connected yet, so the behavioral sections are honest plans
    # ("When connected"), not claims to have already learned anything — and the
    # "your agent researches people" overreach is gone.
    assert html =~ "When connected"
    assert html =~ "once you connect Google"
    refute html =~ "researches the people"
    refute html =~ "Learning"
  end

  test "integrations step degrades without a project and Continue finishes onboarding", %{
    conn: conn
  } do
    # Only a user with no org at all lacks a project now — an org user gets a
    # swarm auto-created on mount.
    user = user_fixture()
    conn = log_in_user(conn, user, onboarded: false)

    {:ok, view, html} = live(conn, ~p"/onboarding/integrations")
    assert html =~ "No Agent Swarm yet"

    render_click(view, "integrations_continue", %{})
    assert_redirect(view, "/")

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.status == "completed"
    assert UserOnboardings.onboarded?(user.id)
  end

  defmodule UnconfiguredComposioClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc "An org without Composio and without IM connects."

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => false,
        "api_key_configured" => false,
        "base_url" => "",
        "source" => "none"
      }

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
  end

  defmodule ComposioClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc "An org with Composio configured, one gmail account already connected."

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => true,
        "api_key_configured" => true,
        "base_url" => "",
        "source" => "tenant"
      }

    def list_composio_connected_accounts(_tenant_id, group_id) do
      {:ok,
       [
         %{
           "id" => "ca_gmail",
           "user_id" => group_id,
           "toolkit" => %{"slug" => "gmail"},
           "status" => "ACTIVE"
         }
       ]}
    end

    def create_composio_connect_link(_tenant_id, _group_id, toolkit, attrs) do
      # Runs in the LiveView process — report back to the test process.
      if pid = Application.get_env(:bridge_for_teams_core, :onboarding_test_pid) do
        send(pid, {:connect_link_requested, toolkit, attrs})
      end

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/lk_onboarding",
         "connected_account_id" => "ca_new"
       }}
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
  end

  defp with_salix_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    BridgeForTeams.TestConversationStore.reset(Module.concat(mod, Store))
    Application.put_env(:bridge_for_teams_core, :onboarding_test_pid, self())

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :onboarding_test_pid)
    end)
  end

  test "integrations step offers every toolkit once Composio is configured", %{conn: conn} do
    %{conn: conn, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(ComposioClient)

    {:ok, _project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, html} = live(conn, ~p"/onboarding/integrations")

    # The already-connected gmail account renders as connected; every other
    # toolkit is connectable — Composio readiness is org-wide, not per-platform.
    assert html =~ "Gmail"
    assert html =~ "Google Calendar"
    assert html =~ "Notion"
    refute has_element?(view, "button[phx-value-toolkit=gmail]")
    assert has_element?(view, "button[phx-value-toolkit=googlecalendar]", "Connect")
    assert has_element?(view, "button[phx-value-toolkit=notion]", "Connect")
    refute html =~ "Configure in Settings"

    # The profile plans treat the gmail toolkit as Google being connected.
    {:ok, _view, profile_html} = live(conn, ~p"/onboarding/profile")
    assert profile_html =~ "Learning"
  end

  test "connect_toolkit hands the browser to the Composio Connect Link", %{conn: conn} do
    %{conn: conn, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(ComposioClient)

    {:ok, _project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, _html} = live(conn, ~p"/onboarding/integrations")

    view
    |> element("button[phx-value-toolkit=notion]", "Connect")
    |> render_click()

    assert_redirect(view, "https://connect.composio.dev/link/lk_onboarding")

    # The Connect Link round-trips the browser back to this step.
    assert_received {:connect_link_requested, "notion", attrs}
    assert attrs["callback_url"] =~ "/onboarding/integrations"
  end

  test "a swarm owner who is only a regular org member can connect accounts", %{conn: conn} do
    # Connecting is swarm-scoped, so the gate is the effective PROJECT role:
    # this user's org role is plain "member", but they own the auto-created
    # swarm — the old org-role gate wrongly told them to ask an org admin.
    %{org: org} = org_with_owner_fixture()
    member = user_fixture()
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, member.id, "member")
    conn = log_in_user(conn, member, onboarded: false)
    with_salix_client(ComposioClient)

    {:ok, view, html} = live(conn, ~p"/onboarding/integrations")

    refute html =~ "Ask a swarm owner"
    assert has_element?(view, "button[phx-value-toolkit=notion]", "Connect")

    view
    |> element("button[phx-value-toolkit=notion]", "Connect")
    |> render_click()

    assert_redirect(view, "https://connect.composio.dev/link/lk_onboarding")
  end

  test "an unconfigured org shows disabled connects and points admins at Composio settings", %{
    conn: conn
  } do
    %{conn: conn, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(UnconfiguredComposioClient)

    {:ok, _project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, html} = live(conn, ~p"/onboarding/integrations")

    refute has_element?(view, "button[phx-value-toolkit=gmail]")
    assert html =~ "Connections need a Composio API key configured once for your organization."
    assert html =~ "/orgs/#{org.slug}/settings/composio"
  end

  test "restart reopens the flow without wiping captured answers", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(UnconfiguredComposioClient)

    # First run: grant capabilities, then finish from the integrations step.
    {:ok, view, _html} = live(conn, ~p"/onboarding")
    render_click(view, "save_capabilities", %{})
    {:ok, view, _html} = live(conn, ~p"/onboarding/integrations")
    render_click(view, "integrations_continue", %{})
    assert_redirect(view, "/")
    assert UserOnboardings.onboarded?(user.id)

    {:ok, %{capabilities: capabilities_before}} = UserOnboardings.get_onboarding(user.id)
    assert capabilities_before != %{}

    # Restart: back to the first step, gate closed again, nothing wiped.
    conn = post(conn, ~p"/onboarding/restart")
    assert redirected_to(conn) == "/onboarding"

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.status == "in_progress"
    assert onboarding.current_step == "capabilities"
    assert onboarding.completed_at == nil
    # Captured capabilities survive.
    assert onboarding.capabilities == capabilities_before
    refute UserOnboardings.onboarded?(user.id)

    # The wizard is enterable again (no bounce to /).
    {:ok, _view, html} = live(conn, ~p"/onboarding")
    assert html =~ "Continue"
  end

  test "restart works for a user who skipped onboarding", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/onboarding/integrations")
    render_click(view, "skip_onboarding", %{})
    assert UserOnboardings.onboarded?(user.id)

    conn = post(conn, ~p"/onboarding/restart")
    assert redirected_to(conn) == "/onboarding"

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.status == "in_progress"
    refute UserOnboardings.onboarded?(user.id)
  end

  test "a plain member's onboarding lands on their own auto-created swarm, never someone else's",
       %{conn: conn} do
    # The org already has a swarm the member has no grant on. Entering
    # onboarding auto-creates a swarm of their OWN; integrations bind there.
    %{org: org} = org_with_owner_fixture()
    foreign_swarm = bare_project_fixture(org)

    member = user_fixture()
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, member.id, "member")
    conn = log_in_user(conn, member, onboarded: false)
    with_salix_client(UnconfiguredComposioClient)

    {:ok, view, _html} = live(conn, ~p"/onboarding/integrations")

    own = BridgeForTeams.Projects.default_project_for_user(org.id, member.id)
    assert own != nil
    assert own.id != foreign_swarm.id
    assert own.created_by_user_id == member.id
    assert has_element?(view, ~s(a[href="/orgs/#{org.slug}/projects/#{own.id}/integrations"]))

    render_click(view, "integrations_continue", %{})
    assert_redirect(view, "/")
    assert UserOnboardings.onboarded?(member.id)
  end

  test "skip onboarding opens the gate", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/onboarding")
    render_click(view, "skip_onboarding", %{})
    assert_redirect(view, "/")

    assert UserOnboardings.onboarded?(user.id)
    assert html_response(get(conn, ~p"/"), 200) =~ ~s(id="root")
  end

  test "bare /onboarding resumes at the stored step", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})

    {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)
    {:ok, _} = UserOnboardings.advance(onboarding, "integrations")

    # The resume push_patch fires during the initial mount, which LiveViewTest
    # surfaces as a live_redirect to follow.
    assert {:error, {:live_redirect, %{to: "/onboarding/integrations"}}} =
             live(conn, ~p"/onboarding")

    assert {:ok, _view, html} = live(conn, ~p"/onboarding/integrations")
    assert html =~ "Supercharge your agent."
  end

  test "a record stored on the retired tasks step resumes on integrations and can finish", %{
    conn: conn
  } do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(UnconfiguredComposioClient)

    {:ok, _onboarding} = UserOnboardings.ensure_onboarding(user.id)

    # Written by the earlier four-step wizard; the changeset no longer accepts it.
    {1, _} =
      Repo.update_all(
        from(o in UserOnboarding, where: o.user_id == ^user.id),
        set: [current_step: "tasks"]
      )

    assert {:error, {:live_redirect, %{to: "/onboarding/integrations"}}} =
             live(conn, ~p"/onboarding")

    {:ok, view, _html} = live(conn, ~p"/onboarding/integrations")
    render_click(view, "integrations_continue", %{})
    assert_redirect(view, "/")
    assert UserOnboardings.onboarded?(user.id)
  end
end
