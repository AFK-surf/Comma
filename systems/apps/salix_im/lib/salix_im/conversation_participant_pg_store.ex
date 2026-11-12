defmodule SalixIM.ConversationParticipantPGStore do
  @moduledoc false
  alias SalixStore.Repo

  defmodule Pending do
    @moduledoc false
    @derive {Inspect, only: [:kind, :scope, :expected_revision]}
    defstruct [:kind, :scope, :expected_revision, :record, :result, :delivery_id]
  end

  def new(group_id, conversation_id, participant_id),
    do: %{group_id: group_id, conversation_id: conversation_id, participant_id: participant_id}

  def read(scope), do: snapshot(scope, nil, "")
  def read_delivery(scope, id), do: snapshot(scope, id, "")

  def import_participants!(scope, facts),
    do: import_participants!(Enum.map(facts, &Map.put(&1, :scope, scope)))

  def import_participants!(facts) do
    columns =
      ~w(revision payload delivery_log_cursor_seq incarnation delivery_fence cutoff_seq deleted_at actor_type agent_id session_id state source_start_seq receives_messages)a

    rows =
      Enum.map(facts, fn fact ->
        record = fact.record
        values = Map.new(Enum.zip(columns, participant_values(record, fact.revision)))

        Map.merge(values, %{
          group_id: fact.scope.group_id,
          conversation_id: fact.scope.conversation_id,
          participant_id: record["participant_id"]
        })
      end)

    SalixStore.PGAuthorityImport.insert_exact_many!(
      "salix_conversation_participants",
      [:group_id, :conversation_id, :participant_id],
      rows
    )
  end

  def import_receipts!(scope, facts),
    do: import_receipts!(Enum.map(facts, &Map.put(&1, :scope, scope)))

  def import_receipts!(facts) do
    rows =
      Enum.map(facts, fn fact ->
        record = fact.record

        %{
          group_id: fact.scope.group_id,
          conversation_id: fact.scope.conversation_id,
          participant_id: record["participant_id"],
          delivery_id: record["delivery_id"],
          revision: fact.revision,
          status: record["status"],
          payload: encode(record)
        }
      end)

    SalixStore.PGAuthorityImport.insert_exact_many!(
      "salix_conversation_deliveries",
      [:group_id, :conversation_id, :participant_id, :delivery_id],
      rows
    )
  end

  def page(group, conversation, after_id, limit) when limit in 1..1001 do
    case query(
           "SELECT payload FROM salix_conversation_participants WHERE group_id = $1 AND conversation_id = $2 AND participant_id COLLATE \"C\" > $3 AND deleted_at IS NULL ORDER BY participant_id COLLATE \"C\" LIMIT $4",
           [group, conversation, after_id || "", limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [body] -> decode(body) end)}
      _ -> {:error, :unavailable}
    end
  end

  def prepare(scope, expected, record, result, delivery_id \\ nil),
    do: %Pending{
      kind: if(is_nil(delivery_id), do: :participant, else: :receipt),
      scope: scope,
      expected_revision: expected || 0,
      record: canonical(scope, record, delivery_id),
      result: result,
      delivery_id: delivery_id
    }

  def execute(%Pending{} = pending), do: transaction(fn -> apply_pending(pending) end)

  def settle(%Pending{} = pending) do
    transaction(fn ->
      lock_source(pending)

      case snapshot(pending.scope, pending.delivery_id, " FOR UPDATE") do
        {:ok, record, revision} when revision == pending.expected_revision + 1 ->
          if record == pending.record,
            do: result(pending, revision),
            else: {:error, :precondition_failed}

        {:ok, _record, revision} when revision == pending.expected_revision ->
          apply_pending(pending)

        {:error, :not_found} when pending.expected_revision == 0 ->
          apply_pending(pending)

        {:error, :unavailable} ->
          {:error, :commit_indeterminate}

        _ ->
          {:error, :precondition_failed}
      end
    end)
  end

  # Only an explicit Conversation create calls this, on its checked-out Repo
  # connection. It installs the already validated initial facts, with no Actor RPC.
  def insert_initial!(scope, participants) do
    for participant <- participants do
      participant_scope =
        new(scope.group_id, scope.conversation_id, participant["participant_id"])

      insert!(prepare(participant_scope, 0, participant, :inserted), 1)
    end

    :ok
  end

  def cleanup(scope, limit) when limit in 1..1000 do
    transaction(fn ->
      case snapshot(scope, nil, " FOR UPDATE") do
        {:error, :not_found} ->
          :done

        {:ok, %{"deleted_at" => deleted}, _} when not is_nil(deleted) ->
          %{rows: rows} =
            Repo.query!(
              "DELETE FROM salix_conversation_deliveries WHERE (group_id, conversation_id, participant_id, delivery_id) IN (SELECT group_id, conversation_id, participant_id, delivery_id FROM salix_conversation_deliveries WHERE group_id = $1 AND conversation_id = $2 AND participant_id = $3 ORDER BY delivery_id LIMIT $4) RETURNING delivery_id",
              params(scope) ++ [limit]
            )

          if rows == [] do
            Repo.query!(
              "DELETE FROM salix_conversation_participants WHERE group_id = $1 AND conversation_id = $2 AND participant_id = $3",
              params(scope)
            )

            :done
          else
            :more
          end

        {:ok, _, _} ->
          {:error, :participant_not_deleted}

        error ->
          error
      end
    end)
  end

  defp apply_pending(pending) do
    lock_source(pending)

    case snapshot(pending.scope, pending.delivery_id, " FOR UPDATE") do
      {:ok, record, revision} ->
        cond do
          pending.result == :inserted and is_nil(pending.delivery_id) ->
            if record == pending.record,
              do: {:ok, :exists, record},
              else: Repo.rollback({:participant_id_collision, pending.scope.participant_id})

          revision != pending.expected_revision ->
            Repo.rollback(:precondition_failed)

          record == pending.record ->
            result(pending, revision)

          true ->
            update!(pending, revision + 1)
            publish_membership(pending, record)
            result(pending, revision + 1)
        end

      {:error, :not_found} when pending.expected_revision == 0 ->
        insert!(pending, 1)
        publish_membership(pending, nil)
        result(pending, 1)

      {:error, :not_found} ->
        Repo.rollback(:not_found)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp lock_source(%{kind: :participant, scope: scope}),
    do: SalixIM.ConversationPGStore.lock_participant_source!(scope)

  defp lock_source(_), do: :ok

  defp publish_membership(%{kind: :participant} = pending, previous),
    do: SalixIM.ConversationPGStore.participant_changed!(pending.scope, previous, pending.record)

  defp publish_membership(_pending, _previous), do: :ok

  defp snapshot(scope, id, lock) do
    {table, condition, values} =
      if is_nil(id),
        do: {"salix_conversation_participants", "", params(scope)},
        else: {"salix_conversation_deliveries", " AND delivery_id = $4", params(scope) ++ [id]}

    case query(
           "SELECT payload, revision FROM " <>
             table <>
             " WHERE group_id = $1 AND conversation_id = $2 AND participant_id = $3" <>
             condition <> lock,
           values
         ) do
      {:ok, %{rows: [[body, revision]]}} -> {:ok, decode(body), revision}
      {:ok, %{rows: []}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp insert!(%{kind: :participant} = pending, revision) do
    %{rows: rows} =
      Repo.query!(
        "INSERT INTO salix_conversation_participants (group_id, conversation_id, participant_id, revision, payload, delivery_log_cursor_seq, incarnation, delivery_fence, cutoff_seq, deleted_at, actor_type, agent_id, session_id, state, source_start_seq, receives_messages) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16) ON CONFLICT DO NOTHING RETURNING revision",
        params(pending.scope) ++ participant_values(pending.record, revision)
      )

    if rows == [], do: Repo.rollback(:precondition_failed)
  end

  defp insert!(%{kind: :receipt} = pending, revision) do
    %{rows: rows} =
      Repo.query!(
        "INSERT INTO salix_conversation_deliveries (group_id, conversation_id, participant_id, delivery_id, revision, status, payload) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING RETURNING revision",
        params(pending.scope) ++
          [
            pending.delivery_id,
            revision,
            pending.record["status"] || "pending",
            encode(pending.record)
          ]
      )

    if rows == [], do: Repo.rollback(:precondition_failed)
  end

  defp update!(%{kind: :participant} = pending, revision) do
    Repo.query!(
      "UPDATE salix_conversation_participants SET revision=$4,payload=$5,delivery_log_cursor_seq=$6,incarnation=$7,delivery_fence=$8,cutoff_seq=$9,deleted_at=$10,actor_type=$11,agent_id=$12,session_id=$13,state=$14,source_start_seq=$15,receives_messages=$16 WHERE group_id=$1 AND conversation_id=$2 AND participant_id=$3",
      params(pending.scope) ++ participant_values(pending.record, revision)
    )
  end

  defp update!(%{kind: :receipt} = pending, revision) do
    Repo.query!(
      "UPDATE salix_conversation_deliveries SET revision=$5,status=$6,payload=$7 WHERE group_id=$1 AND conversation_id=$2 AND participant_id=$3 AND delivery_id=$4",
      params(pending.scope) ++
        [
          pending.delivery_id,
          revision,
          pending.record["status"] || "pending",
          encode(pending.record)
        ]
    )
  end

  defp participant_values(record, revision) do
    fence = record["task_thread_delivery_fence"] || %{}

    [
      revision,
      encode(record),
      record["delivery_log_cursor_seq"] || 0,
      get_in(record, ["payload", "task_thread_binding_token"]),
      fence["fence_token"],
      fence["cutoff_seq"],
      datetime(record["deleted_at"]),
      record["actor_type"],
      record["agent_id"],
      if(record["actor_type"] == "agent", do: get_in(record, ["payload", "session_id"])),
      record["state"],
      record["source_start_seq"],
      SalixIM.ConversationSource.receives_messages?(record)
    ]
  end

  defp result(%{result: :receipt}, revision), do: {:ok, %{etag: revision}}
  defp result(%{result: :inserted, record: record}, _), do: {:ok, :inserted, record}
  defp result(%{result: :updated, record: record}, _), do: {:ok, record}
  defp result(%{result: status, record: record}, _), do: {:ok, status, record}

  defp canonical(scope, record, nil),
    do:
      record
      |> Map.put("participant_id", scope.participant_id)
      |> Map.put("conversation_id", scope.conversation_id)

  defp canonical(scope, record, id),
    do:
      canonical(scope, record, nil)
      |> Map.put("agent_group_id", scope.group_id)
      |> Map.put("delivery_id", id)

  defp params(scope), do: [scope.group_id, scope.conversation_id, scope.participant_id]
  defp encode(value), do: :erlang.term_to_binary(value)
  defp decode(value), do: :erlang.binary_to_term(value, [:safe])
  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.from_unix!(value, :millisecond)

  defp query(sql, values) do
    Repo.query(sql, values)
  rescue
    _ in DBConnection.ConnectionError -> {:error, :unavailable}
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

    _ in DBConnection.ConnectionError ->
      {:error, :commit_indeterminate}
  catch
    :exit, _ -> {:error, :commit_indeterminate}
  end
end
