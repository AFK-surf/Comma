defmodule SalixAgent.SessionFormat1BackupPrune do
  @moduledoc """
  The retention-window deletion of format-1 migration backups, with the
  pre-delete verification the plan requires: sampled sessions must decode as
  format 2, and every terminal result their backup recorded must be
  byte-equal readable at its seq in the format-2 window or archive.
  """

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionFormat2Cutover, as: Cutover
  alias SalixStore.{Codec, Keys, S3}

  @default_retention_days 14
  @sample_limit 100

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    dry_run = Keyword.get(opts, :dry_run, false)

    with :ok <- check_retention(retention_days),
         {:ok, backups} <- backup_keys(),
         :ok <- verify_sample(backups),
         {:ok, deleted} <- delete(backups, dry_run) do
      {:ok,
       %{
         "backups" => length(backups),
         "verified_sample" => min(length(backups), @sample_limit),
         "deleted" => deleted,
         "dry_run" => dry_run
       }}
    end
  end

  defp check_retention(retention_days) do
    with {:ok, completed_at} <- Cutover.marker_completed_at() do
      age_days = DateTime.diff(DateTime.utc_now(), to_utc_datetime(completed_at), :day)

      if age_days >= retention_days,
        do: :ok,
        else: {:error, {:retention_window_open, age_days, retention_days}}
    end
  end

  # The marker column is a naive `timestamp` (Ecto :utc_datetime_usec);
  # a raw Repo.query decodes it as NaiveDateTime, which DateTime.diff/3
  # rejects — a real marker row crashed the previous version here.
  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp backup_keys do
    with {:ok, agents} <- S3.list_all(Keys.ctl_agents_prefix()) do
      agents
      |> Enum.map(& &1.key)
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn key ->
        key
        |> String.replace_prefix(Keys.ctl_agents_prefix(), "")
        |> String.replace_suffix(".json", "")
      end)
      |> Enum.reject(&(&1 == "" or String.contains?(&1, "/")))
      |> Enum.reduce_while({:ok, []}, fn agent_id, {:ok, acc} ->
        case S3.list_all(Keys.agent_internal_runtime_sessions_prefix(agent_id)) do
          {:ok, objects} ->
            keys =
              objects
              |> Enum.map(& &1.key)
              |> Enum.filter(&String.ends_with?(&1, "/backup/format1-state.etf.zst"))

            {:cont, {:ok, acc ++ keys}}

          {:error, reason} ->
            {:halt, {:error, {:list_failed, agent_id, reason}}}
        end
      end)
    end
  end

  defp verify_sample(backups) do
    backups
    |> Enum.take(@sample_limit)
    |> Enum.reduce_while(:ok, fn backup_key, :ok ->
      case verify_backup(backup_key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:verification_failed, backup_key, reason}}}
      end
    end)
  end

  defp verify_backup(backup_key) do
    session_key =
      String.replace_suffix(backup_key, "/backup/format1-state.etf.zst", "/state.etf.zst")

    with {:ok, %{body: backup_bytes}} <- S3.get(backup_key),
         {:ok, %{body: current_bytes}} <- S3.get(session_key),
         {:ok, legacy} <- load(backup_bytes),
         {:ok, current} <- load(current_bytes),
         true <- InternalSession.storage_format(current) >= 2 || {:error, :not_format2} do
      legacy
      |> terminal_results_from_backup()
      |> verify_results(session_key, current)
    else
      false -> {:error, :not_format2}
      {:error, :invalid_snapshot} -> {:error, :undecodable}
      {:error, _} = err -> err
      _other -> {:error, :undecodable}
    end
  end

  # The kernel decodes and normalizes both snapshots.
  defp load(bytes) do
    InternalSession.load(Codec.snapshot_etf(bytes))
  rescue
    _ -> {:error, :undecodable}
  end

  # Replays the migration's deterministic total order (segment 1: covered
  # messages + ALL facts; segment 2: terminal results sorted by
  # {completed_at, tool_call_id}) to pin each record's EXACT expected seq:
  # an otherwise-identical record moved to another seq must not certify.
  # The kernel owns that replay; this reads the answer.
  defp terminal_results_from_backup(legacy),
    do: InternalSession.query(legacy, :terminal_results_from_backup)

  defp verify_results([], _session_key, _current), do: :ok

  # PRESENCE first, then the full terminal record. `Map.get == value` was a
  # certification hole: a failed/cancelled legacy call commonly carries
  # result == nil, and a MISSING migrated record also reads back nil — the
  # comparison passed and the sole recovery material could be deleted.
  defp verify_results(expected, _session_key, current) do
    with {:ok, records} <- all_format2_results(current) do
      by_id = Map.new(records, &{&1["tool_call_id"], &1})

      Enum.reduce_while(expected, :ok, fn {id, legacy_call, expected_seq}, :ok ->
        case Map.fetch(by_id, id) do
          :error ->
            {:halt, {:error, {:result_missing, id}}}

          {:ok, migrated} ->
            cond do
              migrated["seq"] != expected_seq ->
                {:halt, {:error, {:result_seq_mismatch, id, expected_seq, migrated["seq"]}}}

              not same_terminal_record?(legacy_call, migrated) ->
                {:halt, {:error, {:result_mismatch, id}}}

              true ->
                {:cont, :ok}
            end
        end
      end)
    end
  end

  # The FULL canonical record: the migration copies the terminal call map
  # verbatim, so every field — including cancellation/error/diagnostic
  # payload the old comparison ignored — must survive. Comparison is over
  # the canonical ENCODED forms: archived JSON normalizes nested maps and
  # atoms recursively, and a shallow normalization would falsely reject a
  # correct migration of %{result: %{answer: :ok}}.
  defp same_terminal_record?(legacy_call, migrated) do
    canonical(Map.drop(migrated, ["seq", "kind"])) == canonical(legacy_call)
  end

  defp canonical(value), do: value |> Jason.encode!() |> Jason.decode!()

  # The committed archive reader (watermark-capped, gap-checked) plus the
  # hot window — the same logical view every other reader uses.
  defp all_format2_results(current) do
    with {:ok, records} <-
           SalixAgent.InternalSessionStore.archived_records(
             InternalSession.agent_id(current),
             current
           ) do
      archived =
        for %{kind: "async_result", seq: seq, data: data} <- records,
            do: Map.put(data, "seq", seq)

      {:ok, archived ++ (InternalSession.get(current, :async_results) || [])}
    end
  end

  defp delete(_backups, true), do: {:ok, 0}

  defp delete(backups, false) do
    Enum.reduce_while(backups, {:ok, 0}, fn key, {:ok, count} ->
      case S3.delete(key) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, :not_found} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, {:delete_failed, key, reason}}}
      end
    end)
  end
end
