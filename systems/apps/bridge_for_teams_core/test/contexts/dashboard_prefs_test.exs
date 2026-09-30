defmodule BridgeForTeams.DashboardPrefsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, DashboardPrefs, Orgs}
  alias BridgeForTeams.Schema.Project

  test "get/2 returns nil until something is stored" do
    user = user_fixture()
    org = org_fixture()

    assert DashboardPrefs.get(user.id, org.id) == nil
  end

  test "put_selected_project/3 upserts the (user, org) row and can unpin" do
    user = user_fixture()
    org = org_fixture()
    project = project_fixture(org)

    assert {:ok, pref} = DashboardPrefs.put_selected_project(user.id, org.id, project.id)
    assert pref.selected_project_id == project.id
    assert pref.home_layout == %{}

    # Upsert: the same (user, org) row, not a second one.
    assert {:ok, unpinned} = DashboardPrefs.put_selected_project(user.id, org.id, nil)
    assert unpinned.id == pref.id
    assert unpinned.selected_project_id == nil
    assert DashboardPrefs.get(user.id, org.id).id == pref.id
  end

  test "put_home_layout/3 stores the per-swarm layout map without clobbering the selection" do
    user = user_fixture()
    org = org_fixture()
    project = project_fixture(org)

    {:ok, _pref} = DashboardPrefs.put_selected_project(user.id, org.id, project.id)

    layout = %{project.id => ["engineering", "metrics"]}
    assert {:ok, pref} = DashboardPrefs.put_home_layout(user.id, org.id, layout)
    assert pref.home_layout == layout

    # Each write replaces only its own field on the shared row.
    stored = DashboardPrefs.get(user.id, org.id)
    assert stored.selected_project_id == project.id
    assert stored.home_layout == layout
  end

  test "prefs are per org: the same user keeps independent rows" do
    user = user_fixture()
    org_a = org_fixture()
    org_b = org_fixture()
    project_a = project_fixture(org_a)

    {:ok, _pref} = DashboardPrefs.put_selected_project(user.id, org_a.id, project_a.id)
    {:ok, _pref} = DashboardPrefs.put_home_layout(user.id, org_b.id, %{"x" => ["metrics"]})

    assert DashboardPrefs.get(user.id, org_a.id).selected_project_id == project_a.id
    assert DashboardPrefs.get(user.id, org_b.id).selected_project_id == nil
    assert DashboardPrefs.get(user.id, org_a.id).home_layout == %{}
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "dashboard-prefs-#{System.unique_integer([:positive])}@example.com",
        "name" => "Prefs User"
      })

    user
  end

  defp org_fixture do
    n = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Org #{n}", "slug" => "org-#{n}"})
    org
  end

  defp project_fixture(org) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Project{
      org_id: org.id,
      name: "Project #{n}",
      slug: "project-#{n}",
      salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id)
    })
  end
end
