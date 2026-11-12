defmodule Salix.Bindings.MeetingEnrollmentTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.{
    GoogleCalendarWatch,
    MeetingCalendarPolicy,
    MeetingEnrollment
  }

  alias Salix.Control.ComposioSettings
  alias SalixCalendar.Server, as: Calendar
  alias SalixMeet.CalendarEnrollmentCache
  alias SalixStore.{Ids, Keys, S3}

  @proxy_session_path "/api/v3.1/tool_router/session"
  @proxy_execute_path "/api/v3.1/tool_router/session/trs-enrollment/proxy_execute"

  alias SalixWeb.Test.MeetingPreparationProvider, as: MockExternalHTTP

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      composio_url: SystemsRuntime.get_env(:salix_store, :composio_base_url_override),
      slack_url: SystemsRuntime.get_env(:salix_im, :slack_api_base_url),
      calendar_enrollment_mod: SystemsRuntime.get_env(:salix_meet, :calendar_enrollment_mod),
      source_adapters: SystemsRuntime.get_env(:salix_calendar, :source_adapters)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    ensure_started!(MockExternalHTTP)
    port = start_bandit_retry!()
    base_url = "http://127.0.0.1:#{port}"
    SystemsRuntime.put_env(:salix_store, :composio_base_url_override, base_url)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, base_url <> "/api")

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, _} =
             SalixStore.S3.put(
               Keys.ctl_group(group_id),
               Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant_id}),
               if_none_match: "*"
             )

    assert {:ok, _settings} = ComposioSettings.put(tenant_id, %{"api_key" => "ck-test"})

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_store, :composio_base_url_override, previous.composio_url)
      restore_env(:salix_im, :slack_api_base_url, previous.slack_url)

      restore_env(
        :salix_meet,
        :calendar_enrollment_mod,
        previous.calendar_enrollment_mod
      )

      restore_env(:salix_calendar, :source_adapters, previous.source_adapters)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  test "resolves a connect entry into group, account, calendar id, and channel id", context do
    seed_connect(context, "slack-primary", "T-primary")
    # The Group's Lark bot joins the Lark meetings of a Slack destination.
    seed_lark_connect(context, "lark-primary")

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(context.group_id),
               Jason.encode!(%{
                 "group_id" => context.group_id,
                 "tenant_id" => context.tenant_id,
                 "router_conversation_id" => Ids.new_conversation_id()
               })
             )

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([
      %{"id" => "cal-comma", "summary" => "Comma Event"},
      %{"id" => "me@x", "summary" => "me@x", "primary" => true}
    ])

    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, resolved} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-primary",
               "channel" => "#botarena",
               "calendars" => ["Comma Event"]
             })

    assert resolved["tenant_id"] == context.tenant_id
    assert resolved["group_id"] == context.group_id
    assert resolved["provider"] == "slack"
    assert resolved["connect_id"] == "slack-primary"
    assert resolved["workspace_id"] == "T-primary"
    assert resolved["channel_id"] == "C0BOTARENA"
    assert Ids.valid_calendar_id?(resolved["calendar_id"])
    assert resolved["lark_join"] == %{"lark" => "lark-primary"}

    assert [
             %{
               "account_id" => "ca-cal",
               "calendar_id" => "cal-comma",
               "source_id" => source_id
             }
           ] = resolved["calendars"]

    assert Ids.valid_calendar_source_id?(source_id)

    assert {:ok,
            %{
              "active_generation" => 1,
              "sync" => %{"status" => "active", "completed_cursor" => "sync-1"}
            }} = Calendar.get_source(context.group_id, resolved["calendar_id"], source_id)
  end

  test "reports an ACTIVE Slack auto-join policy through the shared policy interface", context do
    seed_connect(context, "slack-primary", "T-primary")
    agent_id = seed_agent(context)

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    save_settings!(context, entry())

    assert {:ok, policy} = MeetingCalendarPolicy.get(agent_id, "slack-primary")
    assert policy["connect_id"] == "slack-primary"
    assert policy["connected_account_ids"] == ["ca-cal"]
    assert policy["calendar_ids"] == ["cal-comma"]
    assert Ids.valid_calendar_id?(policy["meeting_calendar_id"])
    assert policy["watched_calendars"] == ["Comma Event"]
    assert policy["mode"] == "join"
    assert policy["channel"] == "#botarena"
    assert policy["channel_id"] == "C0BOTARENA"
    assert policy["readiness"] == "ACTIVE"
  end

  for {label, tombstone} <- [{"disabled", "disabled_at"}, {"deleted", "deleted_at"}] do
    @tombstone tombstone
    test "fails closed when the Slack connect is #{label}", context do
      seed_connect(context, "slack-primary", "T-primary", %{@tombstone => 101})

      assert {:error, :calendar_enrollment_connect_not_found} = MeetingEnrollment.resolve(entry())
    end
  end

  test "resolves configured connect identities with one bounded shared scan", context do
    seed_connect(context, "slack-primary", "T-primary")
    seed_connect(context, "slack-secondary", "T-secondary")
    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, identities} =
             MeetingEnrollment.resolve_identities([
               entry(),
               %{"connect_id" => "slack-secondary", "channel" => "#other", "calendars" => []}
             ])

    group_id = context.group_id
    assert {:ok, %{"group_id" => ^group_id}} = identities["slack-primary"]
    assert {:ok, %{"group_id" => ^group_id}} = identities["slack-secondary"]

    assert [
             {:list, "ctl/im_connects/", opts}
           ] =
             Enum.filter(SalixStore.S3.Fake.read_log(), fn
               {:list, "ctl/im_connects/", _opts} -> true
               _ -> false
             end)

    assert opts[:max_keys] > 0
  end

  test "fails closed when a calendar name is ambiguous", context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([
      %{"id" => "a", "summary" => "Comma Event"},
      %{"id" => "b", "summary" => "Comma Event"}
    ])

    assert {:error, {:calendar_ambiguous, "Comma Event"}} = MeetingEnrollment.resolve(entry())
  end

  for {label, channel, expected} <- [
        {"the bot is not a member of the channel",
         %{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => false},
         {:channel_bot_not_member, "#botarena"}},
        {"the channel is not found",
         %{"id" => "C0OTHER", "name" => "general", "is_member" => true},
         {:channel_not_found, "#botarena"}}
      ] do
    @expected expected
  end

  test "resolves a Feishu notify target and its explicit create calendar", context do
    seed_feishu_connect(context, "feishu-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([
      %{"id" => "cal-comma", "summary" => "Comma Event"},
      %{"id" => "cal-company", "summary" => "Company"}
    ])

    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, resolved} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "feishu-primary",
               "mode" => "notify",
               "chat_id" => "oc_team",
               "calendars" => ["Comma Event", "Company"],
               "create_calendar" => "Comma Event",
               "mentions" => %{"mode" => "all", "users" => []}
             })

    assert resolved["provider"] == "feishu"
    assert resolved["mode"] == "notify"
    assert resolved["tenant_id"] == context.tenant_id
    assert resolved["group_id"] == context.group_id
    assert resolved["connect_id"] == "feishu-primary"
    assert resolved["chat_id"] == "oc_team"
    assert resolved["mentions"] == %{"mode" => "all", "users" => []}
    assert Ids.valid_calendar_id?(resolved["calendar_id"])
    assert Enum.all?(resolved["calendars"], &Ids.valid_calendar_source_id?(&1["source_id"]))
    assert resolved["create_calendar"]["name"] == "Comma Event"
    assert resolved["create_calendar"]["calendar_id"] == "cal-comma"
    assert Ids.valid_calendar_source_id?(resolved["create_calendar"]["source_id"])
  end

  test "resolves a Lark notify target and its explicit create calendar", context do
    seed_lark_connect(context, "lark-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([
      %{"id" => "cal-comma", "summary" => "Comma Event"},
      %{"id" => "cal-company", "summary" => "Company"}
    ])

    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, resolved} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "lark-primary",
               "mode" => "notify",
               "chat_id" => "oc_team",
               "calendars" => ["Comma Event", "Company"],
               "create_calendar" => "Comma Event",
               "mentions" => %{"mode" => "all", "users" => []}
             })

    assert resolved["provider"] == "lark"
    assert resolved["mode"] == "notify"
    assert resolved["tenant_id"] == context.tenant_id
    assert resolved["group_id"] == context.group_id
    assert resolved["connect_id"] == "lark-primary"
    assert resolved["chat_id"] == "oc_team"
    assert resolved["mentions"] == %{"mode" => "all", "users" => []}
    assert Ids.valid_calendar_id?(resolved["calendar_id"])
    assert Enum.all?(resolved["calendars"], &Ids.valid_calendar_source_id?(&1["source_id"]))
    assert resolved["create_calendar"]["name"] == "Comma Event"
    assert resolved["create_calendar"]["calendar_id"] == "cal-comma"
    assert Ids.valid_calendar_source_id?(resolved["create_calendar"]["source_id"])

    # The durable enrollment proof keeps the Lark target, and the policy reads it.
    entry = %{
      "connect_id" => "lark-primary",
      "mode" => "notify",
      "chat_id" => "oc_team",
      "calendars" => ["Comma Event", "Company"],
      "create_calendar" => "Comma Event",
      "mentions" => %{"mode" => "all", "users" => []}
    }

    save_settings!(context, entry)
    agent_id = seed_agent(context)

    assert {:ok, evidence} = MeetingCalendarPolicy.get(agent_id, "lark-primary")
    assert evidence["mode"] == "notify"
    assert evidence["chat_id"] == "oc_team"
    assert evidence["calendar_name"] == "Comma Event"
    assert evidence["readiness"] == "ACTIVE"
  end

  for {label, failure, maintenance_reason} <- [
        {"persists a producer-shaped Google quota outcome across consecutive policy checks",
         {:proxy_event_error, 403, "rateLimitExceeded"},
         {:google_calendar_rate_limited, 403, ["rateLimitExceeded"]}},
        {"persists a producer-shaped Google 429 outcome across consecutive policy checks",
         {:proxy_event_error, 429, "quotaExceeded"},
         {:google_calendar_rate_limited, 429, ["quotaExceeded"]}},
        {"persists an outer Tool Router 503 across consecutive policy checks", :tool_router_503,
         {:google_calendar_http, 503}}
      ] do
    @expected {:error, {:calendar_source_maintenance, maintenance_reason}}
  end

  test "normalizes LIST_CALENDARS quota envelopes across consecutive policy checks", context do
    seed_feishu_connect(context, "feishu-primary")
    agent_id = seed_agent(context)

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      %{
        "successful" => false,
        "error" => %{
          "status" => 429,
          "message" => "sensitive-list-diagnostic",
          "api_key" => "secret-list-api-key",
          "errors" => [
            %{"reason" => "quotaExceeded"},
            %{"reason" => "Authorization: Bearer secret-list-token"}
          ]
        }
      }
    )

    entry = feishu_entry(["Comma Event"], "Comma Event")
    save_settings!(context, entry)

    expected =
      {:error,
       {:calendar_enrollment_list, {:google_calendar_rate_limited, 429, ["quotaExceeded"]}}}

    first = MeetingCalendarPolicy.get(agent_id, "feishu-primary")
    second = MeetingCalendarPolicy.get(agent_id, "feishu-primary")

    assert first == expected
    assert second == expected

    evidence = inspect({first, second})
    refute evidence =~ "sensitive-list-diagnostic"
    refute evidence =~ "secret-list-api-key"
    refute evidence =~ "secret-list-token"
  end

  test "dashboard saves exact calendars across accounts and disabling revokes old dispatch",
       context do
    alias Salix.Bindings.MeetingPreparationDashboard, as: Dashboard
    alias SalixMeet.CalendarConfiguration

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(context.group_id),
               Jason.encode!(%{
                 "group_id" => context.group_id,
                 "tenant_id" => context.tenant_id,
                 "router_conversation_id" => Ids.new_conversation_id()
               })
             )

    seed_connect(context, "slack-dashboard", "T-dashboard")

    stub_accounts(context.group_id, [
      account("ca-one", context.group_id, "ACTIVE", "googlecalendar"),
      account("ca-two", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "team-calendar", "summary" => "Team"}])

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-dashboard", "name" => "team", "is_member" => true}
    })

    selections =
      Enum.map(["ca-one", "ca-two"], &%{"account_id" => &1, "calendar_id" => "team-calendar"})

    attrs = %{
      "enabled" => true,
      "connect_id" => "slack-dashboard",
      "channel_id" => "C-dashboard",
      "calendar_selections" => selections,
      "preparation_lead_minutes" => 30,
      "research_enabled" => false,
      "calendar_writeback" => false,
      "autojoin" => false,
      "series" => [
        %{"account_id" => "ca-two", "calendar_id" => "team-calendar", "event_id" => "weekly"}
      ]
    }

    assert {:ok, saved} = Dashboard.run(context.tenant_id, context.group_id, "save", attrs)
    assert saved["mode"] == "prepare"
    assert saved["personal_preparation"] == false
    assert saved["research_enabled"] == false
    assert saved["preparation_lead_minutes"] == 30

    assert Enum.map(saved["calendar_selections"], &Map.take(&1, ~w(account_id calendar_id))) ==
             selections

    assert {:ok, entries} = CalendarConfiguration.entries()
    assert Enum.any?(entries, &(&1["group_id"] == context.group_id))

    plan = %{
      "group_id" => context.group_id,
      "managed_calendar" => true,
      "preparation" => %{"policy_revision" => saved["settings_revision"]}
    }

    assert :ok = CalendarConfiguration.authorize_plan(plan)
    assert {:error, _} = Dashboard.run(Ids.new_tenant_id(), context.group_id, "save", attrs)

    assert {:error, :invalid_meeting_preparation_settings} =
             Dashboard.run(context.tenant_id, context.group_id, "save", %{
               attrs
               | "calendar_selections" => [
                   %{"account_id" => "foreign", "calendar_id" => "team-calendar"}
                 ]
             })

    # Disable works even when provider credentials have stopped working.
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts", %{"error" => "expired"}, 401)

    assert {:ok, disabled} =
             Dashboard.run(context.tenant_id, context.group_id, "save", %{"enabled" => false})

    assert disabled["settings_revision"] > saved["settings_revision"]

    assert {:error, :meeting_preparation_settings_changed} =
             CalendarConfiguration.authorize_plan(plan)

    assert {:ok, entries} = CalendarConfiguration.entries()
    refute Enum.any?(entries, &(&1["group_id"] == context.group_id))
  end

  test "dashboard saves members' own calendars, joining unless switched off", context do
    alias Salix.Bindings.MeetingPreparationDashboard, as: Dashboard
    alias SalixMeet.CalendarConfiguration

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(context.group_id),
               Jason.encode!(%{
                 "group_id" => context.group_id,
                 "tenant_id" => context.tenant_id,
                 "router_conversation_id" => Ids.new_conversation_id()
               })
             )

    seed_connect(context, "slack-members", "T-members")

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    attrs = %{
      "enabled" => true,
      "connect_id" => "slack-members",
      "channel_id" => "C-members",
      "calendar_scope" => "members",
      "delivery" => "channel",
      "autojoin" => true
    }

    assert {:ok, saved} = Dashboard.run(context.tenant_id, context.group_id, "save", attrs)
    assert saved["calendar_scope"] == "members"
    assert saved["mode"] == "join"
    assert saved["channel_notice"] == false
    assert saved["personal_preparation"] == false
    assert saved["calendar_selections"] == []

    assert {:ok, entries} = CalendarConfiguration.entries()

    assert Enum.any?(
             entries,
             &(&1["group_id"] == context.group_id and &1["calendar_scope"] == "members")
           )

    # Without automatic joining it needs the personal notice, else it would do nothing.
    assert {:error, :invalid_meeting_preparation_settings} =
             Dashboard.run(context.tenant_id, context.group_id, "save", %{
               attrs
               | "autojoin" => false
             })

    assert {:ok, %{"mode" => "prepare", "personal_preparation" => true}} =
             Dashboard.run(
               context.tenant_id,
               context.group_id,
               "save",
               Map.merge(attrs, %{"autojoin" => false, "personal_preparation" => true})
             )

    # Organizer DMs need the bot's DM scopes, as attendee reminders do.
    assert {:error, :meeting_personal_scopes_unknown} =
             Dashboard.run(context.tenant_id, context.group_id, "save", %{
               attrs
               | "delivery" => "organizer"
             })
  end

  test "dashboard saves a Slack preparation without a team channel only when each meeting still reaches someone",
       context do
    alias Salix.Bindings.MeetingPreparationDashboard, as: Dashboard

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(context.group_id),
               Jason.encode!(%{
                 "group_id" => context.group_id,
                 "tenant_id" => context.tenant_id,
                 "router_conversation_id" => Ids.new_conversation_id()
               })
             )

    seed_connect(context, "slack-dm", "T-dm", %{
      "connect_generation" => "g1",
      "granted_bot_scopes_generation" => "g1",
      "granted_bot_scopes" => ["users:read.email", "im:write", "chat:write"]
    })

    stub_accounts(context.group_id, [
      account("ca-dm", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "team-calendar", "summary" => "Team"}])
    stub_source_lifecycle(context.group_id, "ca-dm")
    save = &Dashboard.run(context.tenant_id, context.group_id, "save", &1)

    attrs = %{
      "enabled" => true,
      "connect_id" => "slack-dm",
      "channel_id" => "",
      "calendar_selections" => [%{"account_id" => "ca-dm", "calendar_id" => "team-calendar"}],
      "preparation_lead_minutes" => 10,
      "research_enabled" => true,
      "calendar_writeback" => false,
      "autojoin" => false,
      "channel_notice" => false,
      "personal_preparation" => true
    }

    # Attendee reminders alone reach every meeting's people.
    assert {:ok, saved} = save.(attrs)
    assert saved["mode"] == "prepare" and saved["channel_id"] == ""

    assert {:ok, identities} = MeetingEnrollment.resolve_identities([saved])
    assert {:ok, identity} = identities["slack-dm"]
    assert {:ok, resolved} = MeetingEnrollment.resolve(saved, identity)
    assert resolved["channel_id"] == ""
    assert :ok = CalendarEnrollmentCache.put(saved, identity, resolved, 1_000)
    assert {:ok, %{group: %{"channel_id" => ""}}} = CalendarEnrollmentCache.load(saved, identity)

    # The channel notice, or a preparation that reminds nobody, needs the channel.
    assert {:error, :meeting_channel_invalid} = save.(%{attrs | "channel_notice" => true})
    assert {:error, :meeting_channel_invalid} = save.(%{attrs | "personal_preparation" => false})

    # A joined meeting's thread needs the channel or a DM to its organizer.
    assert {:error, :meeting_channel_invalid} = save.(%{attrs | "autojoin" => true})

    assert {:ok, %{"mode" => "join", "channel_id" => ""}} =
             save.(Map.merge(attrs, %{"autojoin" => true, "delivery" => "organizer"}))

    members = %{
      "enabled" => true,
      "connect_id" => "slack-dm",
      "channel_id" => "",
      "calendar_scope" => "members",
      "delivery" => "channel",
      "autojoin" => true
    }

    assert {:error, :meeting_channel_invalid} = save.(members)

    assert {:ok, %{"calendar_scope" => "members", "channel_id" => ""}} =
             save.(%{members | "delivery" => "organizer"})
  end

  defp entry,
    do: %{
      "connect_id" => "slack-primary",
      "channel" => "#botarena",
      "calendars" => ["Comma Event"]
    }

  defp feishu_entry(calendars, create_calendar),
    do: %{
      "connect_id" => "feishu-primary",
      "mode" => "notify",
      "chat_id" => "oc_team",
      "calendars" => calendars,
      "create_calendar" => create_calendar,
      "mentions" => %{"mode" => "none", "users" => []}
    }

  test "members' own calendars: each account is a unit of the calendars it owns, listed a bounded number per pass",
       context do
    seed_connect(context, "slack-members", "T-members")
    MockExternalHTTP.reset_requests()
    ids = Enum.map(1..10, &"ca-member-#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

    stub_accounts(
      context.group_id,
      Enum.map(ids, &account(&1, context.group_id, "ACTIVE", "googlecalendar")) ++
        [account("ca-gmail", context.group_id, "ACTIVE", "gmail")]
    )

    Enum.each(ids, &stub_source_lifecycle(context.group_id, &1))

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn body ->
        account_id = body["connected_account_id"]
        email = "#{account_id}@example.test"

        %{
          "successful" => true,
          "data" => %{
            "calendars" => [
              %{"id" => email, "summary" => email, "primary" => true, "accessRole" => "owner"},
              %{
                "id" => "#{account_id}-projects",
                "summary" => "Projects",
                "accessRole" => "owner"
              },
              %{"id" => "boss@example.test", "summary" => "Boss", "accessRole" => "writer"},
              %{"id" => "holidays", "summary" => "Holidays", "accessRole" => "reader"}
            ]
          }
        }
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => [],
      "delivery" => "organizer"
    }

    assert {:ok, first} = MeetingEnrollment.resolve(entry)
    assert first["calendar_scope"] == "members"
    assert first["delivery"] == "organizer"
    assert first["channel_notice"] == false and first["personal_preparation"] == false
    assert length(first["units"]) == 8
    assert listed_accounts() |> Enum.sort() == Enum.take(ids, 8)

    unit = hd(first["units"])
    assert unit["account_email"] == "ca-member-01@example.test"
    assert Ids.valid_calendar_id?(unit["calendar_id"])

    assert unit["calendars"] |> Enum.map(& &1["calendar_id"]) |> Enum.sort() ==
             ["ca-member-01-projects", "ca-member-01@example.test"]

    other = Enum.at(first["units"], 1)
    assert other["calendar_id"] != unit["calendar_id"]

    MockExternalHTTP.reset_requests()

    assert {:ok, second} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", first))
    assert listed_accounts() |> Enum.sort() == ["ca-member-09", "ca-member-10"]
    assert Enum.map(second["units"], & &1["account_id"]) == ids
    assert Enum.take(second["units"], 8) == first["units"]

    stub_accounts(
      context.group_id,
      Enum.map(tl(ids), &account(&1, context.group_id, "ACTIVE", "googlecalendar"))
    )

    MockExternalHTTP.reset_requests()

    assert {:ok, third} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", second))
    assert listed_accounts() == []
    assert Enum.map(third["units"], & &1["account_id"]) == tl(ids)
  end

  test "members' own calendars: a member with more calendar pages than one pass lists continues where it stopped",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-many", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-many")

    # Twelve pages of one owned calendar each; a pass lists at most ten.
    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn body ->
        page = String.to_integer(get_in(body, ["arguments", "page_token"]) || "0")

        calendars =
          if page == 0,
            do: [%{"id" => "ca-many@example.test", "primary" => true, "accessRole" => "owner"}],
            else: [%{"id" => "cal-#{page}", "summary" => "Cal #{page}", "accessRole" => "owner"}]

        next = if page < 11, do: Integer.to_string(page + 1), else: ""
        %{"successful" => true, "data" => %{"calendars" => calendars, "next_page_token" => next}}
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => []
    }

    assert {:ok, first} = MeetingEnrollment.resolve(entry)
    [unit] = first["units"]
    assert length(unit["calendars"]) == 10
    assert unit["listing"]["page_token"] == "10"

    # Ten minutes later the listing continues from page ten.
    earlier = SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 - 1

    continued =
      Map.update!(first, "units", fn [unit] -> [Map.put(unit, "listed_at", earlier)] end)

    assert {:ok, second} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", continued))
    [unit] = second["units"]
    refute Map.has_key?(unit, "listing")
    assert length(unit["calendars"]) == 12
  end

  test "members' own calendars: calendars left to set up and further pages are both continued, and an earlier failure still retries soon",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-many", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-many")

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn body ->
        assert get_in(body, ["arguments", "page_token"]) == "1"

        %{
          "successful" => true,
          "data" => %{
            "calendars" => [%{"id" => "cal-1", "accessRole" => "owner"}],
            "next_page_token" => ""
          }
        }
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => []
    }

    earlier = SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 - 1

    # The last pass ran out of time with page 0's calendar left to set up, a
    # next page to list, and a calendar that had failed to sync.
    unit = %{
      "account_id" => "ca-many",
      "calendars" => [],
      "listed_at" => earlier,
      "listing" => %{
        "page_token" => "1",
        "listed" => false,
        "failed" => true,
        "account_email" => "ca-many@example.test",
        "enrolled" => [],
        "pending" => [
          %{
            "account_id" => "ca-many",
            "calendar_id" => "ca-many@example.test",
            "time_zone" => "UTC"
          }
        ]
      }
    }

    enrolled = %{"group_id" => context.group_id, "units" => [unit]}
    assert {:ok, first} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", enrolled))
    [unit] = first["units"]
    assert Enum.map(unit["calendars"], & &1["calendar_id"]) == ["ca-many@example.test"]
    assert unit["listing"]["page_token"] == "1"

    continued =
      Map.update!(first, "units", fn [unit] -> [Map.put(unit, "listed_at", earlier)] end)

    assert {:ok, second} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", continued))
    [unit] = second["units"]
    refute Map.has_key?(unit, "listing")

    assert unit["calendars"] |> Enum.map(& &1["calendar_id"]) |> Enum.sort() ==
             ["ca-many@example.test", "cal-1"]

    # The earlier failure keeps the account on the ten-minute retry.
    assert unit["listed_at"] <=
             SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 + 10 * 60 * 1_000
  end

  test "members' own calendars: a calendar whose first sync hangs is stopped, the finished one kept, and the retry continues with it",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-mixed", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-mixed")

    previous_deadline = SystemsRuntime.get_env(:salix_web, :member_listing_deadline_ms)
    SystemsRuntime.put_env(:salix_web, :member_listing_deadline_ms, 300)
    SystemsRuntime.put_env(:salix_web, :meeting_enrollment_test_hang, true)

    on_exit(fn ->
      restore_env(:salix_web, :member_listing_deadline_ms, previous_deadline)
      SystemsRuntime.delete_env(:salix_web, :meeting_enrollment_test_hang)
      SystemsRuntime.delete_env(:salix_web, :meeting_enrollment_test_hung)
    end)

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if String.contains?(request["endpoint"] || "", "slow-cal") and
           SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hang) do
        SystemsRuntime.put_env(
          :salix_web,
          :meeting_enrollment_test_hung,
          SystemsRuntime.Proc.self()
        )

        receive(do: (:release -> :ok))
      end

      calendar_proxy_response(request)
    end)

    MockExternalHTTP.stub("POST", "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", %{
      "successful" => true,
      "data" => %{
        "calendars" => [
          %{"id" => "ca-mixed@example.test", "primary" => true, "accessRole" => "owner"},
          %{"id" => "slow-cal", "summary" => "Slow", "accessRole" => "owner"}
        ]
      }
    })

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => []
    }

    assert {:ok, first} = MeetingEnrollment.resolve(entry)
    [unit] = first["units"]
    assert Enum.map(unit["calendars"], & &1["calendar_id"]) == ["ca-mixed@example.test"]
    assert Enum.map(unit["listing"]["pending"], & &1["calendar_id"]) == ["slow-cal"]

    # Google answers the hung request late; the retry then continues.
    SystemsRuntime.put_env(:salix_web, :meeting_enrollment_test_hang, false)

    SystemsRuntime.Proc.send(
      SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung),
      :release
    )

    # The retry comes after the late answer is applied: a refresh queued
    # behind the released one returns only once the source is idle again.
    {:ok, calendar} = Calendar.get_calendar(context.group_id, unit["calendar_id"])
    [finished] = unit["calendars"]

    [slow_source] =
      Map.values(calendar["source_memberships"]) -- [finished["source_id"]]

    assert {:ok, _} =
             Calendar.refresh_source(context.group_id, unit["calendar_id"], slow_source, %{
               "group_id" => context.group_id,
               "object_type" => "Event",
               "page_size" => 200
             })

    earlier = SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 - 1

    continued =
      Map.update!(first, "units", fn [unit] -> [Map.put(unit, "listed_at", earlier)] end)

    assert {:ok, second} = MeetingEnrollment.resolve(Map.put(entry, "enrolled", continued))
    [unit] = second["units"]
    refute Map.has_key?(unit, "listing")

    assert unit["calendars"] |> Enum.map(& &1["calendar_id"]) |> Enum.sort() ==
             ["ca-mixed@example.test", "slow-cal"]
  end

  test "members' own calendars: a calendar whose sync keeps hanging does not keep the others from enrolling",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-slow", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-slow")

    previous_deadline = SystemsRuntime.get_env(:salix_web, :member_listing_deadline_ms)
    SystemsRuntime.put_env(:salix_web, :member_listing_deadline_ms, 300)
    on_exit(fn -> restore_env(:salix_web, :member_listing_deadline_ms, previous_deadline) end)

    # The first calendar's sync never answers.
    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if String.contains?(request["endpoint"] || "", "slow-first") do
        hung = SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung_all, [])

        SystemsRuntime.put_env(:salix_web, :meeting_enrollment_test_hung_all, [
          SystemsRuntime.Proc.self() | hung
        ])

        receive(do: (:release -> :ok))
      end

      calendar_proxy_response(request)
    end)

    MockExternalHTTP.stub("POST", "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", %{
      "successful" => true,
      "data" => %{
        "calendars" => [
          %{"id" => "slow-first", "summary" => "Slow", "accessRole" => "owner"},
          %{"id" => "ca-slow@example.test", "primary" => true, "accessRole" => "owner"}
        ]
      }
    })

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => []
    }

    earlier = SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 - 1

    units =
      Enum.reduce(1..2, nil, fn _, previous ->
        entry =
          if previous,
            do:
              Map.put(
                entry,
                "enrolled",
                Map.update!(previous, "units", fn [unit] ->
                  [Map.put(unit, "listed_at", earlier)]
                end)
              ),
            else: entry

        assert {:ok, resolved} = MeetingEnrollment.resolve(entry)

        # Google answers the hung request only after the pass gave up on it.
        for pid <- SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung_all, []),
            do: SystemsRuntime.Proc.send(pid, :release)

        SystemsRuntime.put_env(:salix_web, :meeting_enrollment_test_hung_all, [])
        resolved
      end)

    [unit] = units["units"]
    assert "ca-slow@example.test" in Enum.map(unit["calendars"], & &1["calendar_id"])
  end

  test "members' own calendars: a hanging calendar page keeps the pages read and continues from it",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-pages", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-pages")

    previous_deadline = SystemsRuntime.get_env(:salix_web, :member_listing_deadline_ms)
    SystemsRuntime.put_env(:salix_web, :member_listing_deadline_ms, 300)
    SystemsRuntime.put_env(:salix_web, :meeting_enrollment_test_hang, true)

    on_exit(fn ->
      restore_env(:salix_web, :member_listing_deadline_ms, previous_deadline)
      SystemsRuntime.delete_env(:salix_web, :meeting_enrollment_test_hang)
      SystemsRuntime.delete_env(:salix_web, :meeting_enrollment_test_hung)
    end)

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn body ->
        case get_in(body, ["arguments", "page_token"]) do
          nil ->
            %{
              "successful" => true,
              "data" => %{
                "calendars" => [
                  %{"id" => "ca-pages@example.test", "primary" => true, "accessRole" => "owner"}
                ],
                "next_page_token" => "1"
              }
            }

          "1" ->
            if SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hang) do
              SystemsRuntime.put_env(
                :salix_web,
                :meeting_enrollment_test_hung,
                SystemsRuntime.Proc.self()
              )

              receive(do: (:release -> :ok))
            end

            %{
              "successful" => true,
              "data" => %{"calendars" => [%{"id" => "page-1", "accessRole" => "owner"}]}
            }
        end
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    entry = %{
      "connect_id" => "slack-members",
      "calendar_scope" => "members",
      "channel" => "meetings",
      "channel_id" => "C-members",
      "calendars" => []
    }

    # The first page's calendar is kept to set up and the listing continues
    # from the page that hung (continuing from a token is covered above).
    assert {:ok, first} = MeetingEnrollment.resolve(entry)

    SystemsRuntime.Proc.send(
      SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung),
      :release
    )

    [unit] = first["units"]
    assert Enum.map(unit["listing"]["pending"], & &1["calendar_id"]) == ["ca-pages@example.test"]
    assert unit["listing"]["page_token"] == "1"
  end

  test "members' own calendars: a first calendar page that times out keeps the account's calendars and retries the first page",
       context do
    seed_connect(context, "slack-members", "T-members")

    stub_accounts(context.group_id, [
      account("ca-first", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_source_lifecycle(context.group_id, "ca-first")

    previous_deadline = SystemsRuntime.get_env(:salix_web, :member_listing_deadline_ms)
    SystemsRuntime.put_env(:salix_web, :member_listing_deadline_ms, 300)

    on_exit(fn ->
      restore_env(:salix_web, :member_listing_deadline_ms, previous_deadline)
      SystemsRuntime.delete_env(:salix_web, :meeting_enrollment_test_hung)
    end)

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn _body ->
        if is_nil(SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung)) do
          SystemsRuntime.put_env(
            :salix_web,
            :meeting_enrollment_test_hung,
            SystemsRuntime.Proc.self()
          )

          receive(do: (:release -> :ok))
        end

        %{
          "successful" => true,
          "data" => %{
            "calendars" => [
              %{"id" => "ca-first@example.test", "primary" => true, "accessRole" => "owner"}
            ]
          }
        }
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    earlier = SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 - 1

    kept = %{
      "account_id" => "ca-first",
      "calendar_id" => "known@example.test",
      "source_id" => "csrc1_kept"
    }

    # An account enrolled earlier is due for its refresh.
    enrolled = %{
      "group_id" => context.group_id,
      "units" => [
        %{
          "account_id" => "ca-first",
          "account_email" => "ca-first@example.test",
          "calendar_id" => Ids.new_calendar_id(),
          "calendars" => [kept],
          "listed_at" => earlier
        }
      ]
    }

    assert {:ok, %{"units" => [unit]}} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-members",
               "calendar_scope" => "members",
               "channel" => "meetings",
               "channel_id" => "C-members",
               "calendars" => [],
               "enrolled" => enrolled
             })

    SystemsRuntime.Proc.send(
      SystemsRuntime.get_env(:salix_web, :meeting_enrollment_test_hung),
      :release
    )

    assert unit["calendars"] == [kept]
    assert unit["account_email"] == "ca-first@example.test"
    assert unit["listing"]["listed"] == false
    assert unit["listing"]["page_token"] == nil

    assert unit["listed_at"] <=
             SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 + 10 * 60 * 1_000

    # The retry lists the first page and finishes, keeping the account's
    # address for direct messages and preparation.
    retry = %{
      "group_id" => context.group_id,
      "units" => [Map.put(unit, "listed_at", earlier)]
    }

    assert {:ok, %{"units" => [unit]}} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-members",
               "calendar_scope" => "members",
               "channel" => "meetings",
               "channel_id" => "C-members",
               "calendars" => [],
               "enrolled" => retry
             })

    refute Map.has_key?(unit, "listing")
    assert unit["account_email"] == "ca-first@example.test"
    assert Enum.map(unit["calendars"], & &1["calendar_id"]) == ["ca-first@example.test"]
  end

  test "members' own calendars: an account that has no calendars yet is listed again after ten minutes",
       context do
    seed_connect(context, "slack-members", "T-members")
    ids = ["ca-failed", "ca-listed"]

    stub_accounts(
      context.group_id,
      Enum.map(ids, &account(&1, context.group_id, "ACTIVE", "googlecalendar"))
    )

    Enum.each(ids, &stub_source_lifecycle(context.group_id, &1))

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      fn body ->
        email = "#{body["connected_account_id"]}@example.test"

        %{
          "successful" => true,
          "data" => %{
            "calendars" => [%{"id" => email, "primary" => true, "accessRole" => "owner"}]
          }
        }
      end
    )

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    eleven_minutes_ago = SystemsClock.system_time(:millisecond) - 11 * 60 * 1_000

    enrolled = %{
      "group_id" => context.group_id,
      "units" => [
        %{"account_id" => "ca-failed", "calendars" => [], "listed_at" => eleven_minutes_ago},
        %{
          "account_id" => "ca-listed",
          "calendar_id" => Ids.new_calendar_id(),
          "calendars" => [],
          "listed_at" => eleven_minutes_ago
        }
      ]
    }

    MockExternalHTTP.reset_requests()

    assert {:ok, %{"units" => units}} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-members",
               "calendar_scope" => "members",
               "channel" => "meetings",
               "channel_id" => "C-members",
               "calendars" => [],
               "enrolled" => enrolled
             })

    assert listed_accounts() == ["ca-failed"]

    assert Enum.find(units, &(&1["account_id"] == "ca-failed"))["account_email"] ==
             "ca-failed@example.test"
  end

  test "members' own calendars: a calendar that cannot sync leaves the member's other calendars enrolled",
       context do
    seed_connect(context, "slack-members", "T-members")
    stub_source_lifecycle(context.group_id, "ca-member")

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if String.contains?(request["endpoint"] || "", "broken"),
        do: %{"status" => 403, "data" => %{"error" => %{"code" => 403}}},
        else: calendar_proxy_response(request)
    end)

    stub_accounts(context.group_id, [
      account("ca-member", context.group_id, "ACTIVE", "googlecalendar")
    ])

    MockExternalHTTP.stub("POST", "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", %{
      "successful" => true,
      "data" => %{
        "calendars" => [
          %{"id" => "member@example.test", "primary" => true, "accessRole" => "owner"},
          %{"id" => "broken-team", "summary" => "Team", "accessRole" => "owner"}
        ]
      }
    })

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-members", "name" => "meetings", "is_member" => true}
    })

    assert {:ok, %{"units" => [unit]}} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-members",
               "calendar_scope" => "members",
               "channel" => "meetings",
               "channel_id" => "C-members",
               "calendars" => []
             })

    assert unit["account_email"] == "member@example.test"
    assert Enum.map(unit["calendars"], & &1["calendar_id"]) == ["member@example.test"]

    # The account is listed again after ten minutes, not six hours.
    assert unit["listed_at"] <=
             SystemsClock.system_time(:millisecond) - 6 * 60 * 60 * 1_000 + 10 * 60 * 1_000
  end

  defp seed_connect(context, connect_id, workspace_id, extra \\ %{}) do
    record =
      Map.merge(
        %{
          "tenant_id" => context.tenant_id,
          "group_id" => context.group_id,
          "connect_id" => connect_id,
          "provider" => "slack",
          "workspace_id" => workspace_id,
          "workspace_name" => workspace_id,
          "bot_token" => "xoxb-#{connect_id}",
          "oauth_completed_at" => 1,
          "created_at" => 100,
          "updated_at" => 100
        },
        extra
      )

    assert {:ok, _record} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(context.group_id, connect_id),
               record
             )
  end

  defp seed_feishu_connect(context, connect_id, extra \\ %{}) do
    record =
      Map.merge(
        %{
          "tenant_id" => context.tenant_id,
          "group_id" => context.group_id,
          "connect_id" => connect_id,
          "provider" => "feishu",
          "app_id" => "cli_#{connect_id}",
          "app_name" => "Bridge",
          "bot_open_id" => "ou_bot",
          "status" => "connected",
          "created_at" => 100,
          "updated_at" => 100
        },
        extra
      )

    assert {:ok, _record} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(context.group_id, connect_id),
               record
             )
  end

  defp seed_lark_connect(context, connect_id, extra \\ %{}) do
    record =
      Map.merge(
        %{
          "tenant_id" => context.tenant_id,
          "group_id" => context.group_id,
          "connect_id" => connect_id,
          "provider" => "lark",
          "app_id" => "cli_#{connect_id}",
          "app_name" => "Bridge",
          "bot_open_id" => "ou_bot",
          "status" => "connected",
          "created_at" => 100,
          "updated_at" => 100
        },
        extra
      )

    assert {:ok, _record} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(context.group_id, connect_id),
               record
             )
  end

  # The dashboard saves a Group's meeting settings; the worker and the policy
  # read only those.
  defp save_settings!(context, entry) do
    configuration = Map.put(entry, "enabled", true)

    assert {:ok, saved} =
             SalixStore.MeetingCalendarSettings.put(
               context.group_id,
               context.tenant_id,
               configuration,
               fn -> :ok end
             )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        SalixStore.Repo,
        "DELETE FROM meeting_calendar_settings WHERE group_id = $1",
        [context.group_id]
      )
    end)

    saved
  end

  defp seed_agent(context) do
    agent_id = Ids.new_agent_id(context.group_id)

    assert {:ok, _record} =
             SalixStore.AgentPGStore.create(agent_id, to_string(node()), SalixAgent.State, %{
               "agent_id" => agent_id,
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id,
               "role" => "worker",
               "heartbeat_schedule_id" => "heartbeat-#{agent_id}"
             })

    agent_id
  end

  defp stub_accounts(_group_id, accounts) do
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts", %{"items" => accounts})
  end

  defp stub_calendars(calendars) do
    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      %{"successful" => true, "data" => %{"calendars" => calendars}}
    )
  end

  defp stub_channels(channels) do
    MockExternalHTTP.stub("POST", "/api/conversations.list", %{
      "ok" => true,
      "channels" => channels
    })
  end

  defp stub_source_lifecycle(group_id, account_id) do
    MockExternalHTTP.stub(
      "GET",
      "/api/v3/connected_accounts/#{account_id}",
      account(account_id, group_id, "ACTIVE", "googlecalendar")
    )

    MockExternalHTTP.stub(
      "POST",
      @proxy_session_path,
      %{"session_id" => "trs-enrollment", "config" => %{}},
      201
    )

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      &calendar_proxy_response/1
    )

    MockExternalHTTP.stub(
      "DELETE",
      @proxy_session_path <> "/trs-enrollment",
      %{"session_id" => "trs-enrollment", "deleted" => true}
    )

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
      fn body ->
        %{
          "successful" => true,
          "data" => %{
            "id" => get_in(body, ["arguments", "id"]),
            "resourceId" => "resource-#{account_id}",
            "expiration" => SystemsClock.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1_000
          }
        }
      end
    )

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_LIST",
      %{"successful" => true, "data" => %{"items" => [], "nextSyncToken" => "sync-1"}}
    )
  end

  defp calendar_proxy_response(request) do
    endpoint = request["endpoint"] || ""

    if String.ends_with?(endpoint, "/events") do
      %{"status" => 200, "data" => %{"items" => [], "nextSyncToken" => "sync-1"}}
    else
      [calendar_id] =
        Regex.run(~r{/calendars/([^/]+)$}, endpoint, capture: :all_but_first)

      %{
        "status" => 200,
        "data" => %{
          "id" => URI.decode(calendar_id),
          "summary" => "Comma Event",
          "timeZone" => "UTC"
        }
      }
    end
  end

  defp listed_accounts do
    for %{method: "POST", path: "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", raw: raw} <-
          MockExternalHTTP.requests(),
        do: Jason.decode!(raw)["connected_account_id"]
  end

  defp account(id, user_id, status, toolkit) do
    %{"id" => id, "user_id" => user_id, "status" => status, "toolkit" => %{"slug" => toolkit}}
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(
             {Bandit, plug: MockExternalHTTP, port: port, ip: {127, 0, 0, 1}},
             id: {:meeting_enrollment_bandit, port}
           ) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind meeting enrollment test server"
  end

  defp ensure_started!(module) do
    case SystemsRuntime.Proc.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
