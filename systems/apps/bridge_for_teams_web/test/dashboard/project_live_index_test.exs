defmodule BridgeForTeamsWeb.Dashboard.ProjectLiveIndexTest do
  @moduledoc """
  Tests for the projects slice: `ProjectLive.Index` at
  `/orgs/:org/projects` — renders the table/empty state, filters, and creates a
  project through the `BridgeForTeams.Projects` context (which allocates the Salix
  tenant id + enqueues reconcile).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Observability, Projects}

  setup %{conn: conn} do
    register_and_log_in_user(%{conn: conn})
  end

  test "shows empty state when the org has no projects", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    assert html =~ "No Agent Swarms yet"
    assert html =~ "New Agent Swarm"
  end

  test "lists existing projects with slug, salix tenant id and status", %{conn: conn, org: org} do
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    assert html =~ "Billing"
    assert html =~ "billing"
    assert html =~ project.salix_group_id
    assert SalixStore.Ids.valid_group_id?(project.salix_group_id)
  end

  test "search filters the project table", %{conn: conn, org: org} do
    {:ok, _} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})
    {:ok, _} = Projects.create_project(org.id, %{"name" => "Analytics", "slug" => "analytics"})

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    html =
      view
      |> form("form[phx-change=filter]", %{"query" => "analy"})
      |> render_change()

    assert html =~ "Analytics"
    refute html =~ "Billing"
  end

  test "creates a project through the modal and grants the creator admin access", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    view |> element("#new-project-button") |> render_click()
    assert render(view) =~ "New Agent Swarm"

    html =
      view
      |> form("#new-project-form", %{"project" => %{"name" => "Payments", "slug" => "payments"}})
      |> render_submit()

    assert html =~ "Payments"
    assert html =~ "created"

    assert [project] = Projects.list_projects(org.id)
    assert project.name == "Payments"
    assert SalixStore.Ids.valid_group_id?(project.salix_group_id)
    assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "project.created")
    assert audit.actor_user_id == user.id
    assert audit.resource_type == "project"
    assert audit.resource_id == project.id
    assert audit.resource_label == "Payments"
    assert is_binary(audit.request_id)
    assert audit.request_id != ""
  end

  test "new project modal cancel starts local close before LiveView event", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    html = view |> element("#new-project-button") |> render_click()

    assert html =~ "New Agent Swarm"
    assert_local_close_before_push(html, "#new-project", "cancel")
  end

  test "creating a duplicate slug surfaces the error on the slug field", %{conn: conn, org: org} do
    {:ok, _} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    view |> element("#new-project-button") |> render_click()

    html =
      view
      |> form("#new-project-form", %{"project" => %{"name" => "Billing 2", "slug" => "billing"}})
      |> render_submit()

    assert html =~ "has already been taken"
    assert [_only] = Projects.list_projects(org.id)
  end

  test "ordinary org members only see Agent Swarms granted to them", %{
    conn: conn,
    org: org
  } do
    user = user_fixture(email: "member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, visible} =
      Projects.create_project(org.id, %{"name" => "Visible", "slug" => "visible"},
        creator_user_id: user.id
      )

    {:ok, _hidden} = Projects.create_project(org.id, %{"name" => "Hidden", "slug" => "hidden"})

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/orgs/#{org.slug}/projects")

    assert html =~ "Visible"
    assert html =~ visible.salix_group_id
    refute html =~ "Hidden"
  end

  test "an ordinary org member can create their one Agent Swarm through the modal", %{
    conn: conn,
    org: org
  } do
    user = user_fixture(email: "project-create-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/orgs/#{org.slug}/projects")

    assert html =~ "New Agent Swarm"

    view |> element("#new-project-button") |> render_click()

    html =
      view
      |> form("#new-project-form", %{"project" => %{"name" => "Mine", "slug" => "mine"}})
      |> render_submit()

    assert html =~ "Mine"
    assert html =~ "created"
    # The member's one-Agent-Swarm quota is now used, so the button is gone.
    refute html =~ "New Agent Swarm"

    assert [project] = Projects.list_projects_for_user(org.id, user.id)
    assert project.created_by_user_id == user.id
    assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)
  end

  test "an ordinary org member at quota cannot create another Agent Swarm", %{
    conn: conn,
    org: org
  } do
    user = user_fixture(email: "project-quota-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, visible} =
      Projects.create_project(org.id, %{"name" => "Visible", "slug" => "visible"},
        creator_user_id: user.id
      )

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/orgs/#{org.slug}/projects")

    assert html =~ "Visible"
    refute html =~ "New Agent Swarm"

    assert render_click(view, "new") =~ "only one Agent Swarm"

    assert render_submit(view, "save", %{
             "project" => %{"name" => "Forged", "slug" => "forged"}
           }) =~ "only one Agent Swarm"

    assert [^visible] = Projects.list_projects_for_user(org.id, user.id)
    refute Enum.any?(Projects.list_projects(org.id), &(&1.slug == "forged"))

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "project.created",
               result: "denied"
             )

    assert audit.actor_user_id == user.id
    assert audit.resource_type == "project"
    assert is_nil(audit.resource_id)
    assert audit.resource_label == "Project write attempt"
    assert audit.reason_class == "project_quota_reached"
    assert audit.metadata["attempted_name_configured"] in [true, "true"]
    assert audit.metadata["attempted_slug_configured"] in [true, "true"]
    assert audit.metadata["surface"] == "project_index"
    assert is_binary(audit.request_id)
    assert audit.request_id != ""
    refute inspect(audit) =~ "Forged"
    refute inspect(audit) =~ "forged"
  end

  test "outsiders cannot open an org project list by guessing the slug", %{conn: conn, org: org} do
    outsider = user_fixture(email: "projects-outsider@example.com")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             conn
             |> log_in_user(outsider)
             |> live(~p"/orgs/#{org.slug}/projects")
  end

  test "shows validation errors for an invalid project", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects")

    view |> element("#new-project-button") |> render_click()

    html =
      view
      |> form("#new-project-form", %{"project" => %{"name" => "", "slug" => ""}})
      |> render_submit()

    assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    assert Projects.list_projects(org.id) == []
  end
end
