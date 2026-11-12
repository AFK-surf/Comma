defmodule Salix.Bindings.MeetingPreparationDashboard do
  @moduledoc """
  Team meeting preparation settings and bounded dashboard reads.

  The setting's bot (`connect_id`) is where reminders, join notices and
  minutes go. A Slack bot sends the notices of Google calendars; a Feishu or
  Lark bot those of its own calendars or of Google calendars
  (`calendar_source`). `destination_confirmed_at` records that an admin
  chose the bot, on the page (`save`) or from chat (`set_destination`,
  `BridgeForTeams.MeetingDestination`); `destination` reads the choice.
  """
  alias Salix.Control.Groups

  alias Salix.Bindings.{
    GoogleCalendarSource,
    LarkMeetingPreparationDashboard,
    MeetingCalendarStatus,
    MeetingEnrollment
  }

  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixMeet.{CalendarConfiguration, CalendarEnrollmentCache}
  alias SalixStore.MeetingCalendarSettings

  @settings_fields ~w(enabled provider chat_id mode connect_id channel channel_id calendar_scope calendar_source destination_confirmed_at delivery calendars calendar_selections calendar_writeback preparation_lead_minutes research_enabled series personal_preparation channel_notice settings_revision updated_at)
  @dm_scopes ~w(users:read.email im:write chat:write)
  @providers ~w(slack feishu lark)

  def run(tenant_id, group_id, action, attrs) when is_map(attrs) do
    with {:ok, group} <- Groups.get(group_id, tenant_id) do
      dispatch(group, action, attrs)
    end
  rescue
    _ in [API.Error, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :meeting_preparation_unavailable}
  end

  defp dispatch(group, "overview", _attrs) do
    with {:ok, settings} <- settings(group),
         {:ok, connects} <- ProviderConnects.list_group_im_connects(group["group_id"]) do
      connects = Enum.filter(connects, &(&1["provider"] in @providers))

      {:ok,
       %{
         "settings" => settings |> Map.take(@settings_fields) |> put_calendar_source(connects),
         "connects" =>
           Enum.map(
             connects,
             &Map.take(
               &1,
               ~w(connect_id provider app_name bot_username workspace_name workspace_id oauth_completed_at disabled_at oauth_bot_scopes status)
             )
           ),
         "calendar" => status(group, settings),
         "runtime_enabled" => is_list(SystemsRuntime.get_env(:salix_meet, :calendar_autojoin)),
         "personal_available" => false
       }}
    end
  end

  defp dispatch(group, "history", attrs) do
    with {:ok, settings} <- settings(group) do
      Salix.Bindings.MeetingHistory.list(group, settings, attrs["cursor"])
    end
  end

  # Members' own calendars need no calendar picker: the page shows how many
  # Google accounts members have connected.
  # A Feishu/Lark connect has its own chats and calendars.
  defp dispatch(group, action, %{"connect_id" => connect_id} = attrs)
       when action in ~w(catalog channels series search_calendars subscribe_calendar) do
    with {:ok, connect} <- meeting_connect(group, connect_id) do
      cond do
        LarkMeetingPreparationDashboard.provider?(connect) ->
          dispatch_lark(group, connect, action, attrs)

        # A Slack bot cannot send the notices of Feishu/Lark calendars.
        attrs["calendar_source"] == "feishu_lark" ->
          {:error, :meeting_destination_unsupported}

        true ->
          dispatch_slack(group, connect, action, attrs)
      end
    end
  end

  defp dispatch(group, "series", attrs), do: dispatch_slack(group, nil, "series", attrs)

  defp dispatch(group, "save", attrs) do
    with {:ok, configuration} <- configuration(group, attrs), do: save(group, configuration)
  end

  defp dispatch(group, "destination", _attrs) do
    with {:ok, settings} <- settings(group), do: {:ok, destination(group, settings)}
  end

  # From chat: the same setting with another bot (and chat), checked as a
  # save from the page is.
  defp dispatch(group, "set_destination", %{"connect_id" => connect_id} = attrs)
       when is_binary(connect_id) do
    with {:ok, settings} <- settings(group),
         true <- settings["enabled"] == true and is_binary(settings["connect_id"]),
         {:ok, connect} <- meeting_connect(group, connect_id),
         {:ok, attrs} <- destination_attrs(settings, connect, attrs["channel_id"]),
         {:ok, configuration} <- configuration(group, attrs),
         {:ok, saved} <- save(group, configuration) do
      {:ok, destination(group, saved)}
    else
      false -> {:error, :meeting_preparation_not_configured}
      {:error, _} = error -> error
    end
  end

  defp dispatch(group, "detail", %{"meeting_plan_id" => plan_id}) do
    with true <- SalixStore.Ids.valid_meeting_plan_id?(plan_id),
         {:ok, plan} <- SalixMeet.MeetingPlan.get(group["group_id"], plan_id),
         :ok <- CalendarConfiguration.authorize_plan(plan) do
      {:ok, %{"report" => get_in(plan, ["preparation", "report"])}}
    else
      false -> {:error, :meeting_not_found}
      {:error, _} = error -> error
    end
  end

  defp dispatch(_group, _action, _attrs), do: {:error, :invalid_meeting_preparation_request}

  defp dispatch_lark(group, connect, "catalog", attrs),
    do: LarkMeetingPreparationDashboard.catalog(group, connect, attrs)

  defp dispatch_lark(group, connect, "series", %{"calendar_source" => "google"} = attrs) do
    if valid_selections?([attrs]) and valid_text?(attrs["cursor"] || "", 2048),
      do: LarkMeetingPreparationDashboard.series(group, connect, attrs),
      else: {:error, :invalid_meeting_preparation_request}
  end

  defp dispatch_lark(_group, connect, "channels", attrs) do
    if valid_text?(attrs["cursor"] || "", 1024),
      do: {:ok, LarkMeetingPreparationDashboard.channel_page(connect, attrs["cursor"])},
      else: {:error, :invalid_meeting_preparation_settings}
  end

  defp dispatch_lark(group, connect, "series", attrs) do
    if valid_selections?([attrs]),
      do: LarkMeetingPreparationDashboard.series(group, connect, attrs),
      else: {:error, :invalid_meeting_preparation_request}
  end

  defp dispatch_lark(_group, connect, "search_calendars", attrs) do
    with {:ok, calendars} <- LarkMeetingPreparationDashboard.search(connect, attrs["query"] || ""),
         do: {:ok, %{"calendars" => calendars}}
  end

  defp dispatch_lark(_group, connect, "subscribe_calendar", attrs) do
    with {:ok, calendar} <-
           LarkMeetingPreparationDashboard.subscribe(connect, attrs["calendar_id"] || ""),
         do: {:ok, %{"calendar" => calendar}}
  end

  defp dispatch_slack(group, connect, "catalog", %{"calendar_scope" => "members"}) do
    with {:ok, count} <-
           MeetingEnrollment.member_account_count(group["tenant_id"], group["group_id"]) do
      {:ok,
       channel_page(connect, nil)
       |> Map.put("calendars", [])
       |> Map.put("member_accounts", count)}
    end
  end

  defp dispatch_slack(group, connect, "catalog", _attrs) do
    with {:ok, calendars} <- MeetingEnrollment.catalog(group["tenant_id"], group["group_id"]) do
      {:ok, Map.put(channel_page(connect, nil), "calendars", calendars)}
    end
  end

  defp dispatch_slack(_group, connect, "channels", attrs) do
    if valid_text?(attrs["cursor"] || "", 1024),
      do: {:ok, channel_page(connect, attrs["cursor"])},
      else: {:error, :invalid_meeting_preparation_settings}
  end

  defp dispatch_slack(group, _connect, "series", attrs) do
    with true <- valid_selections?([attrs]),
         true <- valid_text?(attrs["cursor"] || "", 2048) do
      source = %{
        "group_id" => group["group_id"],
        "source_locator" => %{
          "connection_id" => attrs["account_id"],
          "external_calendar_id" => attrs["calendar_id"]
        }
      }

      GoogleCalendarSource.upcoming_meetings(source, attrs["cursor"])
    else
      _ -> {:error, :invalid_meeting_preparation_request}
    end
  end

  defp dispatch_slack(_group, _connect, _action, _attrs),
    do: {:error, :invalid_meeting_preparation_request}

  defp settings(group) do
    case MeetingCalendarSettings.get(group["group_id"]) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, :not_found} ->
        {:ok,
         %{
           "enabled" => false,
           "mode" => "prepare",
           "calendars" => [],
           "calendar_selections" => [],
           "preparation_lead_minutes" => 10,
           "research_enabled" => true
         }}
    end
  end

  # Members' calendars are scanned one by one; the page reports how many are
  # enrolled rather than reading every member's projection.
  defp status(_group, %{"enabled" => true, "calendar_scope" => "members"} = settings) do
    case CalendarEnrollmentCache.load(settings) do
      {:ok, %{group: enrolled}} ->
        %{
          "health" => "members",
          "member_calendars" =>
            Enum.count(enrolled["units"] || [], &(List.wrap(&1["calendars"]) != [])),
          "events" => []
        }

      {:error, _} ->
        %{"health" => "pending", "member_calendars" => 0, "events" => []}
    end
  end

  defp status(group, %{"enabled" => true, "connect_id" => connect_id}) do
    case MeetingCalendarStatus.get(group["router_agent_id"], connect_id, 20) do
      {:ok, calendar} -> calendar
      {:error, _} -> %{"health" => "unavailable", "events" => []}
    end
  end

  defp status(_group, _settings), do: %{"health" => "disabled", "events" => []}

  defp active_connect(group, connect_id) when is_binary(connect_id) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group["group_id"], connect_id, "slack"),
         true <- connect["tenant_id"] == group["tenant_id"] do
      {:ok, connect}
    else
      _ -> {:error, :meeting_calendar_connect_unavailable}
    end
  end

  defp active_connect(_group, _connect_id), do: {:error, :meeting_calendar_connect_unavailable}

  # A Slack, Feishu or Lark bot of the Group.
  defp meeting_connect(group, connect_id) when is_binary(connect_id) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group["group_id"], connect_id),
         true <- connect["provider"] in @providers and connect["tenant_id"] == group["tenant_id"] do
      {:ok, connect}
    else
      _ -> {:error, :meeting_calendar_connect_unavailable}
    end
  end

  defp meeting_connect(_group, _connect_id), do: {:error, :meeting_calendar_connect_unavailable}

  defp channel_page(connect, cursor) do
    page =
      API.list_conversation_page(API.installation(connect),
        limit: 100,
        cursor: cursor,
        types: ["public_channel", "private_channel"],
        exclude_archived: true
      )

    %{
      "channels" =>
        page["channels"]
        |> Enum.filter(&(&1["is_member"] == true))
        |> Enum.map(&Map.take(&1, ~w(id name is_private))),
      "next_cursor" => page["next_cursor"]
    }
  end

  # Disabling an existing enrollment remains possible when its provider token
  # has expired. It cannot introduce a new connection or widen any scope.
  defp configuration(group, %{"enabled" => false}) do
    with {:ok, settings} <- settings(group),
         true <- is_binary(settings["connect_id"]) do
      {:ok, settings |> Map.take(@settings_fields) |> Map.put("enabled", false)}
    else
      false -> {:error, :meeting_preparation_not_configured}
    end
  end

  # Members' calendars join and record; preparation, when on, is one direct
  # message per meeting to its organizer (or the member who holds it).
  # A Feishu/Lark bot has its own settings (`LarkMeetingPreparationDashboard`).
  defp configuration(group, %{"enabled" => true, "connect_id" => connect_id} = attrs)
       when is_binary(connect_id) do
    case meeting_connect(group, connect_id) do
      {:ok, %{"provider" => provider} = connect} when provider in ["feishu", "lark"] ->
        LarkMeetingPreparationDashboard.configuration(group, connect, attrs)

      # A Slack bot sends the notices of Google calendars only.
      _ ->
        if Map.get(attrs, "calendar_source", "google") == "google",
          do: slack_configuration(group, attrs),
          else: {:error, :meeting_destination_unsupported}
    end
  end

  defp configuration(group, attrs), do: slack_configuration(group, attrs)

  defp slack_configuration(group, %{"enabled" => true, "calendar_scope" => "members"} = attrs) do
    lead = Map.get(attrs, "preparation_lead_minutes", 10)
    personal = Map.get(attrs, "personal_preparation", false)
    research = Map.get(attrs, "research_enabled", false)

    # Members' calendars joined before joining was a switch: without the
    # field they still join. Without joining they need the personal notice.
    autojoin = Map.get(attrs, "autojoin", true)
    mode = if autojoin == true, do: "join", else: "prepare"

    with true <- is_boolean(autojoin) and (autojoin or personal == true),
         true <- lead in [10, 15, 30, 60] and is_boolean(personal) and is_boolean(research),
         {:ok, delivery} <- delivery(attrs),
         {:ok, connect} <- active_connect(group, attrs["connect_id"]),
         :ok <- delivery_scopes(delivery, connect),
         optional? =
           CalendarConfiguration.team_channel_optional?(%{
             "mode" => mode,
             "delivery" => delivery,
             "personal_preparation" => personal,
             "channel_notice" => false
           }),
         {:ok, %{"id" => channel_id} = channel} <-
           team_channel(connect, attrs["channel_id"], optional?) do
      {:ok,
       %{
         "enabled" => true,
         "connect_id" => connect["connect_id"],
         "mode" => mode,
         "calendar_scope" => "members",
         "calendar_source" => "google",
         "delivery" => delivery,
         "channel" => channel["name"],
         "channel_id" => channel_id,
         "calendar_selections" => [],
         "calendars" => [],
         "calendar_writeback" => false,
         "preparation_lead_minutes" => lead,
         "research_enabled" => personal and research,
         "series" => [],
         "personal_preparation" => personal,
         "channel_notice" => false
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp slack_configuration(group, %{"enabled" => true} = attrs) do
    with true <- valid_selections?(attrs["calendar_selections"]),
         {:ok, delivery} <- delivery(attrs),
         true <- attrs["preparation_lead_minutes"] in [10, 15, 30, 60],
         true <- is_boolean(attrs["research_enabled"]),
         true <- is_boolean(attrs["calendar_writeback"]),
         true <- is_boolean(attrs["autojoin"]),
         true <-
           !Map.has_key?(attrs, "personal_preparation") or
             is_boolean(attrs["personal_preparation"]),
         true <- !Map.has_key?(attrs, "channel_notice") or is_boolean(attrs["channel_notice"]),
         true <- valid_series?(attrs["series"] || [], attrs["calendar_selections"]),
         {:ok, previous} <- settings(group),
         {:ok, connect} <- active_connect(group, attrs["connect_id"]),
         {:ok, personal} <- personal_preparation(attrs, previous, connect),
         :ok <- delivery_scopes(delivery, connect),
         {:ok, catalog} <- MeetingEnrollment.catalog(group["tenant_id"], group["group_id"]),
         true <-
           Enum.all?(attrs["calendar_selections"], fn selection ->
             Enum.any?(catalog, &same_calendar?(&1, selection))
           end),
         # Saving without the field keeps the existing choice; older settings
         # had no field and post the notice.
         channel_notice = Map.get(attrs, "channel_notice", previous["channel_notice"] != false),
         mode = if(attrs["autojoin"], do: "join", else: "prepare"),
         optional? =
           CalendarConfiguration.team_channel_optional?(%{
             "mode" => mode,
             "delivery" => delivery,
             "personal_preparation" => personal,
             "channel_notice" => channel_notice
           }),
         {:ok, %{"id" => channel_id} = channel} <-
           team_channel(connect, attrs["channel_id"], optional?) do
      selected =
        Enum.map(attrs["calendar_selections"], fn selection ->
          Enum.find(catalog, &same_calendar?(&1, selection))
          |> Map.take(~w(account_id calendar_id name account_name))
        end)

      {:ok,
       %{
         "enabled" => true,
         "connect_id" => connect["connect_id"],
         "mode" => mode,
         "calendar_scope" => "selected",
         "calendar_source" => "google",
         "delivery" => delivery,
         "channel" => channel["name"],
         "channel_id" => channel_id,
         "calendar_selections" => selected,
         "calendars" => selected |> Enum.map(& &1["calendar_id"]) |> Enum.uniq(),
         # Without a channel notice the shared report has no calendar audience.
         "calendar_writeback" => attrs["calendar_writeback"] and channel_notice,
         "preparation_lead_minutes" => attrs["preparation_lead_minutes"],
         "research_enabled" => attrs["research_enabled"],
         "series" =>
           Enum.map(
             attrs["series"] || [],
             &Map.take(&1, ~w(account_id calendar_id event_id title))
           ),
         "personal_preparation" => personal,
         "channel_notice" => channel_notice
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp slack_configuration(_group, _attrs), do: {:error, :invalid_meeting_preparation_settings}

  # Saving stamps the admin's choice of where the notices go.
  defp save(group, configuration) do
    configuration =
      Map.put(configuration, "destination_confirmed_at", SystemsClock.system_time(:second))

    MeetingCalendarSettings.put(group["group_id"], group["tenant_id"], configuration, fn ->
      case CalendarConfiguration.entries() do
        {:ok, _entries} -> :ok
        {:error, _} = error -> error
      end
    end)
  end

  # Settings saved before `calendar_source` existed read their bot's own kind
  # of calendar.
  defp put_calendar_source(%{"calendar_source" => _} = settings, _connects), do: settings

  defp put_calendar_source(%{"connect_id" => connect_id} = settings, connects)
       when is_binary(connect_id) do
    provider =
      settings["provider"] ||
        Enum.find_value(connects, &(&1["connect_id"] == connect_id && &1["provider"]))

    if provider in ["feishu", "lark"],
      do: Map.put(settings, "calendar_source", "feishu_lark"),
      else: Map.put(settings, "calendar_source", "google")
  end

  defp put_calendar_source(settings, _connects), do: settings

  # Where reminders, join notices and minutes go, and whether someone must
  # choose: a Group with a Slack bot and a Feishu/Lark bot whose admin has
  # not chosen yet.
  defp destination(group, settings) do
    options = SalixMeet.CalendarConfiguration.meeting_bots(group["group_id"])
    # Slack on one side, Feishu/Lark on the other.
    sides = options |> Enum.map(&(&1["platform"] == "slack")) |> Enum.uniq()

    current =
      if is_binary(settings["connect_id"]) and settings["enabled"] == true do
        option = Enum.find(options, &(&1["connect_id"] == settings["connect_id"])) || %{}
        provider = settings["provider"] || option["platform"] || "slack"

        %{
          "platform" => provider,
          "connect_id" => settings["connect_id"],
          "name" => option["name"] || settings["connect_id"],
          "chat_id" => blank_nil(settings["channel_id"]),
          "chat_name" => blank_nil(settings["channel"]),
          "calendar_source" =>
            settings["calendar_source"] ||
              if(provider in ["feishu", "lark"], do: "feishu_lark", else: "google")
        }
      end

    status =
      cond do
        is_nil(current) -> "not_configured"
        is_integer(settings["destination_confirmed_at"]) -> "confirmed"
        length(sides) > 1 -> "choice_needed"
        true -> "single"
      end

    %{"status" => status, "current" => current, "options" => options}
  end

  # The saved setting as the page would send it, with the other bot. Its
  # chat is the one named, or the same one on the same bot. Google calendars
  # stay; a Feishu/Lark bot's own calendars cannot move to Slack.
  defp destination_attrs(settings, connect, channel_id) do
    lark? = connect["provider"] in ["feishu", "lark"]

    source =
      settings["calendar_source"] ||
        if(settings["provider"] in ["feishu", "lark"], do: "feishu_lark", else: "google")

    channel_id =
      cond do
        is_binary(channel_id) and channel_id != "" -> channel_id
        connect["connect_id"] == settings["connect_id"] -> settings["channel_id"] || ""
        true -> ""
      end

    cond do
      source == "feishu_lark" and not lark? ->
        {:error, :meeting_destination_unsupported}

      source == "feishu_lark" and connect["connect_id"] != settings["connect_id"] ->
        # Another Feishu/Lark bot reads other calendars.
        {:error, :meeting_destination_unsupported}

      true ->
        {:ok,
         settings
         |> Map.take(
           ~w(calendar_scope delivery calendar_selections preparation_lead_minutes research_enabled calendar_writeback personal_preparation channel_notice series)
         )
         |> Map.merge(%{
           "enabled" => true,
           "connect_id" => connect["connect_id"],
           "channel_id" => channel_id,
           "autojoin" => settings["mode"] == "join"
         })
         |> then(&if(lark?, do: Map.put(&1, "calendar_source", source), else: &1))
         |> Map.update(
           "calendar_selections",
           [],
           &Enum.map(&1, fn s -> Map.take(s, ~w(account_id calendar_id)) end)
         )}
    end
  end

  defp blank_nil(value) when is_binary(value) and value != "", do: value
  defp blank_nil(_value), do: nil

  # A missing, unjoined or archived channel has its own reason, so the page can
  # point at the channel field instead of the whole form. A preparation that
  # needs no team channel (CalendarConfiguration.team_channel_optional?/1)
  # may leave it empty.
  defp team_channel(_connect, channel_id, true) when channel_id in [nil, ""],
    do: {:ok, %{"id" => "", "name" => ""}}

  defp team_channel(connect, channel_id, _optional?) do
    with true <- valid_text?(channel_id, 128) and channel_id != "",
         %{"id" => ^channel_id, "is_member" => true} = channel <-
           API.conversation_info(API.installation(connect), channel_id),
         true <- channel["is_archived"] != true do
      {:ok, channel}
    else
      _ -> {:error, :meeting_channel_invalid}
    end
  end

  defp delivery(attrs) do
    case Map.get(attrs, "delivery", "channel") do
      delivery when delivery in ["channel", "organizer"] -> {:ok, delivery}
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  # Direct messages to organizers need the same bot scopes as attendee DMs.
  defp delivery_scopes("organizer", connect) do
    case ProviderConnects.delegated_tool_summary(connect)["oauth_bot_scopes"] do
      %{"status" => "known", "scopes" => granted} ->
        if Enum.all?(@dm_scopes, &(&1 in granted)),
          do: :ok,
          else: {:error, :meeting_personal_scopes_missing}

      _ ->
        {:error, :meeting_personal_scopes_unknown}
    end
  end

  defp delivery_scopes(_delivery, _connect), do: :ok

  defp personal_preparation(attrs, previous, connect) do
    existing =
      previous["connect_id"] == connect["connect_id"] and
        previous["personal_preparation"] != false

    requested = Map.get(attrs, "personal_preparation", existing)

    if requested and not existing do
      scopes = ProviderConnects.delegated_tool_summary(connect)["oauth_bot_scopes"]

      case scopes do
        %{"status" => "known", "scopes" => granted} ->
          if Enum.all?(@dm_scopes, &(&1 in granted)),
            do: {:ok, true},
            else: {:error, :meeting_personal_scopes_missing}

        _ ->
          {:error, :meeting_personal_scopes_unknown}
      end
    else
      {:ok, requested}
    end
  end

  defp valid_selections?(selections) when is_list(selections) and length(selections) in 1..10 do
    Enum.all?(selections, fn
      %{"account_id" => account, "calendar_id" => calendar} ->
        valid_text?(account, 256) and account != "" and valid_text?(calendar, 1024) and
          calendar != ""

      _ ->
        false
    end) and
      length(selections) ==
        length(Enum.uniq_by(selections, &{&1["account_id"], &1["calendar_id"]}))
  end

  defp valid_selections?(_selections), do: false

  defp valid_series?(series, selections) when is_list(series) and length(series) <= 20 do
    Enum.all?(series, fn
      %{"event_id" => id} = entry ->
        valid_text?(id, 1024) and id != "" and
          valid_text?(entry["title"] || "", 512) and
          Enum.any?(selections, &same_calendar?(&1, entry))

      _ ->
        false
    end)
  end

  defp valid_series?(_series, _selections), do: false
  defp valid_text?(text, max), do: is_binary(text) and byte_size(text) <= max

  defp same_calendar?(a, b),
    do: a["account_id"] == b["account_id"] and a["calendar_id"] == b["calendar_id"]
end
