defmodule Salix.Bindings.MeetingCalendarPolicy do
  @moduledoc false

  alias Salix.Bindings.MeetingEnrollment
  alias SalixIM.GroupDirectory
  alias SalixMeet.{CalendarEnrollmentCache, CalendarEnrollmentGroups}

  def get(agent_id, connect_id) do
    connect_id = trim(connect_id)

    with {:ok, agent} <- GroupDirectory.get_agent(agent_id),
         group_id when group_id != "" <- trim(agent["group_id"]),
         {:ok, entry, entries} <- configured_entry(connect_id),
         {:ok, identities} <- MeetingEnrollment.resolve_identities(entries),
         {:ok, identity} <- selected_identity(identities, connect_id),
         :ok <- reject_duplicate_group(identities, identity),
         {:ok, resolved} <- MeetingEnrollment.resolve(entry, identity),
         true <- resolved["group_id"] == group_id,
         {:ok, evidence} <- policy_evidence(resolved, entry, connect_id) do
      {:ok, evidence}
    else
      false -> {:error, :calendar_policy_not_owned}
      nil -> {:error, :calendar_policy_invalid}
      "" -> {:error, :calendar_policy_agent_group_missing}
      {:error, _} = error -> error
      _ -> {:error, :calendar_policy_invalid}
    end
  end

  @doc "Read the configured policy from the durable enrollment proof without provider I/O."
  def status(agent_id, connect_id) do
    connect_id = trim(connect_id)

    with {:ok, agent} <- GroupDirectory.get_agent(agent_id),
         group_id when group_id != "" <- trim(agent["group_id"]),
         {:ok, entry, entries} <- configured_entry(connect_id),
         {:ok, identities} <- MeetingEnrollment.resolve_identities(entries),
         {:ok, identity} <- selected_identity(identities, connect_id),
         :ok <- reject_duplicate_group(identities, identity),
         true <- identity["group_id"] == group_id,
         {:ok, cached} <- load_enrollment(entry, identity),
         true <- cached.group["group_id"] == group_id,
         {:ok, evidence} <- policy_evidence(cached.group, entry, connect_id) do
      {:ok, Map.put(evidence, "resolved_at_ms", cached.at)}
    else
      false -> {:error, :calendar_policy_not_owned}
      nil -> {:error, :calendar_policy_invalid}
      "" -> {:error, :calendar_policy_agent_group_missing}
      {:error, _} = error -> error
      _ -> {:error, :calendar_policy_invalid}
    end
  end

  defp configured_entry(connect_id) do
    entries =
      SalixMeet.CalendarConfiguration.authorized_entries()
      |> List.wrap()

    entries
    |> Enum.filter(fn entry ->
      trim(entry["connect_id"]) == connect_id
    end)
    |> case do
      [entry] -> {:ok, entry, entries}
      [] -> {:error, :calendar_policy_not_configured}
      _ -> {:error, :calendar_policy_ambiguous}
    end
  end

  defp selected_identity(identities, connect_id) when is_map(identities) do
    case identities[connect_id] do
      {:ok, identity} when is_map(identity) -> {:ok, identity}
      {:error, _} = error -> error
      _ -> {:error, :calendar_enrollment_connect_not_found}
    end
  end

  defp selected_identity(_identities, _connect_id),
    do: {:error, :calendar_enrollment_invalid}

  defp reject_duplicate_group(identities, selected_identity) do
    duplicate_groups =
      identities
      |> Map.values()
      |> Enum.flat_map(fn
        {:ok, identity} when is_map(identity) -> [identity]
        _ -> []
      end)
      |> CalendarEnrollmentGroups.duplicate_group_ids()

    if MapSet.member?(duplicate_groups, CalendarEnrollmentGroups.group_id(selected_identity)),
      do: {:error, :calendar_policy_group_conflict},
      else: :ok
  end

  defp load_enrollment(entry, identity) do
    case CalendarEnrollmentCache.load(entry, identity) do
      {:ok, cached} ->
        {:ok, cached}

      {:error, reason} when reason in [:not_found, :invalid_calendar_enrollment_cache] ->
        {:error, :calendar_enrollment_pending}

      {:error, reason} ->
        {:error, {:calendar_enrollment_cache_unavailable, reason}}
    end
  end

  defp policy_evidence(
         %{
           "provider" => "feishu",
           "create_calendar" => %{
             "account_id" => account_id,
             "calendar_id" => calendar_id,
             "name" => calendar_name
           },
           "chat_id" => chat_id
         },
         entry,
         connect_id
       ) do
    {:ok,
     %{
       "connect_id" => connect_id,
       "connected_account_id" => account_id,
       "calendar_id" => calendar_id,
       "calendar_name" => calendar_name,
       "watched_calendars" => entry["calendars"],
       "mode" => "notify",
       "chat_id" => chat_id,
       "readiness" => "ACTIVE"
     }}
  end

  defp policy_evidence(
         %{
           "provider" => "slack",
           "calendar_id" => meeting_calendar_id,
           "calendars" => calendars,
           "channel_id" => channel_id
         } = resolved,
         entry,
         connect_id
       )
       when is_list(calendars) do
    {:ok,
     %{
       "connect_id" => connect_id,
       "connected_account_ids" => calendars |> Enum.map(& &1["account_id"]) |> Enum.uniq(),
       "calendar_ids" => calendars |> Enum.map(& &1["calendar_id"]) |> Enum.uniq(),
       "meeting_calendar_id" => meeting_calendar_id,
       "watched_calendars" => entry["calendars"],
       "mode" => resolved["mode"] || "join",
       "channel" => entry["channel"],
       "channel_id" => channel_id,
       "readiness" => "ACTIVE"
     }}
  end

  defp policy_evidence(_resolved, _entry, _connect_id),
    do: {:error, :calendar_policy_invalid}

  defp trim(value), do: value |> to_string() |> String.trim()
end
