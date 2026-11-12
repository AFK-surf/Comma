defmodule Salix.Bindings.LarkCalendarEnrollment do
  @moduledoc """
  Team preparation on a Feishu/Lark connect: which calendars it reads and
  where its notices go (`Salix.Bindings.MeetingEnrollment` resolves a saved
  setting of mode `prepare` on such a connect here).

  Team calendars are read as the app. The app sees the calendars it
  subscribed to (`subscribe/3`, a public or free/busy-visible shared or
  primary calendar) and those whose owner added it as a member; a team
  picks up to 10 of them. Members' calendars are read as each person who
  signed in with the app: one unit per sign-in with that person's primary
  calendar, as Google members' units hold their own calendars.

  Lark sends no change notice here, so a source is read again when the
  enrollment is resolved and its last read is older than
  `@refresh_interval_ms`; the autojoin worker resolves these enrollments every
  minute (`SalixMeet.CalendarAutojoin`). Every read is bounded: one calendar
  list page per identity, at most 10 identities per catalog, at most
  `@member_accounts_per_pass` new members per pass.
  """

  alias Salix.Bindings.LarkCalendarSource
  alias SalixCalendar.Server, as: Calendar
  alias SalixIM.Ports.{FeishuUserAccounts, LarkUserAccounts}
  alias SalixIM.ProviderConnects

  @providers ~w(feishu lark)
  @max_selected_calendars 10
  @identity_batch 10
  @calendar_page_size 500
  @search_page_size 20
  @readable_roles ~w(reader writer owner)
  @readable_types ~w(primary shared)
  @refresh_interval_ms 5 * 60 * 1_000
  @member_accounts_per_pass 8
  @member_refresh_ms 6 * 60 * 60 * 1_000
  @member_retry_ms 10 * 60 * 1_000
  @entry_keys ~w(preparation_lead_minutes research_enabled series personal_preparation channel_notice delivery settings_revision)

  def provider?(provider), do: provider in @providers

  @doc "The resolved enrollment of a saved Feishu/Lark setting."
  def resolve(%{"calendar_scope" => "members"} = entry, identity) do
    with {:ok, connect, provider} <- connect(entry["connect_id"], identity),
         {:ok, chat_id} <- chat_id(entry),
         {:ok, accounts} <- accounts(provider, connect["group_id"]) do
      units =
        member_units(provider, connect, accounts, previous_units(entry, connect["group_id"]))

      {:ok,
       Map.merge(
         base(provider, connect, chat_id, entry),
         %{
           "calendar_scope" => "members",
           "units" => units,
           # A meeting is prepared once, by direct message
           # (`Salix.Bindings.MeetingCalendar`); a shared notice would repeat
           # once per member copy.
           "channel_notice" => false,
           "personal_preparation" => entry["personal_preparation"] == true,
           "research_enabled" => entry["research_enabled"] == true,
           "preparation_lead_minutes" => entry["preparation_lead_minutes"] || 10
         }
         |> Map.merge(Map.take(entry, ~w(delivery settings_revision)))
       )}
    end
  end

  def resolve(%{"calendar_selections" => [_ | _] = selections} = entry, identity) do
    with {:ok, connect, provider} <- connect(entry["connect_id"], identity),
         {:ok, chat_id} <- chat_id(entry),
         true <- length(selections) <= @max_selected_calendars,
         {:ok, calendar} <- team_calendar(connect["group_id"]),
         {:ok, sources} <-
           ensure_sources(provider, connect, calendar["calendar_id"], selections) do
      {:ok,
       base(provider, connect, chat_id, entry)
       |> Map.merge(%{
         "calendar_id" => calendar["calendar_id"],
         "calendars" => sources,
         "calendar_writeback" => false
       })
       |> Map.merge(Map.take(entry, @entry_keys))}
    else
      false -> {:error, :calendar_enrollment_invalid}
      {:error, _} = error -> error
    end
  end

  def resolve(_entry, _identity), do: {:error, :calendar_enrollment_invalid}

  @doc """
  The calendars the app and the signed-in people can read, for the team's
  calendar picker: `account_id` is `app` or the sign-in's alias. Only
  calendars whose events the identity can read are listed.
  """
  def catalog(provider, connect) do
    with {:ok, accounts} <- accounts(provider, connect["group_id"]) do
      identities = [
        %{"alias" => "app", "name" => "app"} | Enum.take(accounts, @identity_batch - 1)
      ]

      calendars =
        Enum.flat_map(identities, fn account ->
          with {:ok, client} <- LarkCalendarSource.identity(provider, connect, account["alias"]),
               {:ok, data} <-
                 LarkCalendarSource.api(provider).get(client, "/calendar/v4/calendars", %{
                   "page_size" => Integer.to_string(@calendar_page_size)
                 }) do
            data
            |> Map.get("calendar_list", [])
            |> List.wrap()
            |> Enum.filter(&readable?/1)
            |> Enum.map(&catalog_entry(&1, account))
          else
            _ -> []
          end
        end)

      {:ok, calendars}
    end
  end

  @doc "Public calendars of the organization whose name matches, as the app finds them."
  def search(provider, connect, query) when is_binary(query) do
    query = String.trim(query)

    with true <- query != "" and String.length(query) <= 50,
         {:ok, data} <-
           LarkCalendarSource.api(provider).post(
             connect,
             "/calendar/v4/calendars/search?page_size=#{@search_page_size}",
             %{"query" => query}
           ) do
      {:ok,
       data
       |> Map.get("items", [])
       |> List.wrap()
       |> Enum.filter(&(&1["type"] in @readable_types and &1["permissions"] == "public"))
       |> Enum.map(&catalog_entry(&1, %{"alias" => "app", "name" => "app"}))}
    else
      false -> {:error, :invalid_meeting_preparation_request}
      {:error, reason} -> {:error, {:lark_calendar, reason}}
    end
  end

  @doc """
  The app subscribes to a team calendar so it can read its events. Lark
  accepts a shared or primary calendar that is public or shows free/busy;
  only a public one gives event details.
  """
  def subscribe(provider, connect, calendar_id) when is_binary(calendar_id) do
    calendar_id = String.trim(calendar_id)
    path = "/calendar/v4/calendars/" <> URI.encode(calendar_id, &URI.char_unreserved?/1)

    with true <- calendar_id != "" and byte_size(calendar_id) <= 1024,
         {:ok, _} <- LarkCalendarSource.api(provider).post(connect, path <> "/subscribe", %{}),
         {:ok, %{} = calendar} <- LarkCalendarSource.api(provider).get(connect, path, %{}) do
      if readable?(calendar),
        do: {:ok, catalog_entry(calendar, %{"alias" => "app", "name" => "app"})},
        else: {:error, :meeting_calendar_details_hidden}
    else
      false -> {:error, :invalid_meeting_preparation_request}
      {:error, reason} when is_binary(reason) -> {:error, {:lark_calendar, reason}}
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_preparation_request}
    end
  end

  @doc "How many people signed in with the app for the Group."
  def member_account_count(provider, group_id) do
    with {:ok, accounts} <- accounts(provider, group_id), do: {:ok, length(accounts)}
  end

  # ---------------------------------------------------------------------------

  # Joining is a switch of its own (`mode` `join`); settings saved before it
  # only prepare.
  defp base(provider, connect, chat_id, entry),
    do: %{
      "provider" => provider,
      "mode" => if(entry["mode"] == "join", do: "join", else: "prepare"),
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "chat_id" => chat_id
    }

  defp connect(connect_id, identity) do
    provider = identity["provider"]

    with true <- provider in @providers and is_binary(connect_id),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(identity["group_id"], connect_id, provider),
         true <-
           connect["tenant_id"] == identity["tenant_id"] and connect["status"] == "connected" do
      {:ok, connect, provider}
    else
      _ -> {:error, :calendar_enrollment_connect_not_found}
    end
  end

  # The shared notice is optional: without it no chat is needed, and only
  # the personal notices go out. Members' meetings never have a shared notice.
  defp chat_id(entry) do
    case String.trim(to_string(entry["chat_id"] || "")) do
      "" ->
        if entry["channel_notice"] == false or entry["calendar_scope"] == "members",
          do: {:ok, ""},
          else: {:error, :calendar_enrollment_invalid}

      chat_id ->
        {:ok, chat_id}
    end
  end

  defp accounts(provider, group_id) do
    port = if provider == "lark", do: LarkUserAccounts, else: FeishuUserAccounts

    case port.list(group_id) do
      {:ok, accounts} ->
        {:ok,
         accounts
         |> Enum.filter(&(&1["status"] == "active" and is_binary(&1["alias"])))
         |> Enum.sort_by(& &1["alias"])}

      {:error, reason} ->
        {:error, {:calendar_enrollment_account, reason}}
    end
  end

  defp readable?(calendar),
    do:
      calendar["type"] in @readable_types and calendar["role"] in @readable_roles and
        calendar["is_deleted"] != true

  defp catalog_entry(calendar, account),
    do: %{
      "account_id" => account["alias"],
      "account_name" => account["name"] || account["alias"],
      "calendar_id" => calendar["calendar_id"],
      "name" =>
        Enum.find([calendar["summary_alias"], calendar["summary"]], calendar["calendar_id"], fn
          value -> is_binary(value) and String.trim(value) != ""
        end),
      "type" => calendar["type"]
    }

  defp team_calendar(group_id),
    do:
      Calendar.ensure_calendar(
        group_id,
        %{"kind" => "meeting_enrollment", "version" => 1},
        %{"name" => "Meeting calendar", "default_time_zone" => "UTC"}
      )

  defp member_calendar(provider, group_id, alias_name),
    do:
      Calendar.ensure_calendar(
        group_id,
        %{
          "kind" => "meeting_enrollment_member",
          "version" => 1,
          "account_id" => provider <> ":" <> alias_name
        },
        %{"name" => "Member meeting calendar", "default_time_zone" => "UTC"}
      )

  defp ensure_sources(provider, connect, calendar_id, selections) do
    Enum.reduce_while(selections, {:ok, []}, fn selection, {:ok, sources} ->
      case ensure_source(provider, connect, calendar_id, selection) do
        {:ok, source} -> {:cont, {:ok, [source | sources]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end
  end

  defp ensure_source(provider, connect, calendar_id, selection) do
    attrs = %{
      "adapter" => LarkCalendarSource.adapter_for(provider),
      "adapter_contract_id" => LarkCalendarSource.adapter_contract_id(),
      "source_locator" => %{
        "connect_id" => connect["connect_id"],
        "account" => selection["account_id"],
        "external_calendar_id" => selection["calendar_id"]
      },
      "access_profile" => "events_read",
      "audience" => %{"kind" => "group", "group_id" => connect["group_id"]},
      "sync_policy" => %{"page_size" => 200, "default_time_zone" => "UTC"}
    }

    with {:ok, source} <- Calendar.ensure_source(connect["group_id"], calendar_id, attrs),
         :ok <- refresh_if_due(source) do
      {:ok,
       %{
         "account_id" => selection["account_id"],
         "calendar_id" => selection["calendar_id"],
         "source_id" => source["source_id"]
       }}
    end
  end

  # A failed read is kept on the source and tried again at the next pass;
  # the enrollment itself stays, so the calendar's earlier events still scan.
  defp refresh_if_due(source) do
    sync = source["sync"] || %{}
    last = max(sync["attempted_at"] || 0, sync["completed_at"] || 0)

    if SystemsClock.system_time(:millisecond) - last >= @refresh_interval_ms do
      _ =
        Calendar.refresh_source(source["group_id"], source["calendar_id"], source["source_id"], %{
          "group_id" => source["group_id"],
          "object_type" => "Event",
          "page_size" => 200
        })
    end

    :ok
  end

  defp previous_units(%{"enrolled" => %{"group_id" => group_id, "units" => units}}, group_id)
       when is_list(units),
       do: Map.new(units, &{&1["account_id"], &1})

  defp previous_units(_entry, _group_id), do: %{}

  # A pass sets up at most @member_accounts_per_pass new members and the
  # members whose unit is older than @member_refresh_ms; the others keep
  # their unit and only have their calendar read again when it is due.
  defp member_units(provider, connect, accounts, previous) do
    now = SystemsClock.system_time(:millisecond)
    {known, new} = Enum.split_with(accounts, &Map.has_key?(previous, &1["alias"]))

    due =
      Enum.filter(known, fn account ->
        unit = previous[account["alias"]]
        unit["calendars"] in [nil, []] and now - (unit["listed_at"] || 0) >= @member_retry_ms
      end) ++
        Enum.filter(
          known,
          &(now - (previous[&1["alias"]]["listed_at"] || 0) >= @member_refresh_ms)
        )

    picked = Enum.uniq_by(Enum.take(new, @member_accounts_per_pass) ++ due, & &1["alias"])
    listed = Map.new(picked, &{&1["alias"], member_unit(provider, connect, &1, now)})

    Enum.map(accounts, fn account ->
      case listed[account["alias"]] || previous[account["alias"]] do
        nil ->
          nil

        unit ->
          Enum.each(unit["calendars"] || [], &refresh_unit_source(connect, unit, &1))
          unit
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp refresh_unit_source(connect, %{"calendar_id" => calendar_id}, %{"source_id" => source_id})
       when is_binary(calendar_id) and is_binary(source_id) do
    case Calendar.get_source(connect["group_id"], calendar_id, source_id) do
      {:ok, source} -> refresh_if_due(source)
      _ -> :ok
    end
  end

  defp refresh_unit_source(_connect, _unit, _calendar), do: :ok

  defp member_unit(provider, connect, account, now) do
    alias_name = account["alias"]
    base = %{"account_id" => alias_name, "account_email" => account["open_id"] || ""}

    with {:ok, client} <- LarkCalendarSource.identity(provider, connect, alias_name),
         {:ok, data} <-
           LarkCalendarSource.api(provider).post(client, "/calendar/v4/calendars/primary", %{}),
         %{"calendar_id" => primary_id} when is_binary(primary_id) <- primary(data),
         {:ok, calendar} <- member_calendar(provider, connect["group_id"], alias_name),
         {:ok, source} <-
           ensure_source(provider, connect, calendar["calendar_id"], %{
             "account_id" => alias_name,
             "calendar_id" => primary_id
           }) do
      Map.merge(base, %{
        "calendar_id" => calendar["calendar_id"],
        "calendars" => [source],
        "listed_at" => now
      })
    else
      _ -> Map.merge(base, %{"calendars" => [], "listed_at" => now})
    end
  end

  defp primary(%{"calendars" => [%{"calendar" => %{} = calendar} | _]}), do: calendar
  defp primary(_data), do: nil
end
