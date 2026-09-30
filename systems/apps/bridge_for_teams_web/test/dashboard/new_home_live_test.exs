defmodule BridgeForTeamsWeb.Dashboard.NewHomeLiveTest do
  @moduledoc """
  New Home board: proactive agent items are seeded once per user and rendered
  as typed widgets; the assistant chat panel degrades gracefully when the org
  has no project/agent to back a conversation.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{
    AssistantChats,
    Agents,
    DashboardProjection,
    Environments,
    Memberships,
    Observability,
    Projects,
    Reports,
    WorkspaceItems
  }

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.ProjectDeviceProjection

  defmodule ConversationClient do
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

    def reset, do: BridgeForTeams.TestConversationStore.reset(@store)

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}
    def list_group_meetings(group_id), do: SalixMeet.list_group_meetings(group_id)
    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}
    def list_agent_sites(_agent_id), do: {:ok, []}

    def create_tenant(attrs), do: {:ok, attrs}
    def update_tenant(tenant_id, attrs), do: {:ok, Map.put(attrs, "tenant_id", tenant_id)}
    def get_tenant(tenant_id), do: {:ok, %{"tenant_id" => tenant_id}}
    def get_tenant_config(_tenant_id, _name, default), do: {:ok, default}
    def update_tenant_config(_tenant_id, _name, value), do: {:ok, value}
    def create_group(attrs), do: {:ok, attrs}

    def update_group(group_id, tenant_id, attrs),
      do: {:ok, attrs |> Map.put("group_id", group_id) |> Map.put("tenant_id", tenant_id)}

    def create_agent(attrs), do: {:ok, attrs}

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
             BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, %{
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
             BridgeForTeams.TestConversationStore.append_group_conversation_message(
               @store,
               group_id,
               conversation["conversation_id"],
               %{
                 "client_request_id" => attrs["client_request_id"],
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => delegator_agent_id,
                 "content" => [%{"type" => "text", "text" => attrs["content"]}],
                 "metadata" => %{"message_type" => "task_command"}
               }
             ) do
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

    def append_group_conversation_message(group_id, conversation_id, attrs),
      do:
        BridgeForTeams.TestConversationStore.append_group_conversation_message(
          @store,
          group_id,
          conversation_id,
          attrs
        )

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeams.TestConversationStore.list_group_conversation_messages(
          @store,
          group_id,
          conversation_id,
          opts
        )
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ConversationClient)
    ConversationClient.reset()

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)
  end

  # The board no longer fabricates demo work products, so tests that exercise a
  # widget's review/drawer flow create the row they need explicitly (as a real
  # delegated/mirrored task would appear).
  defp create_task(user_id, org_id, project_id, attrs) do
    attrs =
      attrs
      |> Map.put_new("conversation_id", attrs["salix_conversation_id"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user_id, org_id, project_id, [
        Map.put_new(attrs, "source", "agent")
      ])

    task
  end

  defp create_worker(project, name) do
    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => name,
        "role" => "worker"
      })

    worker
  end

  defp text_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _other -> ""
    end)
    |> Enum.join("\n")
  end

  defp text_content(_message), do: ""

  defp task_command_text(project, task) do
    {:ok, messages} =
      ConversationClient.list_group_conversation_messages(
        project.salix_group_id,
        task.salix_conversation_id,
        limit: 20
      )

    messages
    |> Enum.map(&text_content/1)
    |> Enum.find(&String.starts_with?(&1, "Work on this task from the user's New Home board."))
  end

  defp assert_initial_chat_message(user, org, project) do
    assert {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, [message | _]} =
             ConversationClient.list_group_conversation_messages(
               project.salix_group_id,
               binding.conversation_id,
               []
             )

    assert message["actor_type"] == "provider_system"
    assert message["provider"] == "bft"
  end

  defp create_delegated_conversation(project, title) do
    {:ok, conversation} =
      ConversationClient.create_group_conversation(project.salix_group_id, %{
        "title" => title,
        "kind" => "agent_task"
      })

    conversation_id = conversation["conversation_id"]
    Application.put_env(:bridge_for_teams_web, :test_delegated_conversation_id, conversation_id)
    conversation_id
  end

  defp seed_email_draft(user_id, org_id, project_id) do
    create_task(user_id, org_id, project_id, %{
      "title" => "Reply: intro request from a founder",
      "category" => "email_drafts",
      "platform" => "gmail",
      "status" => "ready_for_review",
      "payload" => %{
        "to" => "founder@example.com",
        "subject" => "Re: Quick intro",
        "snippet" => "Happy to connect you two.",
        "body" => "Hi —\n\nHappy to connect you two."
      }
    })
  end

  # A mirrored bot-attended meeting record (the shape `sync_meetings/2` produces),
  # with no demo-universe names.
  defp seed_meeting(user_id, org_id, project_id) do
    create_task(user_id, org_id, project_id, %{
      "title" => "Team weekly sync",
      "category" => "meetings",
      "platform" => "slack",
      "status" => "ready_for_review",
      "payload" => %{
        "meeting_id" => "mtg-#{System.unique_integer([:positive])}",
        "meeting_status" => "done",
        "provider" => "slack",
        "artifacts" => ["transcript"],
        "summary" => %{
          "title" => "Team weekly sync",
          "key_points" => ["Shipped the milestone"],
          "action_items" => [
            %{"description" => "Send the recap", "owner" => "Sam", "deadline" => ""}
          ]
        }
      }
    })
  end

  defp seed_report_offer(user, org, project, kind) do
    {title, base, cron} =
      case kind do
        "daily" -> {"Daily Briefing", "daily-briefing", "0 8 * * 1-5"}
        "weekly" -> {"Weekly Portfolio Report", "weekly-portfolio", "0 8 * * 1"}
      end

    series = Reports.series_slug(base, user.id)

    create_task(user.id, org.id, project.id, %{
      "title" => title,
      "category" => "reports",
      "platform" => "comma",
      "status" => "accepted",
      "source" => "onboarding",
      "payload" => %{
        "offer" => "report",
        "kind" => kind,
        "series" => series,
        "site_name" => series,
        "cron" => cron
      }
    })
  end

  defmodule BlockingBoardSourceClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_group_meetings(_group_id), do: block(:list_group_meetings, [])
    def list_group_conversations(_group_id, _opts), do: {:ok, %{"data" => []}}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, %{"data" => []}}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    defdelegate create_group_conversation(group_id, attrs),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    defdelegate append_group_conversation_message(group_id, conversation_id, attrs),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    defdelegate get_group_conversation(group_id, conversation_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_group_conversation_messages(_group_id, _conversation_id, _opts), do: {:ok, []}

    defp block(step, result) do
      if pid = Application.get_env(:bridge_for_teams_web, :blocking_board_source_test_pid) do
        send(pid, {:blocked_board_source_call, self(), step})
      end

      receive do
        :release_blocked_board_source -> {:ok, result}
      after
        5_000 -> {:ok, result}
      end
    end
  end

  defmodule PagePathGuardClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_group_conversations(group_id, opts),
      do: notify({:salix_page_call, :list_group_conversations, group_id, opts})

    def billing_history(agent_id, tenant_id, opts),
      do: notify({:salix_page_call, :billing_history, agent_id, tenant_id, opts})

    def list_group_meetings(group_id),
      do: notify({:salix_page_call, :list_group_meetings, group_id})

    def list_group_oauth_bindings(group_id) do
      notify({:salix_page_call, :list_group_oauth_bindings, group_id})
      []
    end

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}
    def list_agent_sites(_agent_id), do: {:ok, []}

    defdelegate create_group_conversation(group_id, attrs),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    defdelegate append_group_conversation_message(group_id, conversation_id, attrs),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    defdelegate get_group_conversation(group_id, conversation_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_group_conversation_messages(_group_id, _conversation_id, _opts), do: {:ok, []}

    defp notify(message) do
      if pid = Application.get_env(:bridge_for_teams_web, :page_path_guard_pid) do
        # A supervised projection drain is allowed to fan out. Its nested Tasks
        # retain the reconciler in $callers; page calls (including page Tasks)
        # do not. Ignore only that known worker, not arbitrary async callers.
        reconciler = Process.whereis(DashboardProjection.Reconciler)

        unless is_pid(reconciler) and reconciler in Process.get(:"$callers", []) do
          send(pid, message)
        end
      end

      {:ok, []}
    end
  end

  test "page-path guard retains direct and nested task source calls" do
    prev_pid = Application.get_env(:bridge_for_teams_web, :page_path_guard_pid)
    Application.put_env(:bridge_for_teams_web, :page_path_guard_pid, self())
    on_exit(fn -> restore_env(:bridge_for_teams_web, :page_path_guard_pid, prev_pid) end)

    call_sources = fn ->
      PagePathGuardClient.list_group_conversations("guarded-group", limit: 100)
      PagePathGuardClient.billing_history("guarded-agent", "guarded-tenant", limit: 500)
      PagePathGuardClient.list_group_meetings("guarded-group")
      PagePathGuardClient.list_group_oauth_bindings("guarded-group")
    end

    call_sources.()

    Task.async(fn -> Task.async(call_sources) |> Task.await() end)
    |> Task.await()

    for _ <- 1..2 do
      assert_received {:salix_page_call, :list_group_conversations, "guarded-group", [limit: 100]}

      assert_received {:salix_page_call, :billing_history, "guarded-agent", "guarded-tenant",
                       [limit: 500]}

      assert_received {:salix_page_call, :list_group_meetings, "guarded-group"}
      assert_received {:salix_page_call, :list_group_oauth_bindings, "guarded-group"}
    end
  end

  test "connected mount does not block on board source sync", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Slow Board Sources",
        "slug" => "slow-board-sources"
      })

    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    prev_pid = Application.get_env(:bridge_for_teams_web, :blocking_board_source_test_pid)

    Application.put_env(:bridge_for_teams_core, :salix_client, BlockingBoardSourceClient)
    Application.put_env(:bridge_for_teams_web, :blocking_board_source_test_pid, self())

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      restore_env(:bridge_for_teams_web, :blocking_board_source_test_pid, prev_pid)
    end)

    started = System.monotonic_time(:millisecond)
    {:ok, view, html} = live(conn, ~p"/new-home")
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 1_000
    assert html =~ "My Space"
    assert render(view) =~ "Key metrics"
    assert_initial_chat_message(user, org, project)

    assert_receive {:blocked_board_source_call, task_pid, :list_group_meetings}, 500
    send(task_pid, :release_blocked_board_source)
    assert_projection_refreshed(project.id)
    render_async(view)
  end

  test "connected mount page path does not call broad Salix board sources", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Guarded Board Sources",
        "slug" => "guarded-board-sources"
      })

    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    prev_auto = Application.get_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh)
    prev_pid = Application.get_env(:bridge_for_teams_web, :page_path_guard_pid)
    ref = make_ref()

    :telemetry.attach_many(
      "new-home-page-path-guard-#{inspect(ref)}",
      [
        [:bridge_for_teams, :new_home, :mount],
        [:bridge_for_teams, :workspace_items, :list_tasks],
        [:bridge_for_teams, :dashboard_projection, :refresh, :stop]
      ],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      self()
    )

    Application.put_env(:bridge_for_teams_core, :salix_client, PagePathGuardClient)
    Application.put_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh, false)
    Application.put_env(:bridge_for_teams_web, :page_path_guard_pid, self())

    on_exit(fn ->
      :telemetry.detach("new-home-page-path-guard-#{inspect(ref)}")
      restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      restore_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh, prev_auto)
      restore_env(:bridge_for_teams_web, :page_path_guard_pid, prev_pid)
    end)

    # Exercise the real supervised refresh while the page-path guard is armed.
    # Disabling page-triggered enqueue does not cancel an already scheduled drain.
    :ok = DashboardProjection.Reconciler.enqueue(project.id)

    {:ok, view, html} = live(conn, ~p"/new-home")
    assert html =~ "My Space"
    assert render(view) =~ "Key metrics"
    assert_initial_chat_message(user, org, project)

    project_id = project.id

    assert_receive {:telemetry_event, [:bridge_for_teams, :dashboard_projection, :refresh, :stop],
                    _, %{project_id: ^project_id, status: :ok}},
                   5_000

    assert_receive {:telemetry_event, [:bridge_for_teams, :new_home, :mount], %{duration: _}, _}

    assert_receive {:telemetry_event, [:bridge_for_teams, :workspace_items, :list_tasks],
                    %{duration: _, count: _}, _}

    refute_received {:salix_page_call, :list_group_conversations, _, _}
    refute_received {:salix_page_call, :billing_history, _, _, _}
    refute_received {:salix_page_call, :list_group_meetings, _}
    refute_received {:salix_page_call, :list_group_oauth_bindings, _}
  end

  # A medium wall cell caps at two rows and the first-run seeded offers are
  # newer than a test's created report — enlarge the Reports card so the
  # created report stays visible. Returns the re-rendered HTML.
  defp enlarge_reports_widget(view),
    do: render_click(view, "set_widget_size", %{"category" => "reports", "size" => "large"})

  test "first run renders local empty widgets from the project projection", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render_async(view)

    assert html =~ "Key metrics"
    assert html =~ "Team activity"
    assert html =~ "Engineering activity"

    assert html =~ "Drafted emails"
    assert html =~ "Nothing here yet — your agent fills this in."

    projected_categories =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id)
      |> Enum.map(& &1.category)

    assert "metrics" in projected_categories
    assert "team_activity" in projected_categories
    refute html =~ "Compile a weekly engineering report"
    refute html =~ "Lumen Robotics"
    refute html =~ "weekly sync — Google Meet"
  end

  test "renders local report offers carrying the user-namespaced series slug", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    seed_report_offer(user, org, project, "daily")
    seed_report_offer(user, org, project, "weekly")

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render_async(view)

    assert html =~ "Reports"
    assert html =~ "Daily Briefing"
    assert html =~ "Weekly Portfolio Report"

    reports = WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
    assert length(reports) == 2
    assert Enum.all?(reports, &(&1.payload["kind"] in ["daily", "weekly"]))
    assert Enum.all?(reports, &(&1.source == "onboarding"))
    assert Enum.all?(reports, &(&1.status == "accepted"))
    daily = Enum.find(reports, &(&1.payload["kind"] == "daily"))
    weekly = Enum.find(reports, &(&1.payload["kind"] == "weekly"))
    assert daily.payload["series"] == Reports.series_slug("daily-briefing", user.id)
    assert weekly.payload["series"] == Reports.series_slug("weekly-portfolio", user.id)
    # The published-site name shares the series slug (identical suffix scheme).
    assert Enum.all?([daily, weekly], &(&1.payload["site_name"] == &1.payload["series"]))

    # A runnable offer, not a fabricated deploy-in-progress: the row opens the
    # review drawer, whose Run action hands the task to the assistant chat.
    assert html =~ ~s(phx-click="open_drawer")
    refute html =~ "Deploying…"

    # The page does not add, backfill, or duplicate report offers across visits.
    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    assert length(WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")) ==
             2
  end

  test "report cards render a published site URL from the local payload", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "payload" => %{
            "kind" => "daily",
            "site_name" => "daily-briefing-abc",
            "url" => "https://daily-briefing-abc.sites.example.com",
            "summary" => "Three things",
            "period" => "Jul 2"
          }
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    enlarge_reports_widget(view)

    html = render_async(view)

    assert html =~ "https://daily-briefing-abc.sites.example.com"
    assert html =~ "Open site"
    # The card renders from index data: kind/period line plus the one-line
    # summary — never a live embed of the site.
    assert html =~ "Three things"
    assert html =~ "Jul 2"
    refute html =~ "<iframe"
  end

  # Site URLs are part of the local projection now; the page does not resolve
  # Salix site names from `/new-home`.
  defmodule SwitchableSitesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    # `:error` in the env simulates a degraded Salix (uncached, the fan-out
    # really re-runs); anything else is the published site list.
    def list_agent_sites(_agent_id) do
      case Application.get_env(:bridge_for_teams_web, :test_agent_sites, []) do
        :error -> {:error, :unavailable}
        sites -> {:ok, sites}
      end
    end

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_task_conversation(
          group_id,
          delegator_agent_id,
          worker_agent_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "a board refresh keeps report-site URLs from local rows only", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "payload" => %{"kind" => "daily", "site_name" => "daily-briefing-abc"}
        }
      ])

    done_task =
      create_task(user.id, org.id, project.id, %{
        "title" => "A row to complete",
        "category" => "general",
        "platform" => "comma",
        "status" => "accepted"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    enlarge_reports_widget(view)

    html = render_async(view)
    refute html =~ "daily-briefing-abc.sites.example.com"
    refute html =~ "Open site"

    render_click(view, "complete_task", %{"id" => done_task.id})
    html = render_async(view)

    refute html =~ "daily-briefing-abc.sites.example.com"
    refute html =~ "Open site"
  end

  test "a projected site URL survives ordinary board refreshes", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "payload" => %{
            "kind" => "daily",
            "site_name" => "daily-briefing-abc",
            "url" => "https://daily-briefing-abc.sites.example.com"
          }
        }
      ])

    done_task =
      create_task(user.id, org.id, project.id, %{
        "title" => "A row to complete",
        "category" => "general",
        "platform" => "comma",
        "status" => "accepted"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    enlarge_reports_widget(view)
    html = render_async(view)
    assert html =~ "Open site"

    render_click(view, "complete_task", %{"id" => done_task.id})
    html = render_async(view)

    assert html =~ "https://daily-briefing-abc.sites.example.com"
    assert html =~ "Open site"
  end

  # One card row per report series: runs sharing a schedule (or, without one,
  # a series slug) collapse behind the latest run with an honest run count,
  # while standalone reports — even without a `kind` — keep their own row.
  test "report runs collapse into one series row fronted by the latest run", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    for {period, day} <- [{"Jul 2", "02"}, {"Jul 3", "03"}, {"Jul 4", "04"}] do
      create_task(user.id, org.id, project.id, %{
        "title" => "Daily Briefing",
        "category" => "reports",
        "platform" => "comma",
        "status" => "ready_for_review",
        "salix_schedule_id" => "sched-daily",
        "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md",
        "payload" => %{
          "kind" => "daily",
          "period" => period,
          "series" => "daily-briefing-abc",
          "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md"
        }
      })
    end

    # A one-off report row: no schedule, no series, not even a `kind` — it
    # still renders as a report card (index data only), with its summary line.
    create_task(user.id, org.id, project.id, %{
      "title" => "Ad hoc market check",
      "category" => "reports",
      "platform" => "comma",
      "status" => "ready_for_review",
      "payload" => %{"summary" => "One-off look at the market."}
    })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    # The large card shows the full set (seeded offers + the collapsed series
    # + the one-off).
    html = enlarge_reports_widget(view)

    # The series shows once, fronted by its newest run.
    assert html =~ "3 runs"
    assert html =~ "Jul 4"
    refute html =~ "Jul 3"

    assert html =~ "Ad hoc market check"
    assert html =~ "One-off look at the market."
  end

  defmodule DevicesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    # Mirrors SalixEnv.Control.environment_json/1: unix-seconds timestamps,
    # system_info only when the connector reported one, os/arch always.
    def list_group_envs(_group_id, _tenant_id) do
      {:ok,
       [
         %{
           "env_id" => "env-mac-1",
           "connector_run_id" => "env-mac-1",
           "device_id" => "dev-mac-1",
           "name" => "office-mac-mini",
           "status" => "disconnected",
           "updated_at" => System.system_time(:second) - 120,
           "os" => "darwin",
           "arch" => "arm64",
           "system_info" => %{
             "os_type" => "macOS",
             "os_release" => "14.5",
             "hostname" => "studio.local"
           }
         },
         %{
           "env_id" => "cloudvm-abc123",
           "connector_run_id" => "cloudvm-abc123",
           "device_id" => "dev-cloudvm",
           "name" => "Cloud Workspace",
           "status" => "connected",
           "updated_at" => System.system_time(:second),
           "os" => "linux",
           "arch" => "x86_64",
           "system_info" => %{},
           "last_exec" => %{
             "description" => "install deps",
             "at" => System.system_time(:millisecond) - 60_000
           }
         }
       ]}
    end

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "the devices rail lists swarm devices, cloud VM included", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, DevicesClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, devices} = DevicesClient.list_group_envs(project.salix_group_id, org.salix_tenant_id)

    Enum.each(devices, fn device ->
      %ProjectDeviceProjection{}
      |> ProjectDeviceProjection.changeset(%{
        project_id: project.id,
        device_id: device["device_id"],
        connector_run_id: device["connector_run_id"],
        name: device["name"],
        status: device["status"],
        source_updated_at: device["updated_at"],
        observed_generation: 1,
        runtime_inventory: %{
          "items" => [],
          "system_info" => device["system_info"],
          "os" => device["os"],
          "arch" => device["arch"],
          "last_exec" => device["last_exec"]
        }
      })
      |> Repo.insert!()
    end)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render_async(view)

    assert html =~ "Devices"
    assert html =~ "Cloud Workspace"
    assert html =~ "office-mac-mini"
    # Connected devices sort ahead of disconnected ones.
    {cloud_pos, _} = :binary.match(html, "Cloud Workspace")
    {mac_pos, _} = :binary.match(html, "office-mac-mini")
    assert cloud_pos < mac_pos
    # Basic system info from the connector's report; devices without one
    # (the cloud VM) fall back to the connect-time os/arch fields.
    assert html =~ "macOS 14.5 · studio.local"
    assert html =~ "linux · x86_64"
    # Unix-seconds last-seen renders as a sane relative label, not decades.
    assert html =~ "2m ago"
    refute html =~ ~r/\d{3,}d ago/
    # The in-memory last-exec activity renders as a quiet label.
    assert html =~ "install deps · 1m ago"

    # A relayed exec_activity event patches the device row without a reload.
    send(
      view.pid,
      {:agent_event, "org-x", "agent-x",
       {:exec_activity, "env-mac-1",
        %{"description" => "build docs", "at" => System.system_time(:millisecond)}}}
    )

    html = render(view)
    assert html =~ "build docs"

    # A subsequent poll must not regress event-delivered labels: the serving
    # Salix node's in-memory table may have missed the entry (here the fixture
    # still reports no last_exec for the mac at all). Newer entries win.
    send(view.pid, :load_devices)
    html = render(view)
    assert html =~ "build docs"
    assert html =~ "install deps"

    # Devices is a regular wall widget: it carries the DashGrid drag identity
    # and resizes through the same size prefs as every other card.
    assert has_element?(view, ~s(#dash-widget-devices[data-dash-widget="devices"]))
    assert view |> element("#dash-widget-devices") |> render() =~ "col-span-2 row-span-1"

    render_click(view, "set_widget_size", %{"category" => "devices", "size" => "large"})
    assert view |> element("#dash-widget-devices") |> render() =~ "col-span-2 row-span-2"
  end

  # The rail's "Add device" button reuses the Agent Swarm Devices tab flow
  # (shared `DeviceProvisioning` modal): a board-swarm admin requests a device
  # on an online org runner; everyone else gets neither button nor event.
  test "a board-swarm admin adds a device through an org runner from the rail", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

    {:ok, provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "mac-mini-1",
        "name" => "Lab Mac mini",
        "capabilities" => %{"fin" => true}
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    assert render(view) =~ "Add device"

    render_click(view, "new_environment")
    assert has_element?(view, "#new-env-form")
    assert render(view) =~ "Lab Mac mini"

    view
    |> form("#new-env-form",
      device: %{
        name: "production",
        alias: "prod-mac",
        provisioner_id: provisioner.id
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Device connection request created."
    refute has_element?(view, "#new-env-form")

    assert [request] = Environments.list_device_provision_requests(project.id)
    assert request.provisioner_id == provisioner.id
    assert request.name == "production"
  end

  test "with no online runners the rail routes runner management to Fin", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

    {:ok, view, _html} = live(conn, ~p"/new-home")

    html = render_click(view, "new_environment")
    assert html =~ "No runners connected"
    assert html =~ "Connect a runner in Fin before creating a project device."
    assert html =~ ~s(href="/orgs/#{org.slug}/fin")
    assert html =~ "Open Fin"
    refute has_element?(view, "#new-env-form")
    refute html =~ ~s(phx-click="create_runner_install_command")
    refute html =~ "install.sh?"
  end

  test "with runners online the modal stays scoped to project-device creation", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

    {:ok, _provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "mac-mini-1",
        "name" => "Lab Mac mini",
        "capabilities" => %{"fin" => true}
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    html = render_click(view, "new_environment")
    assert has_element?(view, "#new-env-form")
    assert html =~ "Create on runner"
    refute html =~ ~s(phx-click="create_runner_install_command")
    refute html =~ "install.sh?"
  end

  test "swarm admins without org admin cannot mint org runner credentials from the rail",
       %{conn: conn} do
    %{org: org} = org_with_owner_fixture()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    user = user_fixture(email: "rail-env-admin@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/new-home")

    html = render_click(view, "new_environment")
    assert html =~ "No runners connected"
    assert html =~ ~s(href="/orgs/#{org.slug}/fin")
    refute html =~ ~s(phx-click="create_runner_install_command")
    refute html =~ "install.sh?"
  end

  test "non-admin members get no add-device control and forged events are denied", %{
    conn: conn
  } do
    # Org owners derive project admin, so the non-admin must be a plain member.
    %{org: org} = org_with_owner_fixture()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    user = user_fixture(email: "rail-env-user@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/new-home")
    refute render(view) =~ "Add device"

    assert render_click(view, "new_environment") =~
             "Only Agent Swarm admins can manage devices"

    assert render_submit(view, "create_environment", %{"device" => %{"name" => "forged"}}) =~
             "Only Agent Swarm admins can manage devices"

    assert [] = Environments.list_device_provision_requests(project.id)

    # The denied create leaves the same audit trail as the project Devices tab.
    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "device.provision_requested",
               result: "denied"
             )

    assert audit.actor_user_id == user.id
    assert audit.resource_type == "device_provision_request"
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["surface"] == "device"
  end

  test "repeated visits reuse the same projected workspace rows", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)
    count = user.id |> WorkspaceItems.list_tasks(project_id: project.id) |> length()
    assert count > 0

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)
    assert user.id |> WorkspaceItems.list_tasks(project_id: project.id) |> length() == count
  end

  test "chat panel shows the no-agent empty state without a project", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    assert html =~ "No agent to chat with yet"
  end

  # Fallback removal: the board binds only to a swarm the user can actually
  # reach. A plain org member with no project grants gets the honest empty
  # board and chat — never another user's swarm, even though the org has one.
  test "a member without swarm access sees the empty state, not someone else's swarm", %{
    conn: conn
  } do
    %{user: owner, org: org} = org_with_owner_fixture()
    project = bare_project_fixture(org)

    create_task(owner.id, org.id, project.id, %{
      "title" => "Owner-only local row",
      "category" => "general",
      "platform" => "comma",
      "status" => "accepted"
    })

    {:ok, _view, _html} = live(log_in_user(conn, owner), ~p"/new-home")
    assert WorkspaceItems.list_tasks(owner.id, project_id: project.id) != []

    member = user_fixture()
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, member.id, "member")

    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)
    {:ok, view, _html} = live(member_conn, ~p"/new-home")
    html = render(view)

    # No reachable swarm ⇒ the honest empty board, not the org owner's board.
    assert html =~ "No agent to chat with yet"
    # Nothing was seeded onto the org's swarm for the member.
    assert WorkspaceItems.list_tasks(member.id, project_id: project.id) == []
  end

  # The board project resolves prefs → ownership default: a pinned swarm wins
  # while it's still reachable, and a selection the user can no longer see
  # (another org's swarm here) silently falls back to the default.
  test "the pinned swarm drives the board and a revoked selection falls back", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    first = bare_project_fixture(org, name: "First Swarm")
    second = bare_project_fixture(org, name: "Second Swarm")

    {:ok, _} = BridgeForTeams.DashboardPrefs.put_selected_project(user.id, org.id, second.id)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    create_task(user.id, org.id, second.id, %{
      "title" => "Second swarm projected row",
      "category" => "general",
      "platform" => "comma",
      "status" => "accepted"
    })

    assert WorkspaceItems.list_tasks(user.id, project_id: second.id) != []

    refute Enum.any?(
             WorkspaceItems.list_tasks(user.id, project_id: first.id),
             &(&1.title == "Second swarm projected row")
           )

    other_org = org_fixture()
    foreign = bare_project_fixture(other_org)
    {:ok, _} = BridgeForTeams.DashboardPrefs.put_selected_project(user.id, org.id, foreign.id)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    create_task(user.id, org.id, first.id, %{
      "title" => "First swarm fallback row",
      "category" => "general",
      "platform" => "comma",
      "status" => "accepted"
    })

    assert WorkspaceItems.list_tasks(user.id, project_id: first.id) != []
    assert WorkspaceItems.list_tasks(user.id, project_id: foreign.id) == []
  end

  test "two swarms for one user keep separate local boards", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    alpha = bare_project_fixture(org, name: "Alpha Swarm")
    beta = bare_project_fixture(org, name: "Beta Swarm")

    create_task(user.id, org.id, alpha.id, %{
      "title" => "Alpha-only engineering digest",
      "category" => "engineering",
      "platform" => "linear",
      "status" => "ready_for_review"
    })

    create_task(user.id, org.id, beta.id, %{
      "title" => "Beta-only engineering digest",
      "category" => "engineering",
      "platform" => "linear",
      "status" => "ready_for_review"
    })

    # Pinned to Alpha: only Alpha's card renders.
    {:ok, _} = BridgeForTeams.DashboardPrefs.put_selected_project(user.id, org.id, alpha.id)
    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)
    assert html =~ "Alpha-only engineering digest"
    refute html =~ "Beta-only engineering digest"
    refute WorkspaceItems.seeded?(user.id, beta.id)

    # Switch the pin to Beta: the board flips to Beta's card without mutating rows.
    {:ok, _} = BridgeForTeams.DashboardPrefs.put_selected_project(user.id, org.id, beta.id)
    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)
    assert html =~ "Beta-only engineering digest"
    refute html =~ "Alpha-only engineering digest"
    refute WorkspaceItems.seeded?(user.id, alpha.id)
    refute WorkspaceItems.seeded?(user.id, beta.id)
  end

  test "accepted onboarding tasks appear on the board", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Summarize open Linear issues across teams",
          "category" => "engineering",
          "platform" => "linear",
          "status" => "accepted",
          "source" => "onboarding"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    assert html =~ "Summarize open Linear issues across teams"
    assert html =~ "Engineering activity"
  end

  test "the sidebar shows the My Space item", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, _view, html} = live(conn, ~p"/new-home")
    assert html =~ "My Space"
  end

  test "Escape closes read drawers but never the draft editor", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    draft = seed_email_draft(user.id, org.id, project.id)

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # Read-only drawer: Escape closes it.
    render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => draft.id})
    refute render_hook(view, "escape_pressed", %{}) =~ "home-drawer"

    # Draft editor: Escape is inert — its edits live only in the DOM until
    # "Save draft", so closing would silently discard them.
    render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => draft.id})
    render_click(view, "drawer_edit_draft", %{})
    assert render_hook(view, "escape_pressed", %{}) =~ "home-drawer"

    # Deliberate closes (× button, scrim) still work from the editor.
    refute render_click(view, "close_drawer", %{}) =~ "home-drawer"
  end

  test "email draft drawer previews, edits, saves, and hands off to Gmail", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    draft = seed_email_draft(user.id, org.id, project.id)

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # Preview mode: recipient/subject/body + the Gmail handoff link.
    html = render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => draft.id})
    assert html =~ "Draft preview"
    assert html =~ "Open in Gmail"
    assert html =~ "mail.google.com"

    # Switch to the plain-text editor and save an edit.
    html = render_click(view, "drawer_edit_draft", %{})
    assert html =~ "Edit draft"

    render_submit(view, "save_draft", %{
      "draft" => %{
        "to" => "founders@example.com",
        "subject" => "Edited subject",
        "body" => "Edited body line one\n\nSecond paragraph.",
        "action" => "save"
      }
    })

    updated =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "email_drafts")
      |> Enum.find(&(&1.id == draft.id))

    assert updated.payload["subject"] == "Edited subject"
    assert updated.payload["body"] =~ "Second paragraph."
    assert updated.payload["snippet"] == "Edited body line one"

    # Send = save + the client hook opens the mail product in the same gesture;
    # the server records the save and confirms the handoff.
    html =
      render_submit(view, "save_draft", %{
        "draft" => %{
          "to" => "founders@example.com",
          "subject" => "Edited subject",
          "body" => "Edited body line one",
          "action" => "send"
        }
      })

    assert html =~ "Draft opened in Gmail"
  end

  test "complete_task finishes a row; run_task hands accepted work to chat", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    _worker = create_worker(project, "Engineering Worker")

    task = seed_email_draft(user.id, org.id, project.id)

    accepted =
      create_task(user.id, org.id, project.id, %{
        "title" => "Summarize open Linear issues across teams",
        "category" => "engineering",
        "platform" => "linear",
        "status" => "accepted"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    # Completion is one-way (the RowExit hook animates the row out, then
    # pushes this).
    render_click(view, "complete_task", %{"id" => task.id})

    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "email_drafts")
           |> Enum.find(&(&1.id == task.id))
           |> Map.fetch!(:status) == "done"

    # A not-yet-handed item becomes one canonical Task whose command is the
    # initial Message and whose target is the Worker.
    html = render_click(view, "run_task", %{"id" => accepted.id})
    refute html =~ "isn&#39;t connected yet"
    assert html =~ "chat-rail"

    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "engineering")
           |> Enum.find(&(&1.id == accepted.id))
           |> Map.fetch!(:status) == "in_progress"

    {:ok, project} = BridgeForTeams.Projects.get_project(project.id)
    {:ok, accepted} = WorkspaceItems.get_task(user.id, accepted.id, project_id: project.id)

    {:ok, messages} =
      ConversationClient.list_group_conversation_messages(
        project.salix_group_id,
        accepted.salix_conversation_id,
        limit: 20
      )

    assert Enum.any?(messages, fn message ->
             text = text_content(message)

             text =~ accepted.title and text =~ ~s("api": "internal.send_message") and
               not (text =~ ~s("api": "internal.update_conversation")) and
               not (text =~ "conversation_update")
           end)

    {:ok, binding} = BridgeForTeams.AssistantChats.get_binding(user.id, project.id)

    {:ok, assistant_messages} =
      ConversationClient.list_group_conversation_messages(
        project.salix_group_id,
        binding.conversation_id,
        limit: 20
      )

    refute Enum.any?(assistant_messages, fn message ->
             text = text_content(message)

             text =~ "[[bft-task-run]]#{accepted.title}" or
               text =~ "Work on this task from my My Space board."
           end)

    # An already-handed (here: done) task never re-posts the hand-off. The
    # local row still carries task-chat provenance, so the click opens the task
    # conversation directly — it never does nothing.
    html = render_click(view, "run_task", %{"id" => task.id})
    refute html =~ "isn&#39;t connected yet"
    refute html =~ "chat-sheet"
    assert html =~ "chat-rail"

    # The click opens the task's own chat as a floating window.
    assert html =~ ~s(id="chat-form-panel")
    assert has_element?(view, "#home-drawer", "Reply: intro request from a founder")

    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "email_drafts")
           |> Enum.find(&(&1.id == task.id))
           |> Map.fetch!(:status) == "done"
  end

  # Running a report offer creates one canonical Task whose initial Message
  # carries the file-first contract, then materializes the matching recurring
  # series schedule. The scripted client backs both paths.
  defmodule OfferRunClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    defdelegate create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}

    def list_group_meetings(group_id) do
      if pid = Application.get_env(:bridge_for_teams_web, :offer_run_block_board_source_pid) do
        send(pid, {:blocked_offer_run_board_source, self(), :list_group_meetings})

        receive do
          :release_offer_run_board_source ->
            BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
              group_id
            )
        after
          5_000 ->
            BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
              group_id
            )
        end
      else
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )
      end
    end

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}
    def list_agent_sites(_agent_id), do: {:ok, []}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      sent = Application.get_env(:bridge_for_teams_web, :offer_run_messages, [])
      Application.put_env(:bridge_for_teams_web, :offer_run_messages, [attrs | sent])

      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn -> {:ok, %{"conversation_id" => conversation_id, "participants" => []}} end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )

    # The id-stamp rewrite lists schedules to validate ownership — echo the
    # created definitions back (same shape the core ScriptedClient uses).
    def list_schedules_for_owners(_agent_ids, _group_id) do
      schedules =
        Application.get_env(:bridge_for_teams_web, :offer_run_schedules, [])
        |> Enum.map(&Map.merge(&1, %{"created_at" => 1_700_000_000_000, "last_run" => nil}))

      {:ok, schedules}
    end

    def create_schedule(attrs) do
      if Application.get_env(:bridge_for_teams_web, :offer_run_fail_create) do
        # A transient Salix outage exactly at schedule-create time.
        {:error, :unavailable}
      else
        created = Application.get_env(:bridge_for_teams_web, :offer_run_schedules, [])
        Application.put_env(:bridge_for_teams_web, :offer_run_schedules, [attrs | created])
        {:ok, Map.merge(attrs, %{"created_at" => 1_700_000_000_000, "last_run" => nil})}
      end
    end

    def update_schedule(id, changes) do
      stamps = Application.get_env(:bridge_for_teams_web, :offer_run_stamps, [])
      Application.put_env(:bridge_for_teams_web, :offer_run_stamps, [{id, changes} | stamps])
      {:ok, Map.merge(%{"id" => id}, changes)}
    end
  end

  # Free-form chat should route durable work through im_api.internal.task.create. The task
  # conversation's worker prompt owns artifact/reporting details, so the chat
  # context must not offer a direct workspace-item fallback.

  test "running a report offer hands off the file-first one-shot and materializes its schedule once",
       %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, OfferRunClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_web, :offer_run_messages)
      Application.delete_env(:bridge_for_teams_web, :offer_run_schedules)
      Application.delete_env(:bridge_for_teams_web, :offer_run_stamps)
      Application.delete_env(:bridge_for_teams_web, :offer_run_fail_create)
    end)

    # A provisioned project: the assistant chat needs a real agent to reach
    # :ready, and the schedule create resolves the same agent.
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    _worker = create_worker(project, "Report Worker")

    offer = seed_report_offer(user, org, project, "daily")

    {:ok, view, _html} = live(conn, ~p"/new-home")
    # Flush :init_chat so the chat is :ready before the Run click.
    render(view)

    render_click(view, "run_task", %{"id" => offer.id})
    # The schedule create runs async (two Salix erpc calls must never block
    # the event loop) — wait for it to land before asserting.
    render_async(view)

    slug = Reports.series_slug("daily-briefing", user.id)

    ran =
      WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
      |> Enum.find(&(&1.id == offer.id))

    # The canonical Task command carries the file-first contract. The Worker
    # publishes only an ordinary Message; the Router owns Conversation state.
    handoff = task_command_text(project, ran)

    assert handoff =~ "/.salix/reports/"
    assert handoff =~ ~s("vfs_path")
    assert handoff =~ ~s("api": "internal.send_message")
    refute handoff =~ ~s("api": "internal.update_conversation")
    refute handoff =~ ~s("conversation_update")
    # The task-data JSON names the series directory the contract points at.
    assert handoff =~ slug
    refute handoff =~ "body_markdown"

    # The recurring series schedule exists, personalized for this user, and
    # its id landed on the offer row's payload.
    assert [definition] = Application.get_env(:bridge_for_teams_web, :offer_run_schedules, [])
    assert definition["cron"] == "0 8 * * 1-5"
    assert definition["prompt"] =~ "/.salix/reports/#{slug}/"

    assert [{stamped_id, _changes}] =
             Application.get_env(:bridge_for_teams_web, :offer_run_stamps, [])

    assert stamped_id == definition["id"]

    assert ran.status == "in_progress"
    assert ran.payload["salix_schedule_id"] == definition["id"]

    # Idempotent: re-running the offer (fresh mount, offer runnable again)
    # never creates a second schedule — the recorded id is the guard.
    {:ok, _task} = WorkspaceItems.update_task(ran, %{"status" => "accepted"})

    {:ok, view2, _html} = live(conn, ~p"/new-home")
    render(view2)
    render_click(view2, "run_task", %{"id" => offer.id})
    render_async(view2)

    assert [_only_one] = Application.get_env(:bridge_for_teams_web, :offer_run_schedules, [])
  end

  test "running a local report offer uses its projected series payload",
       %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    _worker = create_worker(project, "Local Report Worker")

    daily = seed_report_offer(user, org, project, "daily")

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)

    Application.put_env(:bridge_for_teams_core, :salix_client, OfferRunClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_web, :offer_run_messages)
      Application.delete_env(:bridge_for_teams_web, :offer_run_schedules)
      Application.delete_env(:bridge_for_teams_web, :offer_run_stamps)
    end)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    render_click(view, "run_task", %{"id" => daily.id})

    slug = Reports.series_slug("daily-briefing", user.id)

    ran =
      WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
      |> Enum.find(&(&1.id == daily.id))

    handoff = task_command_text(project, ran)

    assert handoff =~ ~s("series":"#{slug}")
    assert handoff =~ ~s("site_name":"#{slug}")
    render_async(view)
  end

  # A Salix outage at schedule-create time must not lose the recurring series
  # for good: the offer stays schedule-less and the NEXT Run click — including
  # a click on the already-handed offer, which only reopens the chat — retries
  # the create.
  test "a failed schedule create is retried by the next Run click", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, OfferRunClient)
    Application.put_env(:bridge_for_teams_web, :offer_run_fail_create, true)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_web, :offer_run_messages)
      Application.delete_env(:bridge_for_teams_web, :offer_run_schedules)
      Application.delete_env(:bridge_for_teams_web, :offer_run_stamps)
      Application.delete_env(:bridge_for_teams_web, :offer_run_fail_create)
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    _worker = create_worker(project, "Retry Report Worker")

    offer = seed_report_offer(user, org, project, "daily")

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    # First Run: canonical Task creation succeeds, the schedule create fails.
    render_click(view, "run_task", %{"id" => offer.id})
    render_async(view)

    assert Application.get_env(:bridge_for_teams_web, :offer_run_schedules, []) == []

    ran =
      WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
      |> Enum.find(&(&1.id == offer.id))

    assert ran.status == "in_progress"
    refute is_binary(ran.payload["salix_schedule_id"])

    # Salix recovers; the offer is already handed (in_progress), so this click
    # only reopens the chat — and retries the schedule create.
    Application.delete_env(:bridge_for_teams_web, :offer_run_fail_create)

    render_click(view, "run_task", %{"id" => offer.id})
    render_async(view)

    assert [definition] = Application.get_env(:bridge_for_teams_web, :offer_run_schedules, [])

    recovered =
      WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
      |> Enum.find(&(&1.id == offer.id))

    assert recovered.payload["salix_schedule_id"] == definition["id"]
  end

  test "the rail composer carries attach, send, and the task-filing contract", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    # The board has no hero composer anymore — the rail composer is the one
    # entry point, and on the assistant thread it files tasks.
    refute html =~ "chat-form-hero"
    assert html =~ ~s(id="chat-form-rail")
    assert html =~ ~s(phx-change="validate_chat")
    assert html =~ ~s(name="chat[text]")
    assert html =~ ~s(name="chat[create_task]")
    assert html =~ "Start a task…"
  end

  test "composers render the /-skill mention editor with no skills loaded", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    # No Salix in test env: the skill list stays empty and the menu never
    # opens, but the contenteditable editor + hidden inputs are in place.
    assert html =~ ~s(phx-hook="SkillComposer")
    assert html =~ ~s(data-skills="[]")
    assert html =~ ~s(contenteditable)
    assert html =~ ~s(name="chat[skills]")
    assert html =~ ~s(data-skill-text)
    assert html =~ ~s(data-skill-json)
  end

  test "send_chat_message tolerates malformed chat[skills] input", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # Client-controlled param: garbage must not crash the LiveView (the send
    # itself is a no-op here — chat never reaches :ready without Salix).
    for skills <- ["not json", ~s({"location":"x"}), ~s([{"location":42}])] do
      assert view
             |> element("#chat-form-rail")
             |> render_submit(%{"chat" => %{"text" => "hello", "skills" => skills}})
    end
  end

  test "clicking a task reviews its finished result and marks it reviewed", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    # A real agent-produced portfolio overview (no demo universe), in the
    # artifact payload shape: one-line summary plus a hero block for the card.
    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Portfolio status overview",
        "category" => "portfolio",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{
          "summary" => "One company shipped, none need attention.",
          "hero" => %{
            "type" => "entities",
            "items" => [%{"name" => "Acme Corp", "detail" => "Shipped v2"}]
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # The board card renders the hero block natively.
    assert render(view) =~ "Acme Corp"

    # The result drawer shows the index summary + the review action (no
    # vfs_path, so there is no document to hydrate).
    html = render_click(view, "open_drawer", %{"kind" => "result", "id" => task.id})
    assert html =~ "Mark reviewed"
    assert html =~ "One company shipped, none need attention."

    # Confirming closes the drawer and completes the task.
    html = render_click(view, "review_done", %{"id" => task.id})
    assert html =~ "Marked as reviewed."

    reviewed =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "portfolio")
      |> List.first()

    assert reviewed.status == "done"
  end

  test "a general-category artifact task stays compact and opens its conversation", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    # The delegated-composer / sweeper shape: category "general" with the
    # normalized doorbell payload. General Tasks must still read like a task
    # list: artifact details belong behind Review, while the row itself opens
    # the backing task conversation.
    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Cerebras follow-up brief",
        "category" => "general",
        "platform" => "comma",
        "status" => "ready_for_review",
        # No vfs_path so the drawer stays on the index summary (the async
        # document hydration path is covered by the document-rendering test).
        "payload" => %{
          "summary" => "Two blockers cleared; pricing draft attached.",
          "hero" => %{
            "type" => "kpis",
            "items" => [%{"label" => "Blockers cleared", "value" => "2"}]
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    assert html =~ "Cerebras follow-up brief"
    refute html =~ "Two blockers cleared; pricing draft attached."
    refute html =~ "Blockers cleared"

    assert has_element?(
             view,
             ~s(button[phx-click="run_task"][phx-value-id="#{task.id}"])
           )

    assert has_element?(
             view,
             ~s(button[phx-click="open_drawer"][phx-value-kind="result"][phx-value-id="#{task.id}"])
           )

    refute has_element?(view, ~s([data-exit-action="complete_task"][data-task-id="#{task.id}"]))

    # Row click opens the task conversation panel.
    html = render_click(view, "run_task", %{"id" => task.id})
    assert html =~ ~s(id="chat-form-panel")
    assert has_element?(view, "#home-drawer", "Cerebras follow-up brief")

    # The Review action still opens the artifact result.
    html = render_click(view, "open_drawer", %{"kind" => "result", "id" => task.id})
    assert html =~ "Two blockers cleared; pricing draft attached."
  end

  test "does not fabricate a demo meeting or its derived general tasks", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    # No fake bot-attended meeting, no derived action items — those appear only
    # when Salix actually mirrors a real meeting.
    refute html =~ "weekly sync — Google Meet"
    refute html =~ "Send the diligence memo to the IC"
    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "meetings") == []
    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "general") == []
  end

  test "meeting drawer shows key points, action items, and artifacts", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    meeting = seed_meeting(user.id, org.id, project.id)

    {:ok, view, _html} = live(conn, ~p"/new-home")

    html = render_click(view, "open_drawer", %{"kind" => "meeting", "id" => meeting.id})
    assert html =~ "Key points"
    assert html =~ "Action items"
    assert html =~ "Transcript"
    assert html =~ "General tasks list"
    assert html =~ "Slack · Google Meet"
  end

  test "general tasks are completed manually and archived off the board", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Renew the data room access for auditors",
        "category" => "general",
        "platform" => "comma",
        "status" => "accepted",
        "payload" => %{}
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # The user checks the task off themselves...
    render_click(view, "complete_task", %{"id" => task.id})

    assert user.id
           |> WorkspaceItems.list_tasks(project_id: project.id, category: "general")
           |> Enum.find(&(&1.id == task.id))
           |> Map.fetch!(:status) == "done"

    # ...then archives it: archived and gone from the board.
    html = render_click(view, "archive_task", %{"id" => task.id})
    assert html =~ "Completed and archived."
    refute html =~ task.title

    archived =
      user.id
      |> WorkspaceItems.list_tasks(
        project_id: project.id,
        category: "general",
        include_archived: true
      )
      |> Enum.find(&(&1.id == task.id))

    assert archived.status == "archived"
    assert %DateTime{} = archived.archived_at

    refute Enum.any?(
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "general"),
             &(&1.id == task.id)
           )
  end

  test "renders projected meetings and their action items from local rows", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Deals",
        "slug" => "deals-#{System.unique_integer([:positive])}"
      })

    meeting_id = "mtg-live-#{System.unique_integer([:positive])}"

    create_task(user.id, org.id, project.id, %{
      "title" => "Bridge financing call",
      "category" => "meetings",
      "platform" => "slack",
      "status" => "ready_for_review",
      "payload" => %{
        "meeting_id" => meeting_id,
        "meeting_status" => "done",
        "provider" => "slack",
        "artifacts" => ["transcript"],
        "summary" => %{
          "title" => "Bridge financing call",
          "key_points" => ["Bridge terms agreed in principle"],
          "action_items" => [
            %{"description" => "Circulate the bridge term sheet", "owner" => "Sam"}
          ]
        }
      },
      "external_source" => "salix_meeting",
      "external_id" => meeting_id
    })

    create_task(user.id, org.id, project.id, %{
      "title" => "Circulate the bridge term sheet",
      "category" => "general",
      "platform" => "slack",
      "status" => "accepted",
      "payload" => %{
        "origin" => "meeting:#{meeting_id}:0",
        "origin_title" => "Bridge financing call"
      },
      "external_source" => "salix_meeting_action",
      "external_id" => "#{meeting_id}:0"
    })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render_async(view)

    assert html =~ "Bridge financing call"

    mirrored =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "meetings")
      |> Enum.find(&(&1.payload["meeting_id"] == meeting_id))

    assert mirrored.status == "ready_for_review"
    assert mirrored.platform == "slack"
    assert mirrored.payload["artifacts"] == ["transcript"]

    action_item =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "general")
      |> Enum.find(&(&1.payload["origin"] == "meeting:#{meeting_id}:0"))

    assert action_item.title == "Circulate the bridge term sheet"
    assert action_item.status == "accepted"
    assert action_item.payload["origin_title"] == "Bridge financing call"

    # A second mount reads the same local projection without duplicating it.
    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    assert user.id
           |> WorkspaceItems.list_tasks(project_id: project.id, category: "meetings")
           |> Enum.count(&(&1.payload["meeting_id"] == meeting_id)) == 1

    assert user.id
           |> WorkspaceItems.list_tasks(project_id: project.id, category: "general")
           |> Enum.count(&(&1.payload["origin"] == "meeting:#{meeting_id}:0")) == 1
  end

  test "metrics widget renders the current local projection", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    metrics =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "metrics")
      |> List.first()

    # The sync writes the artifact payload shape: a `kpis` hero block plus the
    # one-line summary — no legacy `metrics` list.
    assert %{"type" => "kpis", "items" => items} = metrics.payload["hero"]
    tiles = Map.new(items, &{&1["label"], &1["value"]})

    assert tiles["Conversations"] == "0"
    assert tiles["Meetings"] == "0"
    assert tiles["Tokens used"] == "0"
    assert metrics.payload["summary"] =~ "Live from your workspace"
    refute Map.has_key?(metrics.payload, "metrics")

    # The widget renders the hero via the compact block treatment: the first
    # kpi is the oversized hero number.
    assert render(view) =~ "text-2xl font-semibold tabular-nums"
  end

  test "team activity renders local projected workspace conversations", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Deals",
        "slug" => "deals-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _conversation} =
             ConversationClient.create_group_conversation(project.salix_group_id, %{
               "conversation_id" => "cnv1_team_activity_#{System.unique_integer([:positive])}",
               "title" => "Q3 diligence sync",
               "kind" => "work_item",
               "status" => "accepted"
             })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    activity =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "team_activity")
      |> List.first()

    # The sync writes the artifact payload shape: an `entities` hero block
    # (one entity per conversation) plus the one-line summary.
    assert %{"type" => "entities", "items" => items} = activity.payload["hero"]
    assert Enum.any?(items, &(&1["name"] == "Q3 diligence sync"))
    assert activity.payload["summary"] =~ "workspace conversations"
    refute Map.has_key?(activity.payload, "items")

    # Board item conversations back widgets/tasks, but they are not the
    # workspace's team activity stream.
    refute Enum.any?(items, &(&1["name"] == "Workspace metrics"))
    refute Enum.any?(items, &(&1["name"] == "Weekly Portfolio Report"))

    # The synthetic agent_task session logs backing board rows stay off the feed.
    refute Enum.any?(items, &(&1["name"] =~ "recap"))
  end

  test "summarized meetings render from local recap projection", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Deals",
        "slug" => "deals-#{System.unique_integer([:positive])}"
      })

    meeting_id = "mtg-recap-#{System.unique_integer([:positive])}"

    create_task(user.id, org.id, project.id, %{
      "title" => "Bridge financing call — recap",
      "category" => "meeting_recaps",
      "platform" => "slack",
      "status" => "ready_for_review",
      "payload" => %{
        "meeting_id" => meeting_id,
        "bullets" => ["Bridge terms agreed in principle"],
        "date" => Date.utc_today() |> Date.to_iso8601()
      },
      "external_source" => "salix_meeting_recap",
      "external_id" => meeting_id
    })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    recap =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "meeting_recaps")
      |> Enum.find(&(&1.payload["meeting_id"] == meeting_id))

    assert recap.title == "Bridge financing call — recap"
    assert recap.status == "ready_for_review"
    assert recap.payload["bullets"] == ["Bridge terms agreed in principle"]
    assert recap.payload["date"] == Date.utc_today() |> Date.to_iso8601()

    # A second mount reads the same local projection instead of duplicating it.
    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    assert user.id
           |> WorkspaceItems.list_tasks(project_id: project.id, category: "meeting_recaps")
           |> Enum.count(&(&1.payload["meeting_id"] == meeting_id)) == 1
  end

  defp drain_reconciler do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _more} -> drain_reconciler()
    end
  end

  test "meeting recap drawer renders markdown preview and raw markdown", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    recap =
      create_task(user.id, org.id, project.id, %{
        "title" => "Team weekly sync — recap",
        "category" => "meeting_recaps",
        "platform" => "google_calendar",
        "status" => "ready_for_review",
        "payload" => %{
          "date" => Date.utc_today() |> Date.to_iso8601(),
          "bullets" => ["Shipped the milestone", "Agreed next steps"]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    html = render_click(view, "open_drawer", %{"kind" => "recap", "id" => recap.id})
    assert html =~ "drawer-print-content"
    assert html =~ "Highlights"
    assert html =~ "Download .md"

    html = render_click(view, "drawer_recap_view", %{"view" => "markdown"})
    assert html =~ "## Highlights"
  end

  # ---- task delegation: real "How your agent did it" + run/retry -------------

  # Scripted seam for the delegated-conversation surfaces. Everything the New
  # Home mount touches degrades to a benign empty result; only the delegated
  # conversation `conv-delegated-1` answers with real messages and a traceable
  # agent participant.
  defmodule DelegatedConversationClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}

    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{
             "conversation_id" => conversation_id,
             "kind" => "agent_task",
             "participants" => [
               %{"participant_id" => "user", "actor_type" => "user"},
               %{
                 "participant_id" => "agent",
                 "actor_type" => "agent",
                 "agent_id" => "agent-delegate",
                 "payload" => %{"session_id" => "ses1_0000000000000000002"}
               }
             ]
           }}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts) do
      {:ok, stored} =
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )

      if conversation_id ==
           Application.get_env(:bridge_for_teams_web, :test_delegated_conversation_id) do
        {:ok,
         [
           %{
             "message_id" => SalixStore.Ids.new_message_id(),
             "actor_type" => "user",
             "content" => [%{"type" => "text", "text" => "Work on this task from my board"}]
           },
           %{
             "message_id" => SalixStore.Ids.new_message_id(),
             "actor_type" => "agent",
             "content" => [
               %{"type" => "text", "text" => "I checked the founder thread and drafted a reply."}
             ]
           }
           | stored
         ]}
      else
        {:ok, stored}
      end
    end

    def session_trace("agent-delegate", "ses1_0000000000000000002", _opts),
      do: {:ok, %{"tool_calls" => [%{"name" => "gmail.search_threads"}]}}

    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}

    # The chat's connect-time status seed (`Conversations.list_agent_activities/1`);
    # tests stage current activities via app env.
    def list_agent_activities(_agent_id),
      do: {:ok, Application.get_env(:bridge_for_teams_web, :test_agent_activities, [])}
  end

  defp with_scripted_client do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, DelegatedConversationClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_web, :test_delegated_conversation_id)
    end)
  end

  test "the drawer shows the delegated conversation's real agent messages", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    conversation_id = create_delegated_conversation(project, "Reply to the founder intro")

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Reply to the founder intro",
          "category" => "email_drafts",
          "platform" => "gmail",
          "status" => "in_progress",
          "source" => "onboarding",
          "salix_conversation_id" => conversation_id,
          "salix_agent_id" => "agent-delegate",
          "payload" => %{"to" => "founder@example.com", "subject" => "Re: intro", "body" => "Hi"}
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # The drawer opens immediately; the session log is a Salix conversation
    # read and arrives async — it must never block the open.
    html = render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => task.id})
    refute html =~ "I checked the founder thread and drafted a reply."

    html = render_async(view)

    # The real agent messages from the delegated conversation — and only the
    # agent's (the machine prompt stays out of "How your agent did it").
    assert html =~ "How your agent did it"
    assert html =~ "I checked the founder thread and drafted a reply."
    refute has_element?(view, "#home-drawer", "Work on this task from my board")
  end

  test "opening a task drawer keeps the rail on the assistant conversation", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    conversation_id = create_delegated_conversation(project, "Reply to the founder intro")

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Reply to the founder intro",
          "category" => "email_drafts",
          "platform" => "gmail",
          "status" => "in_progress",
          "source" => "onboarding",
          "salix_conversation_id" => conversation_id,
          "salix_agent_id" => "agent-delegate",
          "payload" => %{"to" => "founder@example.com", "subject" => "Re: intro", "body" => "Hi"}
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    # Flush :init_chat so the assistant thread (and its title) is live.
    render(view)

    render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => task.id})
    render_async(view)

    # The drawer shows the task's result/log, but the persistent rail stays on
    # the assistant conversation.
    assert has_element?(view, "#home-drawer", "I checked the founder thread and drafted a reply.")
    assert has_element?(view, "#chat-rail", "Comma assistant")
    refute has_element?(view, "#chat-rail", "Reply to the founder intro")
    refute has_element?(view, ~s(#chat-rail button[phx-click="unfocus_chat"]))

    # Closing the drawer leaves the rail on the assistant chat.
    render_click(view, "close_drawer", %{})
    refute has_element?(view, ~s(#chat-rail button[phx-click="unfocus_chat"]))
    assert has_element?(view, "#chat-rail", "Comma assistant")
  end

  test "clicking a delegated task opens its chat as a floating window", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    conversation_id = create_delegated_conversation(project, "Chase the diligence checklist")

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Chase the diligence checklist",
          "category" => "general",
          "platform" => "comma",
          "status" => "in_progress",
          "source" => "user",
          "salix_conversation_id" => conversation_id,
          "salix_agent_id" => "agent-delegate"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    html = render_click(view, "run_task", %{"id" => task.id})
    assert html =~ ~s(id="chat-form-panel")
    assert has_element?(view, "#home-drawer", "Chase the diligence checklist")

    # The window shows the task's own conversation once the async read lands,
    # while the rail underneath remains the assistant thread.
    render_async(view)
    assert has_element?(view, "#home-drawer", "I checked the founder thread and drafted a reply.")
    assert has_element?(view, "#chat-rail", "Comma assistant")
    refute has_element?(view, "#chat-rail", "I checked the founder thread and drafted a reply.")
    refute has_element?(view, ~s(#chat-rail button[phx-click="unfocus_chat"]))

    # Closing the window leaves the assistant rail untouched.
    render_click(view, "close_drawer", %{})
    refute has_element?(view, "#home-drawer")
    assert has_element?(view, "#chat-rail", "Comma assistant")
  end

  # The rail composer took over the hero composer's entry point: on the
  # assistant thread a send asks the router to decide whether to create a task
  # conversation, while the task panel composer is a plain follow-up into the
  # task's own conversation.

  test "a follow-up is an ordinary Message and does not change task state", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    conversation_id = create_delegated_conversation(project, "Recheck the founder reply")

    assert {:ok, _conversation} =
             ConversationClient.update_group_conversation(
               project.salix_group_id,
               conversation_id,
               %{"status" => "completed"}
             )

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Recheck the founder reply",
        "category" => "email_drafts",
        "platform" => "gmail",
        "status" => "done",
        "salix_conversation_id" => conversation_id,
        "salix_agent_id" => "agent-delegate"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    render_click(view, "run_task", %{"id" => task.id})
    render_async(view)

    view
    |> element("#chat-form-panel")
    |> render_submit(%{
      "chat" => %{"text" => "Please verify the latest details", "skills" => "[]"}
    })

    assert {:ok, stored_messages} =
             ConversationClient.list_group_conversation_messages(
               project.salix_group_id,
               task.salix_conversation_id,
               limit: 100
             )

    assert Enum.any?(stored_messages, &(text_content(&1) =~ "Please verify the latest details"))

    assert {:ok, unchanged} =
             WorkspaceItems.get_task(user.id, task.id, project_id: project.id)

    assert unchanged.status == "done"
  end

  test "assistant conversation renders task conversation refs as clickable cards", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    conversation_id = create_delegated_conversation(project, "Draft the customer follow-up")

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Draft the customer follow-up",
        "category" => "general",
        "platform" => "comma",
        "status" => "in_progress",
        "salix_conversation_id" => conversation_id
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    {:ok, binding} = BridgeForTeams.AssistantChats.get_binding(user.id, project.id)

    ConversationClient.append_group_conversation_message(
      project.salix_group_id,
      task.salix_conversation_id,
      %{
        "message_id" => "m-task-card-agent",
        "actor_type" => "agent",
        "content" => [%{"type" => "text", "text" => "I started the task conversation."}]
      }
    )

    ConversationClient.append_group_conversation_message(
      project.salix_group_id,
      binding.conversation_id,
      %{
        "message_id" => "m-chat-task-card",
        "actor_type" => "agent",
        "content" => [
          %{"type" => "text", "text" => "I created a task for that."},
          %{
            "type" => "conversation_ref",
            "conversation_id" => task.salix_conversation_id,
            "kind" => "agent_task",
            "title" => task.title
          }
        ]
      }
    )

    send(view.pid, :refresh_chat)
    render(view)

    assert has_element?(view, "#chat-rail", "I created a task for that.")

    assert has_element?(
             view,
             ~s(#chat-rail button[phx-click="open_conversation_ref"][phx-value-id="#{task.salix_conversation_id}"]),
             task.title
           )

    render_click(view, "open_conversation_ref", %{"id" => task.salix_conversation_id})
    render_async(view)

    assert has_element?(view, "#home-drawer", task.title)
    assert has_element?(view, "#home-drawer", "I started the task conversation.")
    assert has_element?(view, "#chat-rail", "Comma assistant")
    refute has_element?(view, "#chat-rail", "I started the task conversation.")
  end

  defmodule PollMustNotReadDelegatedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}
    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
          group_id,
          conversation_id,
          attrs
        )

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn -> {:ok, %{"conversation_id" => conversation_id, "participants" => []}} end
      )
    end

    def list_group_conversation_messages(_group_id, "conv-poll-bomb", _opts) do
      raise "LiveView poll must not read delegated task conversations"
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )

    def list_agent_activities(_agent_id), do: {:ok, []}
  end

  test "the chat poll does not read all delegated task conversations inline", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, PollMustNotReadDelegatedClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, [_task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Slow delegated task",
          "category" => "general",
          "platform" => "comma",
          "status" => "in_progress",
          "source" => "agent",
          "conversation_id" => "conv-poll-bomb",
          "salix_conversation_id" => "conv-poll-bomb",
          "salix_agent_id" => "agent-delegate"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    send(view.pid, :refresh_chat)
    render(view)

    assert Process.alive?(view.pid)
  end

  # ---- VFS-backed reviewable work products -----------------------------------

  # A draft whose bytes live in the agent's workspace: reads come back from the
  # VFS, and reviewer edits are flushed back to the same path before the Gmail
  # handoff so the workspace copy matches what the user sends.
  defmodule WorkProductClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}

    def read_agent_file(_agent_id, "/drafts/t1/draft.md"),
      do: {:ok, "Hi founder,\n\nThe VFS copy of the draft."}

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def write_agent_file(_agent_id, path, body) do
      if pid = Application.get_env(:bridge_for_teams_core, :test_writeback_pid) do
        send(pid, {:write_agent_file, path, body})
      end

      {:ok, %{"path" => path}}
    end

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "the review drawer reads a VFS-backed draft and writes edits back before handoff", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, WorkProductClient)
    Application.put_env(:bridge_for_teams_core, :test_writeback_pid, self())

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_writeback_pid)
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Reply to the founder",
          "category" => "email_drafts",
          "platform" => "gmail",
          "status" => "ready_for_review",
          "source" => "agent",
          "payload" => %{
            "to" => "founder@example.com",
            "subject" => "Re: intro",
            "body" => "stale payload body",
            "vfs_path" => "/drafts/t1/draft.md"
          }
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # The drawer opens immediately from the index copy — the VFS read runs
    # async and replaces the body when it lands, so a slow Salix never blocks
    # the open.
    html = render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => task.id})
    assert html =~ "stale payload body"

    html = render_async(view)
    assert html =~ "The VFS copy of the draft."
    refute html =~ "stale payload body"

    # Edit + send: the edited body is written back to the workspace path and the
    # board row is updated to match.
    render_click(view, "drawer_edit_draft", %{})

    html =
      render_submit(view, "save_draft", %{
        "draft" => %{
          "to" => "founder@example.com",
          "subject" => "Re: intro",
          "body" => "Edited body sent to the workspace.",
          "action" => "send"
        }
      })

    assert_receive {:write_agent_file, "/drafts/t1/draft.md",
                    "Edited body sent to the workspace."}

    assert html =~ "Draft opened in Gmail"

    updated =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "email_drafts")
      |> Enum.find(&(&1.id == task.id))

    assert updated.payload["body"] == "Edited body sent to the workspace."
  end

  # The drawer never blocks on (or lies about) an unreachable VFS artifact: it
  # opens instantly from the index copy and quietly reports when the async
  # read fails.
  test "the result drawer opens from index data and reports an unreadable artifact", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    # No file answers: every VFS read fails.
    Application.put_env(:bridge_for_teams_core, :salix_client, SwitchableSitesClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "payload" => %{
            "kind" => "daily",
            "summary" => "Three things need your attention.",
            "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-06.md"
          }
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # Immediate open with the index data — no waiting on the VFS read.
    html = render_click(view, "open_drawer", %{"kind" => "result", "id" => task.id})
    assert html =~ "Three things need your attention."
    refute html =~ "Content unavailable right now."

    # The failed read degrades to a quiet note; the index copy stays.
    html = render_async(view)
    assert html =~ "Content unavailable right now."
    assert html =~ "Three things need your attention."
  end

  # The report file itself is the artifact of record: the drawer's async VFS
  # read lands the markdown body, rendered sanitized (agent-generated content
  # never passes raw HTML through).
  defmodule ReportBodyClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    # A spec-compliant run file: the frontmatter block is index metadata and
    # must never render as drawer content.
    def read_agent_file(_agent_id, "/.salix/reports/daily-briefing-abc/2026-07-04.md"),
      do:
        {:ok,
         """
         ---
         title: Daily Briefing
         kind: daily
         schedule_id: sched-daily-frontmatter
         generated_at: 2026-07-04T08:00:00Z
         ---
         Markets **rallied** today.

         <script>alert(1)</script>
         """}

    def read_agent_file(_agent_id, "/.salix/reports/daily-briefing-abc/2026-07-03.md"),
      do: {:ok, "Yesterday was *quiet*."}

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "the report drawer renders the run's markdown and swaps between series runs", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ReportBodyClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    [older, latest] =
      for {period, day} <- [{"Jul 3", "03"}, {"Jul 4", "04"}] do
        create_task(user.id, org.id, project.id, %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "salix_schedule_id" => "sched-daily",
          "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md",
          "payload" => %{
            "kind" => "daily",
            "period" => period,
            "series" => "daily-briefing-abc",
            "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md"
          }
        })
      end

    {:ok, view, _html} = live(conn, ~p"/new-home")

    render_click(view, "open_drawer", %{"kind" => "result", "id" => latest.id})
    html = render_async(view)

    # The markdown body, MDEx-rendered and sanitized: emphasis survives, raw
    # HTML does not.
    assert html =~ "<strong>rallied</strong>"
    refute html =~ "<script>"

    # The frontmatter block is stripped before rendering — its keys (including
    # the internal schedule id) never show up as drawer content.
    refute html =~ "generated_at"
    refute html =~ "sched-daily-frontmatter"
    refute html =~ "kind: daily"

    # The series' other runs list below the body, and clicking one swaps the
    # drawer to that run (its own async read included).
    assert html =~ "Earlier runs"
    assert html =~ "Jul 3"

    render_click(view, "open_drawer", %{"kind" => "result", "id" => older.id})
    html = render_async(view)

    assert html =~ "<em>quiet</em>"
    assert html =~ "Jul 4"
    refute html =~ "<strong>rallied</strong>"
  end

  # A generic artifact document: markdown prose interleaved with fenced
  # `bft:block` JSON. The drawer renders prose sanitized and blocks natively —
  # raw JSON never reaches the page, and a broken fence degrades to the quiet
  # placeholder card.
  defmodule ArtifactDocumentClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    def read_agent_file(_agent_id, "/.salix/artifacts/competitor-scan-abc/2026-07-06.md") do
      {:ok,
       """
       ---
       title: Competitor scan
       kind: brief
       summary: Two rivals moved this week.
       generated_at: 2026-07-06T08:00:00Z
       ---
       The **landscape** shifted this week.

       ```bft:block
       {"type": "kpis", "items": [{"label": "Rivals tracked", "value": "7", "delta": "+2"}]}
       ```

       ```bft:block
       {this is not json}
       ```

       Keep an eye on the pricing page.
       """}
    end

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "the result drawer renders an artifact document's prose and blocks natively", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ArtifactDocumentClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Competitor scan",
        "category" => "engineering",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{
          "vfs_path" => "/.salix/artifacts/competitor-scan-abc/2026-07-06.md",
          "summary" => "Two rivals moved this week.",
          "hero" => %{
            "type" => "kpis",
            "items" => [%{"label" => "Rivals tracked", "value" => "7", "delta" => "+2"}]
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    # The board card renders the payload hero as a compact kpis block.
    html = render(view)
    assert html =~ "Rivals tracked"
    assert html =~ "+2"

    # The drawer opens instantly on the index summary; the document replaces
    # it when the async VFS read lands.
    html = render_click(view, "open_drawer", %{"kind" => "result", "id" => task.id})
    assert html =~ "Two rivals moved this week."

    html = render_async(view)

    # Markdown segments render sanitized; block segments render natively.
    assert html =~ "<strong>landscape</strong>"
    assert html =~ "Keep an eye on the pricing page."
    assert html =~ "Rivals tracked"

    # Frontmatter is index metadata, never drawer content.
    refute html =~ "generated_at"
    refute html =~ "kind: brief"

    # The broken fence degrades to the quiet card — raw JSON text never renders.
    assert html =~ "Unrecognized content"
    refute html =~ "this is not json"
    refute html =~ "bft:block"

    # The drawer links to the full-page reader for this row.
    assert html =~ "Open full view"
    assert html =~ ~s(href="/new-home/artifacts/#{task.id}")
  end

  # In a multi-agent swarm a run can live in ANY agent's VFS (delegation, a
  # resumed routine pinned to a non-first agent, sweeper-created rows) — the
  # row's `salix_agent_id` provenance names the owner, and the drawer read
  # must target it instead of defaulting to the project's first agent.
  defmodule AgentScopedReportClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore,
      store: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store

    defdelegate get_agent_projection(agent_id, tenant_id),
      to: BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}

    def list_group_meetings(group_id),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_meetings(
          group_id
        )

    def list_group_conversations(group_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversations(
          group_id,
          opts
        )

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    # Only the owning agent's VFS holds the run file — a read resolved to any
    # other agent honestly misses.
    def read_agent_file(agent_id, "/.salix/reports/daily-briefing-abc/2026-07-06.md") do
      if agent_id == Application.get_env(:bridge_for_teams_web, :test_report_owner_agent_id) do
        {:ok, "---\ntitle: Daily Briefing\n---\nWritten by the *owning* agent."}
      else
        {:error, :not_found}
      end
    end

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.create_group_conversation(
          group_id,
          attrs
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.update_group_conversation(
          group_id,
          conversation_id,
          attrs
        )

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.append_group_conversation_message(
        group_id,
        conversation_id,
        attrs
      )
    end

    def get_group_conversation(group_id, conversation_id) do
      BridgeForTeams.TestConversationStore.get_group_conversation_or(
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.Store,
        group_id,
        conversation_id,
        fn ->
          {:ok,
           %{"conversation_id" => conversation_id, "kind" => "agent_task", "participants" => []}}
        end
      )
    end

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeamsWeb.Dashboard.NewHomeLiveTest.ConversationClient.list_group_conversation_messages(
          group_id,
          conversation_id,
          opts
        )
  end

  test "the drawer reads the run from the row's own agent, not the project's first", %{
    conn: conn
  } do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, AgentScopedReportClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_web, :test_report_owner_agent_id)
    end)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    # A second provisioned agent — NOT the one the unnamed default resolves.
    {:ok, second} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "Zed Worker",
        "role" => "worker"
      })

    Application.put_env(:bridge_for_teams_web, :test_report_owner_agent_id, second.salix_agent_id)

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Daily Briefing",
        "category" => "reports",
        "platform" => "comma",
        "status" => "ready_for_review",
        "salix_agent_id" => second.salix_agent_id,
        "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-06.md",
        "payload" => %{
          "kind" => "daily",
          "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-06.md"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")

    render_click(view, "open_drawer", %{"kind" => "result", "id" => task.id})
    html = render_async(view)

    assert html =~ "<em>owning</em> agent"
    refute html =~ "Content unavailable right now."
  end

  test "mount does not backfill legacy report offer payloads", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    create_task(user.id, org.id, project.id, %{
      "title" => "Daily Briefing",
      "category" => "reports",
      "platform" => "comma",
      "status" => "accepted",
      "source" => "onboarding",
      "payload" => %{"kind" => "daily", "offer" => "report"}
    })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    reports = WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
    assert [daily] = reports
    refute Map.has_key?(daily.payload, "series")
    refute Map.has_key?(daily.payload, "site_name")
  end

  # ---- liveness: relayed agent events ------------------------------------------

  test "an org agent event refreshes the board without waiting for the poll", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    # Seed a fresh projection before mounting, and isolate this event test from
    # the independent mount-triggered projection refresh. render_async/1 only
    # waits for LiveView tasks, not the supervised projection worker.
    prev_auto = Application.get_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh)
    Application.put_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh, false)

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh, prev_auto)
    end)

    # No agent means there is no chat poll either.
    project = bare_project_fixture(org)
    assert {:ok, _snapshot} = DashboardProjection.refresh_project(project)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render_async(view)

    # A canonical projection row lands while we are watching.
    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Freshly delegated output",
          "category" => "general",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent"
        }
      ])

    refute render(view) =~ "Freshly delegated output"

    Phoenix.PubSub.broadcast(
      BridgeForTeamsWeb.PubSub,
      BridgeForTeams.Salix.EventRelay.topic(org.id),
      {:agent_event, org.id, "agent_x", {:session_updated, "s1"}}
    )

    assert_rendered_eventually(view, "Freshly delegated output")
  end

  test "an agent event observes a title-only Conversation update after a Message", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    {:ok, binding} = AssistantChats.get_binding(user.id, project.id)
    assert has_element?(view, "#chat-rail", "Comma assistant")

    {:ok, _message} =
      ConversationClient.append_group_conversation_message(
        project.salix_group_id,
        binding.conversation_id,
        %{
          "client_request_id" => "title-order-message",
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => "agent-router",
          "content" => [%{"type" => "text", "text" => "The visible reply arrived first."}]
        }
      )

    broadcast_agent_refresh(org)
    assert_rendered_eventually(view, "The visible reply arrived first.")
    assert has_element?(view, "#chat-rail", "Comma assistant")

    {:ok, before_title_messages} =
      ConversationClient.list_group_conversation_messages(
        project.salix_group_id,
        binding.conversation_id,
        limit: 100
      )

    {:ok, _conversation} =
      ConversationClient.update_group_conversation(
        project.salix_group_id,
        binding.conversation_id,
        %{"title" => "Quarterly planning"}
      )

    {:ok, after_title_messages} =
      ConversationClient.list_group_conversation_messages(
        project.salix_group_id,
        binding.conversation_id,
        limit: 100
      )

    assert Enum.map(after_title_messages, & &1["message_id"]) ==
             Enum.map(before_title_messages, & &1["message_id"])

    broadcast_agent_refresh(org)
    assert_rendered_eventually(view, "Quarterly planning")
  end

  defp broadcast_agent_refresh(org) do
    Phoenix.PubSub.broadcast(
      BridgeForTeamsWeb.PubSub,
      BridgeForTeams.Salix.EventRelay.topic(org.id),
      {:agent_event, org.id, "agent_x", {:session_updated, "s1"}}
    )
  end

  test "mounting watches the org: Salix agent events reach the org topic", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Deals",
        "slug" => "deals-#{System.unique_integer([:positive])}"
      })

    drain_reconciler()

    agent = project.id |> BridgeForTeams.Agents.list_agents() |> List.first()

    :ok =
      Phoenix.PubSub.subscribe(
        BridgeForTeamsWeb.PubSub,
        BridgeForTeams.Salix.EventRelay.topic(org.id)
      )

    # Mount registers dashboard interest with the relay (synchronously, inside
    # mount), which subscribes to the org's provisioned agents on the Salix side.
    {:ok, _view, _html} = live(conn, ~p"/new-home")

    Phoenix.PubSub.broadcast(
      SalixWeb.PubSub,
      "agent:" <> agent.salix_agent_id,
      {:salix_agent_event, agent.salix_agent_id, {:session_updated, "s1"}}
    )

    org_id = org.id
    salix_agent_id = agent.salix_agent_id
    assert_receive {:agent_event, ^org_id, ^salix_agent_id, {:session_updated, "s1"}}
  end

  # ---- chat status line: live activity signals ----------------------------------

  # Synthesizes the relayed activity event (`SalixAgent.ActivityEvent`) for a
  # runtime session: defaults are a running "Thinking".
  defp activity_event(org_id, session_id, attrs) do
    activity =
      Map.merge(
        %{
          "agent_id" => "agent-x",
          "session_id" => session_id,
          "phase" => "thinking",
          "status" => "running",
          "action" => "Thinking",
          "summary" => "Thinking"
        },
        attrs
      )

    {:agent_event, org_id, "agent-x", {:activity, activity}}
  end

  # Relayed `{:activity, map}` signals drive the status line in the chat
  # surfaces: thinking shows, an execution replaces it with its friendly
  # label, unwatched sessions are ignored, and the terminal idle clears the
  # surface.
  test "live activity events drive the chat status line", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home/chat")
    # Flush :init_chat so the chat is :ready and the binding exists.
    render(view)

    agent = Enum.find(BridgeForTeams.Agents.list_agents(project.id), &(&1.role == "router"))

    {:ok, projection} =
      ConversationClient.get_agent_projection(agent.salix_agent_id, org.salix_tenant_id)

    session_id = projection["router_session_id"]

    emit = fn attrs -> send(view.pid, activity_event(org.id, session_id, attrs)) end

    refute render(view) =~ "Thinking"

    emit.(%{})
    assert render(view) =~ "Thinking"

    # A thinking activity carrying the model's latest reasoning line shows it
    # after the prefix.
    emit.(%{"summary" => "Weighing the tradeoffs"})
    assert render(view) =~ "Thinking · Weighing the tradeoffs"

    # A tool execution replaces the line with its friendly label — here the
    # model-authored env.exec description.
    emit.(%{
      "phase" => "execution",
      "action" => "Running Checking logs",
      "summary" => "Running Checking logs",
      "tool_name" => "env.exec"
    })

    html = render(view)
    assert html =~ "Running Checking logs"
    refute html =~ "Thinking"

    # The agent's other sessions (its own background work) stay off the chat.
    send(
      view.pid,
      activity_event(org.id, "main", %{
        "phase" => "execution",
        "action" => "Running elsewhere",
        "summary" => "Running elsewhere"
      })
    )

    html = render(view)
    refute html =~ "Running elsewhere"
    assert html =~ "Running Checking logs"

    # The turn settles: idle clears the surface.
    emit.(%{"phase" => "idle", "status" => "idle", "action" => nil, "summary" => nil})
    refute render(view) =~ "Running Checking logs"
  end

  # The assistant chat is usually backed by the swarm's ROUTER agent, whose
  # turns all run in the group's one canonical router session — never
  # `im-<conversation_id>`. The status line must follow that session too.
  test "router-session activity drives the assistant status line", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home/chat")
    render(view)

    agent = Enum.find(BridgeForTeams.Agents.list_agents(project.id), &(&1.role == "router"))
    assert %BridgeForTeams.Schema.Agent{} = agent

    {:ok, projection} =
      ConversationClient.get_agent_projection(agent.salix_agent_id, org.salix_tenant_id)

    router_session = projection["router_session_id"]

    send(view.pid, activity_event(org.id, router_session, %{}))
    assert render(view) =~ "Thinking"

    send(
      view.pid,
      activity_event(org.id, router_session, %{
        "phase" => "idle",
        "status" => "idle",
        "action" => nil,
        "summary" => nil
      })
    )

    refute render(view) =~ "Thinking"
  end

  # The status surface is event-sourced, so a page refresh would lose an
  # in-flight line; chat init seeds it from the runtime's in-memory activity
  # surface instead.
  test "a fresh mount seeds the status line from the runtime activity surface", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    agent = project.id |> BridgeForTeams.Agents.list_agents() |> List.first()

    {:ok, projection} =
      ConversationClient.get_agent_projection(agent.salix_agent_id, org.salix_tenant_id)

    router_session = projection["router_session_id"]

    Application.put_env(:bridge_for_teams_web, :test_agent_activities, [
      %{
        "agent_id" => agent.salix_agent_id,
        "session_id" => router_session,
        "phase" => "thinking",
        "status" => "running",
        "action" => "Thinking",
        "summary" => "Weighing the tradeoffs"
      }
    ])

    on_exit(fn -> Application.delete_env(:bridge_for_teams_web, :test_agent_activities) end)

    # No live event is delivered — the line comes from the connect-time seed.
    {:ok, view, _html} = live(conn, ~p"/new-home/chat")
    assert render(view) =~ "Thinking · Weighing the tradeoffs"
  end

  # Opening a task conversation keeps the rail on the assistant thread while the
  # drawer shows the task thread; each surface renders its own status line.
  test "the status line separates assistant rail and task drawer activity", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    with_scripted_client()

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Chase the diligence checklist",
        "category" => "general",
        "platform" => "comma",
        "status" => "in_progress",
        "source" => "user",
        "conversation_id" => "conv-delegated-1",
        "salix_conversation_id" => "conv-delegated-1",
        "salix_agent_id" => "agent-delegate"
      })

    {:ok, view, _html} = live(conn, ~p"/new-home")
    render(view)

    agent = Enum.find(BridgeForTeams.Agents.list_agents(project.id), &(&1.role == "router"))

    {:ok, projection} =
      ConversationClient.get_agent_projection(agent.salix_agent_id, org.salix_tenant_id)

    assistant_session = projection["router_session_id"]

    # The assistant thread is thinking; the rail (unfocused) shows it.
    send(view.pid, activity_event(org.id, assistant_session, %{}))
    assert render(view) =~ "Thinking"

    # Open the task's conversation in the drawer. The rail remains on the
    # assistant conversation, so the assistant status line stays visible.
    render_click(view, "run_task", %{"id" => task.id})
    render_async(view)

    assert render(view) =~ "Thinking"

    send(
      view.pid,
      activity_event(org.id, "ses1_0000000000000000002", %{
        "phase" => "execution",
        "action" => "Running Digging in",
        "summary" => "Running Digging in",
        "tool_name" => "env.exec"
      })
    )

    html = render(view)
    assert html =~ "Running Digging in"
    assert html =~ "Thinking"

    # Closing the task drawer leaves the assistant rail and its status line.
    render_click(view, "close_drawer", %{})
    html = render(view)
    assert html =~ "Thinking"
    refute html =~ "Running Digging in"
  end

  # The event-driven refresh is debounced (~200ms); poll the rendered HTML
  # briefly instead of hardcoding one sleep.
  defp assert_rendered_eventually(view, text, attempts \\ 50)

  defp assert_rendered_eventually(view, text, 0) do
    assert render(view) =~ text
  end

  defp assert_rendered_eventually(view, text, attempts) do
    if render(view) =~ text do
      :ok
    else
      Process.sleep(50)
      assert_rendered_eventually(view, text, attempts - 1)
    end
  end

  defp assert_projection_refreshed(project_id, attempts \\ 20)

  defp assert_projection_refreshed(project_id, 0) do
    assert %{refreshed_at: %DateTime{}} = DashboardProjection.snapshot_for_project(project_id)
  end

  defp assert_projection_refreshed(project_id, attempts) do
    case DashboardProjection.snapshot_for_project(project_id) do
      %{refreshed_at: %DateTime{}} ->
        :ok

      _ ->
        Process.sleep(50)
        assert_projection_refreshed(project_id, attempts - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # ---- branch UI: hero composer, working list, suggestions, chat sheet ---------

  # No reachable swarm is honest: nothing is seeded, the board is empty, and
  # the chat shows its no-agent state.
  test "with no reachable swarm the board is empty and the chat degrades", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    assert html =~ "No agent to chat with yet"
    # No swarm to seed ⇒ no task rows and no seeded widgets.
    assert Regex.scan(~r/data-task-row/, html) == []
    refute html =~ "Key metrics"
  end

  test "the Tasks list folds past ten rows behind Show more", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(
        user.id,
        org.id,
        project.id,
        for n <- 1..12 do
          %{
            "title" => "Folding task #{n}",
            "category" => "general",
            "platform" => "comma",
            "status" => "accepted",
            "source" => "agent"
          }
        end
      )

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    visible = length(Regex.scan(~r/data-task-row/, html))
    assert visible == 10
    assert html =~ "Show more"

    html = render_click(view, "expand_tasks", %{})
    refute html =~ "Show more"
    assert length(Regex.scan(~r/data-task-row/, html)) > 10
  end

  test "the meeting drawer renders a string summary instead of crashing", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    # A worker reporting through the generic artifact contract writes
    # payload.summary as a STRING; the projection's meetings write a map.
    # Both must render.
    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Build research dossiers for my key contacts",
          "category" => "meetings",
          "platform" => "comma",
          "status" => "in_progress",
          "source" => "agent",
          "payload" => %{"summary" => "Initial dossiers scaffolded, ready to populate."}
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")

    html = render_click(view, "open_drawer", %{"id" => task.id, "kind" => "meeting"})
    assert html =~ "Initial dossiers scaffolded, ready to populate."

    # The structured map shape still renders its sections.
    {:ok, _updated} =
      WorkspaceItems.update_task(task, %{
        "payload" => %{
          "summary" => %{"key_points" => ["Point one"], "action_items" => []}
        }
      })

    render_click(view, "close_drawer", %{})
    send(view.pid, {:dashboard_projection_refreshed, project.id})
    render(view)
    html = render_click(view, "open_drawer", %{"id" => task.id, "kind" => "meeting"})
    assert html =~ "Point one"
  end

  test "the Tasks subtitle states who holds the work", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    # Agent-held work only: no false "for you to review" count.
    {:ok, [working]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Compile the digest",
          "category" => "general",
          "platform" => "comma",
          "status" => "in_progress",
          "source" => "agent"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)
    assert html =~ "Your agent is working on 1 task — nothing to review yet."

    # Once something lands for review, both sides are counted.
    {:ok, _reviewable} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Review the digest draft",
          "category" => "general",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent"
        }
      ])

    send(view.pid, {:dashboard_projection_refreshed, project.id})
    html = render(view)
    assert html =~ "1 for you to review · 1 in progress with your agent."

    # Only reviewable work left: a plain review count.
    {:ok, _done} = WorkspaceItems.update_task(working, %{"status" => "done"})
    send(view.pid, {:dashboard_projection_refreshed, project.id})
    html = render(view)
    assert html =~ "1 task for you to review."
  end

  # No agent-proposed suggestion items ⇒ no Suggestions section at all (the
  # static catalog fallback is gone).
  test "the Suggestions block is hidden when the agent has proposed nothing", %{conn: conn} do
    %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
    _project = bare_project_fixture(org)

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    refute html =~ "Proposed by your agent."
    refute html =~ "Find everything I need to follow up on"
    refute html =~ "Compile a portfolio status overview"
  end

  test "suggestion items render the block; accept moves the item and dismiss archives it",
       %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)

    {:ok, [pr_item, task_item]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Open the canary-policy PR",
          "description" => "Branch is staged; opens against infra-config.",
          "category" => "suggestions",
          "platform" => "github",
          "status" => "suggested",
          "source" => "agent",
          "payload" => %{"category" => "general"}
        },
        %{
          "title" => "File the disk-pressure Linear issue",
          "category" => "suggestions",
          "platform" => "linear",
          "status" => "suggested",
          "source" => "agent",
          "payload" => %{"category" => "issues"}
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/new-home")
    html = render(view)

    # Item-backed suggestions own the block: both render, the catalog
    # fallbacks don't, and the subtitle names the agent.
    assert html =~ "Open the canary-policy PR"
    assert html =~ "File the disk-pressure Linear issue"
    assert html =~ "Proposed by your agent."
    refute html =~ "Find everything I need to follow up on"

    # Accept: the SAME item moves into its target category as an accepted
    # task — no duplicate card — and leaves the strip (though it may now
    # legitimately render elsewhere on the board under the same id).
    before_count = length(WorkspaceItems.list_tasks(user.id, project_id: project.id))
    render_click(view, "open_suggestion", %{"id" => pr_item.id})
    html = render_click(view, "accept_suggestion", %{"id" => pr_item.id})
    refute html =~ ~r/open_suggestion"\s+phx-value-id="#{pr_item.id}"/

    assert length(WorkspaceItems.list_tasks(user.id, project_id: project.id)) == before_count

    {:ok, settled} = WorkspaceItems.get_task(user.id, pr_item.id, project_id: project.id)
    assert %{status: "accepted", category: "general", platform: "github"} = settled

    # Dismiss: archives the item — durable, no onboarding-profile bookkeeping.
    html = render_click(view, "dismiss_suggestion", %{"id" => task_item.id})
    refute html =~ ~r/open_suggestion"\s+phx-value-id="#{task_item.id}"/

    {:ok, dismissed} =
      WorkspaceItems.get_task(user.id, task_item.id, project_id: project.id)

    assert dismissed.status == "archived"

    {:ok, onboarding} = BridgeForTeams.UserOnboardings.get_onboarding(user.id)
    assert (onboarding.profile["dismissed_suggestions"] || []) == []

    # With both items settled the section disappears entirely.
    html = render_click(view, "expand_tasks", %{})
    refute html =~ "Proposed by your agent."
    refute html =~ "Find everything I need to follow up on"
  end

  test "the chat sheet stacks over the board at /new-home/chat", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/new-home/chat")
    html = render(view)

    # Sheet card stacked over the receded board panel (no dark scrim).
    assert html =~ "chat-sheet"
    assert html =~ "t-sheet"
    assert html =~ "is-stacked"
    refute html =~ "t-sheet-scrim"

    # Escape / scrim / × all collapse back to the board.
    html = render_click(view, "collapse_chat", %{})
    refute html =~ "chat-sheet"
  end

  test "overlay close controls start local transitions before LiveView events", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    draft = seed_email_draft(user.id, org.id, project.id)

    {:ok, view, _html} = live(conn, ~p"/new-home/chat")

    html = render(view)
    assert_local_close_before_push(html, "#chat-sheet", "collapse_chat")

    html = render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => draft.id})
    assert_local_close_before_push(html, "#home-drawer", "close_drawer")
  end

  test "Escape peels stacked overlays one at a time, topmost first", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    project = bare_project_fixture(org)
    draft = seed_email_draft(user.id, org.id, project.id)

    {:ok, view, _html} = live(conn, ~p"/new-home/chat")
    render_click(view, "open_drawer", %{"kind" => "email_preview", "id" => draft.id})

    # First Escape closes only the drawer — the sheet underneath stays put.
    html = render_hook(view, "escape_pressed", %{})
    refute html =~ "home-drawer"
    assert html =~ "chat-sheet"

    # Second Escape collapses the sheet back onto the board.
    render_hook(view, "escape_pressed", %{})
    assert_patch(view, ~p"/new-home")
    refute render(view) =~ "chat-sheet"
  end

  test "the chat rail sits beside the board with its own composer", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, _view, html} = live(conn, ~p"/new-home")

    # Chrome-level rail: always mounted beside the raised panel, no sheet.
    assert html =~ ~s(id="chat-rail")
    assert html =~ ~s(id="chat-form-rail")
    refute html =~ "chat-sheet"
  end

  describe "widget wall" do
    test "the retired /new-home/widgets URL lands back on the board", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
      _project = bare_project_fixture(org)

      # The patch issued during the initial mount surfaces as a redirect.
      {:ok, _view, html} =
        live(conn, ~p"/new-home/widgets") |> follow_redirect(conn, ~p"/new-home")

      assert html =~ ~s(id="dash-widget-grid")
    end

    test "renders inline below the Tasks list with every category", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
      _project = bare_project_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/new-home")

      # The wall lives on the page itself — no View board entry, no sheet.
      refute html =~ "View board"
      refute html =~ "widgets-sheet"
      assert html =~ ~s(id="dash-widget-grid")

      # Empty categories still get a preview card — the wall shows the full
      # catalog, not just what has data.
      assert html =~ ~s(id="dash-widget-inbox")
      assert html =~ ~s(id="dash-widget-calendar")
      assert html =~ "Nothing here yet"
      # General lives in the Tasks list, never on the wall.
      refute html =~ ~s(id="dash-widget-general")
    end

    test "every widget defaults to medium; sizes persist across mounts", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      project = bare_project_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/new-home")
      html = render(view)

      # Every category starts medium (2x1) — no stored prefs yet.
      assert html =~ ~r/id="dash-widget-reports"[^>]*class="[^"]*col-span-2 row-span-1/
      assert html =~ ~r/id="dash-widget-metrics"[^>]*class="[^"]*col-span-2 row-span-1/
      refute html =~ ~r/id="dash-widget-[a-z_]+"[^>]*class="[^"]*row-span-2/

      html = render_click(view, "set_widget_size", %{"category" => "metrics", "size" => "large"})
      assert html =~ ~r/id="dash-widget-metrics"[^>]*class="[^"]*row-span-2/

      %{widget_sizes: sizes} = BridgeForTeams.DashboardPrefs.get(user.id, org.id)
      assert sizes == %{project.id => %{"metrics" => "large"}}

      {:ok, view, _html} = live(conn, ~p"/new-home")
      assert render(view) =~ ~r/id="dash-widget-metrics"[^>]*class="[^"]*row-span-2/
    end

    test "drag reorder persists and keeps General in the layout", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      project = bare_project_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/new-home")

      order =
        ~w(metrics reports meetings email_drafts meeting_recaps portfolio team_activity engineering inbox informed calendar routines custom)

      render_hook(view, "reorder_dash_widgets", %{"order" => order})

      %{home_layout: home_layout} = BridgeForTeams.DashboardPrefs.get(user.id, org.id)
      stored = home_layout[project.id]
      assert "general" in stored
      assert stored -- ["general"] == order

      # The wall grid re-renders in the new order ("grid" is the container's
      # own id, not a card) — and a fresh mount renders the saved order too.
      first_card = fn view ->
        Regex.scan(~r/id="dash-widget-([a-z_]+)"/, render(view))
        |> Enum.map(fn [_, cat] -> cat end)
        |> Enum.reject(&(&1 == "grid"))
        |> List.first()
      end

      assert first_card.(view) == "metrics"

      {:ok, view, _html} = live(conn, ~p"/new-home")
      assert first_card.(view) == "metrics"
    end

    test "unknown categories and General are never sized", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      _project = bare_project_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/new-home")

      render_click(view, "set_widget_size", %{"category" => "bogus", "size" => "large"})
      render_click(view, "set_widget_size", %{"category" => "general", "size" => "large"})

      prefs = BridgeForTeams.DashboardPrefs.get(user.id, org.id)
      assert prefs == nil or prefs.widget_sizes == %{}
    end

    test "Reset layout appears with a customization and restores the defaults", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      project = bare_project_fixture(org)

      {:ok, view, html} = live(conn, ~p"/new-home")
      refute html =~ "Reset layout"

      # First adjustment: the button appears, the size persists.
      html = render_click(view, "set_widget_size", %{"category" => "metrics", "size" => "large"})
      assert html =~ "Reset layout"
      assert html =~ ~r/id="dash-widget-metrics"[^>]*class="[^"]*row-span-2/

      # It survives a remount alongside the saved customization.
      {:ok, view, html} = live(conn, ~p"/new-home")
      assert html =~ "Reset layout"

      # Reset: canonical order, default sizes, button gone — durably.
      html = render_click(view, "reset_wall_layout", %{})
      refute html =~ "Reset layout"
      assert html =~ ~r/id="dash-widget-metrics"[^>]*class="[^"]*col-span-2 row-span-1/

      prefs = BridgeForTeams.DashboardPrefs.get(user.id, org.id)
      refute Map.has_key?(prefs.widget_sizes || %{}, project.id)
      refute Map.has_key?(prefs.home_layout || %{}, project.id)

      {:ok, _view, html} = live(conn, ~p"/new-home")
      refute html =~ "Reset layout"
    end

    test "a partial saved layout renders first, then the canonical rest", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      project = bare_project_fixture(org)

      {:ok, _prefs} =
        BridgeForTeams.DashboardPrefs.put_home_layout(user.id, org.id, %{
          project.id => ["portfolio", "metrics", "email_drafts"]
        })

      {:ok, view, _html} = live(conn, ~p"/new-home")

      categories =
        Regex.scan(~r/id="dash-widget-([a-z_]+)"/, render(view))
        |> Enum.map(fn [_, cat] -> cat end)
        |> Enum.reject(&(&1 == "grid"))

      assert ["portfolio", "metrics", "email_drafts" | rest] = categories
      refute "general" in categories
      assert "reports" in rest
    end
  end
end
