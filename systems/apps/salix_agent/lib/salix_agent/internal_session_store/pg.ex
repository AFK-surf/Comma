defmodule SalixAgent.InternalSessionStore.PG do
  @moduledoc false

  require Logger

  alias SalixAgent.{InternalSession, SessionStorageRevision, SessionWorkRecovery}
  alias SalixAgent.InternalSessionStore.{PGCodec, Revision}
  alias SalixStore.{Keys, Repo}
  alias SalixStore.SessionHistoryRepo, as: HistoryRepo

  @page_size 128
  @freeze_steps {__MODULE__, :freeze_steps}
  @archive_batch_records 256
  @archive_idle_seconds 30
  # What a read of a session's newest messages may touch (`recent_messages/4`).
  @recent_hot_records 200
  @recent_archive_spans 8
  @archive_columns "s.birth_kind,s.deleted_at,s.control_payload IS NOT NULL AS materialized,s.revision,s.storage_revision,s.last_seq,s.archived_through,s.archive_target_seq,s.last_activity_at"
  @session_columns ~w(agent_id session_id birth_kind name hidden created_at last_activity_at revision storage_revision runtime_epoch control_payload context_revision last_seq compacted_seq queue_ack_id next_queue_id next_message_id archived_through next_run_at work_reasons dispatch_after archive_target_seq deleted_at)

  defmodule Pending do
    @moduledoc false
    @enforce_keys [
      :agent_id,
      :session_id,
      :expected_revision,
      :runtime_epoch,
      :storage_revision,
      :delta,
      :candidate
    ]
    @derive {Inspect,
             only: [:agent_id, :session_id, :expected_revision, :runtime_epoch, :storage_revision]}
    defstruct [
      :agent_id,
      :session_id,
      :expected_revision,
      :runtime_epoch,
      :storage_revision,
      :delta,
      :candidate,
      :command,
      :base_storage_revision
    ]
  end

  defmodule CreatedSeed do
    @moduledoc false
    @enforce_keys [:owned, :pending]
    @derive {Inspect, only: []}
    defstruct [:owned, :pending]
  end

  defmodule InputEffect do
    @moduledoc false
    @enforce_keys [:agent_id, :session_id, :expected_revision, :runtime_epoch, :command, :request]
    @derive {Inspect, only: [:agent_id, :session_id, :expected_revision, :runtime_epoch]}
    defstruct [:agent_id, :session_id, :expected_revision, :runtime_epoch, :command, :request]
  end

  defmodule Archive do
    @moduledoc false
    @enforce_keys [
      :agent_id,
      :session_id,
      :expected_through,
      :candidate_through,
      :through,
      :entries
    ]
    defstruct [
      :agent_id,
      :session_id,
      :expected_through,
      :candidate_through,
      :through,
      :entries,
      :expected_storage_revision
    ]
  end

  defmodule Import do
    @moduledoc false
    @enforce_keys [
      :agent_id,
      :session_id,
      :runtime_epoch,
      :storage_revision,
      :delta,
      :archive_refs
    ]
    @derive {Inspect, only: [:agent_id, :session_id]}
    defstruct [:agent_id, :session_id, :runtime_epoch, :storage_revision, :delta, :archive_refs]
  end

  # The offline importer owns its marker and complete Agent root transaction.
  # Preparing this value neither claims runtime authority nor stamps a new
  # storage identity. All legacy reads precede SQL; archive bytes stay intact.
  def prepare_import(agent_id, state, exact_archive_refs) do
    with {:ok, state} <-
           state
           |> InternalSession.stamp(agent_id: agent_id)
           |> InternalSession.prepare_write() do
      cursor = InternalSession.start_revision(state, nil)
      {:ok, delta} = InternalSession.revision_delta(cursor)
      reasons = InternalSession.work_reasons(state)

      delta =
        delta
        |> Map.put("work_reasons", reasons)
        |> Map.put("next_run_at_ms", next_run(state, reasons))
        |> Map.put("archives_add", archive_entries(exact_archive_refs))

      compacted = InternalSession.get(state, :compacted_seq) || 0
      delta = if compacted > 0, do: Map.put(delta, "archive_target_seq", compacted), else: delta

      {:ok,
       %Import{
         agent_id: agent_id,
         session_id: InternalSession.session_id(state),
         runtime_epoch: InternalSession.get(state, :runtime_epoch),
         storage_revision: InternalSession.get(state, :storage_revision),
         delta: delta,
         archive_refs: exact_archive_refs
       }}
    end
  end

  @doc false
  def import_birth_page(cursor) do
    {condition, params} =
      case cursor do
        nil -> {"", []}
        {agent, session} -> {"WHERE (agent_id,session_id)>($1,$2)", [agent, session]}
      end

    case Repo.query(
           "SELECT agent_id,session_id,birth_kind FROM salix_sessions #{condition} ORDER BY agent_id,session_id LIMIT 1000",
           params
         ) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      _ -> {:error, :import_state_unavailable}
    end
  end

  def import_session!(%Import{} = frozen) do
    import_birth!(frozen.agent_id, frozen.session_id, :internal)
    previous = session_row(frozen.agent_id, frozen.session_id, "")
    write_delta(frozen, previous, 1, max_rows: 512)
    :ok
  end

  def import_birth!(agent_id, session_id, kind) when kind in [:internal, :retired] do
    Repo.query!(
      "INSERT INTO salix_sessions (agent_id,session_id,birth_kind,revision) VALUES($1,$2,$3,0)",
      [agent_id, session_id, Atom.to_string(kind)]
    )

    :ok
  end

  def archive_work_page(cursor \\ nil) do
    result =
      rows(
        """
        WITH page AS MATERIALIZED (
          SELECT s.agent_id,s.session_id,s.archive_target_seq,s.archived_through,s.last_activity_at
          FROM salix_sessions s
          JOIN salix_agents a ON a.agent_id=s.agent_id AND a.config_revision>0
          WHERE s.birth_kind='internal' AND s.control_payload IS NOT NULL
            AND s.deleted_at IS NULL AND s.archive_target_seq IS NOT NULL
            AND s.archive_target_seq>COALESCE(s.archived_through,0)
            AND (s.agent_id,s.session_id)>($1,$2)
          ORDER BY s.agent_id,s.session_id LIMIT #{@page_size}
        )
        SELECT s.agent_id,s.session_id,(#{archive_due_sql()}) AS ready
        FROM page s ORDER BY s.agent_id,s.session_id
        """,
        (cursor || ["", ""]) ++ [archive_idle_cutoff()]
      )

    ids = for row <- result, row["ready"], do: [row["agent_id"], row["session_id"]]
    last = List.last(result)
    next = if length(result) == @page_size, do: [last["agent_id"], last["session_id"]]
    {:ok, ids, next}
  end

  def archive_head(agent_id, session_id) do
    case rows(
           "SELECT #{@archive_columns},#{archive_ready_sql()} AS ready FROM salix_sessions s WHERE s.agent_id=$1 AND s.session_id=$2",
           [agent_id, session_id] ++ archive_policy_params()
         ) do
      [%{"birth_kind" => "internal", "deleted_at" => nil, "materialized" => true} = row] ->
        {:ok,
         %{
           agent_id: agent_id,
           session_id: session_id,
           expected_through: row["archived_through"] || 0,
           target: row["archive_target_seq"],
           storage_revision: row["storage_revision"],
           ready: row["ready"]
         }}

      [%{"birth_kind" => "retired"}] ->
        {:error, :session_read_only}

      _ ->
        {:error, :not_found}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp archive_policy_params do
    [
      archive_idle_cutoff(),
      SalixStore.SealedSegments.line_bytes()
    ]
  end

  defp archive_idle_cutoff,
    do: DateTime.from_unix!(SystemsClock.system_time(:second) - @archive_idle_seconds)

  defp archive_due_sql do
    """
    s.archive_target_seq-COALESCE(s.archived_through,0)>=#{@archive_batch_records}
    OR s.last_activity_at IS NULL OR s.last_activity_at<=$3
    """
  end

  # Examine payload lengths only, over a bounded prefix of the pending range.
  # The cursor advances over the captured page even when no row is ready.
  defp archive_ready_sql do
    """
    CASE
      WHEN COALESCE(s.archive_target_seq,0)<=COALESCE(s.archived_through,0) THEN false
      WHEN #{archive_due_sql()} THEN true
      ELSE COALESCE((
        SELECT sum(h.bytes) FROM (
          SELECT octet_length(r.payload) AS bytes FROM salix_session_records r
          WHERE r.agent_id=s.agent_id AND r.session_id=s.session_id
            AND r.seq>COALESCE(s.archived_through,0) AND r.seq<=s.archive_target_seq
          ORDER BY r.seq LIMIT #{@archive_batch_records}
        ) h
      ),0)>=$4
    END
    """
  end

  # The one-time runner admits unchanged imports and resumes existing work.
  # A pending target grants ordinary archival, not proof of an unchanged import.
  def archive_maintenance_page(cursor \\ nil, agent_id \\ nil) do
    page =
      rows(
        """
        SELECT s.agent_id,s.session_id FROM salix_sessions s
        JOIN salix_agents a ON a.agent_id=s.agent_id AND a.config_revision>0
        WHERE s.birth_kind='internal' AND s.control_payload IS NOT NULL
          AND s.deleted_at IS NULL AND (s.agent_id,s.session_id)>($1,$2)
          AND ($3::text IS NULL OR s.agent_id=$3)
          AND (
            s.last_seq>COALESCE(s.archived_through,0)
            OR EXISTS (
              SELECT 1 FROM salix_session_records r
              WHERE r.agent_id=s.agent_id AND r.session_id=s.session_id
                AND r.seq<=s.archived_through
            )
          )
        ORDER BY s.agent_id,s.session_id LIMIT #{@page_size}
        """,
        (cursor || ["", ""]) ++ [agent_id]
      )

    ids = Enum.map(page, &[&1["agent_id"], &1["session_id"]])
    {:ok, ids, if(length(ids) == @page_size, do: List.last(ids))}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def admit_archive_maintenance(agent_id, session_id) do
    Repo.transaction(fn ->
      lock_archive_agent(agent_id)
      row = archive_row(agent_id, session_id, "FOR UPDATE")
      internal!(row)
      through = row["archived_through"] || 0
      last = row["last_seq"] || 0

      previous_target = row["archive_target_seq"]

      if last > through do
        target = max(previous_target || 0, last)

        Repo.query!(
          "UPDATE salix_sessions SET archive_target_seq=$3 WHERE agent_id=$1 AND session_id=$2",
          [agent_id, session_id, target]
        )
      end

      target = if row["revision"] == 1, do: last, else: previous_target

      if is_integer(target) and target > through do
        %{
          agent_id: agent_id,
          session_id: session_id,
          expected_through: through,
          target: target,
          storage_revision: row["storage_revision"]
        }
      end
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def archive_window(head, existing, line) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])
      row = archive_row(head.agent_id, head.session_id, "")
      internal!(row)
      expect_archive_storage(row, head[:expected_storage_revision])
      if row["archived_through"] != head.expected_through, do: Repo.rollback(:stale_archive)
      ceiling = min(min(row["archive_target_seq"] || 0, row["last_seq"] || 0), head.target || 0)
      scope = [head.agent_id, head.session_id]

      records =
        case existing do
          {:ok, landed} ->
            if List.last(landed).seq > ceiling, do: Repo.rollback(:stale_archive)
            archive_records(scope, head.expected_through, ceiling, length(landed), [])

          {:error, :not_found} ->
            archive_prefix(
              scope,
              head.expected_through,
              ceiling,
              line,
              [],
              0,
              @archive_batch_records
            )
        end

      last =
        case List.last(records) do
          nil -> head.expected_through
          record -> record["seq"]
        end

      %{
        agent_id: head.agent_id,
        session_id: head.session_id,
        expected_through: head.expected_through,
        candidate_through: last,
        record_count: length(records),
        expected_storage_revision: head[:expected_storage_revision],
        state:
          PGCodec.archive_window(
            head.agent_id,
            head.session_id,
            head.expected_through,
            last,
            records
          )
      }
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp archive_prefix(_scope, after_seq, ceiling, _line, pages, _bytes, left)
       when after_seq >= ceiling or left == 0,
       do: pages |> Enum.reverse() |> List.flatten()

  defp archive_prefix(scope, after_seq, ceiling, line, pages, bytes, left) do
    sizes =
      rows(
        "SELECT seq,octet_length(payload) AS bytes FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4 ORDER BY seq LIMIT $5",
        scope ++ [after_seq, ceiling, min(left, @page_size)]
      )

    if sizes == [], do: Repo.rollback(:source_gap)

    # This is a transfer budget, not the archive cut. Payload ETF and the
    # shaped archive ETF have different sizes. Only the native cut below
    # decides the archive boundary; allow the original oversized record.
    {selected, _} =
      Enum.reduce_while(sizes, {[], 0}, fn row, {selected, size} ->
        next = size + row["bytes"]

        if selected == [] or next <= line - bytes,
          do: {:cont, {[row | selected], next}},
          else: {:halt, {selected, size}}
      end)

    last = hd(selected)["seq"]

    page =
      rows(
        "SELECT seq,kind,payload FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4 ORDER BY seq",
        scope ++ [after_seq, last]
      )

    [agent, session] = scope
    plan = PGCodec.archive_window(agent, session, after_seq, last, page)

    {count, bytes} =
      case InternalSession.archive_cut(plan, line, bytes) do
        {:ok, count, total} -> {count, total}
        {:error, reason} -> Repo.rollback(reason)
      end

    pages = [Enum.take(page, count) | pages]

    if bytes >= line or List.last(page)["seq"] >= ceiling do
      pages |> Enum.reverse() |> List.flatten()
    else
      archive_prefix(scope, List.last(page)["seq"], ceiling, line, pages, bytes, left - count)
    end
  end

  defp archive_records(_scope, after_seq, ceiling, left, acc)
       when after_seq >= ceiling or left == 0,
       do: acc |> Enum.reverse() |> List.flatten()

  defp archive_records(scope, after_seq, ceiling, left, acc) do
    page =
      rows(
        "SELECT seq,kind,payload FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4 ORDER BY seq LIMIT $5",
        scope ++ [after_seq, ceiling, min(left, @page_size)]
      )

    case page do
      [] ->
        acc |> Enum.reverse() |> List.flatten()

      _ ->
        archive_records(scope, List.last(page)["seq"], ceiling, left - length(page), [page | acc])
    end
  end

  def prepare_archive(window, event) do
    entries = event["segments"]
    through = event["archived_through"]

    tiled =
      Enum.reduce_while(entries, window.expected_through, fn entry, previous ->
        case SalixStore.SealedSegments.parse_entry(entry) do
          [first, last, _, _] when first == previous + 1 -> {:cont, last}
          _ -> {:halt, :invalid}
        end
      end)

    if entries != [] and tiled == through and through <= window.candidate_through do
      {:ok,
       %Archive{
         agent_id: window.agent_id,
         session_id: window.session_id,
         expected_through: window.expected_through,
         candidate_through: window.candidate_through,
         through: through,
         expected_storage_revision: window[:expected_storage_revision],
         entries:
           Enum.map(entries, fn [first, last, messages, bytes] ->
             %{
               "first_seq" => first,
               "last_seq" => last,
               "message_count" => messages,
               "record_count" => last - first + 1,
               "uncompressed_bytes" => bytes,
               "object_key" =>
                 Keys.agent_internal_runtime_session_segment(
                   window.agent_id,
                   window.session_id,
                   first
                 ),
               "encoding" => "etf.zst",
               "source_session" => nil,
               "byte_offset" => nil,
               "byte_length" => nil
             }
           end)
       }}
    else
      {:error, :invalid_archive_publication}
    end
  end

  # The committed target grants this storage transfer. Publish one cut and
  # remove its PG bodies together, without writing a captured business view.
  def publish_archive(%Archive{} = archive) do
    started = SystemsClock.monotonic_time(:millisecond)

    case Repo.transaction(fn ->
           lock_archive_agent(archive.agent_id)
           row = archive_row(archive.agent_id, archive.session_id, "FOR UPDATE")
           internal!(row)

           cond do
             row["archived_through"] == archive.expected_through ->
               expect_archive_storage(row, archive.expected_storage_revision)

               if archive.through > (row["last_seq"] || 0) or
                    archive.through > (row["archive_target_seq"] || 0),
                  do: Repo.rollback(:stale_archive)

               insert_archives([archive.agent_id, archive.session_id], archive.entries)

               Repo.query!(
                 "DELETE FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4",
                 [archive.agent_id, archive.session_id, archive.expected_through, archive.through]
               )

               Repo.query!(
                 "UPDATE salix_sessions SET archived_through=$3,revision=revision+1,archive_target_seq=CASE WHEN archive_target_seq<=$3 THEN NULL ELSE archive_target_seq END WHERE agent_id=$1 AND session_id=$2",
                 [archive.agent_id, archive.session_id, archive.through]
               )

               {:published, row["revision"]}

             row["archived_through"] >= archive.through ->
               published =
                 rows(
                   "SELECT first_seq,last_seq,object_key,encoding,record_count,message_count,uncompressed_bytes,source_session,byte_offset,byte_length FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2 AND first_seq>=$3 AND first_seq<=$4 ORDER BY first_seq",
                   [
                     archive.agent_id,
                     archive.session_id,
                     archive.expected_through + 1,
                     archive.through
                   ]
                 )

               if published != archive.entries, do: Repo.rollback(:stale_archive)
               :published

             true ->
               Repo.rollback(:stale_archive)
           end
         end) do
      {:ok, {:published, previous_revision}} ->
        fields =
          SalixAgent.DeliveryTelemetry.identity(archive.agent_id, archive.session_id)
          |> Map.merge(%{
            cached_revision: previous_revision,
            current_revision: previous_revision + 1,
            archived_from: archive.expected_through,
            archived_through: archive.through
          })

        SalixAgent.DeliveryTelemetry.emit(
          :archive_published,
          :ok,
          SystemsClock.monotonic_time(:millisecond) - started,
          fields
        )

        {:ok, :archived}

      {:ok, :published} ->
        {:ok, :archived}

      error ->
        error
    end
  rescue
    error in Postgrex.Error -> {:error, {:rolled_back, error}}
    _error in DBConnection.ConnectionError -> {:error, :archive_indeterminate, archive}
  catch
    :exit, _reason -> {:error, :archive_indeterminate, archive}
  end

  def settle_archive(%Archive{} = archive), do: publish_archive(archive)

  defp expect_archive_storage(_row, nil), do: :ok

  defp expect_archive_storage(row, %{value: expected}) do
    if row["storage_revision"] != expected, do: Repo.rollback(:session_changed)
  end

  defp lock_archive_agent(agent_id) do
    case Repo.query!(
           "SELECT config_revision FROM salix_agents WHERE agent_id=$1 FOR SHARE",
           [agent_id]
         ).rows do
      [[revision]] when revision > 0 -> :ok
      _ -> Repo.rollback(:agent_not_found)
    end
  end

  def prepare_created_seed(%SalixStore.Agent.Owned{} = owned, state) do
    with {:ok, state} <-
           state
           |> InternalSession.stamp(agent_id: owned.agent_id)
           |> InternalSession.prepare_write() do
      pending = state |> InternalSession.start_revision(nil) |> revision() |> freeze(owned.epoch)
      {:ok, %CreatedSeed{owned: owned, pending: pending}}
    end
  end

  def seed_created(%CreatedSeed{} = seed) do
    case transaction(seed.pending, fn _key ->
           SalixStore.AgentPGStore.lock_creation!(seed.owned)
           ensure_birth(seed.pending.agent_id, seed.pending.session_id)
           row = session_row(seed.pending.agent_id, seed.pending.session_id, "FOR UPDATE")
           apply_locked(seed.pending, row)
         end) do
      {:error, :commit_indeterminate, _pending} -> {:error, :commit_indeterminate, seed}
      result -> result
    end
  end

  def settle_created(%CreatedSeed{} = seed), do: seed_created(seed)

  def delete_created_session!(agent_id, session_id) do
    scope = [agent_id, session_id]

    Repo.query!(
      "UPDATE salix_sessions SET context_revision = NULL WHERE agent_id = $1 AND session_id = $2",
      scope
    )

    for table <-
          ~w(salix_session_inputs salix_session_input_dedupe salix_session_sources salix_session_records salix_session_archives salix_session_contexts agent_session_history_states salix_sessions) do
      Repo.query!("DELETE FROM #{table} WHERE agent_id = $1 AND session_id = $2", scope)
    end

    :ok
  end

  def create(agent_id, session_id, epoch, attrs \\ %{}) do
    state = InternalSession.new(agent_id, session_id, attrs)
    cursor = InternalSession.start_revision(state, nil)
    cursor |> revision() |> freeze(epoch) |> execute()
  end

  def read(agent_id, session_id) do
    case Repo.transaction(fn ->
           Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
           row = session_row(agent_id, session_id, "")
           snapshot(row)
         end) do
      {:ok, snapshot} -> hydrate(snapshot)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def recent_messages(agent_id, session_id, limit, pick) do
    case Repo.transaction(fn ->
           Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
           row = session_row(agent_id, session_id, "")
           internal!(row)
           if is_nil(row["control_payload"]), do: Repo.rollback(:not_found)
           recent_window(row)
         end) do
      {:ok, {hot, spans, compacted}} ->
        picked = hot |> Enum.map(&PGCodec.message/1) |> Enum.flat_map(pick) |> Enum.take(limit)
        {:ok, recent_archived(spans, compacted, picked, limit, pick)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def input_committed?(agent_id, session_id, source_id) do
    case rows(
           """
           SELECT s.birth_kind, s.deleted_at, s.control_payload IS NOT NULL AS stored,
                  EXISTS(SELECT 1 FROM salix_session_input_dedupe d
                         WHERE d.agent_id=s.agent_id AND d.session_id=s.session_id
                           AND d.dedupe_key=$3) AS committed
           FROM salix_sessions s WHERE s.agent_id=$1 AND s.session_id=$2
           """,
           [agent_id, session_id, PGCodec.identity(source_id)]
         ) do
      [%{"birth_kind" => "retired"}] ->
        {:error, :session_read_only}

      [
        %{
          "birth_kind" => "internal",
          "deleted_at" => nil,
          "stored" => true,
          "committed" => committed
        }
      ] ->
        {:ok, committed}

      _ ->
        {:error, :not_found}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  # The session's visibility from its row alone, without reading its records.
  def hidden(agent_id, session_id) do
    case rows(
           "SELECT birth_kind, deleted_at, hidden, control_payload IS NOT NULL AS stored FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
           [agent_id, session_id]
         ) do
      [%{"birth_kind" => "retired"}] ->
        {:error, :session_read_only}

      [%{"birth_kind" => "internal", "deleted_at" => nil, "stored" => true} = row] ->
        {:ok, row["hidden"] == true}

      _ ->
        {:error, :not_found}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def birth(agent_id, session_id) do
    case rows(
           "SELECT birth_kind, deleted_at FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
           [agent_id, session_id]
         ) do
      [] -> {:ok, :new}
      [%{"birth_kind" => "retired"}] -> {:ok, :retired}
      [%{"deleted_at" => deleted}] when not is_nil(deleted) -> {:ok, :deleted}
      [_] -> {:ok, :internal}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def session_ids(agent_id, cursor, limit) do
    condition = if cursor, do: "AND session_id > $3", else: ""
    params = [agent_id, limit] ++ if(cursor, do: [cursor], else: [])

    {:ok,
     rows(
       "SELECT session_id FROM salix_sessions WHERE agent_id = $1 AND birth_kind = 'internal' AND deleted_at IS NULL AND control_payload IS NOT NULL #{condition} ORDER BY session_id LIMIT $2",
       params
     )
     |> Enum.map(& &1["session_id"])}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def repair_session_ids(agent_id, cursor \\ nil) do
    condition = if cursor, do: "AND session_id > $2", else: ""
    params = if cursor, do: [agent_id, cursor], else: [agent_id]

    result =
      rows(
        "SELECT session_id FROM salix_sessions WHERE agent_id = $1 " <>
          "AND birth_kind = 'internal' AND control_payload IS NOT NULL AND deleted_at IS NULL " <>
          "AND cardinality(work_reasons) > 0 #{condition} ORDER BY session_id LIMIT #{@page_size}",
        params
      )

    ids = Enum.map(result, & &1["session_id"])
    {:ok, ids, if(length(ids) == @page_size, do: List.last(ids))}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  def history_info(agent_id, session_id) do
    history_snapshot(fn ->
      row = history_session(agent_id, session_id)
      %{agent_id: agent_id, session_id: session_id, last_seq: row["last_seq"]}
    end)
  end

  # Pick the body location and copy the hot page in one MVCC snapshot. Cleanup
  # cannot turn a page selected as hot into a missing record after this read.
  def history_page(agent_id, session_id, after_seq, through) do
    snapshot =
      history_snapshot(fn ->
        row = history_session(agent_id, session_id)
        ceiling = min(through, row["last_seq"])
        first = after_seq + 1

        cond do
          first > ceiling ->
            {:hot, []}

          first <= row["archived_through"] ->
            case history_rows(
                   "SELECT * FROM salix_session_archives WHERE agent_id = $1 AND session_id = $2 AND first_seq <= $3 AND last_seq >= $3 ORDER BY first_seq DESC LIMIT 1",
                   [agent_id, session_id, first]
                 ) do
              [span] -> {:cold, span, ceiling}
              [] -> HistoryRepo.rollback({:archive_incomplete, %{missing_seq: first}})
            end

          true ->
            {:hot,
             history_rows(
               "SELECT seq, kind, payload FROM salix_session_records WHERE agent_id = $1 AND session_id = $2 AND seq > $3 AND seq <= $4 ORDER BY seq LIMIT 32",
               [agent_id, session_id, after_seq, ceiling]
             )}
        end
      end)

    case snapshot do
      {:ok, {:hot, rows}} ->
        {:ok, Enum.map(rows, &PGCodec.history_record/1)}

      {:ok, {:cold, span, ceiling}} ->
        with {:ok, records} <- SalixAgent.InternalSessionArchiveReader.read_descriptors([span]) do
          {:ok,
           records |> Enum.filter(&(&1.seq > after_seq and &1.seq <= ceiling)) |> Enum.take(32)}
        end

      error ->
        error
    end
  end

  defp history_session(agent_id, session_id) do
    case history_rows(
           "SELECT birth_kind, deleted_at, control_payload IS NOT NULL AS materialized, last_seq, archived_through FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
           [agent_id, session_id]
         ) do
      [%{"birth_kind" => "internal", "deleted_at" => nil, "materialized" => true} = row] -> row
      [%{"birth_kind" => "retired"}] -> HistoryRepo.rollback(:session_read_only)
      _ -> HistoryRepo.rollback(:not_found)
    end
  end

  defp history_snapshot(fun) do
    HistoryRepo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        HistoryRepo,
        "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
        [],
        log: false
      )

      fun.()
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp history_rows(sql, params) do
    %{columns: columns, rows: rows} =
      Ecto.Adapters.SQL.query!(HistoryRepo, sql, params, log: false)

    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  # This freezes an already admitted working revision. Input admission itself
  # runs under the Session lock in input/4 or commit_events/5.
  def freeze(%Revision{} = version, epoch, opts \\ []) do
    storage_revision = Keyword.get_lazy(opts, :storage_revision, &SessionStorageRevision.new/0)

    stamped = stamp(storage_revision, epoch, activity_revision(version))

    cursor =
      step(:write, fn -> InternalSession.write_revision(version.cursor, [stamped], nil) end)

    freeze_cursor(cursor, epoch, storage_revision, opts[:command])
  end

  # A freeze reaches the database nowhere, so its time is the kernel's. Each
  # call is timed apart while `fun` runs, by name, for the slow fence log.
  @doc false
  def time_freeze(fun) do
    Process.put(@freeze_steps, %{})

    try do
      {fun.(), Process.get(@freeze_steps)}
    after
      Process.delete(@freeze_steps)
    end
  end

  defp step(name, fun) do
    case Process.get(@freeze_steps) do
      nil ->
        fun.()

      %{} ->
        started = SystemsClock.monotonic_time()
        result = fun.()
        elapsed = SystemsClock.monotonic_time() - started
        steps = Process.get(@freeze_steps)
        Process.put(@freeze_steps, Map.update(steps, name, elapsed, &(&1 + elapsed)))
        result
    end
  end

  def execute(%Pending{} = pending),
    do: transaction(pending, fn _key -> apply_pending(pending) end)

  def settle(%Pending{} = pending), do: execute(pending)

  def settle_input(%Pending{} = pending), do: pending |> settle() |> complete_input()

  def freeze_command(command, epoch) do
    case prepare_input({command, {:fence}}, epoch) do
      {:prepared, pending} -> {:ok, pending}
      {:clean, _command} -> :clean
    end
  end

  def fence_command(command, epoch) do
    case freeze_command(command, epoch) do
      {:ok, pending} ->
        execute(pending)

      :clean ->
        base = command |> InternalSession.command_revision() |> revision()

        transaction(nil, fn _key ->
          lock_agent(InternalSession.agent_id(base.state), epoch)

          row =
            session_row(
              InternalSession.agent_id(base.state),
              InternalSession.session_id(base.state),
              "FOR UPDATE"
            )

          expect_revision(row, base.revision)
          {:clean, command, row["revision"]}
        end)
    end
  end

  def confirm_revision(%Revision{} = base, epoch) do
    transaction(nil, fn _key ->
      lock_agent(InternalSession.agent_id(base.state), epoch)

      row =
        session_row(
          InternalSession.agent_id(base.state),
          InternalSession.session_id(base.state),
          "FOR UPDATE"
        )

      expect_base(row, base)
      {:revision, base}
    end)
  end

  def commit_revision(%Revision{} = base, epoch, events, opts \\ []) when is_list(events) do
    agent_id = InternalSession.agent_id(base.state)
    session_id = InternalSession.session_id(base.state)

    with {:ok, result_facts} <- prepare_result_facts(base.state, events) do
      keys = InternalSession.input_identity_keys(base.state, events)

      transaction(nil, fn key ->
        lock_agent(agent_id, epoch)
        if is_nil(base.revision), do: ensure_birth(agent_id, session_id)
        row = session_row(agent_id, session_id, "FOR UPDATE")
        expect_revision(row, base.revision || 0)
        hits = durable_hits(agent_id, session_id, keys)
        base = with_hits(base, hits)

        case SalixAgent.InternalSession.State.validate_events(events) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        case InternalSession.validate_stored_results(base.state, events, result_facts) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        cursor = InternalSession.write_revision(base.cursor, events, opts[:hwm])
        pending = cursor |> revision() |> freeze(epoch)
        Process.put(key, pending)
        apply_locked(pending, row)
      end)
    end
  end

  # Volatile staging never acknowledges receipt. Identity-bearing writes use
  # the same expected revision and lock order as the eventual durable fence.
  def stage_revision(%Revision{} = base, epoch, events, opts \\ []) do
    stage(base, epoch, events, fn admitted, _hits ->
      admitted.cursor
      |> InternalSession.write_revision(events, opts[:hwm])
      |> revision()
    end)
  end

  def stage_command(command, epoch, events) do
    base = command |> InternalSession.command_revision() |> revision()

    stage(base, epoch, events, fn _admitted, hits ->
      {command, {:validate_write, _}} = InternalSession.command_step(command, :write_hits, hits)
      InternalSession.command_step(command, :write_result, :ok)
    end)
  end

  defp stage(base, epoch, events, apply) do
    with :ok <- SalixAgent.InternalSession.State.validate_events(events),
         {:ok, facts} <- prepare_result_facts(base.state, events) do
      keys = InternalSession.input_identity_keys(base.state, events)

      if keys == [] do
        with :ok <- InternalSession.validate_stored_results(base.state, events, facts),
             do: {:ok, apply.(base, [])}
      else
        transaction(nil, fn _key ->
          agent_id = InternalSession.agent_id(base.state)
          session_id = InternalSession.session_id(base.state)
          lock_agent(agent_id, epoch)
          if is_nil(base.revision), do: ensure_birth(agent_id, session_id)
          row = session_row(agent_id, session_id, "FOR UPDATE")
          expect_base(row, base)
          hits = durable_hits(agent_id, session_id, keys)
          admitted = with_hits(base, hits)

          case InternalSession.validate_stored_results(admitted.state, events, facts) do
            :ok -> Repo.rollback({:staged_write, apply.(admitted, hits)})
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
  end

  def prepare_result_facts(state, events) do
    state
    |> InternalSession.stored_result_requests(events)
    |> Enum.reduce_while({:ok, []}, fn {ref, seq}, {:ok, facts} ->
      case SalixAgent.InternalSessionStore.fetch_archived_record(
             InternalSession.agent_id(state),
             InternalSession.session_id(state),
             state,
             seq
           ) do
        {:ok, record} -> {:cont, {:ok, [{ref, seq, record} | facts]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def input_revision(%Revision{} = version, epoch, entry) when is_map(entry) do
    input_version(
      InternalSession.agent_id(version.state),
      InternalSession.session_id(version.state),
      epoch,
      entry,
      version,
      nil
    )
  end

  def stage_input_revision(%Revision{} = version, epoch, entry) when is_map(entry) do
    input_version(
      InternalSession.agent_id(version.state),
      InternalSession.session_id(version.state),
      epoch,
      entry,
      version,
      :stage_conversation
    )
  end

  defp input_version(agent_id, session_id, epoch, entry, resident, mode) do
    entry = SalixAgent.Utf8.scrub_session_input(entry)

    transaction(nil, fn key ->
      lock_agent(agent_id, epoch)
      ensure_birth(agent_id, session_id)
      row = session_row(agent_id, session_id, "FOR UPDATE")
      internal!(row)
      born = is_nil(row["control_payload"])

      if resident, do: expect_revision(row, resident.revision || 0)

      base = resident

      command =
        mode ||
          if is_map(entry[:conversation_source] || entry["conversation_source"]),
            do: :conversation_input,
            else: :input

      case prepare_input(
             InternalSession.start_command(base.cursor, :pg_input, {entry, born, command}, nil),
             epoch
           ) do
        {:prepared, pending} ->
          Process.put(key, pending)
          apply_locked(pending, row)

        {:clean, command} ->
          {:clean, command, row["revision"]}

        {:error, reason} ->
          Repo.rollback(reason)

        {:staged, command, result} ->
          Repo.rollback(
            {:input_staged, result, command |> InternalSession.command_revision() |> revision()}
          )

        {:effect, command, request} ->
          Repo.rollback(
            {:input_effect,
             %InputEffect{
               agent_id: agent_id,
               session_id: session_id,
               expected_revision: row["revision"],
               runtime_epoch: epoch,
               command: command,
               request: request
             }}
          )
      end
    end)
    |> complete_input()
  end

  def continue_input(%InputEffect{} = effect, result) do
    transaction(nil, fn key ->
      lock_agent(effect.agent_id, effect.runtime_epoch)
      if effect.expected_revision == 0, do: ensure_birth(effect.agent_id, effect.session_id)
      row = session_row(effect.agent_id, effect.session_id, "FOR UPDATE")
      expect_revision(row, effect.expected_revision)

      step =
        InternalSession.command_step(
          effect.command,
          :effect_result,
          InternalSession.Command.external_error(result)
        )

      case prepare_input(step, effect.runtime_epoch) do
        {:prepared, pending} ->
          Process.put(key, pending)
          apply_locked(pending, row)

        {:clean, command} ->
          {:clean, command, row["revision"]}

        {:error, reason} ->
          Repo.rollback(reason)

        {:staged, command, result} ->
          Repo.rollback(
            {:input_staged, result, command |> InternalSession.command_revision() |> revision()}
          )
      end
    end)
    |> complete_input()
  end

  defp prepare_input({command, {:validate_write, events}}, epoch) do
    result = SalixAgent.InternalSession.State.validate_events(events)
    command |> InternalSession.command_step(:write_result, result) |> prepare_input(epoch)
  end

  defp prepare_input({command, {:effect, {:input_dedupe, keys}}}, epoch) do
    state = command |> InternalSession.command_revision() |> revision()

    hits =
      durable_hits(
        InternalSession.agent_id(state.state),
        InternalSession.session_id(state.state),
        keys
      )

    command |> InternalSession.command_step(:identity_result, hits) |> prepare_input(epoch)
  end

  defp prepare_input({command, {:fence}}, epoch) do
    cursor = InternalSession.command_revision(command)

    if step(:pending, fn -> InternalSession.revision_pending?(cursor) end) do
      storage_revision = SessionStorageRevision.new()
      activity = cursor |> viewed_revision() |> activity_revision()

      {prepared, {:prepared}} =
        step(:prepare, fn ->
          InternalSession.command_step(
            command,
            :pg_prepare,
            {storage_revision, epoch, to_string(SystemsRuntime.Proc.node()), activity}
          )
        end)

      cursor = InternalSession.command_revision(prepared)
      {:prepared, freeze_cursor(cursor, epoch, storage_revision, prepared)}
    else
      {:clean, command}
    end
  end

  defp prepare_input({_command, {:return, {:error, reason}, _}}, _epoch), do: {:error, reason}

  defp prepare_input({command, {:return, {:ok, :staged, _events} = result, _}}, _epoch),
    do: {:staged, command, result}

  defp prepare_input({command, {:effect, {:workspace, _, _, _, _} = request}}, _epoch),
    do: {:effect, command, request}

  defp freeze_cursor(cursor, epoch, storage_revision, command) do
    candidate = viewed_revision(cursor)
    baseline = baseline_view(cursor)

    {:ok, delta} = step(:delta, fn -> InternalSession.revision_delta(cursor) end)
    refs = step(:reads, fn -> InternalSession.get(candidate.state, :archive_refs) end)

    delta =
      if delta["kind"] == "create" and is_map(refs),
        do: Map.put(delta, "archives_add", archive_entries(refs)),
        else: delta

    reasons = step(:reads, fn -> InternalSession.work_reasons(candidate.state) end)

    delta =
      delta
      |> Map.put("work_reasons", reasons)
      |> Map.put("next_run_at_ms", step(:reads, fn -> next_run(candidate.state, reasons) end))

    delta =
      if delta["records"] != [] or Map.has_key?(delta["columns"], "compacted_seq") do
        last = step(:reads, fn -> InternalSession.get(candidate.state, :last_seq) || 0 end)
        through = step(:reads, fn -> InternalSession.archived_through(candidate.state) || 0 end)
        if last > through, do: Map.put(delta, "archive_target_seq", last), else: delta
      else
        delta
      end

    %Pending{
      agent_id: InternalSession.agent_id(candidate.state),
      session_id: InternalSession.session_id(candidate.state),
      expected_revision: candidate.revision || 0,
      runtime_epoch: epoch,
      storage_revision: storage_revision,
      delta: delta,
      candidate: candidate,
      command: command,
      base_storage_revision:
        step(:reads, fn -> InternalSession.get(baseline, :storage_revision) end)
    }
  end

  defp viewed_revision(cursor), do: step(:view, fn -> revision(cursor) end)

  defp baseline_view(cursor) do
    step(:baseline, fn ->
      {baseline, _, _} =
        cursor |> InternalSession.revision_baseline() |> InternalSession.revision_view()

      baseline
    end)
  end

  defp next_run(state, reasons) do
    if SessionWorkRecovery.immediate_recovery_reasons?(reasons) do
      SystemsClock.system_time(:millisecond)
    else
      SessionWorkRecovery.recover_after_ms(reasons, InternalSession.recovery_wait(state))
    end
  end

  defp transaction(initial_pending, fun) do
    key = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    if initial_pending, do: Process.put(key, initial_pending)

    try do
      case Repo.transaction(fn -> fun.(key) end) do
        {:ok, {:committed, pending, revision}} ->
          SalixStore.SessionWorkNotifications.publish(
            pending.agent_id,
            pending.session_id,
            revision
          )

          finish(pending, revision)

        # The write landed over an archive publication, which moved
        # archived_through. The owner continues from the stored view.
        {:ok, {:rebased, pending, revision}} ->
          SalixStore.SessionWorkNotifications.publish(
            pending.agent_id,
            pending.session_id,
            revision
          )

          read(pending.agent_id, pending.session_id)

        {:ok, {:clean, command, revision}} ->
          finish_command(command, revision)

        {:ok, {:revision, version}} ->
          {:ok, version}

        {:ok, {:cleaned}} ->
          :ok

        {:error, {:staged_write, value}} ->
          {:ok, value}

        {:error, {:input_effect, effect}} ->
          {:effect_required, effect}

        {:error, {:input_staged, result, version}} ->
          {result, version}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error in Postgrex.Error -> {:error, {:rolled_back, error}}
      error in DBConnection.ConnectionError -> indeterminate(Process.get(key), error)
    catch
      :exit, reason -> indeterminate(Process.get(key), reason)
    after
      Process.delete(key)
    end
  end

  defp indeterminate(nil, reason), do: {:error, {:unavailable, reason}}
  defp indeterminate(pending, _reason), do: {:error, :commit_indeterminate, pending}

  defp apply_pending(pending) do
    lock_agent(pending.agent_id, pending.runtime_epoch)
    if pending.expected_revision == 0, do: ensure_birth(pending.agent_id, pending.session_id)
    row = session_row(pending.agent_id, pending.session_id, "FOR UPDATE")

    if archive_only_advance?(pending, row) do
      next = row["revision"] + 1
      write_delta(pending, row, next)
      {:rebased, pending, next}
    else
      apply_locked(pending, row)
    end
  end

  # Archive publication advances the SQL revision and moves bodies of committed
  # records to the archive, and changes nothing else. A frozen owner write whose
  # base is the stored business state (same storage revision) and that adds
  # only records after the archived range still applies as written; refusing
  # it as stale dropped the owner's model response at every publication.
  defp archive_only_advance?(%Pending{command: nil} = pending, row) do
    through = row["archived_through"] || 0

    internal!(row)

    pending.expected_revision > 0 and row["revision"] > pending.expected_revision and
      not is_nil(pending.base_storage_revision) and
      row["storage_revision"] == pending.base_storage_revision and
      pending.delta["kind"] != "create" and
      Enum.all?(pending.delta["records"], &(&1["seq"] > through))
  end

  defp archive_only_advance?(_pending, _row), do: false

  defp apply_locked(pending, row) do
    internal!(row)

    cond do
      row["storage_revision"] == pending.storage_revision ->
        # Archive publication can advance the SQL revision without changing this
        # business storage identity. Confirm the frozen candidate at its own
        # revision; a later write must reload the newer archive projection.
        {:committed, pending, pending.expected_revision + 1}

      row["revision"] != pending.expected_revision ->
        Repo.rollback({:stale_revision, row["revision"]})

      true ->
        next = row["revision"] + 1
        write_delta(pending, row, next)
        {:committed, pending, next}
    end
  end

  # tla/salix/RpcDeliver.tla PgStageCommit abstracts this holder check.
  # tla/salix/SessionEpochFence.tla maps the captured epoch and Session revision
  # to the stale-writer fence; this ancestor lock also serializes owner changes.
  # Agent SHARE remains held through the Session FOR UPDATE and commit;
  # the SQL epoch check is finer than the model's holder identity.
  defp lock_agent(agent_id, epoch) do
    case Repo.query!(
           "SELECT owner_epoch, config_revision FROM salix_agents WHERE agent_id = $1 FOR SHARE",
           [
             agent_id
           ]
         ).rows do
      [[^epoch, config_revision]] when config_revision > 0 -> :ok
      [[_current, 0]] -> Repo.rollback(:agent_not_found)
      [[current, _config_revision]] -> Repo.rollback({:fenced, current})
      [] -> Repo.rollback(:agent_not_found)
    end
  end

  defp ensure_birth(agent_id, session_id) do
    Repo.query!(
      """
      INSERT INTO salix_sessions (agent_id, session_id, birth_kind, revision)
      VALUES ($1, $2, 'internal', 0) ON CONFLICT (agent_id, session_id) DO NOTHING
      """,
      [agent_id, session_id]
    )
  end

  defp internal!(%{"birth_kind" => "internal", "deleted_at" => nil}), do: :ok
  defp internal!(%{"birth_kind" => "retired"}), do: Repo.rollback(:session_read_only)
  defp internal!(_row), do: Repo.rollback(:not_found)

  # A working revision stays usable over an archive publication made since it
  # was read: the row keeps the base's storage revision, and the frozen write
  # that follows lands over the publication (archive_only_advance?/2).
  defp expect_base(row, %Revision{revision: expected} = base) when is_integer(expected) do
    internal!(row)

    storage = InternalSession.get(base.state, :storage_revision)

    unless row["revision"] == expected or
             (row["revision"] > expected and not is_nil(storage) and
                row["storage_revision"] == storage),
           do: Repo.rollback({:stale_revision, row["revision"]})
  end

  defp expect_base(row, base), do: expect_revision(row, base.revision || 0)

  defp expect_revision(row, expected) do
    internal!(row)
    if row["revision"] != expected, do: Repo.rollback({:stale_revision, row["revision"]})
  end

  defp session_row(agent_id, session_id, lock) do
    case rows(
           "SELECT #{Enum.join(@session_columns, ", ")} FROM salix_sessions WHERE agent_id = $1 AND session_id = $2 #{lock}",
           [agent_id, session_id]
         ) do
      [row] -> row
      [] -> Repo.rollback(:not_found)
    end
  end

  defp snapshot(row) do
    internal!(row)
    if is_nil(row["control_payload"]), do: Repo.rollback(:not_found)
    scope = [row["agent_id"], row["session_id"]]

    context =
      case rows(
             "SELECT payload FROM salix_session_contexts WHERE agent_id = $1 AND session_id = $2 AND context_revision = $3",
             scope ++ [row["context_revision"]]
           ) do
        [%{"payload" => payload}] -> payload
        [] -> Repo.rollback(:session_context_missing)
      end

    inputs = page_all("salix_session_inputs", "queue_id", scope)
    sources = page_all("salix_session_sources", "participant_id", scope)
    records = page_all("salix_session_records", "seq", scope, row["archived_through"] || 0)
    archives = page_all("salix_session_archives", "first_seq", scope)

    {row, context, inputs, sources, records, archives}
  end

  defp recent_window(row) do
    scope = [row["agent_id"], row["session_id"]]
    compacted = row["compacted_seq"] || 0
    archived = row["archived_through"] || 0

    hot =
      rows(
        "SELECT seq, kind, payload FROM salix_session_records WHERE agent_id = $1 AND session_id = $2 AND seq > $3 AND kind = 'message' ORDER BY seq DESC LIMIT #{@recent_hot_records}",
        scope ++ [max(compacted, archived)]
      )

    spans =
      rows(
        "SELECT * FROM salix_session_archives WHERE agent_id = $1 AND session_id = $2 AND last_seq > $3 AND first_seq <= $4 ORDER BY first_seq DESC LIMIT #{@recent_archive_spans}",
        scope ++ [compacted, archived]
      )

    {hot, spans, compacted}
  end

  defp recent_archived(spans, compacted, picked, limit, pick) do
    Enum.reduce_while(spans, picked, fn span, picked ->
      if length(picked) >= limit do
        {:halt, picked}
      else
        case SalixAgent.InternalSessionArchiveReader.read_descriptors([span]) do
          {:ok, records} ->
            older =
              records
              |> Enum.filter(&(&1.kind == "message" and &1.seq > compacted))
              |> Enum.sort_by(& &1.seq, :desc)
              |> Enum.map(&PGCodec.archived_message/1)
              |> Enum.flat_map(pick)

            {:cont, Enum.take(picked ++ older, limit)}

          {:error, reason} ->
            Logger.warning(
              "session recent messages stopped at an archive read reason=#{inspect(reason)}"
            )

            {:halt, picked}
        end
      end
    end)
  end

  defp archive_row(agent_id, session_id, lock) do
    case rows(
           "SELECT #{@archive_columns} FROM salix_sessions s WHERE s.agent_id=$1 AND s.session_id=$2 #{lock}",
           [agent_id, session_id]
         ) do
      [row] -> row
      [] -> Repo.rollback(:not_found)
    end
  end

  defp hydrate({row, context, inputs, sources, records, archives}) do
    with {:ok, cold} <- PGCodec.hydrate_records(row, records, archives),
         {:ok, state} <- PGCodec.state(row, context, inputs, sources, records, archives, cold) do
      # The revision cursor holds the state; the restored handle is not
      # returned, so release it rather than leave it for a collection.
      cursor = InternalSession.start_revision(state, row["revision"])
      InternalSession.release(state)
      {:ok, revision(cursor)}
    end
  end

  defp page_all(table, key, scope, cursor \\ nil, acc \\ []) do
    condition = if is_nil(cursor), do: "", else: "AND #{key} > $3"
    params = if is_nil(cursor), do: scope, else: scope ++ [cursor]

    page =
      rows(
        "SELECT * FROM #{table} WHERE agent_id = $1 AND session_id = $2 #{condition} ORDER BY #{key} LIMIT #{@page_size}",
        params
      )

    if length(page) == @page_size do
      page_all(table, key, scope, List.last(page)[key], [page | acc])
    else
      [page | acc] |> Enum.reverse() |> List.flatten()
    end
  end

  # One-time removal of bodies left by the former two-stage publisher.
  # New publications remove their own range in publish_archive/1.
  def cleanup_archived(agent_id, session_id) do
    Repo.transaction(fn ->
      lock_archive_agent(agent_id)
      row = archive_row(agent_id, session_id, "FOR UPDATE")
      internal!(row)
      through = row["archived_through"] || 0

      deleted =
        Repo.query!(
          "WITH batch AS (SELECT seq FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq<=$3 ORDER BY seq LIMIT #{@page_size}) DELETE FROM salix_session_records r USING batch b WHERE r.agent_id=$1 AND r.session_id=$2 AND r.seq=b.seq",
          [agent_id, session_id, through]
        ).num_rows

      remaining =
        Repo.query!(
          "SELECT 1 FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq<=$3 LIMIT 1",
          [agent_id, session_id, through]
        ).rows != []

      if not remaining and is_integer(row["archive_target_seq"]) and
           row["archive_target_seq"] <= through do
        Repo.query!(
          "UPDATE salix_sessions SET archive_target_seq=NULL WHERE agent_id=$1 AND session_id=$2",
          [agent_id, session_id]
        )
      end

      %{deleted: deleted, remaining: remaining}
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp insert_archives(scope, entries, opts \\ []) do
    columns =
      ~w(agent_id session_id first_seq last_seq object_key encoding record_count message_count uncompressed_bytes source_session byte_offset byte_length)

    rows =
      for entry <- entries do
        scope ++ Enum.map(Enum.drop(columns, 2), &entry[&1])
      end

    SalixStore.PGAuthorityImport.insert_many!("salix_session_archives", columns, rows, opts)
  end

  defp durable_hits(_agent_id, _session_id, []), do: []

  defp durable_hits(agent_id, session_id, keys) do
    keys
    |> Enum.uniq()
    |> Enum.chunk_every(@page_size)
    |> Enum.flat_map(fn page ->
      rows(
        "SELECT dedupe_key FROM salix_session_input_dedupe WHERE agent_id = $1 AND session_id = $2 AND dedupe_key = ANY($3::bytea[])",
        [agent_id, session_id, Enum.map(page, &PGCodec.identity/1)]
      )
      |> Enum.map(&PGCodec.decode(&1["dedupe_key"]))
    end)
  end

  defp with_hits(version, hits) do
    version.cursor |> InternalSession.add_input_hits(hits) |> revision()
  end

  defp write_delta(pending, previous, revision, opts \\ []) do
    scope = [pending.agent_id, pending.session_id]
    delta = pending.delta

    if delta["kind"] != "create" and
         (delta["archives_add"] != [] or Map.has_key?(delta["columns"], "archived_through")),
       do: Repo.rollback(:archive_publication_required)

    records =
      for record <- Enum.sort_by(delta["records"], & &1["seq"]) do
        scope ++
          [
            record["seq"],
            record["kind"],
            PGCodec.identity(record["record_id"]),
            PGCodec.encode(record["payload"])
          ]
      end

    SalixStore.PGAuthorityImport.insert_many!(
      "salix_session_records",
      ~w(agent_id session_id seq kind record_id payload),
      records,
      opts
    )

    inputs =
      for item <- Enum.sort_by(delta["inputs_put"], & &1["queue_id"]) do
        {id, kind, dedupe, payload} = PGCodec.input(item)
        scope ++ [id, kind, dedupe, payload, revision]
      end

    SalixStore.PGAuthorityImport.insert_many!(
      "salix_session_inputs",
      ~w(agent_id session_id queue_id kind dedupe_key payload accepted_revision),
      inputs,
      Keyword.put(opts, :conflict, {:update, ~w(agent_id session_id queue_id), ~w(payload)})
    )

    dedupe =
      for {key, queue_id} <-
            Enum.sort_by(delta["dedupe_add"], fn {key, _} -> PGCodec.identity(key) end) do
        scope ++ [PGCodec.identity(key), queue_id, revision]
      end

    SalixStore.PGAuthorityImport.insert_many!(
      "salix_session_input_dedupe",
      ~w(agent_id session_id dedupe_key queue_id accepted_revision),
      dedupe,
      Keyword.put(opts, :conflict, {:nothing, ~w(agent_id session_id dedupe_key)})
    )

    if delta["inputs_remove"] != [] do
      Repo.query!(
        "DELETE FROM salix_session_inputs WHERE agent_id = $1 AND session_id = $2 AND queue_id = ANY($3::bigint[])",
        scope ++ [delta["inputs_remove"]]
      )
    end

    sources =
      for {participant_id, source} <- Enum.sort(delta["sources_put"]) do
        scope ++
          [
            participant_id,
            source["conversation_id"],
            source["generation"],
            source["start_seq"] || 0,
            source["seq"],
            PGCodec.identity(source["last_rejection"])
          ]
      end

    SalixStore.PGAuthorityImport.insert_many!(
      "salix_session_sources",
      ~w(agent_id session_id participant_id conversation_id generation start_seq seq last_rejection),
      sources,
      Keyword.put(
        opts,
        :conflict,
        {:update, ~w(agent_id session_id participant_id),
         ~w(conversation_id generation start_seq seq last_rejection)}
      )
    )

    insert_archives(
      scope,
      Enum.map(delta["archives_add"], fn [first, _, _, _] ->
        Map.fetch!(archive_refs(pending), first)
      end),
      opts
    )

    context_revision =
      if delta["context"] do
        next = (previous["context_revision"] || 0) + 1

        Repo.query!(
          "INSERT INTO salix_session_contexts (agent_id, session_id, context_revision, payload) VALUES ($1, $2, $3, $4)",
          scope ++ [next, PGCodec.encode(delta["context"])]
        )

        next
      else
        previous["context_revision"]
      end

    patch =
      delta["columns"]
      |> Map.update("created_at", nil, &PGCodec.timestamp/1)
      |> Map.update("last_activity_at", nil, &PGCodec.timestamp/1)

    patch =
      Enum.reject(patch, fn {key, _} ->
        key in ~w(created_at last_activity_at) and not Map.has_key?(delta["columns"], key)
      end)
      |> Map.new()

    control =
      if previous["control_payload"], do: PGCodec.decode(previous["control_payload"]), else: %{}

    patch =
      if delta["control_put"] == %{},
        do: patch,
        else:
          Map.put(
            patch,
            "control_payload",
            PGCodec.encode(Map.merge(control, delta["control_put"]))
          )

    patch =
      Map.merge(patch, %{
        "revision" => revision,
        "storage_revision" => pending.storage_revision,
        "runtime_epoch" => pending.runtime_epoch,
        "context_revision" => context_revision,
        "work_reasons" => delta["work_reasons"],
        "next_run_at" => PGCodec.timestamp_ms(delta["next_run_at_ms"]),
        "dispatch_after" => nil
      })

    patch = Map.merge(patch, Map.take(delta, ["archive_target_seq"]))

    ordered = Enum.sort(patch)

    assignments =
      ordered
      |> Enum.with_index(3)
      |> Enum.map_join(", ", fn {{key, _}, index} -> "#{key} = $#{index}" end)

    Repo.query!(
      "UPDATE salix_sessions SET #{assignments} WHERE agent_id = $1 AND session_id = $2",
      scope ++ Enum.map(ordered, &elem(&1, 1))
    )

    last_seq = delta["columns"]["last_seq"] || previous["last_seq"] || 0

    if last_seq > 0 and (delta["kind"] == "create" or delta["records"] != []) do
      Repo.query!(
        """
        INSERT INTO agent_session_history_states (agent_id, session_id, target_seq)
        VALUES ($1, $2, $3) ON CONFLICT (agent_id, session_id)
        DO UPDATE SET target_seq = GREATEST(agent_session_history_states.target_seq, EXCLUDED.target_seq)
        """,
        scope ++ [last_seq]
      )
    end
  end

  defp archive_refs(%Import{archive_refs: refs}), do: refs

  defp archive_refs(pending) do
    InternalSession.get(pending.candidate.state, :archive_refs) || %{}
  end

  defp archive_entries(refs) do
    refs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_first, row} ->
      Enum.map(~w(first_seq last_seq message_count uncompressed_bytes), &Map.fetch!(row, &1))
    end)
  end

  defp finish(%Pending{command: nil} = pending, version) do
    {:ok,
     pending.candidate.cursor
     |> InternalSession.commit_revision_delta({version, archive_refs(pending)})
     |> revision()}
  end

  defp finish(%Pending{command: command} = pending, version),
    do: finish_command(command, version, archive_refs(pending))

  defp finish_command(command, version, refs \\ nil) do
    refs =
      refs ||
        command
        |> InternalSession.command_revision()
        |> revision()
        |> Map.fetch!(:state)
        |> InternalSession.get(:archive_refs) || %{}

    {command, {:committed}} =
      InternalSession.command_step(command, :pg_committed, {version, refs})

    {:ok, command}
  end

  defp complete_input({:ok, {:verified_kernel, 1, :command_driver, _} = command}),
    do: command |> InternalSession.command_step(:next, nil) |> finish_input()

  defp complete_input(result), do: result

  defp finish_input({command, {:effect, {:notify, "input_accepted", events}}}) do
    state = command |> InternalSession.command_revision() |> revision()

    SalixAgent.RouterRequestMonitor.enqueued(
      InternalSession.agent_id(state.state),
      InternalSession.session_id(state.state),
      events
    )

    command |> InternalSession.command_step(:effect_result, :ok) |> finish_input()
  end

  defp finish_input({command, {:return, result, _checkpoint}}),
    do: {result, command |> InternalSession.command_revision() |> revision()}

  defp revision(cursor) do
    {state, etag, pending?} = InternalSession.revision_view(cursor)
    %Revision{cursor: cursor, state: state, revision: etag, pending: if(pending?, do: cursor)}
  end

  defp activity_revision(version) do
    baseline = baseline_view(version.cursor)

    step(:activity, fn ->
      InternalSession.query(
        baseline,
        :activity_revision,
        {InternalSession.monitored_activity_signature(version.state),
         SessionStorageRevision.new()}
      )
    end)
  end

  defp stamp(storage_revision, epoch, activity),
    do: %{
      "type" => "session_stamp",
      "storage_revision" => storage_revision,
      "activity_revision" => activity,
      "runtime_epoch" => epoch,
      "runtime_node" => to_string(SystemsRuntime.Proc.node())
    }

  defp rows(sql, params) do
    %{columns: columns, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
