defmodule SalixStore.StationStats do
  @moduledoc """
  The analysis of a Group's statistics: every station's Stats index as Salix
  holds it (`SalixStore.StationStatsIndex`), its Comma stations' and its
  still.fail stations' (`SalixStore.StillfailStations`), read as one.
  Bounded: a span of at most 366 days, grouped in the
  database, at most 1,000 groups or tasks an answer.
  """

  import Ecto.Query

  alias SalixStore.Repo
  alias SalixStore.StationStatsIndex.Row
  alias SalixStore.Stations.Station
  alias SalixStore.StillfailStations

  @max_days 366
  @max_answer 1_000
  @by %{person: :person, model: :model, day: :day, source: :source, station: :station_id}

  @doc """
  What was spent from day `from` to day `to` (`"YYYY-MM-DD"`, both included, UTC),
  added up `by` one of `:person`, `:model`, `:day`, `:source`, `:station` or
  `:task` (the Task the spending was in, as a Router names a station-hosted
  Task: `station:<station_id>:<thread>`), of one `source` only when given
  (`"self"`, `"stillfail"`), of one `person` only when given:
  `{:ok, [%{"key" => value, "calls", "input", "cache_read", "cache_write", "output", "cost"}]}`,
  the most spent first.
  """
  def usage(group_id, from, to, by, source \\ nil, person \\ nil)

  def usage(group_id, from, to, by, source, person)
      when is_binary(group_id) and (is_map_key(@by, by) or by == :task) and
             (is_nil(source) or is_binary(source)) and (is_nil(person) or is_binary(person)) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.diff(to_date, from_date) in 0..(@max_days - 1) || {:error, :invalid_span} do
      key = key(by)

      rows =
        from(r in of_person(of_source(active(group_id), source), person),
          where: r.kind == "usage" and r.day >= ^from and r.day <= ^to,
          group_by: ^[key],
          select:
            ^%{
              "key" => key,
              "calls" => dynamic([r], sum(r.calls)),
              "input" => dynamic([r], sum(r.input)),
              "cache_read" => dynamic([r], sum(r.cache_read)),
              "cache_write" => dynamic([r], sum(r.cache_write)),
              "output" => dynamic([r], sum(r.output)),
              "cost" => dynamic([r], sum(r.cost))
            },
          order_by: [desc_nulls_last: sum(r.cost), desc: sum(r.calls)],
          limit: @max_answer
        )
        |> Repo.all()
        |> Enum.map(fn r -> Map.new(r, fn {k, v} -> {k, number(k, v)} end) end)

      {:ok, rows}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_span}
    end
  end

  def usage(_group_id, _from, _to, _by, _source, _person), do: {:error, :invalid_grouping}

  # What a row adds up under. A still.fail station's row of a chat on another
  # station of its workspace names that station (`station`), as its Task index
  # ref does (`<thread>@<station>`).
  defp key(:task) do
    dynamic(
      [r],
      fragment(
        "CASE WHEN (?->>'thread') IS NULL THEN NULL ELSE 'station:' || ? || ':' || (?->>'thread') || COALESCE('@' || (?->>'station'), '') END",
        r.row,
        r.station_id,
        r.row,
        r.row
      )
    )
  end

  defp key(by) do
    column = Map.fetch!(@by, by)
    dynamic([r], field(r, ^column))
  end

  defp of_source(query, nil), do: query
  defp of_source(query, source), do: where(query, [r], r.source == ^source)

  defp of_person(query, nil), do: query
  defp of_person(query, person), do: where(query, [r], r.person == ^person)

  @doc """
  The Group's chats with something in them since `since` (unix ms), the latest
  first: each one's station, source and the row as its station sent it.
  """
  def tasks(group_id, since \\ 0) when is_binary(group_id) and is_integer(since) do
    from(r in active(group_id),
      where: r.kind == "task" and fragment("(?->>'lastActiveAt')::bigint >= ?", r.row, ^since),
      order_by: [desc: fragment("(?->>'lastActiveAt')::bigint", r.row)],
      limit: @max_answer,
      select: %{"station_id" => r.station_id, "source" => r.source, "task" => r.row}
    )
    |> Repo.all()
  end

  defp active(group_id) do
    from(r in Row,
      left_join: s in Station,
      on: s.id == r.station_id and is_nil(s.removed_at),
      left_join: f in StillfailStations.Station,
      on: f.id == r.station_id,
      where: r.group_id == ^group_id,
      where: not is_nil(s.id) or not is_nil(f.id)
    )
  end

  # Token counts are whole numbers (SUM of bigint comes back a Decimal); cost is dollars.
  defp number("cost", %Decimal{} = d), do: Decimal.to_float(d)
  defp number(_key, %Decimal{} = d), do: Decimal.to_integer(d)
  defp number(_key, v), do: v
end
