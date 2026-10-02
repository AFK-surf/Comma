defmodule BridgeForTeamsWeb.DashboardAPISwarmTest do
  @moduledoc """
  The Agent Swarm API behind the React Tasks and Settings pages and the
  Overview's Websites panel: paged tasks read from Salix, task creation, the
  Scheduled view and schedule deletion, websites, rename, archive with its
  blockers, and the Access list. Swarm admins write; a swarm member's write is
  refused with a denied audit; someone outside the swarm gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Memberships,
    Observability,
    ProjectIMConnects,
    Projects
  }

  alias BridgeForTeams.Salix.Reconciler

  defmodule SitesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_agent_sites(agent_id),
      do: {:ok, [%{"name" => "marketing", "url" => "https://marketing-#{agent_id}.example.test"}]}
  end

  defmodule SchedulesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Cluster-wide schedules live in application env so deletes can change them.

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    defdelegate triage_worker_configuration(group_id, opts), to: BridgeForTeams.Salix.Erpc

    def list_schedules_for_owners(_agent_ids, _group_id),
      do: {:ok, Application.get_env(:bridge_for_teams_core, :test_schedules, [])}

    def delete_schedule(id) do
      put_schedules(Enum.reject(schedules(), &(&1["id"] == id)))
      :ok
    end

    def update_task_schedule(_group_id, conversation_id, nil) do
      put_schedules(
        Enum.reject(schedules(), &(get_in(&1, ["payload", "conversation_id"]) == conversation_id))
      )

      {:ok, %{"conversation_id" => conversation_id, "schedule" => %{"schedule_id" => nil}}}
    end

    defp schedules, do: Application.get_env(:bridge_for_teams_core, :test_schedules, [])

    defp put_schedules(list),
      do: Application.put_env(:bridge_for_teams_core, :test_schedules, list)
  end

  defmodule UnavailableClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    defdelegate triage_worker_configuration(group_id, opts), to: BridgeForTeams.Salix.Erpc
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:error, :unavailable}
    def list_agent_sites(_agent_id), do: {:error, :unavailable}
    def list_group_conversations(_group_id, _opts), do: {:error, :unavailable}
  end

  defmodule LaterPageOutageClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Requests run in the test process, which hears whenever agents are read.

    def list_group_conversations(_group_id, _opts), do: {:error, :timeout}

    def page_group_agents(tenant_id, group_id, opts) do
      send(self(), :agents_read)
      BridgeForTeams.Salix.Erpc.page_group_agents(tenant_id, group_id, opts)
    end
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "tasks" do
    test "lists tasks from Salix, newest first, with the agents a task can use",
         %{conn: conn, org: org, project: project} do
      {:ok, helper} = create_agent(project, "helper")

      {:ok, titled} =
        create_conversation(project, %{
          "title" => "Incident triage",
          "kind" => "agent_task",
          "status" => "done",
          "schedule" => %{"schedule_id" => SalixStore.Ids.new_schedule_id(), "command" => "x"}
        })

      {:ok, untitled} = create_conversation(project, %{"title" => ""})

      data = conn |> get(swarm_path(org, project, "/tasks")) |> json_response(200) |> data()

      assert data["status"] == "ok"
      assert data["next_cursor"] == nil
      assert data["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}
      assert %{"status" => "ok", "items" => agents} = data["agents"]
      assert %{"id" => helper.id, "name" => "helper"} in agents

      tasks = Map.new(data["tasks"], &{&1["id"], &1})

      assert %{
               "title" => "Incident triage",
               "status" => "done",
               "kind" => "agent_task",
               "scheduled" => true,
               "href" => href
             } = tasks[titled["conversation_id"]]

      assert href ==
               "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{titled["conversation_id"]}"

      assert %{"title" => nil, "status" => "active", "scheduled" => false} =
               tasks[untitled["conversation_id"]]

      assert {:ok, _, 0} = DateTime.from_iso8601(tasks[untitled["conversation_id"]]["updated_at"])
    end

    test "pages 100 tasks at a time; later pages carry no agents", %{
      conn: conn,
      org: org,
      project: project
    } do
      for n <- 1..101, do: {:ok, _} = create_conversation(project, %{"title" => "Task #{n}"})

      first = conn |> get(swarm_path(org, project, "/tasks")) |> json_response(200) |> data()
      assert length(first["tasks"]) == 100
      assert is_binary(first["next_cursor"])

      second =
        conn
        |> get(swarm_path(org, project, "/tasks"), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> data()

      assert [last] = second["tasks"]
      assert second["next_cursor"] == nil
      refute Map.has_key?(second, "agents")
      refute last["id"] in Enum.map(first["tasks"], & &1["id"])
    end

    test "costs a fixed number of queries however many tasks there are", %{
      conn: conn,
      org: org,
      project: project
    } do
      small = query_count(conn, swarm_path(org, project, "/tasks"))
      for n <- 1..5, do: {:ok, _} = create_conversation(project, %{"title" => "Task #{n}"})
      assert query_count(conn, swarm_path(org, project, "/tasks")) == small
    end

    test "says so when Salix is unavailable", %{conn: conn, org: org, project: project} do
      with_client(UnavailableClient)

      assert %{"status" => "unavailable", "tasks" => []} =
               conn |> get(swarm_path(org, project, "/tasks")) |> json_response(200) |> data()
    end

    test "a stale cursor is refused; a later page during an outage is an error, not the end",
         %{conn: conn, org: org, project: project} do
      assert %{"error" => %{"code" => "invalid_cursor"}} =
               conn
               |> get(swarm_path(org, project, "/tasks"), %{"cursor" => "not-a-cursor"})
               |> json_response(422)

      with_client(LaterPageOutageClient)

      assert %{"error" => %{"code" => "runtime_unavailable"}} =
               conn
               |> get(swarm_path(org, project, "/tasks"), %{"cursor" => "later-page"})
               |> json_response(503)

      refute_received :agents_read

      # The first page still says the list is unavailable, with its agents.
      assert %{"status" => "unavailable", "agents" => %{}} =
               conn |> get(swarm_path(org, project, "/tasks")) |> json_response(200) |> data()

      assert_received :agents_read
    end

    test "creates a task for one of the swarm's agents, with a blank title too", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, agent} = create_agent(project, "helper")

      for title <- ["Launch support", ""] do
        assert %{"id" => id, "href" => href} =
                 conn
                 |> post(swarm_path(org, project, "/tasks"), %{
                   "title" => title,
                   "agent_id" => agent.id
                 })
                 |> json_response(201)
                 |> data()

        assert href == "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{id}"

        assert {:ok, conversation} =
                 SalixIM.Conversations.get_group_conversation(project.salix_group_id, id)

        assert conversation["title"] == title

        assert {:ok, %{"participants" => [participant]}} =
                 SalixIM.Conversations.list_group_conversation_participants(
                   project.salix_group_id,
                   id
                 )

        assert participant["actor_type"] == "agent"
        assert participant["agent_id"] == agent.salix_agent_id
      end

      audit =
        org.id
        |> Observability.list_audit_logs(action: "project_conversation.created")
        |> List.first()

      assert audit.actor_user_id == user.id
      assert audit.metadata["agent_id"] == agent.id
      refute inspect(audit) =~ "Launch support"
    end

    test "refuses an agent from outside the swarm", %{conn: conn, org: org, project: project} do
      assert %{"error" => %{"code" => "invalid_agent", "details" => %{"fields" => fields}}} =
               conn
               |> post(swarm_path(org, project, "/tasks"), %{"agent_id" => Ecto.UUID.generate()})
               |> json_response(422)

      assert Map.has_key?(fields, "agent_id")
    end

    test "a swarm member cannot create a task; the attempt is audited", %{
      org: org,
      project: project
    } do
      {:ok, agent} = create_agent(project, "helper")
      member_conn = member_conn(org, project)

      assert %{"error" => %{"code" => "forbidden", "message" => message}} =
               member_conn
               |> post(swarm_path(org, project, "/tasks"), %{
                 "title" => "forged secret topic",
                 "agent_id" => agent.id
               })
               |> json_response(403)

      assert message =~ "Only Agent Swarm admins can manage tasks"

      assert {:ok, %{"data" => []}} =
               SalixIM.Conversations.list_group_conversations(project.salix_group_id, limit: 10)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_conversation.created",
                 result: "denied"
               )

      assert audit.resource_type == "project_conversation"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "conversation"
      assert audit.metadata["agent_id_configured"] in [true, "true"]
      refute inspect(audit) =~ "forged secret topic"

      # The member still reads the list.
      assert %{"project" => %{"role" => "user"}} =
               member_conn
               |> get(swarm_path(org, project, "/tasks"))
               |> json_response(200)
               |> data()
    end
  end

  describe "schedules" do
    setup do
      on_exit(fn -> Application.delete_env(:bridge_for_teams_core, :test_schedules) end)
    end

    test "lists agent and task schedules with their recurrence, never another swarm's",
         %{conn: conn, org: org, project: project} do
      {:ok, agent} = create_agent(project, "scheduler")
      with_client(SchedulesClient)

      put_schedules([
        %{
          "id" => "sched-hourly",
          "agent_id" => agent.salix_agent_id,
          "prompt" => "daily standup digest",
          "interval_minutes" => 60,
          "created_at" => 1_700_000_000_000,
          "last_run" => 1_700_003_600_000
        },
        task_schedule(project),
        %{
          "id" => "sched-foreign",
          "agent_id" => "agent_someone_else",
          "prompt" => "not ours",
          "interval_minutes" => 5
        }
      ])

      data = conn |> get(swarm_path(org, project, "/schedules")) |> json_response(200) |> data()
      assert %{"status" => "ok", "truncated" => false} = data
      schedules = Map.new(data["schedules"], &{&1["id"], &1})
      refute Map.has_key?(schedules, "sched-foreign")

      assert %{
               "target" => "agent",
               "agent_name" => "scheduler",
               "prompt" => "daily standup digest",
               "recurrence" => "Every hour",
               "last_run_at" => "2023-11-14T23:13:20.000Z",
               "href" => agent_href
             } = schedules["sched-hourly"]

      assert agent_href == "/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}"

      assert %{
               "target" => "task",
               "prompt" => nil,
               "recurrence" => "Every Wednesday at 6:30 PM (Asia/Shanghai)",
               "last_run_at" => nil,
               "href" => task_href
             } = schedules["sched-task"]

      assert task_href == "/orgs/#{org.slug}/projects/#{project.id}/tasks/cnv1_task_schedule"
    end

    test "deletes an agent schedule and a task schedule", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, agent} = create_agent(project, "scheduler")
      with_client(SchedulesClient)

      put_schedules([
        %{"id" => "sched-drop", "agent_id" => agent.salix_agent_id, "prompt" => "weekly report"},
        task_schedule(project)
      ])

      assert %{"schedules" => [%{"id" => "sched-task"}]} =
               conn
               |> delete(swarm_path(org, project, "/schedules/sched-drop"))
               |> json_response(200)
               |> data()

      assert [audit] = Observability.list_audit_logs(org.id, action: "project_schedule.deleted")
      assert audit.actor_user_id == user.id
      assert audit.resource_id == "sched-drop"
      refute inspect(audit) =~ "weekly report"

      assert %{"schedules" => []} =
               conn
               |> delete(swarm_path(org, project, "/schedules/sched-task"))
               |> json_response(200)
               |> data()

      assert [task_audit] =
               Observability.list_audit_logs(org.id, action: "project_task_schedule.delete")

      assert task_audit.resource_id == "cnv1_task_schedule"

      assert %{"error" => %{"code" => "schedule_not_found"}} =
               conn
               |> delete(swarm_path(org, project, "/schedules/sched-drop"))
               |> json_response(404)
    end

    test "a swarm member cannot delete a schedule; the attempt is audited", %{
      org: org,
      project: project
    } do
      with_client(SchedulesClient)
      put_schedules([task_schedule(project)])

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn(org, project)
               |> delete(swarm_path(org, project, "/schedules/sched-task"))
               |> json_response(403)

      assert [_still_there] = Application.get_env(:bridge_for_teams_core, :test_schedules)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_schedule.deleted",
                 result: "denied"
               )

      assert audit.reason_class == "forbidden"
      assert audit.metadata["surface"] == "schedule"
      assert audit.metadata["schedule_id_configured"] in [true, "true"]
      refute inspect(audit) =~ "sched-task"
    end

    test "says so when Salix is unavailable", %{conn: conn, org: org, project: project} do
      with_client(UnavailableClient)

      assert %{"status" => "unavailable", "schedules" => []} =
               conn |> get(swarm_path(org, project, "/schedules")) |> json_response(200) |> data()
    end
  end

  describe "websites" do
    test "lists the sites the swarm's agents publish", %{conn: conn, org: org, project: project} do
      assert %{"status" => "ok", "items" => [], "total" => 0} =
               conn |> get(swarm_path(org, project, "/websites")) |> json_response(200) |> data()

      {:ok, agent} = create_agent(project, "publisher")
      with_client(SitesClient)
      BridgeForTeams.Sites.invalidate_project_sites_cache(project.id)

      data = conn |> get(swarm_path(org, project, "/websites")) |> json_response(200) |> data()
      assert data["total"] == length(data["items"])

      assert %{"name" => "marketing", "agent_name" => "publisher", "agent_href" => agent_href} =
               Enum.find(data["items"], &(&1["url"] =~ agent.salix_agent_id))

      assert agent_href == "/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}"
    end

    test "says so when Salix is unavailable", %{conn: conn, org: org, project: project} do
      {:ok, _agent} = create_agent(project, "publisher")
      with_client(UnavailableClient)
      BridgeForTeams.Sites.invalidate_project_sites_cache(project.id)

      assert %{"status" => "unavailable"} =
               conn |> get(swarm_path(org, project, "/websites")) |> json_response(200) |> data()
    end
  end

  describe "settings" do
    test "shows identity, runtime ids and the access list", %{
      conn: conn,
      org: org,
      project: project
    } do
      grantee = user_fixture(email: "grantee@example.com", name: "Grace")
      {:ok, _} = Memberships.put_project_member(project.id, grantee.id, "user")

      data = conn |> get(swarm_path(org, project, "/settings")) |> json_response(200) |> data()

      assert data["project"] == %{
               "id" => project.id,
               "name" => "Acme",
               "slug" => "acme",
               "status" => "active",
               "role" => "admin",
               "runtime_id" => project.salix_group_id
             }

      assert data["org_runtime_id"] == org.salix_tenant_id
      assert %{"truncated" => false, "members" => members} = data["access"]

      grantee_id = grantee.id

      assert %{"id" => ^grantee_id, "name" => "Grace", "email" => "grantee@example.com"} =
               Enum.find(members, &(&1["id"] == grantee_id))
    end

    test "costs a fixed number of queries however many grants there are", %{
      conn: conn,
      org: org,
      project: project
    } do
      small = query_count(conn, swarm_path(org, project, "/settings"))

      for _ <- 1..3 do
        {:ok, _} = Memberships.put_project_member(project.id, user_fixture().id, "user")
      end

      assert query_count(conn, swarm_path(org, project, "/settings")) == small
    end

    test "renames the swarm and keeps its slug", %{conn: conn, org: org, project: project} do
      assert %{"project" => %{"name" => "Renamed Swarm", "slug" => "acme"}} =
               conn
               |> patch(swarm_path(org, project, "/settings"), %{"name" => "  Renamed Swarm "})
               |> json_response(200)
               |> data()

      assert {:ok, %{name: "Renamed Swarm", slug: "acme"}} = Projects.get_project(project.id)

      assert %{"error" => %{"details" => %{"fields" => %{"name" => ["can't be blank"]}}}} =
               conn
               |> patch(swarm_path(org, project, "/settings"), %{"name" => "   "})
               |> json_response(422)
    end

    test "archiving waits until every IM connection is disabled", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, connect} =
        ProjectIMConnects.create_project_connect(org.id, project.id, "slack", %{
          app_name: "Comma",
          app_id: "A123",
          client_id: "cid",
          client_secret: "fake-client-secret",
          signing_secret: "fake-signing-secret"
        })

      assert %{"error" => %{"code" => "archive_blocked", "message" => message}} =
               conn |> post(swarm_path(org, project, "/archive")) |> json_response(409)

      assert message =~ "Disable every IM connection"
      assert {:ok, %{status: "active"}} = Projects.get_project(project.id)

      {:ok, _} =
        ProjectIMConnects.disable_project_connect(org.id, project.id, connect["connect_id"])

      assert %{"redirect" => redirect, "notice" => notice} =
               conn |> post(swarm_path(org, project, "/archive")) |> json_response(200) |> data()

      assert redirect == "/orgs/#{org.slug}/projects"
      assert notice =~ "archived"

      assert {:ok, %{status: "archived", archived_at: %DateTime{}}} =
               Projects.get_project(project.id)
    end

    test "archiving waits until every schedule is deleted", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_client(SchedulesClient)
      on_exit(fn -> Application.delete_env(:bridge_for_teams_core, :test_schedules) end)
      put_schedules([task_schedule(project)])

      assert %{"error" => %{"code" => "archive_blocked", "message" => message}} =
               conn |> post(swarm_path(org, project, "/archive")) |> json_response(409)

      assert message =~ "Scheduled view of Tasks"

      put_schedules([])
      assert conn |> post(swarm_path(org, project, "/archive")) |> json_response(200)
      assert {:ok, %{status: "archived"}} = Projects.get_project(project.id)
    end

    test "refuses to archive when Salix cannot confirm the swarm is quiet", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_client(UnavailableClient)

      assert %{"error" => %{"code" => "runtime_unavailable"}} =
               conn |> post(swarm_path(org, project, "/archive")) |> json_response(503)

      assert {:ok, %{status: "active"}} = Projects.get_project(project.id)
    end

    test "a swarm member reads Settings but cannot rename or archive", %{
      org: org,
      project: project
    } do
      member_conn = member_conn(org, project)

      assert %{"project" => %{"role" => "user"}} =
               member_conn
               |> get(swarm_path(org, project, "/settings"))
               |> json_response(200)
               |> data()

      assert %{"error" => %{"message" => rename_message}} =
               member_conn
               |> patch(swarm_path(org, project, "/settings"), %{"name" => "Forged"})
               |> json_response(403)

      assert rename_message =~ "Only Agent Swarm admins can rename"

      assert %{"error" => %{"message" => archive_message}} =
               member_conn |> post(swarm_path(org, project, "/archive")) |> json_response(403)

      assert archive_message =~ "Only Agent Swarm admins can archive"
      assert {:ok, %{name: "Acme", status: "active"}} = Projects.get_project(project.id)

      for action <- ["project.renamed", "project.archived"] do
        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.resource_id == project.id
        assert audit.reason_class == "forbidden"
      end
    end
  end

  describe "access" do
    test "grants, changes and removes swarm access with audits", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      assert %{"access" => %{"members" => members}} =
               conn
               |> post(swarm_path(org, project, "/access"), %{
                 "email" => " Member@Example.com ",
                 "role" => "user"
               })
               |> json_response(200)
               |> data()

      {:ok, member} = Accounts.get_user_by_email("member@example.com")
      assert Enum.any?(members, &(&1["id"] == member.id and &1["role"] == "user"))
      assert {:ok, "user"} = Memberships.project_role(project.id, member.id)

      assert %{"access" => %{"members" => members}} =
               conn
               |> patch(swarm_path(org, project, "/access/#{member.id}"), %{"role" => "admin"})
               |> json_response(200)
               |> data()

      assert Enum.any?(members, &(&1["id"] == member.id and &1["role"] == "admin"))

      conn |> delete(swarm_path(org, project, "/access/#{member.id}")) |> json_response(200)
      assert {:error, :not_found} = Memberships.project_role(project.id, member.id)

      for {action, diff} <- [
            {"project_member.granted", %{"from" => nil, "to" => "user"}},
            {"project_member.role_changed", %{"from" => "user", "to" => "admin"}},
            {"project_member.removed", %{"from" => "admin", "to" => nil}}
          ] do
        assert [audit] = Observability.list_audit_logs(org.id, action: action)
        assert audit.actor_user_id == admin.id
        assert audit.resource_id == member.id
        assert audit.redacted_diff["role"] == diff
      end
    end

    test "changing or removing someone without a grant is 404 and changes nothing", %{
      conn: conn,
      org: org,
      project: project,
      user: owner
    } do
      outsider = user_fixture()

      # The org owner is an admin through the org, not through a grant.
      for target <- [outsider.id, owner.id] do
        assert %{"error" => %{"code" => "member_not_found"}} =
                 conn
                 |> patch(swarm_path(org, project, "/access/#{target}"), %{"role" => "user"})
                 |> json_response(404)

        assert %{"error" => %{"code" => "member_not_found"}} =
                 conn
                 |> delete(swarm_path(org, project, "/access/#{target}"))
                 |> json_response(404)

        assert {:error, :not_found} = Memberships.project_grant(project.id, target)
      end

      assert {:error, :not_found} = Memberships.project_role(project.id, outsider.id)
      assert {:ok, "admin"} = Memberships.project_role(project.id, owner.id)

      for action <- ["project_member.role_changed", "project_member.removed"],
          do: assert([] == Observability.list_audit_logs(org.id, action: action))
    end

    test "a swarm admin who demotes themselves gets their new role back", %{
      org: org,
      project: project
    } do
      {conn, admin} = swarm_admin_conn(org, project)

      assert %{"project" => %{"role" => "user"}, "access" => %{"members" => members}} =
               conn
               |> patch(swarm_path(org, project, "/access/#{admin.id}"), %{"role" => "user"})
               |> json_response(200)
               |> data()

      assert Enum.any?(members, &(&1["id"] == admin.id and &1["role"] == "user"))
    end

    test "a swarm admin who removes themselves is sent to the swarms list", %{
      org: org,
      project: project
    } do
      {conn, admin} = swarm_admin_conn(org, project)

      assert %{"redirect" => redirect, "notice" => notice} =
               conn
               |> delete(swarm_path(org, project, "/access/#{admin.id}"))
               |> json_response(200)
               |> data()

      assert redirect == "/orgs/#{org.slug}/projects"
      assert notice == ~s(You no longer have access to Agent Swarm "Acme".)
      assert {:error, :not_found} = Memberships.project_role(project.id, admin.id)
    end

    test "pages the access list 100 grants at a time", %{conn: conn, org: org, project: project} do
      for _ <- 1..101 do
        {:ok, _} = Memberships.put_project_member(project.id, user_fixture().id, "user")
      end

      assert %{"access" => first} =
               conn |> get(swarm_path(org, project, "/settings")) |> json_response(200) |> data()

      assert %{"truncated" => true, "next_cursor" => "100"} = first
      assert length(first["members"]) == 100

      assert %{"members" => [last], "truncated" => false, "next_cursor" => nil} =
               conn
               |> get(swarm_path(org, project, "/access"), %{"cursor" => "100"})
               |> json_response(200)
               |> data()

      refute last["id"] in Enum.map(first["members"], & &1["id"])

      assert %{"error" => %{"code" => "invalid_cursor"}} =
               conn
               |> get(swarm_path(org, project, "/access"), %{"cursor" => "nope"})
               |> json_response(422)
    end

    test "checks the email and the role", %{conn: conn, org: org, project: project} do
      assert %{"error" => %{"code" => "invalid_email"}} =
               conn
               |> post(swarm_path(org, project, "/access"), %{"email" => " "})
               |> json_response(422)

      assert %{"error" => %{"code" => "invalid_role"}} =
               conn
               |> patch(swarm_path(org, project, "/access/#{Ecto.UUID.generate()}"), %{
                 "role" => "owner"
               })
               |> json_response(422)
    end

    test "a swarm member cannot change access; each attempt is audited", %{
      org: org,
      project: project,
      user: admin
    } do
      member_conn = member_conn(org, project)

      member_conn
      |> post(swarm_path(org, project, "/access"), %{
        "email" => "forged-access@example.com",
        "role" => "admin"
      })
      |> json_response(403)

      member_conn
      |> patch(swarm_path(org, project, "/access/#{admin.id}"), %{"role" => "admin"})
      |> json_response(403)

      member_conn |> delete(swarm_path(org, project, "/access/#{admin.id}")) |> json_response(403)

      assert {:error, :not_found} = Accounts.get_user_by_email("forged-access@example.com")

      assert [grant] =
               Observability.list_audit_logs(org.id,
                 action: "project_member.granted",
                 result: "denied"
               )

      assert is_nil(grant.resource_id)
      assert grant.metadata["attempted_email_configured"] in [true, "true"]
      assert grant.metadata["attempted_role"] == "admin"
      refute inspect(grant.metadata) =~ "forged-access"

      for action <- ["project_member.role_changed", "project_member.removed"] do
        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.resource_id == admin.id
        assert audit.metadata["surface"] == "project_access"
      end
    end
  end

  describe "visibility" do
    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      for page <- ["/tasks", "/schedules", "/websites", "/settings"] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 build_conn()
                 |> log_in_user(plain)
                 |> get(swarm_path(org, project, page))
                 |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn()
                 |> log_in_user(user_fixture())
                 |> get(swarm_path(org, project, page))
                 |> json_response(404)
      end

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn()
               |> log_in_user(plain)
               |> post(swarm_path(org, project, "/archive"))
               |> json_response(404)
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      conn = get(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn ->
        patch(conn, swarm_path(org, project, "/settings"), %{"name" => "No token"})
      end)

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> patch(swarm_path(org, project, "/settings"), %{"name" => "With token"})
               |> json_response(200)
    end

    test "the React dashboard serves the swarm pages and their retired addresses", %{
      conn: conn,
      org: org,
      project: project
    } do
      for page <- ~w(tasks schedules settings access websites) do
        assert html_response(get(conn, "/orgs/#{org.slug}/projects/#{project.id}/#{page}"), 200) =~
                 ~s(<div id="root">)
      end
    end
  end

  defp swarm_path(org, project, rest),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}#{rest}"

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    log_in_user(build_conn(), member)
  end

  # An org member who administers the swarm through an explicit grant only.
  defp swarm_admin_conn(org, project) do
    admin = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, admin.id, "admin")
    {log_in_user(build_conn(), admin), admin}
  end

  defp create_agent(project, name) do
    with {:ok, agent} <- Agents.create_agent(project.id, %{"name" => name, "role" => "worker"}) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  defp create_conversation(project, attrs) do
    SalixIM.ConversationServer.create_group_conversation(
      project.salix_group_id,
      Map.merge(
        %{"title" => "Task", "kind" => "user_chat", "status" => "active", "participants" => []},
        attrs
      )
    )
  end

  defp task_schedule(project) do
    %{
      "id" => "sched-task",
      "receiver" => "task",
      "payload" => %{
        "agent_group_id" => project.salix_group_id,
        "conversation_id" => "cnv1_task_schedule"
      },
      "cron" => "30 18 * * 3",
      "timezone" => "Asia/Shanghai",
      "created_at" => 1_700_000_000_000,
      "last_run" => nil
    }
  end

  defp put_schedules(list), do: Application.put_env(:bridge_for_teams_core, :test_schedules, list)

  defp with_client(client) do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "swarm-query-count-#{System.unique_integer([:positive])}"

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
