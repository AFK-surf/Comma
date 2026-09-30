defmodule SalixAgent.InternalSessionFormat3Cutover do
  @moduledoc """
  Explicit online operator migration, after the migration-capable runtime has
  finished rolling out. One session at a time; paginated enumeration; original
  bytes backed up before each hot CAS. Durable formats, catalogs and watermarks are the restart cursor.
  No release/readiness dependency and no legacy-object deletion.

  Modeled in tla/salix/SessionFormat3Migration.tla.
  """
  alias SalixAgent.{
    InternalSession,
    InternalSessionFormat,
    InternalSessionMigrationSource,
    InternalSessionStore,
    SessionStorageRevision
  }

  alias SalixStore.{Codec, Keys, Repo, S3, SealedSegments}
  alias SalixStore.S3.Settle
  @marker "internal_session_format3_v1"
  @session_key ~r{\Aagents/([^/]+)/internal_runtime/sessions/([0-9a-f]+)/state\.etf\.zst\z}

  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)
    page_size = Keyword.get(opts, :page_size, 100)
    if page_size not in 1..1000, do: raise(ArgumentError, "page_size must be 1..1000")
    visit = if dry_run, do: &inspect_session/1, else: &migrate_session/1

    with {:ok, stats} <-
           scan(nil, page_size, %{sessions: 0, legacy: 0, migrated: 0, skipped: 0}, visit) do
      if dry_run do
        {:ok, Map.put(stats, :dry_run, true)}
      else
        with {:ok, verified} <-
               scan(
                 nil,
                 page_size,
                 %{sessions: 0, legacy: 0, migrated: 0, skipped: 0},
                 &inspect_session/1
               ),
             true <- verified.legacy == 0 || {:error, {:legacy_sessions_remain, verified.legacy}},
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO UPDATE SET completed_at = EXCLUDED.completed_at, evidence = EXCLUDED.evidence",
                 [@marker, %{verified_sessions: verified.sessions}]
               ) do
          {:ok, Map.merge(stats, %{verified: verified.sessions, dry_run: false})}
        end
      end
    end
  end

  defp scan(cursor, page_size, stats, visit) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list("agents/", max_keys: page_size, continuation_token: cursor),
         {:ok, stats} <-
           Enum.reduce_while(objects, {:ok, stats}, fn object, {:ok, acc} ->
             if Regex.match?(@session_key, object.key) do
               case visit.(object.key) do
                 {:ok, result} ->
                   {:cont,
                    {:ok,
                     acc |> Map.update!(:sessions, &(&1 + 1)) |> Map.update!(result, &(&1 + 1))}}

                 {:error, reason} ->
                   {:halt, {:error, {:session_migration_failed, object.key, reason}}}
               end
             else
               {:cont, {:ok, acc}}
             end
           end) do
      if next == nil, do: {:ok, stats}, else: scan(next, page_size, stats, visit)
    end
  end

  defp inspect_session(key) do
    case read(key) do
      {:ok, %{state: state}} -> classify(state)
      {:error, :not_found} -> {:ok, :skipped}
      {:error, _} = error -> error
    end
  end

  defp classify(state) do
    case InternalSession.storage_format(state) do
      format when format in [1, 2] -> {:ok, :legacy}
      3 -> if legacy_chunks?(state), do: {:ok, :legacy}, else: {:ok, :skipped}
      _ -> {:error, :unsupported_storage_format}
    end
  end

  defp legacy_chunks?(state), do: match?([_ | _], archive_chunks(state))
  defp archive_chunks(state), do: InternalSession.get(state, :archive_chunks)
  defp compacted_seq(state), do: InternalSession.get(state, :compacted_seq)

  def migrate_session(key), do: migrate_session(key, 3)
  defp migrate_session(_key, 0), do: {:error, :concurrent_session_write}

  defp migrate_session(key, budget) do
    with {:ok, snapshot} <- read(key) do
      result =
        case InternalSession.storage_format(snapshot.state) do
          3 ->
            if archive_chunks(snapshot.state) == [] and
                 compacted_seq(snapshot.state) <=
                   InternalSession.archived_through(snapshot.state),
               do: {:ok, :skipped},
               else: convert_segments(key, snapshot)

          1 ->
            normalize_hot(key, snapshot)

          2 ->
            convert_segments(key, snapshot)

          _ ->
            {:error, :unsupported_storage_format}
        end

      case result do
        :normalized ->
          case migrate_session(key, budget) do
            {:ok, _} -> {:ok, :migrated}
            error -> error
          end

        {:error, :precondition_failed} ->
          migrate_session(key, budget - 1)

        {:error, :archive_ahead} ->
          migrate_session(key, budget - 1)

        other ->
          other
      end
    end
  end

  # The kernel decodes and normalizes the stored snapshot; the host checks only
  # that the object belongs where it was found.
  defp read(key) do
    with [_, agent, _hex] <- Regex.run(@session_key, key) || {:error, :invalid_session_key},
         {:ok, %{body: bytes, etag: etag}} <- S3.get(key),
         {:ok, state} <- InternalSession.load(Codec.snapshot_etf(bytes)),
         ^agent <- InternalSession.agent_id(state),
         session <- InternalSession.session_id(state),
         true <- Keys.agent_internal_runtime_session(agent, session) == key do
      {:ok, %{state: state, bytes: bytes, etag: etag}}
    else
      {:error, :invalid_snapshot} -> {:error, :invalid_session_snapshot}
      {:error, _} = error -> error
      _ -> {:error, :invalid_session_snapshot}
    end
  rescue
    _ -> {:error, :invalid_session_snapshot}
  end

  defp backup_prefix(key, etag),
    do:
      String.replace_suffix(
        key,
        "state.etf.zst",
        "backup/format3/#{Base.url_encode64(etag, padding: false)}/"
      )

  defp backup(key, snapshot, archive) do
    prefix = backup_prefix(key, snapshot.etag)

    with :ok <- create_exact(prefix <> "state.etf.zst", snapshot.bytes),
         :ok <- create_exact(prefix <> "archive.jsonl", archive),
         do: :ok
  end

  defp create_exact(key, body) do
    case Settle.create_once(key, body, Settle.byte_settle(body)) do
      :created -> :ok
      :landed -> :ok
      {:exists, _} -> {:error, {:backup_divergence, key}}
      {:error, _} = error -> error
    end
  end

  defp normalize_hot(key, snapshot) do
    with {:ok, normalized} <- InternalSessionFormat.prepare_write(snapshot.state),
         {:ok, source} <- InternalSessionMigrationSource.read(normalized),
         :ok <- backup(key, snapshot, source.archive_bytes),
         :ok <- cas(key, snapshot.etag, normalized),
         do: :normalized
  end

  defp convert_segments(key, snapshot) do
    state = snapshot.state
    through = compacted_seq(state)

    with {:ok, source} <- InternalSessionMigrationSource.read(state),
         :ok <- backup(key, snapshot, source.archive_bytes),
         {:ok, catalog} <- seal(state, source.records, []),
         hot <-
           InternalSessionStore.window_records_shaped(state)
           |> Enum.take_while(&(&1.seq <= through)),
         {:ok, tail} <- seal(state, hot, []),
         final <- reseat_archive(state, catalog, tail, through),
         :ok <- cas(key, snapshot.etag, final),
         do: {:ok, :migrated}
  end

  # Retiring the legacy JSONL prefix in favour of sealed segments moves the
  # archive boundary and the catalog at once, which no session event does:
  # `archive_advance` only extends a format-3 catalog and never clears
  # `archive_chunks`. This one-off operator migration therefore rewrites the
  # exported state directly; every other caller stays on the handle API.
  defp reseat_archive(state, catalog, tail, through) do
    exported = InternalSession.export(state)

    exported
    |> Map.merge(%{
      storage_format: 3,
      archive_chunks: [],
      segment_catalog: catalog ++ exported.segment_catalog ++ tail,
      archived_through: through,
      messages: Enum.reject(exported.messages, &(&1[:seq] <= through)),
      events: Enum.reject(exported.events, &(&1["seq"] <= through)),
      async_results: Enum.reject(exported.async_results, &(&1["seq"] <= through))
    })
    |> InternalSession.open()
  end

  defp cas(key, etag, state) do
    body =
      state
      |> InternalSession.stamp(
        storage_revision: SessionStorageRevision.new(),
        flush_id: SessionStorageRevision.new()
      )
      |> InternalSession.persist()
      |> Codec.compress_snapshot_etf()

    Settle.cas_put(key, body, etag)
  end

  defp seal(_state, [], catalog), do: {:ok, Enum.reverse(catalog)}

  defp seal(state, [record | _] = records, catalog) do
    if record.seq > compacted_seq(state) do
      {:ok, Enum.reverse(catalog)}
    else
      key =
        Keys.agent_internal_runtime_session_segment(
          InternalSession.agent_id(state),
          InternalSession.session_id(state),
          record.seq
        )

      case S3.get(key) do
        {:ok, %{body: body}} ->
          adopt(state, records, catalog, key, body)

        {:error, :not_found} ->
          chosen = SealedSegments.next_segment(records, SealedSegments.line_bytes()).records

          body = SealedSegments.encode(chosen)

          case Settle.create_once(key, body, Settle.byte_settle(body)) do
            result when result in [:created, :landed] ->
              advance_seal(state, records, catalog, chosen)

            {:exists, %{body: winner}} ->
              adopt(state, records, catalog, key, winner)

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp adopt(state, records, catalog, key, body) do
    with {:ok, landed} <- SealedSegments.decode_safe(body),
         :ok <- InternalSession.match_archive_prefix(state, landed, records),
         true <- List.last(landed).seq <= compacted_seq(state) || {:error, :archive_ahead} do
      advance_seal(state, records, catalog, landed)
    else
      {:error, :segment_divergence} -> {:error, {:segment_divergence, key}}
      error -> error
    end
  end

  defp advance_seal(state, records, catalog, landed) do
    seal(state, Enum.drop(records, length(landed)), [SealedSegments.entry_for(landed) | catalog])
  end
end
