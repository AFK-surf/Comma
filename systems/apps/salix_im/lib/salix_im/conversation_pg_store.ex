defmodule SalixIM.ConversationPGStore do
  @moduledoc false

  alias SalixIM.ConversationArchive
  alias SalixStore.{Keys, Repo, S3}

  @enforce_keys [:group_id, :conversation_id]
  defstruct [:group_id, :conversation_id]

  defmodule Pending do
    @moduledoc false
    @derive {Inspect, only: [:kind, :scope, :expected_revision]}
    defstruct [:kind, :scope, :expected_revision, :previous, :record, :message, :participants]
  end

  @columns ~w(agent_group_id conversation_id revision kind updated_at message_tail_seq message_head_seq log_start_seq provider_status_version membership_revision deleted_at message_count target_message_count participants participant_count messages)
  @import_locator_rows 128
  @import_locator_bytes 1_048_576

  def new(group_id, conversation_id),
    do: %__MODULE__{group_id: group_id, conversation_id: conversation_id}

  # Offline import uses the caller's checked-out connection and frozen facts.
  def import_metadata!(scope, record, revision \\ 1) do
    record =
      Map.drop(
        record,
        ~w(current_message_segment current_message_segment_start_seq _list_index_previous_updated_at)
      )

    SalixStore.PGAuthorityImport.insert_exact!(
      "salix_conversations",
      [:group_id, :conversation_id],
      %{
        group_id: scope.group_id,
        conversation_id: scope.conversation_id,
        revision: revision,
        metadata: encode(Map.drop(record, @columns)),
        kind: record["kind"],
        status: record["status"],
        list_timestamp: SalixIM.TaskArchive.list_timestamp(record),
        updated_at: datetime(record["updated_at"]),
        message_tail_seq: record["message_tail_seq"] || record["message_count"] || 0,
        message_head_seq: record["message_head_seq"],
        log_start_seq: record["log_start_seq"],
        provider_status_version: record["provider_status_version"] || 0,
        membership_revision: record["membership_revision"] || 0,
        deleted_at: datetime(record["deleted_at"])
      }
    )
  end

  def import_messages!(scope, facts) do
    rows =
      Enum.map(facts, fn fact ->
        record = fact.record

        %{
          group_id: scope.group_id,
          conversation_id: scope.conversation_id,
          message_id: record["message_id"],
          seq: record["seq"],
          request_identity: normalize_identity(record["request_identity"]),
          request_fingerprint: record["request_fingerprint"],
          revision: fact.revision,
          tombstone: fact.tombstone,
          archive_first_seq: fact.archive_first_seq,
          payload: if(is_nil(fact.archive_first_seq), do: encode(record))
        }
      end)

    SalixStore.PGAuthorityImport.insert_exact_many!(
      "salix_conversation_messages",
      [:group_id, :conversation_id, :message_id],
      rows
    )
  end

  def import_reservations!(scope, records) do
    for record <- records do
      %{rows: rows} =
        Repo.query!(
          "SELECT seq, payload FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
          [scope.group_id, scope.conversation_id, record["message_id"]]
        )

      case rows do
        [[seq, _]] when is_integer(seq) ->
          import_locator!(scope, Map.put(record, "seq", seq))

        [[nil, payload]] ->
          if payload != encode(Map.take(record, ["created_at"])),
            do:
              Repo.rollback(
                {:import_conflict, "salix_conversation_messages", record["message_id"]}
              )

          import_locator!(scope, Map.put(record, "seq", nil))

        [] ->
          SalixStore.PGAuthorityImport.insert_exact!(
            "salix_conversation_messages",
            [:group_id, :conversation_id, :message_id],
            %{
              group_id: scope.group_id,
              conversation_id: scope.conversation_id,
              message_id: record["message_id"],
              seq: nil,
              request_identity: normalize_identity(record["request_identity"]),
              request_fingerprint: record["request_fingerprint"],
              revision: record["revision"] || 1,
              tombstone: false,
              archive_first_seq: nil,
              payload: encode(Map.take(record, ["created_at"]))
            }
          )
      end
    end

    :ok
  end

  def import_locator!(scope, record) do
    fingerprint =
      if record["request_fingerprint"] not in [nil, ""], do: record["request_fingerprint"]

    %{num_rows: count} =
      Repo.query!(
        "UPDATE salix_conversation_messages SET request_identity=COALESCE(request_identity,$5::text), request_fingerprint=COALESCE(request_fingerprint,$6::text) " <>
          "WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3 AND seq IS NOT DISTINCT FROM $4::bigint " <>
          "AND (request_identity IS NULL OR $5::text IS NULL OR request_identity=$5::text) " <>
          "AND (request_fingerprint IS NULL OR $6::text IS NULL OR request_fingerprint=$6::text)",
        [
          scope.group_id,
          scope.conversation_id,
          record["message_id"],
          record["seq"],
          normalize_identity(record["request_identity"]),
          fingerprint
        ]
      )

    if count != 1,
      do: Repo.rollback({:import_conflict, "salix_conversation_messages", record["message_id"]})

    :ok
  end

  def import_locators!(scope, records) do
    records
    |> Stream.chunk_while(
      {[], 0, 0},
      fn record, {batch, bytes, count} ->
        size = :erlang.external_size(record)

        if count == @import_locator_rows or (count > 0 and bytes + size > @import_locator_bytes),
          do: {:cont, Enum.reverse(batch), {[record], size, 1}},
          else: {:cont, {[record | batch], bytes + size, count + 1}}
      end,
      fn
        {[], _, _} = empty -> {:cont, empty}
        {batch, _, _} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
    |> Enum.each(&import_locator_batch!(scope, &1))

    :ok
  end

  defp import_locator_batch!(scope, records) do
    ids = records |> Enum.map(& &1["message_id"]) |> Enum.uniq()

    %{rows: rows} =
      Repo.query!(
        "SELECT message_id,seq,request_identity,request_fingerprint " <>
          "FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 " <>
          "AND message_id=ANY($3::text[]) ORDER BY message_id FOR UPDATE",
        [scope.group_id, scope.conversation_id, ids]
      )

    existing = Map.new(rows, fn [id | values] -> {id, values} end)

    merged =
      Enum.reduce(records, existing, fn record, merged ->
        id = record["message_id"]
        source_seq = record["seq"]
        identity = normalize_identity(record["request_identity"])

        fingerprint =
          if record["request_fingerprint"] not in [nil, ""], do: record["request_fingerprint"]

        case merged[id] do
          [seq, previous_identity, previous_fingerprint]
          when seq == source_seq and
                 (is_nil(previous_identity) or is_nil(identity) or previous_identity == identity) and
                 (is_nil(previous_fingerprint) or is_nil(fingerprint) or
                    previous_fingerprint == fingerprint) ->
            Map.put(merged, id, [
              seq,
              if(is_nil(previous_identity), do: identity, else: previous_identity),
              if(is_nil(previous_fingerprint), do: fingerprint, else: previous_fingerprint)
            ])

          _ ->
            Repo.rollback({:import_conflict, "salix_conversation_messages", id})
        end
      end)

    ids = Enum.reject(ids, &(Map.fetch!(existing, &1) == Map.fetch!(merged, &1)))

    if ids != [] do
      values =
        ids
        |> Enum.with_index()
        |> Enum.map_join(",", fn {_id, index} ->
          first = index * 3 + 3
          "($#{first}::text,$#{first + 1}::text,$#{first + 2}::text)"
        end)

      params =
        Enum.flat_map(ids, fn id ->
          [_seq, identity, fingerprint] = Map.fetch!(merged, id)
          [id, identity, fingerprint]
        end)

      Repo.query!(
        "UPDATE salix_conversation_messages m SET request_identity=v.request_identity, " <>
          "request_fingerprint=v.request_fingerprint FROM (VALUES #{values}) " <>
          "AS v(message_id,request_identity,request_fingerprint) " <>
          "WHERE m.group_id=$1 AND m.conversation_id=$2 AND m.message_id=v.message_id",
        [scope.group_id, scope.conversation_id | params]
      )
    end

    :ok
  end

  def import_archives!(scope, archives) do
    for archive <- archives do
      SalixStore.PGAuthorityImport.insert_exact!(
        "salix_conversation_archives",
        [:group_id, :conversation_id, :first_seq],
        %{
          group_id: scope.group_id,
          conversation_id: scope.conversation_id,
          first_seq: archive.first_seq,
          last_seq: archive.last_seq,
          object_key: archive.object_key,
          encoding: archive.encoding
        }
      )
    end

    :ok
  end

  def import_create_requests!(group_id, bindings) do
    rows =
      Enum.map(bindings, fn record ->
        %{
          group_id: group_id,
          request_identity: record["request_identity"],
          conversation_id: record["conversation_id"],
          request_fingerprint: record["request_fingerprint"],
          created_at: record["created_at"],
          task_placement:
            if(is_map(record["task_placement"]), do: encode(record["task_placement"]))
        }
      end)

    SalixStore.PGAuthorityImport.insert_exact_many!(
      "salix_conversation_create_requests",
      [:group_id, :request_identity],
      rows
    )
  end

  def read(%__MODULE__{} = scope), do: load(scope, "", true)
  def read_creation(%__MODULE__{} = scope), do: load(scope, "")

  def create(scope, record), do: execute(prepare_create(scope, record))

  def prepare_create(%__MODULE__{} = scope, record) when is_map(record) do
    now = SystemsClock.system_time(:millisecond)

    record =
      record
      |> Map.put_new("created_at", now)
      |> Map.put_new("updated_at", now)
      |> Map.put_new("message_tail_seq", 0)
      |> Map.put_new("message_head_seq", 0)
      |> Map.put_new("log_start_seq", 0)
      |> Map.put_new("provider_status_version", 0)
      |> Map.put_new("membership_revision", 0)

    %Pending{
      kind: :create,
      scope: scope,
      expected_revision: 0,
      record: canonical(scope, record),
      participants: record["participants"] || []
    }
  end

  def create_with_message(scope, record, message),
    do: execute(prepare_create_with_message(scope, record, message))

  def prepare_create_with_message(%__MODULE__{} = scope, record, message) do
    pending = prepare_create(scope, record)

    message =
      message |> Map.put("request_identity", request_identity(message)) |> Map.put("seq", 1)

    record =
      pending.record
      |> Map.put("message_tail_seq", 1)
      |> Map.put("message_head_seq", 1)
      |> Map.put("updated_at", append_time(pending.record, message))
      |> project_task_message(message)
      |> then(&canonical(scope, &1))

    %{
      pending
      | kind: :create_with_message,
        previous: pending.record,
        record: record,
        message: message
    }
  end

  # Participant lifecycle changes have their own owner, but publish the source
  # membership frontier on this same Repo connection.
  def lock_participant_source!(scope), do: locked(new(scope.group_id, scope.conversation_id))

  def participant_changed!(scope, previous, updated) do
    fields =
      ~w(participant_id actor_type user_id agent_id provider target_key role_label notification_filter state payload source_start_seq delivery_session_name delivery_billing_context deleted_at)

    if Map.take(previous || %{}, fields) != Map.take(updated, fields) do
      conversation_scope = new(scope.group_id, scope.conversation_id)
      {record, revision} = locked(conversation_scope)
      record = Map.update(record, "membership_revision", 1, &((&1 || 0) + 1))
      save(conversation_scope, record, revision + 1)
      publish_targets(conversation_scope, record)
    end

    :ok
  end

  def update(scope, expected_revision, fun) do
    with {:ok, pending} <- prepare_update(scope, expected_revision, fun), do: execute(pending)
  end

  def prepare_update(%__MODULE__{} = scope, {previous, revision}, fun)
      when is_map(previous) and is_function(fun, 1) do
    case fun.(previous) do
      {:error, _} = error ->
        error

      updated when is_map(updated) ->
        {:ok,
         %Pending{
           kind: :update,
           scope: scope,
           expected_revision: revision,
           previous: previous,
           record: canonical(scope, updated)
         }}
    end
  end

  def prepare_update(%__MODULE__{} = scope, expected_revision, fun) when is_function(fun, 1) do
    with {:ok, previous, ^expected_revision} <- read(scope) do
      prepare_update(scope, {previous, expected_revision}, fun)
    else
      {:ok, _, _} -> {:error, :precondition_failed}
      error -> error
    end
  end

  def append(scope, expected_revision, message) do
    with {:ok, pending} <- prepare_append(scope, expected_revision, message), do: execute(pending)
  end

  def reserve(scope, message) do
    with {:ok, pending} <- prepare_reserve(scope, message), do: execute(pending)
  end

  def prepare_reserve(%__MODULE__{} = scope, message) when is_map(message) do
    with {:ok, record, revision} <- read_creation(scope) do
      {:ok,
       %Pending{
         kind: :reserve,
         scope: scope,
         expected_revision: revision,
         previous: record,
         message: Map.put(message, "request_identity", request_identity(message))
       }}
    end
  end

  def prepare_append(%__MODULE__{} = scope, {previous, revision}, message)
      when is_map(previous) and is_map(message) do
    seq = previous["message_tail_seq"] + 1

    message =
      message |> Map.put("request_identity", request_identity(message)) |> Map.put("seq", seq)

    record =
      previous
      |> Map.put("message_tail_seq", seq)
      |> Map.put("message_head_seq", max(previous["message_head_seq"] || 0, 1))
      |> Map.put("updated_at", append_time(previous, message))
      |> project_task_message(message)
      |> then(&canonical(scope, &1))

    {:ok,
     %Pending{
       kind: :append,
       scope: scope,
       expected_revision: revision,
       previous: previous,
       record: record,
       message: message
     }}
  end

  def prepare_append(%__MODULE__{} = scope, expected_revision, message) when is_map(message) do
    with {:ok, previous, _revision} <- read(scope) do
      prepare_append(scope, {previous, expected_revision}, message)
    end
  end

  def execute(%Pending{} = pending), do: transaction(fn -> apply_pending(pending) end)

  def archive_work_page(after_key, limit, idle_before, batch_size)
      when limit in 1..100 and batch_size in 1..1_000 do
    query(
      """
      WITH RECURSIVE candidates(group_id,conversation_id,n) AS (
        (SELECT group_id,conversation_id,1 FROM salix_conversation_messages
         WHERE seq IS NOT NULL AND NOT tombstone AND payload IS NOT NULL AND archive_first_seq IS NULL
           AND (group_id,conversation_id)>($1,$2)
         ORDER BY group_id,conversation_id,seq LIMIT 1)
        UNION ALL
        SELECT hot.group_id,hot.conversation_id,previous.n+1
        FROM candidates previous
        CROSS JOIN LATERAL (
          SELECT group_id,conversation_id FROM salix_conversation_messages
          WHERE seq IS NOT NULL AND NOT tombstone AND payload IS NOT NULL AND archive_first_seq IS NULL
            AND (group_id,conversation_id)>(previous.group_id,previous.conversation_id)
          ORDER BY group_id,conversation_id,seq LIMIT 1
        ) hot
        WHERE previous.n < $3
      )
      SELECT c.group_id,c.conversation_id,
             c.revision > 0 AND c.deleted_at IS NULL AND
               (h.records >= $4 OR h.bytes >= 1000000 OR h.last_activity <= $5)
      FROM candidates candidate
      JOIN salix_conversations c USING (group_id,conversation_id)
      CROSS JOIN LATERAL (
        SELECT count(*) AS records, sum(body_bytes) AS bytes, max(body_updated_at) AS last_activity
        FROM (
          SELECT body_updated_at, octet_length(payload) AS body_bytes FROM salix_conversation_messages
          WHERE group_id=c.group_id AND conversation_id=c.conversation_id
            AND seq IS NOT NULL AND NOT tombstone AND payload IS NOT NULL AND archive_first_seq IS NULL
          ORDER BY seq LIMIT $4
        ) hot
      ) h
      ORDER BY c.group_id,c.conversation_id
      """,
      (after_key || ["", ""]) ++ [limit, batch_size, datetime(idle_before)]
    )
  end

  def prepare_archive(scope, limit) when is_integer(limit) and limit in 1..1_000 do
    with {:ok, cut} <- read_snapshot(fn -> archive_cut(scope, limit) end) do
      case cut do
        :empty ->
          {:ok, :empty}

        %{snapshots: snapshots, revision: revision, previous: previous} ->
          with {:ok, archive} <- ConversationArchive.prepare(scope, snapshots, revision),
               do:
                 {:ok,
                  %Pending{kind: :archive, scope: scope, previous: previous, record: archive}}
      end
    end
  end

  defp archive_cut(scope, limit) do
    with {:ok, _record, revision} <- read(scope) do
      %{rows: hot} =
        Repo.query!(
          "SELECT seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 " <>
            "AND seq IS NOT NULL AND NOT tombstone AND payload IS NOT NULL AND archive_first_seq IS NULL ORDER BY seq LIMIT 1",
          [scope.group_id, scope.conversation_id]
        )

      case hot do
        [] ->
          {:ok, :empty}

        [[seq]] ->
          %{rows: spans} =
            Repo.query!(
              "SELECT first_seq,last_seq,object_key,encoding FROM salix_conversation_archives " <>
                "WHERE group_id=$1 AND conversation_id=$2 AND first_seq <= $3 ORDER BY first_seq DESC LIMIT 1",
              [scope.group_id, scope.conversation_id, seq]
            )

          previous =
            case spans do
              [[_first, last, _key, _encoding] = span] when last >= seq -> span
              _ -> nil
            end

          {first, last} =
            case previous do
              [first, last, _, _] ->
                {first, last}

              nil ->
                %{rows: [[last]]} =
                  Repo.query!(
                    "SELECT COALESCE(min(first_seq)-1,9223372036854775807) FROM salix_conversation_archives " <>
                      "WHERE group_id=$1 AND conversation_id=$2 AND first_seq > $3",
                    [scope.group_id, scope.conversation_id, seq]
                  )

                {seq, last}
            end

          {:ok, snapshots} =
            load_message_snapshots(
              scope,
              """
              m.seq IN (
                SELECT seq FROM (
                  SELECT seq,row_number() OVER (ORDER BY seq) AS position,
                         sum(COALESCE(body_bytes,0)) OVER (ORDER BY seq) AS bytes
                  FROM (
                    SELECT seq,octet_length(payload) AS body_bytes
                    FROM salix_conversation_messages
                    WHERE group_id=$1 AND conversation_id=$2 AND seq BETWEEN $3 AND $4 AND NOT tombstone
                    ORDER BY seq LIMIT $5
                  ) bounded
                ) measured WHERE bytes <= $6 OR position=1
              ) ORDER BY m.seq
              """,
              [first, last, limit, 1_000_000]
            )

          {:ok, %{revision: revision, previous: previous, snapshots: snapshots}}
      end
    end
  end

  def prepare_cleanup_archive_bodies(scope, limit) when is_integer(limit) and limit in 1..1_000 do
    with {:ok, %{rows: rows}} <-
           query(
             "SELECT message_id, revision, archive_first_seq FROM salix_conversation_messages " <>
               "WHERE group_id=$1 AND conversation_id=$2 AND archive_first_seq IS NOT NULL " <>
               "AND payload IS NOT NULL ORDER BY seq LIMIT $3",
             [scope.group_id, scope.conversation_id, limit]
           ) do
      {:ok, %Pending{kind: :cleanup_archive_bodies, scope: scope, message: rows}}
    end
  end

  def prepare_cleanup_archives(scope, limit) when is_integer(limit) and limit in 1..1_000 do
    with {:ok, record, _} <- read(scope),
         true <- not is_nil(record["deleted_at"]),
         {:ok, %{rows: rows}} <-
           query(
             "SELECT first_seq,object_key FROM salix_conversation_archives WHERE group_id=$1 AND conversation_id=$2 ORDER BY first_seq LIMIT $3",
             [scope.group_id, scope.conversation_id, limit]
           ) do
      with {:ok, keys} <- archive_cleanup_keys(scope, rows, limit) do
        if keys == [] do
          {:ok, :empty}
        else
          with :ok <- ConversationArchive.delete_objects(keys),
               do: {:ok, %Pending{kind: :delete_archives, scope: scope, message: rows}}
        end
      end
    else
      false -> {:error, :conversation_not_deleted}
      error -> error
    end
  end

  defp archive_cleanup_keys(scope, [], limit) do
    with {:ok, %{objects: objects}} <-
           S3.list(
             Keys.ctl_group_conversation_messages_segments_prefix(
               scope.group_id,
               scope.conversation_id
             ),
             max_keys: limit
           ) do
      {:ok, Enum.map(objects, & &1.key)}
    end
  end

  defp archive_cleanup_keys(_scope, rows, _limit), do: {:ok, Enum.map(rows, &Enum.at(&1, 1))}

  def prepare_cleanup_messages(scope, limit) when is_integer(limit) and limit in 1..1_000 do
    with {:ok, record, revision} <- read(scope),
         true <- not is_nil(record["deleted_at"]),
         {:ok, %{rows: rows}} <-
           query(
             "SELECT message_id FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2 ORDER BY message_id LIMIT $3",
             [scope.group_id, scope.conversation_id, limit]
           ) do
      {:ok,
       %Pending{
         kind: :cleanup_messages,
         scope: scope,
         expected_revision: revision,
         previous: record,
         message: Enum.map(rows, &hd/1)
       }}
    else
      false -> {:error, :conversation_not_deleted}
      error -> error
    end
  end

  def prepare_finish_delete(scope) do
    with {:ok, record, revision} <- read(scope),
         true <- not is_nil(record["deleted_at"]),
         {:ok, %{objects: []}} <-
           S3.list(
             Keys.ctl_group_conversation_messages_segments_prefix(
               scope.group_id,
               scope.conversation_id
             ),
             max_keys: 1
           ) do
      {:ok,
       %Pending{kind: :finish_delete, scope: scope, expected_revision: revision, previous: record}}
    else
      false -> {:error, :conversation_not_deleted}
      {:ok, _} -> {:error, :archive_cleanup_required}
      error -> error
    end
  end

  def prepare_backfill_message_threads(scope, after_seq)
      when is_integer(after_seq) and after_seq >= 0 do
    with {:ok, record, revision} <- read(scope),
         {:ok, rows} <- messages(scope, after_seq + 1, record["message_tail_seq"], 32),
         {:ok, replacements} <- thread_roots(scope, rows) do
      next_seq = if rows == [], do: after_seq, else: List.last(rows)["seq"]
      changes = Enum.reject(replacements, fn message -> message in rows end)

      result = %{
        after_seq: next_seq,
        updated: length(changes),
        done: next_seq >= record["message_tail_seq"]
      }

      {:ok,
       %Pending{
         kind: :backfill,
         scope: scope,
         expected_revision: revision,
         previous: record,
         record: result,
         message: changes
       }}
    end
  end

  def prepare_backfill_message_threads(_, _), do: {:error, :invalid_message_sequence}

  defp thread_roots(scope, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, resolved} ->
      parent_id = row["reply_to_message_id"]

      root =
        cond do
          is_binary(row["thread_root_message_id"]) ->
            {:ok, row["thread_root_message_id"]}

          is_nil(parent_id) ->
            {:ok, row["message_id"]}

          true ->
            parent =
              case Enum.find(resolved, &(&1["message_id"] == parent_id)) do
                nil -> message_by_id(scope, parent_id)
                parent -> {:ok, parent}
              end

            with {:ok, parent} <- parent,
                 true <- parent["seq"] < row["seq"],
                 root when is_binary(root) <- parent["thread_root_message_id"],
                 do: {:ok, root},
                 else: (
                   false -> {:error, :invalid_reply_target}
                   nil -> {:error, :message_thread_backfill_requires_earlier_batch}
                   error -> error
                 )
        end

      case root do
        {:ok, root} -> {:cont, {:ok, resolved ++ [Map.put(row, "thread_root_message_id", root)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_pending(%Pending{kind: :archive, scope: scope, previous: previous, record: archive}) do
    {record, _revision} = locked(scope)
    if not is_nil(record["deleted_at"]), do: Repo.rollback(:conversation_deleted)

    %{rows: observed} =
      Repo.query!(
        "SELECT first_seq, last_seq, object_key, encoding FROM salix_conversation_archives " <>
          "WHERE group_id=$1 AND conversation_id=$2 AND first_seq <= $3 ORDER BY first_seq DESC LIMIT 1",
        [scope.group_id, scope.conversation_id, archive.last_seq]
      )

    existing =
      Enum.filter(observed, fn [_first, last, _key, _encoding] -> last >= archive.first_seq end)

    descriptor = [archive.first_seq, archive.last_seq, archive.object_key, archive.encoding]

    cond do
      existing == [descriptor] ->
        :ok

      true ->
        expected = if previous, do: [previous], else: []
        if existing != expected, do: Repo.rollback(:archive_conflict)

        if previous do
          [first, last, key, encoding] = previous

          Repo.query!(
            "DELETE FROM salix_conversation_archives WHERE group_id=$1 AND conversation_id=$2 AND first_seq=$3",
            [scope.group_id, scope.conversation_id, first]
          )

          Repo.query!(
            "UPDATE salix_conversation_messages SET archive_first_seq=NULL WHERE group_id=$1 AND conversation_id=$2 AND archive_first_seq=$3 AND seq BETWEEN $3 AND $4 AND tombstone",
            [scope.group_id, scope.conversation_id, first, last]
          )

          if last > archive.last_seq do
            suffix = archive.last_seq + 1

            Repo.query!(
              "INSERT INTO salix_conversation_archives (group_id,conversation_id,first_seq,last_seq,object_key,encoding) VALUES ($1,$2,$3,$4,$5,$6)",
              [scope.group_id, scope.conversation_id, suffix, last, key, encoding]
            )

            Repo.query!(
              "UPDATE salix_conversation_messages SET archive_first_seq=$4 WHERE group_id=$1 AND conversation_id=$2 AND archive_first_seq=$3 AND seq > $5 AND seq <= $6",
              [scope.group_id, scope.conversation_id, first, suffix, archive.last_seq, last]
            )
          end
        end

        Repo.query!(
          "INSERT INTO salix_conversation_archives (group_id,conversation_id,first_seq,last_seq,object_key,encoding) " <>
            "VALUES ($1,$2,$3,$4,$5,$6)",
          [scope.group_id, scope.conversation_id | descriptor]
        )
    end

    for candidate <- archive.candidates do
      Repo.query!(
        "UPDATE salix_conversation_messages SET archive_first_seq=$5, payload=NULL " <>
          "WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3 AND revision=$4 " <>
          "AND NOT tombstone",
        [
          scope.group_id,
          scope.conversation_id,
          candidate.message_id,
          candidate.revision,
          archive.first_seq
        ]
      )
    end

    {:ok, Map.drop(archive, [:candidates])}
  end

  defp apply_pending(%Pending{kind: :cleanup_archive_bodies} = pending) do
    _ = locked(pending.scope)

    for [id, revision, first] <- pending.message do
      Repo.query!(
        "UPDATE salix_conversation_messages SET payload=NULL " <>
          "WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3 AND revision=$4 AND archive_first_seq=$5",
        [pending.scope.group_id, pending.scope.conversation_id, id, revision, first]
      )
    end

    {:ok, if(pending.message == [], do: :empty, else: :more)}
  end

  defp apply_pending(%Pending{kind: :delete_archives} = pending) do
    {record, _revision} = locked(pending.scope)
    if is_nil(record["deleted_at"]), do: Repo.rollback(:conversation_not_deleted)

    for [first, key] <- pending.message do
      Repo.query!(
        "DELETE FROM salix_conversation_archives WHERE group_id=$1 AND conversation_id=$2 AND first_seq=$3 AND object_key=$4",
        [pending.scope.group_id, pending.scope.conversation_id, first, key]
      )
    end

    {:ok, :more}
  end

  defp apply_pending(%Pending{kind: :cleanup_messages} = pending) do
    {record, revision} = locked(pending.scope)
    expect_revision(revision, pending.expected_revision)
    if is_nil(record["deleted_at"]), do: Repo.rollback(:conversation_not_deleted)

    Repo.query!(
      "DELETE FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2 AND message_id = ANY($3::text[])",
      [pending.scope.group_id, pending.scope.conversation_id, pending.message]
    )

    {:ok, if(pending.message == [], do: :empty, else: :more)}
  end

  defp apply_pending(%Pending{kind: :finish_delete} = pending) do
    {record, revision} = locked(pending.scope)
    expect_revision(revision, pending.expected_revision)
    if is_nil(record["deleted_at"]), do: Repo.rollback(:conversation_not_deleted)

    %{rows: [[archives, messages]]} =
      Repo.query!(
        "SELECT EXISTS(SELECT 1 FROM salix_conversation_archives WHERE group_id = $1 AND conversation_id = $2), EXISTS(SELECT 1 FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2)",
        [pending.scope.group_id, pending.scope.conversation_id]
      )

    if archives, do: Repo.rollback(:archive_cleanup_required)
    if messages, do: Repo.rollback(:message_cleanup_incomplete)

    SalixStore.TaskFiles.delete_conversation!(
      pending.scope.group_id,
      pending.scope.conversation_id
    )

    Repo.query!(
      "DELETE FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2",
      [pending.scope.group_id, pending.scope.conversation_id]
    )

    :ok
  end

  defp apply_pending(%Pending{kind: :backfill} = pending) do
    {_record, revision} = locked(pending.scope)
    expect_revision(revision, pending.expected_revision)

    for message <- pending.message do
      Repo.query!(
        "UPDATE salix_conversation_messages SET payload = $4, revision = revision + 1, archive_first_seq = NULL, body_updated_at=$5 WHERE group_id = $1 AND conversation_id = $2 AND message_id = $3",
        [
          pending.scope.group_id,
          pending.scope.conversation_id,
          message["message_id"],
          encode(message),
          datetime(SystemsClock.system_time(:millisecond))
        ]
      )
    end

    if pending.message != [] do
      save(pending.scope, pending.previous, revision + 1)
      search_target!(pending.scope, pending.previous, :rebuild)
    end

    {:ok, pending.record}
  end

  defp apply_pending(%Pending{kind: :create, scope: scope, record: record} = pending) do
    {:ok, :inserted, record, revision} = insert_conversation(scope, record)
    SalixIM.ConversationParticipantPGStore.insert_initial!(scope, pending.participants || [])
    if is_nil(pending.message), do: search_target!(scope, record, :rebuild)
    {:ok, :inserted, record, revision}
  end

  defp apply_pending(%Pending{kind: :create_with_message} = pending) do
    {:ok, :inserted, record, revision} = apply_pending(%{pending | kind: :create})
    bind_local_refs!(pending, pending.message)
    publish_message(pending.scope, pending.message, nil)
    task_files!(pending.scope, nil, record, pending.message)
    search_target!(pending.scope, record, :message, pending.message)
    {:ok, :inserted, record, inserted_message(pending.message), revision}
  end

  defp apply_pending(%Pending{kind: :update} = pending) do
    {_previous, revision} = locked(pending.scope)
    expect_revision(revision, pending.expected_revision)

    if pending.previous == pending.record do
      {:ok, pending.previous, pending.record, revision}
    else
      save(pending.scope, pending.record, revision + 1)
      task_files!(pending.scope, pending.previous, pending.record, nil)
      search_target!(pending.scope, pending.record, :rebuild)

      if Map.take(
           pending.previous,
           ~w(message_tail_seq provider_status_version membership_revision)
         ) !=
           Map.take(
             pending.record,
             ~w(message_tail_seq provider_status_version membership_revision)
           ),
         do: publish_targets(pending.scope, pending.record)

      {:ok, pending.previous, pending.record, revision + 1}
    end
  end

  defp apply_pending(%Pending{kind: :append} = pending) do
    {conversation, revision} = locked(pending.scope)

    case existing_message(pending.scope, pending.message) do
      {:ok, existing} ->
        cond do
          not same_request?(existing, pending.message) ->
            Repo.rollback(conflict(existing, pending.message))

          is_integer(existing["seq"]) ->
            {:ok, :exists, conversation, existing, revision}

          true ->
            expect_revision(revision, pending.expected_revision)
            append_new(pending, existing)
        end

      {:error, :not_found} ->
        expect_revision(revision, pending.expected_revision)
        append_new(pending)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_pending(%Pending{kind: :reserve} = pending) do
    {conversation, revision} = locked(pending.scope)
    if not is_nil(conversation["deleted_at"]), do: Repo.rollback(:not_found)

    case existing_message(pending.scope, pending.message) do
      {:ok, existing} ->
        if same_request?(existing, pending.message),
          do: {:ok, :exists, conversation, existing, revision},
          else: Repo.rollback(conflict(existing, pending.message))

      {:error, :not_found} ->
        message = pending.message

        Repo.query!(
          """
          INSERT INTO salix_conversation_messages
            (group_id, conversation_id, message_id, request_identity, request_fingerprint, revision, payload)
          VALUES ($1, $2, $3, $4, $5, 1, $6)
          """,
          [
            pending.scope.group_id,
            pending.scope.conversation_id,
            message["message_id"],
            message["request_identity"],
            message["request_fingerprint"],
            encode(Map.take(message, ["created_at"]))
          ]
        )

        {:ok, :reserved, conversation, identity(Map.put(message, "seq", nil), 1, false, nil),
         revision}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_conversation(scope, record) do
    result =
      Repo.query!(
        """
        INSERT INTO salix_conversations
          (group_id, conversation_id, revision, metadata, kind, updated_at,
           message_tail_seq, message_head_seq, log_start_seq, provider_status_version,
           membership_revision, deleted_at, status, list_timestamp)
        VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ON CONFLICT (group_id, conversation_id) DO NOTHING RETURNING revision
        """,
        [scope.group_id, scope.conversation_id | metadata_values(record)]
      )

    case result.rows do
      [[revision]] ->
        publish_targets(scope, record)
        {:ok, :inserted, record, revision}

      [] ->
        Repo.rollback(:precondition_failed)
    end
  end

  def settle(%Pending{} = pending) do
    transaction(fn ->
      case load(pending.scope, " FOR UPDATE") do
        {:ok, record, revision} ->
          settle_observed(pending, record, revision)

        {:error, :not_found}
        when pending.kind in [:create, :create_with_message] ->
          retry_frozen(pending)

        {:error, :not_found} when pending.kind == :finish_delete ->
          :ok

        {:error, :not_found} ->
          {:error, :precondition_failed}

        {:error, _} ->
          {:error, :commit_indeterminate}
      end
    end)
  end

  defp settle_observed(%Pending{kind: :finish_delete} = pending, _record, revision) do
    if revision == pending.expected_revision,
      do: retry_frozen(pending),
      else: {:error, :precondition_failed}
  end

  defp settle_observed(%Pending{kind: kind} = pending, _record, _revision)
       when kind in [:archive, :cleanup_archive_bodies, :delete_archives],
       do: retry_frozen(pending)

  defp settle_observed(%Pending{kind: :cleanup_messages} = pending, _record, revision) do
    if revision == pending.expected_revision,
      do: retry_frozen(pending),
      else: {:error, :precondition_failed}
  end

  defp settle_observed(%Pending{kind: :backfill} = pending, _record, revision) do
    cond do
      revision == pending.expected_revision ->
        retry_frozen(pending)

      revision == pending.expected_revision + 1 ->
        if Enum.all?(pending.message, fn expected ->
             case Repo.query!(
                    "SELECT payload, archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3 AND NOT tombstone",
                    [
                      pending.scope.group_id,
                      pending.scope.conversation_id,
                      expected["message_id"]
                    ]
                  ) do
               %{rows: [[payload, nil]]} when is_binary(payload) -> decode(payload) == expected
               _ -> false
             end
           end), do: {:ok, pending.record}, else: {:error, :precondition_failed}

      true ->
        {:error, :precondition_failed}
    end
  end

  defp settle_observed(%Pending{kind: kind} = pending, record, revision)
       when kind in [:append, :reserve, :create_with_message] do
    case existing_message(pending.scope, pending.message) do
      {:ok, identity} ->
        cond do
          not same_request?(identity, pending.message) ->
            {:error, conflict(identity, pending.message)}

          kind == :reserve or is_integer(identity["seq"]) ->
            {:ok, :exists, record, identity, revision}

          revision == pending.expected_revision ->
            retry_frozen(pending)

          true ->
            {:error, :precondition_failed}
        end

      {:error, :not_found} when kind == :reserve or revision == pending.expected_revision ->
        retry_frozen(pending)

      {:error, :not_found} ->
        {:error, :precondition_failed}

      {:error, _} ->
        {:error, :commit_indeterminate}
    end
  end

  defp settle_observed(pending, record, revision) do
    cond do
      revision == pending.expected_revision + 1 and record == pending.record ->
        case pending.kind do
          :create -> {:ok, :inserted, record, revision}
          :update -> {:ok, pending.previous, record, revision}
        end

      revision == pending.expected_revision ->
        retry_frozen(pending)

      true ->
        {:error, :precondition_failed}
    end
  end

  defp retry_frozen(pending), do: apply_pending(pending)

  def message_by_id(%__MODULE__{} = scope, message_id),
    do: visible_message(message(scope, "message_id = $3", message_id))

  def message_by_seq(%__MODULE__{} = scope, seq),
    do: visible_message(message(scope, "seq = $3", seq))

  def message_by_request_identity(%__MODULE__{} = scope, identity),
    do: visible_message(message(scope, "request_identity = $3", normalize_identity(identity)))

  def identity_by_id(%__MODULE__{} = scope, id), do: read_identity(scope, "message_id = $3", id)

  def identity_by_request_identity(%__MODULE__{} = scope, identity),
    do: read_identity(scope, "request_identity = $3", normalize_identity(identity))

  def messages(%__MODULE__{} = scope, first_seq, last_seq, limit)
      when is_integer(first_seq) and is_integer(last_seq) and is_integer(limit) and
             limit in 0..1_000 do
    with {:ok, snapshots} <-
           message_snapshots(
             scope,
             "m.seq BETWEEN $3 AND $4 ORDER BY m.seq LIMIT $5",
             [first_seq, last_seq, limit]
           ) do
      ConversationArchive.hydrate_many(snapshots)
    end
  end

  def message_from_snapshot(snapshot), do: ConversationArchive.hydrate(snapshot)

  def message_snapshots(scope, condition, values) do
    read_snapshot(fn -> load_message_snapshots(scope, condition, values) end)
  end

  defp load_message_snapshots(scope, condition, values) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT m.seq, m.message_id, m.request_identity, m.request_fingerprint,
               m.revision, m.payload, m.tombstone, m.archive_first_seq,
               a.last_seq, a.object_key, a.encoding
        FROM salix_conversation_messages m
        JOIN salix_conversations c USING (group_id, conversation_id)
        LEFT JOIN salix_conversation_archives a
          ON a.group_id = m.group_id AND a.conversation_id = m.conversation_id
             AND a.first_seq = m.archive_first_seq
        WHERE m.group_id = $1 AND m.conversation_id = $2
          AND c.revision > 0 AND c.deleted_at IS NULL AND m.seq IS NOT NULL AND
        """ <> condition,
        [scope.group_id, scope.conversation_id | values]
      )

    {:ok, Enum.map(rows, &decode_message_snapshot/1)}
  end

  defp decode_message_snapshot([
         seq,
         id,
         identity,
         fingerprint,
         revision,
         payload,
         tombstone,
         first,
         last,
         key,
         encoding
       ]),
       do: %{
         seq: seq,
         message_id: id,
         request_identity: identity,
         request_fingerprint: fingerprint,
         revision: revision,
         payload: payload,
         tombstone: tombstone,
         archive_first_seq: first,
         archive_last_seq: last,
         object_key: key,
         encoding: encoding
       }

  defp read_identity(scope, condition, value) do
    case query(
           "SELECT seq, message_id, request_identity, request_fingerprint, revision, tombstone, archive_first_seq " <>
             "FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2 AND " <>
             condition,
           [scope.group_id, scope.conversation_id, value]
         ) do
      {:ok, %{rows: [[seq, id, identity, fingerprint, revision, tombstone, archive]]}} ->
        {:ok,
         identity(
           %{
             "seq" => seq,
             "message_id" => id,
             "request_identity" => identity,
             "request_fingerprint" => fingerprint
           },
           revision,
           tombstone,
           archive
         )}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp identity(message, revision, tombstone, archive) do
    message
    |> Map.take(~w(seq message_id request_identity request_fingerprint))
    |> Map.merge(%{
      "revision" => revision,
      "tombstone" => tombstone,
      "archive_first_seq" => archive
    })
  end

  defp inserted_message(message) do
    fields = Map.new(~w(seq message_id request_identity request_fingerprint), &{&1, message[&1]})
    Map.put(identity(message, 1, false, nil), :appended_message, Map.merge(message, fields))
  end

  defp visible_message({:error, :message_deleted}), do: {:error, :not_found}
  defp visible_message(result), do: result

  defp append_new(pending, reservation \\ nil)

  defp append_new(
         %Pending{
           scope: scope,
           previous: conversation,
           record: updated,
           message: message,
           expected_revision: revision
         } = pending,
         reservation
       ) do
    if not is_nil(conversation["deleted_at"]), do: Repo.rollback(:not_found)
    message = reserved_message(scope, message, reservation)

    updated =
      updated
      |> Map.put("updated_at", append_time(conversation, message))
      |> project_task_message(message)

    next = revision + 1

    bind_local_refs!(pending, message)
    publish_message(scope, message, reservation)
    task_files!(scope, conversation, updated, message)

    save(scope, updated, next)
    publish_targets(scope, updated)
    search_target!(scope, updated, :message, message)
    {:ok, :inserted, updated, inserted_message(message), next}
  end

  # The Task file index (`SalixIM.TaskFiles`) commits with the Message it
  # indexes and takes the Task's new title with the change that sets it.
  defp task_files!(scope, previous, %{"kind" => "agent_task"} = record, message) do
    if message,
      do:
        SalixStore.TaskFiles.put!(
          scope.group_id,
          scope.conversation_id,
          SalixIM.TaskFiles.rows(record, message)
        )

    title = SalixIM.TaskFiles.title(record)

    if previous && SalixIM.TaskFiles.title(previous) != title,
      do: SalixStore.TaskFiles.retitle!(scope.group_id, scope.conversation_id, title)

    :ok
  end

  defp task_files!(_scope, _previous, _record, _message), do: :ok

  # Indexes Messages a release before the Task file index appended
  # (`SalixIM.TaskFiles.backfill_page/1`). The Conversation row is held while
  # the rows are written, so a rename or final deletion cannot interleave; a
  # deleted Conversation or one that is not a Task gets none.
  def index_task_files(_scope, []), do: :ok

  def index_task_files(%__MODULE__{} = scope, messages) when is_list(messages) do
    transaction(fn ->
      case load(scope, " FOR SHARE") do
        {:ok, %{"kind" => "agent_task", "deleted_at" => nil} = record, _revision} ->
          SalixStore.TaskFiles.put!(
            scope.group_id,
            scope.conversation_id,
            Enum.flat_map(messages, &SalixIM.TaskFiles.rows(record, &1))
          )

        {:ok, _not_a_live_task, _revision} ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp bind_local_refs!(pending, message) do
    case SalixIM.Ports.LocalFileRefs.bind_message(
           pending.scope.group_id,
           pending.scope.conversation_id,
           message,
           SystemsClock.system_time(:millisecond)
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp publish_message(scope, message, reservation) do
    if reservation do
      Repo.query!(
        """
        UPDATE salix_conversation_messages SET seq = $4, payload = $5, body_updated_at=$6
        WHERE group_id = $1 AND conversation_id = $2 AND message_id = $3 AND seq IS NULL
        """,
        [
          scope.group_id,
          scope.conversation_id,
          message["message_id"],
          message["seq"],
          encode(message),
          datetime(SystemsClock.system_time(:millisecond))
        ]
      )
    else
      insert_message(scope, message)
    end
  end

  defp insert_message(scope, message) do
    Repo.query!(
      """
      INSERT INTO salix_conversation_messages
        (group_id, conversation_id, seq, message_id, request_identity, request_fingerprint, revision, payload, body_updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 1, $7, $8)
      """,
      [
        scope.group_id,
        scope.conversation_id,
        message["seq"],
        message["message_id"],
        message["request_identity"],
        message["request_fingerprint"],
        encode(message),
        datetime(SystemsClock.system_time(:millisecond))
      ]
    )
  end

  defp reserved_message(_scope, message, nil), do: message

  defp reserved_message(scope, message, reservation) do
    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT payload FROM salix_conversation_messages " <>
          "WHERE group_id = $1 AND conversation_id = $2 AND message_id = $3 AND seq IS NULL",
        [scope.group_id, scope.conversation_id, reservation["message_id"]]
      )

    message
    |> Map.update("thread_root_message_id", reservation["message_id"], fn root ->
      if root == message["message_id"], do: reservation["message_id"], else: root
    end)
    |> Map.put("message_id", reservation["message_id"])
    |> Map.put("created_at", decode(payload)["created_at"])
  end

  defp append_time(conversation, message) do
    if is_map(message["provider_status"]) or is_map(message["provider_effect"]),
      do: conversation["updated_at"],
      else: max(conversation["updated_at"] + 1, message["created_at"] || 0)
  end

  defp project_task_message(%{"kind" => "agent_task"} = conversation, message) do
    if SalixIM.TaskCardProjection.output_message?(message),
      do: Map.put(conversation, "task_public_output_message_id", message["message_id"]),
      else: conversation
  end

  defp project_task_message(conversation, _message), do: conversation

  defp existing_message(scope, incoming) do
    case request_identity(incoming) do
      nil ->
        identity_by_id(scope, incoming["message_id"])

      identity ->
        case identity_by_request_identity(scope, identity) do
          {:error, :not_found} -> identity_by_id(scope, incoming["message_id"])
          result -> result
        end
    end
  end

  defp same_request?(existing, incoming) do
    same_identity =
      case request_identity(incoming) do
        nil -> existing["message_id"] == incoming["message_id"]
        identity -> existing["request_identity"] == identity
      end

    same_identity and existing["request_fingerprint"] == incoming["request_fingerprint"]
  end

  defp conflict(existing, incoming) do
    if request_identity(incoming) != nil and
         existing["request_identity"] == request_identity(incoming),
       do: :idempotency_conflict,
       else: :message_id_collision
  end

  defp message(scope, condition, value) do
    case message_snapshots(scope, "m." <> condition, [value]) do
      {:ok, [snapshot]} -> message_from_snapshot(snapshot)
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  def decode_projection(group_id, conversation_id, metadata, columns) do
    columns =
      Map.new(columns, fn {key, value} ->
        key = to_string(key)

        value =
          if key in ["updated_at", "deleted_at"] and not is_nil(value) and not is_integer(value),
            do: milliseconds(value),
            else: value

        {key, value}
      end)

    canonical(new(group_id, conversation_id), Map.merge(decode(metadata), columns))
  end

  defp load(scope, lock, published_only \\ false) do
    case query(
           """
           SELECT revision, metadata, kind, updated_at, message_tail_seq, message_head_seq,
                  log_start_seq, provider_status_version, membership_revision, deleted_at
           FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2
           """ <> if(published_only, do: " AND revision > 0", else: "") <> lock,
           [scope.group_id, scope.conversation_id]
         ) do
      {:ok,
       %{
         rows: [
           [revision, payload, kind, updated, tail, head, start, status, membership, deleted]
         ]
       }} ->
        record =
          decode_projection(scope.group_id, scope.conversation_id, payload, %{
            "kind" => kind,
            "updated_at" => updated,
            "message_tail_seq" => tail,
            "message_head_seq" => head,
            "log_start_seq" => start,
            "provider_status_version" => status,
            "membership_revision" => membership,
            "deleted_at" => deleted
          })

        {:ok, record, revision}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp locked(scope) do
    case load(scope, " FOR UPDATE") do
      {:ok, record, revision} -> {record, revision}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp expect_revision(revision, revision), do: :ok
  defp expect_revision(_, _), do: Repo.rollback(:precondition_failed)

  defp save(scope, record, revision) do
    Repo.query!(
      """
      UPDATE salix_conversations
      SET revision = $3, metadata = $4, kind = $5, updated_at = $6,
          message_tail_seq = $7, message_head_seq = $8, log_start_seq = $9,
          provider_status_version = $10, membership_revision = $11, deleted_at = $12,
          status = $13, list_timestamp = $14
      WHERE group_id = $1 AND conversation_id = $2
      """,
      [scope.group_id, scope.conversation_id, revision | metadata_values(record)]
    )
  end

  defp search_target!(scope, record, operation, message \\ nil) do
    operation =
      if not is_nil(record["deleted_at"]) or record["kind"] != "agent_task",
        do: :delete,
        else: operation

    SalixStore.ConversationSearch.enqueue_source!(
      scope.group_id,
      scope.conversation_id,
      operation,
      if(operation == :message, do: message["message_id"]),
      if(operation == :message, do: message["seq"])
    )
  end

  defp publish_targets(scope, record) do
    Repo.query!(
      """
      INSERT INTO conversation_log_recovery
        (group_id, conversation_id, target_seq, due_at_ms, status_version, membership_revision)
      VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (group_id, conversation_id) DO UPDATE
      SET target_seq = GREATEST(conversation_log_recovery.target_seq, EXCLUDED.target_seq),
          status_version = GREATEST(conversation_log_recovery.status_version, EXCLUDED.status_version),
          membership_revision = GREATEST(conversation_log_recovery.membership_revision, EXCLUDED.membership_revision)
      """,
      [
        scope.group_id,
        scope.conversation_id,
        record["message_tail_seq"],
        SystemsClock.system_time(:millisecond),
        record["provider_status_version"],
        record["membership_revision"]
      ]
    )
  end

  defp metadata_values(record) do
    [
      encode(Map.drop(record, @columns)),
      record["kind"],
      datetime(record["updated_at"]),
      record["message_tail_seq"],
      record["message_head_seq"] || 0,
      record["log_start_seq"],
      record["provider_status_version"],
      record["membership_revision"],
      datetime(record["deleted_at"]),
      record["status"],
      SalixIM.TaskArchive.list_timestamp(record)
    ]
  end

  defp canonical(%__MODULE__{} = scope, record) do
    record
    |> Map.drop(~w(participants participant_count messages revision))
    |> Map.put("agent_group_id", scope.group_id)
    |> Map.put("conversation_id", scope.conversation_id)
    |> Map.put("message_count", record["message_tail_seq"])
    |> Map.put("target_message_count", record["message_tail_seq"])
    |> Map.put_new("deleted_at", nil)
  end

  defp request_identity(message), do: normalize_identity(message["request_identity"])
  defp normalize_identity(nil), do: nil

  defp normalize_identity(value) do
    case String.trim(value) do
      "" -> nil
      identity -> identity
    end
  end

  defp encode(value), do: :erlang.term_to_binary(value)
  defp decode(value), do: :erlang.binary_to_term(value, [:safe])
  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.from_unix!(value, :millisecond)
  defp milliseconds(value), do: DateTime.to_unix(value, :millisecond)

  defp read_snapshot(fun) do
    case Repo.transaction(fn ->
           Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
           fun.()
         end) do
      {:ok, result} -> result
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code not in [:admin_shutdown, :crash_shutdown, :cannot_connect_now] ->
          {:error, {:rollback, code}}

        _ ->
          {:error, :commit_indeterminate}
      end

    _error in DBConnection.ConnectionError ->
      {:error, :commit_indeterminate}
  catch
    :exit, _ -> {:error, :commit_indeterminate}
  end

  defp query(sql, params) do
    Repo.query(sql, params)
  rescue
    _error in DBConnection.ConnectionError -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
