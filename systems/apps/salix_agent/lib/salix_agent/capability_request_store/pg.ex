defmodule SalixAgent.CapabilityRequestStore.PG do
  @moduledoc "PostgreSQL storage for capability requests and their result delivery."

  alias SalixStore.{Codec, Repo}

  @columns "revision, payload, result_delivery_due_at, result_delivered_at"
  @page_limit 500

  @doc "Import frozen legacy facts on the release transaction's connection."
  def import_record!(record, delivery) do
    due =
      if delivery == :due,
        do: DateTime.from_unix!(record["updated_at"] || record["created_at"] || 0)

    delivered =
      case delivery do
        {:acknowledged, at} -> at
        _ -> nil
      end

    SalixStore.PGAuthorityImport.insert_exact!(
      "salix_capability_requests",
      ["group_id", "request_id"],
      %{
        "group_id" => Map.fetch!(record, "group_id"),
        "request_id" => Map.fetch!(record, "request_id"),
        "tenant_id" => Map.fetch!(record, "tenant_id"),
        "request_type" => Map.fetch!(record, "request_type"),
        "status" => Map.fetch!(record, "status"),
        "expires_at" => DateTime.from_unix!(Map.fetch!(record, "expires_at")),
        "source_agent_id" => Map.fetch!(record, "source_agent_id"),
        "source_session_id" => Map.fetch!(record, "source_session_id"),
        "tool_call_id" => Map.fetch!(record, "tool_call_id"),
        "surface_kind" => record["surface_kind"],
        "surface_ref" => record["surface_ref"] || %{},
        "payload" => Codec.encode_snapshot(record),
        "created_at" => record["created_at"],
        "updated_at" => record["updated_at"],
        "result_delivery_due_at" => due,
        "result_delivered_at" => delivered,
        "revision" => 1
      }
    )
  end

  defmodule Pending do
    @moduledoc "One frozen SQL mutation; settlement does not compute a new result."
    @derive {Inspect, only: [:kind, :group_id, :request_id, :expected_revision]}
    defstruct [:kind, :group_id, :request_id, :expected_revision, :payload, :sql, :params]
  end

  def get(group_id, request_id) do
    with {:ok, row} <- read(group_id, request_id), do: {:ok, row.record}
  end

  def read(group_id, request_id) do
    case query(
           "SELECT #{@columns} FROM salix_capability_requests WHERE group_id=$1 AND request_id=$2",
           [group_id, request_id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      error -> error
    end
  end

  def find_tool(group_id, tenant_id, agent_id, session_id, tool_call_id, request_types) do
    case query(
           """
           SELECT #{@columns} FROM salix_capability_requests
           WHERE group_id=$1 AND tenant_id=$2 AND source_agent_id=$3
             AND source_session_id=$4 AND tool_call_id=$5 AND request_type=ANY($6)
           ORDER BY array_position($6::text[],request_type),request_id LIMIT 1
           """,
           [group_id, tenant_id, agent_id, session_id, tool_call_id, request_types]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      error -> error
    end
  end

  def upsert(record, fun), do: do_upsert(record, fun, 5)

  defp do_upsert(_record, _fun, 0), do: {:error, :precondition_failed}

  defp do_upsert(record, fun, attempts) do
    result =
      case read(record["group_id"], record["request_id"]) do
        {:ok, row} -> persist_changed(row, fun.(row.record), true)
        {:error, :not_found} -> record |> prepare_insert() |> persist(true)
        error -> error
      end

    case result do
      {:error, :precondition_failed} -> do_upsert(record, fun, attempts - 1)
      {:ok, row} -> {:ok, row.record}
      error -> error
    end
  end

  def update(group_id, request_id, fun, opts \\ []),
    do: do_update(group_id, request_id, fun, Keyword.get(opts, :settle_unknown, true), 5)

  defp do_update(_group, _request, _fun, _settle, 0), do: {:error, :precondition_failed}

  defp do_update(group, request, fun, settle_unknown, attempts) do
    result =
      with {:ok, row} <- read(group, request),
           {:ok, record} <- fun.(row.record) do
        persist_changed(row, record, settle_unknown)
      end

    case result do
      {:error, :precondition_failed} ->
        do_update(group, request, fun, settle_unknown, attempts - 1)

      {:ok, row} ->
        {:ok, row.record}

      error ->
        error
    end
  end

  defp persist_changed(%{record: record} = row, record, _settle), do: {:ok, row}
  defp persist_changed(row, record, settle), do: row |> prepare_update(record) |> persist(settle)

  defp persist(pending, settle_unknown) do
    case execute(pending) do
      {:error, {:commit_indeterminate, _}} when not settle_unknown ->
        {:error, :mutation_outcome_unknown}

      result ->
        resolve(result, 5)
    end
  end

  defp resolve({:error, {:commit_indeterminate, _}}, 0),
    do: {:error, :mutation_outcome_unknown}

  defp resolve({:error, {:commit_indeterminate, pending}}, attempts),
    do: pending |> settle() |> resolve(attempts - 1)

  defp resolve(result, _attempts), do: result

  def acknowledge_delivery(request) do
    with {:ok, row} <- read(request["group_id"], request["request_id"]) do
      cond do
        row.record["status"] == "cancelled" ->
          :ok

        row.record["result"] != request["result"] ->
          {:error, :precondition_failed}

        not is_nil(row.delivered_at) ->
          :ok

        true ->
          case row |> prepare_delivery_ack() |> persist(true) do
            {:ok, _} -> :ok
            error -> error
          end
      end
    end
  end

  def list_group(group_id, tenant_id, status, now, limit) do
    condition =
      case status do
        "pending" -> "status='pending' AND expires_at>to_timestamp($3::bigint)"
        "" -> "($3::bigint IS NOT NULL)"
        _ -> "status=$5 AND ($3::bigint IS NOT NULL)"
      end

    params = [group_id, tenant_id, now, limit]
    params = if status in ["pending", ""], do: params, else: params ++ [status]

    case query(
           """
           SELECT #{@columns} FROM salix_capability_requests
           WHERE group_id=$1 AND tenant_id=$2 AND #{condition}
           ORDER BY COALESCE(updated_at,0) DESC, COALESCE(created_at,0) DESC,
                    request_id COLLATE "C" DESC LIMIT $4
           """,
           params
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode(&1).record)}
      error -> error
    end
  end

  def list_conversation(group, tenant, conversation, now, limit) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

      with {:ok, pending} <- all_pending(group, tenant, conversation, now, nil, []),
           {:ok, finished} <-
             finished(group, tenant, conversation, now, max(limit - length(pending), 0)) do
        pending ++ finished
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  One page of a Group's active pending requests of `type`, newest first; `next`
  is the cursor of the page after it, or nil at the end.
  """
  def pending_of_type(group, tenant, type, now, cursor, limit) do
    {updated, created, request} = cursor || {nil, 0, ""}

    case query(
           """
           SELECT COALESCE(updated_at,0),COALESCE(created_at,0),request_id,#{@columns}
           FROM salix_capability_requests
           WHERE group_id=$1 AND tenant_id=$2 AND request_type=$3
             AND status='pending' AND expires_at>to_timestamp($4::bigint)
             AND ($5::bigint IS NULL OR
                  (COALESCE(updated_at,0),COALESCE(created_at,0),request_id COLLATE "C")
                    < ($5,$6,$7::text COLLATE "C"))
           ORDER BY COALESCE(updated_at,0) DESC,COALESCE(created_at,0) DESC,
                    request_id COLLATE "C" DESC LIMIT $8
           """,
           [group, tenant, type, now, updated, created, request, limit]
         ) do
      {:ok, %{rows: rows}} ->
        items = Enum.map(rows, fn [_updated, _created, _id | row] -> decode(row).record end)

        next =
          if length(rows) == limit, do: rows |> List.last() |> Enum.take(3) |> List.to_tuple()

        {:ok, %{items: items, next: next}}

      error ->
        error
    end
  end

  def pending_location(requester, now, limit) do
    case query(
           """
           SELECT #{@columns} FROM salix_capability_requests
           WHERE request_type='location' AND status='pending'
             AND surface_ref->>'requester'=$1 AND expires_at>to_timestamp($2::bigint)
           ORDER BY created_at DESC, request_id COLLATE "C" DESC LIMIT $3
           """,
           [requester, now, limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode(&1).record)}
      error -> error
    end
  end

  defp all_pending(group, tenant, conversation, now, cursor, pages) do
    case surface_page(group, tenant, conversation, now, :pending, cursor, 100) do
      {:ok, %{items: items, next: nil}} ->
        {:ok, pages |> Enum.reverse([items]) |> List.flatten()}

      {:ok, %{items: items, next: next}} ->
        all_pending(group, tenant, conversation, now, next, [items | pages])

      error ->
        error
    end
  end

  defp finished(_group, _tenant, _conversation, _now, 0), do: {:ok, []}

  defp finished(group, tenant, conversation, now, limit) do
    with {:ok, %{items: items}} <-
           surface_page(group, tenant, conversation, now, :finished, nil, limit),
         do: {:ok, items}
  end

  defp surface_page(group, tenant, conversation, now, phase, cursor, limit) do
    {updated, created, request} = cursor || {nil, 0, ""}
    active = "(status='pending' AND expires_at>to_timestamp($4::bigint))"
    condition = if phase == :pending, do: active, else: "NOT " <> active

    case query(
           """
           SELECT COALESCE(updated_at,0),COALESCE(created_at,0),request_id,#{@columns}
           FROM salix_capability_requests
           WHERE group_id=$1 AND tenant_id=$2 AND surface_kind='conversation'
             AND surface_ref->>'conversation_id'=$3 AND #{condition}
             AND ($5::bigint IS NULL OR
                  (COALESCE(updated_at,0),COALESCE(created_at,0),request_id COLLATE "C")
                    < ($5,$6,$7::text COLLATE "C"))
           ORDER BY COALESCE(updated_at,0) DESC,COALESCE(created_at,0) DESC,
                    request_id COLLATE "C" DESC LIMIT $8
           """,
           [group, tenant, conversation, now, updated, created, request, limit]
         ) do
      {:ok, %{rows: rows}} ->
        items = Enum.map(rows, fn [_updated, _created, _id | row] -> decode(row).record end)

        next =
          if length(rows) == limit, do: rows |> List.last() |> Enum.take(3) |> List.to_tuple()

        {:ok, %{items: items, next: next}}

      error ->
        error
    end
  end

  def prepare_insert(record) do
    pending = mutation(:insert, 0, record)

    %{
      pending
      | sql: """
        INSERT INTO salix_capability_requests
          (group_id, request_id, revision, tenant_id, request_type, status, expires_at,
           source_agent_id, source_session_id, tool_call_id, surface_kind, surface_ref,
           payload, result_delivery_due_at, created_at, updated_at)
        VALUES ($1,$2,1,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,
                CASE WHEN $13 THEN clock_timestamp() ELSE NULL END,$14,$15)
        ON CONFLICT (group_id,request_id) DO NOTHING
        RETURNING #{@columns}
        """
    }
  end

  def prepare_update(%{revision: revision}, record) do
    pending = mutation(:update, revision, record)

    %{
      pending
      | sql: """
        UPDATE salix_capability_requests
        SET revision=revision+1, tenant_id=$3, request_type=$4, status=$5, expires_at=$6,
            source_agent_id=$7, source_session_id=$8, tool_call_id=$9,
            surface_kind=$10, surface_ref=$11, payload=$12, created_at=$14, updated_at=$15,
            result_delivery_due_at=CASE WHEN $13 AND result_delivered_at IS NULL
              THEN COALESCE(result_delivery_due_at,clock_timestamp()) ELSE NULL END
        WHERE group_id=$1 AND request_id=$2 AND revision=$16
        RETURNING #{@columns}
        """,
        params: pending.params ++ [revision]
    }
  end

  def prepare_delivery_ack(%{revision: revision, record: record}) do
    %Pending{
      kind: :delivery_ack,
      group_id: record["group_id"],
      request_id: record["request_id"],
      expected_revision: revision,
      payload: Codec.encode_snapshot(record),
      sql: """
      UPDATE salix_capability_requests
      SET revision=revision+1, result_delivery_due_at=NULL,
          result_delivered_at=clock_timestamp()
      WHERE group_id=$1 AND request_id=$2 AND revision=$3
        AND source_agent_id=$4 AND source_session_id=$5 AND tool_call_id=$6
        AND status <> 'cancelled' AND result_delivery_due_at IS NOT NULL
      RETURNING #{@columns}
      """,
      params: [
        record["group_id"],
        record["request_id"],
        revision,
        record["source_agent_id"],
        record["source_session_id"],
        record["tool_call_id"]
      ]
    }
  end

  def execute(%Pending{} = pending) do
    case query(pending.sql, pending.params) do
      {:ok, %{rows: [row]}} -> {:ok, decode(row)}
      {:ok, %{rows: []}} -> {:error, :precondition_failed}
      {:error, :commit_indeterminate} -> {:error, {:commit_indeterminate, pending}}
      error -> error
    end
  end

  # The domain caller must retain responsibility for any external authority
  # granted after a mutation. In particular, a stored IFC decision alone does
  # not prove which caller may issue its receipt.
  def settle(%Pending{} = pending) do
    case read(pending.group_id, pending.request_id) do
      {:ok, %{revision: revision, record: record} = row} ->
        cond do
          revision == pending.expected_revision + 1 and
            Codec.encode_snapshot(record) == pending.payload and
              (pending.kind != :delivery_ack or not is_nil(row.delivered_at)) ->
            {:ok, row}

          revision == pending.expected_revision ->
            retry_frozen(pending)

          true ->
            {:error, :mutation_outcome_unknown}
        end

      {:error, :not_found} when pending.kind == :insert ->
        retry_frozen(pending)

      {:error, :not_found} ->
        {:error, :mutation_outcome_unknown}

      {:error, :commit_indeterminate} ->
        {:error, {:commit_indeterminate, pending}}

      error ->
        error
    end
  end

  defp retry_frozen(pending) do
    case execute(pending) do
      {:error, :precondition_failed} -> {:error, :mutation_outcome_unknown}
      result -> result
    end
  end

  def page_expired(opts \\ []) do
    page_due(:expiry, opts)
  end

  def page_result_delivery(opts \\ []) do
    page_due(:delivery, opts)
  end

  defp page_due(kind, opts) do
    limit = Keyword.get(opts, :limit, 100)
    cursor = Keyword.get(opts, :cursor)

    if is_integer(limit) and limit in 1..@page_limit do
      {column, condition} =
        case kind do
          :expiry ->
            {"expires_at",
             "status='pending' AND request_type IN ('location','channel_link','plugin_install')"}

          :delivery ->
            {"result_delivery_due_at",
             "result_delivery_due_at IS NOT NULL AND result_delivered_at IS NULL"}
        end

      {cursor_at, cursor_group, cursor_request} = cursor || {nil, "", ""}

      case query(
             """
             SELECT group_id,request_id,#{column},#{@columns}
             FROM salix_capability_requests
             WHERE #{condition} AND #{column} <= clock_timestamp()
               AND ($1::timestamptz IS NULL OR
                    (#{column},group_id,request_id)>($1,$2,$3))
             ORDER BY #{column},group_id,request_id LIMIT $4
             """,
             [cursor_at, cursor_group, cursor_request, limit]
           ) do
        {:ok, %{rows: rows}} ->
          items = Enum.map(rows, fn [_group, _request, _at | row] -> decode(row) end)

          next =
            if length(rows) == limit do
              [group, request, at | _] = List.last(rows)
              {at, group, request}
            end

          {:ok, %{items: items, next: next}}

        error ->
          error
      end
    else
      {:error, :invalid_arguments}
    end
  end

  defp mutation(kind, revision, record) do
    payload = Codec.encode_snapshot(record)

    %Pending{
      kind: kind,
      group_id: Map.fetch!(record, "group_id"),
      request_id: Map.fetch!(record, "request_id"),
      expected_revision: revision,
      payload: payload,
      params: [
        record["group_id"],
        record["request_id"],
        record["tenant_id"],
        record["request_type"],
        record["status"],
        DateTime.from_unix!(record["expires_at"], :second),
        record["source_agent_id"],
        record["source_session_id"],
        record["tool_call_id"],
        record["surface_kind"],
        record["surface_ref"] || %{},
        payload,
        record["status"] != "cancelled" and is_map(record["result"]),
        record["created_at"],
        record["updated_at"]
      ]
    }
  end

  defp decode([revision, payload, due_at, delivered_at]) do
    %{
      revision: revision,
      record: Codec.decode_snapshot(payload),
      due_at: due_at,
      delivered_at: delivered_at
    }
  end

  defp query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, _} = result -> result
      {:error, %Postgrex.Error{}} -> {:error, :unavailable}
      {:error, _} -> {:error, :commit_indeterminate}
    end
  rescue
    _ in Postgrex.Error -> {:error, :unavailable}
    _ in DBConnection.ConnectionError -> {:error, :commit_indeterminate}
  catch
    :exit, _ -> {:error, :commit_indeterminate}
  end
end
