defmodule Salix.Bindings.MeetingEnrollment do
  @moduledoc false

  @behaviour SalixMeet.Ports.CalendarEnrollment

  alias Salix.Control.ComposioSettings

  alias Salix.Bindings.{
    GoogleCalendarError,
    GoogleCalendarSource,
    GoogleCalendarWatch,
    LarkCalendarEnrollment
  }

  alias SalixCalendar.Server, as: Calendar
  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects
  alias SalixStore.Composio

  @max_selected_calendars 10
  @max_active_calendar_accounts 10
  @calendar_page_limit 100
  @calendar_tool_call_budget 10
  @member_accounts_per_pass 8
  @member_refreshes_per_pass 2
  @member_refresh_ms 6 * 60 * 60 * 1_000
  @member_retry_ms 10 * 60 * 1_000
  @member_listing_timeout_ms 20_000
  @member_listing_deadline_ms 12_000

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

  # Every resolved enrollment names the Group's bots that join a Feishu/Lark
  # meeting link, one per platform: the destination's own bot when it is of
  # that platform, else the oldest connected one (`SalixMeet.CalendarAutojoin`).
  @impl true
  def resolve(entry, identity) do
    with {:ok, resolved} <- resolve_target(entry, identity) do
      {:ok, Map.put(resolved, "lark_join", lark_join(resolved))}
    end
  end

  defp lark_join(%{"group_id" => group_id} = resolved) when is_binary(group_id) do
    bots = SalixMeet.CalendarConfiguration.meeting_bots(group_id)

    for platform <- ~w(feishu lark),
        bot =
          Enum.find(
            bots,
            &(&1["connect_id"] == resolved["connect_id"] and &1["platform"] == platform)
          ) ||
            Enum.find(bots, &(&1["platform"] == platform)),
        into: %{},
        do: {platform, bot["connect_id"]}
  end

  defp lark_join(_resolved), do: %{}

  defp resolve_target(
         %{"connect_id" => connect_id, "calendar_scope" => "members"} = entry,
         %{"provider" => "slack"} = identity
       )
       when is_binary(connect_id) do
    with {:ok, connect} <- find_connect(connect_id, identity),
         group_id when group_id != "" <- trim(connect["group_id"]),
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         bot_token when bot_token != "" <- trim(connect["bot_token"]),
         {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, accounts} <- member_accounts(settings, group_id),
         {:ok, channel_id} <- resolve_selected_channel(connect, entry, entry["channel"] || "") do
      units = member_units(settings, group_id, accounts, previous_units(entry, group_id))

      {:ok,
       Map.merge(
         %{
           "provider" => "slack",
           # Joining is a switch of its own; settings saved before it join.
           "mode" => entry["mode"] || "join",
           "calendar_scope" => "members",
           "tenant_id" => tenant_id,
           "group_id" => group_id,
           "connect_id" => trim(connect_id),
           "workspace_id" => trim(connect["workspace_id"]),
           "channel_id" => channel_id,
           "units" => units,
           # A shared channel notice would repeat once per member copy; a
           # meeting's preparation goes to one member (MeetingCalendar).
           "channel_notice" => false,
           "personal_preparation" => entry["personal_preparation"] == true,
           "research_enabled" => entry["research_enabled"] == true,
           "preparation_lead_minutes" => entry["preparation_lead_minutes"] || 10
         },
         Map.take(entry, ~w(delivery settings_revision))
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_invalid}
    end
  end

  defp resolve_target(
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
           ~w(preparation_lead_minutes research_enabled series personal_preparation channel_notice delivery settings_revision)
         )
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_invalid}
    end
  end

  defp resolve_target(
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

  # A Lark connect has the notify mode of a Feishu connect.
  defp resolve_target(
         %{
           "connect_id" => connect_id,
           "mode" => "notify",
           "chat_id" => chat_id,
           "calendars" => calendars,
           "create_calendar" => create_calendar,
           "mentions" => mentions
         },
         %{"provider" => "lark"} = identity
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
         "provider" => "lark",
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

  # Google calendars whose notices go to a Feishu/Lark chat: the calendars
  # are read as for a Slack destination, selected or the members' own.
  defp resolve_target(
         %{"calendar_source" => "google", "connect_id" => connect_id} = entry,
         %{"provider" => provider} = identity
       )
       when provider in ["feishu", "lark"] and is_binary(connect_id) do
    with {:ok, connect} <- find_connect(connect_id, identity),
         "connected" <- connect["status"],
         group_id when group_id != "" <- trim(connect["group_id"]),
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, calendars} <- google_calendars(entry, settings, group_id) do
      {:ok,
       %{
         "provider" => provider,
         "calendar_source" => "google",
         "mode" => if(entry["mode"] == "join", do: "join", else: "prepare"),
         "tenant_id" => tenant_id,
         "group_id" => group_id,
         "connect_id" => trim(connect_id),
         "chat_id" => trim(entry["chat_id"])
       }
       |> Map.merge(
         Map.take(
           entry,
           ~w(preparation_lead_minutes research_enabled series personal_preparation channel_notice delivery settings_revision)
         )
       )
       |> Map.merge(calendars)}
    else
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_invalid}
    end
  end

  # A setting saved for a Feishu/Lark connect reads that platform's calendars
  # and sends its notices to a chat (`Salix.Bindings.LarkCalendarEnrollment`).
  defp resolve_target(%{"mode" => mode} = entry, %{"provider" => provider} = identity)
       when provider in ["feishu", "lark"] and mode in ["prepare", "join"],
       do: LarkCalendarEnrollment.resolve(entry, identity)

  defp resolve_target(_entry, _identity), do: {:error, :calendar_enrollment_invalid}

  defp google_calendars(%{"calendar_scope" => "members"} = entry, settings, group_id) do
    with {:ok, accounts} <- member_accounts(settings, group_id) do
      {:ok,
       %{
         "calendar_scope" => "members",
         "units" => member_units(settings, group_id, accounts, previous_units(entry, group_id)),
         # A meeting's preparation goes to one member (MeetingCalendar).
         "channel_notice" => false,
         "personal_preparation" => entry["personal_preparation"] == true,
         "research_enabled" => entry["research_enabled"] == true,
         "preparation_lead_minutes" => entry["preparation_lead_minutes"] || 10
       }}
    end
  end

  defp google_calendars(entry, settings, group_id) do
    calendars = List.wrap(entry["calendars"])

    with :ok <- validate_calendar_names(calendars),
         {:ok, accounts} <- active_accounts(settings, group_id),
         {:ok, selection} <-
           resolve_calendars(
             settings,
             group_id,
             accounts,
             entry["calendar_selections"] || calendars
           ),
         {:ok, comma_calendar, sources} <- ensure_calendar_sources(group_id, selection.pairs) do
      {:ok,
       %{
         "calendar_id" => comma_calendar["calendar_id"],
         "calendars" => sources,
         "calendar_writeback" => false
       }}
    end
  end

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

  @doc "Count the Group's active Google Calendar accounts without listing their calendars."
  def member_account_count(tenant_id, group_id) do
    with {:ok, settings} <- ComposioSettings.get(tenant_id),
         {:ok, accounts} <- member_accounts(settings, group_id) do
      {:ok, length(accounts)}
    else
      {:error, :calendar_enrollment_no_active_account} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  # Every member who connects a Google account to the Group adds one unit:
  # that account's own meeting calendar with the calendars the member owns.
  # A pass lists calendars for a bounded number of accounts (new ones first,
  # then the longest unlisted); the others keep the units they had, so a pass
  # costs the same however many members the Group has.
  defp member_accounts(settings, group_id) do
    case Composio.list_connected_accounts_all(settings, group_id,
           error_mode: :structured,
           max_pages: 20
         ) do
      {:ok, items} ->
        case items
             |> Enum.filter(&googlecalendar_active?(&1, group_id))
             |> Enum.map(&trim(&1["id"]))
             |> Enum.reject(&(&1 == ""))
             |> Enum.uniq()
             |> Enum.sort() do
          [] -> {:error, :calendar_enrollment_no_active_account}
          ids -> {:ok, ids}
        end

      {:error, reason} ->
        {:error, {:calendar_enrollment_account, reason}}
    end
  end

  defp previous_units(%{"enrolled" => %{"group_id" => group_id, "units" => units}}, group_id)
       when is_list(units),
       do: Map.new(units, &{&1["account_id"], &1})

  defp previous_units(_entry, _group_id), do: %{}

  defp member_units(settings, group_id, accounts, previous) do
    now = SystemsClock.system_time(:millisecond)
    {known, new} = Enum.split_with(accounts, &Map.has_key?(previous, &1))

    stale =
      known
      |> Enum.filter(&(now - (previous[&1]["listed_at"] || 0) >= refresh_after(previous[&1])))
      |> Enum.sort_by(&{previous[&1]["listed_at"] || 0, &1})
      |> Enum.take(@member_refreshes_per_pass)

    # Each account is listed in its own task with its own timeout: a slow
    # account keeps what it had and is listed again after @member_retry_ms,
    # without holding up the others.
    picked = Enum.take(new, @member_accounts_per_pass) ++ stale

    listed =
      picked
      |> SystemsClock.async_stream(
        &list_member_unit(settings, group_id, &1, previous[&1], now),
        ordered: true,
        max_concurrency: length(picked) |> max(1),
        timeout: @member_listing_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.zip(picked)
      |> Map.new(fn
        {{:ok, unit}, account_id} ->
          {account_id, unit}

        {{:exit, _reason}, account_id} ->
          {account_id,
           Map.merge(
             previous[account_id] || %{"account_id" => account_id, "calendars" => []},
             %{"listed_at" => now - @member_refresh_ms + @member_retry_ms}
           )}
      end)

    accounts
    |> Enum.map(&(listed[&1] || previous[&1]))
    |> Enum.reject(&is_nil/1)
  end

  # A member account is enrolled over as many passes as it needs: a pass
  # lists at most @calendar_tool_call_budget pages of calendars, continuing
  # from where the last pass stopped, and sets up the owned calendars it has
  # time for before @member_listing_deadline_ms. What is left (pages, calendars
  # to set up) is kept in the unit's "listing" and continued after
  # @member_retry_ms. A finished listing replaces the unit's calendars.
  defp list_member_unit(settings, group_id, account_id, previous, now) do
    deadline =
      SystemsClock.monotonic_time(:millisecond) +
        SystemsRuntime.get_env(
          :salix_web,
          :member_listing_deadline_ms,
          @member_listing_deadline_ms
        )

    listing = (previous || %{})["listing"] || %{}
    pending = listing["pending"] || []

    with {:ok, calendar} <- ensure_member_calendar(group_id, account_id),
         {:ok, calendars, next_token} <-
           next_calendar_batch(settings, group_id, account_id, listing, deadline) do
      owned = Enum.filter(calendars, &owned_calendar?/1)
      # The first non-empty address wins: the one listed now, the one the
      # listing found earlier, or the account's address before this listing.
      email =
        Enum.find(
          [
            account_email(calendars),
            listing["account_email"],
            (previous || %{})["account_email"]
          ],
          "",
          &(is_binary(&1) and &1 != "")
        )

      to_set_up = pending ++ Enum.map(owned, &member_calendar_pair(account_id, &1))

      {enrolled, left, failed?} =
        ensure_member_sources(group_id, calendar["calendar_id"], to_set_up, deadline)

      cycle = (listing["enrolled"] || []) ++ enrolled
      failed? = failed? or listing["failed"] == true
      done? = is_nil(next_token) and left == []

      base = %{
        "account_id" => account_id,
        "account_email" => email,
        "calendar_id" => calendar["calendar_id"]
      }

      if done? do
        Map.merge(base, %{
          "calendars" => Enum.uniq_by(cycle, & &1["source_id"]),
          "listed_at" => if(failed?, do: now - @member_refresh_ms + @member_retry_ms, else: now)
        })
      else
        Map.merge(base, %{
          # Calendars set up so far start being scanned now.
          "calendars" =>
            Enum.uniq_by(((previous || %{})["calendars"] || []) ++ enrolled, & &1["source_id"]),
          "listing" => %{
            "page_token" => resume_token(next_token),
            "listed" => is_nil(next_token),
            "pending" => left,
            "enrolled" => cycle,
            "failed" => failed?,
            "account_email" => email
          },
          "listed_at" => now - @member_refresh_ms + @member_retry_ms
        })
      end
    else
      # A failing account keeps what it had and is listed again after
      # @member_retry_ms, behind the new members of each pass.
      {:error, _reason} ->
        Map.merge(
          previous || %{"account_id" => account_id, "calendars" => []},
          %{"listed_at" => now - @member_refresh_ms + @member_retry_ms}
        )
    end
  end

  # An account that has no meeting calendar yet (its listing failed, also in
  # an enrollment saved before failures were retried) is listed again soon.
  defp refresh_after(%{"calendar_id" => id}) when is_binary(id) and id != "",
    do: @member_refresh_ms

  defp refresh_after(_unit), do: @member_retry_ms

  defp owned_calendar?(calendar),
    do: calendar["accessRole"] == "owner" and calendar["deleted"] != true

  defp member_calendar_pair(account_id, calendar),
    do: %{
      "account_id" => account_id,
      "calendar_id" => trim(calendar["id"]),
      "time_zone" => calendar["timeZone"] || "UTC"
    }

  defp account_email(calendars) do
    case Enum.find(calendars, &(&1["primary"] == true)) do
      %{"id" => id} when is_binary(id) -> id |> trim() |> String.downcase()
      _ -> ""
    end
  end

  defp ensure_member_calendar(group_id, account_id),
    do:
      Calendar.ensure_calendar(
        group_id,
        %{"kind" => "meeting_enrollment_member", "version" => 1, "account_id" => account_id},
        %{"name" => "Member meeting calendar", "default_time_zone" => "UTC"}
      )

  # A preparation saved without a team channel stays without one.
  defp resolve_selected_channel(_connect, %{"channel_id" => ""} = entry, "") do
    if SalixMeet.CalendarConfiguration.team_channel_optional?(entry),
      do: {:ok, ""},
      else: {:error, :calendar_channel_unavailable}
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
      case ensure_source(group_id, calendar_id, pair) do
        {:ok, enrolled} -> {:cont, {:ok, [enrolled | sources]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end
  end

  # Owned calendars are set up one by one, each with what is left of the
  # deadline: one that runs out of time is stopped and waits, with the rest,
  # for the next pass, and what finished is kept. A calendar that cannot sync
  # is left out, and the account is listed again after @member_retry_ms.
  # A calendar that ran out of time goes to the end of what is left, so the
  # next pass starts with the others and one slow calendar cannot hold them.
  defp ensure_member_sources(group_id, calendar_id, calendar_pairs, deadline) do
    {enrolled, left, slow, failed?} =
      Enum.reduce(calendar_pairs, {[], [], [], false}, fn pair, {enrolled, left, slow, failed?} ->
        if slow != [] or past?(deadline) do
          {enrolled, [pair | left], slow, failed?}
        else
          case ensure_source_within(group_id, calendar_id, pair, deadline) do
            {:ok, source} -> {[source | enrolled], left, slow, failed?}
            :timeout -> {enrolled, left, [pair], failed?}
            {:error, _} -> {enrolled, left, slow, true}
          end
        end
      end)

    {Enum.reverse(enrolled), Enum.reverse(left) ++ slow, failed?}
  end

  defp ensure_source_within(group_id, calendar_id, pair, deadline),
    do: within(deadline, fn -> ensure_source(group_id, calendar_id, pair) end)

  # Runs one enrollment step with what is left of the deadline.
  defp within(deadline, fun) do
    [fun]
    |> SystemsClock.async_stream(& &1.(),
      timeout: max(deadline - SystemsClock.monotonic_time(:millisecond), 1),
      on_timeout: :kill_task
    )
    |> Enum.at(0)
    |> case do
      {:ok, result} -> result
      {:exit, :timeout} -> :timeout
      {:exit, reason} -> {:error, reason}
    end
  end

  defp past?(deadline), do: SystemsClock.monotonic_time(:millisecond) >= deadline

  defp resume_token({:resume, token}), do: token
  defp resume_token(token), do: token

  defp ensure_source(group_id, calendar_id, pair) do
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

    with {:ok, source} <- Calendar.ensure_source(group_id, calendar_id, attrs) do
      case GoogleCalendarWatch.maintain(group_id, calendar_id, source["source_id"]) do
        {:ok, _} -> {:ok, Map.put(pair, "source_id", source["source_id"])}
        {:error, reason} -> {:error, {:calendar_source_maintenance, reason}}
      end
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

        "lark" ->
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

  # Calendars left to set up from the last pass are finished before more
  # pages are listed; the listing keeps its page token meanwhile.
  defp next_calendar_batch(
         _settings,
         _group_id,
         _account_id,
         %{"pending" => [_ | _]} = listing,
         _deadline
       ),
       do:
         {:ok, [], if(listing["listed"] == true, do: nil, else: {:resume, listing["page_token"]})}

  defp next_calendar_batch(_settings, _group_id, _account_id, %{"listed" => true}, _deadline),
    do: {:ok, [], nil}

  defp next_calendar_batch(settings, group_id, account_id, listing, deadline),
    do:
      list_calendar_batch(
        settings,
        group_id,
        account_id,
        listing["page_token"],
        @calendar_tool_call_budget,
        deadline
      )

  defp list_calendar_batch(_settings, _group_id, _account_id, token, 0, _deadline),
    do: {:ok, [], token}

  defp list_calendar_batch(settings, group_id, account_id, token, calls, deadline) do
    # Running out of time is not the end of the list: the listing resumes
    # from this page, also when it is the first one.
    if past?(deadline),
      do: {:ok, [], {:resume, token}},
      else: list_calendar_page(settings, group_id, account_id, token, calls, deadline)
  end

  # A page request gets what is left of the deadline; when it runs out, the
  # pages read so far are kept and the listing continues from this page.
  defp list_calendar_page(settings, group_id, account_id, token, calls, deadline) do
    arguments = put_present(%{"max_results" => @calendar_page_limit}, "page_token", token)

    request = fn ->
      Composio.execute_tool(
        settings,
        "GOOGLECALENDAR_LIST_CALENDARS",
        group_id,
        arguments,
        connected_account_id: account_id,
        error_mode: :structured
      )
    end

    case within(deadline, request) do
      :timeout ->
        {:ok, [], {:resume, token}}

      result ->
        list_calendar_result(result, settings, group_id, account_id, token, calls, deadline)
    end
  end

  defp list_calendar_result(result, settings, group_id, account_id, token, calls, deadline) do
    case result do
      {:ok, %{"successful" => true, "data" => data}} when is_map(data) ->
        calendars = calendar_items(data)

        case calendar_next_page_token(data) do
          "" ->
            {:ok, calendars, nil}

          ^token ->
            {:error, {:calendar_enrollment_list, :page_token_cycle}}

          next ->
            with {:ok, more, last} <-
                   list_calendar_batch(settings, group_id, account_id, next, calls - 1, deadline),
                 do: {:ok, calendars ++ more, last}
        end

      {:ok, %{"successful" => false} = envelope} ->
        {:error,
         {:calendar_enrollment_list, GoogleCalendarError.from_composio_envelope(envelope)}}

      {:error, reason} ->
        {:error, {:calendar_enrollment_list, reason}}
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
