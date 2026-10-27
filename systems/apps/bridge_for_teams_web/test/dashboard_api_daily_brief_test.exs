defmodule BridgeForTeamsWeb.DashboardAPIDailyBriefTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{DailyBrief, Memberships}

  setup do
    %{org: org, user: owner} = org_with_owner_fixture()
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    project = bare_project_fixture(org)
    %{org: org, owner: owner, member: member, project: project}
  end

  test "an owner saves settings and reads the overview", ctx do
    conn =
      build_conn()
      |> log_in_user(ctx.owner)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings", %{
        "project_id" => ctx.project.id,
        "slack_connect_id" => "imc_brief",
        "enabled" => true,
        "team_names" => "hidden"
      })

    assert %{"team_names" => "hidden", "enabled" => true} = json_response(conn, 200)["data"]

    again = fn extra ->
      build_conn()
      |> log_in_user(ctx.owner)
      |> put(
        "/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings",
        Map.merge(%{"enabled" => true}, extra)
      )
      |> json_response(200)
      |> Map.fetch!("data")
    end

    # The calendar: days off and make-up workdays, as days.
    assert %{"off_days" => ["2026-10-01", "2026-10-02"], "work_days" => ["2026-10-10"]} =
             again.(%{"off_days" => ["2026-10-02", "2026-10-01"], "work_days" => ["2026-10-10"]})

    conn =
      build_conn()
      |> log_in_user(ctx.owner)
      |> get("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief")

    data = json_response(conn, 200)["data"]
    assert data["settings"]["slack_connect_id"] == "imc_brief"
    assert data["members"] == []
    assert %{"sent" => 0, "team_pass" => nil, "next_brief_at" => nil} = data["today"]
    assert data["runs"] == []
  end

  test "an owner asks for one member's brief now; only members of the org", ctx do
    {:ok, _} =
      DailyBrief.put_settings(ctx.org.id, %{
        project_id: ctx.project.id,
        slack_connect_id: "imc_brief",
        enabled: true
      })

    {:ok, brief_member} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: ctx.member.id,
        slack_workspace_id: "T1",
        slack_user_id: "UMEMBER1"
      })

    send = fn user, id ->
      build_conn()
      |> log_in_user(user)
      |> post("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/members/#{id}/send")
    end

    assert %{"requested_at" => at} = json_response(send.(ctx.owner, brief_member.id), 200)["data"]
    assert at
    assert send.(ctx.member, brief_member.id).status in [403, 404]

    %{org: other} = org_with_owner_fixture()
    stranger = user_fixture()
    {:ok, _} = Memberships.put_org_member(other.id, stranger.id, "member")

    {:ok, foreign} =
      DailyBrief.put_member(%{
        org_id: other.id,
        user_id: stranger.id,
        slack_workspace_id: "T2",
        slack_user_id: "USTRANGER"
      })

    assert json_response(send.(ctx.owner, foreign.id), 404)
    assert json_response(send.(ctx.owner, "not-a-uuid"), 404)
  end

  test "a project from another organization is refused", ctx do
    other = org_fixture()
    foreign = bare_project_fixture(other)

    conn =
      build_conn()
      |> log_in_user(ctx.owner)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings", %{
        "project_id" => foreign.id,
        "slack_connect_id" => "imc"
      })

    assert json_response(conn, 422)
  end

  test "a member cannot read settings", ctx do
    conn =
      build_conn()
      |> log_in_user(ctx.member)
      |> get("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief")

    assert conn.status in [403, 404]
  end
end
