defmodule BridgeForTeamsWeb.DashboardAPIOnboardingTest do
  @moduledoc """
  The first-run checklist on the React Overview
  (`/dashboard/api/v1/orgs/:org/onboarding`): the steps for each role, steps
  completed by real actions (creating an Agent Swarm, saving an org OAuth
  app), the member-to-admin OAuth reminder, and skipping or acknowledging it
  for good.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Onboarding, OrgOAuthApps}

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    Onboarding.invalidate_oauth_cache(org.id)
    %{conn: conn, user: user, org: org}
  end

  test "an owner without an Agent Swarm sees the swarm step; creating one advances it",
       %{conn: conn, org: org, user: user} do
    path = onboarding_path(org)

    assert %{
             "active" => true,
             "steps" => [
               %{"id" => "swarm", "done" => false},
               %{"id" => "oauth", "done" => false},
               %{"id" => "connect", "done" => false}
             ],
             "first_project_id" => nil
           } = conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    assert %{"data" => %{"id" => project_id}} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{"name" => "Billing"})
             |> json_response(201)

    assert %{
             "active" => true,
             "steps" => [%{"id" => "swarm", "done" => true} | _],
             "first_project_id" => ^project_id
           } = conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    # Skipping ends onboarding for good.
    assert %{"active" => false} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding/dismiss")
             |> json_response(200)
             |> Map.fetch!("data")

    assert Onboarding.get_state(org.id, user.id).dismissed_at
    assert %{"active" => false} = conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  test "saving an OAuth app completes the oauth step at once", %{conn: conn, org: org} do
    path = onboarding_path(org)

    assert %{"steps" => [_swarm, %{"id" => "oauth", "done" => false}, _connect]} =
             conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    # Settings → Integrations drops the cached "no OAuth app" answer.
    assert %{"ok" => true} =
             conn
             |> put(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/integrations/oauth/github", %{
               "client_id" => "cid",
               "client_secret" => "sec"
             })
             |> json_response(200)

    assert %{
             "steps" => [_swarm, %{"id" => "oauth", "done" => true}, _connect],
             "oauth_configured" => true
           } = conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  test "a member gets the member steps; finishing them is acknowledged, not skipped",
       %{org: org} do
    member = user_fixture(%{name: "Li Na"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)
    path = onboarding_path(org)

    assert %{"steps" => [%{"id" => "swarm"}, %{"id" => "connect"}]} =
             member_conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    {:ok, _} = Onboarding.skip_step(org.id, member.id, "swarm")
    :ok = Onboarding.observe_connected(org.id, member.id)

    assert %{"active" => false} =
             member_conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding/dismiss")
             |> json_response(200)
             |> Map.fetch!("data")

    state = Onboarding.get_state(org.id, member.id)
    assert state.celebrated_at
    assert is_nil(state.dismissed_at)
  end

  test "all steps done; acknowledging it ends onboarding for good",
       %{conn: conn, org: org, user: user} do
    {:ok, intended_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Zulu", "slug" => "zulu"},
        creator_user_id: user.id
      )

    {:ok, _alphabetically_first_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Alpha",
        "slug" => "alpha"
      })

    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Onboarding.invalidate_oauth_cache(org.id)
    :ok = Onboarding.observe_connected(org.id, user.id)
    path = onboarding_path(org)

    # The checklist links to the swarm the user created, not the first by name.
    assert %{"active" => true, "first_project_id" => first_project_id, "steps" => steps} =
             conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    assert first_project_id == intended_project.id
    assert Enum.all?(steps, & &1["done"])

    assert %{"active" => false} =
             conn
             |> post(path <> "/dismiss")
             |> json_response(200)
             |> Map.fetch!("data")

    state = Onboarding.get_state(org.id, user.id)
    assert state.celebrated_at
    assert is_nil(state.dismissed_at)
  end

  test "a member blocked on OAuth reminds the admins, who see them waiting",
       %{org: org, user: owner} do
    member = user_fixture(%{name: "Li Na"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, _project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Mine", "slug" => "mine"},
        creator_user_id: member.id
      )

    path = onboarding_path(org)

    # A member with a swarm but no org OAuth client is blocked on connect.
    assert %{
             "steps" => [
               %{"id" => "swarm", "done" => true},
               %{"id" => "connect", "done" => false}
             ],
             "oauth_configured" => false,
             "oauth_reminded" => false
           } = member_conn |> get(path) |> json_response(200) |> Map.fetch!("data")

    for _twice <- 1..2 do
      assert %{"oauth_reminded" => true} =
               member_conn
               |> post(path <> "/remind-admins")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    assert [%{user: %{id: member_id}}] = Onboarding.pending_oauth_reminders(org.id)
    assert member_id == member.id

    # The admin sees the waiting member on Settings → Integrations.
    admin_conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)

    assert %{"names" => ["Li Na"], "truncated" => false} =
             admin_conn
             |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/integrations")
             |> json_response(200)
             |> get_in(["data", "oauth", "waiting_members"])

    # Admins configure OAuth themselves.
    assert %{"error" => %{"code" => "forbidden"}} =
             admin_conn |> post(path <> "/remind-admins") |> json_response(403)
  end

  defp onboarding_path(org), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/onboarding"
end
