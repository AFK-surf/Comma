defmodule BridgeForTeams.SchedulesTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Observability, Orgs, Projects, Schedules}

  # Stub Salix client driven by application env: `:test_schedules` holds the
  # cluster-wide list result, `:test_deleted` collects ids passed to delete,
  # `:test_created` / `:test_updates` collect create/update args. Create echoes
  # the definition back like the real store; update merges into the scripted
  # list entry (CAS-merge semantics) unless `:test_update_result` overrides.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    def list_schedules_for_owners(agent_ids, group_id) do
      SystemsRuntime.put_env(:bridge_for_teams_core, :test_owner_query, {agent_ids, group_id})
      SystemsRuntime.get_env(:bridge_for_teams_core, :test_schedules, {:ok, []})
    end

    def delete_schedule(id) do
      ids = SystemsRuntime.get_env(:bridge_for_teams_core, :test_deleted, [])
      SystemsRuntime.put_env(:bridge_for_teams_core, :test_deleted, [id | ids])
      :ok
    end

    def create_schedule(attrs) do
      created = SystemsRuntime.get_env(:bridge_for_teams_core, :test_created, [])
      SystemsRuntime.put_env(:bridge_for_teams_core, :test_created, [attrs | created])

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :test_create_result,
        {:ok, Map.merge(attrs, %{"created_at" => 1_700_000_000_000, "last_run" => nil})}
      )
    end

    def update_schedule(id, changes) do
      updates = SystemsRuntime.get_env(:bridge_for_teams_core, :test_updates, [])
      SystemsRuntime.put_env(:bridge_for_teams_core, :test_updates, [{id, changes} | updates])

      case SystemsRuntime.get_env(:bridge_for_teams_core, :test_update_result) do
        nil ->
          {:ok, schedules} =
            SystemsRuntime.get_env(:bridge_for_teams_core, :test_schedules, {:ok, []})

          case Enum.find(schedules, &(&1["id"] == id)) do
            nil -> {:error, :not_found}
            current -> {:ok, current |> Map.merge(changes) |> Map.put("id", id)}
          end

        result ->
          result
      end
    end
  end

  defmodule UnavailableAgentOwner do
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  setup do
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)

    on_exit(fn ->
      # Restore-or-delete: putting back a literal nil would poison every later
      # test that reads the Salix client config.
      case prev do
        nil -> SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
        value -> SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, value)
      end

      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_schedules)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_deleted)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_created)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_create_result)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_updates)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_update_result)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    BridgeForTeams.TestSupport.CanonicalAgentClient.drain()
    %{org: org, project: project}
  end

  defp script(result), do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_schedules, result)

  defp schedule(agent, attrs) do
    Map.merge(
      %{
        "id" => "sched-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        "agent_id" => agent.salix_agent_id,
        "prompt" => "do the thing",
        "interval_minutes" => 5,
        "created_at" => 1_700_000_000_000,
        "last_run" => nil
      },
      attrs
    )
  end

  test "lists only schedules owned by the project's agents, tagged with the owner",
       %{project: project} do
    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "worker",
        "role" => "worker"
      })

    script({:ok,
     [
       schedule(router, %{"id" => "s-router", "prompt" => "router job"}),
       schedule(worker, %{"id" => "s-worker", "prompt" => "worker job"}),
       # Another swarm's agent — must be excluded.
       %{
         "id" => "s-foreign",
         "agent_id" => "agent_someone_else",
         "prompt" => "not ours",
         "interval_minutes" => 1,
         "created_at" => 1_700_000_000_000,
         "last_run" => nil
       }
     ]})

    assert {:ok, schedules} = Schedules.list_project_schedules(project)
    assert Enum.map(schedules, & &1["id"]) == ["s-router", "s-worker"]

    router_sched = Enum.find(schedules, &(&1["id"] == "s-router"))
    assert router_sched["agent_name"] == "router"
    assert router_sched["bft_agent_id"] == router.id

    # Cardinality contract: the request is owner-filtered at the source — BFT
    # asks Salix for exactly this project's agent ids + Task group binding,
    # never the global definition set.
    assert {queried_agents, queried_group} =
             SystemsRuntime.get_env(:bridge_for_teams_core, :test_owner_query)

    assert router.salix_agent_id in queried_agents
    assert worker.salix_agent_id in queried_agents
    refute "agent_someone_else" in queried_agents
    assert queried_group == project.salix_group_id
  end

  test "a foreign Task carrying a project agent_id is neither listed nor mutable", %{
    project: project
  } do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    # Reviewer repro: a Task bound to ANOTHER group, maliciously/historically
    # carrying THIS project's agent id. It must not decorate as an agent
    # schedule, and the mutation surface must treat it as not owned.
    foreign_task = %{
      "id" => "s-foreign-task",
      "receiver" => "task",
      "agent_id" => agent.salix_agent_id,
      "payload" => %{
        "agent_group_id" => "someone-elses-group",
        "conversation_id" => "conv-b"
      },
      "interval_minutes" => 5,
      "created_at" => 1_700_000_000_000,
      "last_run" => nil
    }

    script({:ok, [foreign_task]})

    assert {:ok, []} = Schedules.list_project_schedules(project)

    assert {:error, :not_found} =
             Schedules.delete_project_schedule(project, "s-foreign-task")

    assert {:error, :not_found} =
             Schedules.update_project_schedule(project, "s-foreign-task", %{"prompt" => "x"})
  end

  test "includes a Task schedule only when its receiver payload belongs to the project", %{
    project: project
  } do
    script({
      :ok,
      [
        %{
          "id" => "s-task",
          "receiver" => "task",
          "payload" => %{
            "agent_group_id" => project.salix_group_id,
            "conversation_id" => "cnv1_project_task"
          },
          "cron" => "30 18 * * 3",
          "timezone" => "Asia/Shanghai",
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        },
        %{
          "id" => "s-foreign-task",
          "receiver" => "task",
          "payload" => %{
            "agent_group_id" => "grp_other",
            "conversation_id" => "cnv1_foreign_task"
          },
          "interval_minutes" => 5,
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        }
      ]
    })

    assert {:ok, [schedule]} = Schedules.list_project_schedules(project)
    assert schedule["id"] == "s-task"
    assert schedule["target_type"] == "task"
    assert schedule["conversation_id"] == "cnv1_project_task"
  end

  test "deletes a schedule owned by the project", %{project: project} do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    script({:ok, [schedule(agent, %{"id" => "s-mine"})]})

    assert :ok = Schedules.delete_project_schedule(project, "s-mine")
    assert SystemsRuntime.get_env(:bridge_for_teams_core, :test_deleted) == ["s-mine"]
  end

  test "does not delete a Task schedule without clearing its conversation binding", %{
    project: project
  } do
    script({
      :ok,
      [
        %{
          "id" => "s-task",
          "receiver" => "task",
          "payload" => %{
            "agent_group_id" => project.salix_group_id,
            "conversation_id" => "cnv1_project_task"
          },
          "interval_minutes" => 5,
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        }
      ]
    })

    assert {:error, :not_found} = Schedules.delete_project_schedule(project, "s-task")
    assert SystemsRuntime.get_env(:bridge_for_teams_core, :test_deleted, []) == []
  end

  test "refuses to delete a schedule not owned by the project", %{project: project} do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    script({:ok, [schedule(agent, %{"id" => "s-mine"})]})

    assert {:error, :not_found} = Schedules.delete_project_schedule(project, "s-foreign")
    assert SystemsRuntime.get_env(:bridge_for_teams_core, :test_deleted, []) == []
  end

  defp created_definitions,
    do: SystemsRuntime.get_env(:bridge_for_teams_core, :test_created, [])

  defp sent_updates,
    do: SystemsRuntime.get_env(:bridge_for_teams_core, :test_updates, [])

  describe "create_project_schedule/3" do
    test "stamps the target agent's salix id and a generated schedule id", %{project: project} do
      {:ok, router} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      {:ok, worker} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "worker",
          "role" => "worker"
        })

      assert {:ok, created} =
               Schedules.create_project_schedule(project, %{
                 "agent_id" => worker.id,
                 "prompt" => "compile the weekly report",
                 "cron" => "0 8 * * 1-5",
                 "timezone" => "America/New_York",
                 # Spoofing attempts on stamped fields are dropped.
                 "id" => "sched-spoofed"
               })

      assert [definition] = created_definitions()
      assert definition["agent_id"] == worker.salix_agent_id
      assert definition["agent_id"] != router.salix_agent_id
      assert definition["prompt"] == "compile the weekly report"
      assert definition["cron"] == "0 8 * * 1-5"
      assert definition["timezone"] == "America/New_York"
      refute Map.has_key?(definition, "interval_minutes")
      assert SalixStore.Ids.valid_schedule_id?(definition["id"])
      assert definition["id"] != "sched-spoofed"

      assert created["id"] == definition["id"]
      assert created["bft_agent_id"] == worker.id
      assert created["agent_name"] == "worker"
    end

    test "rejects an agent that isn't the project's", %{org: org, project: project} do
      {:ok, _mine} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "mine",
          "role" => "router"
        })

      {:ok, other_project} = Projects.create_project(org.id, %{name: "Other", slug: "other"})

      {:ok, foreign} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
          other_project.id,
          %{"name" => "foreign", "role" => "router"}
        )

      assert {:error, :agent_not_found} =
               Schedules.create_project_schedule(project, %{
                 "agent_id" => foreign.id,
                 "prompt" => "p",
                 "interval_minutes" => 5
               })

      assert created_definitions() == []
    end
  end

  describe "update_project_schedule/4" do
    test "merges writable changes into an owned schedule", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      script({:ok, [schedule(agent, %{"id" => "s-mine"})]})

      assert {:ok, updated} =
               Schedules.update_project_schedule(project, "s-mine", %{
                 prompt: "new prompt",
                 # Stamped/unknown fields are dropped, not forwarded.
                 agent_id: "agent_spoofed",
                 id: "s-other"
               })

      assert [{"s-mine", changes}] = sent_updates()
      assert changes == %{"prompt" => "new prompt"}
      assert updated["prompt"] == "new prompt"
      assert updated["agent_id"] == agent.salix_agent_id
      assert updated["bft_agent_id"] == agent.id
      assert updated["agent_name"] == "router"
    end

    test "refuses to update a schedule not owned by the project", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "a",
          "role" => "router"
        })

      script({:ok, [schedule(agent, %{"id" => "s-mine"})]})

      assert {:error, :not_found} =
               Schedules.update_project_schedule(project, "s-foreign", %{"prompt" => "x"})

      assert sent_updates() == []
    end
  end
end
