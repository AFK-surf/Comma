defmodule SalixAgent.SessionFormat3BackupPrune do
  @moduledoc """
  Retention-gated cleanup of format-3 migration backups. Every backup being
  deleted is checked against current raw history, not a masked transcript or
  a sample. Current session/legacy archive/segments are never deleted.

  Modeled in tla/salix/SessionFormat3Prune.tla.
  """
  alias SalixAgent.{InternalSession, InternalSessionFormat3Legacy, InternalSessionMigrationSource}
  alias SalixStore.{ArchiveLog, Codec, S3, Repo}

  @backup ~r{\A(agents/[^/]+/internal_runtime/sessions/[0-9a-f]+/)backup/format3/[A-Za-z0-9_-]+/(state\.etf\.zst|archive\.jsonl)\z}

  def run(opts \\ []) do
    days = Keyword.get(opts, :retention_days, 14)
    dry_run = Keyword.get(opts, :dry_run, true)
    now = DateTime.utc_now()

    if not is_integer(days) or days < 0,
      do: raise(ArgumentError, "retention_days must be nonnegative")

    with {:ok, %{rows: [[completed]]}} <-
           Repo.query(
             "SELECT completed_at FROM salix_cutover_markers WHERE name = 'internal_session_format3_v1'"
           ),
         :ok <- old_enough(utc(completed), now, days) do
      scan(nil, %{verified: 0, deleted: 0, dry_run: dry_run}, now, days)
    else
      {:ok, %{rows: []}} -> {:error, :migration_not_complete}
      {:error, _} = error -> error
    end
  end

  defp scan(cursor, stats, now, days) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list("agents/", max_keys: 100, continuation_token: cursor),
         {:ok, stats} <-
           Enum.reduce_while(objects, {:ok, stats}, fn object, {:ok, acc} ->
             case Regex.run(@backup, object.key) do
               [_, root, name] ->
                 case prune_one(object, root, name, acc.dry_run, now, days) do
                   {:ok, count} ->
                     {:cont,
                      {:ok,
                       %{
                         acc
                         | verified: acc.verified + count,
                           deleted: acc.deleted + if(acc.dry_run, do: 0, else: count)
                       }}}

                   {:error, reason} ->
                     {:halt, {:error, {:backup_prune_failed, object.key, reason}}}
                 end

               _ ->
                 {:cont, {:ok, acc}}
             end
           end) do
      if next == nil, do: {:ok, stats}, else: scan(next, stats, now, days)
    end
  end

  # State is removed first; an interrupted second delete leaves only archive
  # bytes, which can independently be compared with current immutable history.
  defp prune_one(object, root, "archive.jsonl", dry_run, now, days) do
    state_key = String.replace_suffix(object.key, "archive.jsonl", "state.etf.zst")

    case S3.head(state_key) do
      {:ok, _} ->
        {:ok, 0}

      {:error, :not_found} ->
        with :ok <- aged_object(object, now, days),
             {:ok, %{body: bytes}} <- S3.get(object.key),
             {:ok, current} <- current_records(root),
             :ok <- retained(ArchiveLog.decode!(bytes), current),
             :ok <- delete(object.key, dry_run),
             do: {:ok, 1}

      {:error, _} = error ->
        error
    end
  rescue
    _ -> {:error, :invalid_backup}
  end

  defp prune_one(object, root, "state.etf.zst", dry_run, now, days) do
    archive_key = String.replace_suffix(object.key, "state.etf.zst", "archive.jsonl")

    with :ok <- aged_object(object, now, days),
         {:ok, %{objects: [%{key: ^archive_key} = archive_object | _]}} <-
           S3.list(archive_key, max_keys: 1),
         :ok <- aged_object(archive_object, now, days),
         {:ok, %{body: bytes}} <- S3.get(object.key),
         {:ok, source} <- InternalSession.load(Codec.snapshot_etf(bytes)),
         {:ok, source} <- normalize_source(source),
         {:ok, %{body: archive}} <- S3.get(archive_key),
         {:ok, expected} <- InternalSessionMigrationSource.backup_records(source, archive),
         {:ok, current} <- current_records(root),
         :ok <- retained(expected, current),
         :ok <- delete(object.key, dry_run),
         :ok <- delete(archive_key, dry_run) do
      {:ok, 2}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_backup}
    end
  rescue
    _ -> {:error, :invalid_backup}
  end

  # The kernel owns the format-1 migration; `normalize/1` is its name here.
  defp normalize_source(session) do
    case InternalSession.storage_format(session) do
      1 -> InternalSessionFormat3Legacy.normalize(session)
      format when format in [2, 3] -> {:ok, session}
      _ -> {:error, :invalid_backup_format}
    end
  end

  defp current_records(root) do
    with {:ok, %{body: bytes}} <- S3.get(root <> "state.etf.zst"),
         {:ok, current} <- InternalSession.load(Codec.snapshot_etf(bytes)),
         3 <- InternalSession.storage_format(current) do
      InternalSessionMigrationSource.current_records(current)
    else
      {:error, :invalid_snapshot} -> {:error, :current_session_not_format3}
      {:error, _} = error -> error
      _ -> {:error, :current_session_not_format3}
    end
  end

  # A failed format-1 attempt may precede a later normalization with different
  # coordinates. Compare logical immutable contents and multiplicity; seq and
  # private result_seq are coordinate values, not cross-attempt identity.
  defp retained(expected, current) do
    signature = fn r -> {r.kind, Map.drop(r.data, ["result_seq"])} end
    counts = Enum.frequencies_by(current, signature)

    if Enum.all?(Enum.frequencies_by(expected, signature), fn {record, count} ->
         Map.get(counts, record, 0) >= count
       end), do: :ok, else: {:error, :history_not_retained}
  end

  defp aged_object(object, now, days) do
    with {:ok, date, _} <- DateTime.from_iso8601(object.last_modified),
         do: old_enough(date, now, days)
  end

  defp old_enough(date, now, days) do
    if DateTime.diff(now, date, :second) >= days * 86_400,
      do: :ok,
      else: {:error, :retention_window_open}
  end

  defp utc(%NaiveDateTime{} = date), do: DateTime.from_naive!(date, "Etc/UTC")
  defp utc(%DateTime{} = date), do: date
  defp delete(_key, true), do: :ok
  defp delete(key, false), do: S3.delete(key)
end
