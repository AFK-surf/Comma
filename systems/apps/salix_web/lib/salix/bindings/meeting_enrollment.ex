defmodule Salix.Bindings.MeetingEnrollment do
  @moduledoc false

  @behaviour SalixMeet.Ports.CalendarEnrollment

  alias Salix.Control.ComposioSettings
  alias Salix.Bindings.{GoogleCalendarError, GoogleCalendarSource, GoogleCalendarWatch}
  alias SalixCalendar.Server, as: Calendar
  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects
  alias SalixStore.Composio

  @max_selected_calendars 10
  @max_active_calendar_accounts 10
  @calendar_page_limit 100
  @calendar_tool_call_budget 10

  @impl true
  def resolve_identities(entries) when is_list(entries) do
    connect_ids = Enum.map(entries, &entry_connect_id/1)

    cond do
      entries == [] ->
        {:ok, %{}}

      Enum.any?(connect_ids, &(&1 == "")) ->
        {:error, :calendar_enrollment_invalid}

      true ->
        connect_ids = Enum.uniq(connect_ids)

        case ProviderConnects.find_active_im_connects_by_ids(connect_ids) do
          {:ok, connects} ->
            {:ok,
             Map.new(connect_ids, fn connect_id ->
               result =
                 case connects[connect_id] do
                   nil -> {:error, :calendar_enrollment_connect_not_found}
                   connect -> connect_identity(connect)
                 end

               {connect_id, result}
             end)}

          {:error, reason} ->
            {:error, {:calendar_enrollment_connect_lookup, reason}}
        end
    end
  end

  def resolve_identities(_entries), do: {:error, :calendar_enrollment_invalid}

  @impl true
  def resolve(%{"connect_id" => connect_id} = entry) do
    with {:ok, identities} <- resolve_identities([entry]),
         {:ok, identity} <- Map.get(identities, trim(connect_id)) do
      resolve(entry, identity)
    else
      nil -> {:error, :calendar_enrollment_connect_not_found}
      {:error, _} = error -> error
    end
  end

  def resolve(_entry), do: {:error, :calendar_enrollment_invalid}

  @impl true
  def resolve(
        %{"connect_id" => connect_id, "channel" => channel, "calendars" => calendars} = entry,
        %{"provider" => "slack"} = identity
      )
      when is_binary(connect_id) and is_binary(channel) and is_list(calendars) and
             is_map(identity) do
    with {:ok, connect} <- find_connect(connect_id, identity),
         group_id when group_id != "" <- trim(connect["group_id"]),
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         bot_token when bot_token != "" <- trim(connect["bot_token"]),
         :ok <- validate_calendar_names(calendars),
         {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, accounts} <- active_accounts(settings, group_id),
         {:ok, calendar_selection} <-
           resolve_calendars(
             settings,
             group_id,
             accounts,
             entry["calendar_selections"] || calendars
           ),
         {:ok, comma_calendar, calendar_sources} <-
           ensure_calendar_sources(group_id, calendar_selection.pairs),
         {:ok, channel_id} <- resolve_selected_channel(connect, entry, channel) do
      {:ok,
       Map.merge(
         %{
           "provider" => "slack",
           "mode" => entry["mode"] || "join",
           "tenant_id" => tenant_id,
           "group_id" => group_id,
           "connect_id" => trim(connect_id),
           "workspace_id" => trim(connect["workspace_id"]),
           "calendar_id" => comma_calendar["calendar_id"],
           "calendars" => calendar_sources,
           "calendar_writeback" => entry["calendar_writeback"] == true,
           "channel_id" => channel_id
         },
         Map.take(
           entry,
           ~w(preparation_lead_minutes research_enabled series personal_preparation settings_revision)
         )
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_invalid}
    end
  end

  def resolve(
        %{
          "connect_id" => connect_id,
          "mode" => "notify",
          "chat_id" => chat_id,
          "calendars" => calendars,
          "create_calendar" => create_calendar,
          "mentions" => mentions
        },
        %{"provider" => "feishu"} = identity
      )
      when is_binary(connect_id) and is_binary(chat_id) and is_list(calendars) and
             is_binary(create_calendar) and is_map(mentions) do
    with {:ok, connect} <- find_connect(connect_id, identity),
         group_id when group_id != "" <- trim(connect["group_id"]),
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         "connected" <- connect["status"],
         chat_id when chat_id != "" <- trim(chat_id),
         :ok <- validate_calendar_names(calendars),
         true <- create_calendar in calendars,
         :ok <- validate_mentions(mentions),
         {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, accounts} <- active_accounts(settings, group_id),
         {:ok, calendar_selection} <-
           resolve_calendars(settings, group_id, accounts, calendars),
         {:ok, comma_calendar, calendar_sources} <-
           ensure_calendar_sources(group_id, calendar_selection.pairs),
         {:ok, create_pair} <-
           calendar_pair_for_selector(
             calendar_selection.selectors,
             calendar_sources,
             create_calendar
           ) do
      {:ok,
       %{
         "provider" => "feishu",
         "mode" => "notify",
         "tenant_id" => tenant_id,
         "group_id" => group_id,
         "connect_id" => trim(connect_id),
         "chat_id" => chat_id,
         "calendar_id" => comma_calendar["calendar_id"],
         "calendars" => calendar_sources,
         "create_calendar" => Map.put(create_pair, "name", create_calendar),
         "mentions" => mentions
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_invalid}
    end
  end

  def resolve(_entry, _identity), do: {:error, :calendar_enrollment_invalid}

  @doc "Read the connected accounts' calendar catalog without enrolling sources or creating watches."
  def catalog(tenant_id, group_id) do
    with {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, accounts} <- active_accounts(settings, group_id),
         {:ok, catalog} <- calendar_catalog(settings, group_id, accounts) do
      {:ok,
       Enum.map(catalog, fn {account_id, calendar} ->
         account_name =
           Enum.find_value(catalog, account_id, fn
             {^account_id, %{"primary" => true} = primary} -> primary["id"]
             _ -> nil
           end)

         %{
           "account_id" => account_id,
           "calendar_id" => calendar["id"],
           "account_name" => account_name,
           "name" => calendar["summaryOverride"] || calendar["summary"] || calendar["id"],
           "time_zone" => calendar["timeZone"] || "UTC"
         }
       end)}
    end
  end

  defp resolve_selected_channel(connect, %{"channel_id" => id}, _name) do
    case SlackAPI.conversation_info(SlackAPI.installation(connect), id) do
      %{"id" => ^id, "is_member" => true} = channel ->
        if channel["is_archived"] == true,
          do: {:error, :calendar_channel_unavailable},
          else: {:ok, id}

      _ ->
        {:error, :calendar_channel_unavailable}
    end
  end

  defp resolve_selected_channel(connect, _entry, name),
    do: resolve_channel(SlackAPI.installation(connect), name)

  defp ensure_calendar_sources(group_id, calendar_pairs) do
    with {:ok, calendar} <-
           Calendar.ensure_calendar(
             group_id,
             %{"kind" => "meeting_enrollment", "version" => 1},
             %{"name" => "Meeting calendar", "default_time_zone" => "UTC"}
           ),
         {:ok, sources} <- ensure_sources(group_id, calendar["calendar_id"], calendar_pairs) do
      {:ok, calendar, sources}
    end
  end

  defp ensure_sources(group_id, calendar_id, calendar_pairs) do
    Enum.reduce_while(calendar_pairs, {:ok, []}, fn pair, {:ok, sources} ->
      attrs = %{
        "adapter" => "google_calendar",
        "adapter_contract_id" => GoogleCalendarSource.adapter_contract_id(),
        "source_locator" => %{
          "connection_id" => pair["account_id"],
          "external_calendar_id" => pair["calendar_id"]
        },
        "access_profile" => "events_read",
        "audience" => %{"kind" => "group", "group_id" => group_id},
        "sync_policy" => %{
          "page_size" => 200,
          "default_time_zone" => pair["time_zone"] || "UTC"
        }
      }

      case Calendar.ensure_source(group_id, calendar_id, attrs) do
        {:ok, source} ->
          with {:ok, _} <-
                 GoogleCalendarWatch.maintain(group_id, calendar_id, source["source_id"]) do
            enrolled = Map.put(pair, "source_id", source["source_id"])
            {:cont, {:ok, [enrolled | sources]}}
          else
            {:error, reason} -> {:halt, {:error, {:calendar_source_maintenance, reason}}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end
  end

  defp find_connect(connect_id, identity) do
    group_id = trim(identity["group_id"] || identity[:group_id])
    tenant_id = trim(identity["tenant_id"] || identity[:tenant_id])

    provider = trim(identity["provider"] || identity[:provider])

    case ProviderConnects.get_active_connect_by_id(group_id, connect_id, provider) do
      {:ok, connect} ->
        if trim(connect["tenant_id"]) == tenant_id,
          do: {:ok, connect},
          else: {:error, :calendar_enrollment_connect_not_found}

      {:error, :not_found} ->
        {:error, :calendar_enrollment_connect_not_found}

      {:error, reason} ->
        {:error, {:calendar_enrollment_connect, reason}}
    end
  end

  defp connect_identity(connect) do
    identity = %{
      "connect_id" => trim(connect["connect_id"]),
      "tenant_id" => trim(connect["tenant_id"]),
      "group_id" => trim(connect["group_id"]),
      "provider" => trim(connect["provider"])
    }

    oauth_completed_at = connect["oauth_completed_at"]

    provider_ready? =
      case identity["provider"] do
        "slack" ->
          trim(connect["bot_token"]) != "" and is_integer(oauth_completed_at) and
            oauth_completed_at > 0

        "feishu" ->
          connect["status"] == "connected"

        _ ->
          false
      end

    if Enum.all?(Map.values(identity), &(&1 != "")) and provider_ready?,
      do: {:ok, identity},
      else: {:error, :calendar_enrollment_connect_not_found}
  end

  defp entry_connect_id(entry) when is_map(entry), do: trim(entry["connect_id"])
  defp entry_connect_id(_entry), do: ""

  defp active_accounts(settings, group_id) do
    case Composio.list_connected_accounts_all(settings, group_id, error_mode: :structured) do
      {:ok, items} ->
        ids =
          items
          |> Enum.filter(&googlecalendar_active?(&1, group_id))
          |> Enum.map(&trim(&1["id"]))
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        cond do
          ids == [] ->
            {:error, :calendar_enrollment_no_active_account}

          length(ids) > @max_active_calendar_accounts ->
            {:error, :calendar_enrollment_too_many_active_accounts}

          true ->
            {:ok, ids}
        end

      {:error, reason} ->
        {:error, {:calendar_enrollment_account, reason}}
    end
  end

  defp googlecalendar_active?(account, group_id) do
    slug =
      (get_in(account, ["toolkit", "slug"]) || account["toolkit"])
      |> to_string()
      |> String.downcase()

    slug == "googlecalendar" and account["status"] == Composio.active_status() and
      trim(account["user_id"]) == group_id
  end

  defp resolve_calendars(settings, group_id, account_ids, names) do
    with {:ok, catalog} <- calendar_catalog(settings, group_id, account_ids) do
      names
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        case match_calendar(catalog, name) do
          {:ok, pair} -> {:cont, {:ok, [{name, pair} | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, reversed} ->
          selectors = Enum.reverse(reversed)

          {:ok,
           %{
             pairs: selectors |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
             selectors: selectors
           }}

        other ->
          other
      end
    end
  end

  defp calendar_catalog(settings, group_id, account_ids) do
    Enum.reduce_while(account_ids, {:ok, [], @calendar_tool_call_budget}, fn account_id,
                                                                             {:ok, acc,
                                                                              calls_left} ->
      case list_calendars(settings, group_id, account_id, calls_left) do
        {:ok, calendars, remaining_calls} ->
          {:cont, {:ok, acc ++ tag(account_id, calendars), remaining_calls}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, catalog, _remaining_calls} -> {:ok, catalog}
      {:error, _} = error -> error
    end
  end

  defp tag(account_id, calendars) do
    for calendar <- calendars, is_binary(calendar["id"]) and calendar["id"] != "" do
      {account_id, calendar}
    end
  end

  defp list_calendars(settings, group_id, account_id, calls_left) do
    list_calendar_pages(
      settings,
      group_id,
      account_id,
      nil,
      calls_left,
      [],
      MapSet.new()
    )
  end

  defp list_calendar_pages(
         _settings,
         _group_id,
         _account_id,
         _page_token,
         0,
         _calendars,
         _seen
       ),
       do: {:error, {:calendar_enrollment_list, :page_limit_exceeded}}

  defp list_calendar_pages(
         settings,
         group_id,
         account_id,
         page_token,
         calls_left,
         accumulated,
         seen
       ) do
    arguments =
      %{"max_results" => @calendar_page_limit}
      |> put_present("page_token", page_token)

    case Composio.execute_tool(
           settings,
           "GOOGLECALENDAR_LIST_CALENDARS",
           group_id,
           arguments,
           connected_account_id: account_id,
           error_mode: :structured
         ) do
      {:ok, %{"successful" => true, "data" => data}} when is_map(data) ->
        calendars = calendar_items(data)
        next_page_token = calendar_next_page_token(data)
        accumulated = accumulated ++ calendars
        calls_left = calls_left - 1

        cond do
          next_page_token == "" ->
            {:ok, Enum.uniq_by(accumulated, &trim(&1["id"])), calls_left}

          MapSet.member?(seen, next_page_token) ->
            {:error, {:calendar_enrollment_list, :page_token_cycle}}

          true ->
            list_calendar_pages(
              settings,
              group_id,
              account_id,
              next_page_token,
              calls_left,
              accumulated,
              MapSet.put(seen, next_page_token)
            )
        end

      {:ok, %{"successful" => false} = envelope} ->
        {:error,
         {:calendar_enrollment_list, GoogleCalendarError.from_composio_envelope(envelope)}}

      {:error, reason} ->
        {:error, {:calendar_enrollment_list, reason}}

      _other ->
        {:error, {:calendar_enrollment_list, :invalid_google_calendar_list_response}}
    end
  end

  defp calendar_items(data) do
    case data["calendars"] || data["items"] || get_in(data, ["response_data", "items"]) do
      items when is_list(items) -> Enum.filter(items, &is_map/1)
      _ -> []
    end
  end

  defp calendar_next_page_token(data) do
    (data["next_page_token"] || data["nextPageToken"] ||
       get_in(data, ["response_data", "next_page_token"]) ||
       get_in(data, ["response_data", "nextPageToken"]))
    |> trim()
  end

  defp validate_calendar_names(names) do
    count = names |> Enum.map(&trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> length()

    cond do
      count == 0 -> {:error, :calendar_enrollment_invalid}
      count > @max_selected_calendars -> {:error, :calendar_enrollment_too_many_calendars}
      true -> :ok
    end
  end

  defp calendar_pair_for_selector(selectors, sources, create_calendar) do
    selectors
    |> Enum.find(fn {selector, _pair} -> selector == create_calendar end)
    |> case do
      {_selector, pair} ->
        case Enum.find(sources, &same_calendar_pair?(&1, pair)) do
          nil -> {:error, :calendar_enrollment_invalid}
          source -> {:ok, source}
        end

      nil ->
        {:error, :calendar_enrollment_invalid}
    end
  end

  defp same_calendar_pair?(source, pair),
    do:
      source["account_id"] == pair["account_id"] and
        source["calendar_id"] == pair["calendar_id"]

  defp validate_mentions(%{"mode" => mode, "users" => users})
       when mode in ["none", "all"] and users == [],
       do: :ok

  defp validate_mentions(%{"mode" => "users", "users" => users}) when is_list(users) do
    if length(users) in 1..50 and
         Enum.all?(users, fn user ->
           is_map(user) and trim(user["user_id"]) != "" and trim(user["name"]) != ""
         end),
       do: :ok,
       else: {:error, :calendar_enrollment_invalid_mentions}
  end

  defp validate_mentions(_mentions), do: {:error, :calendar_enrollment_invalid_mentions}

  defp match_calendar(catalog, %{"account_id" => account_id, "calendar_id" => calendar_id}) do
    case Enum.find(catalog, fn {account, calendar} ->
           account == account_id and calendar["id"] == calendar_id
         end) do
      {^account_id, calendar} ->
        {:ok,
         %{
           "account_id" => account_id,
           "calendar_id" => calendar_id,
           "time_zone" => calendar["timeZone"] || calendar["time_zone"] || "UTC"
         }}

      nil ->
        {:error, :calendar_selection_unavailable}
    end
  end

  defp match_calendar(_catalog, selector) when not is_binary(selector),
    do: {:error, :calendar_selection_unavailable}

  defp match_calendar(catalog, name) do
    target = normalize(name)

    catalog
    |> Enum.filter(fn {_account_id, calendar} ->
      [calendar["summaryOverride"], calendar["summary"], calendar["id"]]
      |> Enum.any?(&(is_binary(&1) and normalize(&1) == target))
    end)
    |> Enum.map(fn {account_id, calendar} ->
      %{
        "account_id" => account_id,
        "calendar_id" => trim(calendar["id"]),
        "time_zone" => trim(calendar["timeZone"] || calendar["time_zone"] || "UTC")
      }
    end)
    |> Enum.uniq()
    |> case do
      [pair] -> {:ok, pair}
      [] -> {:error, {:calendar_not_found, name}}
      _ -> {:error, {:calendar_ambiguous, name}}
    end
  end

  defp resolve_channel(token, name) do
    target = name |> trim() |> String.trim_leading("#") |> String.downcase()

    token
    |> SlackAPI.list_conversations(
      limit: 1000,
      types: ["public_channel", "private_channel"],
      exclude_archived: true
    )
    |> Enum.filter(&(String.downcase(to_string(&1["name"] || "")) == target))
    |> Enum.uniq_by(& &1["id"])
    |> case do
      [%{"id" => id} = channel] when is_binary(id) and id != "" ->
        if channel["is_member"] == false,
          do: {:error, {:channel_bot_not_member, name}},
          else: {:ok, id}

      [] ->
        {:error, {:channel_not_found, name}}

      _ ->
        {:error, {:channel_ambiguous, name}}
    end
  rescue
    e in SlackAPI.Error -> {:error, {:channel_resolve, SlackAPI.error_message(e)}}
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
