defmodule Comma.RecommendationSettingsSafetyTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false

  alias Comma.Data.{RecommendationProfile, Workspace, WorkspaceMembership}
  alias Comma.{Recommendations, Repo}
  alias SalixStore.Ids

  test "member mode changes save atomically, preserve schedule, and invalidate old work" do
    {profile, workspace} = profile_fixture!()

    attrs =
      settings(profile, profile.timezone, profile.schedule_hour)
      |> Map.merge(%{
        "relevanceMode" => "generic"
      })

    assert {:ok, envelope} =
             Recommendations.update_settings(%{"id" => profile.user_id}, %{}, workspace.id, attrs)

    assert envelope["settings"]["relevanceMode"] == "generic"
    updated = Repo.get!(RecommendationProfile, profile.id)
    assert updated.source_revision == profile.source_revision + 1
    assert updated.schedule_hour == profile.schedule_hour
    assert updated.timezone == profile.timezone

    assert {:error, :invalid_recommendation_settings} =
             Recommendations.update_settings(
               %{"id" => profile.user_id},
               %{},
               workspace.id,
               Map.put(attrs, "relevanceMode", "unknown")
             )

    assert Repo.get!(RecommendationProfile, profile.id).source_revision == updated.source_revision

    assert {:ok, _} =
             Recommendations.update_settings(
               %{"id" => profile.user_id},
               %{},
               workspace.id,
               settings(updated, updated.timezone, 9)
             )

    assert Repo.get!(RecommendationProfile, profile.id).source_revision == updated.source_revision
  end

  defp settings(profile, timezone, hour \\ 10) do
    %{
      "autoEnableNewSources" => profile.auto_enable_new_sources,
      "schedule" => %{
        "enabled" => profile.schedule_enabled,
        "hour" => hour,
        "minute" => profile.schedule_minute,
        "timezone" => timezone
      },
      "sources" => []
    }
  end

  defp profile_fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "recommendation-settings-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-recommendation-settings-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Recommendation settings",
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
        timezone: "Asia/Singapore"
      })
      |> Repo.insert!()

    {profile, workspace}
  end
end

defmodule Comma.RecommendationLockOrderTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  import Ecto.Query

  alias Comma.Data.{RecommendationProfile, RecommendationRun, User, Workspace}
  alias Comma.{Recommendations, Repo}
end
