defmodule SalixStore.TriageProductRuntime do
  @moduledoc """
  PostgreSQL authority for executing native Triage product obligations.

  Every Pod may claim work. `FOR UPDATE SKIP LOCKED` partitions candidates and
  an opaque claim token fences settlement after lease expiry. Communication
  outcome, context collection and the append-only effect attempt settle in one
  transaction. Before that boundary, a reply adapter uses `obligation_id` as
  the stable provider operation reference and requires provider-confirmed
  delivery plus local thread-admission completion. No Triage effect reads or
  mutates Router Conversation state.

  """

  alias SalixStore.{Crypto, Ids, Repo, Schedules, ULID}

  @max_claim 50
  @default_claim 10
  @default_lease_ms 30_000
  @min_lease_ms 1_000
  @max_lease_ms 300_000
  @max_error_bytes 1_000
  @max_recent 100

  @outcome_columns """
  p.obligation_id,
  p.payload -> 'target',
  p.payload -> 'source_messages',
  p.payload -> 'communication',
  p.payload -> 'context_candidates',
  p.payload -> 'delegations',
  p.payload -> 'target_cutoff',
  p.state,
  p.attempts,
  p.result,
  extract(epoch FROM p.inserted_at) * 1000,
  extract(epoch FROM p.updated_at) * 1000,
  c.obligation_id,
  c.payload -> 'communication',
  c.state,
  c.attempts,
  c.result,
  extract(epoch FROM c.updated_at) * 1000
  """

  @type claim :: %{
          namespace_key: String.t(),
          run_id: String.t(),
          obligation_id: String.t(),
          payload: map(),
          attempt: pos_integer(),
          claim_token: String.t(),
          lease_until: DateTime.t(),
          holder: String.t()
        }

  @doc "Claims a bounded oldest-first batch. Expired claims are safely stealable."
  @spec claim_obligations(String.t(), keyword()) ::
          {:ok, [claim()]} | {:error, :invalid | :unavailable}
  def claim_obligations(holder, opts \\ [])

  def claim_obligations(holder, opts) when is_binary(holder) and is_list(opts) do
    claim_obligations_from(:primary, holder, opts)
  end

  def claim_obligations(_holder, _opts), do: {:error, :invalid}

  @doc "Claims bounded companion reactions without competing with legacy primary workers."
  @spec claim_companion_reactions(String.t(), keyword()) ::
          {:ok, [claim()]} | {:error, :invalid | :unavailable}
  def claim_companion_reactions(holder, opts \\ [])

  def claim_companion_reactions(holder, opts) when is_binary(holder) and is_list(opts) do
    claim_obligations_from(:companion_reaction, holder, opts)
  end

  def claim_companion_reactions(_holder, _opts), do: {:error, :invalid}

  defp claim_obligations_from(lane, holder, opts) do
    limit = Keyword.get(opts, :limit, @default_claim)
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

    if valid_holder?(holder) and valid_limit?(limit) and valid_lease?(lease_ms) do
      token = "triage-product-claim-" <> ULID.generate()

      case Repo.query(claim_sql(lane), [limit, token, lease_ms]) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &claim_row(&1, holder))}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Settles one exact claim.

  `effect` is a content-safe adapter result with atom keys:
  `:adapter`, `:outcome`, `:external_writes`, `:communication`, optional
  `:metadata`, optional `:error`, and optional `:retry`. A retryable failure is
  audited and returned to `pending`; every other outcome is terminal.
  """
  @spec settle_claim(claim(), map()) ::
          {:ok, %{status: :settled | :duplicate, state: atom(), result: map()}}
          | {:error, :conflict | :invalid | :unavailable}
  def settle_claim(%{} = claim, %{} = effect) do
    settle_claim_from(:primary, claim, effect)
  end

  def settle_claim(_claim, _effect), do: {:error, :invalid}

  @doc "Settles one companion reaction claim on its independent durable lane."
  @spec settle_companion_reaction(claim(), map()) ::
          {:ok, %{status: :settled | :duplicate, state: atom(), result: map()}}
          | {:error, :conflict | :invalid | :unavailable}
  def settle_companion_reaction(%{} = claim, %{} = effect) do
    settle_claim_from(:companion_reaction, claim, effect)
  end

  def settle_companion_reaction(_claim, _effect), do: {:error, :invalid}

  defp settle_claim_from(lane, claim, effect) do
    with :ok <- validate_claim(claim),
         {:ok, normalized} <- normalize_effect(effect) do
      result =
        Repo.transaction(fn ->
          case lock_obligation(lane, claim) do
            {:ok, row} ->
              settle_locked(lane, claim, row, normalized)

            {:duplicate, stored} ->
              %{status: :duplicate, state: state_atom(stored["state"]), result: stored}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      normalize_transaction(result)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Settles a Worker's context once under its existing participant delivery identity."
  def settle_investigation_context(%{"context_candidates" => []}, _operation, _effect), do: :ok

  def settle_investigation_context(_payload, _operation, %{outcome: outcome})
      when outcome in [:stale, :failed],
      do: :ok

  def settle_investigation_context(payload, operation, %{outcome: outcome} = effect)
      when is_map(payload) and is_binary(operation) and outcome == :applied do
    attempt = "triage-investigation-context:" <> operation

    Repo.transaction(fn ->
      # Serialize retries against the original obligation. The append-only
      # attempt and context changes commit together; a recovered Task cannot
      # rearm an already resolved reminder by replaying this completion.
      case Repo.query(
             "SELECT namespace_key, run_id FROM triage_product_obligations WHERE obligation_id = $1 FOR UPDATE",
             [payload["obligation_id"]]
           ) do
        {:ok, %{rows: [[namespace, run_id]]}} ->
          case Repo.query("SELECT 1 FROM triage_product_effect_attempts WHERE attempt_id = $1", [
                 attempt
               ]) do
            {:ok, %{rows: [[1]]}} ->
              :ok

            {:ok, %{rows: []}} ->
              context = apply_context_candidates(payload, operation, effect)

              Repo.query!(
                """
                INSERT INTO triage_product_effect_attempts
                  (attempt_id, namespace_key, run_id, adapter, outcome, external_writes, payload)
                VALUES ($1, $2, $3, 'slack', $4, 0, $5)
                """,
                [
                  attempt,
                  namespace,
                  run_id,
                  Atom.to_string(outcome),
                  %{
                    "kind" => "investigation_context",
                    "operation_ref" => operation,
                    "context" => context
                  }
                ]
              )

              :ok

            _ ->
              Repo.rollback(:unavailable)
          end

        _ ->
          Repo.rollback(:unavailable)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def settle_investigation_context(_, _, _), do: {:error, :invalid}

  @doc "Returns bounded recent product outcomes for one project without raw provider payloads."
  @spec recent_outcomes(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def recent_outcomes(project_id, opts \\ [])

  def recent_outcomes(project_id, opts) when is_binary(project_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    agent_id = Keyword.get(opts, :agent_id)
    target = Keyword.get(opts, :target)
    group_id = Keyword.get(opts, :group_id)

    if Keyword.keys(opts) -- [:limit, :agent_id, :target, :group_id] == [] and
         valid_outcome_target?(target, group_id, agent_id) and nonempty?(project_id) and
         (is_nil(agent_id) or nonempty?(agent_id)) and is_integer(limit) and
         limit in 1..@max_recent do
      {source, params} = outcome_source(project_id, agent_id, target, group_id, limit)

      case Repo.query(
             """
             SELECT
               #{@outcome_columns}
             FROM #{source}
             LEFT JOIN triage_companion_reaction_obligations AS c
               USING (namespace_key, run_id)
             WHERE p.payload -> 'product_identity' ->> 'project_id' = $1
               AND ($3::text IS NULL OR p.payload -> 'product_identity' ->> 'agent_id' = $3)
             ORDER BY GREATEST(p.updated_at, COALESCE(c.updated_at, p.updated_at)) DESC,
                      p.obligation_id DESC
             LIMIT $2
             """,
             params
           ) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &outcome_row/1)}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def recent_outcomes(_project_id, _opts), do: {:error, :invalid}

  @doc "Resolves at most 20 existing executions to this Agent's product outcomes."
  def outcome_ids_for_executions(project_id, group_id, agent_id, execution_ids)
      when is_list(execution_ids) and length(execution_ids) <= 20 do
    ids = Enum.filter(execution_ids, &nonempty?/1) |> Enum.uniq()

    if ids == [] do
      {:ok, %{}}
    else
      case Repo.query(
             """
             SELECT run_id, obligation_id FROM triage_product_obligations
             WHERE namespace_key = $1 AND run_id = ANY($2)
               AND payload #>> '{product_identity,project_id}' = $3
               AND payload #>> '{product_identity,project_salix_group_id}' = $4
               AND payload #>> '{product_identity,agent_id}' = $5
             LIMIT 20
             """,
             [
               SalixStore.TriageKeys.namespace_key(SalixStore.TriageKeys.default_namespace()),
               ids,
               project_id,
               group_id,
               agent_id
             ]
           ) do
        {:ok, %{rows: rows}} -> {:ok, Map.new(rows, fn [id, outcome] -> {id, outcome} end)}
        _ -> {:error, :unavailable}
      end
    end
  end

  def outcome_ids_for_executions(_, _, _, _), do: {:error, :invalid}

  @doc "Pages immutable execution order while projecting the latest effect state."
  def outcome_page(project_id, group_id, agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    kind = Keyword.get(opts, :kind, "all")
    cursor = Keyword.get(opts, :cursor)
    obligation_id = Keyword.get(opts, :obligation_id)
    channel_id = Keyword.get(opts, :channel_id)
    before_ms = Keyword.get(opts, :before_ms)

    kind_predicate =
      case kind do
        "investigation" ->
          "$6::text = 'investigation' AND jsonb_array_length(payload->'delegations') > 0"

        "silence" ->
          "payload #>> '{communication,kind}' = $6 AND payload #>> '{communication,reason}' IS DISTINCT FROM 'worker_pending'"

        value when value in ~w(reply reaction) ->
          "payload #>> '{communication,kind}' = $6"

        _ ->
          "$6::text = 'all'"
      end

    with true <-
           Keyword.keys(opts) -- [:limit, :kind, :cursor, :obligation_id, :channel_id, :before_ms] ==
             [],
         true <- Enum.all?([project_id, group_id, agent_id], &nonempty?/1),
         true <- is_integer(limit) and limit in 1..20,
         true <- kind in ~w(all reply reaction silence investigation),
         true <-
           is_nil(obligation_id) or (nonempty?(obligation_id) and byte_size(obligation_id) <= 256),
         true <- is_nil(channel_id) or (nonempty?(channel_id) and byte_size(channel_id) <= 256),
         true <- is_nil(before_ms) or before_ms in 0..253_402_300_799_999,
         {:ok, before_at, before_id} <- outcome_page_start(cursor, before_ms),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT #{@outcome_columns}, p.inserted_at::text
             FROM (
               SELECT * FROM triage_product_obligations
               WHERE payload #>> '{product_identity,project_id}' = $1
                 AND payload #>> '{product_identity,project_salix_group_id}' = $2
                 AND payload #>> '{product_identity,agent_id}' = $3
                 AND ($4::timestamptz IS NULL OR (inserted_at, obligation_id) < ($4, $5))
                 AND ($7::text IS NULL OR obligation_id = $7)
                 AND ($9::text IS NULL OR payload #>> '{target,channel_id}' = $9)
                 AND (#{kind_predicate})
               ORDER BY inserted_at DESC, obligation_id DESC
               LIMIT $8
             ) AS p
             LEFT JOIN triage_companion_reaction_obligations AS c USING (namespace_key, run_id)
             ORDER BY p.inserted_at DESC, p.obligation_id DESC
             """,
             [
               project_id,
               group_id,
               agent_id,
               before_at,
               before_id,
               kind,
               obligation_id,
               limit + 1,
               channel_id
             ]
           ) do
      visible = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          last = List.last(visible)
          encode_outcome_cursor(List.last(last), hd(last))
        end

      {:ok,
       %{
         outcomes: Enum.map(visible, &outcome_row(Enum.drop(&1, -1))),
         next_cursor: next_cursor
       }}
    else
      false -> {:error, :invalid}
      {:error, :invalid_cursor} -> {:error, :invalid}
      _unavailable -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @heatmap_bucket_ms 3_600_000
  @max_heatmap_cells 5_000

  @doc """
  Counts one exact Agent's outcomes per Slack channel and hour since `since_ms`.

  The read uses the Timeline index range and returns at most 5,000 cells. A
  larger result keeps its newest cells and is marked `truncated`.
  """
  def outcome_heatmap(project_id, group_id, agent_id, since_ms)
      when is_integer(since_ms) and since_ms >= 0 do
    with true <- Enum.all?([project_id, group_id, agent_id], &nonempty?/1),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT
               payload #>> '{target,connect_id}',
               payload #>> '{target,channel_id}',
               (floor(extract(epoch FROM inserted_at) * 1000 / $5) * $5)::bigint,
               count(*) FILTER (WHERE payload #>> '{communication,kind}' = 'reply'),
               count(*) FILTER (WHERE payload #>> '{communication,kind}' = 'reaction'),
               count(*) FILTER (
                 WHERE payload #>> '{communication,kind}' = 'silence'
                   AND payload #>> '{communication,reason}' IS DISTINCT FROM 'worker_pending'
               ),
               count(*)
             FROM triage_product_obligations
             WHERE payload #>> '{product_identity,project_id}' = $1
               AND payload #>> '{product_identity,project_salix_group_id}' = $2
               AND payload #>> '{product_identity,agent_id}' = $3
               AND inserted_at >= to_timestamp($4::bigint / 1000.0)
             GROUP BY 1, 2, 3
             ORDER BY 3 DESC, 2, 1
             LIMIT $6
             """,
             [
               project_id,
               group_id,
               agent_id,
               since_ms,
               @heatmap_bucket_ms,
               @max_heatmap_cells + 1
             ]
           ) do
      cells =
        rows
        |> Enum.take(@max_heatmap_cells)
        |> Enum.map(fn [connect_id, channel_id, at_ms, reply, reaction, silence, total] ->
          %{
            connect_id: connect_id,
            channel_id: channel_id,
            at_ms: at_ms,
            reply: reply,
            reaction: reaction,
            silence: silence,
            total: total
          }
        end)

      {:ok,
       %{
         since_ms: since_ms,
         bucket_ms: @heatmap_bucket_ms,
         cells: cells,
         truncated: length(rows) > @max_heatmap_cells
       }}
    else
      false -> {:error, :invalid}
      _unavailable -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def outcome_heatmap(_project_id, _group_id, _agent_id, _since_ms), do: {:error, :invalid}

  # A cursor continues a page. Without one, `before_ms` starts strictly before
  # that instant; the empty id sorts before every obligation id.
  defp outcome_page_start(nil, before_ms) when is_integer(before_ms),
    do: {:ok, DateTime.from_unix!(before_ms, :millisecond), ""}

  defp outcome_page_start(cursor, _before_ms), do: decode_outcome_cursor(cursor)

  defp encode_outcome_cursor(timestamp, id),
    do: Base.url_encode64(Jason.encode!([timestamp, id]), padding: false)

  defp decode_outcome_cursor(nil), do: {:ok, nil, nil}

  defp decode_outcome_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 1024 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [timestamp, id]} <- Jason.decode(json),
         true <- is_binary(timestamp) and byte_size(timestamp) <= 64,
         true <- nonempty?(id) and byte_size(id) <= 256,
         # PostgreSQL's timestamp text uses a space and may shorten the offset.
         {:ok, parsed, _} <-
           DateTime.from_iso8601(String.replace(timestamp, " ", "T") |> normalize_cursor_offset()) do
      {:ok, parsed, id}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_outcome_cursor(_cursor), do: {:error, :invalid_cursor}

  defp normalize_cursor_offset(timestamp) do
    if Regex.match?(~r/[+-]\d{2}$/, timestamp), do: timestamp <> ":00", else: timestamp
  end

  defp valid_outcome_target?(nil, nil, _agent_id), do: true

  defp valid_outcome_target?(target, group_id, agent_id) when is_map(target) do
    Enum.sort(Map.keys(target)) ==
      ~w(channel_id connect_generation connect_id thread_ts workspace_id) and
      Enum.all?(Map.values(target), &(nonempty?(&1) and byte_size(&1) <= 256)) and
      nonempty?(group_id) and nonempty?(agent_id)
  end

  defp valid_outcome_target?(_target, _group_id, _agent_id), do: false

  defp outcome_source(project_id, agent_id, nil, nil, limit),
    do: {"triage_product_obligations AS p", [project_id, limit, agent_id]}

  defp outcome_source(project_id, agent_id, target, group_id, limit) do
    # Select a bounded execution window before joining current effect state.
    # The source index matches these exact predicates and this ordering.
    source = """
    (SELECT * FROM triage_product_obligations
     WHERE payload -> 'product_identity' ->> 'project_id' = $1
       AND payload -> 'product_identity' ->> 'agent_id' = $3
       AND payload -> 'product_identity' ->> 'project_salix_group_id' = $4
       AND payload -> 'target' = $5::jsonb
     ORDER BY inserted_at DESC, obligation_id DESC
     LIMIT $2) AS p
    """

    {source, [project_id, limit, agent_id, group_id, target]}
  end

  @doc "Resolves one explicitly selected debug subject inside its product scope."
  def debug_run_id(project, group, agent, obligation_id) do
    case Repo.query(
           """
           SELECT run_id FROM triage_product_obligations
           WHERE obligation_id = $1
             AND payload #>> '{product_identity,project_id}' = $2
             AND payload #>> '{product_identity,project_salix_group_id}' = $3
             AND payload #>> '{product_identity,agent_id}' = $4
           LIMIT 1
           """,
           [obligation_id, project, group, agent]
         ) do
      {:ok, %{rows: [[run_id]]}} -> {:ok, run_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  Reads one immutable delegation by the existing unique obligation key.

  This grants no claim and changes no state. The caller must validate current
  product, source and Worker authority before using this original intent.
  """
  def fetch_delegation(namespace_key, obligation_id, index)
      when is_binary(namespace_key) and is_binary(obligation_id) and index in 0..1 do
    if byte_size(namespace_key) == 64 and byte_size(obligation_id) in 1..128 do
      case Repo.query(
             """
             SELECT run_id, payload
             FROM triage_product_obligations
             WHERE namespace_key = $1 AND obligation_id = $2
             LIMIT 1
             """,
             [namespace_key, obligation_id]
           ) do
        {:ok, %{rows: [[run_id, payload]]}} ->
          case Enum.at(payload["delegations"] || [], index) do
            %{"task" => task, "source_refs" => refs} = delegation
            when is_binary(task) and task != "" and is_list(refs) ->
              {:ok,
               %{
                 namespace_key: namespace_key,
                 run_id: run_id,
                 obligation_id: obligation_id,
                 payload: payload,
                 index: index,
                 delegation: delegation
               }}

            _missing ->
              {:error, :not_found}
          end

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        _unavailable ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def fetch_delegation(_namespace_key, _obligation_id, _index), do: {:error, :invalid}

  @doc "Returns bounded durable context entries for one project."
  @spec list_context(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def list_context(project_id, opts \\ [])

  def list_context(project_id, opts) when is_binary(project_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    agent_id = Keyword.get(opts, :agent_id)
    entry_id = Keyword.get(opts, :entry_id)
    kind = Keyword.get(opts, :kind)

    if Keyword.keys(opts) -- [:limit, :agent_id, :entry_id, :kind] == [] and nonempty?(project_id) and
         (is_nil(agent_id) or nonempty?(agent_id)) and
         (is_nil(entry_id) or nonempty?(entry_id)) and
         kind in [nil, "follow_up", "decision", "project_fact"] and is_integer(limit) and
         limit in 1..@max_recent do
      case Repo.query(
             """
             SELECT entry_id, kind, state, payload, next_check_at, resolved_at,
                    extract(epoch FROM inserted_at) * 1000,
                    extract(epoch FROM updated_at) * 1000
             FROM triage_context_entries
             WHERE project_id = $1
               AND ($3::text IS NULL OR agent_id = $3)
               AND ($4::text IS NULL OR entry_id = $4)
               AND ($5::text IS NULL OR kind = $5)
             ORDER BY updated_at DESC, entry_id DESC
             LIMIT $2
             """,
             [project_id, limit, agent_id, entry_id, kind]
           ) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &context_row/1)}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def list_context(_project_id, _opts), do: {:error, :invalid}

  @doc """
  Supersedes explicitly selected duplicate follow-ups under one retained entry.

  This maintenance operation requires an operator to confirm that the retained
  goal covers the selected goals. Pass current `list_context/2` snapshots; it
  does not infer equivalence from text or authorize a product user. Callers own
  operator authorization. All entries must share project, Agent and target.

  Payloads, evidence and the retained Schedule stay unchanged. Old schedules
  encounter an inactive entry and finish without admitting another recheck.
  Concurrent changes reject the whole operation. Repeating the same successful
  request is safe. No source completion or cancellation is recorded.
  """
  @spec supersede_follow_ups(String.t(), map(), [map()]) ::
          {:ok, %{retained_entry_id: String.t(), superseded_entry_ids: [String.t()]}}
          | {:error, :invalid | :conflict | :unavailable}
  def supersede_follow_ups(project_id, retained, duplicates)
      when is_binary(project_id) and is_map(retained) and is_list(duplicates) and
             length(duplicates) in 1..19 do
    snapshots = [retained | duplicates]

    ids =
      Enum.map(snapshots, fn
        %{entry_id: id} -> id
        _ -> nil
      end)

    if nonempty?(project_id) and Enum.all?(snapshots, &follow_up_snapshot?/1) and
         length(Enum.uniq(ids)) == length(ids) do
      Repo.transaction(fn ->
        %{rows: rows} =
          Repo.query!(
            """
            SELECT entry_id, agent_id, state, payload, next_check_at, superseded_by
            FROM triage_context_entries
            WHERE project_id = $1 AND kind = 'follow_up' AND entry_id = ANY($2::text[])
            ORDER BY entry_id
            FOR UPDATE
            """,
            [project_id, ids]
          )

        by_id = Map.new(rows, fn [id | rest] -> {id, rest} end)
        kept = Map.get(by_id, retained.entry_id)

        unless length(rows) == length(ids) and
                 Enum.all?(snapshots, fn snapshot ->
                   same_follow_up_snapshot?(Map.get(by_id, snapshot.entry_id), snapshot) and
                     same_follow_up_owner?(Map.get(by_id, snapshot.entry_id), kept) and
                     supersedable_follow_up?(
                       Map.get(by_id, snapshot.entry_id),
                       snapshot.entry_id,
                       retained.entry_id
                     )
                 end),
               do: Repo.rollback(:conflict)

        duplicate_ids = Enum.map(duplicates, & &1.entry_id)

        Repo.query!(
          """
          UPDATE triage_context_entries
          SET state = 'superseded', superseded_by = $2, updated_at = statement_timestamp()
          WHERE entry_id = ANY($1::text[]) AND state = 'active'
          """,
          [duplicate_ids, retained.entry_id]
        )

        %{retained_entry_id: retained.entry_id, superseded_entry_ids: duplicate_ids}
      end)
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def supersede_follow_ups(_project_id, _retained, _duplicates), do: {:error, :invalid}

  defp follow_up_snapshot?(%{
         entry_id: id,
         kind: "follow_up",
         state: :active,
         payload: payload,
         next_check_at: %DateTime{}
       }),
       do: nonempty?(id) and byte_size(id) <= 256 and is_map(payload)

  defp follow_up_snapshot?(_), do: false

  defp same_follow_up_snapshot?([_agent, _state, payload, due, _superseded], expected),
    do: payload == expected.payload and DateTime.compare(due, expected.next_check_at) == :eq

  defp same_follow_up_snapshot?(_, _), do: false

  defp same_follow_up_owner?([agent, _, payload, _, _], [agent, "active", kept, _, nil]),
    do:
      is_map(payload["target"]) and payload["target"] == kept["target"] and
        payload["authority_generation"] == kept["authority_generation"]

  defp same_follow_up_owner?(_, _), do: false

  defp supersedable_follow_up?([_, "active", _, _, nil], _, _), do: true

  defp supersedable_follow_up?([_, "superseded", _, _, retained], id, retained),
    do: id != retained

  defp supersedable_follow_up?(_, _, _), do: false

  @doc "Returns bounded active context entries for one project."
  @spec list_active_context(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def list_active_context(project_id, opts \\ [])

  def list_active_context(project_id, opts)
      when is_binary(project_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    query = Keyword.get(opts, :query)
    entry_ids = Keyword.get(opts, :entry_ids, [])

    if Keyword.keys(opts) -- [:limit, :query, :entry_ids] == [] and nonempty?(project_id) and
         is_list(entry_ids) and length(entry_ids) <= 20 and
         Enum.all?(entry_ids, &(nonempty?(&1) and byte_size(&1) <= 256)) and
         (is_nil(query) or (is_binary(query) and byte_size(query) <= 2_048)) and
         is_integer(limit) and limit in 1..@max_recent do
      with {:ok, pinned} <- read_pinned_context(project_id, entry_ids),
           {:ok, relevant} <- read_active_context(project_id, limit, query) do
        {:ok, (pinned ++ relevant) |> Enum.uniq_by(& &1.entry_id) |> Enum.take(limit)}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def list_active_context(_project_id, _opts), do: {:error, :invalid}

  defp read_pinned_context(_project_id, []), do: {:ok, []}

  defp read_pinned_context(project_id, entry_ids) do
    case Repo.query(
           """
           SELECT entry_id, kind, state, payload, next_check_at, resolved_at,
                  extract(epoch FROM inserted_at) * 1000,
                  extract(epoch FROM updated_at) * 1000
           FROM triage_context_entries
           WHERE project_id = $1 AND state = 'active' AND entry_id = ANY($2::text[])
           ORDER BY entry_id
           """,
           [project_id, entry_ids]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &context_row/1)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp read_active_context(project_id, limit, nil) do
    case Repo.query(
           """
           SELECT entry_id, kind, state, payload, next_check_at, resolved_at,
                  extract(epoch FROM inserted_at) * 1000,
                  extract(epoch FROM updated_at) * 1000
           FROM triage_context_entries
           WHERE project_id = $1
             AND state = 'active'
           ORDER BY updated_at DESC, entry_id DESC
           LIMIT $2
           """,
           [project_id, limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &context_row/1)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp read_active_context(project_id, limit, query) do
    case Repo.query(
           """
           WITH query AS (SELECT (triage_context_search_terms($3))[1:32] AS terms)
           SELECT entry_id, kind, state, payload, next_check_at, resolved_at,
                  extract(epoch FROM inserted_at) * 1000,
                  extract(epoch FROM updated_at) * 1000
           FROM triage_context_entries, query
           WHERE project_id = $1 AND state = 'active' AND search_terms && query.terms
           ORDER BY
             (SELECT count(*) FROM unnest(query.terms) AS term WHERE term = ANY(search_terms)) DESC,
             updated_at DESC, entry_id DESC
           LIMIT $2
           """,
           [project_id, limit, query]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &context_row/1)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc "Reads one exact active follow-up wakeup without claiming provider authority."
  @spec get_due_follow_up(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:ok, :stale} | {:error, :invalid | :unavailable}
  def get_due_follow_up(entry_id, authority_generation, schedule_id, scheduled_for_ms)
      when is_binary(entry_id) and is_binary(authority_generation) and is_binary(schedule_id) and
             is_integer(scheduled_for_ms) and scheduled_for_ms >= 0 do
    case Repo.query(
           """
           SELECT state, payload, extract(epoch FROM next_check_at) * 1000
           FROM triage_context_entries
           WHERE entry_id = $1 AND kind = 'follow_up'
           """,
           [entry_id]
         ) do
      {:ok, %{rows: [["active", payload, due_ms]]}} ->
        if exact_follow_up_wakeup?(
             payload,
             authority_generation,
             schedule_id,
             due_ms,
             scheduled_for_ms
           ) do
          {:ok,
           %{
             entry_id: entry_id,
             payload: payload,
             scheduled_for_ms: scheduled_for_ms
           }}
        else
          {:ok, :stale}
        end

      {:ok, %{rows: [[_state, _payload, _due_ms]]}} ->
        {:ok, :stale}

      {:ok, %{rows: []}} ->
        {:ok, :stale}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def get_due_follow_up(_entry_id, _authority_generation, _schedule_id, _scheduled_for_ms),
    do: {:error, :invalid}

  @doc """
  Settles one exact follow-up wakeup after its fresh Slack-thread read.

  The legacy explicit `:answered` outcome resolves an entry; it is no longer
  inferred or called by the native receiver. Native completion uses a cited
  `follow_up_resolution` in applied product settlement. An admitted recheck
  atomically creates the next shared one-shot Schedule. A stale/duplicate
  wakeup is an idempotent no-op.
  """
  @spec settle_follow_up_wakeup(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          :answered | :admitted | :stale_authority
        ) ::
          {:ok, :resolved | :stopped | :rescheduled | :stale}
          | {:error, :invalid | :unavailable}
  def settle_follow_up_wakeup(
        entry_id,
        authority_generation,
        schedule_id,
        scheduled_for_ms,
        outcome
      )
      when is_binary(entry_id) and is_binary(authority_generation) and is_binary(schedule_id) and
             is_integer(scheduled_for_ms) and scheduled_for_ms >= 0 and
             outcome in [:answered, :admitted, :stale_authority] do
    Repo.transaction(fn ->
      case lock_follow_up(entry_id) do
        {:ok, %{state: "active", payload: payload, due_ms: due_ms}} ->
          if exact_follow_up_wakeup?(
               payload,
               authority_generation,
               schedule_id,
               due_ms,
               scheduled_for_ms
             ) do
            settle_current_follow_up(entry_id, payload, scheduled_for_ms, outcome)
          else
            :stale
          end

        {:ok, _inactive} ->
          :stale

        :missing ->
          :stale

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_follow_up_transaction()
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def settle_follow_up_wakeup(
        _entry_id,
        _authority_generation,
        _schedule_id,
        _scheduled_for_ms,
        _outcome
      ),
      do: {:error, :invalid}

  @doc """
  Admits one exact unanswered follow-up while holding its context-row lock.

  The callback owns idempotent receipt persistence and Runtime admission. It
  runs only while this occurrence is still the active authority; a concurrent
  answer or an already-advanced occurrence makes the callback durably inert.
  Callback failure rolls the context rearm back so the shared Schedule can
  retry the same stable occurrence identity.
  """
  @spec admit_follow_up_wakeup(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          (-> :ok | {:ok, String.t()} | {:stale, term()} | {:error, term()})
        ) ::
          {:ok, :rescheduled | :stale}
          | {:stale, term()}
          | {:error, term()}
  def admit_follow_up_wakeup(
        entry_id,
        authority_generation,
        schedule_id,
        scheduled_for_ms,
        admit
      )
      when is_binary(entry_id) and is_binary(authority_generation) and is_binary(schedule_id) and
             is_integer(scheduled_for_ms) and scheduled_for_ms >= 0 and is_function(admit, 0) do
    Repo.transaction(fn ->
      case lock_follow_up(entry_id) do
        {:ok, %{state: "active", payload: payload, due_ms: due_ms}} ->
          if exact_follow_up_wakeup?(
               payload,
               authority_generation,
               schedule_id,
               due_ms,
               scheduled_for_ms
             ) do
            case admit.() do
              {:ok, event_id} when is_binary(event_id) and event_id != "" ->
                payload = Map.put(payload, "last_wakeup_event_id", event_id)
                settle_current_follow_up(entry_id, payload, scheduled_for_ms, :admitted)

              :ok ->
                settle_current_follow_up(entry_id, payload, scheduled_for_ms, :admitted)

              {:stale, _reason} = stale ->
                Repo.rollback({:admission_callback, stale})

              {:error, _reason} = error ->
                Repo.rollback({:admission_callback, error})

              _invalid ->
                Repo.rollback({:admission_callback, {:error, :triage_follow_up_admission_failed}})
            end
          else
            :stale
          end

        {:ok, _inactive} ->
          :stale

        :missing ->
          :stale

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_follow_up_admission_transaction()
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def admit_follow_up_wakeup(
        _entry_id,
        _authority_generation,
        _schedule_id,
        _scheduled_for_ms,
        _admit
      ),
      do: {:error, :invalid}

  defp claim_sql(lane) do
    table = obligation_table(lane)

    """
    WITH candidates AS (
      SELECT namespace_key, run_id
      FROM #{table}
      WHERE state = 'pending'
         OR (state = 'claimed' AND lease_until <= statement_timestamp())
      ORDER BY inserted_at, namespace_key, run_id
      LIMIT $1
      FOR UPDATE SKIP LOCKED
    ), claimed AS (
      UPDATE #{table} AS obligation
      SET state = 'claimed',
          attempts = obligation.attempts + 1,
          claim_token = $2,
          lease_until = statement_timestamp() + ($3::bigint * interval '1 millisecond'),
          updated_at = statement_timestamp()
      FROM candidates
      WHERE obligation.namespace_key = candidates.namespace_key
        AND obligation.run_id = candidates.run_id
      RETURNING obligation.namespace_key, obligation.run_id, obligation.obligation_id,
                obligation.payload, obligation.attempts, obligation.claim_token,
                obligation.lease_until
    )
    SELECT namespace_key, run_id, obligation_id, payload, attempts, claim_token, lease_until
    FROM claimed
    ORDER BY namespace_key, run_id
    """
  end

  defp claim_row(
         [namespace_key, run_id, obligation_id, payload, attempt, token, lease_until],
         holder
       ) do
    %{
      namespace_key: namespace_key,
      run_id: run_id,
      obligation_id: obligation_id,
      payload: payload,
      attempt: attempt,
      claim_token: token,
      lease_until: lease_until,
      holder: holder
    }
  end

  defp lock_obligation(lane, claim) do
    table = obligation_table(lane)

    case Repo.query(
           """
           SELECT state, attempts, claim_token, payload, result
           FROM #{table}
           WHERE namespace_key = $1 AND run_id = $2 AND obligation_id = $3
           FOR UPDATE
           """,
           [claim.namespace_key, claim.run_id, claim.obligation_id]
         ) do
      {:ok, %{rows: [["claimed", attempt, token, payload, _result]]}}
      when attempt == claim.attempt and token == claim.claim_token ->
        {:ok, %{attempt: attempt, payload: payload}}

      {:ok, %{rows: [[state, _attempt, _token, _payload, %{} = result]]}}
      when state in ["applied", "stale", "failed"] ->
        if result["claim_token"] == claim.claim_token do
          {:duplicate, Map.put(result, "state", state)}
        else
          {:error, :conflict}
        end

      {:ok, %{rows: []}} ->
        {:error, :conflict}

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp settle_locked(lane, claim, row, effect) do
    context = apply_context_candidates(row.payload, claim.obligation_id, effect)
    state = settlement_state(effect)
    attempt_id = attempt_id(claim)

    result =
      %{
        "schema" => "comma.triage-product-effect-result.v1",
        "obligation_id" => claim.obligation_id,
        "claim_token" => claim.claim_token,
        "attempt" => row.attempt,
        "adapter" => Atom.to_string(effect.adapter),
        "outcome" => Atom.to_string(effect.outcome),
        "external_writes" => effect.external_writes,
        "communication" => effect.communication,
        "context" => context,
        "metadata" => effect.metadata,
        "state" => state
      }
      |> put_optional("error", effect.error)

    attempt_payload = Map.drop(result, ["claim_token"])

    with {:ok, %{rows: [[1]]}} <-
           Repo.query(
             """
             INSERT INTO triage_product_effect_attempts
               (attempt_id, namespace_key, run_id, adapter, outcome, external_writes, payload)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT DO NOTHING
             RETURNING 1
             """,
             [
               attempt_id,
               claim.namespace_key,
               claim.run_id,
               Atom.to_string(effect.adapter),
               Atom.to_string(effect.outcome),
               effect.external_writes,
               attempt_payload
             ]
           ),
         {:ok, %{rows: [[1]]}} <-
           update_settled_obligation(lane, claim, state, result, effect.error) do
      %{status: :settled, state: state_atom(state), result: result}
    else
      {:ok, %{rows: []}} -> Repo.rollback(:conflict)
      {:error, _reason} -> Repo.rollback(:unavailable)
    end
  end

  defp update_settled_obligation(lane, claim, state, result, error) do
    table = obligation_table(lane)

    Repo.query(
      """
      UPDATE #{table}
      SET state = $4,
          claim_token = NULL,
          lease_until = NULL,
          result = $5,
          last_error = $6,
          updated_at = statement_timestamp()
      WHERE namespace_key = $1 AND run_id = $2 AND claim_token = $3
      RETURNING 1
      """,
      [claim.namespace_key, claim.run_id, claim.claim_token, state, result, error]
    )
  end

  defp obligation_table(:primary), do: "triage_product_obligations"

  defp obligation_table(:companion_reaction),
    do: "triage_companion_reaction_obligations"

  defp apply_context_candidates(payload, obligation_id, effect) do
    project_id = get_in(payload, ["product_identity", "project_id"])
    agent_id = get_in(payload, ["product_identity", "agent_id"])
    candidates = payload["context_candidates"] || []

    entries =
      Enum.map(candidates, fn candidate ->
        cond do
          candidate["kind"] == "follow_up_resolution" ->
            resolve_context_follow_up(project_id, obligation_id, candidate, payload, effect)

          candidate["kind"] == "follow_up" and Map.has_key?(candidate, "follow_up_ref") ->
            reuse_context_follow_up(project_id, obligation_id, candidate, payload, effect)

          true ->
            apply_context_candidate(project_id, agent_id, obligation_id, candidate, payload)
        end
      end)

    %{
      "candidate_count" => length(entries),
      "active_count" => Enum.count(entries, &(&1["state"] == "active")),
      "proposed_count" => Enum.count(entries, &(&1["state"] == "proposed")),
      "resolved_count" => Enum.count(entries, &(&1["state"] == "resolved")),
      "entries" => entries
    }
  end

  # Completion is an explicit evaluator effect, never inferred from activity.
  # The product row lock composes with admit_follow_up_wakeup/5: either its
  # rearm wins first and becomes inert, or resolution wins and admission stops.
  # Protocol anchor: tla/salix/TriageFollowUpSchedule.tla, ResolveCompleted.
  defp resolve_context_follow_up(
         project_id,
         obligation_id,
         candidate,
         obligation,
         %{outcome: :applied} = effect
       ) do
    refs = candidate["source_refs"] || []
    context_refs = Enum.filter(refs, &String.starts_with?(&1, "triage-context://"))

    with "explicit" <- candidate["confidence"],
         ["triage-context://" <> entry_id] <- context_refs,
         true <- current_completion_evidence?(refs, obligation),
         {:ok, %{rows: [["active", payload]]}} <-
           Repo.query(
             "SELECT state, payload FROM triage_context_entries WHERE entry_id = $1 AND project_id = $2 AND kind = 'follow_up' FOR UPDATE",
             [entry_id, project_id]
           ),
         true <- payload["target"] == obligation["target"],
         {:ok, reason} <- follow_up_resolution_reason(payload, obligation, candidate, effect) do
      resolved =
        payload
        |> Map.put("resolved_reason", reason)
        |> Map.put("resolution", candidate)
        |> Map.put("last_obligation_id", obligation_id)

      Repo.query!(
        "UPDATE triage_context_entries SET state = 'resolved', payload = $2, resolved_at = statement_timestamp(), updated_at = statement_timestamp() WHERE entry_id = $1",
        [entry_id, resolved]
      )

      %{"entry_id" => entry_id, "state" => "resolved", "disposition" => reason}
    else
      {:error, _reason} -> Repo.rollback(:unavailable)
      _stale_or_unproven -> %{"state" => "ignored", "disposition" => "resolution_not_authorized"}
    end
  end

  defp resolve_context_follow_up(_project_id, _obligation_id, _candidate, _obligation, _outcome),
    do: %{"state" => "ignored", "disposition" => "resolution_not_applied"}

  # A reminder completes only when this scheduled evaluation delivers its reply.
  # An audit capture or a reply from an older evaluation cannot complete it.
  defp follow_up_resolution_reason(
         %{"follow_up_basis" => "reminder_confirmed"} = payload,
         obligation,
         %{"resolution_basis" => "reminder_delivery"} = candidate,
         effect
       ) do
    event_id = payload["last_wakeup_event_id"]
    context_ref = "triage-context://" <> payload["entry_id"]

    if effect.adapter == :slack and
         effect.communication["kind"] == "reply" and
         effect.communication["status"] == "delivered" and
         is_binary(event_id) and event_id in (obligation["recheck_event_ids"] || []) and
         context_ref in (effect.communication["source_refs"] || []) and
         context_ref in candidate["source_refs"] do
      {:ok, "reminder_delivered"}
    else
      :unproven
    end
  end

  defp follow_up_resolution_reason(
         _payload,
         _obligation,
         %{"resolution_basis" => "reminder_delivery"},
         _effect
       ),
       do: :unproven

  defp follow_up_resolution_reason(_payload, _obligation, _candidate, _effect),
    do: {:ok, "evidenced_completion"}

  defp current_completion_evidence?(refs, obligation) do
    target = obligation["target"]
    prefix = "slack://#{target["workspace_id"]}/#{target["channel_id"]}/#{target["thread_ts"]}/"

    Enum.any?(obligation["source_authority"] || [], fn message ->
      (prefix <> message["message_ts"]) in refs
    end)
  end

  defp reuse_context_follow_up(project_id, obligation_id, candidate, obligation, %{
         outcome: :applied
       }) do
    refs = candidate["source_refs"] || []

    with "triage-context://" <> entry_id <- candidate["follow_up_ref"],
         true <- candidate["follow_up_ref"] in refs,
         "explicit" <- candidate["confidence"],
         true <- current_completion_evidence?(refs, obligation),
         {:ok, %{rows: [["active", payload]]}} <-
           Repo.query(
             "SELECT state, payload FROM triage_context_entries WHERE entry_id = $1 AND project_id = $2 AND kind = 'follow_up' FOR UPDATE",
             [entry_id, project_id]
           ),
         true <- payload["target"] == obligation["target"] do
      # Creation keys remain the original admission/deduplication identity.
      # The current description is mutable; schedule authority is not.
      updated = Map.merge(payload, Map.take(candidate, ~w(subject value)))
      reinforce_context(%{entry_id: entry_id, payload: updated}, refs, obligation_id, candidate)
    else
      {:error, _reason} -> Repo.rollback(:unavailable)
      _ -> %{"state" => "ignored", "disposition" => "follow_up_reuse_not_authorized"}
    end
  end

  defp reuse_context_follow_up(_project_id, _obligation_id, _candidate, _obligation, _effect),
    do: %{"state" => "ignored", "disposition" => "follow_up_reuse_not_applied"}

  defp apply_context_candidate(project_id, agent_id, obligation_id, candidate, obligation) do
    kind = candidate["kind"]
    subject = String.trim(candidate["subject"])
    value = String.trim(candidate["value"])
    source_refs = candidate["source_refs"] |> Enum.uniq() |> Enum.sort()

    subject_identity =
      if candidate["knowledge_scope"] do
        [
          candidate["knowledge_scope"],
          get_in(candidate, ["scope_owner", "id"]) || "",
          String.downcase(subject)
        ]
      else
        [String.downcase(subject)]
      end

    # An explicit new goal is admitted by this durable operation, not its title.
    # Replaying the same operation retains the same key.
    subject_identity =
      if kind == "follow_up" and candidate["follow_up_action"] == "create",
        do: ["explicit-create", obligation_id, value | subject_identity],
        else: subject_identity

    subject_key =
      Crypto.hex([
        "triage-context-subject-v1",
        <<0>>,
        kind,
        <<0>>,
        Enum.intersperse(subject_identity, <<0>>)
      ])

    value_key = Crypto.hex(["triage-context-value-v1", <<0>>, value])
    evidence_key = Crypto.hex(["triage-context-evidence-v1", <<0>>, framed(source_refs)])

    entry_id =
      "triage-context-" <>
        Crypto.hex([
          project_id,
          <<0>>,
          kind,
          <<0>>,
          subject_key,
          <<0>>,
          value_key,
          <<0>>,
          evidence_key
        ])

    active = lock_active_context(project_id, kind, subject_key)

    if active != nil and active.value_key == value_key do
      reinforce_context(active, source_refs, obligation_id, candidate)
    else
      state = context_state(candidate, active)

      insert_context_entry(
        entry_id,
        project_id,
        agent_id,
        kind,
        subject_key,
        value_key,
        evidence_key,
        state,
        candidate,
        source_refs,
        obligation_id,
        obligation
      )
    end
  end

  defp lock_active_context(project_id, kind, subject_key) do
    case Repo.query(
           """
           SELECT entry_id, value_key, payload
           FROM triage_context_entries
           WHERE project_id = $1 AND kind = $2 AND subject_key = $3 AND state = 'active'
           FOR UPDATE
           """,
           [project_id, kind, subject_key]
         ) do
      {:ok, %{rows: [[entry_id, value_key, payload]]}} ->
        %{entry_id: entry_id, value_key: value_key, payload: payload}

      _other ->
        nil
    end
  end

  defp reinforce_context(active, source_refs, obligation_id, candidate) do
    old_refs = active.payload["source_refs"] || []
    refs = (old_refs ++ source_refs) |> Enum.uniq() |> Enum.sort() |> Enum.take(20)

    payload =
      active.payload
      |> Map.put("source_refs", refs)
      |> Map.put("last_obligation_id", obligation_id)
      |> merge_context_attribution(candidate)

    Repo.query!(
      "UPDATE triage_context_entries SET payload = $2, updated_at = statement_timestamp() WHERE entry_id = $1",
      [active.entry_id, payload]
    )

    %{"entry_id" => active.entry_id, "state" => "active", "disposition" => "reinforced"}
  end

  defp merge_context_attribution(payload, candidate) do
    if candidate["source_attribution"] do
      attribution =
        ((payload["source_attribution"] || []) ++ candidate["source_attribution"])
        |> Enum.uniq_by(& &1["source_ref"])
        |> Enum.filter(&(&1["source_ref"] in payload["source_refs"]))
        |> Enum.take(20)

      Map.put(payload, "source_attribution", attribution)
    else
      payload
    end
  end

  defp insert_context_entry(
         entry_id,
         project_id,
         agent_id,
         kind,
         subject_key,
         value_key,
         evidence_key,
         state,
         candidate,
         source_refs,
         obligation_id,
         obligation
       ) do
    schedule_id =
      if kind == "follow_up" and state == "active", do: Ids.new_schedule_id(), else: nil

    payload =
      %{
        "schema" => "comma.triage-context-entry.v1",
        "entry_id" => entry_id,
        "obligation_id" => obligation_id,
        "last_obligation_id" => obligation_id,
        "kind" => kind,
        "subject" => String.trim(candidate["subject"]),
        "value" => String.trim(candidate["value"]),
        "confidence" => candidate["confidence"],
        "source_refs" => source_refs
      }
      |> Map.merge(Map.take(candidate, ~w(knowledge_scope scope_owner)))
      |> merge_context_attribution(candidate)
      |> then(fn payload ->
        if kind == "follow_up",
          do: Map.put(payload, "follow_up_basis", candidate["follow_up_basis"]),
          else: payload
      end)
      |> put_follow_up_authority(kind, state, candidate, obligation, schedule_id)

    recheck_hours = candidate["recheck_after_hours"]

    next_check_sql =
      if kind == "follow_up",
        do: "statement_timestamp() + ($10::bigint * interval '1 hour')",
        else: "NULL"

    params =
      [
        entry_id,
        project_id,
        agent_id,
        kind,
        subject_key,
        value_key,
        evidence_key,
        state,
        payload
      ] ++ if(kind == "follow_up", do: [recheck_hours], else: [])

    case Repo.query(
           """
           INSERT INTO triage_context_entries
             (entry_id, project_id, agent_id, kind, subject_key, value_key, evidence_key,
              state, payload, next_check_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, #{next_check_sql})
           ON CONFLICT (project_id, kind, subject_key, value_key, evidence_key) DO NOTHING
           RETURNING entry_id, state, next_check_at
           """,
           params
         ) do
      {:ok, %{rows: [[stored_id, stored_state, next_check_at]]}} ->
        :ok = maybe_create_follow_up_schedule(payload, next_check_at)

        %{"entry_id" => stored_id, "state" => stored_state, "disposition" => "created"}

      {:ok, %{rows: []}} ->
        case Repo.query(
               """
               SELECT entry_id, state
               FROM triage_context_entries
               WHERE project_id = $1 AND kind = $2 AND subject_key = $3
                 AND value_key = $4 AND evidence_key = $5
               """,
               [project_id, kind, subject_key, value_key, evidence_key]
             ) do
          {:ok, %{rows: [[stored_id, stored_state]]}} ->
            %{
              "entry_id" => stored_id,
              "state" => stored_state,
              "disposition" => "duplicate"
            }

          _other ->
            Repo.rollback(:conflict)
        end

      {:error, _reason} ->
        Repo.rollback(:unavailable)
    end
  end

  defp context_state(%{"knowledge_scope" => "unattributed"}, _active), do: "proposed"

  defp context_state(
         %{"kind" => "follow_up", "confidence" => "explicit", "follow_up_basis" => basis},
         nil
       )
       when basis in ["reminder_confirmed", "agent_owned"], do: "active"

  defp context_state(%{"kind" => "follow_up"}, _active), do: "proposed"
  defp context_state(%{"confidence" => "explicit"}, nil), do: "active"
  defp context_state(_candidate, _active), do: "proposed"

  defp put_follow_up_authority(payload, "follow_up", "active", candidate, obligation, schedule_id) do
    trigger_message_ts =
      obligation
      |> get_in(["target_cutoff", "event_message_timestamps"])
      |> List.wrap()
      |> Enum.max(fn -> nil end)

    Map.merge(payload, %{
      "schedule_id" => schedule_id,
      "authority_generation" => get_in(obligation, ["target", "connect_generation"]),
      "target" => obligation["target"],
      "product_identity" => obligation["product_identity"],
      "trigger_message_ts" => trigger_message_ts,
      "recheck_after_hours" => candidate["recheck_after_hours"]
    })
  end

  defp put_follow_up_authority(payload, _kind, _state, _candidate, _obligation, _schedule_id),
    do: payload

  defp maybe_create_follow_up_schedule(
         %{
           "entry_id" => entry_id,
           "schedule_id" => schedule_id,
           "authority_generation" => authority_generation
         },
         %DateTime{} = next_check_at
       ) do
    create_follow_up_schedule(entry_id, authority_generation, schedule_id, next_check_at)
  end

  defp maybe_create_follow_up_schedule(_payload, _next_check_at), do: :ok

  defp create_follow_up_schedule(entry_id, authority_generation, schedule_id, next_check_at) do
    run_at = DateTime.to_unix(next_check_at, :millisecond)

    record = %{
      "id" => schedule_id,
      "receiver" => "triage_follow_up",
      "payload" => %{
        "entry_id" => entry_id,
        "authority_generation" => authority_generation
      },
      "run_at" => run_at,
      "created_at" => System.system_time(:millisecond),
      "last_run" => nil
    }

    case Schedules.create(record, run_at) do
      {:ok, _schedule} -> :ok
      {:error, _reason} -> Repo.rollback(:unavailable)
    end
  end

  defp lock_follow_up(entry_id) do
    case Repo.query(
           """
           SELECT state, payload, extract(epoch FROM next_check_at) * 1000
           FROM triage_context_entries
           WHERE entry_id = $1 AND kind = 'follow_up'
           FOR UPDATE
           """,
           [entry_id]
         ) do
      {:ok, %{rows: [[state, payload, due_ms]]}} ->
        {:ok, %{state: state, payload: payload, due_ms: due_ms}}

      {:ok, %{rows: []}} ->
        :missing

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp exact_follow_up_wakeup?(
         payload,
         authority_generation,
         schedule_id,
         due_ms,
         scheduled_for_ms
       ) do
    is_map(payload) and payload["schema"] == "comma.triage-context-entry.v1" and
      payload["kind"] == "follow_up" and payload["schedule_id"] == schedule_id and
      payload["authority_generation"] == authority_generation and
      get_in(payload, ["target", "connect_generation"]) == authority_generation and
      integer_ms(due_ms) == scheduled_for_ms
  end

  defp settle_current_follow_up(entry_id, payload, scheduled_for_ms, :answered) do
    resolved_payload =
      payload
      |> Map.put("last_wakeup_schedule_id", payload["schedule_id"])
      |> Map.put("last_wakeup_scheduled_for_ms", scheduled_for_ms)

    case Repo.query(
           """
           UPDATE triage_context_entries
           SET state = 'resolved', payload = $2, resolved_at = statement_timestamp(),
               updated_at = statement_timestamp()
           WHERE entry_id = $1 AND state = 'active'
           RETURNING 1
           """,
           [entry_id, resolved_payload]
         ) do
      {:ok, %{rows: [[1]]}} -> :resolved
      {:ok, %{rows: []}} -> :stale
      {:error, _reason} -> Repo.rollback(:unavailable)
    end
  end

  defp settle_current_follow_up(entry_id, payload, scheduled_for_ms, :stale_authority) do
    resolved_payload =
      payload
      |> Map.put("last_wakeup_schedule_id", payload["schedule_id"])
      |> Map.put("last_wakeup_scheduled_for_ms", scheduled_for_ms)
      |> Map.put("resolved_reason", "source_authority_stale")

    case Repo.query(
           """
           UPDATE triage_context_entries
           SET state = 'resolved', payload = $2, resolved_at = statement_timestamp(),
               updated_at = statement_timestamp()
           WHERE entry_id = $1 AND state = 'active'
           RETURNING 1
           """,
           [entry_id, resolved_payload]
         ) do
      {:ok, %{rows: [[1]]}} -> :stopped
      {:ok, %{rows: []}} -> :stale
      {:error, _reason} -> Repo.rollback(:unavailable)
    end
  end

  defp settle_current_follow_up(entry_id, payload, scheduled_for_ms, :admitted) do
    schedule_id = Ids.new_schedule_id()
    recheck_hours = payload["recheck_after_hours"]

    case Repo.query(
           """
           UPDATE triage_context_entries
           SET next_check_at = statement_timestamp() + ($3::bigint * interval '1 hour'),
               payload = $2,
               updated_at = statement_timestamp()
           WHERE entry_id = $1 AND state = 'active'
           RETURNING next_check_at
           """,
           [
             entry_id,
             payload
             |> Map.put("last_wakeup_schedule_id", payload["schedule_id"])
             |> Map.put("last_wakeup_scheduled_for_ms", scheduled_for_ms)
             |> Map.put("schedule_id", schedule_id),
             recheck_hours
           ]
         ) do
      {:ok, %{rows: [[%DateTime{} = next_check_at]]}} ->
        :ok =
          create_follow_up_schedule(
            entry_id,
            payload["authority_generation"],
            schedule_id,
            next_check_at
          )

        :rescheduled

      {:ok, %{rows: []}} ->
        :stale

      {:error, _reason} ->
        Repo.rollback(:unavailable)
    end
  end

  defp integer_ms(value) when is_integer(value), do: value
  defp integer_ms(value) when is_float(value), do: trunc(value)

  defp integer_ms(%Decimal{} = value),
    do: value |> Decimal.round(0, :floor) |> Decimal.to_integer()

  defp integer_ms(_value), do: nil

  defp normalize_follow_up_transaction({:ok, result})
       when result in [:resolved, :stopped, :rescheduled, :stale],
       do: {:ok, result}

  defp normalize_follow_up_transaction({:error, _reason}), do: {:error, :unavailable}

  defp normalize_follow_up_admission_transaction({:ok, result})
       when result in [:rescheduled, :stale],
       do: {:ok, result}

  defp normalize_follow_up_admission_transaction({:error, {:admission_callback, result}}),
    do: result

  defp normalize_follow_up_admission_transaction({:error, _reason}), do: {:error, :unavailable}

  defp normalize_effect(effect) do
    adapter = effect[:adapter]
    outcome = effect[:outcome]
    external_writes = effect[:external_writes]
    communication = effect[:communication]
    metadata = effect[:metadata] || %{}
    error = normalize_error(effect[:error])
    retry? = effect[:retry] == true

    if adapter in [:slack, :audit_sink] and outcome in [:applied, :stale, :failed] and
         is_integer(external_writes) and external_writes >= 0 and is_map(communication) and
         is_map(metadata) and (not retry? or outcome == :failed) do
      {:ok,
       %{
         adapter: adapter,
         outcome: outcome,
         external_writes: external_writes,
         communication: communication,
         metadata: metadata,
         error: error,
         retry?: retry?
       }}
    else
      {:error, :invalid}
    end
  end

  defp settlement_state(%{outcome: :failed, retry?: true}), do: "pending"
  defp settlement_state(%{outcome: outcome}), do: Atom.to_string(outcome)

  defp validate_claim(claim) do
    if nonempty?(claim[:namespace_key]) and nonempty?(claim[:run_id]) and
         nonempty?(claim[:obligation_id]) and nonempty?(claim[:claim_token]) and
         is_integer(claim[:attempt]) and claim[:attempt] > 0 and is_map(claim[:payload]) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp attempt_id(claim) do
    "triage-product-attempt-" <>
      Crypto.hex([
        claim.namespace_key,
        <<0>>,
        claim.run_id,
        <<0>>,
        Integer.to_string(claim.attempt),
        <<0>>,
        claim.claim_token
      ])
  end

  defp outcome_row([
         obligation_id,
         target,
         source_messages,
         communication,
         context_candidates,
         delegations,
         target_cutoff,
         state,
         attempts,
         result,
         inserted_at,
         updated_at,
         companion_obligation_id,
         companion_communication,
         companion_state,
         companion_attempts,
         companion_result,
         companion_updated_at
       ]) do
    %{
      obligation_id: obligation_id,
      target: target,
      source_messages: source_messages || [],
      decision: communication,
      context_candidates: context_candidates || [],
      delegations: delegations || [],
      target_cutoff: target_cutoff || %{},
      state: state_atom(state),
      attempts: attempts,
      result: result,
      companion:
        companion_outcome(
          companion_obligation_id,
          companion_communication,
          companion_state,
          companion_attempts,
          companion_result,
          companion_updated_at
        ),
      inserted_at: decimal_millis(inserted_at),
      updated_at: decimal_millis(updated_at)
    }
  end

  defp companion_outcome(nil, _communication, _state, _attempts, _result, _updated_at),
    do: nil

  defp companion_outcome(
         obligation_id,
         communication,
         state,
         attempts,
         result,
         updated_at
       ) do
    %{
      obligation_id: obligation_id,
      decision: communication,
      state: state_atom(state),
      attempts: attempts,
      result: result,
      updated_at: decimal_millis(updated_at)
    }
  end

  defp context_row([
         entry_id,
         kind,
         state,
         payload,
         next_check_at,
         resolved_at,
         inserted_at,
         updated_at
       ]) do
    stopped? = state == "resolved" and payload["resolved_reason"] == "source_authority_stale"

    %{
      entry_id: entry_id,
      kind: kind,
      state: if(stopped?, do: :stopped, else: state_atom(state)),
      payload: payload,
      next_check_at: if(state == "active", do: next_check_at),
      resolved_at: if(stopped?, do: nil, else: resolved_at),
      stopped_at: if(stopped?, do: resolved_at),
      inserted_at: decimal_millis(inserted_at),
      updated_at: decimal_millis(updated_at)
    }
  end

  defp normalize_transaction({:ok, %{status: _status} = result}), do: {:ok, result}

  defp normalize_transaction({:error, reason})
       when reason in [:conflict, :invalid, :unavailable],
       do: {:error, reason}

  defp normalize_transaction({:error, _reason}), do: {:error, :unavailable}

  defp normalize_error(nil), do: nil

  defp normalize_error(value) when is_binary(value),
    do: binary_part(value, 0, min(byte_size(value), @max_error_bytes))

  defp normalize_error(_value), do: nil

  defp framed(parts),
    do: Enum.map(parts, fn part -> [Integer.to_string(byte_size(part)), ":", part, ";"] end)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp state_atom(value)
       when value in [
              "pending",
              "claimed",
              "applied",
              "stale",
              "failed",
              "active",
              "proposed",
              "resolved",
              "superseded"
            ],
       do: String.to_existing_atom(value)

  defp state_atom(_value), do: :unknown
  defp decimal_millis(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp decimal_millis(value) when is_number(value), do: round(value)
  defp valid_holder?(value), do: nonempty?(value) and byte_size(value) <= 200
  defp valid_limit?(value), do: is_integer(value) and value in 1..@max_claim
  defp valid_lease?(value), do: is_integer(value) and value in @min_lease_ms..@max_lease_ms
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
