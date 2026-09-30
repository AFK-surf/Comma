defmodule BridgeForTeams.RoutineSchedulesTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Artifacts,
    AssistantChats,
    Observability,
    Orgs,
    Reports,
    RoutineSchedules,
    UserOnboardings
  }

  @report_schedule_id "sch1_0000000000000000001"
  @routine_schedule_id "sch1_0000000000000000002"

  # Scripted Salix client (same shape as SchedulesTest): create echoes the
  # definition back with an id; delete/update collect their calls; list returns
  # whatever the test scripts under `:test_schedules`, falling back to the
  # definitions created so far (minus the deleted ones) so ownership lookups
  # against freshly materialized schedules work.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    use BridgeForTeams.TestConversationStore, :group_router

    @store __MODULE__.Store

    def reset, do: BridgeForTeams.TestConversationStore.reset(@store)

    def list_schedules_for_owners(_agent_ids, _group_id) do
      case Application.get_env(:bridge_for_teams_core, :test_schedules) do
        nil ->
          created = Application.get_env(:bridge_for_teams_core, :test_created, [])
          deleted = Application.get_env(:bridge_for_teams_core, :test_deleted, [])
          updated = Application.get_env(:bridge_for_teams_core, :test_updated, [])

          schedules =
            created
            |> Enum.reject(&(&1["id"] in deleted))
            |> Enum.map(fn attrs ->
              changes =
                updated
                |> Enum.filter(fn {id, _changes} -> id == attrs["id"] end)
                |> Enum.reduce(%{}, fn {_id, changes}, acc -> Map.merge(acc, changes) end)

              attrs
              |> Map.merge(changes)
              |> Map.merge(%{"created_at" => 1_700_000_000_000, "last_run" => nil})
            end)

          {:ok, schedules}

        scripted ->
          scripted
      end
    end

    def create_schedule(attrs) do
      created = Application.get_env(:bridge_for_teams_core, :test_created, [])
      Application.put_env(:bridge_for_teams_core, :test_created, [attrs | created])
      {:ok, Map.merge(attrs, %{"created_at" => 1_700_000_000_000, "last_run" => nil})}
    end

    def update_schedule(id, changes) do
      updates = Application.get_env(:bridge_for_teams_core, :test_updated, [])
      Application.put_env(:bridge_for_teams_core, :test_updated, [{id, changes} | updates])
      {:ok, Map.merge(%{"id" => id}, changes)}
    end

    def delete_schedule(id) do
      ids = Application.get_env(:bridge_for_teams_core, :test_deleted, [])
      Application.put_env(:bridge_for_teams_core, :test_deleted, [id | ids])
      :ok
    end

    # Routine reconcile now resolves the materializing user's per-swarm New Home
    # assistant chat (`AssistantChats.ensure_chat`) to embed its conversation id
    # in each prompt. Salix owns the public id and returns it to the binding.
    def create_group_conversation(group_id, attrs),
      do: BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, attrs)

    def get_agent_projection(agent_id, _tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "role" => "router",
         "router_session_id" => "ses1_0000000000000000001"
       }}
    end
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)
    ScriptedClient.reset()

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_schedules)
      Application.delete_env(:bridge_for_teams_core, :test_created)
      Application.delete_env(:bridge_for_teams_core, :test_updated)
      Application.delete_env(:bridge_for_teams_core, :test_deleted)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "P",
        slug: "p"
      })

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "name" => "Owner"
      })

    {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)

    %{org: org, project: project, user: user, onboarding: onboarding}
  end

  defp all_on, do: Map.new(RoutineSchedules.materializable_keys(), &{&1, true})

  defp created, do: Application.get_env(:bridge_for_teams_core, :test_created, [])
  defp updated, do: Application.get_env(:bridge_for_teams_core, :test_updated, [])
  defp deleted, do: Application.get_env(:bridge_for_teams_core, :test_deleted, [])

  defp chat_conversation_id(user, project) do
    {:ok, binding} = AssistantChats.get_binding(user.id, project.id)
    binding.conversation_id
  end

  describe "reconcile/4" do
    test "materializes each granted time-shaped capability and audits the ids", %{
      project: project,
      onboarding: onboarding
    } do
      assert {:ok, updated} = RoutineSchedules.reconcile(project, onboarding, all_on())

      audit = updated.capabilities["_schedules"][project.id]
      assert is_map(audit)

      assert Enum.sort(Map.keys(audit)) ==
               Enum.sort(RoutineSchedules.materializable_keys())

      # One schedule was created per capability, stamped with the project agent.
      [agent | _] = Agents.list_agents(project.id)
      definitions = created()
      assert length(definitions) == length(RoutineSchedules.materializable_keys())
      assert Enum.all?(definitions, &(&1["agent_id"] == agent.salix_agent_id))
      assert Enum.all?(definitions, &is_binary(&1["cron"]))

      # The audit points at the created schedule ids.
      created_ids = Enum.map(definitions, & &1["id"]) |> Enum.sort()
      assert audit |> Map.values() |> Enum.sort() == created_ids
    end

    test "is idempotent — re-running with the same grants creates nothing new", %{
      project: project,
      onboarding: onboarding
    } do
      assert {:ok, updated} = RoutineSchedules.reconcile(project, onboarding, all_on())
      first = created()
      assert first != []

      # Feed the already-materialized capabilities (audit included) back in.
      assert {:ok, _again} =
               RoutineSchedules.reconcile(project, updated, updated.capabilities)

      assert created() == first
    end

    test "toggling a capability off deletes its schedule and drops the audit entry", %{
      project: project,
      onboarding: onboarding
    } do
      [agent | _] = Agents.list_agents(project.id)

      assert {:ok, materialized} = RoutineSchedules.reconcile(project, onboarding, all_on())
      audit = materialized.capabilities["_schedules"][project.id]
      [target_key | _] = RoutineSchedules.materializable_keys()
      schedule_id = audit[target_key]
      assert is_binary(schedule_id)

      # Ownership check (inside delete) lists cluster schedules — include ours.
      Application.put_env(
        :bridge_for_teams_core,
        :test_schedules,
        {:ok,
         [
           %{
             "id" => schedule_id,
             "agent_id" => agent.salix_agent_id,
             "prompt" => "x",
             "cron" => "0 8 * * 1-5",
             "created_at" => 1_700_000_000_000,
             "last_run" => nil
           }
         ]}
      )

      revoked = Map.put(materialized.capabilities, target_key, false)
      assert {:ok, after_toggle} = RoutineSchedules.reconcile(project, materialized, revoked)

      assert schedule_id in deleted()
      refute Map.has_key?(after_toggle.capabilities["_schedules"][project.id], target_key)
    end

    test "ignores capabilities that are not time-shaped", %{
      project: project,
      onboarding: onboarding
    } do
      caps = %{"inbox.draft_replies" => true, "memory.semantic_profile" => true}

      assert {:ok, updated} = RoutineSchedules.reconcile(project, onboarding, caps)
      assert created() == []
      assert updated.capabilities["_schedules"][project.id] == %{}
    end

    test "stamps each created schedule's id into its own prompt contract", %{
      project: project,
      onboarding: onboarding
    } do
      assert {:ok, materialized} = RoutineSchedules.reconcile(project, onboarding, all_on())

      # Two-phase create: Salix assigns the id, then the prompt is updated to
      # embed it in the artifact frontmatter.
      audit = materialized.capabilities["_schedules"][project.id]

      for {_capability, schedule_id} <- audit do
        assert {^schedule_id, %{"prompt" => prompt}} =
                 Enum.find(updated(), fn {id, _changes} -> id == schedule_id end)

        assert prompt =~ "schedule_id: #{schedule_id}"
      end
    end

    test "embeds the materializing user's assistant-chat conversation id in each prompt", %{
      project: project,
      user: user,
      onboarding: onboarding
    } do
      assert {:ok, _materialized} = RoutineSchedules.reconcile(project, onboarding, all_on())

      conversation_id = chat_conversation_id(user, project)
      assert is_binary(conversation_id)

      # Both create-phase prompts and their id-stamped rewrites name the concrete
      # conversation, and the title-search instruction is gone entirely.
      assert Enum.all?(created(), &(&1["prompt"] =~ ~s(conversation_id "#{conversation_id}")))

      for {_id, %{"prompt" => prompt}} <- updated() do
        assert prompt =~ ~s(conversation_id "#{conversation_id}")
      end
    end

    test "materializes a generic routine under the user's namespaced artifact directory", %{
      project: project,
      user: user,
      onboarding: onboarding
    } do
      assert {:ok, _materialized} =
               RoutineSchedules.reconcile(project, onboarding, %{
                 "informed.morning_briefing" => true
               })

      slug = Artifacts.slug("Morning briefing", user.id)
      assert [definition] = created()
      assert definition["prompt"] =~ "/.salix/artifacts/#{slug}/"
    end
  end

  describe "per-user routine delivery" do
    test "two users in one swarm get their own conversation ids in their own schedules", %{
      project: project,
      user: user,
      onboarding: onboarding
    } do
      {:ok, other_user} =
        Accounts.create_user(%{
          "email" => "other-#{System.unique_integer([:positive])}@example.com",
          "name" => "Other"
        })

      {:ok, other_onboarding} = UserOnboardings.ensure_onboarding(other_user.id)

      assert {:ok, _} = RoutineSchedules.reconcile(project, onboarding, all_on())
      conv1 = chat_conversation_id(user, project)

      assert {:ok, _} = RoutineSchedules.reconcile(project, other_onboarding, all_on())
      conv2 = chat_conversation_id(other_user, project)

      assert is_binary(conv1)
      assert is_binary(conv2)
      # Each user of the same swarm bound their own chat thread.
      assert conv1 != conv2

      key_count = length(RoutineSchedules.materializable_keys())
      assert length(Enum.filter(created(), &(&1["prompt"] =~ conv1))) == key_count
      assert length(Enum.filter(created(), &(&1["prompt"] =~ conv2))) == key_count

      # No prompt reports into the other user's conversation.
      refute Enum.any?(created(), &(&1["prompt"] =~ conv1 and &1["prompt"] =~ conv2))
    end
  end

  describe "report routines" do
    defp report_definition(key, user) do
      RoutineSchedules.capability_definitions()
      |> Enum.find(&(&1.key == key))
      |> RoutineSchedules.definition_for_user(user.id)
    end

    test "capability_definitions carries the two report series" do
      definitions = RoutineSchedules.capability_definitions()

      assert %{
               cron: "0 8 * * 1-5",
               category: "reports",
               title: "Daily Briefing",
               series: "daily-briefing",
               kind: "daily"
             } = Enum.find(definitions, &(&1.key == "reports.daily_briefing"))

      assert %{
               cron: "0 9 * * 1",
               category: "reports",
               title: "Weekly Portfolio Report",
               series: "weekly-portfolio",
               kind: "weekly"
             } = Enum.find(definitions, &(&1.key == "reports.weekly_portfolio"))
    end

    test "definition_for_user namespaces the report series and the artifact slug per user", %{
      user: user
    } do
      definition = report_definition("reports.daily_briefing", user)
      assert definition.series_slug == Reports.series_slug("daily-briefing", user.id)
      refute Map.has_key?(definition, :artifact_slug)

      plain =
        RoutineSchedules.capability_definitions()
        |> Enum.find(&(&1.key == "informed.morning_briefing"))

      personalized = RoutineSchedules.definition_for_user(plain, user.id)
      assert personalized.artifact_slug == Artifacts.slug("Morning briefing", user.id)
      refute Map.has_key?(personalized, :series_slug)
    end

    test "reconcile materializes a report routine with the user's namespaced series", %{
      project: project,
      user: user,
      onboarding: onboarding
    } do
      assert {:ok, materialized} =
               RoutineSchedules.reconcile(project, onboarding, %{
                 "reports.daily_briefing" => true
               })

      slug = Reports.series_slug("daily-briefing", user.id)
      assert [definition] = created()
      assert definition["cron"] == "0 8 * * 1-5"
      assert definition["prompt"] =~ "/.salix/reports/#{slug}/"

      # The id-stamped rewrite carries the id in the frontmatter contract.
      schedule_id =
        materialized.capabilities["_schedules"][project.id]["reports.daily_briefing"]

      assert {^schedule_id, %{"prompt" => stamped}} =
               Enum.find(updated(), fn {id, _changes} -> id == schedule_id end)

      assert stamped =~ "schedule_id: #{schedule_id}"
      refute stamped =~ "source_refs"
      assert stamped =~ "/.salix/reports/#{slug}/"
    end

    test "materialize_definition creates a personalized schedule outside the grant audit", %{
      project: project,
      user: user
    } do
      definition =
        RoutineSchedules.capability_definitions()
        |> Enum.find(&(&1.key == "reports.daily_briefing"))

      # The raw catalog definition goes in — personalization is applied inside.
      assert {:ok, schedule} =
               RoutineSchedules.materialize_definition(
                 project,
                 definition,
                 user.id,
                 "conv-offer-1"
               )

      slug = Reports.series_slug("daily-briefing", user.id)

      assert [created_definition] = created()
      assert created_definition["id"] == schedule["id"]
      assert created_definition["cron"] == "0 8 * * 1-5"
      assert created_definition["prompt"] =~ "/.salix/reports/#{slug}/"
      assert created_definition["prompt"] =~ ~s(conversation_id "conv-offer-1")

      # Two-phase like reconcile: the schedule's own id is stamped back into
      # its prompt contract.
      assert [{stamped_id, %{"prompt" => stamped}}] = updated()
      assert stamped_id == schedule["id"]
      assert stamped =~ "schedule_id: #{schedule["id"]}"
      refute stamped =~ "source_refs"

      # No "_schedules" audit entry is written — the caller (the board's offer
      # row) owns the idempotency record.
      {:ok, reloaded} = UserOnboardings.ensure_onboarding(user.id)
      refute Map.has_key?(reloaded.capabilities || %{}, "_schedules")
    end

    test "resume re-embeds the resuming user's series slug", %{
      project: project,
      user: user,
      onboarding: onboarding
    } do
      {:ok, onboarding} =
        RoutineSchedules.reconcile(project, onboarding, %{"reports.weekly_portfolio" => true})

      schedule_id =
        onboarding.capabilities["_schedules"][project.id]["reports.weekly_portfolio"]

      {:ok, paused} = RoutineSchedules.pause_routine(project, onboarding, schedule_id)
      assert {:ok, resumed} = RoutineSchedules.resume_routine(project, paused, schedule_id)

      new_id = resumed.capabilities["_schedules"][project.id]["reports.weekly_portfolio"]
      slug = Reports.series_slug("weekly-portfolio", user.id)

      assert Enum.any?(
               created(),
               &(&1["id"] == new_id and &1["prompt"] =~ "/.salix/reports/#{slug}/")
             )
    end
  end

  describe "pause/resume/delete_routine" do
    setup %{project: project, onboarding: onboarding} do
      {:ok, onboarding} = RoutineSchedules.reconcile(project, onboarding, all_on())
      [target_key | _rest] = RoutineSchedules.materializable_keys()
      schedule_id = onboarding.capabilities["_schedules"][project.id][target_key]
      assert is_binary(schedule_id)

      %{onboarding: onboarding, target_key: target_key, schedule_id: schedule_id}
    end

    test "pause deletes the schedule and snapshots it under _paused", %{
      project: project,
      onboarding: onboarding,
      target_key: target_key,
      schedule_id: schedule_id
    } do
      assert {:ok, paused} =
               RoutineSchedules.pause_routine(project, onboarding, schedule_id)

      # Salix has no enabled flag: pause is delete + snapshot.
      assert schedule_id in deleted()

      entry = paused.capabilities["_paused"][project.id][schedule_id]
      assert entry["capability"] == target_key
      assert entry["definition"]["cron"] == "0 8 * * 1-5"
      assert is_binary(entry["definition"]["prompt"])

      # The grant and its audit entry survive the pause (reconcile idempotence).
      assert paused.capabilities[target_key] == true
      assert paused.capabilities["_schedules"][project.id][target_key] == schedule_id

      # The paused snapshot renders in the widget.
      assert [routine] = RoutineSchedules.paused_routines(paused, project)
      assert routine["id"] == schedule_id
      assert routine["paused"] == true
      assert routine["cron"] == "0 8 * * 1-5"
    end

    test "resume recreates the schedule and re-points the audit", %{
      project: project,
      user: user,
      onboarding: onboarding,
      target_key: target_key,
      schedule_id: schedule_id
    } do
      {:ok, paused} = RoutineSchedules.pause_routine(project, onboarding, schedule_id)

      assert {:ok, resumed} =
               RoutineSchedules.resume_routine(project, paused, schedule_id)

      new_id = resumed.capabilities["_schedules"][project.id][target_key]
      assert is_binary(new_id)
      assert new_id != schedule_id
      assert resumed.capabilities["_paused"][project.id] == %{}

      # Recreated from the capability definition — re-personalized, so the
      # fresh prompt keeps the resuming user's artifact directory — and the
      # prompt is stamped with the new id.
      assert Enum.any?(created(), &(&1["id"] == new_id))

      assert {^new_id, %{"prompt" => prompt}} =
               Enum.find(updated(), fn {id, _changes} -> id == new_id end)

      assert prompt =~ "schedule_id: #{new_id}"
      assert prompt =~ "/.salix/artifacts/#{Artifacts.slug("Morning briefing", user.id)}/"
    end

    test "resume re-stamps the fresh schedule with the user's conversation id", %{
      project: project,
      user: user,
      onboarding: onboarding,
      target_key: target_key,
      schedule_id: schedule_id
    } do
      {:ok, paused} = RoutineSchedules.pause_routine(project, onboarding, schedule_id)
      assert {:ok, resumed} = RoutineSchedules.resume_routine(project, paused, schedule_id)

      new_id = resumed.capabilities["_schedules"][project.id][target_key]
      conversation_id = chat_conversation_id(user, project)

      assert {^new_id, %{"prompt" => prompt}} =
               Enum.find(updated(), fn {id, _changes} -> id == new_id end)

      # The re-stamp keeps the same delivery rule: the fresh prompt names the
      # user's conversation id and its new schedule id.
      assert prompt =~ ~s(conversation_id "#{conversation_id}")
      assert prompt =~ "schedule_id: #{new_id}"
    end

    test "resume of an unknown paused id returns not_found", %{
      project: project,
      onboarding: onboarding
    } do
      assert {:error, :not_found} =
               RoutineSchedules.resume_routine(project, onboarding, "sched-missing")
    end

    test "delete revokes the backing capability and reconciles the audit", %{
      project: project,
      onboarding: onboarding,
      target_key: target_key,
      schedule_id: schedule_id
    } do
      assert {:ok, after_delete} =
               RoutineSchedules.delete_routine(project, onboarding, schedule_id)

      # The widget delete is the post-onboarding revocation surface: the grant
      # flips off, the schedule is deleted, and the audit entry goes with it —
      # no stale grant → schedule_id mapping survives.
      assert schedule_id in deleted()
      assert after_delete.capabilities[target_key] == false
      refute Map.has_key?(after_delete.capabilities["_schedules"][project.id], target_key)
    end

    test "delete of a paused capability routine drops grant, audit, and snapshot", %{
      project: project,
      onboarding: onboarding,
      target_key: target_key,
      schedule_id: schedule_id
    } do
      {:ok, paused} = RoutineSchedules.pause_routine(project, onboarding, schedule_id)

      assert {:ok, after_delete} =
               RoutineSchedules.delete_routine(project, paused, schedule_id)

      assert after_delete.capabilities[target_key] == false
      refute Map.has_key?(after_delete.capabilities["_schedules"][project.id], target_key)
      assert after_delete.capabilities["_paused"][project.id] == %{}
    end

    test "delete of a schedule outside the audit deletes it directly", %{
      project: project,
      onboarding: onboarding
    } do
      [agent | _] = BridgeForTeams.Agents.list_agents(project.id)

      Application.put_env(
        :bridge_for_teams_core,
        :test_schedules,
        {:ok,
         [
           %{
             "id" => "sched-foreign",
             "agent_id" => agent.salix_agent_id,
             "prompt" => "someone else's routine",
             "cron" => "0 9 * * *",
             "created_at" => 1_700_000_000_000,
             "last_run" => nil
           }
         ]}
      )

      before = onboarding.capabilities

      assert {:ok, unchanged} =
               RoutineSchedules.delete_routine(project, onboarding, "sched-foreign")

      assert "sched-foreign" in deleted()
      assert unchanged.capabilities == before
    end
  end

  describe "list_project_routines/1" do
    defp schedule_def(agent, attrs) do
      Map.merge(
        %{
          "id" => "sched-#{System.unique_integer([:positive])}",
          "agent_id" => agent.salix_agent_id,
          "prompt" => "do the thing",
          "cron" => "0 8 * * 1-5",
          "timezone" => "UTC",
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        },
        attrs
      )
    end

    test "marks a never-run schedule pending", %{project: project} do
      [agent | _] = Agents.list_agents(project.id)

      Application.put_env(
        :bridge_for_teams_core,
        :test_schedules,
        {:ok, [schedule_def(agent, %{})]}
      )

      assert {:ok, [routine]} = RoutineSchedules.list_project_routines(project)
      assert routine["health"]["status"] == "pending"
    end

    test "marks a schedule with a last run healthy", %{project: project} do
      [agent | _] = Agents.list_agents(project.id)

      Application.put_env(
        :bridge_for_teams_core,
        :test_schedules,
        {:ok, [schedule_def(agent, %{"last_run" => 1_700_000_500_000})]}
      )

      assert {:ok, [routine]} = RoutineSchedules.list_project_routines(project)
      assert routine["health"]["status"] == "healthy"
      assert routine["health"]["last_run"] == 1_700_000_500_000
    end

    test "marks a schedule failing when a fire diagnostic is newer than the last run", %{
      org: org,
      project: project
    } do
      [agent | _] = Agents.list_agents(project.id)
      schedule = schedule_def(agent, %{"id" => "sched-fail", "last_run" => 1_700_000_500_000})
      Application.put_env(:bridge_for_teams_core, :test_schedules, {:ok, [schedule]})

      {:ok, _event} =
        Observability.create_event(%{
          "org_id" => org.id,
          "project_id" => project.id,
          "domain" => "schedule",
          "source" => "salix.schedule",
          "event_type" => "schedule.fire.failed",
          "severity" => "error",
          "status" => "failed",
          "reason_class" => "deliver",
          "summary" => "Schedule fire failed at deliver",
          "resource_type" => "project_schedule",
          "resource_id" => "sched-fail",
          "correlation_id" => "schedule:sched-fail:1700000600000",
          "occurred_at" => DateTime.utc_now()
        })

      assert {:ok, [routine]} = RoutineSchedules.list_project_routines(project)
      assert routine["health"]["status"] == "failing"
      assert routine["health"]["reason"] == "deliver"
    end

    test "surfaces the schedule listing error", %{project: project} do
      Application.put_env(:bridge_for_teams_core, :test_schedules, {:error, :unavailable})
      assert {:error, :unavailable} = RoutineSchedules.list_project_routines(project)
    end
  end
end
