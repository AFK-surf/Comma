defmodule BridgeForTeams.AnalyticsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Analytics, DashboardProjection, Memberships, Orgs, Repo}
  alias BridgeForTeams.Schema.Project

  test "org_home_summary aggregates visible project dashboard snapshots without Salix" do
    %{user: user, org: org, project: project, other_project: other_project} = fixture()

    assert {:ok, _snapshot} =
             DashboardProjection.upsert_snapshot(project, %{
               conversation_count: 3,
               token_input: 10,
               token_output: 20,
               token_total: 30,
               refreshed_at: DateTime.utc_now()
             })

    assert {:ok, _snapshot} =
             DashboardProjection.upsert_snapshot(other_project, %{
               conversation_count: 0,
               refresh_error: "timeout"
             })

    summary = Analytics.org_home_summary(org.id, user.id)

    assert summary.project_count == 2
    assert summary.used_project_count == 1
    assert summary.unused_project_count == 1
    assert summary.conversation_count == 3
    assert summary.token_totals.total == 30
    assert Enum.map(summary.project_usage_rows, & &1.project_id) == [project.id, other_project.id]
  end

  test "missing snapshots return stable zero values" do
    %{user: user, org: org} = fixture()

    summary = Analytics.org_home_summary(org.id, user.id)

    assert summary.project_count == 2
    assert summary.conversation_count == 0
    assert summary.token_totals.total == 0
    assert Enum.all?(summary.project_usage_rows, &(&1.snapshot_status == :missing))
  end

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "analytics-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Analytics #{n}", "slug" => "analytics-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    project = project!(org, user.id, "one-#{n}")
    other_project = project!(org, user.id, "two-#{n}")

    %{user: user, org: org, project: project, other_project: other_project}
  end

  defp project!(org, user_id, slug) do
    Repo.insert!(%Project{
      org_id: org.id,
      name: slug,
      slug: slug,
      salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id),
      created_by_user_id: user_id
    })
  end
end
