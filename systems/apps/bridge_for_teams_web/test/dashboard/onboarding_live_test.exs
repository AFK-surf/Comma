defmodule BridgeForTeamsWeb.Dashboard.OnboardingLiveTest do
  @moduledoc """
  First-run onboarding: the `:require_onboarded` gate bounces fresh users from
  the dashboard to `/onboarding`, the four steps advance and persist, and
  finishing (or skipping) opens the gate.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Agents, WorkspaceItems, UserOnboardings}

  defp log_in_fresh_owner(%{conn: conn}) do
    %{user: user, org: org} = org_with_owner_fixture()
    %{conn: log_in_user(conn, user, onboarded: false), user: user, org: org}
  end

  test "gate: a fresh user is redirected from / to /onboarding", %{conn: conn} do
    %{conn: conn} = log_in_fresh_owner(%{conn: conn})

    assert redirected_to(get(conn, ~p"/")) == "/onboarding"
  end

  test "gate: CLI device login is exempt", %{conn: conn} do
    %{conn: conn} = log_in_fresh_owner(%{conn: conn})

    assert {:ok, _view, _html} = live(conn, ~p"/cli/device-login")
  end

  test "gate: Settings → Composio is exempt so admins can configure the key mid-onboarding",
       %{conn: conn} do
    %{conn: conn, org: org} = log_in_fresh_owner(%{conn: conn})

    # The integrations step's "Configure in Settings" link lands here.
    assert {:ok, _view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/composio")

    # Every other settings tab stays gated.
    assert {:error, {:redirect, %{to: "/onboarding"}}} =
             live(conn, ~p"/orgs/#{org.slug}/settings")
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
    # integrations and finish steps have somewhere for their work to land.
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
    assert onboarding.capabilities["informed.morning_briefing"] == true
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

  test "integrations step degrades without a project and Skip advances", %{conn: conn} do
    # Only a user with no org at all lacks a project now — an org user gets a
    # swarm auto-created on mount.
    user = user_fixture()
    conn = log_in_user(conn, user, onboarded: false)

    {:ok, view, html} = live(conn, ~p"/onboarding/integrations")
    assert html =~ "No Agent Swarm yet"

    render_click(view, "integrations_continue", %{})
    assert_patch(view, "/onboarding/tasks")

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.current_step == "tasks"
  end

  test "tasks step persists selected + custom tasks and completes onboarding", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(__MODULE__.DispatchClient)

    # A swarm the user OWNS (explicit admin ACL — implied org-admin access
    # doesn't count as ownership, so without this the mount would auto-create
    # a second swarm) for the selected tasks to land on.
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    {:ok, _worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, view, html} = live(conn, ~p"/onboarding/tasks")
    assert html =~ "Suggested starter tasks"

    render_submit(view, "add_custom_task", %{"custom" => %{"title" => "Track fund II pipeline"}})
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    assert UserOnboardings.onboarded?(user.id)

    tasks =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, source: "onboarding")
      |> Enum.reject(&(&1.payload["offer"] == "report"))

    # The custom task remains general. Starter Tasks carry their target
    # category in canonical Conversation metadata from creation, so projection
    # does not need a later synthetic Message to move the row between widgets.
    assert Enum.any?(tasks, &(&1.title == "Track fund II pipeline" and &1.category == "general"))

    assert Enum.all?(tasks, fn task ->
             case task.payload["category"] do
               nil -> task.category == "general"
               target -> task.category == target
             end
           end)

    assert Enum.any?(tasks, fn task ->
             task.payload["category"] in ["email_drafts", "meeting_recaps", "inbox", "routines"]
           end)

    assert Enum.all?(tasks, &(&1.status == "in_progress"))
    assert Enum.all?(tasks, &is_binary(&1.salix_conversation_id))
    # Suggestions were pre-selected, so more than just the custom task landed.
    assert length(tasks) > 1
  end

  # Scripted seam for the finish-time task delegation: conversation create and
  # prompt delivery succeed; the integrations surfaces the tasks step also
  # loads degrade to empty.
  defmodule DispatchClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore, :group_router

    @store __MODULE__.Store

    def get_agent_projection(agent_id, tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "tenant_id" => tenant_id,
         "role" => "router",
         "router_session_id" => "ses1_0000000000000000001"
       }}
    end

    # Integrations surfaces degrade to "Composio unconfigured" + no connects.
    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => false,
        "api_key_configured" => false,
        "base_url" => "",
        "source" => "none"
      }

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    # Finishing also materializes time-shaped capabilities into schedules —
    # tracked in app env so the two-phase create (create, then stamp the
    # schedule's own id into its prompt) can list and update what it created.
    def create_schedule(attrs) do
      schedule = Map.merge(attrs, %{"created_at" => 1_700_000_000_000, "last_run" => nil})
      Application.put_env(:bridge_for_teams_core, :test_ob_schedules, [schedule | schedules()])
      {:ok, schedule}
    end

    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, schedules()}

    def update_schedule(id, changes) do
      updated =
        Enum.map(schedules(), fn schedule ->
          if schedule["id"] == id, do: Map.merge(schedule, changes), else: schedule
        end)

      Application.put_env(:bridge_for_teams_core, :test_ob_schedules, updated)
      {:ok, Enum.find(updated, %{"id" => id}, &(&1["id"] == id))}
    end

    defp schedules, do: Application.get_env(:bridge_for_teams_core, :test_ob_schedules, [])

    def create_group_conversation(group_id, attrs),
      do: BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, attrs)

    def create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs) do
      participants = [
        %{
          "participant_id" => SalixStore.Ids.new_participant_id(),
          "actor_type" => "agent",
          "agent_id" => delegator_agent_id,
          "role_label" => "delegator"
        },
        %{
          "participant_id" => SalixStore.Ids.new_participant_id(),
          "actor_type" => "agent",
          "agent_id" => worker_agent_id,
          "role_label" => "worker"
        }
      ]

      with {:ok, conversation} <-
             create_group_conversation(group_id, %{
               "title" => attrs["title"],
               "kind" => "agent_task",
               "status" => "active",
               "owner_user_id" => attrs["owner_user_id"],
               "metadata" => attrs["conversation_metadata"] || %{},
               "source_refs" => attrs["source_refs"] || %{},
               "labels" => attrs["labels"] || [],
               "latest_artifact" => attrs["latest_artifact"],
               "artifact_manifest" => attrs["artifact_manifest"],
               "participants" => participants
             }),
           {:ok, _message} <-
             append_group_conversation_message(group_id, conversation["conversation_id"], %{
               "client_request_id" => attrs["client_request_id"],
               "kind" => "message",
               "actor_type" => "agent",
               "agent_id" => delegator_agent_id,
               "content" => [%{"type" => "text", "text" => attrs["content"]}],
               "metadata" => %{"message_type" => "task_command"}
             }) do
        {:ok,
         %{
           "conversation_id" => conversation["conversation_id"],
           "conversation_kind" => "agent_task",
           "worker_agent_id" => worker_agent_id,
           "inserted" => true
         }}
      end
    end

    def list_group_conversations(group_id, opts),
      do: BridgeForTeams.TestConversationStore.list_group_conversations(@store, group_id, opts)

    def get_group_conversation(group_id, conversation_id),
      do:
        BridgeForTeams.TestConversationStore.get_group_conversation(
          @store,
          group_id,
          conversation_id
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeams.TestConversationStore.update_group_conversation(
          @store,
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      if Application.get_env(:bridge_for_teams_core, :test_dispatch_append_error) do
        {:error, :unavailable}
      else
        BridgeForTeams.TestConversationStore.append_group_conversation_message(
          @store,
          group_id,
          conversation_id,
          attrs
        )
      end
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeams.TestConversationStore.list_group_conversation_messages(
          @store,
          group_id,
          conversation_id,
          opts
        )
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
      Application.delete_env(:bridge_for_teams_core, :test_dispatch_append_error)
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
    with_salix_client(DispatchClient)

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

  test "finishing onboarding dispatches accepted tasks to the project's Worker", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, DispatchClient)
    BridgeForTeams.TestConversationStore.reset(DispatchClient.Store)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_ob_schedules)
    end)

    # A project (with its default router agent) the user OWNS gives dispatch
    # a target; without the creator ACL the mount would auto-create a second
    # swarm and the flow would land there instead.
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    # Report offers are seeded alongside but are pre-run intent — never
    # dispatched. Everything else became a real delegated conversation.
    {offers, tasks} =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, source: "onboarding")
      |> Enum.split_with(&(&1.payload["offer"] == "report"))

    assert tasks != []
    assert Enum.all?(tasks, &(&1.status == "in_progress"))
    assert Enum.all?(tasks, &is_binary(&1.salix_conversation_id))
    assert Enum.all?(tasks, &(&1.salix_agent_id == worker.salix_agent_id))
    assert Enum.all?(offers, &(&1.status == "suggested"))
  end

  test "finishing onboarding seeds a report offer per catalog report series", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, DispatchClient)
    BridgeForTeams.TestConversationStore.reset(DispatchClient.Store)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_ob_schedules)
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    offers =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "reports")
      |> Enum.filter(&(&1.payload["offer"] == "report"))

    report_definitions =
      Enum.filter(
        BridgeForTeams.RoutineSchedules.capability_definitions(),
        &(&1.category == "reports")
      )

    assert length(offers) == length(report_definitions)

    assert Enum.sort(Enum.map(offers, & &1.payload["kind"])) ==
             Enum.sort(Enum.map(report_definitions, & &1.kind))

    for offer <- offers do
      assert offer.status == "suggested"
      assert offer.source == "onboarding"
      # Series is namespaced per user, matching what the Run flow's recurring
      # schedule writes, so one-shot runs and the series share a directory.
      definition =
        Enum.find(report_definitions, &(&1.kind == offer.payload["kind"]))
        |> BridgeForTeams.RoutineSchedules.definition_for_user(user.id)

      assert offer.payload["series"] == definition.series_slug
      refute is_binary(offer.payload["salix_schedule_id"])
    end
  end

  test "restart reopens the flow without wiping anything, and re-finishing never duplicates",
       %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(DispatchClient)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    # First run: grant capabilities, then finish (tasks + offers land).
    {:ok, view, _html} = live(conn, ~p"/onboarding")
    render_click(view, "save_capabilities", %{})
    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")
    assert UserOnboardings.onboarded?(user.id)

    items_before = WorkspaceItems.list_tasks(user.id, project_id: project.id)
    assert items_before != []
    {:ok, %{capabilities: capabilities_before}} = UserOnboardings.get_onboarding(user.id)

    # Restart: back to the first step, gate closed again, nothing wiped.
    conn = post(conn, ~p"/onboarding/restart")
    assert redirected_to(conn) == "/onboarding"

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.status == "in_progress"
    assert onboarding.current_step == "capabilities"
    assert onboarding.completed_at == nil
    # Captured capabilities (including the schedules audit) survive.
    assert onboarding.capabilities == capabilities_before
    refute UserOnboardings.onboarded?(user.id)

    assert length(WorkspaceItems.list_tasks(user.id, project_id: project.id)) ==
             length(items_before)

    # The wizard is enterable again (no bounce to /).
    {:ok, _view, html} = live(conn, ~p"/onboarding")
    assert html =~ "Continue"

    # Re-finishing duplicates nothing: starter suggestions dedupe against the
    # board by title, offers dedupe by series, routines by the audit map.
    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")
    assert UserOnboardings.onboarded?(user.id)

    items_after = WorkspaceItems.list_tasks(user.id, project_id: project.id)
    assert length(items_after) == length(items_before)

    titles = Enum.map(items_after, & &1.title)
    assert titles == Enum.uniq(titles)
  end

  test "restart works for a user who skipped onboarding", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "skip_onboarding", %{})
    assert UserOnboardings.onboarded?(user.id)

    conn = post(conn, ~p"/onboarding/restart")
    assert redirected_to(conn) == "/onboarding"

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    assert onboarding.status == "in_progress"
    refute UserOnboardings.onboarded?(user.id)
  end

  test "the onboarding profile is handed to agents through prompts", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    # Walk the capability and profile steps so the onboarding row carries both.
    {:ok, view, _html} = live(conn, ~p"/onboarding")
    render_click(view, "save_capabilities", %{})
    {:ok, view, _html} = live(conn, ~p"/onboarding/profile")
    render_click(view, "save_profile", %{})

    brief = BridgeForTeams.UserOnboardings.agent_brief(user.id)
    assert is_binary(brief)
    assert brief =~ (user.name || user.email)

    # Task delegation embeds the brief, so workers know who they write for.
    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Draft the note",
          "category" => "general",
          "platform" => "comma",
          "salix_conversation_id" => SalixStore.Ids.new_conversation_id()
        }
      ])

    assert BridgeForTeams.TaskDelegation.prompt(task) =~ brief

    # A user who never onboarded gets no brief.
    other =
      BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.User{
        email: "nobody-#{System.unique_integer([:positive])}@example.com"
      })

    assert BridgeForTeams.UserOnboardings.agent_brief(other.id) == nil
  end

  test "finishing onboarding materializes granted time-shaped capabilities into schedules", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, DispatchClient)
    BridgeForTeams.TestConversationStore.reset(DispatchClient.Store)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_ob_schedules)
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p"},
        creator_user_id: user.id
      )

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
    audit = onboarding.capabilities["_schedules"][project.id]

    # Default (opt-out) capabilities grant every catalog time-shaped
    # capability, so each one is materialized and audited back with its
    # created schedule id. Report series are materializable but live outside
    # the onboarding catalog (the board's report offers opt into them), so
    # finishing onboarding never auto-materializes them.
    assert is_map(audit)

    defaults = BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog.default_capabilities()

    expected =
      BridgeForTeams.RoutineSchedules.materializable_keys()
      |> Enum.filter(&(defaults[&1] == true))

    assert expected != []
    assert Enum.sort(Map.keys(audit)) == Enum.sort(expected)
    refute Enum.any?(Map.keys(audit), &String.starts_with?(&1, "reports."))

    assert Enum.all?(Map.values(audit), &is_binary/1)
  end

  test "a failed dispatch keeps tasks accepted and still finishes onboarding", %{conn: conn} do
    %{conn: conn, user: user, org: org} = log_in_fresh_owner(%{conn: conn})
    with_salix_client(DispatchClient)
    Application.put_env(:bridge_for_teams_core, :test_dispatch_append_error, true)

    # A transient Salix delivery failure keeps the tasks accepted (retryable
    # from the board) while finishing still completes.
    project = bare_project_fixture(org)
    {:ok, _} = BridgeForTeams.Memberships.put_project_member(project.id, user.id, "admin")

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    assert UserOnboardings.onboarded?(user.id)

    tasks =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, source: "onboarding")
      |> Enum.reject(&(&1.payload["offer"] == "report"))

    assert tasks != []
    assert Enum.all?(tasks, &(&1.status == "accepted"))

    assert Enum.all?(tasks, fn task ->
             match?({:ok, _uuid}, Ecto.UUID.cast(task.id)) and
               is_nil(task.salix_conversation_id)
           end)
  end

  test "finishing without any org still completes onboarding (no tasks land)", %{conn: conn} do
    # A user with no org at all: there is nowhere to auto-create a swarm, so
    # the flow still finishes and the board stays honestly empty.
    user = user_fixture()
    conn = log_in_user(conn, user, onboarded: false)

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    assert UserOnboardings.onboarded?(user.id)
    assert BridgeForTeams.Orgs.list_orgs_for_user(user.id) == []
  end

  test "a plain member's onboarding lands on their own auto-created swarm, never someone else's",
       %{conn: conn} do
    # The org already has a swarm the member has no grant on. Entering
    # onboarding auto-creates a swarm of their OWN; their tasks land there.
    %{org: org} = org_with_owner_fixture()
    foreign_swarm = bare_project_fixture(org)

    member = user_fixture()
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, member.id, "member")
    conn = log_in_user(conn, member, onboarded: false)

    {:ok, view, _html} = live(conn, ~p"/onboarding/tasks")
    render_click(view, "finish_onboarding", %{})
    assert_redirect(view, "/")

    assert UserOnboardings.onboarded?(member.id)

    own = BridgeForTeams.Projects.default_project_for_user(org.id, member.id)
    assert own != nil
    assert own.id != foreign_swarm.id
    assert own.created_by_user_id == member.id

    assert WorkspaceItems.list_tasks(member.id, project_id: own.id, source: "onboarding") != []
    assert WorkspaceItems.list_tasks(member.id, project_id: foreign_swarm.id) == []
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
end
