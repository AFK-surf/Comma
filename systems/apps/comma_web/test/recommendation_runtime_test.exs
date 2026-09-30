defmodule CommaWeb.RecommendationRuntimeTest do
  use Comma.DataCase, async: false
  use Oban.Testing, repo: Comma.Repo
  alias Comma.Recommendations
  alias CommaWeb.RecommendationRuntime
  alias SalixAgent.{AgentControl, InternalSessionStore}
  alias SalixCluster.Schedules
  alias SalixStore.Ids

  setup do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "reads and settings queue reconciliation without provisioning an Agent" do
    {user, workspace, profile} = fixture!()
    assert is_nil(profile.agent_id)
    assert is_nil(profile.schedule_id)

    assert_enqueued(
      worker: Comma.Workers.RecommendationReconcile,
      args: %{profile_id: profile.id}
    )

    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert {:ok, schedule} = Schedules.get(profile.schedule_id)
    assert schedule["receiver"] == "comma_recommendation"
    assert schedule["payload"] == %{"profile_id" => profile.id}
    assert schedule["timezone"] == "Asia/Singapore"
    refute Map.has_key?(schedule, "agent_id")

    assert {:ok, _} =
             Recommendations.update_settings(user, %{}, workspace["id"], %{
               "schedule" => %{
                 "enabled" => false,
                 "hour" => 8,
                 "minute" => 0,
                 "timezone" => "Asia/Singapore"
               },
               "autoEnableNewSources" => true
             })

    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    assert {:ok, %{"status" => "paused"}} = Schedules.get(profile.schedule_id)

    assert {:ok, :skipped} =
             Recommendations.begin_schedule_occurrence(profile.id, profile.schedule_id, 1)
  end

  test "converting an owned legacy schedule preserves its ID, occurrence and renderer journal" do
    {user, workspace, profile} = fixture!()

    ids = %{
      agent_id: Ids.new_agent_id(workspace["default_group_id"]),
      session_id: Ids.new_session_id(),
      schedule_id: Ids.new_schedule_id()
    }

    assert {:ok, profile} = Recommendations.reserve_runtime(profile.id, ids)

    assert {:ok, _} =
             AgentControl.create_preallocated(
               %{
                 "group_id" => workspace["default_group_id"],
                 "name" => "Routine renderer",
                 "role" => "worker",
                 "purpose" => "comma_recommendation",
                 "hidden" => true
               },
               workspace["salix_tenant_id"],
               profile.agent_id
             )

    assert {:ok, _} =
             InternalSessionStore.prepare_create(profile.agent_id, profile.session_id, %{
               "hidden" => true
             })

    assert {:ok, _} =
             Schedules.create(profile.schedule_id, %{
               "agent_id" => profile.agent_id,
               "session_id" => profile.session_id,
               "cron" => "0 8 * * *",
               "timezone" => profile.timezone,
               "prompt" => "Call recommendation.begin"
             })

    assert {:ok, old} = Schedules.get(profile.schedule_id)
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id, retire_renderer: true)
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id, retire_renderer: true)
    assert {:ok, converted} = Schedules.get(profile.schedule_id)

    assert Map.take(converted, ~w(id created_at last_run)) ==
             Map.take(old, ~w(id created_at last_run))

    assert converted["receiver"] == "comma_recommendation"
    assert {:ok, %{"archived_at" => _}} = AgentControl.get_record(profile.agent_id)
    assert InternalSessionStore.exists?(profile.agent_id, profile.session_id)
    assert {:ok, same} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert same.agent_id == profile.agent_id
  end

  test "a foreign schedule is never changed or deleted by Routine reconciliation" do
    {_user, workspace, profile} = fixture!()
    foreign_agent = Ids.new_agent_id(workspace["default_group_id"])
    schedule_id = Ids.new_schedule_id()
    assert {:ok, _} = Recommendations.bind_runtime(profile.id, %{schedule_id: schedule_id})

    assert {:ok, before} =
             Schedules.create(schedule_id, %{
               "agent_id" => foreign_agent,
               "interval_minutes" => 60,
               "prompt" => "Unrelated work"
             })

    assert {:error, :recommendation_schedule_owner_mismatch} =
             RecommendationRuntime.reconcile_profile(profile.id)

    assert {:ok, ^before} = Schedules.get(schedule_id)
  end

  test "one scheduled occurrence queues one durable generation and disabled sources skip" do
    {_user, _workspace, profile} = fixture!()
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    profile = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)
    assert {:ok, schedule} = Schedules.get(profile.schedule_id)
    assert {:ok, :fired} = Schedules.fire(schedule, 123)

    assert all_enqueued(worker: Comma.Workers.RecommendationGenerate) == []

    assert {:ok, _} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               %{
                 "connectionId" => "account-github",
                 "label" => "GitHub",
                 "appId" => "github",
                 "appName" => "GitHub",
                 "toolkit" => "github",
                 "kind" => "composio"
               }
             ])

    assert {:ok, :fired} = Schedules.fire(schedule, 124)
    assert {:ok, :already_fired} = Schedules.recover_claim(profile.schedule_id, 124)
    assert {:ok, %{"last_run" => 124}} = Schedules.get(profile.schedule_id)

    assert [%{args: %{"run_id" => run_id}}] =
             all_enqueued(worker: Comma.Workers.RecommendationGenerate)

    assert {:ok, %{run: %{source_message_id: source_message_id}}} =
             Recommendations.run_context(run_id)

    assert source_message_id == "schedule:#{profile.schedule_id}:124"

    assert {:ok, :skipped} =
             Recommendations.begin_schedule_occurrence(profile.id, Ids.new_schedule_id(), 123)
  end

  test "an old accepted schedule receipt without an Agent-created run receives a bounded terminal outcome" do
    {_user, _workspace, profile} = fixture!()
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    profile = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)

    assert {:ok, profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               %{
                 "connectionId" => "account-github",
                 "appId" => "github",
                 "appName" => "GitHub",
                 "label" => "GitHub",
                 "toolkit" => "github",
                 "kind" => "composio"
               }
             ])

    accepted_at = System.system_time(:millisecond) - 500_000
    assert :ok = Recommendations.recover_schedule_receipt(profile, %{"last_run" => accepted_at})

    assert {:ok, %{run: run}} =
             Recommendations.begin_schedule_occurrence(
               profile.id,
               profile.schedule_id,
               accepted_at
             )

    assert run["status"] == "failed"

    assert {:ok, %{run: %{error: ":recommendation_run_timed_out"}}} =
             Recommendations.run_context(run["id"])

    assert :ok =
             Recommendations.recover_schedule_receipt(
               Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id),
               %{"last_run" => accepted_at}
             )

    assert length(all_enqueued(worker: Comma.Workers.RecommendationGenerate)) == 1
  end

  test "retired model tools cannot publish or start a new generation" do
    assert {:error, :recommendation_renderer_retired} = RecommendationRuntime.begin_run(%{})

    assert {:error, :recommendation_renderer_retired} =
             RecommendationRuntime.publish(%{}, Ecto.UUID.generate(), %{})

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "recommendation.publish", %{})
  end

  defp fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "routine-runtime-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    assert {:ok, _} = RecommendationRuntime.ensure(user, %{}, workspace, "Asia/Singapore", "en")
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    {user, workspace, profile}
  end
end
