defmodule Comma.Workers.RecommendationRunTimeoutTest do
  use Comma.DataCase, async: false
  alias Comma.Data.{RecommendationProfile, RecommendationRun, Workspace, WorkspaceMembership}
  alias Comma.{RecommendationBudgets, Recommendations, Repo}
  alias Comma.Workers.RecommendationRunTimeout
  alias SalixStore.Ids

  test "deadline settles lost or stalled generation work without consulting an Agent" do
    {user, workspace, _profile, run} = pending_run!()
    age(run, RecommendationBudgets.run_hard_cap_seconds())
    assert :ok = RecommendationRunTimeout.perform(job(run))
    assert Repo.get!(RecommendationRun, run["id"]).status == "failed"

    assert {:ok, %{"state" => "error", "lastError" => "timed_out"}} =
             Recommendations.get(user, %{}, workspace.id)
  end

  defp job(run), do: %Oban.Job{args: %{"run_id" => run["id"]}}

  defp age(run, seconds) do
    Repo.get!(RecommendationRun, run["id"])
    |> Ecto.Changeset.change(inserted_at: DateTime.add(SystemsClock.utc_now(), -seconds, :second))
    |> Repo.update!()
  end

  defp pending_run! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "run-timeout-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-run-timeout-#{SystemsRuntime.Proc.unique_integer([:positive])}",
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
