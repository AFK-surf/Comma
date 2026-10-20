defmodule SalixWeb.StationTaskIndex do
  @moduledoc """
  A station's `task.index` request on its Connector run: a page of the Task
  index it keeps (`SalixStore.StationTaskIndex`, which says what a page
  holds). Salix answers what it holds afterwards, `{"epoch", "through"}`.

  Only a run that proved its station's key (`relay_register`,
  `SalixWeb.StationRelay`: the iroh endpoint id is the station id) may send,
  and only while that station is an active station of the run's Group; any
  other run is answered `not_this_group`. Salix stamps the run's Device on
  every row. One connection sends at most 4 pages a second; more are
  answered `rate_limited`.
  """

  alias SalixStore.{StationTaskIndex, Stations}

  @pages_per_second 4
  @pg __MODULE__.PG

  def child_spec(_opts), do: %{id: @pg, start: {:pg, :start_link, [@pg]}}

  @doc """
  Sends `subscriber` `{:station_tasks_invalidated, group_id}` each time a
  station of the Group changes the Task index Salix holds, until it exits.
  """
  def subscribe(group_id, subscriber)
      when is_binary(group_id) and is_pid(subscriber) do
    :pg.join(@pg, {:station_tasks, group_id}, subscriber)
  end

  @doc "The Group's station-hosted Tasks (`SalixStore.StationTaskIndex.list_group/2`)."
  def list(group_id), do: StationTaskIndex.list_group(group_id)

  @doc "The station id a relay registration proved, else nil."
  def station_id(%{endpoint: key}) when is_binary(key), do: Base.encode16(key, case: :lower)
  def station_id(_relay), do: nil

  @doc """
  Counts one page against the connection's rate: `{:ok, window}` to apply it,
  `{:error, :rate_limited}` when the connection sent its pages for this
  second. `window` is the connection's, nil at first.
  """
  def admit(window, now_ms) when is_integer(now_ms) do
    case window do
      %{start: start, count: count} when now_ms - start < 1_000 ->
        if count < @pages_per_second,
          do: {:ok, %{start: start, count: count + 1}},
          else: {:error, :rate_limited}

      _ ->
        {:ok, %{start: now_ms, count: 1}}
    end
  end

  @doc """
  Applies a page from the run `view` (`tenant_id`, `group_id`, `device_id`)
  whose relay registration proved `station_id`.
  """
  def receive_page(station_id, view, params) do
    with true <- is_binary(station_id) || {:error, :not_this_group},
         {:ok, station} <- Stations.active_station(station_id),
         true <-
           {station.tenant_id, station.group_id} == {view.tenant_id, view.group_id} ||
             {:error, :not_this_group} do
      case StationTaskIndex.apply_page(station, view.device_id, params) do
        {:error, :station_removed} ->
          {:error, :not_this_group}

        {:ok, held} = result ->
          if held != StationTaskIndex.held(station), do: invalidated(station.group_id)
          result

        result ->
          result
      end
    else
      {:error, :station_removed} -> {:error, :not_this_group}
      {:error, _reason} = error -> error
    end
  end

  defp invalidated(group_id) do
    for pid <- :pg.get_members(@pg, {:station_tasks, group_id}),
        do: SystemsRuntime.Proc.send(pid, {:station_tasks_invalidated, group_id})

    :ok
  end
end
