defmodule BridgeForTeamsWeb.DashboardAPISwarmTaskTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The task detail API behind the React task page: the thread read from Salix
  (sanitized Markdown, attachments, authors), polling newer and paging older
  messages, steering with its event and audit, review acceptance at the
  version the user saw, the task's own schedule with its preview, the
  participant list, and who may read or write. It replaces the tests of the
  retired `ConversationLive.Show` and `ConversationSessionLive.Show`.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Memberships, Observability, Projects}
  alias BridgeForTeams.Salix.Reconciler

  # A task with a schedule, two participants and an attachment-carrying Slack
  # message. Schedule writes and review acceptance change application env, so
  # a later read sees them.
  defmodule TaskClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    @task "task-dashboard-status"

    defp env(key, default \\ nil), do: SystemsRuntime.get_env(:bridge_for_teams_web, key, default)
    defp put_env(key, value), do: SystemsRuntime.put_env(:bridge_for_teams_web, key, value)

    def conversation do
      base = %{
        "conversation_id" => @task,
        "title" => "Worker task",
        "kind" => "agent_task",
        "status" => "active",
        "updated_at" => 1_780_000_100_000,
        "schedule" => %{
          "schedule_id" => "schedule-task-dashboard-status",
          "command" => "Inspect the task."
        }
      }

      base =
        case env(:task_schedule_override) do
          :deleted -> put_in(base, ["schedule", "schedule_id"], nil)
          schedule when is_map(schedule) -> Map.put(base, "schedule", schedule)
          _ -> base
        end

      Map.merge(base, env(:task_workflow_override, %{}))
    end

    def get_group_conversation(_group_id, @task), do: {:ok, conversation()}

    def get_group_conversation(_group_id, "task-untitled"),
      do: {:ok, %{"conversation_id" => "task-untitled", "kind" => "work_session"}}

    def get_group_conversation(_group_id, _id), do: {:error, :not_found}

    def get_group_conversation_with_messages(group_id, id, opts) do
      case env(:task_snapshot_error) do
        nil ->
          with {:ok, conversation} <- get_group_conversation(group_id, id) do
            {:ok,
             %{
               "conversation" => conversation,
               "messages" => if(id == @task, do: messages(), else: [])
             }}
          end

        reason ->
          {:error, reason}
      end
      |> tap(fn _ ->
        if pid = env(:task_observer), do: SystemsRuntime.Proc.send(pid, {:snapshot, opts})
      end)
    end

    def list_group_conversation_participants(_group_id, id, _opts) do
      if pid = env(:task_observer), do: SystemsRuntime.Proc.send(pid, :participants_read)

      participants =
        if id == @task,
          do: [
            %{
              "participant_id" => "worker",
              "actor_type" => "agent",
              "agent_id" => env(:status_agent_id),
              "role_label" => "worker",
              "payload" => %{"session_id" => "im-task-dashboard-status"}
            },
            %{
              "participant_id" => "slack:connect-status:C-status:100.000",
              "actor_type" => "provider",
              "provider" => "slack",
              "role_label" => "slack_thread",
              "user_id" => "U0STATUS1",
              "display_name" => "Dana Ops",
              "payload" => %{
                "thread_url" =>
                  "https://app.slack.com/client/T-status/C-status/thread/C-status-100.000"
              }
            },
            %{
              "participant_id" => "slack:connect-status:C-status:200.000",
              "actor_type" => "provider",
              "provider" => "slack",
              "role_label" => "slack_thread",
              "payload" => %{"thread_url" => "javascript:alert(1)"}
            }
          ],
          else: []

      {:ok, %{"conversation_id" => id, "participants" => participants}}
    end

    defp messages do
      env(:task_messages, [
        %{
          "message_id" => "slack-msg-1",
          "seq" => 1,
          "actor_type" => "provider_user",
          "provider" => "slack",
          "user_id" => "U0STATUS1",
          "content" => [
            %{"type" => "text", "text" => "please handle this https://example.test/spec"},
            %{
              "type" => "image",
              "file_ref" => %{"environment_id" => "vfs", "path" => "/slack/attachments/spec.png"},
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
      ])
    end

    def get_schedule("schedule-task-dashboard-status") do
      case env(:task_schedule_error) do
        nil ->
          {:ok,
           Map.merge(
             %{
               "id" => "schedule-task-dashboard-status",
               "receiver" => "task",
               "payload" => %{
                 "agent_group_id" => env(:status_group_id),
                 "conversation_id" => @task
               }
             },
             env(:task_schedule_definition, %{"interval_minutes" => 60})
           )}

        reason ->
          {:error, reason}
      end
    end

    def get_schedule(_id), do: {:error, :not_found}

    def update_task_schedule(_group_id, @task, attrs) when is_map(attrs) do
      with nil <- env(:task_schedule_write_error) do
        save_task_schedule(attrs)
      else
        reason -> {:error, reason}
      end
    end

    def update_task_schedule(_group_id, @task, nil) do
      put_env(:task_schedule_override, :deleted)
      {:ok, conversation()}
    end

    defp save_task_schedule(attrs) do
      put_env(:task_schedule_definition, Map.take(attrs, ~w(interval_minutes cron timezone)))

      put_env(:task_schedule_override, %{
        "schedule_id" => "schedule-task-dashboard-status",
        "command" => attrs["command"]
      })

      {:ok, conversation()}
    end

    def accept_task_review(_group_id, @task, version) do
      case env(:task_review_error) do
        nil -> accept_current(conversation(), version)
        reason -> {:error, reason}
      end
    end

    defp accept_current(current, version) do
      if current["status"] == "ready_for_review" and current["updated_at"] == version do
        put_env(:task_workflow_override, %{"status" => "completed", "updated_at" => version + 1})
        {:ok, conversation()}
      else
        {:error, {:conflict, "Task review changed"}}
      end
    end
  end

  @task_env ~w(status_agent_id status_group_id task_schedule_override task_workflow_override
               task_snapshot_error task_observer task_messages task_schedule_error
               task_schedule_definition task_schedule_write_error task_review_error)a

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    on_exit(fn -> Enum.each(@task_env, &SystemsRuntime.delete_env(:bridge_for_teams_web, &1)) end)
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "thread" do
    test "renders sanitized Markdown, oldest first, and steers the task with an event and audit",
         %{conn: conn, org: org, project: project, user: user} do
      {:ok, agent} = create_agent(project, "helper")

      {:ok, conversation} =
        SalixIM.ConversationInput.create_group_conversation(project.salix_group_id, %{
          "title" => "Agent chat",
          "kind" => "user_chat",
          "status" => "active",
          "participants" => [
            user_participant(user),
            %{
              "actor_type" => "agent",
              "agent_id" => agent.salix_agent_id,
              "agent_name" => "helper",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"}
            }
          ]
        })

      id = conversation["conversation_id"]

      append_user(project, id, "dash-1", "Hi **there**\n\n- one", 1_700_000_000_500)

      {:ok, _} =
        SalixIM.ConversationServer.append_group_conversation_agent_message(
          project.salix_group_id,
          id,
          agent.salix_agent_id,
          %{
            "client_request_id" => "m-1",
            "kind" => "message",
            "agent_name" => "helper",
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  "How can `I` help?\n\n[Docs](https://example.com)\n\n<script>alert('x')</script>"
              }
            ],
            "created_at" => 1_700_000_001
          }
        )

      page = conn |> get(task_path(org, project, id)) |> json_response(200) |> data()

      assert page["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}

      assert %{"title" => "Agent chat", "status" => "active", "scheduled" => false} =
               page["task"]

      assert page["has_older"] == false
      assert [first, second] = page["messages"]
      assert %{"author" => "You", "from_person" => true} = first
      assert first["created_at"] == "2023-11-14T22:13:20.500Z"
      assert [%{"type" => "text", "html" => html}] = first["blocks"]
      assert html =~ "<strong>there</strong>"
      assert html =~ "<li>one</li>"

      assert %{"author" => "helper", "from_person" => false} = second
      assert [%{"html" => html}] = second["blocks"]
      assert html =~ "How can <code>I</code> help?"
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
      refute html =~ "<script>"
      refute html =~ "alert("

      assert %{"message_id" => message_id} =
               conn
               |> post(task_path(org, project, id, "/messages"), %{
                 "text" => "Please summarize the deployment."
               })
               |> json_response(201)
               |> data()

      assert {:ok, messages} =
               SalixIM.Conversations.list_group_conversation_messages(
                 project.salix_group_id,
                 id,
                 limit: 100
               )

      assert %{"actor_type" => "provider_user", "provider" => "bft", "user_id" => user_id} =
               Enum.find(messages, &(&1["message_id"] == message_id))

      assert user_id == user.id

      # The poll from the last message the page holds returns the new one,
      # written by the dashboard user without a provider prefix.
      polled =
        conn
        |> get(task_path(org, project, id, "/messages?after=#{second["id"]}"))
        |> json_response(200)
        |> data()

      assert [%{"id" => ^message_id, "from_person" => true} = sent] = polled["messages"]
      assert sent["author"] == (user.name || user.email)
      assert polled["has_more"] == false
      assert polled["task"]["id"] == id

      [event] =
        Observability.list_events(org.id,
          domain: "conversation",
          event_type: "conversation.message.sent"
        )

      assert event.status == "ok"
      assert event.actor_user_id == user.id
      assert event.resource_id == id
      refute inspect(event) =~ "Please summarize the deployment."

      [audit] =
        Observability.list_audit_logs(org.id,
          action: "project_conversation.message_sent",
          result: "ok"
        )

      assert audit.actor_user_id == user.id
      assert audit.request_id == event.correlation_id
      refute inspect(audit) =~ "Please summarize the deployment."
    end

    test "a retried send with the same request id appends one message; a blank one is refused",
         %{conn: conn, org: org, project: project} do
      {:ok, conversation} = create_conversation(project, %{"title" => "Retry"})
      id = conversation["conversation_id"]
      request_id = SystemsRuntime.Proc.uuid()
      body = %{"text" => "Ship it.", "request_id" => request_id}

      first = conn |> post(task_path(org, project, id, "/messages"), body) |> json_response(201)
      again = conn |> post(task_path(org, project, id, "/messages"), body) |> json_response(201)
      assert data(first)["message_id"] == data(again)["message_id"]

      assert {:ok, [_one]} =
               SalixIM.Conversations.list_group_conversation_messages(
                 project.salix_group_id,
                 id,
                 limit: 100
               )

      assert %{"error" => %{"code" => "message_required", "details" => details}} =
               conn
               |> post(task_path(org, project, id, "/messages"), %{"text" => "   "})
               |> json_response(422)

      assert %{"fields" => %{"text" => [_message]}} = details
    end

    test "adds one BFT participant before sending to a provider-backed task, and lists participants",
         %{conn: conn, org: org, project: project, user: user} do
      {:ok, worker} = create_agent(project, "slack-worker")

      {:ok, conversation} =
        SalixIM.ConversationInput.create_group_conversation(project.salix_group_id, %{
          "title" => "Slack direct task",
          "kind" => "agent_task",
          "status" => "active",
          "participants" => [
            %{
              "actor_type" => "provider",
              "provider" => "slack",
              "role_label" => "slack_thread",
              "payload" => %{
                "connect_id" => "sl-worker",
                "channel_id" => "C1",
                "thread_ts" => "1"
              }
            },
            %{
              "actor_type" => "agent",
              "agent_id" => worker.salix_agent_id,
              "agent_name" => "slack-worker",
              "role_label" => "worker"
            }
          ],
          "messages" => []
        })

      id = conversation["conversation_id"]

      page = conn |> get(task_path(org, project, id)) |> json_response(200) |> data()
      labels = Map.new(page["participants"], &{&1["label"], &1})

      assert %{"role_label" => "worker", "agent_href" => agent_href} = labels["slack-worker"]
      assert agent_href == "/orgs/#{org.slug}/projects/#{project.id}/agents/#{worker.id}"
      assert %{"agent_href" => nil, "thread_url" => nil} = labels["slack · slack_thread"]
      # A session id is an internal runtime handle, never shown.
      refute inspect(page) =~ "ses1_"

      for text <- ["Investigate the failed deploy.", "Send me the result."] do
        conn
        |> post(task_path(org, project, id, "/messages"), %{"text" => text})
        |> json_response(201)
      end

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 id
               )

      assert [bft] =
               Enum.filter(
                 participants,
                 &(&1["actor_type"] == "provider" and &1["provider"] == "bft")
               )

      assert {:ok, messages} =
               SalixIM.Conversations.list_group_conversation_messages(
                 project.salix_group_id,
                 id,
                 limit: 100
               )

      assert Enum.map(messages, &{&1["participant_id"], &1["user_id"], &1["content"]}) == [
               {bft["participant_id"], user.id,
                [%{"type" => "text", "text" => "Investigate the failed deploy."}]},
               {bft["participant_id"], user.id,
                [%{"type" => "text", "text" => "Send me the result."}]}
             ]
    end

    test "pages older messages with `before` and polls newer ones with `after`",
         %{conn: conn, org: org, project: project} do
      {:ok, conversation} = create_conversation(project, %{"title" => "Long"})
      id = conversation["conversation_id"]
      for n <- 1..60, do: append_user(project, id, "long-#{n}", "Message #{n}", 1_700_000_000 + n)

      page = conn |> get(task_path(org, project, id)) |> json_response(200) |> data()
      assert length(page["messages"]) == 50
      assert page["has_older"] == true
      assert text_of(hd(page["messages"])) =~ "Message 11"
      assert text_of(List.last(page["messages"])) =~ "Message 60"

      older =
        conn
        |> get(task_path(org, project, id, "/messages?before=#{hd(page["messages"])["id"]}"))
        |> json_response(200)
        |> data()

      assert Enum.map(older["messages"], &text_of/1) ==
               Enum.map(1..10, &"<p>Message #{&1}</p>")

      assert older["has_more"] == false

      last = List.last(page["messages"])["id"]

      assert %{"messages" => [], "has_more" => false} =
               conn
               |> get(task_path(org, project, id, "/messages?after=#{last}"))
               |> json_response(200)
               |> data()

      append_user(project, id, "long-61", "Message 61", 1_700_000_061)

      assert %{"messages" => [newer]} =
               conn
               |> get(task_path(org, project, id, "/messages?after=#{last}"))
               |> json_response(200)
               |> data()

      assert text_of(newer) =~ "Message 61"

      assert %{"error" => %{"code" => "invalid_cursor"}} =
               conn
               |> get(task_path(org, project, id, "/messages?before=msg1_missing"))
               |> json_response(422)
    end

    test "a page costs the same queries however long the task is",
         %{conn: conn, org: org, project: project} do
      {:ok, conversation} = create_conversation(project, %{"title" => "Counted"})
      id = conversation["conversation_id"]
      append_user(project, id, "count-1", "One", 1_700_000_001)

      [%{"id" => first}] =
        conn
        |> get(task_path(org, project, id))
        |> json_response(200)
        |> data()
        |> Map.fetch!("messages")

      poll_path = task_path(org, project, id, "/messages?after=#{first}")
      small = query_count(conn, task_path(org, project, id))
      poll = query_count(conn, poll_path)

      for n <- 2..20, do: append_user(project, id, "count-#{n}", "More #{n}", 1_700_000_000 + n)

      assert query_count(conn, task_path(org, project, id)) == small
      assert query_count(conn, poll_path) == poll
    end
  end

  describe "participants and schedule" do
    test "lists participants with agent links and only http(s) thread links; no session ids",
         %{conn: conn, org: org, project: project} do
      %{agent: agent} = use_task_client(project)

      page =
        conn
        |> get(task_path(org, project, "task-dashboard-status"))
        |> json_response(200)
        |> data()

      assert [worker, slack, unsafe] = page["participants"]

      assert worker == %{
               "id" => "worker",
               "label" => "status-worker",
               "role_label" => "worker",
               "agent_href" => "/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}",
               "thread_url" => nil
             }

      assert %{"label" => "Dana Ops", "role_label" => "slack_thread"} = slack

      assert slack["thread_url"] ==
               "https://app.slack.com/client/T-status/C-status/thread/C-status-100.000"

      assert %{"label" => "slack · slack_thread", "thread_url" => nil} = unsafe
      refute inspect(page) =~ "im-task-dashboard-status"

      assert %{"scheduled" => true, "schedulable" => true, "review_version" => nil} =
               page["task"]

      assert page["schedule"] == %{
               "status" => "ok",
               "recurrence" => "Every hour",
               "command" => "Inspect the task.",
               "form" => %{
                 "mode" => "interval",
                 "interval_value" => "1",
                 "interval_unit" => "hours",
                 "cron" => "",
                 "timezone" => "UTC",
                 "command" => "Inspect the task."
               }
             }
    end

    test "manages the task's schedule in place", %{conn: conn, org: org, project: project} do
      use_task_client(project)
      path = task_path(org, project, "task-dashboard-status", "/schedule")

      assert %{"task" => %{"scheduled" => false}, "schedule" => %{"status" => "none"}} =
               conn |> delete(path) |> json_response(200) |> data()

      added =
        conn
        |> put(path, %{
          "mode" => "interval",
          "interval_value" => "30",
          "interval_unit" => "minutes",
          "command" => "Inspect the task."
        })
        |> json_response(200)
        |> data()

      assert %{"task" => %{"scheduled" => true}, "schedule" => schedule} = added
      assert schedule["recurrence"] == "Every 30 minutes"

      assert %{"mode" => "interval", "interval_value" => "30", "interval_unit" => "minutes"} =
               schedule["form"]

      changed =
        conn
        |> put(path, %{
          "mode" => "cron",
          "cron" => "0 9 * * 1-5",
          "timezone" => "Asia/Shanghai",
          "command" => "Inspect the task."
        })
        |> json_response(200)
        |> data()

      assert changed["schedule"]["recurrence"] == "Every weekday at 9 AM (Asia/Shanghai)"

      assert %{"mode" => "cron", "cron" => "0 9 * * 1-5", "timezone" => "Asia/Shanghai"} =
               changed["schedule"]["form"]

      assert [_put, _put2] =
               Observability.list_audit_logs(org.id, action: "project_task_schedule.put")
    end

    test "a swarm member cannot change the schedule; the attempt is audited",
         %{org: org, project: project} do
      use_task_client(project)
      {conn, member} = member_conn(org, project)
      path = task_path(org, project, "task-dashboard-status", "/schedule")

      assert %{"project" => %{"role" => "user"}, "task" => %{"scheduled" => true}} =
               conn
               |> get(task_path(org, project, "task-dashboard-status"))
               |> json_response(200)
               |> data()

      assert %{"error" => %{"code" => "forbidden"}} = conn |> delete(path) |> json_response(403)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_task_schedule.delete",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
      assert audit.resource_id == "task-dashboard-status"
      assert audit.metadata["surface"] == "task_schedule"

      assert %{"task" => %{"scheduled" => true}} =
               conn
               |> get(task_path(org, project, "task-dashboard-status"))
               |> json_response(200)
               |> data()
    end
  end

  describe "review" do
    test "marks a task complete only at the version the user reviewed",
         %{org: org, project: project} do
      use_task_client(project)
      # Any swarm member may accept, as on the LiveView page.
      {conn, _member} = member_conn(org, project)

      SystemsRuntime.put_env(:bridge_for_teams_web, :task_schedule_override, :deleted)

      SystemsRuntime.put_env(:bridge_for_teams_web, :task_workflow_override, %{
        "status" => "ready_for_review",
        "updated_at" => 1_780_000_200_000
      })

      assert %{"task" => %{"review_version" => 1_780_000_200_000, "terminal" => false}} =
               conn
               |> get(task_path(org, project, "task-dashboard-status"))
               |> json_response(200)
               |> data()

      path = task_path(org, project, "task-dashboard-status", "/review")

      assert %{"error" => %{"code" => "review_changed"}} =
               conn |> post(path, %{"review_version" => 1}) |> json_response(409)

      assert %{"task" => %{"status" => "completed", "terminal" => true, "review_version" => nil}} =
               conn
               |> post(path, %{"review_version" => 1_780_000_200_000})
               |> json_response(200)
               |> data()
    end
  end

  describe "visibility" do
    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      {:ok, conversation} = create_conversation(project, %{"title" => "Private"})
      id = conversation["conversation_id"]
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      for path <- [task_path(org, project, id), task_path(org, project, id, "/messages")] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 build_conn() |> log_in_user(plain) |> get(path) |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn() |> log_in_user(user_fixture()) |> get(path) |> json_response(404)
      end

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn()
               |> log_in_user(plain)
               |> post(task_path(org, project, id, "/messages"), %{"text" => "Hi"})
               |> json_response(404)
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      {:ok, conversation} = create_conversation(project, %{"title" => "Guarded"})
      id = conversation["conversation_id"]
      conn = get(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{id}")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn ->
        post(conn, task_path(org, project, id, "/messages"), %{"text" => "No token"})
      end)

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(task_path(org, project, id, "/messages"), %{"text" => "With token"})
               |> json_response(201)
    end
  end

  defp task_path(org, project, task, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/tasks/#{task}#{rest}"

  defp data(%{"data" => data}), do: data

  defp text_of(%{"blocks" => [%{"html" => html} | _]}), do: html

  defp use_task_client(project) do
    {:ok, agent} = create_agent(project, "status-worker")
    SystemsRuntime.put_env(:bridge_for_teams_web, :status_agent_id, agent.salix_agent_id)
    SystemsRuntime.put_env(:bridge_for_teams_web, :status_group_id, project.salix_group_id)
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, TaskClient)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    %{agent: agent}
  end

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp create_agent(project, name) do
    with {:ok, agent} <-
           BridgeForTeams.TestSupport.LegacyWorker.create(project.id, %{
             "name" => name,
             "role" => "worker"
           }) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  # The test user takes part, so `append_user/5` can write as that user.
  defp create_conversation(project, attrs) do
    SalixIM.ConversationInput.create_group_conversation(
      project.salix_group_id,
      Map.merge(
        %{
          "title" => "Task",
          "kind" => "user_chat",
          "status" => "active",
          "participants" => [user_participant(nil)]
        },
        attrs
      )
    )
  end

  @participant_user "usr_task_test"

  defp user_participant(user) do
    %{
      "actor_type" => "user",
      "user_id" => if(user, do: user.id, else: @participant_user),
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"}
    }
  end

  defp append_user(project, id, request_id, text, created_at) do
    {:ok, _} =
      SalixIM.ConversationServer.append_group_conversation_message(project.salix_group_id, id, %{
        "client_request_id" => request_id,
        "kind" => "message",
        "actor_type" => "user",
        "content" => [%{"type" => "text", "text" => text}],
        "created_at" => created_at
      })
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "task-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
