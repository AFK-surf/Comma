defmodule SalixStore.StationStatsIndex do
  @moduledoc """
  The Stats index a station sends over its Connector run (`stats.index`), as
  its Task index (`SalixStore.StationTaskIndex`): the station's statistics in
  one structure, kept as the station last sent them. A row is one `source`'s
  (`self`: the station's own; `stillfail`: a still.fail station's, connected
  through a Comma connect, `SalixStore.StillfailStations`) `kind`:

    * `usage`: what was spent in one day for one chat, person, account,
      runtime and model: `calls`, `input`, `cacheRead`, `cacheWrite`,
      `output` tokens, `cost` (dollars at list prices, or null);
    * `task`: a chat: its title, state, creator, times and agents;
    * `source`: how an outside source stands on the station (`state`: asking,
      granted, refused, revoked, failed; `at`; `scopes`; `message`).

  The station owns the rows; Salix keeps the latest copy, numbered by revision
  within an epoch (`salix_stations.stats_epoch`, `stats_through`; a still.fail
  station's in `salix_stillfail_stations`), and the
  analysis reads it (`SalixStore.StationStats`). A page carries at most 200
  rows and 64 KiB; a station holds at most 100,000 rows. Removing the station,
  or moving it to another Group, deletes its rows.
  """

  import Ecto.Query

  alias SalixStore.Repo
  alias SalixStore.Stations.Station
  alias SalixStore.StillfailStations

  @max_rows 100_000
  @max_page_rows 200
  @max_page_bytes 64 * 1024
  @kinds ~w(usage task source)

  defmodule Row do
    @moduledoc "One row of a station's Stats index as its station last sent it."
    use Ecto.Schema

    @primary_key false
    @timestamps_opts [
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    ]

    schema "salix_station_stats_index" do
      field(:station_id, :string, primary_key: true)
      field(:key, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:device_id, :string)
      field(:source, :string)
      field(:kind, :string)
      field(:day, :string)
      field(:person, :string)
      field(:model, :string)
      field(:calls, :integer, default: 0)
      field(:input, :integer, default: 0)
      field(:cache_read, :integer, default: 0)
      field(:cache_write, :integer, default: 0)
      field(:output, :integer, default: 0)
      field(:cost, :float)
      field(:row, :map)
      field(:rev, :integer)

      timestamps()
    end
  end

  @doc "What Salix holds of a station's Stats index: `%{\"epoch\", \"through\"}`."
  def held(%{stats_epoch: _, stats_through: _} = station),
    do: %{"epoch" => station.stats_epoch, "through" => station.stats_through || 0}

  @doc """
  Applies one page the station sent, for an active station of the run's Group
  (a `SalixStore.Stations.Station`, or a still.fail station's
  `SalixStore.StillfailStations.Station`; the caller checks that), as
  `SalixStore.StationTaskIndex.apply_page/3` does:
  `"epoch"`, `"reset"`, `"since"`, `"through"` and `"rows"`, each row `"key"`,
  `"source"`, `"kind"`, `"rev"` and either `"removed" => true` or `"row"`.
  Answers `{:ok, held}`, also when the page was not applied.
  """
  def apply_page(%kind{id: station_id}, device_id, page)
      when kind in [Station, StillfailStations.Station] and is_map(page) do
    with {:ok, page} <- parse_page(page) do
      Repo.transaction(fn ->
        station = lock_active(kind, station_id) || Repo.rollback(:station_removed)

        if applies?(station, page) do
          if page.reset,
            do: Repo.delete_all(from(r in Row, where: r.station_id == ^station_id))

          write_rows(station, device_id, new_rows(station, page))

          if count(station_id) > @max_rows, do: Repo.rollback(:too_many_rows)

          through =
            if page.reset,
              do: page.through,
              else: max(page.through, station.stats_through || 0)

          station
          |> Ecto.Changeset.change(stats_epoch: page.epoch, stats_through: through)
          |> Repo.update!()
          |> held()
        else
          held(station)
        end
      end)
    end
  end

  def apply_page(_station, _device_id, _page), do: {:error, :invalid_page}

  @doc "Deletes a station's rows and forgets what Salix held (inside the caller's transaction)."
  def delete_station(station_id) when is_binary(station_id) do
    Repo.delete_all(from(r in Row, where: r.station_id == ^station_id))

    Repo.update_all(from(s in Station, where: s.id == ^station_id),
      set: [stats_epoch: nil, stats_through: nil]
    )

    :ok
  end

  # ── applying ────────────────────────────────────────────────────────────

  defp applies?(_station, %{reset: true}), do: true

  defp applies?(%{stats_epoch: epoch} = station, %{epoch: epoch, since: since})
       when is_binary(epoch),
       do: since <= (station.stats_through || 0)

  defp applies?(_station, _page), do: false

  defp new_rows(_station, %{reset: true, rows: rows}), do: rows

  defp new_rows(%{stats_through: held}, %{rows: rows}),
    do: Enum.filter(rows, &(&1.rev > (held || 0)))

  defp write_rows(station, device_id, rows) do
    {tombstones, live} = Enum.split_with(rows, & &1.removed)

    for %{key: key, rev: rev} <- tombstones do
      Repo.delete_all(
        from(r in Row, where: r.station_id == ^station.id and r.key == ^key and r.rev < ^rev)
      )
    end

    if live != [] do
      now = SystemsClock.timestamp(:utc_datetime_usec)

      entries =
        Enum.map(live, fn row ->
          row
          |> Map.drop([:removed])
          |> Map.merge(%{
            station_id: station.id,
            tenant_id: station.tenant_id,
            group_id: station.group_id,
            device_id: device_id,
            inserted_at: now,
            updated_at: now
          })
        end)

      Repo.insert_all(Row, entries,
        conflict_target: [:station_id, :key],
        on_conflict:
          from(r in Row,
            where: r.rev < fragment("EXCLUDED.rev"),
            update: [
              set: [
                tenant_id: fragment("EXCLUDED.tenant_id"),
                group_id: fragment("EXCLUDED.group_id"),
                device_id: fragment("EXCLUDED.device_id"),
                source: fragment("EXCLUDED.source"),
                kind: fragment("EXCLUDED.kind"),
                day: fragment("EXCLUDED.day"),
                person: fragment("EXCLUDED.person"),
                model: fragment("EXCLUDED.model"),
                calls: fragment("EXCLUDED.calls"),
                input: fragment("EXCLUDED.input"),
                cache_read: fragment("EXCLUDED.cache_read"),
                cache_write: fragment("EXCLUDED.cache_write"),
                output: fragment("EXCLUDED.output"),
                cost: fragment("EXCLUDED.cost"),
                row: fragment("EXCLUDED.row"),
                rev: fragment("EXCLUDED.rev"),
                updated_at: fragment("EXCLUDED.updated_at")
              ]
            ]
          )
      )
    end

    :ok
  end

  defp count(station_id),
    do: Repo.aggregate(from(r in Row, where: r.station_id == ^station_id), :count)

  defp lock_active(StillfailStations.Station, station_id), do: StillfailStations.lock(station_id)

  defp lock_active(Station, station_id) do
    Repo.one(
      from(s in Station, where: s.id == ^station_id and is_nil(s.removed_at), lock: "FOR UPDATE")
    )
  end

  # ── parsing ─────────────────────────────────────────────────────────────

  defp parse_page(page) do
    rows = Map.get(page, "rows", [])

    with {:ok, epoch} <- text(page["epoch"], 64),
         true <- is_list(rows) || {:error, :invalid_page},
         :ok <- page_bounds(rows),
         {:ok, rows} <- parse_rows(rows) do
      top = rows |> Enum.map(& &1.rev) |> Enum.max(fn -> 0 end)

      {:ok,
       %{
         epoch: epoch,
         reset: page["reset"] == true,
         since: non_negative(page["since"]) || 0,
         through: max(non_negative(page["through"]) || 0, top),
         rows: rows
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_page}
    end
  end

  defp page_bounds(rows) do
    cond do
      length(rows) > @max_page_rows -> {:error, :page_too_large}
      byte_size(Jason.encode!(rows)) > @max_page_bytes -> {:error, :page_too_large}
      true -> :ok
    end
  end

  # Rows of one page are applied as one set: the latest revision of a key wins.
  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case parse_row(row) do
        {:ok, %{key: key, rev: rev} = parsed} ->
          acc =
            case acc do
              %{^key => %{rev: held}} when held >= rev -> acc
              _ -> Map.put(acc, key, parsed)
            end

          {:cont, {:ok, acc}}

        :error ->
          {:halt, {:error, :invalid_page}}
      end
    end)
    |> case do
      {:ok, by_key} -> {:ok, Map.values(by_key)}
      error -> error
    end
  end

  defp parse_row(%{"key" => key, "source" => source, "kind" => kind, "rev" => rev} = row)
       when kind in @kinds and is_integer(rev) and rev > 0 do
    with {:ok, key} <- text(key, 512),
         {:ok, source} <- text(source, 64) do
      case row do
        %{"removed" => true} ->
          {:ok, %{key: key, source: source, kind: kind, rev: rev, removed: true}}

        %{"row" => fields} when is_map(fields) ->
          {:ok,
           Map.merge(
             %{key: key, source: source, kind: kind, rev: rev, removed: false, row: fields},
             columns(kind, fields)
           )}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp parse_row(_row), do: :error

  # What the analysis groups and adds by, out of the row.
  defp columns("usage", f) do
    %{
      day: short(f["day"], 10),
      person: short(f["person"], 200),
      model: short(f["model"], 120),
      calls: count_of(f["calls"]),
      input: count_of(f["input"]),
      cache_read: count_of(f["cacheRead"]),
      cache_write: count_of(f["cacheWrite"]),
      output: count_of(f["output"]),
      cost: if(is_number(f["cost"]), do: f["cost"] * 1.0)
    }
  end

  defp columns("source", _f), do: columns("task", %{})

  defp columns("task", f) do
    %{
      day: nil,
      person: short(f["creator"], 200),
      model: nil,
      calls: 0,
      input: 0,
      cache_read: 0,
      cache_write: 0,
      output: 0,
      cost: nil
    }
  end

  defp short(value, max) when is_binary(value) and value != "", do: String.slice(value, 0, max)
  defp short(_value, _max), do: nil

  defp count_of(value) when is_integer(value) and value >= 0, do: value
  defp count_of(_value), do: 0

  defp text(value, max) when is_binary(value) and value != "" do
    if byte_size(value) <= max, do: {:ok, value}, else: {:error, :invalid_page}
  end

  defp text(_value, _max), do: {:error, :invalid_page}

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil
end
