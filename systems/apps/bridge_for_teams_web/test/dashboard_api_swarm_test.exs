defmodule BridgeForTeamsWeb.DashboardAPISwarmTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Agent Swarm API behind the React Tasks and Settings pages and the
  Overview's Websites panel: paged tasks read from Salix, task creation with
  its places and models, the Scheduled view and schedule deletion, websites,
  rename, the default Task model, archive with its blockers, and the Access
  list. Swarm members create Tasks; other writes are for swarm admins, and a
  swarm member's is refused with a denied audit; someone outside the swarm
  gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

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

  # A Salix node of the release before has no default place to run Tasks.
  defmodule PlaceUnknownClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def put_group_task_place(_tenant, _group, _place), do: {:error, :unavailable}
  end

  # A Salix node of the release before has no worker-less Task create.
  defmodule PlacementUnknownClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    defdelegate get_group(group), to: BridgeForTeams.Salix.Erpc

    def create_placed_task_conversation(group_id, router_agent_id, attrs) do
      # What `:erpc.call` raises there, as `Erpc` answers it.
      {:error,
       {:error,
        {:exception, :undef,
         [
           {SalixIM.TaskPlacement, :create_task_conversation, [group_id, router_agent_id, attrs],
            []}
         ]}}}
      |> BridgeForTeams.Salix.Erpc.unknown_before_release(SalixIM.TaskPlacement)
    end
  end

  defmodule SchedulesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Cluster-wide schedules live in application env so deletes can change them.

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    defdelegate triage_worker_configuration(group_id, opts), to: BridgeForTeams.Salix.Erpc

    def list_schedules_for_owners(_agent_ids, _group_id),
      do: {:ok, SystemsRuntime.get_env(:bridge_for_teams_core, :test_schedules, [])}

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

    defp schedules, do: SystemsRuntime.get_env(:bridge_for_teams_core, :test_schedules, [])

    defp put_schedules(list),
      do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_schedules, list)
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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :agents_read)
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
    test "lists tasks from Salix, newest first", %{conn: conn, org: org, project: project} do
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

    test "creates a Task the swarm's Task agent runs, inside Salix by default; agent_id is ignored",
         %{conn: conn, org: org, project: project, user: user} do
      {:ok, worker} = create_agent(project, "helper")
      {:ok, router} = Agents.current_router(project)
      group_id = project.salix_group_id

      for title <- ["Launch support", ""] do
        assert %{"id" => id, "href" => href} =
                 conn
                 |> post(swarm_path(org, project, "/tasks"), %{
                   "title" => title,
                   "content" => "Draft the launch support plan.",
                   "agent_id" => worker.id
                 })
                 |> json_response(201)
                 |> data()

        assert href == "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{id}"

        assert {:ok, %{"kind" => "agent_task"} = conversation} =
                 SalixIM.Conversations.get_group_conversation(group_id, id)

        # A blank title leaves Salix to name the Task.
        if title != "", do: assert(conversation["title"] == title)

        assert {:ok, %{"participants" => participants}} =
                 SalixIM.Conversations.list_group_conversation_participants(group_id, id)

        by_role = Map.new(participants, &{&1["role_label"], &1["agent_id"]})
        assert by_role["delegator"] == router.salix_agent_id
        assert by_role["worker"] == SalixAgent.TaskAgent.id(group_id)

        # Inside Salix: the Task agent's Session takes the Task.
        refute participants
               |> Enum.find(&(&1["role_label"] == "worker"))
               |> SalixIM.TaskConversationInput.station_worker?()
      end

      audit =
        org.id
        |> Observability.list_audit_logs(action: "project_conversation.created")
        |> List.first()

      assert audit.actor_user_id == user.id
      assert audit.metadata["agent_id"] == router.id
      refute inspect(audit) =~ "Launch support"
    end

    test "lists the places and models a Task can choose, the swarm's defaults marked", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, _off} = Projects.set_vm_enabled(project, false)
      {:ok, project} = Projects.get_project(project.id)
      ready = "device-ready"

      connect_station(org, project, ready, %{
        "tasks" => 2,
        "task_models" => %{"codex" => ["gpt-5.5"]}
      })

      connect_station(org, project, "device-old-connector", %{})
      offline = "device-offline"
      offline_run = connect_station(org, project, offline, %{"tasks" => 2})
      {:ok, _} = SalixEnv.Registry.mark_disconnected(offline_run)

      {:ok, _result} =
        BridgeForTeams.Environments.reconcile_device_projection(projection_page_limit: 100)

      gpt = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
      {:ok, _org} = BridgeForTeams.Orgs.update_org(org, %{"allowed_models" => [gpt]})

      targets = fn ->
        conn |> get(swarm_path(org, project, "/tasks/targets")) |> json_response(200) |> data()
      end

      # Salix and the station that takes Tasks now; the Cloud VM is off.
      assert %{"places" => places, "models" => models} = targets.()

      assert [
               %{"id" => "salix", "kind" => "salix", "default" => true},
               %{
                 "id" => ^ready,
                 "kind" => "station",
                 "device_id" => ^ready,
                 "default" => false,
                 "models" => %{"codex" => ["gpt-5.5"], "claude" => []}
               }
             ] = places

      assert [%{"key" => "", "choice" => nil, "label" => default}, platform, offered] = models
      assert default =~ "Swarm default"
      assert platform["choice"] == %{"kind" => "platform", "tier" => "worker"}
      assert %{"key" => "catalog:gpt-5.5", "choice" => ^gpt} = offered

      # The swarm's default place is marked; the Cloud VM shows once it is on.
      {:ok, _on} = Projects.set_vm_enabled(project, true)
      {:ok, project} = Projects.get_project(project.id)

      {:ok, _place} =
        Projects.set_default_task_place(project, %{"kind" => "station", "device_id" => ready})

      assert %{"places" => places} = targets.()

      assert Enum.map(places, &{&1["id"], &1["default"]}) == [
               {"salix", false},
               {"cloud_vm", false},
               {ready, true}
             ]
    end

    test "Salix refuses a place or model the swarm cannot use, and nothing is made", %{
      conn: conn,
      org: org,
      project: project
    } do
      offline = "device-offline"
      offline_run = connect_station(org, project, offline, %{"tasks" => 2})
      {:ok, _} = SalixEnv.Registry.mark_disconnected(offline_run)
      gpt = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
      {:ok, _org} = BridgeForTeams.Orgs.update_org(org, %{"allowed_models" => [gpt]})

      create = fn extra, status ->
        conn
        |> post(
          swarm_path(org, project, "/tasks"),
          Map.merge(%{"title" => "Refused", "content" => "Do it."}, extra)
        )
        |> json_response(status)
      end

      for {extra, code} <- [
            {%{"runs_on" => %{"kind" => "cloud_vm"}}, "cloud_vm_disabled"},
            {%{
               "runs_on" => %{"kind" => "station", "device_id" => offline},
               "model" => %{"kind" => "runtime", "provider" => "codex"}
             }, "station_offline"},
            {%{
               "runs_on" => %{"kind" => "station", "device_id" => "device-elsewhere"},
               "model" => %{"kind" => "runtime", "provider" => "codex"}
             }, "invalid_place"},
            {%{"model" => %{"kind" => "catalog", "model" => "claude-opus-4-7"}}, "invalid_model"},
            {%{"runs_on" => "station"}, "invalid_place"},
            {%{"content" => " "}, "invalid_task"}
          ] do
        assert %{"error" => %{"code" => ^code}} = create.(extra, 422)
      end

      assert {:ok, %{"data" => []}} =
               SalixIM.Conversations.list_group_conversations(project.salix_group_id, limit: 10)
    end

    test "a Salix node of the release before cannot create it: 503, and the browser asks again",
         %{conn: conn, org: org, project: project} do
      with_client(PlacementUnknownClient)

      assert %{"error" => %{"code" => "runtime_unavailable"}} =
               conn
               |> post(swarm_path(org, project, "/tasks"), %{"content" => "Do it."})
               |> json_response(503)

      with_client(BridgeForTeams.Salix.Erpc)

      assert %{"id" => _id} =
               conn
               |> post(swarm_path(org, project, "/tasks"), %{"content" => "Do it."})
               |> json_response(201)
               |> data()
    end

    test "a swarm member creates a Task too, on any place of the swarm", %{
      org: org,
      project: project
    } do
      member_conn = member_conn(org, project)

      assert %{"places" => [%{"id" => "salix", "default" => true} | _others]} =
               member_conn
               |> get(swarm_path(org, project, "/tasks/targets"))
               |> json_response(200)
               |> data()

      assert %{"id" => id} =
               member_conn
               |> post(swarm_path(org, project, "/tasks"), %{
                 "title" => "From a member",
                 "content" => "Summarize the week.",
                 "runs_on" => %{"kind" => "salix"},
                 "model" => %{"kind" => "platform", "tier" => "worker"}
               })
               |> json_response(201)
               |> data()

      assert {:ok, %{"title" => "From a member"}} =
               SalixIM.Conversations.get_group_conversation(project.salix_group_id, id)

      assert %{"project" => %{"role" => "user"}} =
               member_conn
               |> get(swarm_path(org, project, "/tasks"))
               |> json_response(200)
               |> data()
    end
  end

  describe "schedules" do
    setup do
      on_exit(fn -> SystemsRuntime.delete_env(:bridge_for_teams_core, :test_schedules) end)
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

      assert [_still_there] = SystemsRuntime.get_env(:bridge_for_teams_core, :test_schedules)

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

    test "an admin sets the default place to run Tasks: Salix, the Cloud VM or a station", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      path = swarm_path(org, project, "/settings/task-place")

      # Unset: Tasks run inside Salix.
      assert %{
               "task_place" => %{
                 "status" => "ok",
                 "place" => %{"kind" => "salix"},
                 "label" => "Salix"
               }
             } =
               conn |> get(swarm_path(org, project, "/settings")) |> json_response(200) |> data()

      # The Cloud VM while the swarm's Cloud VM is on.
      {:ok, _} =
        SalixStore.CasRecord.update(
          SalixStore.Keys.ctl_group(project.salix_group_id),
          &Map.put(&1, "cloud_vm_enabled", true),
          create: false
        )

      assert %{"task_place" => %{"place" => %{"kind" => "cloud_vm"}, "label" => "The Cloud VM"}} =
               conn
               |> put(path, %{"place" => %{"kind" => "cloud_vm"}})
               |> json_response(200)
               |> data()

      assert {:ok, %{"kind" => "cloud_vm"}} = Projects.default_task_place(project)

      # A station the swarm does not have is refused and changes nothing.
      assert %{"error" => %{"code" => "invalid_place"}} =
               conn
               |> put(path, %{
                 "place" => %{"kind" => "station", "device_id" => "device-elsewhere"}
               })
               |> json_response(422)

      {:ok, _off} = Projects.set_vm_enabled(project, false)

      assert %{"error" => %{"code" => "cloud_vm_disabled"}} =
               conn |> put(path, %{"place" => %{"kind" => "cloud_vm"}}) |> json_response(422)

      assert {:ok, %{"kind" => "cloud_vm"}} = Projects.default_task_place(project)

      # A Salix node of the release before: nothing is stored, and saving again works.
      with_client(PlaceUnknownClient)

      assert %{"error" => %{"code" => "write_failed"}} =
               conn |> put(path, %{"place" => %{"kind" => "salix"}}) |> json_response(503)

      with_client(BridgeForTeams.Salix.Erpc)

      assert %{"task_place" => %{"place" => %{"kind" => "salix"}}} =
               conn
               |> put(path, %{"place" => %{"kind" => "salix"}})
               |> json_response(200)
               |> data()

      audits = Observability.list_audit_logs(org.id, action: "project.default_task_place_changed")

      assert Enum.sort(Enum.map(audits, & &1.redacted_diff["default_task_place"]["to"])) == [
               "cloud_vm",
               "salix"
             ]

      assert Enum.all?(audits, &(&1.actor_user_id == admin.id and &1.result == "ok"))
    end

    test "an admin sets the default Task model from the platform model and the org's models", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      platform = %{"kind" => "platform", "tier" => "worker"}
      gpt = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
      sol = %{"kind" => "catalog", "model" => "gpt-6.1-sol", "allow_paid" => false}
      {:ok, _org} = BridgeForTeams.Orgs.update_org(org, %{"allowed_models" => [gpt]})
      path = swarm_path(org, project, "/settings/task-model")

      # Unset: each Task runs the org's default Task model; that row clears a default.
      assert %{
               "task_model" => %{
                 "status" => "ok",
                 "key" => "",
                 "label" => "Organization default (" <> _,
                 "models" => rows
               }
             } =
               conn |> get(swarm_path(org, project, "/settings")) |> json_response(200) |> data()

      assert [
               %{"key" => "", "choice" => nil, "disabled" => false},
               %{"key" => "platform:worker", "choice" => ^platform, "disabled" => false},
               %{"key" => "catalog:gpt-5.5", "choice" => ^gpt, "disabled" => false}
             ] = rows

      assert %{"error" => %{"code" => "invalid_model"}} =
               conn |> put(path, %{"model" => sol}) |> json_response(422)

      assert %{
               "task_model" => %{
                 "key" => "platform:worker",
                 "models" => [unset, platform_row | _]
               }
             } =
               conn |> put(path, %{"model" => platform}) |> json_response(200) |> data()

      assert %{"key" => "", "choice" => nil, "disabled" => false} = unset
      assert platform_row["choice"] == platform

      assert %{"task_model" => %{"key" => "catalog:gpt-5.5", "label" => "GPT-5.5"}} =
               conn |> put(path, %{"model" => gpt}) |> json_response(200) |> data()

      assert {:ok, ^gpt} = Projects.default_task_model(project)

      # Clearing it gives each Task the org's default Task model again.
      assert %{"task_model" => %{"key" => "", "label" => "Organization default (" <> _}} =
               conn |> delete(path) |> json_response(200) |> data()

      assert {:ok, nil} = Projects.default_task_model(project)

      assert [_, _, _] =
               audits =
               Observability.list_audit_logs(org.id, action: "project.default_task_model_changed")

      assert Enum.all?(audits, &(&1.actor_user_id == admin.id and &1.result == "ok"))
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

      assert %{"project" => %{"role" => "user"}, "task_model" => %{"status" => "ok", "key" => ""}} =
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

      assert %{"error" => %{"message" => model_message}} =
               member_conn
               |> put(swarm_path(org, project, "/settings/task-model"), %{
                 "model" => %{"kind" => "platform", "tier" => "worker"}
               })
               |> json_response(403)

      assert model_message =~ "Only Agent Swarm admins can change the default Task model"

      assert %{"error" => %{"message" => place_message}} =
               member_conn
               |> put(swarm_path(org, project, "/settings/task-place"), %{
                 "place" => %{"kind" => "salix"}
               })
               |> json_response(403)

      assert place_message =~ "Only Agent Swarm admins can change the default place to run Tasks"
      assert {:ok, nil} = Projects.default_task_place(project)
      assert {:ok, nil} = Projects.default_task_model(project)

      assert %{"error" => %{"message" => ^model_message}} =
               member_conn
               |> delete(swarm_path(org, project, "/settings/task-model"))
               |> json_response(403)

      for {action, count} <- [
            {"project.renamed", 1},
            {"project.archived", 1},
            {"project.default_task_model_changed", 2},
            {"project.default_task_place_changed", 1}
          ] do
        audits = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert length(audits) == count
        assert Enum.all?(audits, &(&1.resource_id == project.id))
        assert Enum.all?(audits, &(&1.reason_class == "forbidden"))
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

  # A device of the swarm whose Comma station reports `capabilities`; answers
  # its connector run.
  defp connect_station(org, project, device_id, capabilities) do
    {:ok, _transport_id, record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> device_id,
          "name" => "Mac Studio"
        },
        transport_id: "transport-" <> device_id
      )

    run_id = record["connector_run_id"]
    {:ok, _} = SalixEnv.Registry.update_meta(run_id, &Map.put(&1, "capabilities", capabilities))
    refresh_device_projection(project.id, device_id, 20)
    run_id
  end

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} =
             BridgeForTeams.Environments.reconcile_device_projection(projection_page_limit: 100)

    unless BridgeForTeams.Repo.get_by(BridgeForTeams.Schema.ProjectDeviceProjection,
             project_id: project_id,
             device_id: device_id
           ),
           do: refresh_device_projection(project_id, device_id, attempts - 1)
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

  defp put_schedules(list),
    do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_schedules, list)

  defp with_client(client) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, client)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
    end)
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "swarm-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
