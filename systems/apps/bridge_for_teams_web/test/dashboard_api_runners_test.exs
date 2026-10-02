defmodule BridgeForTeamsWeb.DashboardAPIRunnersTest do
  @moduledoc """
  The Runners API behind the React Runners page (`/orgs/:org/fin`): the paged
  fleet with connector summaries, per-runner connector pages, the onboarding
  guide, install commands, runner key revoke/rotate, runner removal, and the
  member/admin authorization split.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Auth, Environments, MacMiniOnboarding, Memberships, Observability, Repo}
  alias BridgeForTeams.Schema.{EnvironmentProvisionRequest, MacMiniInstallCode}

  setup :register_and_log_in_user

  describe "GET /dashboard/api/v1/orgs/:org/runners" do
    test "lists runners with status, versions, capacity and connector counts",
         %{conn: conn, org: org} do
      {:ok, runner} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "lab-mac-mini",
          "name" => "Lab Mac mini",
          "status" => "online",
          "host_identity" => "lab-host",
          "os_summary" => "macOS arm64",
          "version" => "0.1.0",
          "capabilities" => %{"component_versions" => %{"salix-connect" => "2026.06.18"}},
          "capacity" => 3,
          "current_connector_count" => 1,
          "last_seen_at" => DateTime.utc_now()
        })

      project = bare_project_fixture(org)
      insert_connectors(org, project, runner, ~w(connected connected stopped))

      data = conn |> get(runners_path(org)) |> json_response(200) |> Map.fetch!("data")

      assert data["viewer"] == %{"can_manage" => true}
      assert data["total_count"] == 1
      assert data["next_cursor"] == nil
      assert data["poll_interval_ms"] == 5_000

      assert [
               %{
                 "id" => id,
                 "stable_id" => "lab-mac-mini",
                 "name" => "Lab Mac mini",
                 "effective_status" => "online",
                 "host_identity" => "lab-host",
                 "os_summary" => "macOS arm64",
                 "version" => "0.1.0",
                 "component_versions" => %{"salix-connect" => "2026.06.18"},
                 "capacity" => 3,
                 "current_connector_count" => 1,
                 "connectors" => %{"total" => 3, "by_status" => by_status},
                 "credential" => %{"active" => false, "key_id" => nil}
               }
             ] = data["runners"]

      assert id == runner.id

      assert Enum.sort_by(by_status, & &1["status"]) == [
               %{"count" => 2, "status" => "connected"},
               %{"count" => 1, "status" => "stopped"}
             ]
    end

    test "reports a stale online runner as recently lost", %{conn: conn, org: org} do
      {:ok, _} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "stale",
          "name" => "Stale",
          "status" => "online",
          "last_seen_at" => DateTime.add(DateTime.utc_now(), -90, :second)
        })

      assert [
               %{
                 "status" => "online",
                 "effective_status" => "recently_lost",
                 "last_seen_age_seconds" => age
               }
             ] =
               conn |> get(runners_path(org)) |> json_response(200) |> get_in(["data", "runners"])

      assert age >= 90
    end

    test "pages 25 runners at a time and restarts past the end", %{conn: conn, org: org} do
      for n <- 1..26 do
        register_runner(org, "paged-#{pad(n)}", "Paged #{pad(n)}")
      end

      first = conn |> get(runners_path(org)) |> json_response(200) |> Map.fetch!("data")
      assert first["total_count"] == 26
      assert length(first["runners"]) == 25
      assert hd(first["runners"])["name"] == "Paged 01"
      assert is_binary(first["next_cursor"])

      second =
        conn
        |> get(runners_path(org), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(second["runners"], & &1["name"]) == ["Paged 26"]
      assert second["cursor"] == first["next_cursor"]
      assert second["next_cursor"] == nil

      [last] = Repo.all(from_runner(org, "paged-26"))
      Repo.delete!(last)

      restarted =
        conn
        |> get(runners_path(org), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> Map.fetch!("data")

      assert restarted["cursor"] == nil
      assert hd(restarted["runners"])["name"] == "Paged 01"
    end

    test "a member sees the fleet, only granted connectors, and no credentials",
         %{org: org} do
      member = add_member(org, "member")
      runner = register_runner(org, "shared", "Shared")
      bind_runner_key(org, runner.stable_id)

      visible = bare_project_fixture(org, %{name: "Visible"})
      hidden = bare_project_fixture(org, %{name: "Hidden"})
      {:ok, _} = Memberships.put_project_member(visible.id, member.id, "user")
      [visible_connector] = insert_connectors(org, visible, runner, ~w(pending))
      _hidden = insert_connectors(org, hidden, runner, ~w(pending))

      member_conn = log_in_user(build_conn(), member)
      data = member_conn |> get(runners_path(org)) |> json_response(200) |> Map.fetch!("data")

      assert data["viewer"] == %{"can_manage" => false}

      assert [%{"connectors" => %{"total" => 1}, "credential" => nil}] = data["runners"]

      assert %{"entries" => [entry], "next_cursor" => nil} =
               member_conn
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/runners/#{runner.id}/connectors")
               |> json_response(200)
               |> Map.fetch!("data")

      assert entry["id"] == visible_connector.id
      assert entry["project_name"] == "Visible"
    end

    test "answers 404 to a non-member", %{org: org} do
      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(user_fixture())
               |> get(runners_path(org))
               |> json_response(404)
    end

    test "uses the same number of queries however many runners and connectors exist",
         %{conn: conn, org: org} do
      runner = register_runner(org, "count-0", "Count 0")
      bind_runner_key(org, runner.stable_id)
      small = query_count(conn, runners_path(org))

      project = bare_project_fixture(org)

      for n <- 1..6 do
        runner = register_runner(org, "count-#{n}", "Count #{n}")
        bind_runner_key(org, runner.stable_id)
        insert_connectors(org, project, runner, ~w(pending connected))
      end

      assert query_count(conn, runners_path(org)) == small
    end
  end

  describe "GET /dashboard/api/v1/orgs/:org/runners/:id/connectors" do
    test "pages a runner's connectors with their Agent Swarms", %{conn: conn, org: org} do
      runner = register_runner(org, "connector-runner", "Connector Runner")
      project = bare_project_fixture(org, %{name: "Support"})
      insert_connectors(org, project, runner, List.duplicate("pending", 51))

      first =
        conn |> get(connectors_path(org, runner.id)) |> json_response(200) |> Map.fetch!("data")

      assert length(first["entries"]) == 50

      assert %{
               "name" => "connector-" <> _,
               "project_id" => project_id,
               "project_name" => "Support"
             } =
               hd(first["entries"])

      assert project_id == project.id

      second =
        conn
        |> get(connectors_path(org, runner.id), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> Map.fetch!("data")

      assert length(second["entries"]) == 1
      assert second["next_cursor"] == nil
    end

    test "a malformed runner id is not found", %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "runner_not_found"}} =
               conn |> get(connectors_path(org, "nope")) |> json_response(404)
    end
  end

  describe "GET /dashboard/api/v1/orgs/:org/runners/onboarding" do
    test "returns the manual steps and the local-agent handoff without credentials",
         %{conn: conn, org: org} do
      data =
        conn
        |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/runners/onboarding")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["org_id"] == org.id
      assert data["api_base_url"] == "http://localhost:4102"
      assert data["install_code_ttl_seconds"] == 900

      assert Enum.map(data["local_steps"], &{&1["id"], &1["group"]}) == [
               {"doctor", "primary"},
               {"foreground", "primary"},
               {"launchd", "primary"},
               {"status-logs", "advanced"}
             ]

      assert hd(data["local_steps"])["command"] ==
               ~s("$HOME/.bridge-for-teams/bin/bft-runner" doctor)

      assert data["paths"]["config"] == "~/.bridge-for-teams/runner.json"
      assert data["agent_handoff"] =~ "Target organization: #{org.id}"
      assert data["agent_handoff"] =~ "create exactly one runner install command"
      assert data["agent_skill"] =~ "name: bft-operator"
      refute inspect(data) =~ "bfti_"
      assert Repo.aggregate(MacMiniInstallCode, :count, :id) == 0
    end

    test "is translated for a Chinese user", %{conn: conn, org: org, user: user} do
      {:ok, _} = BridgeForTeams.Accounts.update_locale(user, "zh_Hans")

      assert [%{"title" => "检查本机状态"} | _] =
               conn
               |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/runners/onboarding")
               |> json_response(200)
               |> get_in(["data", "local_steps"])
    end
  end

  describe "runner writes" do
    test "an install command is not created while the Server release is unavailable",
         %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "server_release_unavailable"}} =
               conn
               |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/runners/install-commands")
               |> json_response(503)

      assert Repo.aggregate(MacMiniInstallCode, :count, :id) == 0
    end

    test "revokes a runner key but not another org API key", %{conn: conn, org: org, user: user} do
      runner = register_runner(org, "lab", "Lab")
      %{token: token, api_key: api_key} = bind_runner_key(org, runner.stable_id)

      {:ok, %{token: other_token, api_key: other_key}} =
        Auth.create_api_key(org.id, %{"name" => "automation", "scopes" => ["projects:read"]})

      assert %{"error" => %{"code" => "runner_key_not_found"}} =
               conn |> delete(key_path(org, other_key.id)) |> json_response(404)

      assert {:ok, _} = Auth.authenticate_api_key(other_token)

      assert %{"data" => %{"id" => id, "revoked_at" => revoked_at}} =
               conn |> delete(key_path(org, api_key.id)) |> json_response(200)

      assert id == api_key.id
      assert is_binary(revoked_at)
      assert {:error, :unauthenticated} = Auth.authenticate_api_key(token)

      assert [audit] = Observability.list_audit_logs(org.id, action: "api_key.revoked")
      assert audit.actor_user_id == user.id

      [listed] =
        conn |> get(runners_path(org)) |> json_response(200) |> get_in(["data", "runners"])

      assert listed["credential"]["active"] == false
    end

    test "rotation revokes nothing while the Server release is unavailable",
         %{conn: conn, org: org} do
      runner = register_runner(org, "lab", "Lab")
      %{token: token, api_key: api_key} = bind_runner_key(org, runner.stable_id)

      [listed] =
        conn |> get(runners_path(org)) |> json_response(200) |> get_in(["data", "runners"])

      assert listed["credential"]["active"]
      assert listed["credential"]["key_id"] == api_key.id

      assert %{"error" => %{"code" => "server_release_unavailable"}} =
               conn
               |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/runners/keys/#{api_key.id}/rotate")
               |> json_response(503)

      assert {:ok, _} = Auth.authenticate_api_key(token)
    end

    test "reads only the active keys of the listed runners", %{conn: conn, org: org} do
      runner = register_runner(org, "lab", "Lab")
      %{api_key: old_key} = bind_runner_key(org, runner.stable_id)
      {:ok, _} = Auth.revoke_api_key(org.id, old_key.id)
      %{api_key: active_key} = bind_runner_key(org, runner.stable_id)
      bind_runner_key(org, "elsewhere")
      %{api_key: from_metadata} = bind_runner_key(org, nil, %{"runner_stable_id" => "meta"})
      %{api_key: unnamed, install_code: unnamed_code} = bind_runner_key(org, nil)
      fallback_id = "runner_" <> String.replace(unnamed_code.id, "-", "")

      listed = fn opts ->
        org.id |> MacMiniOnboarding.list_runner_credentials(opts) |> Enum.map(& &1.api_key.id)
      end

      assert listed.(stable_ids: [runner.stable_id], active_only: true) == [active_key.id]
      assert listed.(stable_ids: ["meta"]) == [from_metadata.id]
      assert listed.(stable_ids: [fallback_id]) == [unnamed.id]
      assert listed.(key_id: old_key.id) == [old_key.id]

      [listed_runner] =
        conn |> get(runners_path(org)) |> json_response(200) |> get_in(["data", "runners"])

      assert listed_runner["credential"]["key_id"] == active_key.id
    end

    test "removes a runner and revokes its key", %{conn: conn, org: org, user: user} do
      runner = register_runner(org, "lab", "Lab")
      %{token: token, api_key: api_key} = bind_runner_key(org, runner.stable_id)

      assert %{"data" => %{"id" => id}} =
               conn |> delete(runner_path(org, runner.id)) |> json_response(200)

      assert id == runner.id
      assert {:error, :not_found} = Environments.get_mac_mini_provisioner(runner.id)
      assert {:error, :unauthenticated} = Auth.authenticate_api_key(token)

      assert [audit] = Observability.list_audit_logs(org.id, action: "api_key.revoked")
      assert audit.actor_user_id == user.id
      assert audit.resource_id == api_key.id

      assert %{"error" => %{"code" => "runner_not_found"}} =
               conn |> delete(runner_path(org, runner.id)) |> json_response(404)
    end

    test "does not remove another org's runner", %{conn: conn, org: org} do
      other = org_fixture()
      runner = register_runner(other, "foreign", "Foreign")

      assert %{"error" => %{"code" => "runner_not_found"}} =
               conn |> delete(runner_path(org, runner.id)) |> json_response(404)

      assert {:ok, _} = Environments.get_mac_mini_provisioner(runner.id)
    end

    test "members cannot manage runners", %{org: org} do
      runner = register_runner(org, "lab", "Lab")
      %{token: token, api_key: api_key} = bind_runner_key(org, runner.stable_id)
      member_conn = org |> add_member("member") |> then(&log_in_user(build_conn(), &1))

      for {method, path} <- [
            {:get, ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/onboarding"},
            {:post, ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/install-commands"},
            {:delete, key_path(org, api_key.id)},
            {:post, ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/keys/#{api_key.id}/rotate"},
            {:delete, runner_path(org, runner.id)}
          ] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 member_conn |> dispatch(@endpoint, method, path, nil) |> json_response(403)
      end

      assert {:ok, _} = Auth.authenticate_api_key(token)
      assert {:ok, _} = Environments.get_mac_mini_provisioner(runner.id)
    end

    test "writes need the CSRF token", %{conn: conn, org: org} do
      runner = register_runner(org, "lab", "Lab")
      conn = get(conn, ~p"/orgs/#{org.slug}/fin")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn -> delete(conn, runner_path(org, runner.id)) end)
      assert {:ok, _} = Environments.get_mac_mini_provisioner(runner.id)

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> delete(runner_path(org, runner.id))
               |> json_response(200)
    end
  end

  defp runners_path(org), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/runners"
  defp runner_path(org, id), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/#{id}"
  defp key_path(org, id), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/keys/#{id}"

  defp connectors_path(org, id),
    do: ~p"/dashboard/api/v1/orgs/#{org.slug}/runners/#{id}/connectors"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp from_runner(org, stable_id) do
    import Ecto.Query

    from(p in BridgeForTeams.Schema.MacMiniProvisioner,
      where: p.org_id == ^org.id and p.stable_id == ^stable_id
    )
  end

  defp add_member(org, role) do
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
    user
  end

  defp register_runner(org, stable_id, name) do
    {:ok, runner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => stable_id,
        "name" => name,
        "status" => "online"
      })

    runner
  end

  defp insert_connectors(org, project, runner, statuses) do
    now = DateTime.utc_now()

    rows =
      for {status, index} <- Enum.with_index(statuses) do
        %{
          id: Ecto.UUID.generate(),
          org_id: org.id,
          project_id: project.id,
          provisioner_id: runner.id,
          salix_group_id: project.salix_group_id,
          name: "connector #{index}",
          env_alias: "connector-#{runner.stable_id}-#{index}",
          status: status,
          spec: %{},
          progress: %{},
          created_at: now,
          updated_at: now
        }
      end

    {_count, nil} = Repo.insert_all(EnvironmentProvisionRequest, rows)
    rows
  end

  defp bind_runner_key(org, stable_id, audit_metadata \\ %{}) do
    {:ok, %{token: token, api_key: api_key}} =
      Auth.create_api_key(org.id, %{"name" => "#{stable_id} key", "scopes" => ["runners:write"]})

    now = DateTime.utc_now()

    {:ok, install_code} =
      %MacMiniInstallCode{}
      |> MacMiniInstallCode.changeset(%{
        "org_id" => org.id,
        "api_key_id" => api_key.id,
        "code_hash" => Ecto.UUID.generate(),
        "server_build_id" => String.duplicate("a", 40),
        "runner_stable_id" => stable_id,
        "audit_metadata" => audit_metadata,
        "expires_at" => DateTime.add(now, 900, :second),
        "consumed_at" => now
      })
      |> Repo.insert()

    %{token: token, api_key: api_key, install_code: install_code}
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "runners-query-count-#{System.unique_integer([:positive])}"

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
