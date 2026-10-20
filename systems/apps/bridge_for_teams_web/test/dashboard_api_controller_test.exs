defmodule BridgeForTeamsWeb.DashboardAPIControllerTest do
  require SystemsRuntime.Proc

  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Environments, Memberships, Observability}

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

  describe "GET /dashboard/api/v1/orgs/:org/health" do
    setup :register_and_log_in_user

    test "returns the org status, signal freshness and recent errors to an owner",
         %{conn: conn, org: org} do
      project = bare_project_fixture(org, %{name: "Support Desk"})
      conversation_id = SystemsRuntime.Proc.uuid()
      now = SystemsClock.utc_now()

      {:ok, runner} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "office-1",
          "name" => "office-1",
          "host_identity" => "office-1"
        })

      {:ok, delivery_failure} =
        create_event(org, %{
          project_id: project.id,
          conversation_id: conversation_id,
          domain: "conversation",
          event_type: "slack.reply_delivery_failed",
          severity: "error",
          summary: "Reply could not be posted with token xoxb-1234567890-secretvalue",
          occurred_at: DateTime.add(now, -60, :second)
        })

      {:ok, runner_failure} =
        create_event(org, %{
          runner_type: "mac_mini_provisioner",
          runner_id: runner.id,
          domain: "runner",
          event_type: "runner.install_failed",
          severity: "critical",
          summary: "Install failed",
          occurred_at: now
        })

      {:ok, _info} = create_event(org, %{domain: "device", event_type: "device.seen"})

      {:ok, _old} =
        create_event(org, %{
          domain: "integration",
          event_type: "feishu.callback_failed",
          severity: "error",
          occurred_at: DateTime.add(now, -8 * 86_400, :second)
        })

      data =
        conn
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/health")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["health"]["status"] == "critical"
      assert "Recent operational events include critical alerts." in data["health"]["reasons"]
      assert data["runners"] == %{"total" => 1, "online" => 1}
      assert data["audit_export_href"] == "/orgs/#{org.slug}/operations/audit.csv"

      assert Enum.map(data["signals"], & &1["key"]) == ~w(delivery integrations runners devices)
      signals = Map.new(data["signals"], &{&1["key"], &1})
      assert %{"status" => "unknown", "observed_at" => nil} = signals["delivery"]

      assert %{"status" => "degraded", "detail" => "Latest diagnostic: " <> _} =
               signals["integrations"]

      assert %{"status" => "ok", "detail" => "Latest heartbeat: office-1"} = signals["runners"]
      assert %{"status" => "ok", "observed_at" => observed_at} = signals["devices"]
      assert {:ok, _, 0} = DateTime.from_iso8601(observed_at)

      assert [critical, error] = data["events"]
      assert critical["id"] == runner_failure.id
      assert critical["title"] == "Runner install failed"
      assert critical["href"] == nil
      assert error["id"] == delivery_failure.id
      assert error["severity"] == "error"
      assert error["title"] == "Slack reply delivery failed"
      refute error["summary"] =~ "secretvalue"
      assert error["href"] == "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}"
    end

    test "answers 404 to members and non-members", %{org: org} do
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      outsider = user_fixture()

      for user <- [member, outsider], path <- ["health", "audit"] do
        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn()
                 |> log_in_user(user)
                 |> get("/dashboard/api/v1/orgs/#{org.slug}/#{path}")
                 |> json_response(404)
      end
    end

    test "uses the same number of queries however many facts exist", %{conn: conn, org: org} do
      _ = bare_project_fixture(org)
      small = query_count(conn, ~p"/dashboard/api/v1/orgs/#{org.slug}/health")

      for n <- 1..6 do
        project = bare_project_fixture(org)

        {:ok, _} =
          Environments.register_mac_mini_provisioner(org.id, %{
            "stable_id" => "runner-#{n}",
            "name" => "runner-#{n}",
            "host_identity" => "runner-#{n}",
            "status" => "offline"
          })

        {:ok, _} =
          create_event(org, %{project_id: project.id, domain: "device", severity: "error"})
      end

      assert query_count(conn, ~p"/dashboard/api/v1/orgs/#{org.slug}/health") == small
    end
  end

  describe "GET /dashboard/api/v1/orgs/:org/audit" do
    setup :register_and_log_in_user
  end

  describe "GET /dashboard/api/v1/orgs/:org/projects/:id/overview" do
    setup :register_and_log_in_user

    test "returns the Agent Swarm's details and usage to an org owner",
         %{conn: conn, org: org, user: user} do
      project = bare_project_fixture(org, %{name: "Support Desk"})

      {:ok, _} =
        BridgeForTeams.Repo.update(Ecto.Changeset.change(project, created_by_user_id: user.id))

      data =
        conn
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/overview")
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"id" => id, "name" => "Support Desk", "role" => "admin"} = data["project"]
      assert id == project.id
      assert data["project"]["created_by"] == user.name
      assert data["usage"]["status"] == "missing"
      assert data["recent_conversations"] == []
      assert data["agents"]["status"] in ["ok", "unavailable"]
    end

    test "hides an Agent Swarm the member has no grant for", %{org: org} do
      project = bare_project_fixture(org)
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn()
               |> log_in_user(member)
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/overview")
               |> json_response(404)
    end

    test "does not serve an Agent Swarm through another org's URL", %{conn: conn, org: org} do
      other = org_fixture()
      project = bare_project_fixture(other)

      assert %{"error" => %{"code" => "project_not_found"}} =
               conn
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/overview")
               |> json_response(404)
    end
  end

  defp overview_query_count(conn, org),
    do: query_count(conn, ~p"/dashboard/api/v1/orgs/#{org.slug}/overview")

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "dashboard-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
      count_messages(:repo_query, 0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp create_event(org, attrs) do
    %{
      org_id: org.id,
      source: "salix.conversation",
      resource_type: "conversation",
      event_type: "test.event",
      severity: "info",
      summary: "Test event"
    }
    |> Map.merge(attrs)
    |> Observability.create_event()
  end

  defp count_messages(message, count) do
    SystemsRuntime.Proc.receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end
end
