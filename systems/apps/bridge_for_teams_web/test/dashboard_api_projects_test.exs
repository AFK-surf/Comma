defmodule BridgeForTeamsWeb.DashboardAPIProjectsTest do
  @moduledoc """
  The Agent Swarms API behind the React list at `/orgs/:org/projects`: the
  paged and filtered list of visible Agent Swarms, creation with field errors
  and its audit, the one-Agent-Swarm rule for ordinary members with the denied
  audit, CSRF protection, and a fixed query count per page.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Observability, Projects}

  setup :register_and_log_in_user

  describe "GET /dashboard/api/v1/orgs/:org/projects" do
    test "lists Agent Swarms with slug, runtime id, status and creation time",
         %{conn: conn, org: org} do
      assert %{"projects" => [], "next_cursor" => nil, "viewer" => %{"can_create" => true}} =
               conn |> get(projects_path(org)) |> json_response(200) |> data()

      {:ok, project} =
        Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

      assert %{"projects" => [listed]} =
               conn |> get(projects_path(org)) |> json_response(200) |> data()

      assert listed["id"] == project.id
      assert listed["name"] == "Billing"
      assert listed["slug"] == "billing"
      assert listed["status"] == "active"
      assert listed["salix_group_id"] == project.salix_group_id
      assert SalixStore.Ids.valid_group_id?(listed["salix_group_id"])
      assert is_binary(listed["created_at"])
    end

    test "filters by name, slug or runtime id", %{conn: conn, org: org} do
      {:ok, billing} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "pay"})
      {:ok, _} = Projects.create_project(org.id, %{"name" => "Analytics", "slug" => "analytics"})

      names = fn query ->
        conn
        |> get(projects_path(org), %{"query" => query})
        |> json_response(200)
        |> data()
        |> Map.fetch!("projects")
        |> Enum.map(& &1["name"])
      end

      assert names.("analy") == ["Analytics"]
      assert names.("PAY") == ["Billing"]
      assert names.(billing.salix_group_id) == ["Billing"]
      # LIKE wildcards are literal characters.
      assert names.("%") == []
    end

    test "pages 50 Agent Swarms at a time in a fixed number of queries",
         %{conn: conn, org: org} do
      bare_project_fixture(org, %{name: "Swarm 00"})
      small = query_count(conn, projects_path(org))

      for n <- 1..54, do: bare_project_fixture(org, %{name: "Swarm #{pad(n)}"})

      assert query_count(conn, projects_path(org)) == small

      first = conn |> get(projects_path(org)) |> json_response(200) |> data()
      assert length(first["projects"]) == 50
      assert List.last(first["projects"])["name"] == "Swarm 49"

      second =
        conn
        |> get(projects_path(org), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> data()

      assert Enum.map(second["projects"], & &1["name"]) ==
               Enum.map(50..54, &"Swarm #{pad(&1)}")

      assert second["next_cursor"] == nil
    end

    test "pages a filtered list across two Agent Swarms with the same name",
         %{conn: conn, org: org} do
      for n <- 1..49, do: bare_project_fixture(org, %{name: "Match #{pad(n)}"})
      twins = for _ <- 1..2, do: bare_project_fixture(org, %{name: "Match twin"})
      for n <- 1..3, do: bare_project_fixture(org, %{name: "Other #{n}"})

      page = fn params ->
        conn |> get(projects_path(org), params) |> json_response(200) |> data()
      end

      first = page.(%{"query" => "match"})
      assert length(first["projects"]) == 50
      assert List.last(first["projects"])["name"] == "Match twin"

      second = page.(%{"query" => "match", "cursor" => first["next_cursor"]})
      assert [%{"name" => "Match twin"}] = second["projects"]
      assert second["next_cursor"] == nil

      assert Enum.sort([
               List.last(first["projects"])["id"] | Enum.map(second["projects"], & &1["id"])
             ]) ==
               twins |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "ordinary members see only the Agent Swarms granted to them", %{org: org} do
      member = add_member(org)

      {:ok, visible} =
        Projects.create_project(org.id, %{"name" => "Visible", "slug" => "visible"},
          creator_user_id: member.id
        )

      {:ok, _hidden} = Projects.create_project(org.id, %{"name" => "Hidden", "slug" => "hidden"})

      assert %{"projects" => [%{"id" => id}], "viewer" => %{"can_create" => false}} =
               build_conn()
               |> log_in_user(member)
               |> get(projects_path(org))
               |> json_response(200)
               |> data()

      assert id == visible.id
    end

    test "answers 404 to a non-member", %{org: org} do
      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(user_fixture())
               |> get(projects_path(org))
               |> json_response(404)
    end
  end

  describe "POST /dashboard/api/v1/orgs/:org/projects" do
    test "creates an Agent Swarm, grants the creator admin access and audits it",
         %{conn: conn, org: org, user: user} do
      assert %{"id" => id, "name" => "Payments", "slug" => "payments"} =
               conn
               |> post(projects_path(org), %{
                 "name" => "Payments",
                 "slug" => "payments",
                 "status" => "archived",
                 "created_by_user_id" => Ecto.UUID.generate()
               })
               |> json_response(201)
               |> data()

      assert [project] = Projects.list_projects(org.id)
      assert project.id == id
      assert project.status == "active"
      assert project.created_by_user_id == user.id
      assert SalixStore.Ids.valid_group_id?(project.salix_group_id)
      assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.created")
      assert audit.actor_user_id == user.id
      assert audit.resource_id == project.id
      assert audit.resource_label == "Payments"
      assert is_binary(audit.request_id) and audit.request_id != ""
    end

    test "a blank slug follows the name", %{conn: conn, org: org} do
      assert %{"slug" => "release-notes"} =
               conn
               |> post(projects_path(org), %{"name" => "Release Notes", "slug" => ""})
               |> json_response(201)
               |> data()
    end

    test "reports field errors without creating anything", %{conn: conn, org: org} do
      {:ok, _} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

      assert %{"code" => "invalid_project", "details" => %{"fields" => fields}} =
               conn
               |> post(projects_path(org), %{"name" => "Billing 2", "slug" => "billing"})
               |> json_response(422)
               |> Map.fetch!("error")

      assert fields["slug"] == ["has already been taken"]

      assert %{"details" => %{"fields" => %{"name" => ["can't be blank"]}}} =
               conn
               |> post(projects_path(org), %{"name" => "", "slug" => ""})
               |> json_response(422)
               |> Map.fetch!("error")

      assert [_only] = Projects.list_projects(org.id)
    end

    test "an ordinary member creates one Agent Swarm, then is refused with an audit",
         %{org: org} do
      member = add_member(org)
      member_conn = log_in_user(build_conn(), member)

      assert %{"name" => "Mine"} =
               member_conn
               |> post(projects_path(org), %{"name" => "Mine", "slug" => "mine"})
               |> json_response(201)
               |> data()

      assert %{"viewer" => %{"can_create" => false}} =
               member_conn |> get(projects_path(org)) |> json_response(200) |> data()

      assert %{"error" => %{"code" => "project_quota_reached", "message" => message}} =
               member_conn
               |> post(projects_path(org), %{"name" => "Forged", "slug" => "forged"})
               |> json_response(403)

      assert message =~ "only one Agent Swarm"
      assert [%{name: "Mine"}] = Projects.list_projects(org.id)

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "project.created", result: "denied")

      assert audit.actor_user_id == member.id
      assert audit.reason_class == "project_quota_reached"
      assert audit.metadata["attempted_name_configured"] in [true, "true"]
      assert audit.metadata["surface"] == "project_index"
      refute inspect(audit) =~ "orged"
    end

    test "answers 404 to a non-member", %{org: org} do
      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(user_fixture())
               |> post(projects_path(org), %{"name" => "Outsider"})
               |> json_response(404)

      assert Projects.list_projects(org.id) == []
    end

    test "needs the page's CSRF token", %{conn: conn, org: org} do
      conn = get(conn, ~p"/orgs/#{org.slug}/projects")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn -> post(conn, projects_path(org), %{"name" => "No token"}) end)
      assert Projects.list_projects(org.id) == []

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(projects_path(org), %{"name" => "With token"})
               |> json_response(201)
    end
  end

  defp projects_path(org), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/projects"
  defp data(%{"data" => data}), do: data
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp add_member(org) do
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    user
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "projects-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
