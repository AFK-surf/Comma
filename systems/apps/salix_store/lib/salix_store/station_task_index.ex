defmodule SalixStore.StationTaskIndex do
  @moduledoc """
  The Task index a station sends over its Connector run
  (docs/architecture/DOMAIN_CONCEPTS.md, "Station Task index"): one row per
  station-hosted Task, a station's own page chat, keyed by
  `(station_id, thread)`. A row holds the Task's title, status, creator,
  times, runtime and model, never message text. The station owns these
  facts; Salix only keeps the latest copy so members and the Router can list
  Tasks of stations that are offline.

  The station numbers every row change with a revision (`rev`) that grows
  within one index generation (`epoch`). Salix keeps, on the station's
  `salix_stations` row, the epoch it holds (`index_epoch`) and the highest
  revision it holds of it (`index_through`). A page that starts after what
  Salix holds, or is of another epoch, is not applied: Salix answers what it
  holds and the station sends again from there, or all of it with `reset`.

  A station holds at most 10,000 rows here. Removing a station, or moving
  it to another Group, deletes its rows (`delete_station/1`, called inside the
  roster's own transaction by `SalixStore.Stations`).
  """

  import Ecto.Query

  alias SalixStore.Repo
  alias SalixStore.Stations.Station

  @max_rows 10_000
  @max_page_rows 200
  @max_page_bytes 64 * 1024
  @max_title 120
  @max_text 200
  @max_labels 20
  @statuses ~w(in_progress needs_review done cancelled archived)

  defmodule Row do
    @moduledoc "One station-hosted Task as its station last sent it."
    use Ecto.Schema

    @primary_key false
    @timestamps_opts [
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    ]

    schema "salix_station_task_index" do
      field(:station_id, :string, primary_key: true)
      field(:thread, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:device_id, :string)
      field(:task, :string)
      field(:title, :string)
      field(:status, :string)
      field(:created_by, :string)
      field(:created_at, :integer)
      field(:last_activity_at, :integer)
      field(:runtime, :string)
      field(:model, :string)
      field(:labels, {:array, :string})
      field(:rev, :integer)

      timestamps()
    end
  end

  @doc "How many rows one station holds at most."
  def max_rows, do: @max_rows

  @doc "How many rows one page carries at most."
  def max_page_rows, do: @max_page_rows

  @doc "The statuses a row may have."
  def statuses, do: @statuses

  @doc """
  What Salix holds of a station's index: `%{"epoch" => epoch | nil,
  "through" => rev}`. The station compares it with its own to choose what to
  send.
  """
  def held(%Station{} = station),
    do: %{"epoch" => station.index_epoch, "through" => station.index_through || 0}

  @max_list 500

  @doc """
  The Group's station-hosted Tasks as their stations last sent them, the
  latest activity first: at most `limit` (at most #{@max_list}) rows of
  active stations, each a map of the row's fields.
  """
  def list_group(group_id, limit \\ @max_list) when is_binary(group_id) and is_integer(limit) do
    from(r in Row,
      join: s in Station,
      on: s.id == r.station_id and is_nil(s.removed_at),
      where: r.group_id == ^group_id,
      order_by: [desc: r.last_activity_at, asc: r.station_id, asc: r.thread],
      limit: ^min(max(limit, 1), @max_list),
      select:
        map(r, [
          :station_id,
          :device_id,
          :thread,
          :task,
          :title,
          :status,
          :created_by,
          :created_at,
          :last_activity_at,
          :runtime,
          :model,
          :labels,
          :rev
        ])
    )
    |> Repo.all()
  end

  @doc "One row of the Group's index, of an active station, else nil."
  def get(group_id, station_id, thread)
      when is_binary(group_id) and is_binary(station_id) and is_binary(thread) do
    Repo.one(
      from(r in Row,
        join: s in Station,
        on: s.id == r.station_id and is_nil(s.removed_at),
        where: r.group_id == ^group_id and r.station_id == ^station_id and r.thread == ^thread
      )
    )
  end

  @doc """
  Applies one page the station sent, for an active station of the run's
  Group (the caller checks that). `device_id` is the Device of the run the
  page came on; Salix stamps it on every row.

  `page`: `"epoch"` (string), `"reset"` (boolean: replace every row of the
  station), `"since"` (the revision the page continues from; ignored with
  reset), `"through"` (the revision the page brings the index to) and
  `"rows"`. A row is `"thread"` and `"rev"` with either `"removed" => true`
  (a tombstone: the row is deleted) or the Task's fields `"task"`, `"title"`
  (at most #{@max_title} characters are kept), `"status"`, `"created_by"`,
  `"created_at"`, `"last_activity_at"` (unix milliseconds), `"runtime"`,
  `"model"` and `"labels"` (the Group's label ids a person gave the Task, at
  most #{@max_labels}; a station from before sends none).

  Answers `{:ok, held}` with what Salix holds afterwards (`held/1`), also
  when the page was not applied. Errors: `:invalid_page`, `:page_too_large`,
  `:too_many_tasks`, `:station_removed`.
  """
  def apply_page(%Station{id: station_id}, device_id, page) when is_map(page) do
    with {:ok, page} <- parse_page(page) do
      Repo.transaction(fn ->
        station = lock_active(station_id) || Repo.rollback(:station_removed)

        if applies?(station, page) do
          if page.reset,
            do: Repo.delete_all(from(r in Row, where: r.station_id == ^station_id))

          write_rows(station, device_id, new_rows(station, page))

          if count(station_id) > @max_rows, do: Repo.rollback(:too_many_tasks)

          through =
            if page.reset,
              do: page.through,
              else: max(page.through, station.index_through || 0)

          station
          |> Ecto.Changeset.change(index_epoch: page.epoch, index_through: through)
          |> Repo.update!()
          |> held()
        else
          held(station)
        end
      end)
    end
  end

  def apply_page(_station, _device_id, _page), do: {:error, :invalid_page}

  @doc """
  Deletes every row of a station and forgets the epoch Salix held, so the
  station sends all of it again. Called by `SalixStore.Stations` when the
  station is removed or moves to another Group, inside that transaction.
  """
  def delete_station(station_id) when is_binary(station_id) do
    Repo.delete_all(from(r in Row, where: r.station_id == ^station_id))

    Repo.update_all(from(s in Station, where: s.id == ^station_id),
      set: [index_epoch: nil, index_through: nil]
    )

    :ok
  end

  # ── applying ────────────────────────────────────────────────────────────

  # A reset always applies. Otherwise the page must be of the held epoch and
  # continue from no later than what Salix holds.
  defp applies?(_station, %{reset: true}), do: true

  defp applies?(%Station{index_epoch: epoch} = station, %{epoch: epoch, since: since})
       when is_binary(epoch),
       do: since <= (station.index_through || 0)

  defp applies?(_station, _page), do: false

  # Salix already holds every change up to `index_through`: a row of a page
  # that overlaps it is applied or superseded (a tombstone included), so only
  # later revisions are written. A reset brings all of them.
  defp new_rows(_station, %{reset: true, rows: rows}), do: rows

  defp new_rows(%Station{index_through: held}, %{rows: rows}),
    do: Enum.filter(rows, &(&1.rev > (held || 0)))

  defp write_rows(station, device_id, rows) do
    {tombstones, live} = Enum.split_with(rows, & &1.removed)

    for %{thread: thread, rev: rev} <- tombstones do
      Repo.delete_all(
        from(r in Row,
          where: r.station_id == ^station.id and r.thread == ^thread and r.rev < ^rev
        )
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
        conflict_target: [:station_id, :thread],
        on_conflict:
          from(r in Row,
            where: r.rev < fragment("EXCLUDED.rev"),
            update: [
              set: [
                tenant_id: fragment("EXCLUDED.tenant_id"),
                group_id: fragment("EXCLUDED.group_id"),
                device_id: fragment("EXCLUDED.device_id"),
                task: fragment("EXCLUDED.task"),
                title: fragment("EXCLUDED.title"),
                status: fragment("EXCLUDED.status"),
                created_by: fragment("EXCLUDED.created_by"),
                created_at: fragment("EXCLUDED.created_at"),
                last_activity_at: fragment("EXCLUDED.last_activity_at"),
                runtime: fragment("EXCLUDED.runtime"),
                model: fragment("EXCLUDED.model"),
                labels: fragment("EXCLUDED.labels"),
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

  defp lock_active(station_id) do
    Repo.one(
      from(s in Station,
        where: s.id == ^station_id and is_nil(s.removed_at),
        lock: "FOR UPDATE"
      )
    )
  end

  # ── parsing ─────────────────────────────────────────────────────────────

  defp parse_page(page) do
    rows = Map.get(page, "rows", [])

    with {:ok, epoch} <- text(page["epoch"], 64),
         true <- is_list(rows) || {:error, :invalid_page},
         :ok <- page_bounds(rows),
         {:ok, rows} <- parse_rows(rows) do
      reset = page["reset"] == true
      since = non_negative(page["since"]) || 0
      top = rows |> Enum.map(& &1.rev) |> Enum.max(fn -> 0 end)

      {:ok,
       %{
         epoch: epoch,
         reset: reset,
         since: since,
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

  # Rows of one page are applied as one set: the latest revision of a thread wins.
  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case parse_row(row) do
        {:ok, %{thread: thread, rev: rev} = parsed} ->
          acc =
            case acc do
              %{^thread => %{rev: held}} when held >= rev -> acc
              _ -> Map.put(acc, thread, parsed)
            end

          {:cont, {:ok, acc}}

        :error ->
          {:halt, {:error, :invalid_page}}
      end
    end)
    |> case do
      {:ok, by_thread} -> {:ok, Map.values(by_thread)}
      error -> error
    end
  end

  defp parse_row(%{"thread" => thread, "rev" => rev, "removed" => true}) do
    with {:ok, thread} <- thread(thread),
         rev when is_integer(rev) and rev > 0 <- rev do
      {:ok, %{thread: thread, rev: rev, removed: true}}
    else
      _ -> :error
    end
  end

  defp parse_row(%{"thread" => thread, "rev" => rev} = row) do
    with {:ok, thread} <- thread(thread),
         true <- is_integer(rev) and rev > 0,
         {:ok, task} <- text(row["task"] || thread, @max_text),
         title when is_binary(title) <- row["title"],
         status when status in @statuses <- row["status"],
         {:ok, created_by} <- optional_text(row["created_by"], @max_text),
         created_at when is_integer(created_at) <- non_negative(row["created_at"]),
         active when is_integer(active) <- non_negative(row["last_activity_at"]),
         {:ok, runtime} <- optional_text(row["runtime"], 40),
         {:ok, model} <- optional_text(row["model"], 120),
         {:ok, labels} <- labels(row["labels"]) do
      {:ok,
       %{
         thread: thread,
         rev: rev,
         removed: false,
         task: task,
         title: title |> String.trim() |> String.slice(0, @max_title),
         status: status,
         created_by: created_by,
         created_at: created_at,
         last_activity_at: active,
         runtime: runtime,
         model: model,
         labels: labels
       }}
    else
      _ -> :error
    end
  end

  defp parse_row(_row), do: :error

  defp labels(nil), do: {:ok, []}

  defp labels(labels) when is_list(labels) and length(labels) <= @max_labels do
    if Enum.all?(labels, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 128)),
      do: {:ok, labels |> Enum.uniq() |> Enum.sort()},
      else: :error
  end

  defp labels(_labels), do: :error

  # A participant thread (`TASK/…`) is another station's Task and is never
  # indexed by the station that only takes part in it.
  defp thread("TASK/" <> _), do: :error

  defp thread(value) do
    case text(value, @max_text) do
      {:ok, thread} -> {:ok, thread}
      _ -> :error
    end
  end

  defp text(value, max) when is_binary(value) and value != "" do
    if byte_size(value) <= max, do: {:ok, value}, else: {:error, :invalid_page}
  end

  defp text(_value, _max), do: {:error, :invalid_page}

  defp optional_text(nil, _max), do: {:ok, nil}
  defp optional_text(value, max), do: text(value, max)

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil
end
