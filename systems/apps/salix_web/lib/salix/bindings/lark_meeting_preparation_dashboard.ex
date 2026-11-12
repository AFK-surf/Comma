defmodule Salix.Bindings.LarkMeetingPreparationDashboard do
  @moduledoc """
  The team preparation settings page for a Feishu/Lark connect
  (`Salix.Bindings.MeetingPreparationDashboard` hands such a connect here).

  The notice goes to one group chat the bot is in, and that shared notice is
  optional: without it only the personal notices go out. Team calendars are
  the calendars the app can read; a team calendar the app cannot read yet is
  found by name (`search_calendars`) or added by its id
  (`subscribe_calendar`), and the app subscribes to it. Members' calendars
  are read as each person who signed in with the app.

  The bot may also send the notices of Google calendars
  (`calendar_source` `google`): the calendars are then the Group's Google
  calendars, picked as for a Slack bot, or the members' own. Joining
  (`autojoin`) is a switch of its own in every case; without it a setting
  only prepares, as settings saved before the switch did.
  """

  alias Salix.Bindings.{
    GoogleCalendarSource,
    LarkCalendarEnrollment,
    LarkCalendarSource,
    MeetingEnrollment
  }

  @chat_page_size 100
  @lead_minutes [10, 15, 30, 60]

  def provider?(connect), do: connect["provider"] in ["feishu", "lark"]

  @doc "The bot's chats and the readable calendars (or the members' sign-ins)."
  def catalog(group, connect, %{"calendar_source" => "google"} = attrs) do
    calendars =
      if attrs["calendar_scope"] == "members" do
        with {:ok, count} <-
               MeetingEnrollment.member_account_count(group["tenant_id"], group["group_id"]),
             do: {:ok, %{"calendars" => [], "member_accounts" => count}}
      else
        with {:ok, calendars} <- MeetingEnrollment.catalog(group["tenant_id"], group["group_id"]),
             do: {:ok, %{"calendars" => calendars}}
      end

    with {:ok, calendars} <- calendars,
         do: {:ok, connect |> channel_page(nil) |> Map.merge(calendars)}
  end

  def catalog(group, connect, %{"calendar_scope" => "members"}) do
    with {:ok, count} <-
           LarkCalendarEnrollment.member_account_count(connect["provider"], group["group_id"]) do
      {:ok,
       connect
       |> channel_page(nil)
       |> Map.put("calendars", [])
       |> Map.put("member_accounts", count)}
    end
  end

  def catalog(_group, connect, _attrs) do
    with {:ok, calendars} <- LarkCalendarEnrollment.catalog(connect["provider"], connect) do
      {:ok, connect |> channel_page(nil) |> Map.put("calendars", calendars)}
    end
  end

  @doc "One page of the group chats the bot is in."
  def channel_page(connect, cursor) do
    params =
      %{"page_size" => @chat_page_size}
      |> then(
        &if(is_binary(cursor) and cursor != "", do: Map.put(&1, "page_token", cursor), else: &1)
      )

    case im(connect).call(nil, connect, connect["provider"] <> ".list_chats", params) do
      {:ok, page} ->
        %{
          "channels" =>
            for chat <- List.wrap(page["chats"]),
                is_binary(chat["chat_id"]),
                chat["chat_status"] in [nil, "normal"] do
              %{
                "id" => chat["chat_id"],
                "name" => chat["name"] || chat["chat_id"],
                "is_private" => chat["chat_type"] != "public"
              }
            end,
          "next_cursor" => page["next_page_token"]
        }

      {:error, _reason} ->
        %{"channels" => [], "next_cursor" => nil}
    end
  end

  def search(connect, query),
    do: LarkCalendarEnrollment.search(connect["provider"], connect, query)

  def subscribe(connect, calendar_id),
    do: LarkCalendarEnrollment.subscribe(connect["provider"], connect, calendar_id)

  @doc "The next two weeks' meetings of one selected calendar, for the series picker."
  def series(group, _connect, %{"calendar_source" => "google"} = attrs) do
    GoogleCalendarSource.upcoming_meetings(
      %{
        "group_id" => group["group_id"],
        "source_locator" => %{
          "connection_id" => attrs["account_id"],
          "external_calendar_id" => attrs["calendar_id"]
        }
      },
      attrs["cursor"]
    )
  end

  def series(group, connect, attrs) do
    LarkCalendarSource.upcoming_meetings(%{
      "group_id" => group["group_id"],
      "adapter" => LarkCalendarSource.adapter_for(connect["provider"]),
      "source_locator" => %{
        "connect_id" => connect["connect_id"],
        "account" => attrs["account_id"],
        "external_calendar_id" => attrs["calendar_id"]
      }
    })
  end

  @doc """
  The saved setting of a Feishu/Lark team preparation. The page sends the
  chosen chat (unless the shared notice is off) and the chosen calendars;
  every calendar must be one the catalog lists now. `delivery` `organizer`
  sends a joined meeting's notices to its organizer's private chat with the
  bot (`Salix.Bindings.MeetingChannel`).
  """
  def configuration(group, connect, attrs) do
    source = Map.get(attrs, "calendar_source", "feishu_lark")

    with {:ok, mode} <- mode(attrs),
         {:ok, delivery} <- delivery(attrs),
         true <- source in ["google", "feishu_lark"],
         {:ok, configuration} <- scoped_configuration(group, connect, attrs, mode, source) do
      {:ok,
       Map.merge(configuration, %{
         "enabled" => true,
         "provider" => connect["provider"],
         "connect_id" => connect["connect_id"],
         "mode" => mode,
         "delivery" => delivery,
         "calendar_source" => source
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp scoped_configuration(
         _group,
         connect,
         %{"calendar_scope" => "members"} = attrs,
         mode,
         _source
       ) do
    lead = Map.get(attrs, "preparation_lead_minutes", 10)
    personal = Map.get(attrs, "personal_preparation", true)
    research = Map.get(attrs, "research_enabled", false)

    with true <- lead in @lead_minutes and is_boolean(personal) and is_boolean(research),
         true <- personal or mode == "join",
         {:ok, chat} <- notice_chat(connect, attrs["channel_id"], false) do
      {:ok,
       %{
         "calendar_scope" => "members",
         "channel" => chat["name"],
         "channel_id" => chat["id"],
         "chat_id" => chat["id"],
         "calendar_selections" => [],
         "calendars" => [],
         "calendar_writeback" => false,
         "preparation_lead_minutes" => lead,
         "research_enabled" => personal and research,
         "series" => [],
         "personal_preparation" => personal,
         "channel_notice" => false
       }}
    end
  end

  defp scoped_configuration(group, connect, attrs, mode, source) do
    channel_notice = Map.get(attrs, "channel_notice", true)
    personal = Map.get(attrs, "personal_preparation", true)

    with true <- attrs["preparation_lead_minutes"] in @lead_minutes,
         true <- is_boolean(attrs["research_enabled"]),
         true <- is_boolean(channel_notice) and is_boolean(personal),
         true <- channel_notice or personal or mode == "join",
         {:ok, catalog} <- selectable_calendars(group, connect, source),
         {:ok, selected} <- selected_calendars(catalog, attrs["calendar_selections"]),
         {:ok, chat} <- notice_chat(connect, attrs["channel_id"], channel_notice) do
      {:ok,
       %{
         "calendar_scope" => "selected",
         "channel" => chat["name"],
         "channel_id" => chat["id"],
         "chat_id" => chat["id"],
         "calendar_selections" => selected,
         "calendars" => selected |> Enum.map(& &1["calendar_id"]) |> Enum.uniq(),
         "calendar_writeback" => false,
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
    end
  end

  defp selectable_calendars(group, _connect, "google"),
    do: MeetingEnrollment.catalog(group["tenant_id"], group["group_id"])

  defp selectable_calendars(_group, connect, _source),
    do: LarkCalendarEnrollment.catalog(connect["provider"], connect)

  # Saving without the switch keeps today's behaviour: only preparing.
  defp mode(attrs) do
    case Map.get(attrs, "autojoin", false) do
      true -> {:ok, "join"}
      false -> {:ok, "prepare"}
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp delivery(attrs) do
    case Map.get(attrs, "delivery", "channel") do
      delivery when delivery in ["channel", "organizer"] -> {:ok, delivery}
      _ -> {:error, :invalid_meeting_preparation_settings}
    end
  end

  defp selected_calendars(catalog, selections) when is_list(selections) do
    selected =
      Enum.map(selections, fn selection ->
        Enum.find(
          catalog,
          &(&1["account_id"] == selection["account_id"] and
              &1["calendar_id"] == selection["calendar_id"])
        )
      end)

    if Enum.all?(selected, &is_map/1),
      do: {:ok, Enum.map(selected, &Map.take(&1, ~w(account_id calendar_id name account_name)))},
      else: {:error, :invalid_meeting_preparation_settings}
  end

  defp selected_calendars(_catalog, _selections),
    do: {:error, :invalid_meeting_preparation_settings}

  # The shared notice needs a group chat the bot is in. Without the notice a
  # chosen chat is kept as a research source; none is needed.
  defp notice_chat(_connect, chat_id, false) when chat_id in [nil, ""],
    do: {:ok, %{"id" => "", "name" => ""}}

  defp notice_chat(connect, chat_id, _required) when is_binary(chat_id) do
    case im(connect).call(nil, connect, connect["provider"] <> ".get_chat", %{
           "chat_id" => chat_id
         }) do
      {:ok, %{} = chat} ->
        if chat["chat_mode"] in [nil, "group"] and chat["chat_status"] in [nil, "normal"],
          do: {:ok, %{"id" => chat_id, "name" => chat["name"] || chat_id}},
          else: {:error, :meeting_channel_invalid}

      _ ->
        {:error, :meeting_channel_invalid}
    end
  end

  defp notice_chat(_connect, _chat_id, _required), do: {:error, :meeting_channel_invalid}

  defp im(%{"provider" => "lark"}), do: SalixIM.Provider.Lark
  defp im(%{"provider" => "feishu"}), do: SalixIM.Provider.Feishu
end
