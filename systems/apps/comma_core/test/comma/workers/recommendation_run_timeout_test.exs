defmodule Comma.Workers.RecommendationRunTimeoutTest do
  use Comma.DataCase, async: false
  alias Comma.Data.{RecommendationProfile, RecommendationRun, Workspace, WorkspaceMembership}
  alias Comma.{RecommendationBudgets, Recommendations, Repo}
  alias Comma.Workers.RecommendationRunTimeout
  alias SalixStore.Ids

  test "an early or old soft-deadline job waits for the durable run's hard deadline" do
    {_user, _workspace, _profile, run} = pending_run!()
    age(run, 100)
    assert {:snooze, remaining} = RecommendationRunTimeout.perform(job(run))
    assert remaining in 379..380
    assert Repo.get!(RecommendationRun, run["id"]).status == "pending"
  end

  test "deadline settles lost or stalled generation work without consulting an Agent" do
    {user, workspace, _profile, run} = pending_run!()
    age(run, RecommendationBudgets.run_hard_cap_seconds())
    assert :ok = RecommendationRunTimeout.perform(job(run))
    assert Repo.get!(RecommendationRun, run["id"]).status == "failed"

    assert {:ok, %{"state" => "error", "lastError" => "timed_out"}} =
             Recommendations.get(user, %{}, workspace.id)
  end

  test "a terminal outcome is unchanged by deadline replay" do
    {_user, _workspace, _profile, run} = pending_run!()
    assert {:ok, _} = Recommendations.fail(run["id"], :source_collection_failed)
    age(run, 600)
    assert :ok = RecommendationRunTimeout.perform(job(run))
    assert Repo.get!(RecommendationRun, run["id"]).error == ":source_collection_failed"
  end

  test "Pod-lost work at its last attempt is rescued only after the budget and settles without a model" do
    {_user, _workspace, _profile, run} = pending_run!()
    age(run, 481)
    worker = "Comma.Workers.RecommendationGenerate"

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker and fragment("?->>'run_id'", j.args) == ^run["id"]
      )

    job = Repo.one!(query)

    Repo.update_all(query,
      set: [
        state: "executing",
        attempt: 3,
        max_attempts: 3,
        attempted_at: DateTime.add(DateTime.utc_now(), -481, :second)
      ]
    )

    unrelated =
      %Oban.Job{
        queue: "comma_external",
        worker: "Comma.Workers.ProfileAvatarCleanup",
        args: %{},
        state: "executing",
        attempted_at: DateTime.add(DateTime.utc_now(), -600, :second),
        max_attempts: 1,
        attempt: 1
      }
      |> Repo.insert!()

    assert {1, [%{id: rescued_id, max_attempts: 4}]} =
             Comma.ObanPlugins.OperationLifeline.rescue_recommendation_jobs(
               Oban.config(Comma.Oban),
               1
             )

    assert rescued_id == job.id
    assert Repo.get!(Oban.Job, unrelated.id).state == "executing"
    assert :ok = Comma.Workers.RecommendationGenerate.perform(job)
    assert Repo.get!(RecommendationRun, run["id"]).error == ":recommendation_run_timed_out"
  end

  defp job(run), do: %Oban.Job{args: %{"run_id" => run["id"]}}

  defp age(run, seconds) do
    Repo.get!(RecommendationRun, run["id"])
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -seconds, :second))
    |> Repo.update!()
  end

  defp pending_run! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "run-timeout-#{System.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-run-timeout-#{System.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Run timeout",
        status: "active"
      })
      |> Repo.insert!()

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })
    |> Repo.insert!()

    profile =
      %RecommendationProfile{}
      |> RecommendationProfile.create_changeset(%{
        workspace_id: workspace.id,
        user_id: user["id"],
        timezone: "Etc/UTC"
      })
      |> Repo.insert!()

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               %{
                 "appId" => "github",
                 "appName" => "Github",
                 "bindingAlias" => "github",
                 "connectionId" => "mpb-github",
                 "kind" => "managed_oauth",
                 "label" => "github"
               }
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert run["status"] == "pending"
    {user, workspace, profile, run}
  end
end
