defmodule SalixAgent.InternalSessionMigrationSource do
  @moduledoc "Operator-only materialization and verification of legacy recovery data."
  alias SalixAgent.{InternalSession, InternalSessionArchiveReader, InternalSessionStore}
  alias SalixStore.{ArchiveLog, Keys, S3, SealedSegments}

  def read(session) do
    with {:ok, spans} <- InternalSessionArchiveReader.committed_spans(session),
         :ok <- window_complete(session),
         legacy <- Enum.filter(spans, &Map.has_key?(&1, :offset)),
         {:ok, bytes} <- archive_bytes(session, legacy),
         {:ok, records} <- prefix_records(session, bytes) do
      {:ok, %{records: records, archive_bytes: bytes}}
    end
  end

  defp window_complete(session) do
    records = InternalSessionStore.window_records_shaped(session)

    with :ok <- SealedSegments.validate(records),
         true <-
           length(records) == last_seq(session) - InternalSession.archived_through(session) ||
             {:error, :incomplete_migration_source},
         true <-
           (records == [] or
              hd(records).seq == InternalSession.archived_through(session) + 1) ||
             {:error, :incomplete_migration_source},
         do: :ok
  end

  def backup_records(session, bytes) do
    with {:ok, records} <- prefix_records(session, bytes),
         {:ok, spans} <- InternalSessionArchiveReader.committed_spans(session),
         {:ok, segments} <-
           InternalSessionArchiveReader.read(
             InternalSession.agent_id(session),
             session,
             Enum.reject(spans, &Map.has_key?(&1, :offset))
           ),
         all <- records ++ segments ++ InternalSessionStore.window_records_shaped(session),
         :ok <- complete(all, last_seq(session)) do
      {:ok, all}
    end
  end

  def current_records(session) do
    with {:ok, archived} <-
           InternalSessionStore.archived_records(
             InternalSession.agent_id(session),
             session,
             mask: false
           ),
         all <- archived ++ InternalSessionStore.window_records_shaped(session),
         :ok <- complete(all, last_seq(session)),
         do: {:ok, all}
  end

  defp last_seq(session), do: InternalSession.get(session, :last_seq)

  defp prefix_records(session, bytes) do
    with {:ok, spans} <- InternalSessionArchiveReader.committed_spans(session),
         legacy <- Enum.filter(spans, &Map.has_key?(&1, :offset)),
         true <-
           byte_size(bytes) == Enum.reduce(legacy, 0, &(&1.length + &2)) ||
             {:error, :invalid_backup_prefix},
         records <- ArchiveLog.decode!(bytes),
         through <-
           (case List.last(legacy) do
              nil -> 0
              span -> span.last
            end),
         :ok <- complete(records, through) do
      {:ok, records}
    end
  rescue
    _ -> {:error, :invalid_migration_source}
  end

  defp complete(records, through) do
    with :ok <- SealedSegments.validate(records),
         true <- length(records) == through || {:error, :incomplete_migration_source},
         true <- (records == [] or hd(records).seq == 1) || {:error, :incomplete_migration_source},
         do: :ok
  end

  defp archive_bytes(_session, []), do: {:ok, ""}

  defp archive_bytes(session, spans) do
    size = Enum.reduce(spans, 0, &(&1.length + &2))

    key =
      Keys.agent_internal_runtime_session_archive(
        InternalSession.agent_id(session),
        InternalSession.session_id(session)
      )

    case S3.get(key, range: {0, size}) do
      {:ok, %{body: bytes}} when byte_size(bytes) == size -> {:ok, bytes}
      {:ok, _} -> {:error, {:archive_incomplete, %{key: key, reason: :short_prefix}}}
      {:error, reason} -> {:error, {:archive_unreadable, key, reason}}
    end
  end
end
