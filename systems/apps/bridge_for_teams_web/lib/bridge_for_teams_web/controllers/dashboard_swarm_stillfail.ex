defmodule BridgeForTeamsWeb.DashboardSwarmStillfail do
  @moduledoc """
  The Agent Swarm still.fail page for `DashboardAPIController`: the swarm's
  still.fail stations (`SalixEnv.StillfailDevices`), each one still.fail
  workspace, what still.fail's agents spent by person in the last 30 days (of
  one workspace's station with `device_id`), a new station's line to connect
  with, and removing one station or all of them.

  The page reads Salix through the client (`stillfail_stations/1`,
  `station_usage/6`), two bounded queries of the swarm's Group. Every swarm
  member reads it; making a line and removing stations are for swarm admins.
  A line is shown once, at the answer that made it.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Salix.Client

  @source "stillfail"
  @days 30
  @system_card_kinds ~w(login secret vault signin device adb rig)
  @attention_kinds ~w(need failed done)
  @active_statuses ~w(in_progress running waiting needs_review)
  @active_window_ms 24 * 60 * 60 * 1_000
  @max_tasks 50

  @doc "The page; `device_id` in `params` keeps one station's usage and tasks."
  def page(_org, _user, project, role, params \\ %{}) do
    now = SystemsClock.utc_now()
    today = DateTime.to_date(now)
    from = today |> Date.add(-(@days - 1)) |> Date.to_iso8601()
    now_ms = DateTime.to_unix(now, :millisecond)

    with {:ok, device} <- device_filter(params),
         {:ok, stations} <- call(:stillfail_stations, [project.salix_group_id]),
         {:ok, usage} <-
           call(:station_usage, [
             project.salix_group_id,
             from,
             Date.to_iso8601(today),
             :person,
             @source,
             device
           ]) do
      tasks = load_tasks(project.salix_group_id, device, now_ms)

      {:ok,
       %{
         "project" => %{"id" => project.id, "name" => project.name, "role" => role},
         "days" => @days,
         "stations" => stations,
         "tasks" => tasks,
         "usage" => usage
       }}
    end
  end

  @doc "A new still.fail station's line, `comma <server> <token>` (swarm admins only)."
  def connect(org, _user, project, role, _params) do
    with :ok <- admin(role),
         {:ok, line} <-
           call(:stillfail_connect_line, [org.salix_tenant_id, project.salix_group_id]) do
      {:ok, %{"line" => line}}
    end
  end

  @doc "Removes the swarm's still.fail stations and what they sent (swarm admins only)."
  def disconnect(_org, _user, project, role) do
    with :ok <- admin(role),
         {:ok, _removed} <- call(:remove_stillfail_stations, [project.salix_group_id]) do
      {:ok, %{"notice" => gettext("This Agent Swarm no longer has still.fail stations.")}}
    end
  end

  @doc "Removes one still.fail station of the swarm and what it sent (swarm admins only)."
  def disconnect_one(_org, _user, project, role, device_id) do
    with :ok <- admin(role),
         {:ok, _removed} <- call(:remove_stillfail_station, [project.salix_group_id, device_id]) do
      {:ok, %{"notice" => gettext("The still.fail station was disconnected.")}}
    end
  end

  # An empty or absent `device_id` is every station's usage.
  defp device_filter(%{"device_id" => device}) when is_binary(device) do
    case String.trim(device) do
      "" -> {:ok, nil}
      device -> {:ok, device}
    end
  end

  defp device_filter(%{"device_id" => _invalid}),
    do: {:error, 422, "invalid_device", gettext("device_id must be a station's id."), %{}}

  defp device_filter(_params), do: {:ok, nil}

  defp call(fun, args) do
    case Client.call_optional(fun, args) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        {:error, 404, "not_found", gettext("This Agent Swarm has no such still.fail station."),
         %{}}

      {:error, :unsupported} ->
        {:error, 503, "unavailable", gettext("Salix cannot answer this yet."), %{}}

      {:error, reason} ->
        {:error, 503, "unavailable",
         gettext("Salix did not answer: %{reason}", reason: inspect(reason)), %{}}
    end
  end

  defp admin("admin"), do: :ok

  defp admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can change this."), %{}}

  defp load_tasks(group_id, device, now_ms) do
    case Client.call_optional(:daily_brief_station_tasks, [group_id]) do
      {:ok, rows} when is_list(rows) ->
        format_tasks(rows, device, now_ms)

      _other ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp format_tasks(rows, device, now_ms) do
    active_cutoff_ms = now_ms - @active_window_ms

    rows
    |> Enum.flat_map(&serialize_task(&1, device, active_cutoff_ms))
    |> Enum.sort_by(fn task ->
      {task_priority(task), -(task["last_activity_at"] || 0), task["id"]}
    end)
    |> Enum.take(@max_tasks)
  end

  defp serialize_task(row, device, active_cutoff_ms) when is_map(row) do
    station_id = normalize_optional_text(field(row, :station_id, "station_id"))
    thread = normalize_optional_text(field(row, :thread, "thread"))
    device_id = normalize_optional_text(field(row, :device_id, "device_id"))
    url = normalize_optional_text(field(row, :url, "url"))
    status = normalize_optional_text(field(row, :status, "status"))
    attention = normalize_optional_text(field(row, :attention, "attention"))
    last_activity_at = integer_or_nil(field(row, :last_activity_at, "last_activity_at"))

    valid_url? = is_binary(url) and String.starts_with?(url, "https://")
    matches_device? = is_nil(device) or device_id == device

    visible? =
      attention in @attention_kinds or
        (status in @active_statuses and is_integer(last_activity_at) and
           last_activity_at >= active_cutoff_ms)

    if is_binary(station_id) and is_binary(thread) and valid_url? and matches_device? and visible? do
      card_kind = extract_card_kind(field(row, :labels, "labels"))
      title = normalize_optional_text(field(row, :title, "title")) || thread

      [
        %{
          "id" => "#{station_id}:#{thread}",
          "station_id" => station_id,
          "device_id" => device_id,
          "title" => title,
          "url" => url,
          "status" => status,
          "attention" => attention,
          "note" => normalize_optional_text(field(row, :note, "note")),
          "card_kind" => card_kind,
          "waits_for" => normalize_waits_for(field(row, :waits_for, "waits_for")),
          "created_by" => normalize_optional_text(field(row, :created_by, "created_by")),
          "last_activity_at" => last_activity_at
        }
      ]
    else
      []
    end
  end

  defp serialize_task(_row, _device, _active_cutoff_ms), do: []

  defp task_priority(%{"attention" => "need", "card_kind" => kind})
       when kind in @system_card_kinds,
       do: 0

  defp task_priority(%{"attention" => "need"}), do: 1
  defp task_priority(%{"attention" => nil, "status" => "needs_review"}), do: 1
  defp task_priority(%{"attention" => "failed"}), do: 2
  defp task_priority(%{"attention" => "done"}), do: 3
  defp task_priority(_task), do: 4

  defp extract_card_kind(labels) when is_list(labels) do
    Enum.find_value(labels, fn
      "card:" <> kind when kind != "" -> kind
      _ -> nil
    end)
  end

  defp extract_card_kind(_labels), do: nil

  defp normalize_waits_for(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_waits_for(_), do: []

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_), do: nil

  defp field(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
