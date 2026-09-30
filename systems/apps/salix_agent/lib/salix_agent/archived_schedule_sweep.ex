defmodule SalixAgent.ArchivedScheduleSweep do
  @moduledoc """
  Reconcile every agent's schedules with its archive state, once.

  `SalixAgent.AgentControl.delete/1` pauses an agent's schedules at archive
  time and `unarchive/2` resumes them (#849, `SalixAgent.ArchivedSchedules`).
  This sweep covers what those hooks cannot, in both directions:

    * an **archived** record whose rows are still active — archived before
      the hook existed, or a pause that failed after the record was written
      — gets them paused for the record's archive epoch;
    * a **live** record with archive-paused rows — a pause that landed on a
      stale observation and whose re-validation then failed — gets them
      resumed.

  It is idempotent: a row already in the right state is not touched, and a
  row the user paused keeps its own status (no `paused_by` marker), so
  running it again, or running it after the hooks, changes nothing.

  Cost: one LIST of `ctl/agents/`, one GET per control record with bounded
  concurrency, and at most one UPDATE (plus one re-validating GET) per
  agent. Only transport failures abort the listing; a record that vanished
  between LIST and GET, or no longer parses, is skipped like any other
  invalid record, so an outage is never mistaken for "nothing to do".

  The sweep acts on what it READ, possibly long after; the epoch fence and
  the post-pause re-validation in `ArchivedSchedules` are what make that
  safe against a concurrent unarchive. Modeled in
  tla/salix/SchedulePauseOnArchive.tla (`SweepRead`, `SweepAct`,
  `SweepRevalidate`).

      mix salix.schedules.pause_archived [--dry-run]
      bin/comma eval 'Comma.Release.pause_archived_agent_schedules()'
  """

  alias SalixAgent.ArchivedSchedules
  alias SalixStore.{Keys, S3, Schedules}

  @read_concurrency 8

  @type summary :: %{
          agents_scanned: non_neg_integer(),
          archived_agents: non_neg_integer(),
          schedules_paused: non_neg_integer(),
          schedules_resumed: non_neg_integer(),
          failed: [{String.t(), term()}],
          dry_run: boolean()
        }

  @doc """
  Run the sweep. `dry_run: true` counts the rows the sweep would pause or
  resume without writing. Returns `{:error, summary}` when any per-agent
  update failed, so a caller that raises on error (the release entry) fails
  the invocation.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, summary() | term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    now_ms = Keyword.get(opts, :now_ms) || System.system_time(:millisecond)

    with {:ok, objects} <- S3.list_all(Keys.ctl_agents_prefix()),
         {:ok, records} <- read_records(objects) do
      results =
        Enum.map(records, fn {agent_id, archived?, epoch} ->
          {agent_id, archived?, act(agent_id, archived?, epoch, dry_run?, now_ms)}
        end)

      summary = %{
        agents_scanned: length(objects),
        archived_agents: Enum.count(results, fn {_id, archived?, _} -> archived? end),
        schedules_paused: results |> Enum.map(&count(&1, :paused)) |> Enum.sum(),
        schedules_resumed: results |> Enum.map(&count(&1, :resumed)) |> Enum.sum(),
        failed: for({id, _archived?, {:error, reason}} <- results, do: {id, reason}),
        dry_run: dry_run?
      }

      if summary.failed == [], do: {:ok, summary}, else: {:error, summary}
    end
  end

  defp count({_id, _archived?, {:ok, counts}}, key), do: Map.get(counts, key, 0)
  defp count({_id, _archived?, {:error, _}}, _key), do: 0

  defp act(agent_id, true, epoch, false, now_ms) do
    with {:ok, %{paused: paused, undone: undone}} <-
           ArchivedSchedules.pause(agent_id, epoch, now_ms: now_ms) do
      {:ok, %{paused: paused, resumed: undone}}
    end
  end

  defp act(agent_id, false, epoch, false, now_ms) do
    with {:ok, resumed} <- ArchivedSchedules.reconcile_live(agent_id, epoch, now_ms: now_ms) do
      {:ok, %{paused: 0, resumed: resumed}}
    end
  end

  defp act(agent_id, archived?, epoch, true, _now_ms) do
    with {:ok, records} <- Schedules.list_by_agent(agent_id) do
      rows = Enum.filter(records, &(&1["receiver"] == "agent"))

      if archived? do
        {:ok,
         %{
           paused:
             Enum.count(rows, fn r ->
               r["status"] == "active" and (r["unarchived_epoch"] || 0) < epoch
             end),
           resumed: 0
         }}
      else
        {:ok,
         %{
           paused: 0,
           resumed:
             Enum.count(rows, fn r ->
               r["paused_by"] == "archive" and (r["archive_epoch"] || 0) <= epoch
             end)
         }}
      end
    end
  end

  # {agent_id, archived?, epoch} per readable control record.
  defp read_records(objects) do
    objects
    |> Task.async_stream(fn %{key: key} -> read_record(key) end,
      max_concurrency: @read_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, nil}}, acc -> {:cont, acc}
      {:ok, {:ok, entry}}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, _} = error -> error
    end
  end

  # nil = not an agent record (vanished, or unparseable).
  defp read_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, rec} when is_map(rec) ->
            {:ok,
             {rec["agent_id"] || agent_id_from_key(key), ArchivedSchedules.archived?(rec),
              ArchivedSchedules.archive_epoch(rec)}}

          _ ->
            {:ok, nil}
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp agent_id_from_key(key) do
    key
    |> String.replace_prefix(Keys.ctl_agents_prefix(), "")
    |> String.replace_suffix(".json", "")
  end
end
