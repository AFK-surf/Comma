defmodule BridgeForTeamsWeb.Dashboard.DailyBriefControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{DailyBrief, Memberships, Repo}

  defmodule FakeSalix do
    def daily_brief_dm_start(_request),
      do:
        {:ok,
         %{"authorization_url" => "https://slack.test/oauth/v2/authorize", "state" => "st-1"}}

    def daily_brief_dm_result(%{state: "st-1", bft_member: member}) do
      {:ok,
       %{
         status: "completed",
         connection_id: "conn-1",
         slack_user_id: SystemsRuntime.fetch_env!(:bridge_for_teams_core, :daily_brief_slack_id),
         slack_workspace_id: "T1",
         scopes: [],
         member: member
       }}
    end

    def daily_brief_dm_result(_request), do: {:error, :not_found}

    def daily_brief_dm_delete(request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:deleted, request.connection_id})
      :ok
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_slack_id)
    end)

    %{org: org, user: owner} = org_with_owner_fixture()
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    project = bare_project_fixture(org)

    {:ok, _} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: "imc_brief",
        enabled: true
      })

    {:ok, member} =
      DailyBrief.put_member(%{
        org_id: org.id,
        user_id: user.id,
        slack_workspace_id: "T1",
        slack_user_id: "UMEMBER1"
      })

    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_slack_id, "UMEMBER1")
    %{org: org, owner: owner, user: user, member: member}
  end

  test "a member connects their own Slack and comes back with direct messages on", ctx do
    conn = build_conn() |> log_in_user(ctx.user)

    conn = get(conn, "/orgs/#{ctx.org.slug}/daily-brief/direct-messages/connect")
    assert redirected_to(conn, 302) == "https://slack.test/oauth/v2/authorize"

    conn = recycle(conn)
    conn = get(conn, "/orgs/#{ctx.org.slug}/daily-brief/direct-messages/connected")

    assert response(conn, 200) =~ "原文不保存"
    assert Repo.reload!(ctx.member).dm_status == "on"
  end

  test "the return page refuses a state that this browser did not start", ctx do
    conn =
      build_conn()
      |> log_in_user(ctx.user)
      |> get("/orgs/#{ctx.org.slug}/daily-brief/direct-messages/connected")

    assert response(conn, 400)
    assert Repo.reload!(ctx.member).dm_status == "off"
  end

  test "a member turns direct messages off and the grant is revoked", ctx do
    {:ok, _} = BridgeForTeams.DailyBrief.DirectMessages.enable(ctx.member, "conn-1")
    conn = build_conn() |> log_in_user(ctx.user)

    conn = get(conn, "/orgs/#{ctx.org.slug}/daily-brief/direct-messages/disconnect")
    assert response(conn, 200) =~ "停止读取私信"

    conn =
      conn
      |> recycle()
      |> post("/orgs/#{ctx.org.slug}/daily-brief/direct-messages/disconnect", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token()
      })

    assert response(conn, 200) =~ "Slack 授权已撤销"
    assert Repo.reload!(ctx.member).dm_status == "off"
    assert_received {:deleted, "conn-1"}
  end

  test "a user who is not a brief member cannot start", ctx do
    conn =
      build_conn()
      |> log_in_user(ctx.owner)
      |> get("/orgs/#{ctx.org.slug}/daily-brief/direct-messages/connect")

    assert response(conn, 404)
  end
end
