defmodule Salix.Bindings.LarkCalendarMeetingTest do
  @moduledoc """
  Team preparation on a Feishu/Lark bot, with the platform's OpenAPI faked:
  the settings page saves a team calendar and a chat, the enrollment reads
  the calendar as the app, a meeting with a Feishu video link becomes a plan
  on the system track, its people come from the event's attendee list, and
  each gets a private notice addressed by open_id. Without the shared notice
  no chat is needed.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias Salix.Bindings.{
    LarkCalendarSource,
    LarkMeetingPersonalPreparation,
    MeetingCalendar,
    MeetingEnrollment,
    MeetingPersonalPublication,
    MeetingPreparationDashboard
  }

  alias SalixIM.Conversations
  alias SalixMeet.{CalendarEnrollmentCache, MeetingPlan}
  alias SalixStore.{CasRecord, Ids, Keys, MeetingCalendarSettings, S3}

  @team_calendar "feishu.cn_team@group.calendar.feishu.cn"
  @chat "oc_team"
  @meeting_url "https://vc.feishu.cn/j/123456789"

  defmodule FakeLark do
    @moduledoc "The Calendar v4 and IM reads the team preparation makes."
    use Agent
    import Plug.Conn

    def start_link(_opts),
      do: Agent.start_link(fn -> %{requests: [], events: [], removed: []} end, name: __MODULE__)

    def events(events), do: Agent.update(__MODULE__, &Map.put(&1, :events, events))

    def change(calendar, events),
      do: Agent.update(__MODULE__, &Map.put(&1, {:changes, calendar}, events))

    def remove(open_id),
      do: Agent.update(__MODULE__, &Map.update!(&1, :removed, fn r -> [open_id | r] end))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def requests(suffix), do: Enum.filter(requests(), &String.ends_with?(&1.path, suffix))
    def sent, do: Enum.filter(requests("/im/v1/messages"), &(&1.method == "POST"))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      path = "/" <> Enum.join(conn.path_info, "/")
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      request = %{method: conn.method, path: path, body: body, query: conn.query_params}
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer(conn.method, path, request)))
    end

    defp ok(data), do: %{"code" => 0, "msg" => "success", "data" => data}

    defp answer("POST", "/open-apis/auth/v3/tenant_access_token/internal", _request),
      do: %{"code" => 0, "tenant_access_token" => "t-bot", "expire" => 7200}

    defp answer("POST", "/open-apis/calendar/v4/calendars/primary", _request),
      do:
        ok(%{
          "calendars" => [%{"calendar" => %{"calendar_id" => "ann_primary", "type" => "primary"}}]
        })

    defp answer("GET", "/open-apis/calendar/v4/calendars", _request),
      do:
        ok(%{
          "has_more" => false,
          "calendar_list" => [
            %{
              "calendar_id" => "feishu.cn_freebusy@group.calendar.feishu.cn",
              "summary" => "Leave",
              "type" => "shared",
              "role" => "free_busy_reader"
            },
            %{
              "calendar_id" => "feishu.cn_team@group.calendar.feishu.cn",
              "summary" => "Team meetings",
              "type" => "shared",
              "role" => "reader"
            },
            %{
              "calendar_id" => "feishu.cn_eng@group.calendar.feishu.cn",
              "summary" => "Engineering",
              "type" => "shared",
              "role" => "reader"
            }
          ]
        })

    defp answer("GET", "/open-apis/calendar/v4/calendars/" <> rest, request) do
      cond do
        String.ends_with?(rest, "/attendees") ->
          removed = Agent.get(__MODULE__, & &1.removed)

          ok(%{
            "has_more" => false,
            "items" =>
              Enum.reject(
                [
                  attendee("ou_ann", "Ann", true),
                  attendee("ou_bob", "Bob", false),
                  Map.put(attendee("ou_cat", "Cat", false), "rsvp_status", "decline"),
                  Map.put(attendee("ou_out", "Outsider", false), "is_external", true),
                  %{"type" => "chat", "chat_id" => "oc_any", "display_name" => "A group"},
                  %{"type" => "resource", "room_id" => "omm_room", "display_name" => "Room 1"}
                ],
                &(&1["user_id"] in removed)
              )
          })

        String.ends_with?(rest, "/events") ->
          calendar = rest |> String.trim_trailing("/events") |> URI.decode()
          state = Agent.get(__MODULE__, & &1)

          # A change scripted for one calendar arrives on its next delta read.
          case {request.query["sync_token"], Map.get(state, {:changes, calendar}, [])} do
            {nil, _changes} ->
              ok(%{"has_more" => false, "items" => state.events, "sync_token" => "sync-1"})

            {_token, changes} ->
              ok(%{"has_more" => false, "items" => changes, "sync_token" => "sync-2"})
          end

        String.contains?(rest, "/events/") ->
          event_id = rest |> String.split("/events/") |> List.last() |> URI.decode()
          events = Agent.get(__MODULE__, & &1.events)
          ok(%{"event" => Enum.find(events, &(&1["event_id"] == event_id))})

        true ->
          ok(%{"calendar_id" => URI.decode(rest), "type" => "shared", "role" => "reader"})
      end
    end

    defp answer("GET", "/open-apis/im/v1/chats/oc_team", _request),
      do:
        ok(%{
          "chat_id" => "oc_team",
          "name" => "Team",
          "chat_mode" => "group",
          "chat_type" => "private",
          "chat_status" => "normal"
        })

    defp answer("GET", "/open-apis/im/v1/chats", _request),
      do:
        ok(%{
          "has_more" => false,
          "items" => [%{"chat_id" => "oc_team", "name" => "Team", "chat_type" => "private"}]
        })

    defp answer("GET", "/open-apis/im/v1/messages", %{query: %{"container_id" => "oc_team"}}),
      do:
        ok(%{
          "has_more" => false,
          "items" => [
            %{
              "message_id" => "om_1",
              "chat_id" => "oc_team",
              "msg_type" => "text",
              "create_time" => "1893456000000",
              "sender" => %{"id" => "ou_bob", "id_type" => "open_id", "sender_type" => "user"},
              "body" => %{"content" => ~s({"text":"Pricing page copy is done."})}
            }
          ]
        })

    defp answer("POST", "/open-apis/im/v1/messages", request),
      do:
        ok(%{
          "message_id" => "om_" <> request.body["receive_id"],
          "chat_id" => "oc_dm_" <> request.body["receive_id"],
          "msg_type" => "text"
        })

    # The directory knows ann by email; a connect without the scope is
    # refused.
    defp answer("POST", "/open-apis/contact/v3/users/batch_get_id", %{body: body}) do
      if body["emails"] == ["denied@example.test"] do
        %{
          "code" => 99_991_672,
          "msg" => "Access denied. scope required: contact:user.id:readonly"
        }
      else
        ok(%{
          "user_list" =>
            for email <- body["emails"] do
              if email == "ann@example.test",
                do: %{"email" => email, "user_id" => "ou_ann"},
                else: %{"email" => email}
            end
        })
      end
    end

    defp answer(_method, _path, _request), do: %{"code" => 99_999, "msg" => "not faked"}

    defp attendee(open_id, name, organizer),
      do: %{
        "type" => "user",
        "user_id" => open_id,
        "display_name" => name,
        "is_organizer" => organizer,
        "is_external" => false,
        "rsvp_status" => "accept"
      }
  end

  defmodule SignedIn do
    @moduledoc "One person signed in with the app."
    @behaviour SalixIM.Ports.LarkUserAccounts

    @impl true
    def list(_group_id),
      do:
        {:ok,
         [%{"alias" => "lark-ann", "open_id" => "ou_ann", "name" => "Ann", "status" => "active"}]}

    @impl true
    def access_token(_agent_id, "lark-ann"), do: {:ok, "u-ann"}
    def access_token(_agent_id, _alias), do: {:error, :not_found}
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      adapters: SystemsRuntime.get_env(:salix_calendar, :source_adapters),
      runtime: SystemsRuntime.get_env(:salix_meet, :agent_runtime_mod),
      base: SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
      feishu_base: SystemsRuntime.get_env(:salix_im, :feishu_api_base_url),
      accounts: SystemsRuntime.get_env(:salix_im, :lark_user_accounts_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    SystemsRuntime.put_env(:salix_calendar, :source_adapters, %{
      "lark_calendar" => LarkCalendarSource,
      "feishu_calendar" => LarkCalendarSource
    })

    SystemsRuntime.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)
    SalixAgent.TestSupport.configure_control_fixtures!()

    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(FakeLark)

    bandit =
      start_supervised!({Bandit, plug: FakeLark, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SalixIM.Provider.Lark.API.reset_token_cache()
    SalixIM.Provider.Feishu.API.reset_token_cache()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_id = Ids.new_agent_id(group_id)
    # Saved settings outlive a test, and a connect has one setting.
    connect_id = "lark-meetings-" <> group_id

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Router",
      "role" => "router"
    })

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "tenant_id" => tenant_id,
      "router_agent_id" => router_id
    })

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "lark",
               "status" => "connected",
               "events" => "socket",
               "app_id" => "cli_meetings",
               "app_secret" => "secret",
               "bot_open_id" => "ou_bot"
             })

    feishu_connect_id = "feishu-meetings-" <> group_id

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, feishu_connect_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => feishu_connect_id,
               "provider" => "feishu",
               "status" => "connected",
               "app_id" => "cli_feishu_meetings",
               "app_secret" => "secret",
               "bot_open_id" => "ou_bot"
             })

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_calendar, :source_adapters, previous.adapters)
      restore_env(:salix_meet, :agent_runtime_mod, previous.runtime)
      restore_env(:salix_im, :lark_api_base_url, previous.base)
      restore_env(:salix_im, :feishu_api_base_url, previous.feishu_base)
      restore_env(:salix_im, :lark_user_accounts_mod, previous.accounts)
      SalixIM.Provider.Lark.API.reset_token_cache()
      SalixIM.Provider.Feishu.API.reset_token_cache()
    end)

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     connect_id: connect_id,
     feishu_connect_id: feishu_connect_id}
  end

  describe "normalization" do
    test "a weekly series keeps its end, its Feishu meeting and its organizer" do
      assert {:ok, record} =
               LarkCalendarSource.normalize(
                 event("uid-weekly_0", 1_893_456_000,
                   recurrence: "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO;UNTIL=20300301T015959Z"
                 )
               )

      object = record["object"]
      assert object["start"] == "2030-01-01T08:00:00"
      assert object["timeZone"] == "Asia/Shanghai"
      assert object["duration"] == "PT30M"

      assert [%{"frequency" => "weekly", "byDay" => [%{"day" => "mo"}], "until" => until}] =
               object["recurrenceRules"]

      assert until == "2030-03-01T09:59:59"
      assert get_in(object, ["virtualLocations", "conference", "uri"]) == @meeting_url

      assert get_in(object, ["links", "event", "href"]) =~
               "https://applink.feishu.cn/client/calendar/event/detail"

      assert record["meeting_qualification"] == %{
               "item_eligible" => true,
               "item_reason" => "eligible",
               "authorized" => true,
               "reason" => "lark_meeting"
             }

      assert record["scheduling_identity"]["series_uid"] == "uid-weekly"
      assert record["scheduling_identity"]["scheduling_authority_key"] == "ou_ann"
    end

    test "a third-party Zoom or Teams meeting qualifies; a Google Meet there does not" do
      zoom = "https://us02web.zoom.us/j/81234567890?pwd=abc"

      for {url, reason} <- [
            {zoom, "zoom_meeting"},
            {"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0", "teams_meeting"},
            {"https://vc-sg.larksuite.com/j/123456789", "lark_meeting"}
          ] do
        assert {:ok, record} =
                 "uid-third_0"
                 |> event(1_893_456_000)
                 |> Map.put("vchat", %{"vc_type" => "third_party", "meeting_url" => url})
                 |> LarkCalendarSource.normalize()

        assert get_in(record, ["object", "virtualLocations", "conference", "uri"]) == url
        assert %{"authorized" => true, "reason" => ^reason} = record["meeting_qualification"]
      end

      assert {:ok, meet} =
               "uid-meet_0"
               |> event(1_893_456_000)
               |> Map.put("vchat", %{
                 "vc_type" => "third_party",
                 "meeting_url" => "https://meet.google.com/abc-defg-hij"
               })
               |> LarkCalendarSource.normalize()

      refute get_in(meet, ["object", "virtualLocations"])
      assert meet["meeting_qualification"]["reason"] == "no_supported_conference"
    end

    test "an exception changes one occurrence; a cancelled one excludes it" do
      moved =
        event("uid-weekly_1893456000", 1_893_459_600, recurring_event_id: "uid-weekly_0")
        |> Map.put("is_exception", true)

      assert {:ok, patch} = LarkCalendarSource.normalize(moved)
      assert patch["external_locator"] == %{"event_id" => "uid-weekly_0"}

      assert %{"2030-01-01T08:00:00" => %{"start" => "2030-01-01T09:00:00"}} =
               patch["object_patch"]["recurrenceOverrides"]

      assert patch["source_version_patch"] == %{
               "recurrence_instances" => %{"2030-01-01T08:00:00" => "uid-weekly_1893456000"}
             }

      assert {:ok, cancelled} =
               LarkCalendarSource.normalize(Map.put(moved, "status", "cancelled"))

      assert cancelled["object_patch"]["recurrenceOverrides"] == %{
               "2030-01-01T08:00:00" => %{"excluded" => true}
             }
    end

    test "copies are ordered by when their read was sent, not when it was answered" do
      # The read of the old content was sent first and answered last.
      {:ok, new} =
        LarkCalendarSource.normalize(event("uid-moved_0", 1_893_459_600), requested_at: 2_000)

      {:ok, old} =
        LarkCalendarSource.normalize(event("uid-moved_0", 1_893_456_000), requested_at: 1_000)

      copies = [
        Map.put(old, "calendar_item_id", "cit-b"),
        Map.put(new, "calendar_item_id", "cit-a")
      ]

      assert {:ok, %{"calendar_item_id" => "cit-a"}} =
               SalixCalendar.SchedulingLink.select_item(copies)

      # Reads of two calendars sent in the same microsecond still order, so
      # copies never tie (a tie would stop the calendar's whole scan).
      refute LarkCalendarSource.request_stamp(%{"source_id" => "csrc_a"}) ==
               LarkCalendarSource.request_stamp(%{"source_id" => "csrc_b"})
    end

    test "a cancelled event is a tombstone; an unsupported rule never qualifies" do
      assert {:ok, %{"tombstone" => true}} =
               LarkCalendarSource.normalize(
                 Map.put(event("uid-gone_0", 1_893_456_000), "status", "cancelled")
               )

      assert {:ok, counted} =
               LarkCalendarSource.normalize(
                 event("uid-count_0", 1_893_456_000, recurrence: "FREQ=WEEKLY;COUNT=3")
               )

      assert counted["normalization_state"] == "unsupported_timing"
      assert counted["meeting_qualification"]["authorized"] == false

      assert {:ok, linkless} =
               LarkCalendarSource.normalize(
                 Map.delete(event("uid-room_0", 1_893_456_000), "vchat")
               )

      assert linkless["meeting_qualification"]["reason"] == "no_supported_conference"
    end
  end

  test "a team calendar meeting is prepared and each attendee gets a private notice", ctx do
    start = div(SystemsClock.system_time(:millisecond), 1_000) + 3 * 60 * 60
    FakeLark.events([event("uid-standup_0", start)])

    assert {:ok, %{"calendars" => calendars, "channels" => channels}} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "catalog", %{
               "connect_id" => ctx.connect_id
             })

    # Only a calendar whose events the app can read is offered.
    assert [
             %{"account_id" => "app", "calendar_id" => @team_calendar, "name" => "Team meetings"},
             %{"name" => "Engineering"}
           ] = Enum.map(calendars, &Map.take(&1, ~w(account_id calendar_id name)))

    assert [%{"id" => @chat, "name" => "Team"}] =
             Enum.map(channels, &Map.take(&1, ~w(id name)))

    assert {:ok, settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "channel_id" => @chat,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar}
               ],
               "preparation_lead_minutes" => 15,
               "research_enabled" => true,
               "personal_preparation" => true,
               "channel_notice" => true
             })

    assert settings["provider"] == "lark"
    assert settings["mode"] == "prepare"
    assert settings["chat_id"] == @chat

    group = enrolled_group!(ctx)
    assert group["provider"] == "lark"
    assert group["chat_id"] == @chat
    assert [%{"account_id" => "app", "calendar_id" => @team_calendar}] = group["calendars"]

    # The calendar is read as the app, a day back on the first read.
    assert [%{query: %{"anchor_time" => _}} | _] = FakeLark.requests("/events")

    assert {:ok, [event]} =
             MeetingCalendar.list(group, start * 1_000 - 60_000, start * 1_000 + 60_000)

    assert event["meet_url"] == @meeting_url
    assert {:ok, plan} = MeetingPlan.get(ctx.group_id, event["meeting_plan_id"])
    assert MeetingPlan.system_track?(plan)

    assert plan["publication_target"] == %{
             "provider" => "lark",
             "tool" => "im_api.lark.send_message",
             "params" => %{"connect_id" => ctx.connect_id, "chat_id" => @chat}
           }

    # The notice keeps the team's lead time, not the old seven minutes.
    assert plan["preparation"]["card_at"] == start * 1_000 - :timer.minutes(15)
    assert Map.has_key?(plan["preparation"]["schedule_ids"], "personal")

    # The people are the event's internal user attendees who did not decline.
    assert {:ok, ["ou_ann", "ou_bob"]} = LarkMeetingPersonalPreparation.roster(plan)

    # The Worker reads the notice chat, with the arguments its tool declares.
    pattern =
      Regex.compile!(
        SalixAgent.Tools.Schemas.schema("meeting.preparation.read_shared_source")["properties"][
          "channel"
        ]["pattern"]
      )

    assert Regex.match?(pattern, @chat)

    assert {:ok, page} =
             SalixMeet.PreparationSources.read(plan, %{
               "channel" => @chat,
               "operation" => "history"
             })

    assert page["source_label"] == ["scope|#{ctx.connect_id}|#{@chat}"]

    assert [%{"sender" => %{"sender_type" => "user"}, "text" => "Pricing page copy is done."}] =
             page["messages"]

    # A private chat other than the notice chat is no source.
    assert {:error, _} =
             SalixMeet.PreparationSources.read(plan, %{
               "channel" => "oc_other",
               "operation" => "history"
             })

    # The receiver runs again until every discovered person is served.
    payload = %{"group_id" => ctx.group_id, "meeting_plan_id" => plan["meeting_plan_id"]}

    assert {:ok, :fired} =
             Enum.reduce_while(1..5, nil, fn _, _ ->
               case MeetingPersonalPublication.receive(payload,
                      now: plan["preparation"]["card_at"]
                    ) do
                 {:ok, :continue} = result -> {:cont, result}
                 result -> {:halt, result}
               end
             end)

    assert {:ok, conversation} = SalixIM.RouterConversationInput.ensure(ctx.group_id)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               ctx.group_id,
               conversation["conversation_id"],
               limit: 100
             )

    direct =
      for %{"actor_type" => "provider", "provider" => "lark"} = participant <- participants,
          do: participant["payload"]

    assert Enum.sort(Enum.map(direct, & &1["receive_open_id"])) == ["ou_ann", "ou_bob"]
    assert Enum.all?(direct, &(&1["connect_id"] == ctx.connect_id and is_nil(&1["chat_id"])))

    # Lark puts each notice in the person's private chat with the bot.
    settle_until(fn -> length(FakeLark.sent()) == 2 end)
    sent = FakeLark.sent()
    assert Enum.all?(sent, &(&1.query["receive_id_type"] == "open_id"))
    assert Enum.sort(Enum.map(sent, & &1.body["receive_id"])) == ["ou_ann", "ou_bob"]
    assert Enum.all?(sent, &(&1.body["content"] =~ "Join meeting"))
  end

  test "without the shared notice no chat is needed and only personal notices go out", ctx do
    start = div(SystemsClock.system_time(:millisecond), 1_000) + 3 * 60 * 60
    FakeLark.events([event("uid-review_0", start)])

    assert {:ok, settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar}
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "personal_preparation" => true,
               "channel_notice" => false
             })

    assert settings["chat_id"] == ""

    group = enrolled_group!(ctx)

    assert {:ok, [event]} =
             MeetingCalendar.list(group, start * 1_000 - 60_000, start * 1_000 + 60_000)

    assert {:ok, plan} = MeetingPlan.get(ctx.group_id, event["meeting_plan_id"])

    assert plan["publication_target"] == %{
             "provider" => "lark",
             "tool" => "none",
             "params" => %{"connect_id" => ctx.connect_id}
           }

    assert MeetingPlan.system_track?(plan)
    assert plan["channel_notice"] == false
  end

  test "a meeting on two selected team calendars is prepared once", ctx do
    start = div(SystemsClock.system_time(:millisecond), 1_000) + 3 * 60 * 60
    # Both calendars answer with the same event, as Lark does for one meeting.
    FakeLark.events([event("uid-shared_0", start)])

    assert {:ok, _settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "channel_id" => @chat,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar},
                 %{
                   "account_id" => "app",
                   "calendar_id" => "feishu.cn_eng@group.calendar.feishu.cn"
                 }
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "personal_preparation" => true,
               "channel_notice" => true
             })

    group = enrolled_group!(ctx)
    assert length(group["calendars"]) == 2

    assert {:ok, [first]} =
             MeetingCalendar.list(group, start * 1_000 - 60_000, start * 1_000 + 60_000)

    # The meeting moves; one calendar has read the change and the other not
    # yet. The copy read last is the meeting, so the moved time stands.
    moved = start + 30 * 60
    eng = Enum.find(group["calendars"], &(&1["calendar_id"] =~ "eng"))
    FakeLark.change("feishu.cn_eng@group.calendar.feishu.cn", [event("uid-shared_0", moved)])
    SystemsClock.advance(1_000)

    assert {:ok, _} =
             SalixCalendar.Server.refresh_source(
               ctx.group_id,
               group["calendar_id"],
               eng["source_id"],
               %{
                 "group_id" => ctx.group_id,
                 "object_type" => "Event",
                 "page_size" => 200
               }
             )

    assert {:ok, [current]} =
             MeetingCalendar.list(group, start * 1_000 - 60_000, moved * 1_000 + 60_000)

    assert current["start_ms"] == moved * 1_000
    assert current["meeting_plan_id"] != nil and first["start_ms"] == start * 1_000
  end

  test "a Feishu bot prepares a team calendar meeting the same way", ctx do
    start = div(SystemsClock.system_time(:millisecond), 1_000) + 3 * 60 * 60
    FakeLark.events([event("uid-feishu_0", start)])

    assert {:ok, settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.feishu_connect_id,
               "channel_id" => @chat,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar}
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "personal_preparation" => true,
               "channel_notice" => true
             })

    assert settings["provider"] == "feishu"
    group = enrolled_group!(ctx, "feishu")
    assert group["provider"] == "feishu"

    assert {:ok, [event]} =
             MeetingCalendar.list(group, start * 1_000 - 60_000, start * 1_000 + 60_000)

    assert {:ok, plan} = MeetingPlan.get(ctx.group_id, event["meeting_plan_id"])
    assert MeetingPlan.system_track?(plan)
    assert plan["publication_target"]["provider"] == "feishu"
    assert plan["publication_target"]["params"]["receive_id"] == @chat
    assert {:ok, ["ou_ann", "ou_bob"]} = LarkMeetingPersonalPreparation.roster(plan)

    payload = %{"group_id" => ctx.group_id, "meeting_plan_id" => plan["meeting_plan_id"]}

    assert {:ok, :fired} =
             Enum.reduce_while(1..5, nil, fn _, _ ->
               case MeetingPersonalPublication.receive(payload,
                      now: plan["preparation"]["card_at"]
                    ) do
                 {:ok, :continue} = result -> {:cont, result}
                 result -> {:halt, result}
               end
             end)

    settle_until(fn -> length(FakeLark.sent()) == 2 end)
    sent = FakeLark.sent()
    assert Enum.all?(sent, &(&1.query["receive_id_type"] == "open_id"))
    assert Enum.sort(Enum.map(sent, & &1.body["receive_id"])) == ["ou_ann", "ou_bob"]
  end

  test "members' calendars are read with each sign-in and their meetings remind current attendees",
       ctx do
    SystemsRuntime.put_env(:salix_im, :lark_user_accounts_mod, SignedIn)
    start = div(SystemsClock.system_time(:millisecond), 1_000) + 3 * 60 * 60
    FakeLark.events([event("uid-one-on-one_0", start)])

    assert {:ok, %{"member_accounts" => 1}} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "catalog", %{
               "connect_id" => ctx.connect_id,
               "calendar_scope" => "members"
             })

    assert {:ok, _settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "calendar_scope" => "members",
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "personal_preparation" => true
             })

    group = enrolled_group!(ctx)
    assert [%{"account_id" => "lark-ann", "account_email" => "ou_ann"} = unit] = group["units"]
    assert [%{"calendar_id" => "ann_primary"}] = unit["calendars"]

    # The primary calendar is read with the person's own token.
    assert [%{path: path} | _] = FakeLark.requests("/events")
    assert path =~ "ann_primary"

    unit_group =
      group
      |> Map.drop(["units"])
      |> Map.merge(%{
        "calendar_id" => unit["calendar_id"],
        "calendars" => unit["calendars"],
        "account_email" => unit["account_email"],
        "member_emails" => ["ou_ann"]
      })

    assert {:ok, [event]} =
             MeetingCalendar.list(unit_group, start * 1_000 - 60_000, start * 1_000 + 60_000)

    assert {:ok, plan} = MeetingPlan.get(ctx.group_id, event["meeting_plan_id"])
    # The claiming member's copy reminds every current attendee.
    assert is_nil(plan["personal_recipients"])
    assert plan["channel_notice"] == false
    assert {:ok, ["ou_ann", "ou_bob"]} = LarkMeetingPersonalPreparation.roster(plan)

    # Someone taken off the meeting before the reminder gets none.
    FakeLark.remove("ou_bob")

    assert {:ok, [%{"user_id" => "ou_ann", "name" => "Ann"}]} =
             LarkMeetingPersonalPreparation.current_recipients(plan, [
               %{"user_id" => "ou_ann"},
               %{"user_id" => "ou_bob"}
             ])
  end

  test "saving refuses a calendar the app cannot read and a notice without a chat", ctx do
    assert {:error, :invalid_meeting_preparation_settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "channel_id" => @chat,
               "calendar_selections" => [
                 %{
                   "account_id" => "app",
                   "calendar_id" => "feishu.cn_freebusy@group.calendar.feishu.cn"
                 }
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false
             })

    assert {:error, :meeting_channel_invalid} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar}
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "channel_notice" => true
             })
  end

  test "joining is a switch of its own, and the Group's bots join Feishu and Lark links", ctx do
    assert {:ok, settings} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "save", %{
               "enabled" => true,
               "connect_id" => ctx.connect_id,
               "channel_id" => @chat,
               "calendar_selections" => [
                 %{"account_id" => "app", "calendar_id" => @team_calendar}
               ],
               "preparation_lead_minutes" => 10,
               "research_enabled" => false,
               "autojoin" => true
             })

    assert settings["mode"] == "join"
    assert settings["calendar_source"] == "feishu_lark"
    assert is_integer(settings["destination_confirmed_at"])

    group = enrolled_group!(ctx)
    assert group["mode"] == "join"
    assert group["lark_join"] == %{"lark" => ctx.connect_id, "feishu" => ctx.feishu_connect_id}

    # The page and the Router read the same choice; with no Slack bot there
    # is nothing to choose between.
    assert {:ok, %{"settings" => %{"calendar_source" => "feishu_lark"}}} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "overview", %{})

    assert {:ok, %{"status" => "confirmed", "current" => current, "options" => options}} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "destination", %{})

    assert %{"platform" => "lark", "connect_id" => connect_id, "chat_id" => @chat} = current
    assert connect_id == ctx.connect_id
    assert Enum.map(options, & &1["platform"]) |> Enum.sort() == ["feishu", "lark"]

    # Another bot cannot read this bot's own calendars.
    assert {:error, :meeting_destination_unsupported} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "set_destination", %{
               "connect_id" => ctx.feishu_connect_id
             })
  end

  test "with a Slack bot too and nobody's choice, the Router asks and one notice says so once",
       ctx do
    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(ctx.group_id, "slack-" <> ctx.group_id), %{
               "tenant_id" => ctx.tenant_id,
               "group_id" => ctx.group_id,
               "connect_id" => "slack-" <> ctx.group_id,
               "provider" => "slack",
               "workspace_id" => "T1",
               "bot_token" => "xoxb-test",
               "oauth_completed_at" => 1
             })

    # A setting saved before the choice existed.
    assert {:ok, _} =
             MeetingCalendarSettings.put(
               ctx.group_id,
               ctx.tenant_id,
               %{
                 "enabled" => true,
                 "provider" => "lark",
                 "connect_id" => ctx.connect_id,
                 "mode" => "prepare",
                 "calendar_scope" => "selected",
                 "chat_id" => @chat,
                 "channel_id" => @chat
               },
               fn -> :ok end
             )

    assert {:ok, %{"status" => "choice_needed", "options" => options}} =
             MeetingPreparationDashboard.run(ctx.tenant_id, ctx.group_id, "destination", %{})

    assert "slack" in Enum.map(options, & &1["platform"])

    assert SalixMeet.CalendarConfiguration.destination_hint(ctx.group_id, "lark") =~
             "can also go to Slack"

    assert SalixMeet.CalendarConfiguration.destination_hint(ctx.group_id, "lark") == ""
    # The line changed no revision: plans of the setting stay authorized.
    assert {:ok, %{"settings_revision" => 1}} = MeetingCalendarSettings.get(ctx.group_id)
  end

  test "a Google attendee is reminded by the open_id the directory gives for the email", ctx do
    {:ok, lark} = SalixIM.ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect_id)

    assert LarkMeetingPersonalPreparation.open_ids(lark, [
             "ann@example.test",
             "guest@example.test"
           ]) == %{"ann@example.test" => "ou_ann"}

    # Without the directory scope nobody is found, and nothing fails.
    assert LarkMeetingPersonalPreparation.open_ids(lark, ["denied@example.test"]) == %{}
  end

  defp enrolled_group!(ctx, provider \\ "lark") do
    assert {:ok, entry} = MeetingCalendarSettings.get(ctx.group_id)

    identity = %{
      "connect_id" => entry["connect_id"],
      "tenant_id" => ctx.tenant_id,
      "group_id" => ctx.group_id,
      "provider" => provider
    }

    assert {:ok, group} = MeetingEnrollment.resolve(entry, identity)
    group = CalendarEnrollmentCache.sanitize_group(group)
    assert :ok = CalendarEnrollmentCache.put(entry, identity, group, 0)
    group
  end

  defp event(event_id, start, opts \\ []) do
    %{
      "event_id" => event_id,
      "summary" => "Standup",
      "status" => "confirmed",
      "start_time" => %{"timestamp" => Integer.to_string(start), "timezone" => "Asia/Shanghai"},
      "end_time" => %{
        "timestamp" => Integer.to_string(start + 1_800),
        "timezone" => "Asia/Shanghai"
      },
      "vchat" => %{"vc_type" => "vc", "meeting_url" => @meeting_url},
      "app_link" =>
        "https://applink.feishu.cn/client/calendar/event/detail?calendarId=1&key=#{event_id}",
      "event_organizer" => %{"user_id" => "ou_ann", "display_name" => "Ann"},
      "free_busy_status" => "busy",
      "recurrence" => Keyword.get(opts, :recurrence, ""),
      "is_exception" => false
    }
    |> then(fn event ->
      case Keyword.get(opts, :recurring_event_id) do
        nil -> event
        master -> Map.put(event, "recurring_event_id", master)
      end
    end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
