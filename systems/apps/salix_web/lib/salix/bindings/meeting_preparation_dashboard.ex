defmodule Salix.Bindings.MeetingPreparationDashboard do
  @moduledoc "Team meeting preparation settings and bounded dashboard reads."
  alias Salix.Control.Groups
  alias Salix.Bindings.{GoogleCalendarSource, MeetingCalendarStatus, MeetingEnrollment}
  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixMeet.{CalendarConfiguration, CalendarEnrollmentCache}
  alias SalixStore.MeetingCalendarSettings

  @settings_fields ~w(enabled mode connect_id channel channel_id calendars calendar_selections calendar_writeback preparation_lead_minutes research_enabled series personal_preparation settings_revision updated_at)

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
         {:ok, connects} <- ProviderConnects.list_group_im_connects(group["group_id"], "slack") do
      {:ok,
       %{
         "settings" => Map.take(settings, @settings_fields),
         "connects" =>
           Enum.map(
             connects,
             &Map.take(
               &1,
               ~w(connect_id app_name bot_username workspace_name workspace_id oauth_completed_at disabled_at oauth_bot_scopes)
             )
           ),
         "calendar" => status(group, settings),
         "runtime_enabled" => is_list(Application.get_env(:salix_meet, :calendar_autojoin)),
         "personal_available" => false
       }}
    end
  end

  defp dispatch(group, "history", attrs) do
    with {:ok, settings} <- settings(group) do
      Salix.Bindings.MeetingHistory.list(group, settings, attrs["cursor"])
    end
  end

  defp dispatch(group, "catalog", %{"connect_id" => connect_id}) do
    with {:ok, connect} <- active_connect(group, connect_id),
         {:ok, calendars} <- MeetingEnrollment.catalog(group["tenant_id"], group["group_id"]) do
      {:ok, Map.put(channel_page(connect, nil), "calendars", calendars)}
    end
  end

  defp dispatch(group, "channels", %{"connect_id" => connect_id} = attrs) do
    with {:ok, connect} <- active_connect(group, connect_id),
         true <- valid_text?(attrs["cursor"] || "", 1024) do
      {:ok, channel_page(connect, attrs["cursor"])}
    else
      false -> {:error, :invalid_meeting_preparation_settings}
      error -> error
    end
  end

  defp dispatch(group, "save", attrs) do
    with {:ok, configuration} <- configuration(group, attrs) do
      MeetingCalendarSettings.put(group["group_id"], group["tenant_id"], configuration, fn ->
        case CalendarConfiguration.entries() do
          {:ok, _entries} -> :ok
          {:error, _} = error -> error
        end
      end)
    end
  end

  defp dispatch(group, "series", attrs) do
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

  defp settings(group) do
    case MeetingCalendarSettings.get(group["group_id"]) do
      {:ok, settings} -> {:ok, settings}
      {:error, :not_found} -> inherited_settings(group)
    end
  end

  defp inherited_settings(group) do
    defaults = Application.get_env(:salix_meet, :calendar_autojoin_channels, []) |> List.wrap()

    with {:ok, identities} <- MeetingEnrollment.resolve_identities(defaults) do
      entries =
        Enum.filter(defaults, fn entry ->
          case identities[entry["connect_id"]] do
            {:ok, identity} -> identity["group_id"] == group["group_id"]
            _ -> false
          end
        end)

      case entries do
        [] ->
          {:ok,
           %{
             "enabled" => false,
             "mode" => "prepare",
             "calendars" => [],
             "calendar_selections" => [],
             "preparation_lead_minutes" => 10,
             "research_enabled" => true
           }}

        [entry] ->
          {:ok, identity} = identities[entry["connect_id"]]

          {selections, channel_id} =
            case CalendarEnrollmentCache.load(entry, identity) do
              {:ok, %{group: enrolled}} ->
                {Enum.map(enrolled["calendars"], &Map.take(&1, ~w(account_id calendar_id))),
                 enrolled["channel_id"]}

              _ ->
                {[], entry["channel_id"]}
            end

          {:ok,
           entry
           |> Map.put("enabled", true)
           |> Map.put_new("mode", "join")
           |> Map.put("calendar_selections", selections)
           |> Map.put("channel_id", channel_id)}

        _ ->
          {:error, :meeting_calendar_conflict}
      end
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
      error -> error
    end
  end

  defp configuration(group, %{"enabled" => true} = attrs) do
    with true <- valid_selections?(attrs["calendar_selections"]),
         true <- attrs["preparation_lead_minutes"] in [10, 15, 30, 60],
         true <- is_boolean(attrs["research_enabled"]),
         true <- is_boolean(attrs["calendar_writeback"]),
         true <- is_boolean(attrs["autojoin"]),
         true <-
           !Map.has_key?(attrs, "personal_preparation") or
             is_boolean(attrs["personal_preparation"]),
         true <- valid_series?(attrs["series"] || [], attrs["calendar_selections"]),
         {:ok, previous} <- settings(group),
         true <- valid_text?(attrs["channel_id"], 128),
         {:ok, connect} <- active_connect(group, attrs["connect_id"]),
         {:ok, personal} <- personal_preparation(attrs, previous, connect),
         {:ok, catalog} <- MeetingEnrollment.catalog(group["tenant_id"], group["group_id"]),
         true <-
           Enum.all?(attrs["calendar_selections"], fn selection ->
             Enum.any?(catalog, &same_calendar?(&1, selection))
           end),
         %{"id" => channel_id, "is_member" => true} = channel <-
           API.conversation_info(API.installation(connect), attrs["channel_id"]),
         true <- channel_id == attrs["channel_id"] and channel["is_archived"] != true do
      selected =
        Enum.map(attrs["calendar_selections"], fn selection ->
          Enum.find(catalog, &same_calendar?(&1, selection))
          |> Map.take(~w(account_id calendar_id name account_name))
        end)

      {:ok,
       %{
         "enabled" => true,
         "connect_id" => connect["connect_id"],
         "mode" => if(attrs["autojoin"], do: "join", else: "prepare"),
         "channel" => channel["name"],
         "channel_id" => channel_id,
         "calendar_selections" => selected,
         "calendars" => selected |> Enum.map(& &1["calendar_id"]) |> Enum.uniq(),
         "calendar_writeback" => attrs["calendar_writeback"],
         "preparation_lead_minutes" => attrs["preparation_lead_minutes"],
         "research_enabled" => attrs["research_enabled"],
         "series" =>
           Enum.map(
             attrs["series"] || [],
             &Map.take(&1, ~w(account_id calendar_id event_id title))
           ),
         "personal_preparation" => personal
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp configuration(_group, _attrs), do: {:error, :invalid_meeting_preparation_settings}

  defp personal_preparation(attrs, previous, connect) do
    existing =
      previous["connect_id"] == connect["connect_id"] and
        previous["personal_preparation"] != false

    requested = Map.get(attrs, "personal_preparation", existing)

    if requested and not existing do
      scopes = ProviderConnects.delegated_tool_summary(connect)["oauth_bot_scopes"]

      case scopes do
        %{"status" => "known", "scopes" => granted} ->
          if Enum.all?(~w(users:read.email im:write chat:write), &(&1 in granted)),
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
