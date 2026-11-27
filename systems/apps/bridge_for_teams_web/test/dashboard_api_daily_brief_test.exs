defmodule BridgeForTeamsWeb.DashboardAPIDailyBriefTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Memberships, Repo}

  defmodule FakeSalix do
    def daily_brief_channels(request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:channels, request})

      {:ok,
       %{
         complete?: true,
         channels: [%{id: "oc_sales", name: "销售"}, %{id: "oc_all", name: "全员"}],
         gaps: %{}
       }}
    end
  end

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

  test "an owner picks a Feishu bot and its group by name; members are Feishu's", ctx do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)
    on_exit(fn -> SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous) end)

    Repo.update_all(from(o in BridgeForTeams.Schema.Organization, where: o.id == ^ctx.org.id),
      set: [salix_tenant_id: "ten-web"]
    )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^ctx.project.id),
      set: [salix_group_id: "grp-web"]
    )

    channels =
      build_conn()
      |> log_in_user(ctx.owner)
      |> get("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/channels", %{
        "project_id" => ctx.project.id,
        "provider" => "feishu",
        "connect_id" => "cnx_feishu"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert channels == %{
             "channels" => [
               %{"id" => "oc_all", "name" => "全员"},
               %{"id" => "oc_sales", "name" => "销售"}
             ],
             "complete" => true
           }

    assert_received {:channels,
                     %{provider: "feishu", connect_id: "cnx_feishu", group_id: "grp-web"}}

    saved =
      build_conn()
      |> log_in_user(ctx.owner)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings", %{
        "project_id" => ctx.project.id,
        "provider" => "feishu",
        "connect_id" => "cnx_feishu",
        "team_channel_id" => "oc_sales",
        "enabled" => true
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert %{"provider" => "feishu", "connect_id" => "cnx_feishu", "slack_connect_id" => nil} =
             saved

    # A Slack channel is not a Feishu group.
    conn =
      build_conn()
      |> log_in_user(ctx.owner)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings", %{
        "team_channel_id" => "CTEAM1"
      })

    assert %{"fields" => ["team_channel_id"]} = json_response(conn, 422)["error"]["details"]

    {:ok, _slack} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: ctx.member.id,
        slack_workspace_id: "T1",
        slack_user_id: "UMEMBER1"
      })

    {:ok, feishu} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: ctx.member.id,
        provider: "feishu",
        app_id: "cli_app",
        open_id: "ou_member"
      })

    overview =
      build_conn()
      |> log_in_user(ctx.owner)
      |> get("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief")
      |> json_response(200)
      |> Map.fetch!("data")

    assert [%{"id" => id, "provider" => "feishu", "provider_user_id" => "ou_member"}] =
             overview["members"]

    assert id == feishu.id
    assert overview["settings"]["team_channel_id"] == "oc_sales"
  end

  test "each Swarm's page shows its own settings; an owner moves a member's brief", ctx do
    second = bare_project_fixture(ctx.org)

    for {project, connect} <- [{ctx.project, "imc_one"}, {second, "imc_two"}] do
      build_conn()
      |> log_in_user(ctx.owner)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/settings", %{
        "project_id" => project.id,
        "slack_connect_id" => connect,
        "enabled" => true
      })
      |> json_response(200)
    end

    {:ok, brief_member} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: ctx.member.id,
        slack_workspace_id: "T1",
        slack_user_id: "UMEMBER1",
        project_id: ctx.project.id
      })

    overview = fn query ->
      build_conn()
      |> log_in_user(ctx.owner)
      |> get("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief", query)
      |> json_response(200)
      |> Map.fetch!("data")
    end

    # The first Swarm sent the member's brief.
    Repo.insert!(%BridgeForTeams.Schema.DailyBriefRun{
      org_id: ctx.org.id,
      project_id: ctx.project.id,
      member_id: brief_member.id,
      kind: "personal_brief",
      status: "completed",
      window_after: SystemsClock.utc_now() |> DateTime.add(-86_400),
      window_before: SystemsClock.utc_now()
    })

    assert overview.(%{})["settings"]["slack_connect_id"] == "imc_one"
    two = overview.(%{"project_id" => second.id})
    # Its last brief shows on every Swarm's page.
    assert [%{"last_brief_at" => last}] = two["members"]
    assert last
    assert two["settings"]["slack_connect_id"] == "imc_two"

    assert Enum.map(two["configured_projects"], & &1["project_id"]) == [
             ctx.project.id,
             second.id
           ]

    assert [%{"id" => id, "project_id" => project_id}] = two["members"]
    assert {id, project_id} == {brief_member.id, ctx.project.id}

    move = fn user, project_id ->
      build_conn()
      |> log_in_user(user)
      |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/daily-brief/members/#{id}", %{
        "project_id" => project_id
      })
    end

    assert %{"project_id" => moved} = json_response(move.(ctx.owner, second.id), 200)["data"]
    assert moved == second.id
    assert move.(ctx.member, ctx.project.id).status in [403, 404]

    # A Swarm without settings cannot send it.
    third = bare_project_fixture(ctx.org)
    assert json_response(move.(ctx.owner, third.id), 422)
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
