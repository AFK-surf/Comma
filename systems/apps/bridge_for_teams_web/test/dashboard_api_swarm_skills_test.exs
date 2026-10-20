defmodule BridgeForTeamsWeb.DashboardAPISwarmSkillsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Skills API behind the React Agent Swarm Skills page, against the real
  Salix skill catalog: the custom and system skills of the swarm's Router,
  creating a skill, uploading a `SKILL.md` with the LiveView upload's type and
  size limits, and deleting a custom skill, including one another Agent
  created. Swarm admins write; a swarm member's delete is refused with a
  denied audit; someone outside the swarm gets 404. A Salix outage leaves the
  page readable.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Memberships, Observability, Skills}
  alias BridgeForTeams.TestSupport.CanonicalAgentClient
  alias SalixAgent.{AgentRuntimeConfig, SkillStore}

  # Salix answers the agent list but not the skill catalog.
  defmodule CatalogDownClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc
    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def create_agent_skill(_agent_id, _tenant_id, _attrs), do: {:error, :timeout}
  end

  # A group without agents, and a catalog whose miniskills overflow the budget.
  defmodule NoAgentsClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def page_group_agents(_tenant_id, _group_id, _opts),
      do: {:ok, %{items: [], next_cursor: nil}}
  end

  defmodule OverBudgetClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc

    def list_agent_skills(_agent_id, _tenant_id),
      do: {:ok, %{"skills" => [], "miniskill_status" => "catalog_over_budget"}}
  end

  @skill_md """
  ---
  name: Weekly recap
  description: Use for weekly summaries.
  ---

  Summarize the week.
  """

  setup %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Skills swarm",
        "slug" => "skills-swarm"
      })

    %{conn: conn, user: user, org: org, project: project}
  end

  describe "page" do
    test "lists the Router's custom and system skills with the upload limits", %{
      conn: conn,
      org: org,
      project: project
    } do
      data = conn |> get(skills_path(org, project)) |> json_response(200) |> data()

      {:ok, %{"router_agent_id" => router}} = Salix.Control.Groups.get(project.salix_group_id)

      assert data["project"] == %{"id" => project.id, "name" => "Skills swarm", "role" => "admin"}
      assert data["status"] == "ok"
      assert %{"id" => ^router, "name" => name} = data["agent"]
      assert is_binary(name)
      assert data["custom"] == []
      assert is_list(data["system"])
      assert Enum.all?(data["system"], &(&1["deletable"] == false))
      assert data["limits"] == %{"max_bytes" => 200_000, "extensions" => [".md", ".markdown"]}
      assert data["agents_href"] == "/orgs/#{org.slug}/projects/#{project.id}/agents"
    end

    test "costs the same queries however many skills the catalog holds", %{
      conn: conn,
      org: org,
      project: project
    } do
      create(conn, org, project, %{"name" => "First"})
      small = query_count(conn, skills_path(org, project))

      for index <- 1..5, do: create(conn, org, project, %{"name" => "More #{index}"})

      data = conn |> get(skills_path(org, project)) |> json_response(200) |> data()
      assert length(data["custom"]) == 6
      assert query_count(conn, skills_path(org, project)) == small
    end

    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn()
               |> log_in_user(plain)
               |> get(skills_path(org, project))
               |> json_response(404)

      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(user_fixture())
               |> post(skills_path(org, project), %{"name" => "Recap"})
               |> json_response(404)
    end
  end

  describe "detail" do
    test "returns one custom or system skill with its content, as the list describes it", %{
      conn: conn,
      org: org,
      project: project
    } do
      create(conn, org, project, %{"name" => "Recap", "instructions" => "Summarize it."})
      data = conn |> get(skills_path(org, project)) |> json_response(200) |> data()

      for listed <- [hd(data["custom"]) | Enum.take(data["system"], 1)] do
        assert %{"skill" => %{"content" => content} = skill} =
                 conn
                 |> get(skills_path(org, project, "/#{listed["id"]}"))
                 |> json_response(200)
                 |> data()

        assert is_binary(content) and content != ""
        # The same fields as the list, deletable included.
        assert Map.delete(skill, "content") == listed
      end

      {member_conn, _member} = member_conn(org, project)

      assert %{"skill" => %{"id" => "recap", "content" => content}} =
               member_conn
               |> get(skills_path(org, project, "/recap"))
               |> json_response(200)
               |> data()

      assert content =~ "Summarize it."
    end

    test "an unknown skill, or one of another swarm, answers 404", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, other} =
        CanonicalAgentClient.create_provisioned_project(org.id, %{
          "name" => "Other swarm",
          "slug" => "other-swarm"
        })

      create(conn, org, other, %{"name" => "Elsewhere"})

      assert %{"skill" => %{"id" => "elsewhere"}} =
               conn |> get(skills_path(org, other, "/elsewhere")) |> json_response(200) |> data()

      for id <- ["missing", "elsewhere"] do
        assert %{"error" => %{"code" => "skill_not_found", "message" => "Skill not found."}} =
                 conn |> get(skills_path(org, project, "/#{id}")) |> json_response(404)
      end
    end
  end

  describe "create" do
    test "an admin creates a skill the Router lists as a deletable custom skill", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{"notice" => "Skill created."} =
               conn
               |> post(skills_path(org, project), %{
                 "name" => "Release Checklist",
                 "description" => "Use before every release.",
                 "instructions" => "Check the changelog.",
                 "activation" => "regular"
               })
               |> json_response(201)
               |> data()

      data = conn |> get(skills_path(org, project)) |> json_response(200) |> data()

      assert [skill] = data["custom"]

      assert %{
               "id" => "release-checklist",
               "name" => "Release Checklist",
               "description" => "Use before every release.",
               "activation" => "regular",
               "deletable" => true,
               "location" => location
             } = skill

      assert location == Skills.runtime_location("release-checklist")
      # The list carries metadata only; the skill's own read has its content.
      refute Map.has_key?(skill, "content")

      assert %{"skill" => %{"content" => content}} =
               conn
               |> get(skills_path(org, project, "/release-checklist"))
               |> json_response(200)
               |> data()

      assert content =~ "Check the changelog."
    end
  end

  describe "upload" do
    test "stores a SKILL.md verbatim under its frontmatter name", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{"notice" => "Skill uploaded."} =
               conn
               |> post(skills_path(org, project, "/upload"), %{
                 "filename" => "recap.MD",
                 "content" => @skill_md
               })
               |> json_response(201)
               |> data()

      data = conn |> get(skills_path(org, project)) |> json_response(200) |> data()

      assert [%{"id" => "weekly-recap", "name" => "Weekly recap"}] = data["custom"]

      assert %{"skill" => %{"content" => content}} =
               conn
               |> get(skills_path(org, project, "/weekly-recap"))
               |> json_response(200)
               |> data()

      assert content =~ "Summarize the week."
    end
  end

  describe "delete" do
    test "an admin deletes a custom skill with an audit", %{
      conn: conn,
      org: org,
      project: project
    } do
      create(conn, org, project, %{"name" => "Recap"})

      assert %{"notice" => "Skill deleted."} =
               conn |> delete(skills_path(org, project, "/recap")) |> json_response(200) |> data()

      assert %{"custom" => []} =
               conn |> get(skills_path(org, project)) |> json_response(200) |> data()

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "skill.group.deleted", result: "ok")

      assert audit.resource_id == "recap"

      assert %{"error" => %{"code" => "skill_not_found", "message" => "Skill not found."}} =
               conn |> delete(skills_path(org, project, "/recap")) |> json_response(404)
    end
  end

  describe "authorization" do
    test "a swarm member reads the page; writes are refused and a delete is audited", %{
      conn: conn,
      org: org,
      project: project
    } do
      create(conn, org, project, %{"name" => "Recap"})
      {member_conn, member} = member_conn(org, project)

      data = member_conn |> get(skills_path(org, project)) |> json_response(200) |> data()
      assert data["project"]["role"] == "user"
      assert [%{"id" => "recap", "deletable" => true}] = data["custom"]

      for {method, path, body} <- [
            {:post, skills_path(org, project), %{"name" => "Forged"}},
            {:post, skills_path(org, project, "/upload"),
             %{"filename" => "SKILL.md", "content" => @skill_md}},
            {:delete, skills_path(org, project, "/recap"), %{}}
          ] do
        assert %{
                 "error" => %{
                   "code" => "forbidden",
                   "message" => "Only Agent Swarm admins can manage skills."
                 }
               } = member_conn |> dispatch(@endpoint, method, path, body) |> json_response(403)
      end

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "skill.group.deleted",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
      assert audit.metadata["location_configured"] in [true, "true"]
      assert audit.metadata["surface"] == "skills"

      assert %{"custom" => [%{"id" => "recap"}]} =
               conn |> get(skills_path(org, project)) |> json_response(200) |> data()
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      conn = get(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/skills")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn ->
        post(conn, skills_path(org, project), %{"name" => "No token"})
      end)

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(skills_path(org, project), %{"name" => "With token"})
               |> json_response(201)
    end
  end

  defp create(conn, org, project, body) do
    conn |> post(skills_path(org, project), body) |> json_response(201)
  end

  defp skills_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/skills#{rest}"

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "swarm-skills-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
