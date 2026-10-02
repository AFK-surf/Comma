defmodule BridgeForTeamsWeb.Dashboard.ConversationLiveShowTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Agents, Memberships, Observability}

  defmodule ConversationShowSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    @conversation %{
      "conversation_id" => "task-dashboard-status",
      "title" => "Worker task",
      "kind" => "agent_task",
      "updated_at" => 1_780_000_100_000,
      "schedule" => %{
        "schedule_id" => "schedule-task-dashboard-status",
        "command" => "Inspect the task."
      },
      "participants" => [
        %{
          "participant_id" => "worker",
          "actor_type" => "agent",
          "agent_id" => "agent-worker-status",
          "role_label" => "worker",
          "payload" => %{"session_id" => "im-task-dashboard-status"}
        },
        %{
          "participant_id" => "slack:connect-status:C-status:100.000",
          "actor_type" => "provider",
          "provider" => "slack",
          "role_label" => "slack_thread",
          "payload" => %{
            "connect_id" => "connect-status",
            "workspace_id" => "T-status",
            "channel_id" => "C-status",
            "thread_ts" => "100.000",
            "thread_url" =>
              "https://app.slack.com/client/T-status/C-status/thread/C-status-100.000"
          }
        }
      ]
    }

    @untitled_conversation %{
      "conversation_id" => "task-untitled",
      "kind" => "work_session",
      "participants" => []
    }

    def get_group_conversation(_group_id, "task-dashboard-status") do
      {:ok, Map.delete(conversation(), "participants")}
    end

    def get_group_conversation(_group_id, "task-untitled"), do: {:ok, @untitled_conversation}
    def get_group_conversation(_group_id, _conversation_id), do: {:error, :not_found}

    def subscribe_group_conversation(_group_id, _conversation_id, subscriber) do
      owner = Application.fetch_env!(:bridge_for_teams_web, :conversation_subscription_owner)

      if observer =
           Application.get_env(:bridge_for_teams_web, :conversation_subscription_observer),
         do: send(observer, {:conversation_subscribed, subscriber, owner})

      {:ok,
       %{
         "owner_pid" => owner,
         "tail_seq" =>
           Application.get_env(:bridge_for_teams_web, :conversation_subscription_tail, 1)
       }}
    end

    def get_schedule("schedule-task-dashboard-status") do
      recurrence =
        Application.get_env(
          :bridge_for_teams_web,
          :task_schedule_definition,
          %{"interval_minutes" => 60}
        )

      {:ok,
       Map.merge(
         %{
           "id" => "schedule-task-dashboard-status",
           "receiver" => "task",
           "payload" => %{
             "agent_group_id" => Application.fetch_env!(:bridge_for_teams_web, :status_group_id),
             "conversation_id" => "task-dashboard-status"
           },
           "created_at" => 1_780_000_000_000,
           "last_run" => nil
         },
         recurrence
       )}
    end

    def get_schedule(_schedule_id), do: {:error, :not_found}

    def list_group_conversation_participants(_group_id, "task-dashboard-status", _opts) do
      {:ok,
       %{
         "conversation_id" => "task-dashboard-status",
         "participants" => conversation()["participants"]
       }}
    end

    def list_group_conversation_participants(_group_id, "task-untitled", _opts) do
      {:ok, %{"conversation_id" => "task-untitled", "participants" => []}}
    end

    defp conversation do
      conversation =
        put_in(
          @conversation,
          ["participants", Access.at(0), "agent_id"],
          Application.fetch_env!(:bridge_for_teams_web, :status_agent_id)
        )

      conversation =
        case Application.get_env(:bridge_for_teams_web, :task_schedule_override) do
          :deleted -> put_in(conversation, ["schedule", "schedule_id"], nil)
          schedule when is_map(schedule) -> Map.put(conversation, "schedule", schedule)
          _ -> conversation
        end

      Map.merge(
        conversation,
        Application.get_env(:bridge_for_teams_web, :conversation_workflow_override, %{})
      )
    end

    def update_task_schedule(_group_id, _conversation_id, attrs) when is_map(attrs) do
      Application.put_env(
        :bridge_for_teams_web,
        :task_schedule_definition,
        Map.take(attrs, ~w(interval_minutes cron timezone))
      )

      Application.put_env(
        :bridge_for_teams_web,
        :task_schedule_override,
        put_in(@conversation["schedule"], ["schedule_id"], "schedule-task-dashboard-status")
      )

      {:ok, Map.delete(conversation(), "participants")}
    end

    def update_task_schedule(_group_id, _conversation_id, nil) do
      Application.put_env(:bridge_for_teams_web, :task_schedule_override, :deleted)
      {:ok, Map.delete(conversation(), "participants")}
    end

    def list_group_conversation_messages(_group_id, "task-untitled", _opts), do: {:ok, []}

    def list_group_conversation_messages(_group_id, "task-dashboard-status", _opts) do
      messages =
        [
          %{
            "message_id" => "slack-msg-1",
            "actor_type" => "provider_user",
            "participant_id" => "slack:connect-status:C-status:100.000",
            "user_id" => "U-status",
            "content" => [
              %{"type" => "text", "text" => "please handle this https://example.test/spec"},
              %{
                "type" => "image",
                "file_ref" => %{
                  "environment_id" => "vfs",
                  "path" => "/slack/attachments/spec.png"
                },
                "file_name" => "spec.png",
                "mime_type" => "image/png"
              },
              %{
                "type" => "file",
                "path" => "/slack/attachments/report.pdf",
                "file_name" => "report.pdf",
                "mime_type" => "application/pdf"
              }
            ],
            "created_at" => 1_780_000_000
          }
        ]

      {:ok, Application.get_env(:bridge_for_teams_web, :conversation_live_messages, messages)}
    end

    def get_group_conversation_with_messages(group_id, conversation_id, opts) do
      if observer = Application.get_env(:bridge_for_teams_web, :task_snapshot_observer),
        do: send(observer, {:task_snapshot_read, group_id, conversation_id, opts})

      case Application.get_env(:bridge_for_teams_web, :task_snapshot_error) do
        nil ->
          with {:ok, conversation} <- get_group_conversation(group_id, conversation_id),
               {:ok, messages} <-
                 list_group_conversation_messages(group_id, conversation_id, opts) do
            {:ok, %{"conversation" => conversation, "messages" => messages}}
          end

        reason ->
          {:error, reason}
      end
    end

    def accept_task_review(_group_id, "task-dashboard-status", review_version) do
      conversation = conversation()

      if conversation["status"] == "ready_for_review" and
           conversation["updated_at"] == review_version do
        override =
          Application.get_env(:bridge_for_teams_web, :conversation_workflow_override, %{})
          |> Map.merge(%{"status" => "completed", "updated_at" => review_version + 1})

        Application.put_env(
          :bridge_for_teams_web,
          :conversation_workflow_override,
          override
        )

        {:ok, Map.delete(conversation(), "participants")}
      else
        {:error, {:conflict, "Task review changed"}}
      end
    end

    def session_records(agent_id, "im-task-dashboard-status", opts) do
      ^agent_id = Application.fetch_env!(:bridge_for_teams_web, :status_agent_id)
      50 = Keyword.fetch!(opts, :limit)

      cond do
        fixture = Application.get_env(:bridge_for_teams_web, :session_evidence_records) ->
          if pages = fixture["pages"],
            do: {:ok, Map.fetch!(pages, Keyword.get(opts, :before) || "latest")},
            else: {:ok, fixture}

        Application.get_env(:bridge_for_teams_web, :empty_first_session_records, false) ->
          empty_first_records(Keyword.get(opts, :before))

        Application.get_env(:bridge_for_teams_web, :paginated_session_records, false) ->
          paginated_records(Keyword.get(opts, :before))

        true ->
          session_records_fixture()
      end
    end

    defp session_records_fixture do
      {:ok,
       if Application.get_env(:bridge_for_teams_web, :external_session_records, false) do
         %{
           "runtime_kind" => "external",
           "records" => [
             %{
               "id" => "event-status",
               "type" => "runtime.event",
               "created_at" => 1_780_000_010,
               "data" => %{
                 "event" => %{
                   "provider" => "codex",
                   "type" => "status",
                   "name" => "thread/status/changed",
                   "state" => "active"
                 }
               }
             },
             %{
               "id" => "event-response",
               "type" => "runtime.event",
               "created_at" => 1_780_000_011,
               "data" => %{
                 "event" => %{
                   "provider" => "codex",
                   "type" => "message",
                   "name" => "agentMessage",
                   "role" => "assistant",
                   "content" => "done"
                 }
               }
             },
             %{
               "id" => "event-command",
               "type" => "runtime.event",
               "created_at" => 1_780_000_012,
               "data" => %{
                 "event" => %{
                   "provider" => "codex",
                   "type" => "operation",
                   "operation_id" => "command-1",
                   "name" => "commandExecution",
                   "input" => %{"command" => "mix test"},
                   "output" => "7 tests, 0 failures",
                   "status" => "completed",
                   "duration_ms" => 900
                 }
               }
             }
           ]
         }
       else
         %{
           "runtime_kind" => "internal",
           "records" => [
             %{
               "id" => 1,
               "role" => "user",
               "content" => "Find the founder updates",
               "created_at" => 1_780_000_000
             },
             %{
               "id" => 2,
               "role" => "assistant",
               "content" => "",
               "provider_meta" => %{
                 "responses_items" => [
                   %{
                     "type" => "reasoning",
                     "content" => "Private model reasoning",
                     "summary" => [
                       %{
                         "type" => "summary_text",
                         "text" => "Search the connected mailbox first."
                       }
                     ]
                   }
                 ]
               },
               "created_at" => 1_780_000_001,
               "tool_calls" => [
                 %{
                   "id" => "tool-search",
                   "name" => "call",
                   "args" => %{
                     "tool" => "gmail.search_threads",
                     "params" => %{"query" => "from:founder"}
                   }
                 }
               ]
             },
             %{
               "id" => 3,
               "role" => "tool",
               "tool_call_id" => "tool-search",
               "tool_name" => "gmail.search_threads",
               "status" => "completed",
               "created_at" => 1_780_000_002,
               "duration_ms" => 1250,
               "output" => "3 threads"
             },
             %{
               "id" => 4,
               "role" => "assistant",
               "content" => "Found 3 founder threads.",
               "created_at" => 1_780_000_003
             },
             %{
               "id" => 5,
               "role" => "summary",
               "content" => "The mailbox search is complete.",
               "created_at" => 1_780_000_004
             },
             %{
               "id" => 6,
               "role" => "runtime",
               "type" => "context.updated",
               "summary" => "Runtime context refreshed",
               "created_at" => 1_780_000_005
             }
           ]
         }
       end}
    end

    defp empty_first_records(nil) do
      {:ok,
       %{
         "runtime_kind" => "internal",
         "records" => [],
         "has_more" => true,
         "next_before" => "visible-page"
       }}
    end

    defp empty_first_records("visible-page") do
      {:ok,
       %{
         "runtime_kind" => "internal",
         "records" => [
           %{
             "id" => 1,
             "role" => "user",
             "content" => "Visible on the earlier page",
             "created_at" => 1
           }
         ],
         "has_more" => false
       }}
    end

    defp paginated_records(nil) do
      {:ok,
       %{
         "runtime_kind" => "internal",
         "records" => [
           %{
             "id" => 3,
             "role" => "tool",
             "tool_call_id" => "tool-cross-page",
             "tool_name" => "fs.read_file",
             "status" => "completed",
             "content" => "file contents",
             "created_at" => 3
           }
         ],
         "has_more" => true,
         "next_before" => "older-page"
       }}
    end

    defp paginated_records("older-page") do
      {:ok,
       %{
         "runtime_kind" => "internal",
         "records" => [
           %{"id" => 1, "role" => "user", "content" => "Read the file", "created_at" => 1},
           %{
             "id" => 2,
             "role" => "assistant",
             "content" => "",
             "created_at" => 2,
             "tool_calls" => [
               %{
                 "id" => "tool-cross-page",
                 "name" => "fs.read_file",
                 "args" => %{"path" => "/workspace/README.md"}
               }
             ]
           }
         ],
         "has_more" => false
       }}
    end
  end

  setup %{conn: conn} do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_web, :status_agent_id)
      Application.delete_env(:bridge_for_teams_web, :status_group_id)
      Application.delete_env(:bridge_for_teams_web, :task_schedule_definition)
      Application.delete_env(:bridge_for_teams_web, :external_session_records)
      Application.delete_env(:bridge_for_teams_web, :session_evidence_records)
      Application.delete_env(:bridge_for_teams_web, :empty_first_session_records)
      Application.delete_env(:bridge_for_teams_web, :paginated_session_records)
      Application.delete_env(:bridge_for_teams_web, :conversation_live_messages)
      Application.delete_env(:bridge_for_teams_web, :task_snapshot_observer)
      Application.delete_env(:bridge_for_teams_web, :task_snapshot_error)
      Application.delete_env(:bridge_for_teams_web, :conversation_subscription_owner)
      Application.delete_env(:bridge_for_teams_web, :conversation_subscription_observer)
      Application.delete_env(:bridge_for_teams_web, :conversation_subscription_tail)
      Application.delete_env(:bridge_for_teams_web, :conversation_workflow_override)

      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    Application.put_env(:bridge_for_teams_core, :salix_client, ConversationShowSalixClient)
    Application.put_env(:bridge_for_teams_web, :conversation_subscription_owner, self())
    Application.put_env(:bridge_for_teams_web, :conversation_subscription_observer, self())

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Support",
        "slug" => "support"
      })

    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "status-worker",
        "role" => "worker"
      })

    Application.put_env(:bridge_for_teams_web, :status_agent_id, agent.salix_agent_id)
    Application.put_env(:bridge_for_teams_web, :status_group_id, project.salix_group_id)

    Application.put_env(:bridge_for_teams_web, :task_schedule_definition, %{
      "interval_minutes" => 60
    })

    Application.delete_env(:bridge_for_teams_web, :task_schedule_override)

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_web, :task_schedule_override)
    end)

    %{conn: log_in_user(conn, user), org: org, project: project}
  end

  test "task page shows user-facing participant details", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    # The synchronous store-backed reads (conversation + messages) render on mount.
    assert html =~ "Worker task"
    assert html =~ "Scheduled"
    assert html =~ "Every hour"
    assert has_element?(view, "aside", "Inspect the task.")
    assert has_element?(view, "button", "Edit")
    refute has_element?(view, "#task-schedule-form")
    assert html =~ "status-worker"
    assert html =~ "please handle this"
    assert html =~ "https://example.test/spec"
    assert html =~ "spec.png"
    assert html =~ "/slack/attachments/spec.png"
    assert html =~ "image/png"
    assert html =~ "report.pdf"
    assert html =~ "/slack/attachments/report.pdf"
    assert html =~ "application/pdf"
    assert has_element?(view, "#message-slack-msg-1.justify-end")
    assert has_element?(view, "#task-messages[phx-hook='ScrollToBottom']")
    assert has_element?(view, "aside[aria-label='Task details']")
    refute has_element?(view, "#participant-worker details")
    assert has_element?(view, "textarea[placeholder='Steer this task...']")
    assert has_element?(view, "button", "Steer")
    refute has_element?(view, "span", "1 message")
    refute has_element?(view, "h2", "Properties")
    refute has_element?(view, "summary", "Delivery")
    refute html =~ "UTC"

    view
    |> element("button", "Edit")
    |> render_click()

    assert has_element?(view, "#task-schedule-modal")
    assert has_element?(view, "input[name='schedule[interval_value]'][value='1']")

    assert has_element?(
             view,
             "select[name='schedule[interval_unit]'] option[value='hours'][selected]"
           )

    assert has_element?(view, "textarea[name='schedule[command]']", "Inspect the task.")

    view
    |> element("button", "Cancel")
    |> render_click()

    refute has_element?(view, "#task-schedule-modal")

    assert has_element?(
             view,
             "#participant-worker a[href*='/agents/']",
             "status-worker"
           )

    assert has_element?(
             view,
             "#participant-worker a[href*='/tasks/task-dashboard-status/session?participant=worker']",
             "View timeline"
           )

    refute html =~ "running · executing tool"
    refute html =~ "delivered"
    refute html =~ "im-task-dashboard-status"
    assert html =~ "Open Slack thread"
    assert html =~ "https://app.slack.com/client/T-status/C-status/thread/C-status-100.000"
  end

  test "task page refreshes when Salix commits a new conversation message", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    {:ok, messages} =
      ConversationShowSalixClient.list_group_conversation_messages(
        project.salix_group_id,
        "task-dashboard-status",
        []
      )

    Application.put_env(
      :bridge_for_teams_web,
      :conversation_live_messages,
      messages ++
        [
          %{
            "message_id" => "agent-msg-2",
            "seq" => 2,
            "actor_type" => "agent",
            "participant_id" => "worker",
            "agent_name" => "status-worker",
            "content" => [%{"type" => "text", "text" => "pushed from the server"}],
            "created_at" => 1_780_000_100
          }
        ]
    )

    send(
      view.pid,
      {:conversation_message_created, project.salix_group_id, "task-dashboard-status",
       "agent-msg-2", 2}
    )

    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#message-agent-msg-2", "pushed from the server")
  end

  test "task page re-subscribes and catches up after its conversation owner exits", %{
    conn: conn,
    org: org,
    project: project
  } do
    first_owner = spawn(fn -> Process.sleep(:infinity) end)
    second_owner = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(first_owner, :kill)
      Process.exit(second_owner, :kill)
    end)

    Application.put_env(:bridge_for_teams_web, :conversation_subscription_owner, first_owner)

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    assert_receive {:conversation_subscribed, live_pid, ^first_owner}
    assert live_pid == view.pid

    {:ok, messages} =
      ConversationShowSalixClient.list_group_conversation_messages(
        project.salix_group_id,
        "task-dashboard-status",
        []
      )

    Application.put_env(
      :bridge_for_teams_web,
      :conversation_live_messages,
      messages ++
        [
          %{
            "message_id" => "agent-msg-after-owner-loss",
            "seq" => 2,
            "actor_type" => "agent",
            "participant_id" => "worker",
            "content" => [%{"type" => "text", "text" => "caught up after owner restart"}],
            "created_at" => 1_780_000_200
          }
        ]
    )

    Application.put_env(:bridge_for_teams_web, :conversation_subscription_owner, second_owner)
    Application.put_env(:bridge_for_teams_web, :conversation_subscription_tail, 2)
    Process.exit(first_owner, :kill)

    assert_receive {:conversation_subscribed, ^live_pid, ^second_owner}, 2_000
    assert has_element?(view, "#message-agent-msg-after-owner-loss", "owner restart")
  end

  test "task page manages the live conversation Schedule in place", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    view
    |> element("button", "Edit")
    |> render_click()

    render_click(view, "delete_task_schedule")
    refute render(view) =~ "Scheduled"
    refute render(view) =~ "Set a valid schedule"
    assert has_element?(view, "button", "Add schedule")
    refute has_element?(view, "#task-schedule-form")

    view
    |> element("button", "Add schedule")
    |> render_click()

    view
    |> form("form[phx-change='validate_task_schedule']", schedule: %{mode: "interval"})
    |> render_change()

    view
    |> form("form[phx-submit='save_task_schedule']",
      schedule: %{
        mode: "interval",
        interval_value: "30",
        interval_unit: "minutes",
        command: "Inspect the task."
      }
    )
    |> render_submit()

    assert render(view) =~ "Scheduled"
    assert render(view) =~ "Every 30 minutes"
    assert has_element?(view, "button", "Edit")
    refute has_element?(view, "#task-schedule-form")

    view
    |> element("button", "Edit")
    |> render_click()

    assert has_element?(view, "button[type='submit']", "Update schedule")
    assert has_element?(view, "input[name='schedule[interval_value]'][value='30']")

    assert has_element?(
             view,
             "select[name='schedule[interval_unit]'] option[value='minutes'][selected]"
           )
  end

  test "task page displays a cron Schedule from the authoritative definition", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :task_schedule_definition, %{
      "cron" => "0 9 * * 1-5",
      "timezone" => "Asia/Shanghai"
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    assert render(view) =~ "Every weekday at 9 AM (Asia/Shanghai)"
    assert has_element?(view, "button", "Edit")
    refute has_element?(view, "#task-schedule-form")

    view
    |> element("button", "Edit")
    |> render_click()

    assert has_element?(view, "#task-schedule-form")
    assert has_element?(view, "input[name='schedule[cron]'][value='0 9 * * 1-5']")
    assert has_element?(view, "input[name='schedule[timezone]'][value='Asia/Shanghai']")
  end

  test "adding a Schedule to a legacy Task requires an explicit command", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :task_schedule_override, %{})

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    assert has_element?(view, "button", "Add schedule")
    refute has_element?(view, "#task-schedule-form")

    view
    |> element("button", "Add schedule")
    |> render_click()

    assert has_element?(view, "textarea[name='schedule[command]'][required]")

    view
    |> form("form[phx-change='validate_task_schedule']", schedule: %{mode: "interval"})
    |> render_change()

    view
    |> form("form[phx-submit='save_task_schedule']",
      schedule: %{
        mode: "interval",
        interval_value: "30",
        interval_unit: "minutes",
        command: "Inspect the legacy task."
      }
    )
    |> render_submit()

    assert render(view) =~ "Scheduled"
    refute has_element?(view, "#task-schedule-form")
  end

  test "task schedule previews a fixed-time Cron in human language", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    view
    |> element("button", "Edit")
    |> render_click()

    view
    |> form("form[phx-change='validate_task_schedule']", schedule: %{mode: "cron"})
    |> render_change()

    view
    |> form("form[phx-change='validate_task_schedule']",
      schedule: %{
        mode: "cron",
        cron: "30 18 * * 3",
        timezone: "Asia/Shanghai",
        command: "Inspect the task."
      }
    )
    |> render_change()

    assert render(view) =~ "Every Wednesday at 6:30 PM (Asia/Shanghai)"
  end

  test "project users cannot mutate Task Schedule through forged events", %{
    conn: conn,
    org: org,
    project: project
  } do
    user = user_fixture(email: "task-schedule-user@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status")

    assert render_click(view, "delete_task_schedule") =~ "Could not update the task schedule"
    assert render(view) =~ "Scheduled"
    refute has_element?(view, "button[phx-click='delete_task_schedule']", "Delete schedule")

    view
    |> element("button", "Edit")
    |> render_click()

    assert has_element?(view, "button[phx-click='delete_task_schedule']", "Delete schedule")

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "project_task_schedule.delete",
               result: "denied"
             )

    assert audit.actor_user_id == user.id
    assert audit.resource_type == "task_schedule"
    assert audit.resource_id == "task-dashboard-status"
    assert audit.reason_class == "forbidden"
    assert audit.metadata["surface"] == "task_schedule"
  end

  test "participant session activity renders durable session records", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    html = render_async(view)

    assert has_element?(view, "h1", "Session activity")
    assert has_element?(view, "#session-activity-timeline")
    assert has_element?(view, "#record-tool-tool-search h3", "gmail.search_threads")
    assert has_element?(view, "#record-tool-tool-search summary", "from:founder")
    assert has_element?(view, "#record-tool-tool-search details:not([open])")
    assert has_element?(view, "#record-tool-tool-search details > div", "3 threads")
    assert has_element?(view, "#record-1 h3", "Input")
    assert has_element?(view, "#record-reasoning-2 h3", "Thinking")
    assert has_element?(view, "#record-4 h3", "Agent")
    assert has_element?(view, "#record-5 h3", "Summary")
    assert has_element?(view, "#record-6 h3", "context.updated")
    assert html =~ "1.3 s"
    assert html =~ "Find the founder updates"
    assert html =~ "Search the connected mailbox first."
    refute html =~ "Private model reasoning"
    assert html =~ "Found 3 founder threads."
    assert html =~ "The mailbox search is complete."
    assert html =~ "Runtime context refreshed"
  end

  @tag :session_timestamps
  test "session activity renders mixed inbound milliseconds and runtime seconds", %{
    conn: conn,
    org: org,
    project: project
  } do
    # ConversationDelivery retains message milliseconds while internal runtime
    # events use seconds. These values came from a real-model Worker session.
    Application.put_env(:bridge_for_teams_web, :session_evidence_records, %{
      "runtime_kind" => "internal",
      "records" => [
        %{
          "id" => 1,
          "role" => "user",
          "content" => "Original task",
          "created_at" => 1_788_854_550_669
        },
        %{
          "id" => 2,
          "role" => "assistant",
          "content" => "Worker answer",
          "created_at" => 1_788_854_550
        },
        %{
          "id" => 3,
          "role" => "runtime",
          "content" => "Record with invalid time",
          "created_at" => 999_999_999_999_999_999
        }
      ]
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    assert has_element?(view, "#record-1", "Original task")
    assert has_element?(view, "#record-1", "08:02:30")
    assert has_element?(view, "#record-2", "Worker answer")
    assert has_element?(view, "#record-2", "08:02:30")
    assert has_element?(view, "#record-3", "Record with invalid time")
    assert has_element?(view, "#record-3", "Time unavailable")
  end

  @tag :session_task_context
  test "session review opens exact bounded Task messages beside the investigation", %{
    conn: conn,
    org: org,
    project: project
  } do
    install_task_review_fixture()
    install_session_evidence_fixture()
    Application.put_env(:bridge_for_teams_web, :task_snapshot_observer, self())

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    refute_received {:task_snapshot_read, _, _, _}
    refute render(view) =~ "TASK_ANSWER_END"

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    view |> element("button", "Show Task messages") |> render_click()

    assert_received {:task_snapshot_read, group_id, "task-dashboard-status", opts}
    assert group_id == project.salix_group_id
    assert Keyword.fetch!(opts, :limit) == 100
    assert Keyword.fetch!(opts, :tail) == 100
    refute_received {:task_snapshot_read, _, _, _}
    assert has_element?(view, "#session-task-messages", "TASK_ORIGINAL_REQUEST")
    assert has_element?(view, "#session-task-messages", "TASK_ANSWER_END")
    assert has_element?(view, "#session-task-messages", "delegator")
    assert has_element?(view, "#session-task-messages", "worker")
    assert has_element?(view, "#session-task-context", "not the full source thread")
    assert has_element?(view, "#session-tool-evidence-result", "FINAL_SOURCE_MARKER")

    download_path =
      "/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/messages/review-answer/attachments/1"

    assert has_element?(view, "#session-task-messages a[href='#{download_path}']", "Download")
    refute has_element?(view, "#session-task-messages a[href$='/attachments/0']")

    view |> element("button", "Hide Task messages") |> render_click()
    refute render(view) =~ "TASK_ANSWER_END"
    assert has_element?(view, "#session-tool-evidence-result", "FINAL_SOURCE_MARKER")

    messages = Application.fetch_env!(:bridge_for_teams_web, :conversation_live_messages)

    messages =
      put_in(messages, [Access.at(1), "content", Access.at(0), "text"], "NEW_TASK_ANSWER")

    Application.put_env(:bridge_for_teams_web, :conversation_live_messages, messages)

    render_click(view, "show_task_messages", %{
      "conversation_id" => "another-task",
      "project_id" => "another-project"
    })

    assert_received {:task_snapshot_read, ^group_id, "task-dashboard-status", _}
    assert has_element?(view, "#session-task-messages", "NEW_TASK_ANSWER")
    refute render(view) =~ "TASK_ANSWER_END"
  end

  @tag :session_task_context
  test "revocation clears Task and tool evidence and prevents another Task read", %{
    conn: conn,
    org: org,
    project: project
  } do
    install_task_review_fixture()
    install_session_evidence_fixture()
    Application.put_env(:bridge_for_teams_web, :task_snapshot_observer, self())
    reader = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, reader.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, reader.id, "user")

    {:ok, view, _html} =
      conn
      |> log_in_user(reader)
      |> live(
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    view |> element("button", "Show Task messages") |> render_click()
    assert_received {:task_snapshot_read, _, _, _}

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-task-messages", "TASK_ANSWER_END")
    :ok = Memberships.remove_project_member(project.id, reader.id)

    html = render_click(view, "show_task_messages", %{})
    refute_received {:task_snapshot_read, _, _, _}
    refute html =~ "TASK_ANSWER_END"
    refute html =~ "FINAL_SOURCE_MARKER"
    assert html =~ "Session activity unavailable"
  end

  @tag :session_task_context
  test "canonical human messages are not attributed to the reviewing user", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(
      :bridge_for_teams_web,
      :conversation_live_messages,
      for sender <- ["human-one", "human-two"] do
        %{
          "message_id" => sender,
          "actor_type" => "user",
          "role_label" => "user",
          "user_id" => sender,
          "content" => [%{"type" => "text", "text" => "Statement from #{sender}"}]
        }
      end
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    view |> element("button", "Show Task messages") |> render_click()
    assert has_element?(view, "#session-task-messages header", "User · human-one")
    assert has_element?(view, "#session-task-messages header", "User · human-two")
    refute has_element?(view, "#session-task-messages header", "You")
  end

  @tag :session_task_context
  test "a failed Task read stays explicit and leaves the loaded investigation usable", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :task_snapshot_error, :timeout)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    html = view |> element("button", "Show Task messages") |> render_click()
    assert html =~ "Task messages unavailable"
    assert has_element?(view, "#session-activity-timeline")
    refute has_element?(view, "#session-task-messages")
  end

  defp install_task_review_fixture do
    Application.put_env(:bridge_for_teams_web, :conversation_live_messages, [
      %{
        "message_id" => "review-command",
        "actor_type" => "agent",
        "role_label" => "delegator",
        "content" => [
          %{"type" => "text", "text" => "TASK_ORIGINAL_REQUEST: investigate the source."}
        ],
        "created_at" => 1_788_854_550_669
      },
      %{
        "message_id" => "review-answer",
        "actor_type" => "agent",
        "role_label" => "worker",
        "content" => [
          %{
            "type" => "text",
            "text" => String.duplicate("Evidence with uncertainty. ", 160) <> "TASK_ANSWER_END"
          },
          %{
            "type" => "file",
            "file_name" => "report.txt",
            "path" => "/report.txt",
            "blob_ref" => %{"size" => 10}
          }
        ],
        "created_at" => 1_788_854_560_669
      }
    ])
  end

  @tag :session_evidence
  test "tool details reveal stored input and asynchronous result without preview truncation", %{
    conn: conn,
    org: org,
    project: project
  } do
    install_session_evidence_fixture()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    html = render_async(view)
    assert has_element?(view, "#record-tool-evidence-call summary", "completed")
    refute html =~ "FINAL_SOURCE_MARKER"
    refute html =~ "INPUT_END_MARKER"
    refute html =~ "json-secret"

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-tool-evidence-input", "INPUT_END_MARKER")
    assert has_element?(view, "#record-tool-evidence-call details[open]")
    assert has_element?(view, "#session-tool-evidence-result", "FINAL_SOURCE_MARKER")
    assert has_element?(view, "#session-tool-evidence-result", "[REDACTED]")
    assert has_element?(view, "#session-tool-evidence", "Stored result page")
    assert has_element?(view, "#session-tool-evidence", "not the full tool result")
    refute render(view) =~ "json-secret"
    refute render(view) =~ "input-secret"
    refute render(view) =~ "Private model reasoning"
    refute has_element?(view, "#record-3")

    view
    |> element("#record-tool-second-call button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-tool-evidence-result", "SECOND_RESULT")
    assert has_element?(view, "#record-tool-second-call details[open]")
    refute render(view) =~ "FINAL_SOURCE_MARKER"
    refute render(view) =~ "INPUT_END_MARKER"
  end

  @tag :session_evidence
  @tag :session_failed_tool
  test "a durable async failure replaces the running result without exposing private diagnostics",
       %{
         conn: conn,
         org: org,
         project: project
       } do
    failure = %{
      "id" => 34,
      "role" => "runtime",
      "type" => "tool_call_failed",
      "source_tool_call_id" => "calendar-read",
      "diagnostic_visibility" => "model_only",
      "summary" => "async tool calendar.list_items failed for calendar-read",
      "source_refs" => %{"tool_name" => "calendar.list_items", "status" => "failed"},
      "content" =>
        Jason.encode!(%{
          "error" => true,
          "status" => "error",
          "result" => %{
            "content" => "PRIVATE_CALENDAR_DIAGNOSTIC",
            "diagnostic_visibility" => "model_only"
          }
        })
    }

    earlier = [
      %{
        "id" => 1,
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "calendar-read",
            "name" => "calendar.list_items",
            "args" => %{"calendar_id" => "unverified-id"}
          }
        ]
      },
      %{
        "id" => 2,
        "role" => "tool",
        "tool_call_id" => "calendar-read",
        "status" => "async_running",
        "content" => Jason.encode!(%{"status" => "async_running"})
      }
    ]

    Application.put_env(:bridge_for_teams_web, :session_evidence_records, %{
      "pages" => %{
        "latest" => %{
          "runtime_kind" => "internal",
          "records" => [failure],
          "has_more" => true,
          "next_before" => "before-calendar-failure"
        },
        "before-calendar-failure" => %{
          "runtime_kind" => "internal",
          "records" => earlier,
          "has_more" => false
        }
      }
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    assert has_element?(view, "#record-tool-calendar-read summary", "error")
    refute has_element?(view, "#record-34")

    view |> element("#session-activity-scroll") |> render_hook("load_older")
    render_async(view)
    assert has_element?(view, "#record-tool-calendar-read h3", "calendar.list_items")
    assert has_element?(view, "#record-tool-calendar-read summary", "error")
    refute has_element?(view, "#record-tool-calendar-read summary", "async_running")

    view
    |> element("#record-tool-calendar-read button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-tool-evidence-input", "unverified-id")

    assert has_element?(
             view,
             "#session-tool-evidence-result",
             "Private failure details are not shown"
           )

    refute render(view) =~ "PRIVATE_CALENDAR_DIAGNOSTIC"
  end

  @tag :session_evidence
  test "asynchronous evidence reconnects to its request on an older page", %{
    conn: conn,
    org: org,
    project: project
  } do
    install_session_evidence_fixture()
    records = Application.fetch_env!(:bridge_for_teams_web, :session_evidence_records)["records"]

    Application.put_env(:bridge_for_teams_web, :session_evidence_records, %{
      "pages" => %{
        "latest" => %{
          "runtime_kind" => "internal",
          "records" => Enum.drop(records, 2),
          "has_more" => true,
          "next_before" => "earlier-evidence"
        },
        "earlier-evidence" => %{
          "runtime_kind" => "internal",
          "records" => Enum.take(records, 2),
          "has_more" => false
        }
      }
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-tool-evidence-input", "Input is not present")
    assert has_element?(view, "#session-tool-evidence-result", "FINAL_SOURCE_MARKER")

    view |> element("#session-activity-scroll") |> render_hook("load_older")
    render_async(view)

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    assert has_element?(view, "#session-tool-evidence-input", "INPUT_END_MARKER")
    assert has_element?(view, "#session-tool-evidence-result", "FINAL_SOURCE_MARKER")
    assert has_element?(view, "#record-tool-evidence-call summary", "completed")
    refute has_element?(view, "#record-3")
  end

  @tag :session_evidence
  test "revoked project access cannot expand cached tool evidence", %{
    conn: conn,
    org: org,
    project: project
  } do
    install_session_evidence_fixture()
    install_task_review_fixture()
    user = user_fixture(email: "session-evidence-reader@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)

    view |> element("button", "Show Task messages") |> render_click()
    assert has_element?(view, "#session-task-messages", "TASK_ANSWER_END")

    view
    |> element("#record-tool-evidence-call button", "View stored input and result")
    |> render_click()

    assert render(view) =~ "FINAL_SOURCE_MARKER"
    :ok = Memberships.remove_project_member(project.id, user.id)

    html = render_click(view, "show_tool_evidence", %{"id" => "record-tool-second-call"})
    assert html =~ "Session activity unavailable"
    refute html =~ "FINAL_SOURCE_MARKER"
    refute html =~ "SECOND_RESULT"
    refute html =~ "TASK_ANSWER_END"
    refute has_element?(view, "#session-activity-timeline")
  end

  defp install_session_evidence_fixture do
    Application.put_env(:bridge_for_teams_web, :session_evidence_records, %{
      "runtime_kind" => "internal",
      "records" => [
        %{
          "id" => 1,
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => "evidence-call",
              "name" => "web.read_pages",
              "args" => %{
                "query" => "Source evidence",
                "instructions" => String.duplicate("Input context. ", 80) <> "INPUT_END_MARKER",
                "token" => "input-secret"
              }
            }
          ]
        },
        %{
          "id" => 2,
          "role" => "tool",
          "tool_call_id" => "evidence-call",
          "status" => "running",
          "content" => Jason.encode!(%{"status" => "running"})
        },
        %{
          "id" => 3,
          "role" => "runtime",
          "type" => "tool_call_completed",
          "source_tool_call_id" => "evidence-call",
          "summary" => "Read complete",
          "content" =>
            Jason.encode!(%{
              "status" => "completed",
              "error" => false,
              "source_refs" => %{"tool_name" => "web.read_pages"},
              "result_page" => %{
                "offset" => 0,
                "content_chars" => 4_000,
                "total_chars" => 8_000,
                "truncated" => true,
                "next_offset" => 4_000,
                "content" =>
                  Jason.encode!(%{
                    "text" => String.duplicate("Source evidence. ", 200) <> "FINAL_SOURCE_MARKER",
                    "token" => "json-secret"
                  })
              }
            })
        },
        %{
          "id" => 4,
          "role" => "assistant",
          "tool_calls" => [
            %{"id" => "second-call", "name" => "fs.read_file", "args" => %{"path" => "notes.md"}}
          ]
        },
        %{
          "id" => 5,
          "role" => "tool",
          "tool_call_id" => "second-call",
          "status" => "completed",
          "content" => "SECOND_RESULT"
        }
      ]
    })
  end

  test "participant session activity renders external runtime events", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :external_session_records, true)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    html = render_async(view)

    assert has_element?(view, "#session-activity-timeline")
    assert html =~ "mix test"
    assert html =~ "7 tests, 0 failures"
    assert html =~ "completed"
    refute html =~ "thread/status/changed"
    refute html =~ "agentMessage"

    view |> element("#record-command-1 button", "View stored input and result") |> render_click()
    assert has_element?(view, "#session-tool-evidence-input", "mix test")
    assert has_element?(view, "#session-tool-evidence-result", "7 tests, 0 failures")
  end

  test "participant session activity prepends earlier pages", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :paginated_session_records, true)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    render_async(view)
    assert has_element?(view, "#record-tool-tool-cross-page", "file contents")

    view |> element("#session-activity-scroll") |> render_hook("load_older")
    html = render_async(view)

    assert has_element?(view, "#record-tool-tool-cross-page", "fs.read_file")
    assert has_element?(view, "#record-tool-tool-cross-page", "/workspace/README.md")
    assert has_element?(view, "#record-tool-tool-cross-page", "file contents")
    assert has_element?(view, "#record-1", "Read the file")
    refute has_element?(view, "#record-2")
    assert html =~ ~s(data-has-more="false")
  end

  test "participant session activity can load past an empty latest page", %{
    conn: conn,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_web, :empty_first_session_records, true)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-status/session?#{%{participant: "worker"}}"
      )

    html = render_async(view)
    assert html =~ ~s(data-has-more="true")
    assert has_element?(view, "#session-activity-scroll[phx-hook='SessionTimeline']")
    refute html =~ "No session activity recorded"

    view |> element("#session-activity-scroll") |> render_hook("load_older")
    html = render_async(view)

    assert has_element?(view, "#record-1", "Visible on the earlier page")
    assert html =~ ~s(data-has-more="false")
  end

  test "session activity requires a traceable participant", %{
    conn: conn,
    org: org,
    project: project
  } do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               conn,
               ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-untitled/session?#{%{participant: "worker"}}"
             )

    assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-untitled"
  end

  test "untitled task page does not expose its Salix identifier", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/task-untitled")

    assert has_element?(view, "h1", "Untitled task")
    assert has_element?(view, "p", "Steer this task to get started.")
    refute has_element?(view, "p.font-mono", "task-untitled")
  end
end
