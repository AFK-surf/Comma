defmodule BridgeForTeamsWeb.DashboardAPIDataPolicyTest do
  @moduledoc """
  The Data policy API behind the React page at `/orgs/:org/information-flow`
  (`docs/verification.md` §3.6, §10): each write reaches Salix with the org's
  own group id, the mode goes through the group control API, the language
  write leaves the mode alone, members get the non-member 404, a Salix outage
  is said plainly, writes need the CSRF token, and a read costs the same
  queries however many Agent Swarms the org has.

  The Salix seam is scripted, so what is asserted is what crossed it. These
  swap the global `:salix_client` app env, so they run serially.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Memberships

  defmodule Client do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def ifc_overview(_tenant_id, group_id),
      do: Process.get(:ifc_overview, {:ok, overview(group_id, %{})})

    def ifc_put_scope_label(_tenant, group_id, connect_id, scope_id, attrs),
      do: called({:put_scope_label, group_id, connect_id, scope_id, attrs})

    def ifc_delete_scope_label(_tenant, group_id, connect_id, scope_id),
      do: called({:delete_scope_label, group_id, connect_id, scope_id})

    def ifc_put_tag_clearance(_tenant, group_id, connect_id, tag, user_id),
      do: called({:put_clearance, group_id, connect_id, tag, user_id})

    def ifc_delete_tag_clearance(_tenant, group_id, connect_id, tag, principal_key),
      do: called({:delete_clearance, group_id, connect_id, tag, principal_key})

    def ifc_put_placement_override(_tenant, group_id, connect_id, user_id, placement),
      do: called({:put_placement, group_id, connect_id, user_id, placement})

    # Same argument order as the behaviour and `BridgeForTeams.Salix.Erpc`.
    def update_group(group_id, tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs),
      do: called({:update_group, group_id, attrs}, {:ok, %{}})

    defp called(call, reply \\ :ok) do
      send(self(), call)
      Process.get(:ifc_write, reply)
    end

    def overview(group_id, overrides) do
      Map.merge(
        %{
          "group_id" => group_id,
          "mode" => "off",
          "language" => "zh",
          "audience_modes" => ~w(space members),
          "connects" => []
        },
        overrides
      )
    end
  end

  setup %{conn: conn} do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, Client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, org: org, user: user, project: bare_project_fixture(org, %{name: "Bridge"})}
  end

  defp connect(overrides) do
    Map.merge(
      %{
        "connect_id" => "cnx1",
        "provider" => "slack",
        "name" => "Acme",
        "available" => true,
        "truncated" => false,
        "scopes" => [],
        "clearances" => [],
        "principals" => []
      },
      overrides
    )
  end

  describe "reading" do
    test "returns each workspace's conversations, clearances and placements",
         %{conn: conn, org: org, project: project} do
      scope = %{
        "scope_id" => "C_LEGAL",
        "kind" => "room",
        "display_name" => "legal",
        "observed_at" => nil,
        "tags" => ["counsel"],
        "audience_mode" => "members",
        "sealed" => true,
        "classified" => true
      }

      Process.put(
        :ifc_overview,
        {:ok,
         Client.overview(project.salix_group_id, %{
           "mode" => "audit",
           "connects" => [
             connect(%{
               "scopes" => [scope],
               "clearances" => [%{"tag" => "counsel", "principals" => ["provider_user|cnx1|U01"]}],
               "principals" => [
                 %{
                   "user_id" => "U_GUEST",
                   "placement_observed" => "external",
                   "placement_override" => "internal"
                 }
               ]
             }),
             connect(%{"connect_id" => "cnx2", "name" => "Broken", "available" => false})
           ]
         })}
      )

      data = conn |> get(policy_path(org, project)) |> json_response(200) |> data()

      assert %{"mode" => "audit", "language" => "zh", "audience_modes" => ["space", "members"]} =
               data

      assert [acme, broken] = data["connects"]
      assert acme["scopes"] == [scope]

      assert acme["clearances"] == [
               %{"tag" => "counsel", "principals" => ["provider_user|cnx1|U01"]}
             ]

      # Provider user ids are the payload here, not something to redact.
      assert acme["principals"] == [
               %{"id" => "U_GUEST", "observed" => "external", "override" => "internal"}
             ]

      # One unavailable workspace degrades one entry, not the page.
      assert %{"name" => "Broken", "available" => false} = broken
    end

    test "a Salix outage says nothing has changed", %{conn: conn, org: org, project: project} do
      Process.put(:ifc_overview, {:error, :unavailable})

      assert %{"error" => %{"code" => "runtime_unavailable", "message" => message}} =
               conn |> get(policy_path(org, project)) |> json_response(503)

      assert message =~ "Nothing has changed"
    end

    test "another organization's Agent Swarm is not found", %{conn: conn, org: org} do
      foreign = bare_project_fixture(org_fixture())

      assert %{"error" => %{"code" => "project_not_found"}} =
               conn |> get(policy_path(org, foreign)) |> json_response(404)

      assert %{"error" => %{"code" => "project_not_found"}} =
               conn
               |> patch(policy_path(org, foreign), %{"mode" => "enforce"})
               |> json_response(404)

      refute_received {:update_group, _, _}
    end

    test "costs the same queries however many Agent Swarms the org has",
         %{conn: conn, org: org, project: project} do
      few = query_count(conn, policy_path(org, project))
      for n <- 1..20, do: bare_project_fixture(org, %{name: "Swarm #{n}"})
      assert query_count(conn, policy_path(org, project)) == few
    end
  end

  describe "who may use it" do
    test "members and non-members get the non-member 404 and write nothing",
         %{org: org, project: project} do
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      for user <- [member, user_fixture()] do
        conn = log_in_user(build_conn(), user)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 conn |> get(policy_path(org, project)) |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 conn
                 |> patch(policy_path(org, project), %{"mode" => "enforce"})
                 |> json_response(404)
      end

      refute_received {:update_group, _, _}
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      conn = get(conn, ~p"/orgs/#{org.slug}/information-flow")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn ->
        patch(conn, policy_path(org, project), %{"mode" => "enforce"})
      end)

      refute_received {:update_group, _, _}

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> patch(policy_path(org, project), %{"mode" => "audit"})
               |> json_response(200)
    end
  end

  describe "the mode and language" do
    test "enforce goes through the group control API with this org's group id",
         %{conn: conn, org: org, project: project} do
      assert %{"mode" => "off"} =
               conn
               |> patch(policy_path(org, project), %{"mode" => "enforce", "group_id" => "forged"})
               |> json_response(200)
               |> data()

      assert_received {:update_group, group_id, %{"ifc" => %{"mode" => "enforce"}}}
      assert group_id == project.salix_group_id
    end

    test "the language write leaves the mode alone", %{conn: conn, org: org, project: project} do
      conn |> patch(policy_path(org, project), %{"language" => "en"}) |> json_response(200)

      assert_received {:update_group, group_id, %{"ifc" => ifc}}
      assert ifc == %{"language" => "en"}
      assert group_id == project.salix_group_id
    end

    test "rejects an unknown mode or language before calling Salix",
         %{conn: conn, org: org, project: project} do
      for {body, message} <- [
            {%{"mode" => "loud"}, "Choose a valid mode."},
            {%{"language" => "fr"}, "Choose a valid language."},
            {%{}, "Choose a valid mode."}
          ] do
        assert %{"error" => %{"code" => "invalid_data_policy", "message" => ^message}} =
                 conn |> patch(policy_path(org, project), body) |> json_response(422)
      end

      refute_received {:update_group, _, _}
    end
  end

  describe "conversations, clearances and placements" do
    test "classifying sends the tags, audience and sealed flag as set",
         %{conn: conn, org: org, project: project} do
      conn
      |> put(connect_path(org, project, "/scopes/C_LEGAL"), %{
        "tags" => [" counsel", "board", "counsel", ""],
        "audience_mode" => "members",
        "sealed" => true
      })
      |> json_response(200)

      assert_received {:put_scope_label, group_id, "cnx1", "C_LEGAL", attrs}
      assert group_id == project.salix_group_id

      assert attrs == %{
               "tags" => ["counsel", "board"],
               "audience_mode" => "members",
               "sealed" => true
             }

      conn |> delete(connect_path(org, project, "/scopes/C_LEGAL")) |> json_response(200)
      assert_received {:delete_scope_label, ^group_id, "cnx1", "C_LEGAL"}
    end

    test "grants and withdraws one clearance", %{conn: conn, org: org, project: project} do
      conn
      |> post(connect_path(org, project, "/clearances"), %{"tag" => "counsel", "user" => "U01ABC"})
      |> json_response(200)

      assert_received {:put_clearance, group_id, "cnx1", "counsel", "U01ABC"}
      assert group_id == project.salix_group_id

      # The tag and principal travel in the JSON body, so a tag that is a dot
      # segment reaches Salix as written instead of rewriting the path.
      for tag <- ["counsel", ".", ".."] do
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(
          connect_path(org, project, "/clearances"),
          Jason.encode!(%{"tag" => tag, "principal" => "provider_user|cnx1|U01ABC"})
        )
        |> json_response(200)

        assert_received {:delete_clearance, ^group_id, "cnx1", ^tag, "provider_user|cnx1|U01ABC"}
      end
    end

    test "a blank placement drops the override", %{conn: conn, org: org, project: project} do
      for {placement, expected} <- [{"external", "external"}, {"", nil}] do
        conn
        |> put(connect_path(org, project, "/placements/U_GUEST"), %{"placement" => placement})
        |> json_response(200)

        assert_received {:put_placement, _group, "cnx1", "U_GUEST", ^expected}
      end
    end

    test "Salix's validation errors come back as messages", %{
      conn: conn,
      org: org,
      project: project
    } do
      Process.put(:ifc_write, {:error, :invalid_tag})

      assert %{"error" => %{"code" => "invalid_data_policy", "message" => message}} =
               conn
               |> post(connect_path(org, project, "/clearances"), %{
                 "tag" => "a|b",
                 "user" => "U1"
               })
               |> json_response(422)

      assert message =~ "cannot be empty or contain the | character"
    end

    test "a workspace or conversation that is gone is not found", %{
      conn: conn,
      org: org,
      project: project
    } do
      for {reason, code, text} <- [
            {:connect_not_found, "connect_not_found", "no longer part of this organization"},
            {:scope_not_found, "scope_not_found", "no longer available"}
          ] do
        Process.put(:ifc_write, {:error, reason})

        assert %{"error" => %{"code" => ^code, "message" => message}} =
                 conn
                 |> put(connect_path(org, project, "/scopes/C_GONE"), %{"tags" => ["counsel"]})
                 |> json_response(404)

        assert message =~ text
      end
    end
  end

  defp policy_path(org, project),
    do: ~p"/dashboard/api/v1/orgs/#{org.slug}/data-policy/#{project.id}"

  defp connect_path(org, project, rest),
    do: policy_path(org, project) <> "/connects/cnx1" <> rest

  defp data(%{"data" => data}), do: data

  defp query_count(conn, path) do
    test_pid = self()
    handler = "data-policy-query-count-#{System.unique_integer([:positive])}"

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
