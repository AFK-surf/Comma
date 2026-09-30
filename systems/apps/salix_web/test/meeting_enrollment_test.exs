defmodule Salix.Bindings.MeetingEnrollmentTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.{
    GoogleCalendarSource,
    GoogleCalendarWatch,
    MeetingCalendarPolicy,
    MeetingEnrollment
  }

  alias Salix.Control.ComposioSettings
  alias SalixCalendar.Server, as: Calendar
  alias SalixMeet.{CalendarAutojoin, CalendarEnrollmentCache}
  alias SalixStore.{Ids, Keys, S3}

  @proxy_session_path "/api/v3.1/tool_router/session"
  @proxy_execute_path "/api/v3.1/tool_router/session/trs-enrollment/proxy_execute"

  alias SalixWeb.Test.MeetingPreparationProvider, as: MockExternalHTTP

  defmodule VersionedGoogleCalendarSource do
    @behaviour SalixCalendar.SourceAdapter

    alias Salix.Bindings.GoogleCalendarSource

    @impl true
    def adapter_contract_id,
      do: Application.fetch_env!(:salix_web, :test_google_calendar_contract_id)

    @impl true
    def capabilities, do: GoogleCalendarSource.capabilities()

    @impl true
    def start_sync(source, query_contract, completed_cursor),
      do: GoogleCalendarSource.start_sync(source, query_contract, completed_cursor)

    @impl true
    def continue_sync(source, query_contract, continuation),
      do: GoogleCalendarSource.continue_sync(source, query_contract, continuation)

    @impl true
    def exact_refresh(source, item, occurrence),
      do: GoogleCalendarSource.exact_refresh(source, item, occurrence)

    @impl true
    def normalize(record, opts), do: GoogleCalendarSource.normalize(record, opts)
  end

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      composio_url: Application.get_env(:salix_store, :composio_base_url_override),
      slack_url: Application.get_env(:salix_im, :slack_api_base_url),
      calendar_autojoin_channels: Application.get_env(:salix_meet, :calendar_autojoin_channels),
      calendar_enrollment_mod: Application.get_env(:salix_meet, :calendar_enrollment_mod),
      source_adapters: Application.get_env(:salix_calendar, :source_adapters),
      google_contract: Application.get_env(:salix_web, :test_google_calendar_contract_id)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    ensure_started!(MockExternalHTTP)
    port = start_bandit_retry!()
    base_url = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_store, :composio_base_url_override, base_url)
    Application.put_env(:salix_im, :slack_api_base_url, base_url <> "/api")

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
        :calendar_autojoin_channels,
        previous.calendar_autojoin_channels
      )

      restore_env(
        :salix_meet,
        :calendar_enrollment_mod,
        previous.calendar_enrollment_mod
      )

      restore_env(:salix_calendar, :source_adapters, previous.source_adapters)
      restore_env(:salix_web, :test_google_calendar_contract_id, previous.google_contract)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  test "resolves a connect entry into group, account, calendar id, and channel id", context do
    seed_connect(context, "slack-primary", "T-primary")

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

  test "autojoin replaces a v4 cache and v2 Google source without selecting legacy facts",
       context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, calendar} =
             Calendar.ensure_calendar(
               context.group_id,
               %{"kind" => "meeting_enrollment", "version" => 1},
               %{"name" => "Meeting calendar", "default_time_zone" => "UTC"}
             )

    Application.put_env(
      :salix_web,
      :test_google_calendar_contract_id,
      "google_calendar.events.v2"
    )

    Application.put_env(:salix_calendar, :source_adapters, %{
      "google_calendar" => VersionedGoogleCalendarSource
    })

    assert {:ok, legacy_source} =
             Calendar.ensure_source(context.group_id, calendar["calendar_id"], %{
               "adapter" => "google_calendar",
               "adapter_contract_id" => "google_calendar.events.v2",
               "source_locator" => %{
                 "connection_id" => "ca-cal",
                 "external_calendar_id" => "cal-comma"
               },
               "access_profile" => "events_read",
               "audience" => %{"kind" => "group", "group_id" => context.group_id},
               "sync_policy" => %{"page_size" => 200, "default_time_zone" => "UTC"}
             })

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if String.ends_with?(request["endpoint"] || "", "/events") do
        %{
          "status" => 200,
          "data" => %{"items" => [legacy_event()], "nextSyncToken" => "sync-v2"}
        }
      else
        calendar_proxy_response(request)
      end
    end)

    assert {:ok, _result} =
             Calendar.refresh_source(
               context.group_id,
               calendar["calendar_id"],
               legacy_source["source_id"],
               %{"group_id" => context.group_id, "object_type" => "Event", "page_size" => 200}
             )

    assert {:ok, [_legacy_occurrence]} =
             Calendar.query_items(
               context.group_id,
               calendar["calendar_id"],
               unix_ms("2029-12-31T00:00:00Z"),
               unix_ms("2030-01-02T00:00:00Z"),
               source_ids: [legacy_source["source_id"]]
             )

    configured_entry = entry()

    identity = %{
      "connect_id" => "slack-primary",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "provider" => "slack"
    }

    legacy_group = %{
      "provider" => "slack",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => "slack-primary",
      "workspace_id" => "T-primary",
      "channel_id" => "C0BOTARENA",
      "calendar_id" => calendar["calendar_id"],
      "calendars" => [
        %{
          "account_id" => "ca-cal",
          "calendar_id" => "cal-comma",
          "source_id" => legacy_source["source_id"]
        }
      ]
    }

    fingerprint = CalendarEnrollmentCache.fingerprint(configured_entry)
    cache_key = Keys.ctl_meet_calendar_enrollment("slack-primary", fingerprint)

    assert {:ok, _} =
             S3.put(
               cache_key,
               Jason.encode!(%{
                 "version" => 4,
                 "connect_id" => "slack-primary",
                 "fingerprint" => fingerprint,
                 "identity" => identity,
                 "group" => CalendarEnrollmentCache.sanitize_group(legacy_group),
                 "source_activation" => %{"status" => "ready", "version" => 1},
                 "resolved_at_ms" => System.system_time(:millisecond)
               }),
               if_none_match: "*"
             )

    Application.put_env(:salix_calendar, :source_adapters, %{
      "google_calendar" => GoogleCalendarSource
    })

    Application.put_env(:salix_meet, :calendar_enrollment_mod, MeetingEnrollment)
    stub_source_lifecycle(context.group_id, "ca-cal")

    autojoin =
      start_supervised!(
        {CalendarAutojoin,
         [
           name: :"calendar_enrollment_cutover_#{System.unique_integer([:positive])}",
           channels: [configured_entry],
           scan_interval_ms: 3_600_000,
           join_interval_ms: 3_600_000,
           node: "calendar-enrollment-cutover-node"
         ]},
        id: make_ref(),
        restart: :temporary
      )

    assert %{groups: [selected_group]} = :sys.get_state(autojoin)
    assert [%{"source_id" => selected_source_id}] = selected_group["calendars"]
    refute selected_source_id == legacy_source["source_id"]

    assert {:ok, %{"adapter_contract_id" => "google_calendar.events.v3"}} =
             Calendar.get_source(context.group_id, calendar["calendar_id"], selected_source_id)

    assert {:ok, %{group: persisted_group, identity: ^identity}} =
             CalendarEnrollmentCache.load(configured_entry, identity)

    assert get_in(persisted_group, ["calendars", Access.at(0), "source_id"]) ==
             selected_source_id

    assert {:ok, %{body: cache_body}} = S3.get(cache_key)
    assert %{"version" => 5} = Jason.decode!(cache_body)

    assert {:ok, []} =
             Calendar.query_items(
               context.group_id,
               calendar["calendar_id"],
               unix_ms("2029-12-31T00:00:00Z"),
               unix_ms("2030-01-02T00:00:00Z"),
               source_ids: [selected_source_id]
             )

    assert {:ok, [_legacy_occurrence]} =
             Calendar.query_items(
               context.group_id,
               calendar["calendar_id"],
               unix_ms("2029-12-31T00:00:00Z"),
               unix_ms("2030-01-02T00:00:00Z"),
               source_ids: [legacy_source["source_id"]]
             )
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

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry()])

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

  test "diagnostic policy reads the durable enrollment proof without provider calls or writes",
       context do
    seed_connect(context, "slack-primary", "T-primary")
    agent_id = seed_agent(context)

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    configured_entry = entry()
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [configured_entry])

    assert {:ok, resolved} = MeetingEnrollment.resolve(configured_entry)

    identity = %{
      "connect_id" => "slack-primary",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "provider" => "slack"
    }

    assert :ok =
             CalendarEnrollmentCache.put(configured_entry, identity, resolved, 1_786_000_000_000)

    before_objects = SalixStore.S3.Fake.dump()
    before_requests = MockExternalHTTP.requests()
    SalixStore.S3.Fake.reset_put_log()

    assert {:ok, policy} = MeetingCalendarPolicy.status(agent_id, "slack-primary")
    assert policy["readiness"] == "ACTIVE"
    assert policy["connected_account_ids"] == ["ca-cal"]
    assert policy["calendar_ids"] == ["cal-comma"]
    assert policy["resolved_at_ms"] == 1_786_000_000_000

    assert SalixStore.S3.Fake.dump() == before_objects
    assert SalixStore.S3.Fake.put_log() == []
    assert MockExternalHTTP.requests() == before_requests
  end

  test "policy fails closed for every connect when two configured targets resolve to one group",
       context do
    seed_connect(context, "slack-primary", "T-primary")
    seed_feishu_connect(context, "feishu-primary")
    agent_id = seed_agent(context)

    slack_entry = entry()

    feishu_entry = %{
      "connect_id" => "feishu-primary",
      "mode" => "notify",
      "chat_id" => "oc_team",
      "calendars" => ["Comma Event"],
      "create_calendar" => "Comma Event",
      "mentions" => %{"mode" => "none", "users" => []}
    }

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_channels,
      [slack_entry, feishu_entry]
    )

    assert {:error, :calendar_policy_group_conflict} =
             MeetingCalendarPolicy.get(agent_id, "slack-primary")

    assert {:error, :calendar_policy_group_conflict} =
             MeetingCalendarPolicy.get(agent_id, "feishu-primary")
  end

  test "resolves a stable calendar ID selector for Slack", context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Renamed Team Calendar"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, resolved} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-primary",
               "channel" => "#botarena",
               "calendars" => ["cal-comma"]
             })

    assert [%{"calendar_id" => "cal-comma"}] = resolved["calendars"]
  end

  test "does not materialize a calendar for an orphaned connect", context do
    seed_connect(context, "slack-primary", "T-primary")
    assert :ok = SalixStore.S3.delete(Keys.ctl_group(context.group_id))

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])

    assert {:error, :not_found} = MeetingEnrollment.resolve(entry())
  end

  test "fails closed when a calendar name is ambiguous across two active accounts", context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-1", context.group_id, "ACTIVE", "googlecalendar"),
      account("ca-2", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-x", "summary" => "Comma Event"}])
    stub_channels([%{"id" => "C0BOTARENA", "name" => "botarena", "is_member" => true}])

    assert {:error, {:calendar_ambiguous, "Comma Event"}} = MeetingEnrollment.resolve(entry())
  end

  test "fails closed when the connect is not found" do
    assert {:error, :calendar_enrollment_connect_not_found} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "slack-missing",
               "channel" => "#botarena",
               "calendars" => ["Comma Event"]
             })
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

  test "fails closed when the group has no active google calendar account", context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-x", context.group_id, "INITIATED", "googlecalendar")
    ])

    assert {:error, :calendar_enrollment_no_active_account} =
             MeetingEnrollment.resolve(entry())
  end

  test "preserves producer-shaped Composio account and calendar-list rate limits", context do
    seed_connect(context, "slack-primary", "T-primary")

    MockExternalHTTP.stub(
      "GET",
      "/api/v3/connected_accounts",
      %{"error" => %{"message" => "quota exceeded"}},
      429
    )

    assert {:error, {:calendar_enrollment_account, {:http, 429}}} =
             MeetingEnrollment.resolve(entry())

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS",
      %{"error" => %{"message" => "quota exceeded"}},
      429
    )

    assert {:error, {:calendar_enrollment_list, {:http, 429}}} =
             MeetingEnrollment.resolve(entry())
  end

  test "fails closed when a calendar name matches no calendar", context do
    seed_connect(context, "slack-primary", "T-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "me@x", "summary" => "me@x", "primary" => true}])

    assert {:error, {:calendar_not_found, "Comma Event"}} = MeetingEnrollment.resolve(entry())
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
    @channel channel
    @expected expected
    test "fails closed when #{label}", context do
      seed_connect(context, "slack-primary", "T-primary")

      stub_accounts(context.group_id, [
        account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
      ])

      stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
      stub_source_lifecycle(context.group_id, "ca-cal")
      stub_channels([@channel])

      assert {:error, @expected} == MeetingEnrollment.resolve(entry())
    end
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

  test "resolves a stable calendar ID selector and create_calendar for Feishu", context do
    seed_feishu_connect(context, "feishu-primary")

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Renamed Team Calendar"}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    assert {:ok, resolved} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "feishu-primary",
               "mode" => "notify",
               "chat_id" => "oc_team",
               "calendars" => ["cal-comma"],
               "create_calendar" => "cal-comma",
               "mentions" => %{"mode" => "none", "users" => []}
             })

    assert [%{"calendar_id" => "cal-comma"}] = resolved["calendars"]
    assert resolved["create_calendar"]["name"] == "cal-comma"
    assert resolved["create_calendar"]["calendar_id"] == "cal-comma"
  end

  test "preserves the Feishu create_calendar selector when a name and ID alias one calendar",
       context do
    seed_feishu_connect(context, "feishu-primary")
    agent_id = seed_agent(context)

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([
      %{"id" => "cal-team", "summary" => "Team"},
      %{"id" => "cal-exec", "summary" => "Executive"}
    ])

    stub_source_lifecycle(context.group_id, "ca-cal")

    entry = %{
      "connect_id" => "feishu-primary",
      "mode" => "notify",
      "chat_id" => "oc_team",
      "calendars" => ["Team", "cal-team", "Executive"],
      "create_calendar" => "cal-team",
      "mentions" => %{"mode" => "none", "users" => []}
    }

    assert {:ok, resolved} = MeetingEnrollment.resolve(entry)
    assert resolved["create_calendar"]["calendar_id"] == "cal-team"

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

    assert {:ok, policy} = MeetingCalendarPolicy.get(agent_id, "feishu-primary")
    assert policy["calendar_name"] == "cal-team"
    assert policy["calendar_id"] == "cal-team"
    assert policy["readiness"] == "ACTIVE"
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
    @failure failure
    @expected {:error, {:calendar_source_maintenance, maintenance_reason}}
    test label, context do
      seed_feishu_connect(context, "feishu-primary")
      agent_id = seed_agent(context)

      stub_accounts(context.group_id, [
        account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
      ])

      stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
      stub_source_lifecycle(context.group_id, "ca-cal")
      stub_policy_source_failure(@failure)

      entry = feishu_entry(["Comma Event"], "Comma Event")
      Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

      assert @expected == MeetingCalendarPolicy.get(agent_id, "feishu-primary")
      assert @expected == MeetingCalendarPolicy.get(agent_id, "feishu-primary")
    end
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
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

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

  test "keeps an active source permission failure until a successful repair supersedes it",
       context do
    seed_feishu_connect(context, "feishu-primary")
    agent_id = seed_agent(context)

    stub_accounts(context.group_id, [
      account("ca-cal", context.group_id, "ACTIVE", "googlecalendar")
    ])

    stub_calendars([%{"id" => "cal-comma", "summary" => "Comma Event"}])
    stub_source_lifecycle(context.group_id, "ca-cal")

    entry = feishu_entry(["Comma Event"], "Comma Event")
    assert {:ok, resolved} = MeetingEnrollment.resolve(entry)
    [%{"source_id" => source_id}] = resolved["calendars"]

    assert {:ok, _source} =
             SalixStore.CasRecord.update(
               Keys.ctl_calendar_source(context.group_id, resolved["calendar_id"], source_id),
               fn source ->
                 update_in(source, ["sync"], fn sync ->
                   sync
                   |> Map.put("attempted_at", 0)
                   |> Map.put("completed_at", 0)
                 end)
               end
             )

    stub_proxy_event_error(403, "forbidden")
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

    expected =
      {:error, {:calendar_source_maintenance, {:google_calendar_http, 403}}}

    assert ^expected = MeetingCalendarPolicy.get(agent_id, "feishu-primary")
    assert ^expected = MeetingCalendarPolicy.get(agent_id, "feishu-primary")

    assert {:ok, source} =
             Calendar.get_source(context.group_id, resolved["calendar_id"], source_id)

    assert get_in(source, ["sync", "last_outcome", "reason"]) == %{
             "kind" => "google_calendar_http",
             "status" => 403
           }

    MockExternalHTTP.stub("POST", @proxy_execute_path, &calendar_proxy_response/1)

    assert {:ok, %{"sync_status" => "active"}} =
             GoogleCalendarWatch.repair(
               context.group_id,
               resolved["calendar_id"],
               source_id,
               System.system_time(:millisecond) + 8 * 60 * 60 * 1_000
             )

    assert {:ok, policy} = MeetingCalendarPolicy.get(agent_id, "feishu-primary")
    assert policy["readiness"] == "ACTIVE"
  end

  test "Feishu notify enrollment fails closed for a disconnected app", context do
    seed_feishu_connect(context, "feishu-primary", %{"status" => "error"})

    assert {:error, :calendar_enrollment_connect_not_found} =
             MeetingEnrollment.resolve(%{
               "connect_id" => "feishu-primary",
               "mode" => "notify",
               "chat_id" => "oc_team",
               "calendars" => ["Comma Event"],
               "create_calendar" => "Comma Event",
               "mentions" => %{"mode" => "none", "users" => []}
             })
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

  defp seed_agent(context) do
    agent_id = Ids.new_agent_id(context.group_id)

    assert {:ok, _record} =
             SalixStore.CasRecord.create(
               Keys.ctl_agent(agent_id),
               %{
                 "agent_id" => agent_id,
                 "tenant_id" => context.tenant_id,
                 "group_id" => context.group_id,
                 "role" => "worker",
                 "heartbeat_schedule_id" => "heartbeat-#{agent_id}"
               }
             )

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
            "expiration" => System.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1_000
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

  defp stub_policy_source_failure({:proxy_event_error, status, reason}),
    do: stub_proxy_event_error(status, reason)

  defp stub_policy_source_failure(:tool_router_503) do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"error" => %{"message" => "temporary proxy outage"}},
      503
    )
  end

  defp stub_proxy_event_error(status, reason) do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      fn request ->
        if String.ends_with?(request["endpoint"] || "", "/events") do
          %{
            "status" => status,
            "data" => %{
              "error" => %{
                "errors" => [%{"reason" => reason}],
                "message" => "redacted test error"
              }
            }
          }
        else
          calendar_proxy_response(request)
        end
      end
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

  defp account(id, user_id, status, toolkit) do
    %{"id" => id, "user_id" => user_id, "status" => status, "toolkit" => %{"slug" => toolkit}}
  end

  defp legacy_event do
    %{
      "id" => "legacy-v2-event",
      "iCalUID" => "legacy-v2-event@example.com",
      "summary" => "Legacy v2 meeting",
      "status" => "confirmed",
      "sequence" => 1,
      "updated" => "2030-01-01T00:00:00Z",
      "start" => %{"dateTime" => "2030-01-01T10:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-01-01T11:00:00Z", "timeZone" => "Etc/UTC"},
      "organizer" => %{"self" => true, "email" => "owner@example.com"}
    }
  end

  defp unix_ms(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(datetime, :millisecond)
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

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
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
