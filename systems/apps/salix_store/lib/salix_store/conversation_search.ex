defmodule SalixStore.ConversationSearch do
  @moduledoc """
  Durable PostgreSQL Task-search jobs and projections.

  Source transactions record jobs with canonical Conversation changes. The
  existing release barrier opens a bounded PG backfill; readers remain closed
  until its scan and jobs finish. Job claims and source versions fence stale
  projection writes.
  """

  alias SalixStore.{Repo, SearchDocumentEnvelope}

  @marker_name "conversation_search_projection_v1"
  @max_limit 50
  @statement_timeout_ms 250
  @database_timeout_ms 500
  @default_gc_retention_hours 168
  @default_gc_batch_size 100
  @max_gc_batch_size 1_000
  @gc_statement_timeout_ms 2_000
  @gc_database_timeout_ms 5_000

  @type claim :: %{
          id: pos_integer(),
          writer_generation: String.t(),
          agent_group_id: String.t(),
          conversation_id: String.t(),
          operation: :rebuild | :message | :delete,
          source_id: String.t(),
          source_seq: pos_integer() | nil,
          generation: pos_integer(),
          attempt_count: pos_integer(),
          claim_token: String.t()
        }

  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def search(group_id, query, opts \\ [])

  def search(group_id, query, opts)
      when is_binary(group_id) and is_binary(query) and is_list(opts) do
    query = String.trim(query)
    limit = Keyword.get(opts, :limit, 20)
    conversation_id = Keyword.get(opts, :conversation_id)

    case validated_query(group_id, query, conversation_id, limit, opts) do
      {:ok, query_envelope} ->
        pattern = "%" <> escape_like(query_envelope.folded) <> "%"

        case run_projection_query(search_sql(), [
               group_id,
               pattern,
               conversation_id,
               limit,
               limit * SearchDocumentEnvelope.message_slots(),
               query_envelope.short_grams
             ]) do
          {:ok, rows} -> {:ok, Enum.flat_map(rows, &project_hit(&1, query_envelope))}
          {:error, _reason} -> {:error, :unavailable}
        end

      :error ->
        {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def search(_group_id, _query, _opts), do: {:error, :invalid}

  @doc """
  Every indexed Message of one Task whose text matches `query`, oldest first:
  `%{"message_id" => id, "message_seq" => seq}`. The projection keeps a Task's
  latest `SearchDocumentEnvelope.message_slots/0` Messages, which bounds the
  answer.
  """
  @spec message_matches(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def message_matches(group_id, conversation_id, query)
      when is_binary(group_id) and group_id != "" and is_binary(conversation_id) and
             conversation_id != "" and is_binary(query) do
    case SearchDocumentEnvelope.query(String.trim(query)) do
      {:ok, query_envelope} ->
        case run_projection_query(message_matches_sql(), [
               group_id,
               "%" <> escape_like(query_envelope.folded) <> "%",
               conversation_id,
               SearchDocumentEnvelope.message_slots(),
               query_envelope.short_grams
             ]) do
          {:ok, rows} -> {:ok, Enum.flat_map(rows, &project_message_match(&1, query_envelope))}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, _reason} ->
        {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def message_matches(_group_id, _conversation_id, _query), do: {:error, :invalid}

  @doc "Positive mail associations only; an empty result does not establish Task absence."
  def mail_tasks(group_id, account_id, thread_ids)
      when is_binary(group_id) and is_binary(account_id) and is_list(thread_ids) and
             length(thread_ids) <= 40 do
    with true <- byte_size(group_id) in 1..256 and byte_size(account_id) in 1..256,
         true <- Enum.all?(thread_ids, &(is_binary(&1) and byte_size(&1) in 1..256)),
         {:ok, generation} <- writer_generation(),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT conversation_id, mail_thread_id
             FROM conversation_search_states
             WHERE writer_generation = $1 AND agent_group_id = $2
               AND mail_account_id = $3 AND mail_thread_id = ANY($4::text[])
               AND EXISTS (SELECT 1 FROM salix_cutover_markers WHERE name = $5
                           AND evidence->>'writer_generation' = $1)
             ORDER BY conversation_id LIMIT 41
             """,
             [generation, group_id, account_id, thread_ids, @marker_name],
             timeout: @database_timeout_ms
           ),
         true <- length(rows) <= 40 do
      {:ok, Enum.map(rows, fn [id, thread] -> %{conversation_id: id, thread_id: thread} end)}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def mail_tasks(_, _, _), do: {:error, :invalid}

  @spec ready?() :: boolean()
  def ready? do
    with {:ok, generation} <- writer_generation(),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM salix_cutover_markers " <>
               "WHERE name = $1 AND evidence->>'writer_generation' = $2",
             [@marker_name, generation]
           ) do
      true
    else
      _other -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  @spec writer_generation() :: {:ok, String.t()} | {:error, :unavailable}
  def writer_generation do
    case SystemsRuntime.get_env(:salix_store, :conversation_search_writer_generation) do
      generation when is_binary(generation) ->
        case String.trim(generation) do
          "" -> {:error, :unavailable}
          value -> {:ok, value}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  @doc "Whether this deployment has opted into the Task-search lifecycle."
  @spec configured?() :: boolean()
  def configured?,
    do: not is_nil(SystemsRuntime.get_env(:salix_store, :conversation_search_writer_generation))

  @spec pending_job_count() :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def pending_job_count do
    with {:ok, generation} <- writer_generation(),
         {:ok, %{rows: [[count]]}} <-
           Repo.query(
             "SELECT count(*) FROM conversation_search_jobs WHERE writer_generation = $1",
             [generation]
           ) do
      {:ok, count}
    else
      _other -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec begin_backfill(String.t()) :: :ok | {:error, :invalid | :unavailable}
  def begin_backfill(generation) when is_binary(generation) and generation != "" do
    with {:ok, ^generation} <- writer_generation() do
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE conversation_search_backfill_runs IN SHARE ROW EXCLUSIVE MODE")

        %{rows: rows} =
          Repo.query!(
            """
            INSERT INTO conversation_search_backfill_runs (writer_generation, inserted_at, updated_at)
            SELECT $1,statement_timestamp(),statement_timestamp()
            WHERE NOT EXISTS (SELECT 1 FROM conversation_search_gc_runs WHERE writer_generation=$1)
            ON CONFLICT (writer_generation) DO UPDATE SET updated_at=statement_timestamp()
              WHERE conversation_search_backfill_runs.sealed_at IS NULL
                AND conversation_search_backfill_runs.writer_barrier_at IS NULL
                AND conversation_search_backfill_runs.retired_at IS NULL
            RETURNING 1
            """,
            [generation]
          )

        if rows != [[1]], do: Repo.rollback(:invalid)

        Repo.query!(
          "UPDATE conversation_search_backfill_runs SET retired_at=statement_timestamp(),updated_at=statement_timestamp() WHERE writer_generation<>$1 AND retired_at IS NULL",
          [generation]
        )

        Repo.query!("DELETE FROM salix_cutover_markers WHERE name=$1", [@marker_name])
        :ok
      end)
      |> release_result(:invalid)
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def begin_backfill(_), do: {:error, :invalid}

  def backfill_state(generation) do
    case Repo.query(
           """
           SELECT writer_barrier_authority,writer_barrier_at,sealed_at,retired_at,
                  scan_upper_group_id,scan_upper_conversation_id,scan_group_id,
                  scan_conversation_id,scan_completed_at
           FROM conversation_search_backfill_runs WHERE writer_generation=$1
           """,
           [generation]
         ) do
      {:ok,
       %{
         rows: [
           [
             authority,
             barrier,
             sealed,
             retired,
             upper_group,
             upper_conversation,
             group,
             conversation,
             completed
           ]
         ]
       }} ->
        {:ok,
         %{
           writer_barrier_authority: authority,
           writer_barrier_at: barrier,
           sealed_at: sealed,
           retired_at: retired,
           scan_upper_group_id: upper_group,
           scan_upper_conversation_id: upper_conversation,
           scan_group_id: group,
           scan_conversation_id: conversation,
           scan_completed_at: completed
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def record_writer_barrier(generation, authority)
      when is_binary(authority) and authority != "" do
    with {:ok, ^generation} <- writer_generation() do
      Repo.transaction(fn ->
        %{rows: rows} =
          Repo.query!(
            "SELECT 1 FROM conversation_search_backfill_runs WHERE writer_generation=$1 AND sealed_at IS NULL AND retired_at IS NULL AND writer_barrier_at IS NULL FOR UPDATE",
            [generation]
          )

        if rows != [[1]], do: Repo.rollback(:invalid)

        upper =
          case Repo.query!(
                 "SELECT group_id,conversation_id FROM salix_conversations WHERE revision>0 ORDER BY group_id COLLATE \"C\" DESC,conversation_id COLLATE \"C\" DESC LIMIT 1"
               ).rows do
            [key] -> key
            [] -> [nil, nil]
          end

        Repo.query!(
          "UPDATE conversation_search_backfill_runs SET writer_barrier_authority=$2,writer_barrier_at=statement_timestamp(),scan_upper_group_id=$3,scan_upper_conversation_id=$4,updated_at=statement_timestamp() WHERE writer_generation=$1",
          [generation, String.trim(authority)] ++ upper
        )

        :ok
      end)
      |> release_result(:invalid)
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def record_writer_barrier(_, _), do: {:error, :invalid}

  def scan_page(generation, limit \\ 100) when limit in 1..100 do
    with {:ok, ^generation} <- writer_generation() do
      Repo.transaction(fn ->
        case Repo.query!(
               """
               SELECT scan_upper_group_id,scan_upper_conversation_id,scan_group_id,
                      scan_conversation_id,scan_completed_at,writer_barrier_at
               FROM conversation_search_backfill_runs
               WHERE writer_generation=$1 AND retired_at IS NULL AND sealed_at IS NULL FOR UPDATE
               """,
               [generation]
             ).rows do
          [] ->
            :idle

          [[_, _, _, _, completed, _]] when not is_nil(completed) ->
            :draining

          [[_, _, _, _, _, nil]] ->
            :idle

          [[upper_group, upper_conversation, group, conversation, _, _]] ->
            rows =
              Repo.query!(
                """
                SELECT group_id,conversation_id,kind,deleted_at FROM salix_conversations
                WHERE revision>0 AND $1::text IS NOT NULL
                  AND (group_id COLLATE "C",conversation_id COLLATE "C")<=($1,$2)
                  AND ($3::text IS NULL OR (group_id COLLATE "C",conversation_id COLLATE "C")>($3,$4))
                ORDER BY group_id COLLATE "C",conversation_id COLLATE "C" LIMIT $5
                """,
                [upper_group, upper_conversation, group, conversation, limit]
              ).rows

            for [source_group, source_conversation, kind, deleted] <- rows do
              operation = if kind == "agent_task" and is_nil(deleted), do: :rebuild, else: :delete

              case enqueue(source_group, source_conversation, operation, "", nil) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end
            end

            last =
              if rows == [], do: [group, conversation], else: rows |> List.last() |> Enum.take(2)

            complete = length(rows) < limit or last == [upper_group, upper_conversation]

            Repo.query!(
              """
              UPDATE conversation_search_backfill_runs
              SET scan_group_id=$2,scan_conversation_id=$3,
                  scan_completed_at=CASE WHEN $4 THEN statement_timestamp() ELSE NULL END,
                  updated_at=statement_timestamp() WHERE writer_generation=$1
              """,
              [generation] ++ last ++ [complete]
            )

            %{scanned: length(rows), complete: complete}
        end
      end)
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Open the configured generation after a successful core rollout.

  The release runner calls this only once every serving node runs the release,
  so every writer has the configured generation: the fleet fact
  `record_writer_barrier/2` asks for, recorded under `authority`. A generation
  already past its barrier is left alone; discovery seals it once its
  bounded scan is complete and its queue is drained.
  """
  @spec open_after_rollout(String.t()) ::
          {:ok, :not_configured | :opened | :indexing | :ready}
          | {:error, :invalid | :unavailable}
  def open_after_rollout(authority) when is_binary(authority) and authority != "" do
    case writer_generation() do
      {:error, :unavailable} ->
        {:ok, :not_configured}

      {:ok, generation} ->
        case backfill_state(generation) do
          {:ok, %{sealed_at: sealed_at}} when not is_nil(sealed_at) ->
            {:ok, :ready}

          {:ok, %{writer_barrier_at: barrier_at}} when not is_nil(barrier_at) ->
            {:ok, :indexing}

          {:ok, _open} ->
            record_writer_barrier(generation, authority) |> opened()

          {:error, :not_found} ->
            with :ok <- begin_backfill(generation),
                 do: record_writer_barrier(generation, authority) |> opened()

          {:error, :unavailable} = error ->
            error
        end
    end
  end

  def open_after_rollout(_authority), do: {:error, :invalid}

  defp opened(:ok), do: {:ok, :opened}
  defp opened({:error, _reason} = error), do: error

  @doc "The sole production transition that creates the reader-ready marker."
  def seal_backfill(generation) do
    Repo.transaction(fn ->
      with {:ok, ^generation} <- writer_generation(),
           {:ok, %{rows: [[authority, barrier, completed]]}} <-
             Repo.query(
               """
               SELECT writer_barrier_authority,writer_barrier_at,scan_completed_at
               FROM conversation_search_backfill_runs
               WHERE writer_generation=$1 AND retired_at IS NULL AND sealed_at IS NULL FOR UPDATE
               """,
               [generation]
             ),
           true <-
             is_binary(authority) and authority != "" and not is_nil(barrier) and
               not is_nil(completed),
           {:ok, %{rows: [[0]]}} <-
             Repo.query(
               "SELECT count(*) FROM conversation_search_jobs WHERE writer_generation=$1",
               [generation]
             ) do
        evidence = %{
          "writer_generation" => generation,
          "writer_barrier_authority" => authority,
          "writer_barrier_at" => to_string(barrier),
          "scan_completed_at" => to_string(completed),
          "pending_jobs" => 0
        }

        Repo.query!(
          """
          INSERT INTO salix_cutover_markers(name,completed_at,evidence)
          VALUES($1,statement_timestamp(),$2) ON CONFLICT(name) DO UPDATE
          SET completed_at=EXCLUDED.completed_at,evidence=EXCLUDED.evidence
          """,
          [@marker_name, evidence]
        )

        Repo.query!(
          "UPDATE conversation_search_backfill_runs SET sealed_at=statement_timestamp(),updated_at=statement_timestamp() WHERE writer_generation=$1",
          [generation]
        )

        :ok
      else
        _ -> Repo.rollback(:not_ready)
      end
    end)
    |> release_result(:not_ready)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Delete one bounded batch from a retired projection generation.

  The durable GC row records phase, counters, and the last removed key. The
  generation is refused while it is configured by this release, selected by
  an unretired run, reader-ready, or inside the retention window.
  Repeated operator invocations resume without a fleet poller.
  """
  @spec gc_retired_generation(String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :active | :ready | :too_young | :not_found | :invalid | :unavailable}
  def gc_retired_generation(generation, opts \\ [])

  def gc_retired_generation(generation, opts)
      when is_binary(generation) and generation != "" and is_list(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_gc_batch_size)
    configured_generation = configured_generation()
    minimum_retention = gc_retention_hours()
    retention_hours = Keyword.get(opts, :retention_hours, minimum_retention)

    cond do
      Keyword.keys(opts) -- [:batch_size, :retention_hours] != [] ->
        {:error, :invalid}

      not is_integer(batch_size) or batch_size < 1 or batch_size > @max_gc_batch_size ->
        {:error, :invalid}

      not is_integer(retention_hours) or retention_hours < minimum_retention ->
        {:error, :invalid}

      configured_generation == generation ->
        {:error, :active}

      true ->
        run_gc_batch(generation, batch_size, retention_hours)
    end
  end

  def gc_retired_generation(_generation, _opts), do: {:error, :invalid}

  @doc "Write the source's search target on its current Repo transaction connection."
  def enqueue_source!(group_id, conversation_id, operation, source_id, source_seq) do
    if configured?() do
      with {:ok, generation} <- writer_generation(),
           %{rows: [[1]]} <-
             enqueue_query!(
               generation,
               group_id,
               conversation_id,
               operation,
               source_id || "",
               source_seq
             ) do
        :ok
      else
        _ -> Repo.rollback(:conversation_search_unavailable)
      end
    else
      :ok
    end
  end

  @spec enqueue_rebuild(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def enqueue_rebuild(group_id, conversation_id),
    do: enqueue(group_id, conversation_id, :rebuild, "", nil)

  @spec claim_one(String.t(), pos_integer()) ::
          {:ok, claim() | nil} | {:error, :unavailable}
  def claim_one(holder, lease_ms)
      when is_binary(holder) and holder != "" and is_integer(lease_ms) and lease_ms > 0 do
    with {:ok, generation} <- writer_generation() do
      token = claim_token(holder)

      case Repo.query(
             """
             WITH candidate AS (
               SELECT job.id
               FROM conversation_search_jobs AS job
               WHERE job.writer_generation = $3
                 AND ((job.claim_token IS NULL AND job.available_at <= statement_timestamp()) OR
                      (job.claim_token IS NOT NULL AND job.claim_until <= statement_timestamp()))
                 AND EXISTS (
                   SELECT 1 FROM conversation_search_backfill_runs AS run
                   WHERE run.writer_generation = $3 AND run.writer_barrier_at IS NOT NULL AND run.retired_at IS NULL
                 )
               ORDER BY job.available_at, job.id
               LIMIT 1
               FOR UPDATE SKIP LOCKED
             )
             UPDATE conversation_search_jobs AS job
             SET claim_token = $1,
                 claim_until = statement_timestamp() + ($2::bigint * interval '1 millisecond'),
                 attempt_count = job.attempt_count + 1,
                 updated_at = statement_timestamp()
             FROM candidate
             WHERE job.id = candidate.id
             RETURNING job.id, job.writer_generation, job.agent_group_id,
                       job.conversation_id, job.operation, job.source_id, job.source_seq,
                       job.generation, job.attempt_count, job.claim_token
             """,
             [token, lease_ms, generation]
           ) do
        {:ok, %{rows: []}} -> {:ok, nil}
        {:ok, %{rows: [row]}} -> {:ok, claim_from_row(row)}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec renew_job_claim(claim(), pos_integer()) :: :ok | {:error, :claim_lost | :unavailable}
  def renew_job_claim(claim, lease_ms) when is_integer(lease_ms) and lease_ms > 0 do
    renew_claim(
      "conversation_search_jobs",
      "id = $1 AND writer_generation = $2 AND claim_token = $3 AND generation = $4 " <>
        "AND EXISTS (SELECT 1 FROM conversation_search_backfill_runs AS active_run " <>
        "WHERE active_run.retired_at IS NULL AND active_run.writer_generation = $2)",
      [claim.id, claim.writer_generation, claim.claim_token, claim.generation, lease_ms]
    )
  end

  @spec complete(claim()) :: :ok | {:error, :claim_lost | :unavailable}
  def complete(claim) do
    case Repo.query(
           """
           DELETE FROM conversation_search_jobs
           WHERE id = $1 AND writer_generation = $2 AND claim_token = $3 AND generation = $4
             AND claim_until > statement_timestamp()
             AND EXISTS (
               SELECT 1 FROM conversation_search_backfill_runs AS active_run
               WHERE active_run.retired_at IS NULL AND active_run.writer_generation = $2
             )
           RETURNING 1
           """,
           [claim.id, claim.writer_generation, claim.claim_token, claim.generation]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :claim_lost}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @spec retry(claim(), term()) :: :ok | {:error, :claim_lost | :unavailable}
  def retry(claim, reason) do
    delay_ms = min(60_000, trunc(:math.pow(2, min(claim.attempt_count, 9))) * 100)

    case Repo.query(
           """
           UPDATE conversation_search_jobs
           SET claim_token = NULL, claim_until = NULL,
               available_at = statement_timestamp() + ($5::bigint * interval '1 millisecond'),
               last_error = $6, updated_at = statement_timestamp()
           WHERE id = $1 AND writer_generation = $2 AND claim_token = $3 AND generation = $4
             AND claim_until > statement_timestamp()
             AND EXISTS (
               SELECT 1 FROM conversation_search_backfill_runs AS active_run
               WHERE active_run.retired_at IS NULL AND active_run.writer_generation = $2
             )
           RETURNING 1
           """,
           [
             claim.id,
             claim.writer_generation,
             claim.claim_token,
             claim.generation,
             delay_ms,
             inspect(reason, limit: 20, printable_limit: 1_000)
           ]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :claim_lost}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc "Atomically replace one Task's bounded title and recent-message projection."
  @spec replace_task(claim(), map(), [map()]) ::
          :ok | {:error, :claim_lost | :invalid | :unavailable}
  def replace_task(claim, snapshot, messages) do
    with true <- valid_snapshot?(snapshot),
         true <- valid_messages?(messages, snapshot),
         true <- claim.agent_group_id == snapshot.group_id,
         true <- claim.conversation_id == snapshot.conversation_id,
         true <- claim.operation in [:rebuild, :message] do
      Repo.transaction(fn ->
        with :ok <- lock_authorized_claim(claim),
             :ok <- reject_newer_state(claim.writer_generation, snapshot),
             {:ok, _state} <- upsert_state(claim.writer_generation, snapshot),
             {:ok, _delete} <- delete_documents(claim.writer_generation, snapshot),
             {:ok, _insert} <- insert_documents(claim.writer_generation, snapshot, messages) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> projection_result()
    else
      _other -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Apply one exact append and enforce the 64-slot and 256-KiB windows."
  @spec apply_message(claim(), map(), map() | nil) ::
          :ok | {:error, :requires_rebuild | :claim_lost | :invalid | :unavailable}
  def apply_message(claim, snapshot, message) do
    with true <- valid_snapshot?(snapshot),
         true <- is_nil(message) or SearchDocumentEnvelope.valid_message_entry?(message),
         true <- claim.operation == :message,
         true <- claim.agent_group_id == snapshot.group_id,
         true <- claim.conversation_id == snapshot.conversation_id,
         true <- claim.source_seq == snapshot.message_tail_seq do
      Repo.transaction(fn ->
        with :ok <- lock_authorized_claim(claim),
             :ok <- lock_incremental_state(claim.writer_generation, snapshot, claim.source_seq),
             {:ok, _title} <- upsert_title(claim.writer_generation, snapshot),
             {:ok, _message} <-
               upsert_optional_message(claim.writer_generation, snapshot, message),
             {:ok, _gc} <- gc_messages(claim.writer_generation, snapshot),
             {:ok, _state} <- update_incremental_state(claim.writer_generation, snapshot) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> projection_result()
    else
      _other -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec apply_delete(claim()) :: :ok | {:error, :claim_lost | :unavailable}
  def apply_delete(%{operation: :delete} = claim) do
    remove_task(claim)
  end

  def apply_delete(_claim), do: {:error, :claim_lost}

  @doc "Remove a projection after an exact canonical read proves it is no longer a Task."
  @spec apply_non_task(claim()) :: :ok | {:error, :claim_lost | :unavailable}
  def apply_non_task(%{operation: operation} = claim) when operation in [:rebuild, :message],
    do: remove_task(claim)

  defp remove_task(claim) do
    Repo.transaction(fn ->
      with :ok <- lock_authorized_claim(claim),
           {:ok, _state} <-
             Repo.query(
               """
               DELETE FROM conversation_search_states
               WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
               """,
               [claim.writer_generation, claim.agent_group_id, claim.conversation_id]
             ) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> projection_result()
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Whether a missing canonical object can be settled without changing projection state."
  @spec missing_source_safe_noop?(claim()) ::
          {:ok, boolean()} | {:error, :claim_lost | :unavailable}
  def missing_source_safe_noop?(claim) do
    Repo.transaction(fn ->
      with :ok <- lock_authorized_claim(claim),
           {:ok, %{rows: rows}} <-
             Repo.query(
               """
               SELECT 1 FROM conversation_search_states
               WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
               FOR UPDATE
               """,
               [claim.writer_generation, claim.agent_group_id, claim.conversation_id]
             ) do
        rows == []
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, safe?} when is_boolean(safe?) -> {:ok, safe?}
      {:error, :claim_lost} -> {:error, :claim_lost}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  def short_grams_for_test(content),
    do: content |> SearchDocumentEnvelope.fold() |> SearchDocumentEnvelope.bigrams()

  @doc false
  def snippet_for_test(content, query) do
    with {:ok, query_envelope} <- SearchDocumentEnvelope.query(query) do
      SearchDocumentEnvelope.render_match(:message, content, query_envelope)
    end
  end

  @doc false
  def explain_for_test(group_id, query, opts \\ []) do
    query = String.trim(query)
    limit = Keyword.get(opts, :limit, 20)
    conversation_id = Keyword.get(opts, :conversation_id)

    case validated_query(group_id, query, conversation_id, limit, opts) do
      {:ok, query_envelope} ->
        pattern = "%" <> escape_like(query_envelope.folded) <> "%"

        Repo.transaction(
          fn ->
            with {:ok, generation} <- writer_generation(),
                 {:ok, _timeout} <-
                   Repo.query("SELECT set_config('statement_timeout', $1, true)", [
                     Integer.to_string(@statement_timeout_ms) <> "ms"
                   ]),
                 {:ok, %{rows: [[plan]]}} <-
                   Repo.query(
                     "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> search_sql(),
                     [
                       generation,
                       group_id,
                       pattern,
                       conversation_id,
                       limit,
                       limit * SearchDocumentEnvelope.message_slots(),
                       query_envelope.short_grams
                     ],
                     timeout: @database_timeout_ms
                   ) do
              plan
            else
              _other -> Repo.rollback(:projection_unavailable)
            end
          end,
          timeout: @database_timeout_ms
        )

      :error ->
        {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  def delete_projection_for_test(group_id, conversation_id) do
    with {:ok, generation} <- writer_generation() do
      Repo.query(
        """
        DELETE FROM conversation_search_states
        WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
        """,
        [generation, group_id, conversation_id]
      )
    end
  end

  defp enqueue(group_id, conversation_id, operation, source_id, source_seq)
       when is_binary(group_id) and group_id != "" and is_binary(conversation_id) and
              conversation_id != "" do
    with {:ok, generation} <- writer_generation(),
         %{rows: [[1]]} <-
           enqueue_query!(generation, group_id, conversation_id, operation, source_id, source_seq) do
      :ok
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp enqueue(_, _, _, _, _), do: {:error, :unavailable}

  defp enqueue_query!(generation, group_id, conversation_id, operation, source_id, source_seq) do
    Repo.query!(
      """
      INSERT INTO conversation_search_jobs
      (writer_generation, agent_group_id, conversation_id, operation,
      source_id, source_seq, generation, available_at, inserted_at, updated_at)
      SELECT $1, $2, $3, $4, $5, $6, 1, statement_timestamp(),
         statement_timestamp(), statement_timestamp()
      WHERE EXISTS (
      SELECT 1 FROM conversation_search_backfill_runs
      WHERE retired_at IS NULL AND writer_generation = $1
      )
      ON CONFLICT (writer_generation, agent_group_id, conversation_id)
      DO UPDATE SET
      operation = CASE
      WHEN EXCLUDED.operation = 'delete' THEN 'delete'
      WHEN conversation_search_jobs.operation = 'delete' THEN 'delete'
      WHEN EXCLUDED.operation = 'rebuild' THEN 'rebuild'
      WHEN conversation_search_jobs.operation = 'rebuild' THEN 'rebuild'
      WHEN conversation_search_jobs.source_id = EXCLUDED.source_id AND
           conversation_search_jobs.source_seq = EXCLUDED.source_seq THEN 'message'
      ELSE 'rebuild'
      END,
      source_id = CASE
      WHEN EXCLUDED.operation = 'message' AND
           conversation_search_jobs.operation = 'message' AND
           conversation_search_jobs.source_id = EXCLUDED.source_id AND
           conversation_search_jobs.source_seq = EXCLUDED.source_seq
        THEN EXCLUDED.source_id
      ELSE ''
      END,
      source_seq = CASE
      WHEN EXCLUDED.operation = 'message' AND
           conversation_search_jobs.operation = 'message' AND
           conversation_search_jobs.source_id = EXCLUDED.source_id AND
           conversation_search_jobs.source_seq = EXCLUDED.source_seq
        THEN EXCLUDED.source_seq
      ELSE NULL
      END,
      generation = conversation_search_jobs.generation + 1,
      available_at = statement_timestamp(), claim_token = NULL, claim_until = NULL,
      last_error = NULL, updated_at = statement_timestamp()
      RETURNING 1
      """,
      [generation, group_id, conversation_id, Atom.to_string(operation), source_id, source_seq]
    )
  end

  defp lock_authorized_claim(claim) do
    with {:ok, generation} <- writer_generation(),
         true <- generation == claim.writer_generation,
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             """
             SELECT 1
             FROM conversation_search_jobs AS job
             JOIN conversation_search_backfill_runs AS run
               ON run.writer_generation = job.writer_generation
              AND run.writer_barrier_at IS NOT NULL AND run.retired_at IS NULL
             WHERE job.id = $1 AND job.writer_generation = $2
               AND job.claim_token = $3 AND job.generation = $4
               AND job.claim_until > statement_timestamp()
             FOR UPDATE OF job
             FOR SHARE OF run
             """,
             [claim.id, claim.writer_generation, claim.claim_token, claim.generation]
           ) do
      :ok
    else
      _other -> {:error, :claim_lost}
    end
  end

  defp reject_newer_state(generation, snapshot) do
    case Repo.query(
           """
           SELECT source_version
           FROM conversation_search_states
           WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
           FOR UPDATE
           """,
           [generation, snapshot.group_id, snapshot.conversation_id]
         ) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [[version]]}} when version <= snapshot.source_version -> :ok
      {:ok, %{rows: [[_newer]]}} -> {:error, :claim_lost}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_incremental_state(generation, snapshot, seq) do
    case Repo.query(
           """
           SELECT 1
           FROM conversation_search_states
           WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
             AND title = $4 AND message_head_seq = $5 AND message_tail_seq = $6
             AND source_version <= $7
             AND mail_account_id IS NOT DISTINCT FROM $8::text
             AND mail_thread_id IS NOT DISTINCT FROM $9::text
           FOR UPDATE
           """,
           [
             generation,
             snapshot.group_id,
             snapshot.conversation_id,
             snapshot.title_envelope.content,
             snapshot.message_head_seq,
             seq - 1,
             snapshot.source_version,
             snapshot[:mail_account_id],
             snapshot[:mail_thread_id]
           ]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :requires_rebuild}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_state(generation, snapshot) do
    Repo.query(
      """
      INSERT INTO conversation_search_states
        (writer_generation, agent_group_id, conversation_id, conversation_kind, title,
         source_version, message_head_seq, message_tail_seq, mail_account_id, mail_thread_id, updated_at)
      VALUES ($1, $2, $3, 'agent_task', $4, $5, $6, $7, $8, $9, statement_timestamp())
      ON CONFLICT (writer_generation, agent_group_id, conversation_id)
      DO UPDATE SET conversation_kind = 'agent_task', title = EXCLUDED.title,
                    source_version = EXCLUDED.source_version,
                    message_head_seq = EXCLUDED.message_head_seq,
                    message_tail_seq = EXCLUDED.message_tail_seq,
                    mail_account_id = EXCLUDED.mail_account_id,
                    mail_thread_id = EXCLUDED.mail_thread_id,
                    updated_at = statement_timestamp()
      """,
      [
        generation,
        snapshot.group_id,
        snapshot.conversation_id,
        snapshot.title_envelope.content,
        snapshot.source_version,
        snapshot.message_head_seq,
        snapshot.message_tail_seq,
        snapshot[:mail_account_id],
        snapshot[:mail_thread_id]
      ]
    )
  end

  defp update_incremental_state(generation, snapshot) do
    Repo.query(
      """
      UPDATE conversation_search_states
      SET source_version = $4, message_head_seq = $5, message_tail_seq = $6,
          updated_at = statement_timestamp()
      WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
      """,
      [
        generation,
        snapshot.group_id,
        snapshot.conversation_id,
        snapshot.source_version,
        snapshot.message_head_seq,
        snapshot.message_tail_seq
      ]
    )
  end

  defp delete_documents(generation, snapshot) do
    Repo.query(
      """
      DELETE FROM conversation_search_documents
      WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
      """,
      [generation, snapshot.group_id, snapshot.conversation_id]
    )
  end

  defp insert_documents(generation, snapshot, messages) do
    documents =
      [title_document(snapshot) | Enum.map(messages, &message_document/1)]
      |> Enum.map(fn document ->
        envelope = document.envelope

        %{
          "document_type" => document.type,
          "document_id" => document.id,
          "source_id" => document.source_id,
          "source_seq" => document.source_seq,
          "source_created_at" => document.created_at,
          "content" => envelope.content,
          "folded_content" => envelope.folded_content,
          "short_grams" => envelope.short_grams
        }
      end)

    Repo.query(
      """
      INSERT INTO conversation_search_documents
        (writer_generation, agent_group_id, conversation_id, document_type, document_id,
         source_id, source_seq, source_created_at, content, folded_content,
         short_grams, updated_at)
      SELECT $1, $2, $3, value.document_type, value.document_id, value.source_id,
             value.source_seq, value.source_created_at, value.content,
             value.folded_content,
             ARRAY(SELECT jsonb_array_elements_text(value.short_grams)),
             statement_timestamp()
      FROM jsonb_to_recordset($4::jsonb)
           AS value(document_type text, document_id text, source_id text,
                    source_seq bigint, source_created_at bigint, content text,
                    folded_content text, short_grams jsonb)
      """,
      [generation, snapshot.group_id, snapshot.conversation_id, documents]
    )
  end

  defp upsert_title(generation, snapshot) do
    document = title_document(snapshot)
    envelope = document.envelope

    Repo.query(
      """
      INSERT INTO conversation_search_documents
        (writer_generation, agent_group_id, conversation_id, document_type, document_id,
         source_id, source_seq, source_created_at, content, folded_content,
         short_grams, updated_at)
      VALUES ($1, $2, $3, 'title', 'title', 'title', NULL, NULL,
              $4, $5, $6, statement_timestamp())
      ON CONFLICT (writer_generation, agent_group_id, conversation_id, document_type, document_id)
      DO UPDATE SET content = EXCLUDED.content, folded_content = EXCLUDED.folded_content,
                    short_grams = EXCLUDED.short_grams, updated_at = statement_timestamp()
      """,
      [
        generation,
        snapshot.group_id,
        snapshot.conversation_id,
        envelope.content,
        envelope.folded_content,
        envelope.short_grams
      ]
    )
  end

  defp upsert_optional_message(_generation, _snapshot, nil), do: {:ok, %{rows: []}}

  defp upsert_optional_message(generation, snapshot, message) do
    document = message_document(message)
    envelope = document.envelope

    Repo.query(
      """
      INSERT INTO conversation_search_documents
        (writer_generation, agent_group_id, conversation_id, document_type, document_id,
         source_id, source_seq, source_created_at, content, folded_content,
         short_grams, updated_at)
      VALUES ($1, $2, $3, 'message', $4, $4, $5, $6, $7, $8, $9,
              statement_timestamp())
      ON CONFLICT (writer_generation, agent_group_id, conversation_id, document_type, document_id)
      DO UPDATE SET source_seq = EXCLUDED.source_seq,
                    source_created_at = EXCLUDED.source_created_at,
                    content = EXCLUDED.content,
                    folded_content = EXCLUDED.folded_content,
                    short_grams = EXCLUDED.short_grams, updated_at = statement_timestamp()
      """,
      [
        generation,
        snapshot.group_id,
        snapshot.conversation_id,
        document.id,
        document.source_seq,
        document.created_at,
        envelope.content,
        envelope.folded_content,
        envelope.short_grams
      ]
    )
  end

  defp gc_messages(generation, snapshot) do
    window_start =
      SearchDocumentEnvelope.message_window_start(
        snapshot.message_head_seq,
        snapshot.message_tail_seq
      )

    Repo.query(
      """
      WITH ranked AS (
        SELECT document_id,
               sum(weight_bytes) OVER (
                 ORDER BY source_seq DESC, document_id DESC
               ) AS cumulative_bytes
        FROM conversation_search_documents
        WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
          AND document_type = 'message' AND source_seq >= $4
      ), remove AS (
        SELECT document_id FROM ranked WHERE cumulative_bytes > $5
        UNION ALL
        SELECT document_id
        FROM conversation_search_documents
        WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
          AND document_type = 'message' AND source_seq < $4
      )
      DELETE FROM conversation_search_documents AS document
      USING remove
      WHERE document.writer_generation = $1 AND document.agent_group_id = $2
        AND document.conversation_id = $3 AND document.document_type = 'message'
        AND document.document_id = remove.document_id
      """,
      [
        generation,
        snapshot.group_id,
        snapshot.conversation_id,
        window_start,
        SearchDocumentEnvelope.message_window_bytes()
      ]
    )
  end

  # Runs a reader query against the open writer generation (`$1`), after
  # `params`, under the reader's statement timeout.
  defp run_projection_query(sql, params) do
    Repo.transaction(
      fn ->
        with {:ok, generation} <- writer_generation(),
             {:ok, %{rows: [[1]]}} <-
               Repo.query(
                 """
                 SELECT 1 FROM salix_cutover_markers
                 WHERE name = $1 AND evidence->>'writer_generation' = $2
                 """,
                 [@marker_name, generation]
               ),
             {:ok, _timeout} <-
               Repo.query("SELECT set_config('statement_timeout', $1, true)", [
                 Integer.to_string(@statement_timeout_ms) <> "ms"
               ]),
             {:ok, %{rows: rows}} <-
               Repo.query(sql, [generation | params], timeout: @database_timeout_ms) do
          rows
        else
          _other -> Repo.rollback(:projection_unavailable)
        end
      end,
      timeout: @database_timeout_ms
    )
  end

  defp search_sql do
    """
    WITH title_documents AS MATERIALIZED (
      SELECT document.conversation_id, document.document_type,
             document.content, document.source_id, document.source_seq
      FROM conversation_search_documents AS document
      WHERE document.writer_generation = $1 AND document.agent_group_id = $2
        AND ($4::text IS NULL OR document.conversation_id = $4)
        AND document.document_type = 'title'
        AND document.short_grams @> $7::text[]
        AND document.folded_content LIKE $3 ESCAPE E'\\\\'
      LIMIT $5
    ), message_documents AS MATERIALIZED (
      SELECT document.conversation_id, document.document_type,
             document.content, document.source_id, document.source_seq
      FROM conversation_search_documents AS document
      WHERE document.writer_generation = $1 AND document.agent_group_id = $2
        AND ($4::text IS NULL OR document.conversation_id = $4)
        AND document.document_type = 'message'
        AND document.short_grams @> $7::text[]
        AND document.folded_content LIKE $3 ESCAPE E'\\\\'
      LIMIT $6
    ), candidate_documents AS MATERIALIZED (
      SELECT * FROM title_documents
      UNION ALL
      SELECT * FROM message_documents
    ), candidates AS MATERIALIZED (
      SELECT state.conversation_id, state.title, document.document_type,
             document.content, document.source_id, document.source_seq,
             state.source_version
      FROM candidate_documents AS document
      JOIN conversation_search_states AS state
        ON state.writer_generation = $1
       AND state.agent_group_id = $2
       AND state.conversation_id = document.conversation_id
      WHERE state.conversation_kind = 'agent_task'
    ), ranked AS (
      SELECT candidates.*,
             row_number() OVER (
               PARTITION BY conversation_id
               ORDER BY CASE document_type WHEN 'title' THEN 0 ELSE 1 END,
                        source_seq DESC NULLS LAST
             ) AS hit_rank
      FROM candidates
    ), selected AS MATERIALIZED (
      SELECT conversation_id, title, document_type, content, source_id, source_seq,
             source_version
      FROM ranked
      WHERE hit_rank = 1
      ORDER BY CASE document_type WHEN 'title' THEN 0 ELSE 1 END,
               source_seq DESC NULLS LAST, source_version DESC, conversation_id
      LIMIT $5
    )
    SELECT selected.conversation_id, selected.title, selected.document_type,
           selected.content, selected.source_id, selected.source_seq,
           selected.source_version, content_match.content, content_match.source_id,
           content_match.source_seq
    FROM selected
    LEFT JOIN LATERAL (
      SELECT document.content, document.source_id, document.source_seq
      FROM conversation_search_documents AS document
      WHERE selected.document_type = 'title'
        AND document.writer_generation = $1
        AND document.agent_group_id = $2
        AND document.conversation_id = selected.conversation_id
        AND document.document_type = 'message'
        AND document.short_grams @> $7::text[]
        AND document.folded_content LIKE $3 ESCAPE E'\\\\'
      ORDER BY document.source_seq DESC
      LIMIT 1
    ) AS content_match ON TRUE
    ORDER BY CASE selected.document_type WHEN 'title' THEN 0 ELSE 1 END,
             selected.source_seq DESC NULLS LAST, selected.source_version DESC,
             selected.conversation_id
    """
  end

  defp message_matches_sql do
    """
    SELECT document.content, document.source_id, document.source_seq
    FROM conversation_search_documents AS document
    JOIN conversation_search_states AS state
      ON state.writer_generation = $1
     AND state.agent_group_id = $2
     AND state.conversation_id = document.conversation_id
    WHERE document.writer_generation = $1 AND document.agent_group_id = $2
      AND document.conversation_id = $4
      AND document.document_type = 'message'
      AND document.short_grams @> $6::text[]
      AND document.folded_content LIKE $3 ESCAPE E'\\\\'
      AND state.conversation_kind = 'agent_task'
    ORDER BY document.source_seq
    LIMIT $5
    """
  end

  defp project_message_match([content, message_id, seq], query_envelope)
       when is_binary(message_id) and is_integer(seq) do
    case SearchDocumentEnvelope.render_match(:message, content, query_envelope) do
      {:ok, _snippet, _range} -> [%{"message_id" => message_id, "message_seq" => seq}]
      :nomatch -> []
    end
  end

  defp project_message_match(_row, _query_envelope), do: []

  defp project_hit(
         [
           conversation_id,
           title,
           document_type,
           content,
           source_id,
           source_seq,
           updated_at,
           content_match_content,
           content_match_source_id,
           content_match_source_seq
         ],
         query_envelope
       ) do
    kind = if document_type == "title", do: :title, else: :message
    projection = SearchDocumentEnvelope.render_match(kind, content, query_envelope)

    case projection do
      {:ok, snippet, range} ->
        hit =
          %{
            "conversation_id" => conversation_id,
            "title" => title,
            "snippet" => snippet,
            "matched_field" => if(document_type == "title", do: "title", else: "content"),
            "highlights" => [range],
            "updated_at" => updated_at
          }
          |> maybe_put_message_position(document_type, source_id, source_seq)

        [
          maybe_put_content_match(
            hit,
            document_type,
            {content_match_content, content_match_source_id, content_match_source_seq},
            query_envelope
          )
        ]

      :nomatch ->
        []
    end
  end

  # Where a matched Message sits in its Conversation: its id, and its `seq`,
  # which positions a page of Messages (`around`) without reading the history
  # before it.
  defp maybe_put_message_position(match, "message", message_id, seq)
       when is_binary(message_id) and is_integer(seq),
       do: Map.merge(match, %{"message_id" => message_id, "message_seq" => seq})

  defp maybe_put_message_position(match, _document_type, _message_id, _seq), do: match

  defp maybe_put_content_match(hit, "title", {content, message_id, seq}, query_envelope)
       when is_binary(content) do
    case SearchDocumentEnvelope.render_match(:message, content, query_envelope) do
      {:ok, snippet, range} ->
        content_match =
          maybe_put_message_position(
            %{"snippet" => snippet, "highlights" => [range]},
            "message",
            message_id,
            seq
          )

        Map.put(hit, "content_match", content_match)

      :nomatch ->
        hit
    end
  end

  defp maybe_put_content_match(hit, _document_type, _content_match, _query_envelope), do: hit

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp title_document(snapshot) do
    %{
      type: "title",
      id: "title",
      source_id: "title",
      source_seq: nil,
      created_at: nil,
      envelope: snapshot.title_envelope
    }
  end

  defp message_document(message) do
    %{
      type: "message",
      id: message.id,
      source_id: message.id,
      source_seq: message.seq,
      created_at: message.created_at,
      envelope: message.envelope
    }
  end

  defp run_gc_batch(generation, batch_size, retention_hours) do
    Repo.transaction(
      fn ->
        with {:ok, _timeout} <-
               Repo.query("SET LOCAL statement_timeout = '#{@gc_statement_timeout_ms}ms'"),
             {:ok, _lock_timeout} <- Repo.query("SET LOCAL lock_timeout = '250ms'"),
             {:ok, phase} <- prepare_gc_run(generation, retention_hours),
             {:ok, result} <- delete_gc_phase(generation, phase, batch_size) do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @gc_database_timeout_ms
    )
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, reason}
      when reason in [:active, :ready, :too_young, :not_found, :invalid] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp prepare_gc_run(generation, retention_hours) do
    case Repo.query(
           "SELECT phase FROM conversation_search_gc_runs " <>
             "WHERE writer_generation = $1 FOR UPDATE",
           [generation]
         ) do
      {:ok, %{rows: [[phase]]}} ->
        with :ok <- gc_generation_inactive(generation) do
          {:ok, phase}
        end

      {:ok, %{rows: []}} ->
        with :ok <- gc_generation_eligible(generation, retention_hours),
             {:ok, %{rows: [[phase]]}} <-
               Repo.query(
                 """
                 INSERT INTO conversation_search_gc_runs
                   (writer_generation, phase, cursor, inserted_at, updated_at)
                 VALUES ($1, 'documents', '{}'::jsonb, statement_timestamp(),
                         statement_timestamp())
                 RETURNING phase
                 """,
                 [generation]
               ) do
          {:ok, phase}
        else
          {:error, reason} -> {:error, reason}
          _other -> {:error, :unavailable}
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp gc_generation_eligible(generation, retention_hours) do
    with :ok <- gc_generation_inactive(generation),
         {:ok, %{rows: [[old_enough]]}} <-
           Repo.query(
             """
             SELECT retired_at IS NOT NULL AND retired_at <=
                      statement_timestamp() - ($2::bigint * interval '1 hour')
             FROM conversation_search_backfill_runs
             WHERE writer_generation = $1
             FOR UPDATE
             """,
             [generation, retention_hours]
           ) do
      if old_enough, do: :ok, else: {:error, :too_young}
    else
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  end

  defp gc_generation_inactive(generation) do
    with {:ok, %{rows: [[ready, active]]}} <-
           Repo.query(
             """
             SELECT
               EXISTS (
                 SELECT 1 FROM salix_cutover_markers
                 WHERE name = $1 AND evidence->>'writer_generation' = $2
               ),
               EXISTS (
                 SELECT 1 FROM conversation_search_backfill_runs
                 WHERE retired_at IS NULL AND writer_generation = $2
               )
             """,
             [@marker_name, generation]
           ) do
      cond do
        ready -> {:error, :ready}
        active -> {:error, :active}
        true -> :ok
      end
    else
      _other -> {:error, :unavailable}
    end
  end

  defp delete_gc_phase(generation, "documents", batch_size) do
    delete_gc_rows(
      generation,
      batch_size,
      "conversation_search_documents",
      "agent_group_id, conversation_id, document_type, document_id",
      "documents",
      "states",
      "deleted_documents",
      fn [group_id, conversation_id, type, id] ->
        %{
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id,
          "document_type" => type,
          "document_id" => id
        }
      end
    )
  end

  defp delete_gc_phase(generation, "states", batch_size) do
    delete_gc_rows(
      generation,
      batch_size,
      "conversation_search_states",
      "agent_group_id, conversation_id",
      "states",
      "jobs",
      "deleted_states",
      fn [group_id, conversation_id] ->
        %{"agent_group_id" => group_id, "conversation_id" => conversation_id}
      end
    )
  end

  defp delete_gc_phase(generation, "jobs", batch_size) do
    delete_gc_rows(
      generation,
      batch_size,
      "conversation_search_jobs",
      "id",
      "jobs",
      "metadata",
      "deleted_jobs",
      fn [id] -> %{"id" => id} end
    )
  end

  defp delete_gc_phase(generation, "metadata", _batch_size) do
    with {:ok, _deleted} <-
           Repo.query(
             "DELETE FROM conversation_search_backfill_runs WHERE writer_generation = $1",
             [generation]
           ),
         {:ok, %{rows: [row]}} <-
           Repo.query(
             """
             UPDATE conversation_search_gc_runs
             SET phase = 'done', cursor = '{}'::jsonb, finished_at = statement_timestamp(),
                 updated_at = statement_timestamp()
             WHERE writer_generation = $1 AND phase = 'metadata'
             RETURNING phase, cursor, deleted_documents, deleted_states, deleted_jobs,
                       finished_at
             """,
             [generation]
           ) do
      {:ok, gc_result(generation, row, 0)}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp delete_gc_phase(generation, "done", _batch_size) do
    case Repo.query(
           """
           SELECT phase, cursor, deleted_documents, deleted_states, deleted_jobs, finished_at
           FROM conversation_search_gc_runs WHERE writer_generation = $1
           """,
           [generation]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, gc_result(generation, row, 0)}
      _other -> {:error, :unavailable}
    end
  end

  defp delete_gc_phase(_generation, _phase, _batch_size), do: {:error, :invalid}

  defp delete_gc_rows(
         generation,
         batch_size,
         table,
         ordered_columns,
         expected_phase,
         next_phase,
         counter,
         cursor_fun
       ) do
    case Repo.query(
           """
           WITH doomed AS MATERIALIZED (
             SELECT ctid, #{ordered_columns}
             FROM #{table}
             WHERE writer_generation = $1
             ORDER BY #{ordered_columns}
             LIMIT $2
           )
           DELETE FROM #{table} AS target
           USING doomed
           WHERE target.ctid = doomed.ctid
           RETURNING #{Enum.map_join(String.split(ordered_columns, ", "), ", ", &("doomed." <> &1))}
           """,
           [generation, batch_size]
         ) do
      {:ok, %{rows: []}} ->
        update_gc_progress(generation, expected_phase, next_phase, %{}, counter, 0, 0)

      {:ok, %{rows: rows}} ->
        cursor = rows |> List.last() |> cursor_fun.()

        update_gc_progress(
          generation,
          expected_phase,
          expected_phase,
          cursor,
          counter,
          length(rows),
          length(rows)
        )

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp update_gc_progress(
         generation,
         expected_phase,
         next_phase,
         cursor,
         counter,
         increment,
         deleted_in_batch
       ) do
    case Repo.query(
           """
           UPDATE conversation_search_gc_runs
           SET phase = $3, cursor = $4, #{counter} = #{counter} + $5,
               updated_at = statement_timestamp()
           WHERE writer_generation = $1 AND phase = $2
           RETURNING phase, cursor, deleted_documents, deleted_states, deleted_jobs,
                     finished_at
           """,
           [generation, expected_phase, next_phase, cursor, increment]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, gc_result(generation, row, deleted_in_batch)}
      _other -> {:error, :unavailable}
    end
  end

  defp gc_result(generation, [phase, cursor, documents, states, jobs, finished_at], batch) do
    %{
      writer_generation: generation,
      phase: String.to_existing_atom(phase),
      cursor: cursor,
      deleted_in_batch: batch,
      deleted_documents: documents,
      deleted_states: states,
      deleted_jobs: jobs,
      done: phase == "done",
      finished_at: finished_at
    }
  end

  defp configured_generation do
    case writer_generation() do
      {:ok, generation} -> generation
      {:error, _reason} -> nil
    end
  end

  defp gc_retention_hours do
    case SystemsRuntime.get_env(
           :salix_store,
           :conversation_search_gc_retention_hours,
           @default_gc_retention_hours
         ) do
      hours when is_integer(hours) and hours >= @default_gc_retention_hours -> hours
      _other -> @default_gc_retention_hours
    end
  end

  defp validated_query(group_id, query, conversation_id, limit, opts) do
    valid_scope? =
      group_id != "" and is_integer(limit) and limit in 1..@max_limit and
        (is_nil(conversation_id) or (is_binary(conversation_id) and conversation_id != "")) and
        Keyword.keys(opts) -- [:limit, :conversation_id] == []

    with true <- valid_scope?,
         {:ok, query_envelope} <- SearchDocumentEnvelope.query(query) do
      {:ok, query_envelope}
    else
      _other -> :error
    end
  end

  defp valid_snapshot?(snapshot) do
    is_map(snapshot) and is_binary(snapshot.group_id) and snapshot.group_id != "" and
      is_binary(snapshot.conversation_id) and snapshot.conversation_id != "" and
      SearchDocumentEnvelope.valid?(snapshot.title_envelope, :title) and
      is_integer(snapshot.source_version) and snapshot.source_version >= 0 and
      SearchDocumentEnvelope.valid_sequence_range?(
        snapshot.message_head_seq,
        snapshot.message_tail_seq
      )
  end

  defp valid_messages?(messages, snapshot),
    do:
      SearchDocumentEnvelope.valid_message_window?(
        messages,
        snapshot.message_head_seq,
        snapshot.message_tail_seq
      )

  defp claim_token(holder),
    do: holder <> ":" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp claim_from_row([
         id,
         writer_generation,
         group_id,
         conversation_id,
         operation,
         source_id,
         source_seq,
         generation,
         attempt_count,
         token
       ]) do
    %{
      id: id,
      writer_generation: writer_generation,
      agent_group_id: group_id,
      conversation_id: conversation_id,
      operation: String.to_existing_atom(operation),
      source_id: source_id,
      source_seq: source_seq,
      generation: generation,
      attempt_count: attempt_count,
      claim_token: token
    }
  end

  defp release_result({:ok, :ok}, _reason), do: :ok
  defp release_result({:error, reason}, reason), do: {:error, reason}
  defp release_result({:error, _reason}, _expected), do: {:error, :unavailable}

  defp projection_result({:ok, :ok}), do: :ok

  defp projection_result({:error, reason})
       when reason in [:claim_lost, :requires_rebuild, :invalid],
       do: {:error, reason}

  defp projection_result({:error, _reason}), do: {:error, :unavailable}

  defp renew_claim(table, where_sql, params) do
    lease_param = length(params)

    case Repo.query(
           """
           UPDATE #{table}
           SET claim_until = statement_timestamp() +
                 ($#{lease_param}::bigint * interval '1 millisecond'),
               updated_at = statement_timestamp()
           WHERE #{where_sql} AND claim_until > statement_timestamp()
           RETURNING 1
           """,
           params
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :claim_lost}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
