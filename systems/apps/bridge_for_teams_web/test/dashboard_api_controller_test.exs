defmodule BridgeForTeamsWeb.DashboardAPIControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Environments, Memberships}

  describe "authentication" do
    test "rejects a request without a dashboard session", %{conn: conn} do
      conn = get(conn, ~p"/dashboard/api/v1/session")

      assert %{"ok" => false, "error" => %{"code" => "unauthenticated"}} =
               json_response(conn, 401)
    end
  end

  describe "GET /dashboard/api/v1/session" do
    setup :register_and_log_in_user

    test "returns the user and their organizations", %{conn: conn, user: user, org: org} do
      data =
        conn |> get(~p"/dashboard/api/v1/session") |> json_response(200) |> Map.fetch!("data")

      assert data["user"]["id"] == user.id
      assert data["orgs"] == [%{"slug" => org.slug, "name" => org.name}]
    end
  end

  describe "GET /dashboard/api/v1/orgs/:org/context" do
    setup :register_and_log_in_user

    test "returns the role, capabilities and visible Agent Swarms", %{conn: conn, org: org} do
      project = bare_project_fixture(org, %{name: "Support Desk"})

      data =
        conn
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/context")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["org"] == %{"slug" => org.slug, "name" => org.name, "role" => "owner"}
      assert data["capabilities"]["settings"]
      assert data["capabilities"]["operations"]
      assert data["projects"] == [%{"id" => project.id, "name" => "Support Desk"}]
    end

    test "a member gets no admin capabilities and only granted Agent Swarms", %{org: org} do
      _hidden = bare_project_fixture(org, %{name: "Hidden"})
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      data =
        build_conn()
        |> log_in_user(member)
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/context")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["org"]["role"] == "member"
      refute Enum.any?(Map.values(data["capabilities"]))
      assert data["projects"] == []
    end

    test "answers 404 for an org the user does not belong to and for an unknown slug",
         %{conn: conn} do
      other = org_fixture()

      for slug <- [other.slug, "no-such-org"] do
        assert %{"error" => %{"code" => "org_not_found"}} =
                 conn |> get(~p"/dashboard/api/v1/orgs/#{slug}/context") |> json_response(404)
      end
    end
  end

  describe "GET /dashboard/api/v1/orgs/:org/overview" do
    setup :register_and_log_in_user

    test "summarizes the org and flags offline runners", %{conn: conn, org: org} do
      _project = bare_project_fixture(org, %{name: "Support Desk"})

      {:ok, _online} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "office-1",
          "name" => "office-1",
          "host_identity" => "office-1"
        })

      {:ok, _offline} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "office-2",
          "name" => "office-2",
          "host_identity" => "office-2",
          "status" => "offline"
        })

      data =
        conn
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/overview")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["project_count"] == 1
      assert data["member_count"] == 1
      assert data["runners"] == %{"total" => 2, "online" => 1}
      assert [%{"name" => "Support Desk", "status" => status}] = data["projects"]
      assert status in ~w(ready stale refreshing missing error)

      assert [%{"severity" => "error", "title" => "Runner office-2 is offline", "href" => href}] =
               data["attention"]

      assert href == "/orgs/#{org.slug}/fin"
    end

    test "uses the org's default language when the user has none", %{conn: conn, org: org} do
      {:ok, _} = BridgeForTeams.Orgs.update_org(org, %{default_locale: "zh_Hans"})

      {:ok, _} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "office-8",
          "name" => "office-8",
          "host_identity" => "office-8",
          "status" => "offline"
        })

      assert [%{"title" => "Runner office-8 已离线"}] =
               conn
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/overview")
               |> json_response(200)
               |> get_in(["data", "attention"])
    end

    test "writes attention items in the user's dashboard language",
         %{conn: conn, org: org, user: user} do
      {:ok, _} = BridgeForTeams.Accounts.update_user(user, %{"preferred_locale" => "zh_Hans"})

      {:ok, _} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "office-9",
          "name" => "office-9",
          "host_identity" => "office-9",
          "status" => "offline"
        })

      assert [%{"title" => "Runner office-9 已离线"}] =
               conn
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/overview")
               |> json_response(200)
               |> get_in(["data", "attention"])
    end

    test "answers 404 for an org the user does not belong to", %{conn: conn} do
      other = org_fixture()

      assert conn
             |> get(~p"/dashboard/api/v1/orgs/#{other.slug}/overview")
             |> json_response(404)
    end

    test "uses the same number of queries however many Agent Swarms and runners exist",
         %{conn: conn, org: org} do
      _ = bare_project_fixture(org)
      small = overview_query_count(conn, org)

      for n <- 1..6 do
        _ = bare_project_fixture(org)

        {:ok, _} =
          Environments.register_mac_mini_provisioner(org.id, %{
            "stable_id" => "runner-#{n}",
            "name" => "runner-#{n}",
            "host_identity" => "runner-#{n}",
            "status" => "offline"
          })
      end

      assert overview_query_count(conn, org) == small
    end
  end

  defp overview_query_count(conn, org) do
    test_pid = self()
    handler = "overview-query-count-#{System.unique_integer([:positive])}"

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
      conn |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/overview") |> json_response(200)
      count_messages(:repo_query, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(message, count) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end
end
