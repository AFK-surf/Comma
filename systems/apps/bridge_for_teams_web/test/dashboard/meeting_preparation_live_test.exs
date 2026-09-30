defmodule BridgeForTeamsWeb.Dashboard.MeetingPreparationLiveTest do
  use BridgeForTeamsWeb.DashboardCase, async: false
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
          do: {app, key, Application.get_env(app, key)}

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Provider)
    server = start_supervised!({Bandit, plug: Provider, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [])
    project = bare_project_fixture(org, %{name: "Product team"})
    fixture = MeetingPreparationFixture.seed(org, project)

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      Ecto.Adapters.SQL.query!(
        SalixStore.Repo,
        "DELETE FROM meeting_calendar_settings WHERE group_id = $1",
        [project.salix_group_id]
      )
    end)

    Map.merge(fixture, %{project: project})
  end

  test "admin saves multiple calendars through the real backend and can pause preparation", %{
    conn: conn,
    org: org,
    project: project,
    connect_id: connect_id
  } do
    second_connect_id = connect_id <> "-second"
    key = SalixStore.Keys.ctl_im_connect(project.salix_group_id, connect_id)
    {:ok, original} = SalixStore.CasRecord.get(key)

    {:ok, _} =
      SalixStore.CasRecord.create(
        SalixStore.Keys.ctl_im_connect(project.salix_group_id, second_connect_id),
        Map.merge(original, %{
          "connect_id" => second_connect_id,
          "app_name" => "Release Assistant",
          "bot_username" => "release-assistant"
        })
      )

    for {suffix, attrs} <- [
          {"pending", %{"app_name" => "Pending Assistant", "oauth_completed_at" => nil}},
          {"incomplete", %{"app_name" => "Incomplete Assistant", "workspace_id" => nil}}
        ] do
      id = connect_id <> "-" <> suffix

      {:ok, _} =
        SalixStore.CasRecord.create(
          SalixStore.Keys.ctl_im_connect(project.salix_group_id, id),
          original |> Map.merge(attrs) |> Map.put("connect_id", id)
        )
    end

    path = "/orgs/#{org.slug}/meetings"
    {:ok, view, _} = live(conn, path <> "/settings")
    # The overview starts a second async operation for the calendar catalog.
    render_async(view, 2_000)
    assert render_async(view, 2_000) =~ "Product calendar"
    assert render(view) =~ "Engineering calendar"
    assert render(view) =~ "Meeting Assistant"
    assert render(view) =~ "@meeting-assistant · Local test workspace"
    assert render(view) =~ "Release Assistant"
    assert render(view) =~ "@release-assistant · Local test workspace"

    assert has_element?(
             view,
             "[aria-labelledby=meeting-bot-group-connected]",
             "Release Assistant"
           )

    assert has_element?(
             view,
             "[aria-labelledby=meeting-bot-group-unconnected]",
             "Pending Assistant"
           )

    assert has_element?(
             view,
             "[aria-labelledby=meeting-bot-group-unavailable]",
             "Incomplete Assistant"
           )

    assert has_element?(
             view,
             "label",
             "Release Assistant @release-assistant · Local test workspace Preparation not configured"
           )

    view
    |> form("#meeting-preparation-form", settings: %{connect_id: second_connect_id})
    |> render_change()

    render_async(view, 2_000)
    assert has_element?(view, "input[type=radio][value='#{second_connect_id}'][checked]")

    assert has_element?(
             view,
             "label",
             "Release Assistant @release-assistant · Local test workspace Preparation not configured"
           )

    values = %{
      "connect_id" => second_connect_id,
      "calendar_keys" => [
        Jason.encode!(["ca-product", "product@example.test"]),
        Jason.encode!(["ca-engineering", "engineering@example.test"])
      ],
      "scope" => "all",
      "research" => "false",
      "lead" => "30",
      "channel_id" => "C-TEAM",
      "writeback" => "false",
      "autojoin" => "false",
      "personal_preparation" => "true"
    }

    view |> form("#meeting-preparation-form", settings: values) |> render_submit()
    render_async(view, 2_000)
    assert_patch(view, path <> "?project=" <> project.id)
    assert render_async(view, 2_000) =~ "Team preparation enabled"
    assert {:ok, settings} = SalixStore.MeetingCalendarSettings.get(project.salix_group_id)
    assert settings["connect_id"] == second_connect_id
    assert length(settings["calendar_selections"]) == 2
    assert settings["preparation_lead_minutes"] == 30
    assert settings["research_enabled"] == false
    assert settings["mode"] == "prepare"
    assert settings["personal_preparation"] == true

    # Deployment defaults can retain Slack's leading hash in the channel name.
    assert {:ok, _} =
             SalixStore.MeetingCalendarSettings.put(
               project.salix_group_id,
               org.salix_tenant_id,
               Map.put(settings, "channel", "#team-meetings"),
               fn -> :ok end
             )

    view |> element("a", "Preparation settings") |> render_click()
    render_async(view, 2_000)
    render_async(view, 2_000)

    assert view
           |> element("select[name='settings[channel_id]'] option[value='C-TEAM']")
           |> render() =~ ">#team-meetings</option>"

    assert has_element?(
             view,
             "label",
             "Release Assistant @release-assistant · Local test workspace Preparation enabled"
           )

    assert has_element?(view, "#meeting-attendee-dms[checked]")

    view
    |> form("#meeting-preparation-form",
      settings: Map.put(values, "personal_preparation", "false")
    )
    |> render_submit()

    render_async(view, 2_000)

    assert {:ok, %{"personal_preparation" => false}} =
             SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

    view |> element("a", "Preparation settings") |> render_click()
    render_async(view, 2_000)
    render_async(view, 2_000)
    refute has_element?(view, "#meeting-attendee-dms[checked]")

    view |> element("button[phx-click=disable]") |> render_click()
    render_async(view, 2_000)
    assert_patch(view, path <> "?project=" <> project.id)
    assert render_async(view, 2_000) =~ "Team preparation is not enabled"

    assert {:ok, %{"enabled" => false}} =
             SalixStore.MeetingCalendarSettings.get(project.salix_group_id)

    view |> element("a", "Preparation settings") |> render_click()
    render_async(view, 2_000)
    render_async(view, 2_000)

    assert has_element?(
             view,
             "label",
             "Release Assistant @release-assistant · Local test workspace Preparation paused"
           )
  end

  test "attendee DMs require known permissions for the selected bot", %{
    conn: conn,
    org: org,
    project: project,
    connect_id: connect_id
  } do
    key = SalixStore.Keys.ctl_im_connect(project.salix_group_id, connect_id)

    attrs = %{
      "enabled" => true,
      "connect_id" => connect_id,
      "channel_id" => "C-TEAM",
      "calendar_selections" => [
        %{"account_id" => "ca-product", "calendar_id" => "product@example.test"}
      ],
      "preparation_lead_minutes" => 10,
      "research_enabled" => true,
      "calendar_writeback" => false,
      "autojoin" => false,
      "personal_preparation" => true
    }

    for {scopes, expected, message} <- [
          {~w(chat:write), :meeting_personal_scopes_missing, "users:read.email, im:write"},
          {nil, :meeting_personal_scopes_unknown, "permissions are unknown"}
        ] do
      {:ok, _} =
        SalixStore.CasRecord.update(key, fn rec ->
          Map.put(rec, "granted_bot_scopes", scopes)
        end)

      {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/settings")
      render_async(view, 2_000)
      render_async(view, 2_000)
      assert has_element?(view, "#meeting-attendee-dms[disabled]")
      assert render(view) =~ message

      assert {:error, ^expected} =
               Salix.Bindings.MeetingPreparationDashboard.run(
                 org.salix_tenant_id,
                 project.salix_group_id,
                 "save",
                 attrs
               )

      assert {:ok, %{"personal_preparation" => false}} =
               Salix.Bindings.MeetingPreparationDashboard.run(
                 org.salix_tenant_id,
                 project.salix_group_id,
                 "save",
                 Map.put(attrs, "personal_preparation", false)
               )
    end
  end

  test "admin selects a recurring series from the connected calendar", %{
    conn: conn,
    org: org,
    project: project,
    connect_id: connect_id
  } do
    {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/settings")
    render_async(view, 2_000)
    render_async(view, 2_000)
    calendar_key = Jason.encode!(["ca-product", "product@example.test"])

    values = %{
      "connect_id" => connect_id,
      "calendar_keys" => [calendar_key],
      "scope" => "series",
      "series_calendar_key" => calendar_key,
      "research" => "true",
      "lead" => "15",
      "channel_id" => "C-TEAM"
    }

    view
    |> form("#meeting-preparation-form", settings: Map.delete(values, "series_calendar_key"))
    |> render_change()

    view |> form("#meeting-preparation-form", settings: values) |> render_change()
    view |> element("button[phx-click=browse-series]") |> render_click()
    html = render_async(view, 2_000)
    assert html =~ "Technical Design"
    refute html =~ "No supported meeting link"

    values =
      Map.put(
        values,
        "series_key",
        Jason.encode!(["ca-product", "product@example.test", "design-series"])
      )

    view |> form("#meeting-preparation-form", settings: values) |> render_submit()
    render_async(view, 2_000)
    assert_patch(view, "/orgs/#{org.slug}/meetings?project=#{project.id}")
    assert {:ok, settings} = SalixStore.MeetingCalendarSettings.get(project.salix_group_id)
    assert [%{"event_id" => "design-series", "account_id" => "ca-product"}] = settings["series"]
  end

  test "member cannot open admin settings or submit writes directly", %{
    conn: conn,
    org: org,
    user: user,
    project: project
  } do
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, user.id, "member")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             live(conn, "/orgs/#{org.slug}/meetings/settings")

    assert {:error, :forbidden} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "save", %{
               "enabled" => false
             })
  end

  test "another organization's project cannot be selected by an admin", %{org: org, user: user} do
    foreign = bare_project_fixture(org_fixture())

    assert {:error, :project_not_found} =
             BridgeForTeams.MeetingPreparation.run(org, user, foreign.id, "overview")
  end

  test "history links existing materials without content previews and preserves navigation", %{
    conn: conn,
    org: org,
    project: project,
    group: group,
    connect_id: connect_id
  } do
    configure_history(group, connect_id)

    first =
      MeetingPreparationFixture.seed_record(group, connect_id, "history-a-" <> project.id, %{
        "title" =>
          ":date: *Meeting prep: Stand-up · sample meeting*\n• *Time*: 2026-08-24\n" <>
            String.duplicate("Recent Merged PRs & Highlights ", 80)
      })

    second =
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

    {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/past?project=#{project.id}")
    html = render_async(view, 5_000)
    assert html =~ "Stand-up · sample meeting"
    refute html =~ "Other channel secret"
    refute html =~ "Do not expose a content preview"
    refute html =~ "private-storage-key"
    refute html =~ "Recent Merged PRs &amp; Highlights"
    refute has_element?(view, "#meeting-record-detail")
    view |> element("#record-#{first}") |> render_click()
    assert has_element?(view, "#meeting-record-detail [role=dialog][aria-modal=true]")

    assert has_element?(
             view,
             "a[href='https://sample.slack.com/files/UTEST/FRECORD'][target='_blank']"
           )

    assert has_element?(view, "a[href='https://sample.slack.com/docs/TTEST/FTEST']")
    view |> element("#record-#{second}") |> render_click()
    assert has_element?(view, "#meeting-record-detail", "No recording was saved")
    refute has_element?(view, "#meeting-record-detail a", "Open Canvas")
    view |> element("#record-#{first}") |> render_click()
    assert has_element?(view, "#meeting-record-detail a", "Open Canvas")
    view |> element("a", "Upcoming") |> render_click()
    render_async(view, 5_000)
    refute has_element?(view, "#meeting-history")
  end

  test "history fails closed for private channels and unknown channel visibility", %{
    conn: conn,
    org: org,
    user: user,
    group: group,
    connect_id: connect_id,
    project: project
  } do
    configure_history(group, connect_id)
    MeetingPreparationFixture.seed_record(group, connect_id, "private-" <> project.id)

    for visibility <- [true, nil] do
      Provider.stub("POST", "/api/conversations.info", %{
        "ok" => true,
        "channel" => %{
          "id" => "C-TEAM",
          "is_member" => true,
          "is_private" => visibility
        }
      })

      assert {:error, :meeting_history_scope_unavailable} =
               BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history")
    end

    {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/past")
    html = render_async(view, 5_000)
    assert html =~ "Private channels are not shown"
    refute html =~ "Stand-up · sample meeting"
    refute html =~ "FRECORD"
  end

  test "history paginates through hidden records and isolates project changes", %{
    conn: conn,
    org: org,
    group: group,
    connect_id: connect_id,
    project: project
  } do
    configure_history(group, connect_id)

    for number <- 1..21 do
      MeetingPreparationFixture.seed_record(
        group,
        connect_id,
        "page-#{String.pad_leading(to_string(number), 2, "0")}-#{project.id}",
        if(number <= 20, do: %{"slack_ref" => %{"channel_id" => "CPRIVATE"}}, else: %{})
      )
    end

    other = bare_project_fixture(org, %{name: "Other team"})
    {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/past?project=#{project.id}")
    assert render_async(view, 5_000) =~ "No shared meeting records on this page"
    view |> element("a", "Next page") |> render_click()
    assert render_async(view, 5_000) =~ "Stand-up · sample meeting"
    refute has_element?(view, "a", "Next page")
    view |> form("#meeting-preparation-project", project: other.id) |> render_change()
    assert_patch(view, "/orgs/#{org.slug}/meetings/past?project=#{other.id}")
    html = render_async(view, 5_000)
    refute html =~ "Stand-up · sample meeting"
    refute html =~ "FRECORD"
  end

  test "history distinguishes unavailable sources from empty records and rejects foreign projects",
       %{
         conn: conn,
         org: org,
         user: user,
         group: group,
         connect_id: connect_id,
         project: project
       } do
    configure_history(group, connect_id)
    foreign = bare_project_fixture(org_fixture())

    assert {:error, :project_not_found} =
             BridgeForTeams.MeetingPreparation.run(org, user, foreign.id, "history")

    assert {:error, :invalid} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history", %{
               "cursor" => String.duplicate("x", 129)
             })

    Provider.stub("POST", "/api/conversations.info", %{"ok" => false, "error" => "internal_error"})

    {:ok, view, _} = live(conn, "/orgs/#{org.slug}/meetings/past")
    html = render_async(view, 5_000)
    assert html =~ "Meeting history is unavailable"
    refute html =~ "No shared meeting records on this page"
    {:ok, _} = BridgeForTeams.Memberships.put_org_member(org.id, user.id, "member")

    assert {:error, :forbidden} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history")
  end

  test "history omits unsafe links and distinguishes captured but unshared audio", %{
    org: org,
    user: user,
    group: group,
    connect_id: connect_id,
    project: project
  } do
    configure_history(group, connect_id)

    MeetingPreparationFixture.seed_record(group, connect_id, "unsafe-" <> project.id, %{
      "delivery" => %{
        "status" => "failed_terminal",
        "published_at" => 1,
        "canvas_url" => "javascript:alert(1)",
        "artifacts" => %{"audio" => %{"permalink" => "https://slack.com.evil.test/record"}}
      }
    })

    assert {:ok, %{"meetings" => [record]}} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history")

    assert record["recording_url"] == nil
    assert record["canvas_url"] == nil
    assert record["recording_status"] == "unavailable"
  end

  test "history resolves a deployment-default channel through its existing enrollment cache", %{
    org: org,
    user: user,
    group: group,
    connect_id: connect_id,
    project: project
  } do
    configure_history(group, connect_id)

    SalixStore.Repo.query!("DELETE FROM meeting_calendar_settings WHERE group_id = $1", [
      group["group_id"]
    ])

    entry = %{
      "connect_id" => connect_id,
      "channel" => "team-meetings",
      "calendars" => ["product@example.test"]
    }

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

    identity =
      Map.merge(Map.take(group, ~w(tenant_id group_id)), %{
        "connect_id" => connect_id,
        "provider" => "slack"
      })

    enrolled =
      Map.merge(identity, %{
        "channel_id" => "C-TEAM",
        "calendar_id" => SalixStore.Ids.new_calendar_id(),
        "mode" => "join",
        "calendars" => [
          %{
            "account_id" => "ca-product",
            "calendar_id" => "product@example.test",
            "source_id" => SalixStore.Ids.new_calendar_source_id()
          }
        ]
      })

    :ok =
      SalixMeet.CalendarEnrollmentCache.put(
        entry,
        identity,
        enrolled,
        System.system_time(:millisecond)
      )

    MeetingPreparationFixture.seed_record(group, connect_id, "inherited-" <> project.id)

    assert {:ok, %{"meetings" => [_]}} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history")

    :ok = SalixMeet.CalendarEnrollmentCache.delete(entry)

    assert {:error, :meeting_history_scope_unavailable} =
             BridgeForTeams.MeetingPreparation.run(org, user, project.id, "history")
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
end
