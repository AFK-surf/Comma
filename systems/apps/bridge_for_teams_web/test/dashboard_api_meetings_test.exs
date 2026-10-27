defmodule BridgeForTeamsWeb.DashboardAPIMeetingsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Meetings API behind the React pages at `/orgs/:org/meetings`,
  `/meetings/past` and `/meetings/settings`, through the real Salix meeting
  binding with local Slack, Composio and Google Calendar fixtures: saving and
  pausing team preparation, the attendee DM permission rule, recurring series,
  history links and its fail-closed channel rule, owner/admin access, CSRF,
  and query counts that do not grow with the history page.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{MeetingPreparation, Memberships}
  alias BridgeForTeamsWeb.MeetingPreparationFixture
  alias SalixWeb.Test.MeetingPreparationProvider, as: Provider

  setup :register_and_log_in_user

  setup %{org: org} do
    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_store, :composio_base_url_override},
            {:salix_im, :slack_api_base_url},
            {:salix_meet, :calendar_autojoin_channels}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    unless SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: start_supervised!(SalixStore.S3.Fake)

    start_supervised!(Provider)
    server = start_supervised!({Bandit, plug: Provider, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    SystemsRuntime.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_channels, [])
    project = bare_project_fixture(org, %{name: "Product team"})
    fixture = MeetingPreparationFixture.seed(org, project)

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end

      Ecto.Adapters.SQL.query!(
        SalixStore.Repo,
        "DELETE FROM meeting_calendar_settings WHERE group_id = $1",
        [project.salix_group_id]
      )
    end)

    Map.merge(fixture, %{project: project})
  end

  @product Jason.encode!(["ca-product", "product@example.test"])

  defp save_attrs(connect_id, overrides \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "connect_id" => connect_id,
        "channel_id" => "C-TEAM",
        "calendar_selections" => [
          %{"account_id" => "ca-product", "calendar_id" => "product@example.test"},
          %{"account_id" => "ca-engineering", "calendar_id" => "engineering@example.test"}
        ],
        "preparation_lead_minutes" => 30,
        "research_enabled" => false,
        "calendar_writeback" => false,
        "autojoin" => false,
        "personal_preparation" => true
      },
      overrides
    )
  end

  describe "settings" do
    test "admin saves multiple calendars with another bot and can pause preparation",
         %{conn: conn, org: org, project: project, connect_id: connect_id} do
      second = connect_id <> "-second"
      key = SalixStore.Keys.ctl_im_connect(project.salix_group_id, connect_id)
      {:ok, original} = SalixStore.CasRecord.get(key)

      for {id, attrs} <- [
            {second, %{"app_name" => "Release Assistant", "bot_username" => "release-assistant"}},
            {connect_id <> "-pending",
             %{"app_name" => "Pending Assistant", "oauth_completed_at" => nil}},
            {connect_id <> "-incomplete",
             %{"app_name" => "Incomplete Assistant", "workspace_id" => nil}}
          ] do
        {:ok, _} =
          SalixStore.CasRecord.create(
            SalixStore.Keys.ctl_im_connect(project.salix_group_id, id),
            original |> Map.merge(attrs) |> Map.put("connect_id", id)
          )
      end

      overview = conn |> get(meetings_path(org, project)) |> json_response(200) |> data()
      assert overview["settings"]["enabled"] == false
      assert overview["runtime_enabled"] == false
      bots = Map.new(overview["connects"], &{&1["app_name"], &1})

      assert %{
               "bot_username" => "release-assistant",
               "workspace_name" => "Local test workspace",
               "state" => "connected",
               "preparation" => "not_configured"
             } = bots["Release Assistant"]

      assert bots["Pending Assistant"]["state"] == "unconnected"
      assert bots["Incomplete Assistant"]["state"] == "unavailable"
      # Connection internals stay out of the page payload.
      refute Map.has_key?(bots["Release Assistant"], "workspace_id")

      catalog =
        conn
        |> get(meetings_path(org, project, "/catalog?connect_id=#{second}"))
        |> json_response(200)
        |> data()

      assert Enum.map(catalog["calendars"], & &1["name"]) |> Enum.sort() ==
               ["Engineering calendar", "Product calendar"]

      assert [%{"id" => "C-TEAM", "name" => "team-meetings"}] = catalog["channels"]

      assert %{"settings" => %{"enabled" => true}} =
               conn
               |> put(meetings_path(org, project, "/settings"), save_attrs(second))
               |> json_response(200)
               |> data()

      assert {:ok, settings} = SalixStore.MeetingCalendarSettings.get(project.salix_group_id)
      assert settings["connect_id"] == second
      assert length(settings["calendar_selections"]) == 2
      assert settings["preparation_lead_minutes"] == 30
      assert settings["research_enabled"] == false
      assert settings["mode"] == "prepare"
      assert settings["personal_preparation"] == true

      overview = conn |> get(meetings_path(org, project)) |> json_response(200) |> data()
      assert %{"enabled" => true, "channel" => "team-meetings"} = overview["settings"]

      assert Enum.find(overview["connects"], &(&1["connect_id"] == second))["preparation"] ==
               "enabled"

      conn
      |> put(
        meetings_path(org, project, "/settings"),
        save_attrs(second, %{"personal_preparation" => false})
      )
      |> json_response(200)

      assert {:ok, %{"personal_preparation" => false}} =
               SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

      # Turning off the channel notice keeps joining and drops calendar writeback.
      conn
      |> put(
        meetings_path(org, project, "/settings"),
        save_attrs(second, %{
          "personal_preparation" => false,
          "channel_notice" => false,
          "calendar_writeback" => true,
          "autojoin" => true
        })
      )
      |> json_response(200)

      assert {:ok, %{"channel_notice" => false, "calendar_writeback" => false, "mode" => "join"}} =
               SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

      overview = conn |> get(meetings_path(org, project)) |> json_response(200) |> data()
      assert overview["settings"]["channel_notice"] == false

      # Pausing keeps every other saved choice.
      conn
      |> put(meetings_path(org, project, "/settings"), %{"enabled" => false, "connect_id" => "x"})
      |> json_response(200)

      assert {:ok, %{"enabled" => false, "connect_id" => ^second}} =
               SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

      overview = conn |> get(meetings_path(org, project)) |> json_response(200) |> data()

      assert Enum.find(overview["connects"], &(&1["connect_id"] == second))["preparation"] ==
               "paused"
    end

    test "admin picks one recurring series from the connected calendar",
         %{conn: conn, org: org, project: project, connect_id: connect_id} do
      series =
        conn
        |> get(
          meetings_path(
            org,
            project,
            "/series?account_id=ca-product&calendar_id=product@example.test"
          )
        )
        |> json_response(200)
        |> data()

      # Only meetings with a supported Google Meet link are offered.
      assert [design] = series["meetings"]

      assert %{"event_id" => "design-series", "title" => "Technical Design", "recurring" => true} =
               design

      assert Jason.encode!([design["account_id"], design["calendar_id"]]) == @product

      conn
      |> put(
        meetings_path(org, project, "/settings"),
        save_attrs(connect_id, %{
          "calendar_selections" => [
            %{"account_id" => "ca-product", "calendar_id" => "product@example.test"}
          ],
          "series" => [design],
          "personal_preparation" => false
        })
      )
      |> json_response(200)

      assert {:ok, settings} = SalixStore.MeetingCalendarSettings.get(project.salix_group_id)
      assert [%{"event_id" => "design-series", "account_id" => "ca-product"}] = settings["series"]
    end
  end

  describe "upcoming meetings" do
    defmodule Scripted do
      use BridgeForTeams.TestSupport.CanonicalAgentClient
      @moduledoc false
      def meeting_preparation(%{"action" => action}), do: Process.get({:meetings, action})
    end

    setup do
      previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, Scripted)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
          else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
      end)
    end

    test "the detail read returns the shared report", %{conn: conn, org: org, project: project} do
      Process.put({:meetings, "detail"}, {:ok, %{"report" => "Agenda", "private" => "x"}})

      assert %{"report" => "Agenda"} ==
               conn
               |> get(meetings_path(org, project, "/detail?plan=mp-1"))
               |> json_response(200)
               |> data()
    end
  end

  describe "access" do
    test "members get the non-member 404 and cannot write",
         %{org: org, user: user, project: project} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      member = log_in_user(build_conn(), user)

      for path <- [meetings_path(org, project), meetings_path(org, project, "/history")] do
        assert %{"error" => %{"code" => "org_not_found"}} =
                 member |> get(path) |> json_response(404)
      end

      assert %{"error" => %{"code" => "org_not_found"}} =
               member
               |> put(meetings_path(org, project, "/settings"), %{"enabled" => false})
               |> json_response(404)

      assert {:error, :forbidden} =
               MeetingPreparation.run(org, user, project.id, "save", %{"enabled" => false})
    end

    test "another organization's Agent Swarm is not found", %{conn: conn, org: org} do
      foreign = bare_project_fixture(org_fixture())

      for path <- [meetings_path(org, foreign), meetings_path(org, foreign, "/history")] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 conn |> get(path) |> json_response(404)
      end
    end

    test "writes need the page's CSRF token",
         %{conn: conn, org: org, project: project, connect_id: connect_id} do
      conn = get(conn, ~p"/orgs/#{org.slug}/meetings/settings")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      attrs = save_attrs(connect_id, %{"personal_preparation" => false})

      assert_error_sent(403, fn -> put(conn, meetings_path(org, project, "/settings"), attrs) end)
      assert {:error, :not_found} = SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> put(meetings_path(org, project, "/settings"), attrs)
               |> json_response(200)
    end
  end

  describe "history" do
    test "links existing materials without content previews",
         %{conn: conn, org: org, project: project, group: group, connect_id: connect_id} do
      configure_history(group, connect_id)

      MeetingPreparationFixture.seed_record(group, connect_id, "history-a-" <> project.id, %{
        "title" =>
          ":date: *Meeting prep: Stand-up · sample meeting*\n• *Time*: 2026-08-24\n" <>
            String.duplicate("Recent Merged PRs & Highlights ", 80)
      })

      MeetingPreparationFixture.seed_record(group, connect_id, "history-b-" <> project.id, %{
        "title" =>
          "Meeting prep: No recording example Time: 2026-09-04 10:00 Open event: https://example.test/event",
        "start_at" => 1_789_600_000,
        "artifacts" => %{},
        "delivery" => %{}
      })

      MeetingPreparationFixture.seed_record(group, connect_id, "history-c-" <> project.id, %{
        "title" => "Other channel secret",
        "slack_ref" => %{"channel_id" => "CPRIVATE"}
      })

      response = conn |> get(meetings_path(org, project, "/history")) |> response(200)
      refute response =~ "Other channel secret"
      refute response =~ "Do not expose a content preview"
      refute response =~ "private-storage-key"
      refute response =~ "Recent Merged PRs"

      history = response |> Jason.decode!() |> data()
      assert history["channel"] == "team-meetings"
      assert [first, second] = history["meetings"]
      assert first["title"] == "Stand-up · sample meeting"
      assert first["recording_url"] == "https://sample.slack.com/files/UTEST/FRECORD"
      assert first["canvas_url"] == "https://sample.slack.com/docs/TTEST/FTEST"
      assert second["title"] == "No recording example"
      assert second["recording_url"] == nil
      assert second["canvas_url"] == nil
    end

    test "fails closed for private channels and unknown channel visibility",
         %{conn: conn, org: org, project: project, group: group, connect_id: connect_id} do
      configure_history(group, connect_id)
      MeetingPreparationFixture.seed_record(group, connect_id, "private-" <> project.id)

      for visibility <- [true, nil] do
        Provider.stub("POST", "/api/conversations.info", %{
          "ok" => true,
          "channel" => %{"id" => "C-TEAM", "is_member" => true, "is_private" => visibility}
        })

        response = conn |> get(meetings_path(org, project, "/history")) |> response(409)
        assert response =~ "Private channels are not shown"
        refute response =~ "FRECORD"
      end
    end

    test "pages through hidden records at a fixed query cost",
         %{conn: conn, org: org, project: project, group: group, connect_id: connect_id} do
      configure_history(group, connect_id)
      empty_cost = query_count(conn, meetings_path(org, project, "/history"))

      for number <- 1..21 do
        MeetingPreparationFixture.seed_record(
          group,
          connect_id,
          "page-#{String.pad_leading(to_string(number), 2, "0")}-#{project.id}",
          if(number <= 20, do: %{"slack_ref" => %{"channel_id" => "CPRIVATE"}}, else: %{})
        )
      end

      assert query_count(conn, meetings_path(org, project, "/history")) == empty_cost

      first = conn |> get(meetings_path(org, project, "/history")) |> json_response(200) |> data()
      assert first["meetings"] == []
      assert is_binary(first["next_cursor"])

      second =
        conn
        |> get(
          meetings_path(
            org,
            project,
            "/history?cursor=" <> URI.encode_www_form(first["next_cursor"])
          )
        )
        |> json_response(200)
        |> data()

      assert [%{"title" => "Stand-up · sample meeting"}] = second["meetings"]
      assert second["next_cursor"] == nil

      # Another Agent Swarm in the org has its own, empty history.
      other = bare_project_fixture(org, %{name: "Other team"})
      refute get(conn, meetings_path(org, other, "/history")).resp_body =~ "FRECORD"
    end

    test "omits unsafe links and tells captured but unshared audio apart",
         %{conn: conn, org: org, project: project, group: group, connect_id: connect_id} do
      configure_history(group, connect_id)

      MeetingPreparationFixture.seed_record(group, connect_id, "unsafe-" <> project.id, %{
        "delivery" => %{
          "status" => "failed_terminal",
          "published_at" => 1,
          "canvas_url" => "javascript:alert(1)",
          "artifacts" => %{"audio" => %{"permalink" => "https://slack.com.evil.test/record"}}
        }
      })

      assert %{"meetings" => [record]} =
               conn
               |> get(meetings_path(org, project, "/history"))
               |> json_response(200)
               |> data()

      assert record["recording_url"] == nil
      assert record["canvas_url"] == nil
      assert record["recording_status"] == "unavailable"
    end
  end

  defp configure_history(group, connect_id) do
    channel = %{
      "id" => "C-TEAM",
      "name" => "team-meetings",
      "is_member" => true,
      "is_private" => false
    }

    Provider.stub("POST", "/api/conversations.info", %{"ok" => true, "channel" => channel})

    {:ok, _} =
      SalixStore.MeetingCalendarSettings.put(
        group["group_id"],
        group["tenant_id"],
        %{
          "enabled" => false,
          "connect_id" => connect_id,
          "channel_id" => "C-TEAM",
          "channel" => "team-meetings",
          "calendars" => [],
          "calendar_selections" => []
        },
        fn -> :ok end
      )

    :ok = SalixStore.MeetingGroupProjections.mark_ready(%{"source" => "local-test"})
    :ok = SalixStore.MeetingGroupProjectionReadiness.refresh()
  end

  defp meetings_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/meetings/#{project.id}" <> rest

  defp data(%{"data" => data}), do: data

  # Every authenticated request touches its session's `last_seen_at`, and Ecto
  # writes that only when the clock has moved since the previous touch. The
  # driven clock may jump between two measured requests (seeding records waits
  # on clock-scoped servers), so clear the stamp first: each measured request
  # then pays the same one session write, and the counts compare the page.
  defp query_count(conn, path) do
    BridgeForTeams.Repo.update_all(BridgeForTeams.Schema.AuthSession, set: [last_seen_at: nil])
    test_pid = SystemsRuntime.Proc.self()
    handler = "meetings-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
