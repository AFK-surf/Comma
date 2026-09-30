defmodule BridgeForTeams.DashboardProjection.RebuildTaskTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Orgs, Projects}

  test "dry-run emits scoped JSON without refreshing remote sources" do
    %{org: org, project: project} = fixture()
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.BridgeForTeams.DashboardProjection.Rebuild.run([
      "--org",
      org.slug,
      "--project",
      project.slug,
      "--dry-run",
      "--pretty"
    ])

    assert_receive {:mix_shell, :info, [json]}
    decoded = Jason.decode!(json)
    assert decoded["dry_run"] == true
    assert decoded["scope"]["org_slug"] == org.slug
    assert decoded["scope"]["project_count"] == 1
    assert decoded["concurrency"] == 2
    assert decoded["timeout_ms"] == 30_000
    assert decoded["salix_call_counts"] == %{}
    assert decoded["failed_project_ids"] == []
    assert [%{"action" => "dry_run", "project_id" => project_id}] = decoded["results"]
    assert project_id == project.id
  end

  test "dry-run supports user scoping, concurrency, and timeout options" do
    %{org: org, user: user, project: project} = fixture()
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.BridgeForTeams.DashboardProjection.Rebuild.run([
      "--org",
      org.slug,
      "--user",
      user.email,
      "--dry-run",
      "--concurrency",
      "3",
      "--timeout",
      "12000"
    ])

    assert_receive {:mix_shell, :info, [json]}
    decoded = Jason.decode!(json)
    assert decoded["scope"]["user_id"] == user.id
    assert decoded["scope"]["project_count"] == 1
    assert decoded["concurrency"] == 3
    assert decoded["timeout_ms"] == 12_000
    assert [%{"action" => "dry_run", "project_id" => project_id}] = decoded["results"]
    assert project_id == project.id
  end

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "rebuild-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Rebuild #{n}", "slug" => "rebuild-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Project #{n}", "slug" => "proj-#{n}"},
        creator_user_id: user.id
      )

    %{user: user, org: org, project: project}
  end
end
