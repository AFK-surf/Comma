defmodule SalixIM.Triage.ReadModel do
  @moduledoc """
  Read-only window over native Slack Triage durable state, for the BFT
  Triage Workbench.

  This module never writes. It holds no CAS update, no lease, no receipt
  record, and no runtime effect: every function is a bounded read that
  re-uses the validation already owned by `SalixIM.ProviderReceipts` and
  `SalixIM.Triage.Bucketing`, so the dashboard never re-implements record
  semantics on the far side of the erpc seam.

  The namespace is always an explicit argument. The composition root and BFT
  both use the same stable product-owned namespace; this module reads no
  configuration of its own.

  ## Honest scans

  Triage record-address spaces are opaque: any listed row is a legal cursor
  position, including a marker at exactly the prefix and a malformed or
  trailing-space address. Poison records are counted and skipped, never fatal and
  never page-pinning — the same discipline as
  `ProviderReceipts.list_slack_triage_page/3`. An empty scan and a failed
  scan stay distinguishable: a page never degrades into `{:ok, %{...[]}}`.

  A skipped record and an unreadable one are two different facts and are
  counted separately. `invalid_count` is what the scan **refused** to emit (a
  bad key shape, a body that is not a valid record, a record parked at the
  wrong key); `unavailable_count` is what it **could not read** (a GET that
  failed). Folding the second into the first would let a storage fault read as
  "these records are poison", which is exactly the lie the honest-scan counts
  exist to prevent.

  ## Raw locators

  A bucket key is an opaque durable-record address handed back by a previous
  list. It is read byte-identically and never trimmed: a trailing space is a
  legal address that selects a *different* record than its trimmed sibling, so normalizing
  here would GET a nonexistent neighbour of the exact record the scan listed.
  Reads are confined to the namespace's bucket prefix; anything outside it
  addresses nothing.

  ## Taxonomy of returns

    * `list_buckets/3` — `{:error, :invalid_triage_bucket_cursor}` for an
      undecodable cursor, `{:error, :invalid_triage_bucket_page}` for
      malformed arguments, `{:error, :unavailable}` for a storage fault or an
      unavailable-shaped page (unsorted, duplicated, or not strictly beyond
      the cursor).
    * `get_bucket/2` — `{:error, :not_found}` when nothing is stored at that
      exact raw key (or the key lies outside the namespace),
      `{:error, :invalid_triage_bucket}` when the record is not a valid
      `comma.triage-durable-bucket.v1`, `{:error, :unavailable}` on a storage
      fault.
    * `list_receipts_page/1` — passes the `ProviderReceipts` taxonomy through
      unchanged.
    * `recent_window/3` — `{:error, :invalid_triage_recent_window}` for
      malformed arguments, `{:error, :unavailable}` for a storage fault.
    * `ring_status/1` and `connect_posture/2` — `{:error, :unavailable}`.
  """

  alias SalixIM.Triage.{Bucketing, FileAttachments, IdentityContract, Ledger, Pipeline, RunFence}
  alias SalixIM.{GroupDirectory, ProviderConnects, ProviderReceipts}
  alias SalixStore.{CasRecord, TriageProductRuntime, ULID}

  @bucket_page_limit 25
  @receipt_page_limit 25
  @default_page_budget 8
  @max_page_budget 40
  @default_processing_limit 20
  @max_processing_limit 20
  @default_knowledge_context_limit 50
  @max_knowledge_context_limit 99
  @interactive_record_budget_bytes 4 * 1024 * 1024
  @processing_prefetch {__MODULE__, :processing_prefetch}

  # One budget for both introspection calls. 250ms was tight enough that a ring
  # doing real work (a recovery pass holding its own lease, a runtime under an
  # admission burst) answered late and was reported as a fault; a busy ring is
  # not a broken one. 1000ms still fits comfortably inside the dashboard's 3s
  # read budget, so a genuinely wedged process degrades one card rather than
  # hanging the page.
  @ring_call_timeout_ms 1_000

  # The production evaluator lives in downstream `salix_web`. Keep the module
  # a literal atom so this read-only projection can ask its credential-free
  # readiness predicate without introducing a compile-time dependency.
  @product_evaluator :"Elixir.Salix.Bindings.TriageEvaluator"

  @lower_hex_64 ~r/\A[0-9a-f]{64}\z/

  @doc """
  Lists one bounded page of durable buckets for this namespace.

  Bucket identity lives in the record body; addresses are sha256 and opaque, so
  the page is a prefix list plus bounded record reads sharing one
  #{@interactive_record_budget_bytes}-byte body budget. The
  cursor is `"v1." <> base64url(raw_key)` and any listed key is a valid
  position. `invalid_count` covers every record the page refused to emit: a
  non-bucket key shape, a body that is not a valid durable bucket, and a body
  whose scope does not hash back to its own key. `unavailable_count` is its own
  number and covers records whose GET failed or whose body was refused after
  the shared page budget was exhausted — those may be perfectly valid records
  that simply could not be read right now. `truncated: true` means remaining
  listed bodies were not opened.
  """
  def list_buckets(namespace, cursor \\ nil, limit \\ @bucket_page_limit)

  def list_buckets(namespace, cursor, limit)
      when is_binary(namespace) and namespace != "" and
             (is_binary(cursor) or is_nil(cursor)) and
             is_integer(limit) and limit in 1..@bucket_page_limit do
    prefix = SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    with {:ok, start_after} <- decode_bucket_cursor(cursor, prefix),
         opts <- [max_keys: limit] |> maybe_put_start_after(start_after),
         {:ok, %{objects: objects, next: next}} <- SalixStore.TriageRecordStore.list(prefix, opts),
         :ok <- validate_bucket_page_objects(objects, start_after, next, prefix),
         {:ok, next_cursor} <- next_bucket_cursor(objects, next) do
      {:ok,
       objects
       |> hydrate_bucket_page(namespace, prefix)
       |> Map.merge(%{next_cursor: next_cursor, scan_complete: is_nil(next)})}
    else
      {:error, :invalid_triage_bucket_cursor} = error -> error
      _unavailable -> {:error, :unavailable}
    end
  end

  def list_buckets(_namespace, _cursor, _limit), do: {:error, :invalid_triage_bucket_page}

  @doc """
  Reads one durable bucket by its exact opaque record address, with embedded receipts.

  The key is never normalized (see the raw-locator note above) and is
  confined to this namespace's bucket prefix. A body above the interactive
  #{@interactive_record_budget_bytes}-byte budget is not decoded and returns
  `{:error, :unavailable}`.
  """
  def get_bucket(namespace, bucket_key)
      when is_binary(namespace) and namespace != "" and is_binary(bucket_key) do
    if String.starts_with?(
         bucket_key,
         SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)
       ) do
      read_bucket(bucket_key)
    else
      {:error, :not_found}
    end
  end

  def get_bucket(_namespace, _bucket_key), do: {:error, :invalid_triage_bucket}

  @doc """
  Reads one bounded global page of typed Slack Triage receipts.

  A pass-through of `ProviderReceipts.list_slack_triage_page/3`: the
  legacy/invalid/unavailable counts are part of the honest-scan contract and
  are handed to the caller exactly as produced. `legacy_count` is the
  compatibility bucket for historical untyped provider receipts. Intent
  settlements live in a disjoint PostgreSQL table and are invisible to this
  strict S3 receipt scan.
  """
  def list_receipts_page(cursor \\ nil),
    do: ProviderReceipts.list_slack_triage_page(:all, cursor, @receipt_page_limit)

  @doc """
  Walks the receipt scan under an explicit page budget and keeps the typed
  receipts created at or after `since_ms`, newest first.

  The receipt keyspace is key-ordered, not time-ordered, so a recent window
  is a bounded scan and not a query: `truncated: true` means the budget ran
  out before the scan completed and the window may be missing rows. The
  caller renders that, never an unqualified "N events".

  `namespace` is accepted for the namespace-partitioned scans the replay-run
  keyspace will need, but the receipt prefix is global today and this
  function does not filter by it — no receipt carries a namespace.

  Options: `:page_budget` (default #{@default_page_budget}, max
  #{@max_page_budget}).
  """
  def recent_window(namespace, since_ms, opts \\ [])

  def recent_window(namespace, since_ms, opts)
      when is_binary(namespace) and namespace != "" and is_integer(since_ms) and
             since_ms >= 0 and is_list(opts) do
    budget = Keyword.get(opts, :page_budget, @default_page_budget)

    if Keyword.keys(opts) -- [:page_budget] == [] and is_integer(budget) and
         budget in 1..@max_page_budget do
      walk_recent_window(nil, since_ms, budget, empty_window())
    else
      {:error, :invalid_triage_recent_window}
    end
  end

  def recent_window(_namespace, _since_ms, _opts), do: {:error, :invalid_triage_recent_window}

  @doc """
  Projects the latest bounded receipt window into durable processing states.

  A receipt alone proves only `:received`. A later state is emitted only when
  the exact durable bucket membership and, for sealed generations, the exact
  matching fence validate. Missing membership is therefore not mistaken for a
  queued evaluation, and a terminal is never inferred from the mere existence
  of a receipt.

  Returned items are deliberately narrow. Source text, namespace, physical
  bucket/fence addresses, raw run ids, provider payloads, model output, tool
  arguments, and raw failure reasons never cross this read boundary. Each item
  may expose product-safe diagnostics from the same already-budgeted evidence:
  source routing metadata, correlated milestone timestamps, a hashed trace
  reference, a bounded decision reason, and validated/bounded evaluator
  identity plus prompt/policy evidence references. No diagnostic causes an
  additional durable-record read.

  The receipt address space is key-ordered rather than time-ordered. This uses
  the same bounded scan as `recent_window/3`, then reads at most `:limit`
  candidates (default/max #{@default_processing_limit}), groups them by bucket
  scope before any downstream read, and charges bucket/fence/ledger bodies to
  one #{@interactive_record_budget_bytes}-byte budget. Every accepted bucket and
  generation is validated once. `truncated: true` means the scan budget ended,
  more recent receipts matched than the output limit, or the downstream byte
  budget could not cover the next exact record. Scan-health counts retain their
  receipt-scan meaning; additionally, `state_unavailable_count` counts emitted
  items whose downstream durable evidence could not be read or validated.

  Options: `:page_budget` (default #{@default_page_budget}, max
  #{@max_page_budget}) and `:limit` (default/max #{@default_processing_limit}).
  """
  def recent_processing(namespace, since_ms, opts \\ [])

  def recent_processing(namespace, since_ms, opts)
      when is_binary(namespace) and namespace != "" and is_integer(since_ms) and
             since_ms >= 0 and is_list(opts) do
    page_budget = Keyword.get(opts, :page_budget, @default_page_budget)
    limit = Keyword.get(opts, :limit, @default_processing_limit)

    if Keyword.keys(opts) -- [:page_budget, :limit] == [] and
         is_integer(page_budget) and page_budget in 1..@max_page_budget and
         is_integer(limit) and limit in 1..@max_processing_limit do
      with {:ok, window} <- recent_window(namespace, since_ms, page_budget: page_budget) do
        selected = Enum.take(window.receipts, limit)

        {items, processing_truncated?} = project_processing(namespace, selected)

        items =
          items
          |> Enum.map(&Map.delete(&1, :execution_id))
          |> Enum.sort_by(
            &{&1.observed_at_ms, &1.received_at_ms, &1.receipt_ref},
            :desc
          )

        {:ok,
         %{
           items: items,
           scanned_pages: window.scanned_pages,
           legacy_count: window.legacy_count,
           invalid_count: window.invalid_count,
           unavailable_count: window.unavailable_count,
           state_unavailable_count: Enum.count(items, &(&1.state == :unavailable)),
           truncated: window.truncated or length(window.receipts) > limit or processing_truncated?
         }}
      end
    else
      {:error, :invalid_triage_recent_processing}
    end
  end

  def recent_processing(_namespace, _since_ms, _opts),
    do: {:error, :invalid_triage_recent_processing}

  @doc """
  Returns the bounded product-facing lifecycle for one exact BFT Agent.

  Unlike `recent_processing/3`, this projection speaks in product outcomes:
  reply, reaction, or silence, context collected, worker delegations, and source
  activity attached to those outcomes. It never exposes the retired patrol
  scanner shape, run ids, claim tokens, provider payloads,
  raw failures, or transport metadata. Reply text and context values are
  included because they are the product output an operator must accept before
  a local rehearsal can be promoted.

  Options are independently bounded: `:limit` (outcomes) and `:context_limit`,
  each max 20. A zero context limit omits the unrelated Knowledge query.
  `:target` restricts history to one exact source and authority generation.
  That path selects recent executions through the source index before joining
  their current effects. It does not resolve a Task or infer its completion.

  A paged read may also pass `:channel_id`. Outcomes and intake are then read
  for that Slack channel only; follow-ups and context remain Agent-wide.
  A paged read may pass `:before_ms` to start before an instant instead of at
  a cursor.
  """
  def product_activity(project_id, group_id, agent_id, opts \\ [])

  def product_activity(project_id, group_id, agent_id, opts)
      when is_binary(project_id) and project_id != "" and is_binary(group_id) and
             group_id != "" and is_binary(agent_id) and agent_id != "" and is_list(opts) do
    limit = Keyword.get(opts, :limit, 12)
    context_limit = Keyword.get(opts, :context_limit, 20)

    target = Keyword.get(opts, :target)
    source_opts = if is_nil(target), do: [], else: [target: target, group_id: group_id]
    paged? = Keyword.get(opts, :page, false)
    intake? = Keyword.get(opts, :include_intake, false)
    follow_ups? = Keyword.get(opts, :include_follow_ups, false)
    task_context? = Keyword.get(opts, :include_task_context, false)

    if Keyword.keys(opts) --
         [
           :limit,
           :context_limit,
           :target,
           :page,
           :cursor,
           :kind,
           :channel_id,
           :before_ms,
           :obligation_id,
           :include_intake,
           :include_follow_ups,
           :include_task_context,
           :context_entry_id
         ] == [] and
         limit in 1..20 and context_limit in 0..20 and is_boolean(paged?) and
         is_boolean(intake?) and is_boolean(follow_ups?) and
         is_boolean(task_context?) and (not task_context? or (limit <= 3 and is_map(target))) and
         (not paged? or is_nil(target)) and
         (paged? or
            Keyword.keys(opts) --
              [
                :limit,
                :context_limit,
                :target,
                :page,
                :include_intake,
                :include_follow_ups,
                :include_task_context,
                :context_entry_id
              ] == []) do
      with {:ok, page} <-
             activity_outcomes(project_id, group_id, agent_id, limit, source_opts, paged?, opts),
           {:ok, context} <-
             activity_context(
               project_id,
               agent_id,
               context_limit,
               Keyword.get(opts, :context_entry_id)
             ) do
        {:ok,
         page
         |> Map.update!(
           :outcomes,
           &Enum.map(&1, fn outcome ->
             outcome |> product_outcome() |> with_task_context(group_id, task_context?)
           end)
         )
         |> Map.put(:context, Enum.map(context, &product_context/1))
         |> maybe_put_intake(
           project_id,
           group_id,
           agent_id,
           intake?,
           Keyword.get(opts, :channel_id)
         )
         |> maybe_put_followups(project_id, agent_id, follow_ups?)}
      else
        _unavailable -> {:error, :unavailable}
      end
    else
      {:error, :invalid_triage_product_activity}
    end
  end

  def product_activity(_project_id, _group_id, _agent_id, _opts),
    do: {:error, :invalid_triage_product_activity}

  @heatmap_window_ms 7 * 24 * 3_600_000

  @doc """
  Agent-wide hourly outcome counts per Slack channel for the last seven days.

  The window starts on an hour boundary so its first bucket is complete. See
  `SalixStore.TriageProductRuntime.outcome_heatmap/4` for the cell bound.
  """
  def product_heatmap(project_id, group_id, agent_id) do
    hour_ms = 3_600_000
    now_ms = System.system_time(:millisecond)
    since_ms = div(now_ms, hour_ms) * hour_ms + hour_ms - @heatmap_window_ms

    TriageProductRuntime.outcome_heatmap(project_id, group_id, agent_id, since_ms)
  end

  # Only a source-specific context freeze opts in: three outcomes, two Tasks
  # each, three recent messages per Task. The ordinary dashboard adds no reads.
  defp with_task_context(outcome, group_id, true) do
    Map.update!(outcome, :delegations, fn delegations ->
      Enum.map(delegations, fn delegation ->
        Map.put(
          delegation,
          :task_context,
          SalixIM.Triage.TaskContext.read(group_id, outcome.obligation_id, delegation.index)
        )
      end)
    end)
  end

  defp with_task_context(outcome, _group_id, false), do: outcome

  defp activity_outcomes(project, group, agent, limit, _source_opts, true, opts),
    do:
      TriageProductRuntime.outcome_page(
        project,
        group,
        agent,
        [limit: limit] ++
          Keyword.take(opts, [:cursor, :kind, :channel_id, :before_ms, :obligation_id])
      )

  defp activity_outcomes(project, _group, agent, limit, source_opts, false, _opts) do
    with {:ok, outcomes} <-
           TriageProductRuntime.recent_outcomes(
             project,
             [limit: limit, agent_id: agent] ++ source_opts
           ),
         do: {:ok, %{outcomes: outcomes}}
  end

  defp maybe_put_intake(page, _project, _group, _agent, false, _channel_id), do: page

  defp maybe_put_intake(page, project, group, agent, true, channel_id) do
    result =
      with {:ok, window} <- SalixStore.TriageIntake.recent(group, 20, channel_id) do
        {items, truncated?} =
          project_processing(SalixStore.TriageKeys.default_namespace(), window.receipts, :summary)

        {:ok, outcome_ids} =
          TriageProductRuntime.outcome_ids_for_executions(
            project,
            group,
            agent,
            Enum.map(items, & &1[:execution_id])
          )

        receipts = Map.new(window.receipts, &{&1["receipt_ref"], &1})

        items =
          Enum.map(items, fn item ->
            event = receipts[item.receipt_ref]["triage_event"]

            item
            |> Map.put(:outcome_ref, public_event_ref(outcome_ids[item[:execution_id]]))
            |> Map.delete(:execution_id)
            |> Map.put(:source_text, event["text"] |> String.slice(0, 1024))
            |> Map.put(:source_actor, event["actor_id"])
            |> Map.put(:source_at_ms, slack_timestamp_ms(event["message_ts"]))
            |> Map.put(:source_message_ts, event["message_ts"])
            |> Map.put(:source_channel, event["bucket"]["channel_id"])
            |> Map.put(:source_thread_ts, event["bucket"]["thread_ts"])
            |> Map.put(
              :source_url,
              slack_thread_url(
                event["bucket"]["workspace_id"],
                event["bucket"]["channel_id"],
                event["bucket"]["thread_ts"]
              )
            )
          end)

        {:ok,
         %{
           items: Enum.sort_by(items, &{&1.received_at_ms, &1.receipt_ref}, :desc),
           truncated: window.truncated or truncated?
         }}
      end

    Map.put(page, :intake, result)
  rescue
    _ -> Map.put(page, :intake, {:error, :unavailable})
  catch
    :exit, _ -> Map.put(page, :intake, {:error, :unavailable})
  end

  @doc "Verifies one selected receipt's processing evidence within its current group."
  def processing_detail(group, receipt_ref) when is_binary(group) and is_binary(receipt_ref) do
    with {:ok, [receipt]} <- SalixStore.TriageIntake.by_refs(group, [receipt_ref]),
         {[item], _truncated?} <-
           project_processing(SalixStore.TriageKeys.default_namespace(), [receipt]) do
      {:ok, Map.delete(item, :execution_id)}
    else
      {:ok, []} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  def processing_detail(_group, _receipt_ref), do: {:error, :invalid}

  defp activity_context(_project_id, _agent_id, 0, _entry_id), do: {:ok, []}

  defp activity_context(project_id, agent_id, limit, entry_id),
    do:
      TriageProductRuntime.list_context(project_id,
        limit: limit,
        agent_id: agent_id,
        entry_id: entry_id
      )

  defp maybe_put_followups(page, _project, _agent, false), do: page

  defp maybe_put_followups(page, project, agent, true) do
    result =
      case TriageProductRuntime.list_context(project,
             agent_id: agent,
             kind: "follow_up",
             limit: 20
           ) do
        {:ok, entries} -> {:ok, Enum.map(entries, &product_context/1)}
        error -> error
      end

    Map.put(page, :follow_ups, result)
  end

  @doc """
  Explicit administrator debug read, separate from the product projections.
  The BFT caller audits before reading. One exact subject resolves one run;
  receipt subjects are restricted to the selected project's Salix group.
  The final ledger fetch has a 2 MiB budget; receipt routing uses the existing
  bounded processing projection. No new model calls or writes occur.
  """
  def model_debug(namespace, project, group, agent, kind, id)
      when is_binary(namespace) and is_binary(project) and is_binary(group) and
             is_binary(agent) and kind in ["outcome", "receipt"] and is_binary(id) and
             byte_size(id) in 1..2048 do
    with {:ok, run_id} <- debug_run_id(namespace, project, group, agent, kind, id),
         {:ok, run, _bytes} <- Ledger.fetch_bounded(namespace, run_id, 2_097_152) do
      proof = run["evaluator"] || %{}
      chain = proof["provider_payload_chain"] || run["provider_payload_chain"]

      payloads =
        if is_list(chain),
          do: Enum.map(Enum.take(chain, 3), & &1["payload_bytes"]),
          else: [proof["provider_payload_bytes"] || run["provider_payload_bytes"]]

      requests =
        Enum.map(payloads, fn bytes ->
          case bytes && Jason.decode(bytes) do
            {:ok, payload} when is_map(payload) -> payload
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         run_id: run_id,
         status: run["status"],
         provider: proof["provider"] || run["provider"],
         model: proof["model"] || run["model"],
         requests: requests,
         participation_decision: proof["participation_decision"] || run["participation_decision"],
         tool_receipts: proof["tool_receipts"] || run["tool_receipts"] || [],
         decision: run["decision"],
         raw_response: nil
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :not_found, _} -> {:error, :not_found}
      {:error, :too_large, _} -> {:error, :too_large}
      _ -> {:error, :unavailable}
    end
  end

  def model_debug(_, _, _, _, _, _), do: {:error, :invalid}

  defp debug_run_id(_namespace, project, group, agent, "outcome", id),
    do: TriageProductRuntime.debug_run_id(project, group, agent, id)

  defp debug_run_id(namespace, _project, group, _agent, "receipt", id) do
    with {:ok, [receipt]} <- SalixStore.TriageIntake.by_refs(group, [id]),
         {[item], false} <- project_processing(namespace, [receipt]),
         run_id when is_binary(run_id) <- item[:execution_id] do
      {:ok, run_id}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Resolves one original delegation to its canonical Task, without creating or
  repairing anything. The product caller authorizes org access; this boundary
  requires the immutable obligation to belong to its exact project and Agent.
  One indexed obligation read and one existing request/Conversation lookup are
  performed only on an explicit detail request, never for each Timeline row.
  """
  def delegation_task(namespace, project_id, group_id, agent_id, obligation_id, index)
      when is_binary(namespace) and namespace != "" and is_binary(project_id) and
             is_binary(group_id) and is_binary(agent_id) and is_binary(obligation_id) and
             index in 0..1 do
    with {:ok, original} <-
           TriageProductRuntime.fetch_delegation(
             SalixStore.TriageKeys.namespace_key(namespace),
             obligation_id,
             index
           ),
         %{
           "project_id" => ^project_id,
           "project_salix_group_id" => ^group_id,
           "agent_id" => ^agent_id
         } <- original.payload["product_identity"] do
      SalixIM.ConversationServer.lookup_task_create_request(
        group_id,
        "triage-delegation:#{obligation_id}:#{index}"
      )
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
      _foreign -> {:error, :not_found}
    end
  end

  def delegation_task(_namespace, _project, _group, _agent, _obligation, _index),
    do: {:error, :invalid_triage_delegation}

  @doc """
  Returns active Triage context as a project-scoped Knowledge projection.

  `triage_context_entries` remains the lifecycle authority. This read filters
  active rows at the store boundary, does not copy them into another knowledge
  table, and reports whether the bounded result is complete. The Agent id is
  an authorization/routing input only; it does not narrow project-shared
  Knowledge to the producing Agent.
  """
  def knowledge_context(project_id, group_id, agent_id, opts \\ [])

  def knowledge_context(project_id, group_id, agent_id, opts)
      when is_binary(project_id) and project_id != "" and is_binary(group_id) and
             group_id != "" and is_binary(agent_id) and agent_id != "" and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_knowledge_context_limit)

    if Keyword.keys(opts) -- [:limit, :query, :entry_ids] == [] and is_integer(limit) and
         limit in 1..@max_knowledge_context_limit do
      case TriageProductRuntime.list_active_context(project_id,
             limit: limit + 1,
             query: Keyword.get(opts, :query),
             entry_ids: Keyword.get(opts, :entry_ids, [])
           ) do
        {:ok, context} ->
          {:ok,
           %{
             items: context |> Enum.take(limit) |> Enum.map(&product_context/1),
             complete: length(context) <= limit
           }}

        _unavailable ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid_triage_knowledge_context}
    end
  end

  def knowledge_context(_project_id, _group_id, _agent_id, _opts),
    do: {:error, :invalid_triage_knowledge_context}

  @doc """
  Reports the native Triage review ring as its supervised processes see it.

  `salix_im` owns neither process name, so the caller supplies the refs:
  `%{runtime: server_ref | nil, recovery: server_ref | nil,
  evaluation_agent_id: String.t() | nil}`. Under `salix_web` those are
  `Salix.Bindings.TriageReviewRuntime` and
  `Salix.Bindings.TriageReceiptRecovery`. `evaluation_ready` is true only when
  the product evaluator is wired and the selected identity-bound Agent's live
  provider template has the complete shape required before a provider call. A
  missing Agent never claims ready. A `nil` process ref, or a registered name
  with no live process, reports `running: false` — the runtime being off is a
  fact, not a fault. A ref that is present but does not answer within
  #{@ring_call_timeout_ms}ms is `{:error, :unavailable}`.

  Both calls are read-only introspection handles.
  """
  def ring_status(refs) when is_map(refs) do
    with {:ok, runtime} <- runtime_status(Map.get(refs, :runtime)),
         {:ok, recovery} <- recovery_status(Map.get(refs, :recovery)) do
      runtime =
        attach_evaluation_readiness(runtime, Map.get(refs, :evaluation_agent_id))

      {:ok,
       %{
         running: runtime.running and recovery.running,
         runtime: runtime,
         recovery: recovery
       }}
    end
  end

  def ring_status(_refs), do: {:error, :unavailable}

  @doc """
  Per-connect Slack Triage posture for one group, display fields only.

  Never returns a credential: bot tokens, signing secrets, and client
  secrets are excluded by construction (the public projection is read
  through `ProviderConnects`, while the raw record contributes the non-secret
  installation tuple (`connect_generation`, `workspace_id`, and `app_id`), the
  one-way provisioning marker, and `source_ready?` authority derived from the
  active OAuth installation and its exact tenant/group/router binding).

  Each row carries `posture_complete?`. It is `false` when the raw record read
  failed, which means `provisioned?`, the installation tuple, and
  `source_ready?` are defaults rather than observations — the caller must never
  offer provisioning, channel-authority, or sourced-context actions on that
  row, nor render it as definitively "not provisioned". The public
  `triage_enabled` projection remains usable for the one fail-safe exception:
  an active source may still be disabled.
  """
  def connect_posture(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    with {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, connects} <- ProviderConnects.list_group_im_connects(group_id, "slack") do
      router_agent_id = present(group["router_agent_id"])
      {:ok, Enum.map(connects, &posture(tenant_id, group_id, router_agent_id, &1))}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  def connect_posture(_tenant_id, _group_id), do: {:error, :unavailable}

  # ---- buckets ----

  defp read_bucket(bucket_key) do
    case CasRecord.get_bounded(
           bucket_key,
           @interactive_record_budget_bytes,
           :invalid_triage_bucket
         ) do
      {:ok, record, _bytes} ->
        with :ok <- validate_durable_bucket(record) do
          {:ok,
           record
           |> bucket_view(bucket_key)
           |> Map.merge(%{
             receipts: record["open_receipts"],
             sealed_generations: record["sealed_generations"],
             sealed_receipts: sealed_receipts(record["sealed_generations"])
           })}
        end

      {:error, :not_found, _bytes} ->
        {:error, :not_found}

      {:error, :invalid_triage_bucket, _bytes} ->
        {:error, :invalid_triage_bucket}

      {:error, _reason, _bytes} ->
        {:error, :unavailable}
    end
  end

  defp hydrate_bucket_page(objects, namespace, prefix) do
    objects
    |> Enum.reduce(
      %{
        buckets: [],
        invalid_count: 0,
        unavailable_count: 0,
        remaining_bytes: @interactive_record_budget_bytes,
        truncated: false
      },
      fn %{key: key}, acc ->
        if valid_bucket_key?(key, prefix) do
          hydrate_bucket(namespace, key, acc)
        else
          Map.update!(acc, :invalid_count, &(&1 + 1))
        end
      end
    )
    |> Map.update!(:buckets, &Enum.reverse/1)
    |> Map.delete(:remaining_bytes)
  end

  defp hydrate_bucket(_namespace, _key, %{remaining_bytes: remaining} = acc)
       when remaining <= 0 do
    acc
    |> Map.update!(:unavailable_count, &(&1 + 1))
    |> Map.put(:truncated, true)
  end

  defp hydrate_bucket(namespace, key, acc) do
    case CasRecord.get_bounded(key, acc.remaining_bytes, :invalid_triage_bucket) do
      {:ok, record, bytes} ->
        acc = spend_bucket_bytes(acc, bytes)

        if validate_durable_bucket(record) == :ok and
             exact_bucket_storage_key?(namespace, record, key) do
          Map.update!(acc, :buckets, &[bucket_view(record, key) | &1])
        else
          Map.update!(acc, :invalid_count, &(&1 + 1))
        end

      # A body this scan refuses, and an object that vanished between the list
      # and the GET: in both cases there is nothing to emit and the object is
      # not evidence of a fault.
      {:error, reason, bytes} when reason in [:invalid_triage_bucket, :not_found] ->
        acc
        |> spend_bucket_bytes(bytes)
        |> Map.update!(:invalid_count, &(&1 + 1))

      {:error, :too_large, _bytes} ->
        acc
        |> Map.put(:remaining_bytes, 0)
        |> Map.put(:truncated, true)
        |> Map.update!(:unavailable_count, &(&1 + 1))

      # A failed GET is a different fact: the record may be entirely valid and
      # simply unreadable right now, so it must not be reported as poison.
      {:error, _fault, bytes} ->
        acc
        |> spend_bucket_bytes(bytes)
        |> Map.update!(:unavailable_count, &(&1 + 1))
    end
  end

  defp spend_bucket_bytes(acc, bytes),
    do: Map.update!(acc, :remaining_bytes, &max(0, &1 - bytes))

  # The bucket key is sha256(bucket_scope) under the namespace prefix, so a
  # listed record must hash back to the key it was found at. A record parked
  # at any other key is a poison object for the scan; `get_bucket/2` still
  # reads it byte-identically when a caller addresses it directly.
  defp exact_bucket_storage_key?(namespace, record, key),
    do: SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, record["bucket_scope"]) == key

  defp bucket_view(record, key) do
    open_receipts = record["open_receipts"]
    sealed_generations = record["sealed_generations"]
    sealed_receipts = sealed_receipts(sealed_generations)
    all_receipts = open_receipts ++ sealed_receipts

    %{
      bucket_key: key,
      bucket_scope: record["bucket_scope"],
      open_generation: record["open_generation"],
      open_first_at: record["open_first_at"],
      open_last_at: record["open_last_at"],
      open_receipt_count: length(open_receipts),
      sealed_generation_count: length(sealed_generations),
      sealed_receipt_count: length(sealed_receipts),
      receipt_count: length(all_receipts),
      fast_path: record["open_fast_path"],
      connect_id: bucket_connect_id(all_receipts)
    }
  end

  defp sealed_receipts(sealed_generations) do
    Enum.flat_map(sealed_generations, & &1["receipts"])
  end

  defp bucket_connect_id(receipts) do
    case receipts |> Enum.map(& &1["connect_id"]) |> Enum.uniq() do
      [connect_id] -> connect_id
      _empty_or_conflicting -> nil
    end
  end

  defp validate_durable_bucket(bucket), do: Bucketing.validate_durable_bucket(bucket)

  defp validate_bucket_page_objects(objects, start_after, next, prefix) when is_list(objects) do
    keys = Enum.map(objects, &Map.get(&1, :key))

    valid? =
      Enum.all?(keys, &valid_bucket_cursor_key?(&1, prefix)) and
        keys == Enum.sort(keys) and keys == Enum.uniq(keys) and
        (is_nil(start_after) or Enum.all?(keys, &(&1 > start_after))) and
        not (objects == [] and not is_nil(next))

    if valid?, do: :ok, else: {:error, :unavailable}
  end

  defp validate_bucket_page_objects(_objects, _start_after, _next, _prefix),
    do: {:error, :unavailable}

  defp valid_bucket_key?(key, prefix) when is_binary(key) do
    with true <- String.starts_with?(key, prefix),
         <<hash::binary-size(64), ".json">> <- String.replace_prefix(key, prefix, "") do
      Regex.match?(@lower_hex_64, hash)
    else
      _invalid -> false
    end
  end

  defp valid_bucket_key?(_key, _prefix), do: false

  # Any listed object under the prefix is a legal cursor position, including
  # a folder marker at exactly the prefix: one poison object is counted and
  # skipped instead of pinning the page.
  defp valid_bucket_cursor_key?(key, prefix) when is_binary(key),
    do: String.starts_with?(key, prefix)

  defp valid_bucket_cursor_key?(_key, _prefix), do: false

  defp decode_bucket_cursor(nil, _prefix), do: {:ok, nil}

  defp decode_bucket_cursor("v1." <> encoded, prefix) do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- valid_bucket_cursor_key?(key, prefix) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_triage_bucket_cursor}
    end
  end

  defp decode_bucket_cursor(_cursor, _prefix), do: {:error, :invalid_triage_bucket_cursor}

  defp next_bucket_cursor(_objects, nil), do: {:ok, nil}

  defp next_bucket_cursor(objects, _continuation) do
    case List.last(objects) do
      %{key: key} -> {:ok, "v1." <> Base.url_encode64(key, padding: false)}
      _missing -> {:error, :unavailable}
    end
  end

  defp maybe_put_start_after(opts, nil), do: opts
  defp maybe_put_start_after(opts, key), do: Keyword.put(opts, :start_after, key)

  # ---- recent window ----

  defp empty_window,
    do: %{
      receipts: [],
      scanned_pages: 0,
      legacy_count: 0,
      invalid_count: 0,
      unavailable_count: 0
    }

  defp walk_recent_window(cursor, since_ms, budget, acc) do
    case list_receipts_page(cursor) do
      {:ok, page} ->
        acc = merge_window_page(acc, page, since_ms)

        cond do
          page.scan_complete or is_nil(page.next_cursor) -> {:ok, finish_window(acc, false)}
          acc.scanned_pages >= budget -> {:ok, finish_window(acc, true)}
          true -> walk_recent_window(page.next_cursor, since_ms, budget, acc)
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp merge_window_page(acc, page, since_ms) do
    kept = Enum.filter(page.receipts, &(&1["created_at"] >= since_ms))

    %{
      acc
      | receipts: kept ++ acc.receipts,
        scanned_pages: acc.scanned_pages + 1,
        legacy_count: acc.legacy_count + page.legacy_count,
        invalid_count: acc.invalid_count + page.invalid_count,
        # A receipt whose GET failed is a hole in the window, not an absent
        # row: dropping this count would let the window read as complete when
        # it is only as complete as storage let it be.
        unavailable_count: acc.unavailable_count + page.unavailable_count
    }
  end

  defp finish_window(acc, truncated?) do
    receipts =
      Enum.sort_by(
        acc.receipts,
        &{&1["created_at"], &1["triage_event"]["message_ts"], &1["event_id"]},
        :desc
      )

    %{acc | receipts: receipts} |> Map.put(:truncated, truncated?)
  end

  # ---- recent processing ----

  # The summary projection reads one bucket per scope and one fence summary per
  # sealed group. `processing_prefetch/2` reads them in three queries up front;
  # the reducer below still decides every result and its byte budget, and it
  # reads anything the prefetch did not cover on its own.
  defp project_processing(namespace, selected, mode \\ :evidence)

  defp project_processing(namespace, selected, :summary) do
    previous = Process.put(@processing_prefetch, processing_prefetch(namespace, selected))

    try do
      reduce_processing(namespace, selected, :summary)
    after
      if previous,
        do: Process.put(@processing_prefetch, previous),
        else: Process.delete(@processing_prefetch)
    end
  end

  defp project_processing(namespace, selected, mode),
    do: reduce_processing(namespace, selected, mode)

  defp reduce_processing(namespace, selected, mode) do
    {items, _remaining, truncated?} =
      selected
      |> Enum.group_by(&Bucketing.scope_key/1)
      |> Enum.sort_by(fn {_scope, receipts} -> newest_receipt_key(receipts) end, :desc)
      |> Enum.reduce({[], @interactive_record_budget_bytes, false}, fn {scope, receipts},
                                                                       {items, remaining,
                                                                        truncated?} ->
        {scope_items, remaining, scope_truncated?} =
          processing_scope(namespace, scope, receipts, remaining, mode)

        {scope_items ++ items, remaining, truncated? or scope_truncated?}
      end)

    {items, truncated?}
  end

  defp processing_prefetch(namespace, selected) do
    scopes =
      selected
      |> Enum.group_by(&Bucketing.scope_key/1)
      |> Enum.sort_by(fn {_scope, receipts} -> newest_receipt_key(receipts) end, :desc)

    bucket_key = &SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, &1)

    buckets =
      scopes
      |> Enum.map(fn {scope, _receipts} -> bucket_key.(scope) end)
      |> Enum.take(100)
      |> CasRecord.prefetch_bounded(@interactive_record_budget_bytes)

    decoded =
      Map.new(scopes, fn {scope, _receipts} ->
        key = bucket_key.(scope)
        {key, prefetched_scope_bucket(buckets, key, scope)}
      end)

    {sealed_requests, missing} =
      Enum.reduce(scopes, {[], []}, fn {scope, receipts}, {requests, missing} ->
        case Map.fetch!(decoded, bucket_key.(scope)) do
          {:ok, bucket, _bytes} ->
            memberships = bucket_memberships(bucket)
            sealed = Map.new(bucket["sealed_generations"], &{&1["generation"], &1})

            receipts
            |> Enum.group_by(&Map.get(memberships, &1["receipt_ref"], :missing))
            |> Enum.reduce({requests, missing}, fn
              {{:sealed, generation}, _grouped}, {requests, missing} ->
                case Map.fetch(sealed, generation) do
                  {:ok, generation_record} ->
                    refs =
                      generation_record["receipts"]
                      |> Enum.take(20)
                      |> Enum.map(& &1["receipt_ref"])

                    {[{seal_key(namespace, scope, generation), refs} | requests], missing}

                  :error ->
                    {requests, missing}
                end

              {:missing, grouped}, {requests, missing} ->
                {requests, Enum.map(grouped, &{scope, &1}) ++ missing}

              _other, acc ->
                acc
            end)

          :skip ->
            {requests, missing}
        end
      end)

    {memberships, archived_requests} = prefetch_archived(namespace, missing)

    fences =
      (Enum.reverse(sealed_requests) ++ archived_requests)
      |> Enum.reject(fn {_key, refs} -> refs == [] end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(20)
      |> case do
        [] ->
          %{}

        requests ->
          case SalixStore.TriageRecords.processing_fences(requests) do
            {:ok, results} ->
              Map.new(requests, fn {key, refs} -> {key, {MapSet.new(refs), results[key]}} end)

            _error ->
              %{}
          end
      end

    %{buckets: buckets, decoded: decoded, memberships: memberships, fences: fences}
  end

  # Decoded once here and reused by the reducer. Only a valid bucket for this
  # scope drives planning; the reducer still validates what it consumes.
  defp prefetched_scope_bucket(buckets, key, scope) do
    with {:ok, {:ok, %{body: body, size: size}}} <- Map.fetch(buckets, key),
         {:ok, bucket} when is_map(bucket) <- Jason.decode(body),
         :ok <- Bucketing.validate_durable_bucket(bucket),
         true <- bucket["bucket_scope"] == scope do
      {:ok, bucket, size}
    else
      _ -> :skip
    end
  end

  defp prefetch_archived(_namespace, []), do: {nil, []}

  defp prefetch_archived(namespace, missing) when length(missing) <= 20 do
    identities =
      Enum.map(missing, fn {_scope, receipt} ->
        {SalixStore.Crypto.hex(Bucketing.source_key(receipt)),
         SalixStore.Crypto.hex(receipt["connect_id"])}
      end)

    case SalixStore.TriageRecords.receipt_memberships(namespace, identities) do
      {:ok, rows} ->
        by_ref = Map.new(rows, fn [ref, bucket, generation] -> {ref, {bucket, generation}} end)

        requests =
          missing
          |> Enum.group_by(fn {scope, receipt} -> {scope, by_ref[receipt["receipt_ref"]]} end)
          |> Enum.flat_map(fn
            {{scope, {bucket, generation}}, grouped} when is_binary(generation) ->
              if bucket == SalixStore.Crypto.hex(scope) do
                refs =
                  grouped |> Enum.take(20) |> Enum.map(fn {_scope, r} -> r["receipt_ref"] end)

                [{seal_key(namespace, scope, generation), refs}]
              else
                []
              end

            _other ->
              []
          end)

        covered = MapSet.new(missing, fn {_scope, receipt} -> receipt["receipt_ref"] end)
        {{covered, rows}, requests}

      _error ->
        {nil, []}
    end
  end

  defp prefetch_archived(_namespace, _missing), do: {nil, []}

  defp seal_key(namespace, scope, generation),
    do: SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

  defp prefetched_bucket(key, remaining) do
    case Process.get(@processing_prefetch) do
      %{decoded: %{^key => {:ok, bucket, size}}} when size <= remaining ->
        {:ok, bucket, size}

      %{buckets: buckets} ->
        CasRecord.from_prefetch(buckets, key, remaining, :invalid_triage_bucket)

      nil ->
        CasRecord.get_bounded(key, remaining, :invalid_triage_bucket)
    end
  end

  # The prefetched rows answer only receipts the prefetch asked about. Extra
  # rows for other scopes are harmless: the caller looks up its own refs.
  defp prefetched_memberships(namespace, identities, receipts) do
    with %{memberships: {covered, rows}} <- Process.get(@processing_prefetch),
         true <- Enum.all?(receipts, &MapSet.member?(covered, &1["receipt_ref"])) do
      {:ok, rows}
    else
      _ -> SalixStore.TriageRecords.receipt_memberships(namespace, identities)
    end
  end

  defp prefetched_fence(key, refs) do
    with %{fences: fences} <- Process.get(@processing_prefetch),
         {:ok, {requested, result}} <- Map.fetch(fences, key),
         true <- MapSet.equal?(requested, MapSet.new(refs)) do
      result
    else
      _ -> SalixStore.TriageRecords.processing_fence(key, refs)
    end
  end

  defp processing_scope(_namespace, _scope, receipts, remaining, _mode) when remaining <= 0,
    do: {unavailable_bases(receipts), 0, true}

  defp processing_scope(namespace, scope, receipts, remaining, mode) do
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    case prefetched_bucket(bucket_key, remaining) do
      {:ok, bucket, bytes} ->
        remaining = max(0, remaining - bytes)
        processing_from_scope_bucket(namespace, scope, receipts, bucket, remaining, mode)

      {:error, :not_found, _bytes} ->
        {Enum.map(receipts, &processing_base/1), remaining, false}

      {:error, :too_large, _bytes} ->
        {unavailable_bases(receipts), 0, true}

      {:error, _unreadable_or_invalid, bytes} ->
        {unavailable_bases(receipts), max(0, remaining - bytes), false}
    end
  end

  defp processing_from_scope_bucket(namespace, scope, receipts, bucket, remaining, mode) do
    with :ok <- Bucketing.validate_durable_bucket(bucket),
         true <- bucket["bucket_scope"] == scope do
      memberships = bucket_memberships(bucket)
      sealed = Map.new(bucket["sealed_generations"], &{&1["generation"], &1})

      receipts
      |> Enum.group_by(fn receipt ->
        Map.get(memberships, receipt["receipt_ref"], :missing)
      end)
      |> Enum.sort_by(fn {_membership, grouped} -> newest_receipt_key(grouped) end, :desc)
      |> Enum.reduce({[], remaining, false}, fn {membership, grouped},
                                                {items, remaining, truncated?} ->
        {grouped_items, remaining, group_truncated?} =
          processing_membership(
            namespace,
            scope,
            membership,
            grouped,
            bucket,
            sealed,
            remaining,
            mode
          )

        {grouped_items ++ items, remaining, truncated? or group_truncated?}
      end)
    else
      _invalid -> {unavailable_bases(receipts), remaining, false}
    end
  end

  defp processing_membership(
         namespace,
         scope,
         :missing,
         receipts,
         _bucket,
         _sealed,
         remaining,
         mode
       ) do
    identities =
      Enum.map(receipts, fn receipt ->
        {SalixStore.Crypto.hex(Bucketing.source_key(receipt)),
         SalixStore.Crypto.hex(receipt["connect_id"])}
      end)

    case prefetched_memberships(namespace, identities, receipts) do
      {:ok, rows} ->
        memberships =
          Map.new(rows, fn [ref, bucket, generation] -> {ref, {bucket, generation}} end)

        receipts
        |> Enum.group_by(&Map.get(memberships, &1["receipt_ref"]))
        |> Enum.sort_by(fn {_membership, grouped} -> newest_receipt_key(grouped) end, :desc)
        |> Enum.reduce({[], remaining, false}, fn {membership, grouped},
                                                  {items, budget, truncated} ->
          {next, budget, cut} =
            archived_processing(namespace, scope, membership, grouped, budget, mode)

          {next ++ items, budget, truncated or cut}
        end)

      {:error, _} ->
        {unavailable_bases(receipts), remaining, false}
    end
  end

  defp processing_membership(
         _namespace,
         _scope,
         :conflict,
         receipts,
         _bucket,
         _sealed,
         remaining,
         _mode
       ),
       do: {unavailable_bases(receipts), remaining, false}

  defp processing_membership(
         _namespace,
         _scope,
         :open,
         receipts,
         bucket,
         _sealed,
         remaining,
         _mode
       ) do
    item =
      receipts
      |> processing_group_base()
      |> Map.merge(%{
        state: :queued,
        observed_at_ms: bucket["open_last_at"],
        receipt_count: length(bucket["open_receipts"])
      })
      |> put_processing_milestone(:queued_at_ms, bucket["open_first_at"])
      |> maybe_mark_connect_conflict(receipts)

    {[item], remaining, false}
  end

  defp processing_membership(
         namespace,
         scope,
         {:sealed, generation},
         receipts,
         _bucket,
         sealed,
         remaining,
         mode
       ) do
    case Map.fetch(sealed, generation) do
      {:ok, sealed_generation} ->
        base =
          receipts
          |> processing_group_base()
          |> Map.merge(%{
            observed_at_ms: sealed_generation["sealed_at"],
            receipt_count: length(sealed_generation["receipts"])
          })
          |> put_processing_milestone(:sealed_at_ms, sealed_generation["sealed_at"])
          |> maybe_mark_connect_conflict(receipts)

        if base.state == :unavailable do
          {[base], remaining, false}
        else
          {item, remaining, truncated?} =
            processing_from_seal(namespace, scope, sealed_generation, base, remaining, mode)

          {[item], remaining, truncated?}
        end

      :error ->
        base = receipts |> processing_group_base() |> maybe_mark_connect_conflict(receipts)
        {[%{base | state: :unavailable}], remaining, false}
    end
  end

  defp archived_processing(_namespace, _scope, nil, receipts, remaining, _mode),
    do: {Enum.map(receipts, &processing_base/1), remaining, false}

  defp archived_processing(_namespace, _scope, _membership, receipts, remaining, _mode)
       when remaining <= 0,
       do: {unavailable_bases(receipts), 0, true}

  defp archived_processing(namespace, scope, {bucket, generation}, receipts, remaining, :summary) do
    base = receipts |> processing_group_base() |> maybe_mark_connect_conflict(receipts)

    if bucket == SalixStore.Crypto.hex(scope) and is_binary(generation) and
         base.state != :unavailable do
      {item, budget, cut} =
        processing_summary(namespace, scope, generation, receipts, base, remaining, true)

      {[item], budget, cut}
    else
      {unavailable_bases(receipts), remaining, false}
    end
  end

  defp archived_processing(namespace, scope, {bucket, generation}, receipts, remaining, :evidence) do
    if bucket == SalixStore.Crypto.hex(scope) and is_binary(generation) do
      key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

      case CasRecord.get_bounded(key, remaining) do
        {:ok, %{"sealed_generation" => sealed} = fence, bytes} when is_map(sealed) ->
          budget = max(0, remaining - bytes)

          if RunFence.valid_record?(fence) and
               MapSet.subset?(
                 MapSet.new(receipts, & &1["receipt_ref"]),
                 MapSet.new(sealed["receipts"], & &1["receipt_ref"])
               ) do
            base =
              receipts
              |> processing_group_base()
              |> Map.put(:receipt_count, length(sealed["receipts"]))
              |> put_processing_milestone(:sealed_at_ms, sealed["sealed_at"])
              |> maybe_mark_connect_conflict(receipts)

            if base.state == :unavailable do
              {[base], budget, false}
            else
              {item, budget, cut} =
                processing_from_fence(namespace, scope, sealed, fence, base, budget)

              {[item], budget, cut}
            end
          else
            {unavailable_bases(receipts), budget, false}
          end

        {:error, :too_large, _bytes} ->
          {unavailable_bases(receipts), 0, true}

        {_result, _value, bytes} ->
          {unavailable_bases(receipts), max(0, remaining - bytes), false}
      end
    else
      {unavailable_bases(receipts), remaining, false}
    end
  end

  defp processing_base(receipt) do
    event = receipt["triage_event"]

    %{
      state: :received,
      receipt_ref: receipt["receipt_ref"],
      receipt_count: 1,
      connect_id: receipt["connect_id"],
      received_at_ms: receipt["created_at"],
      observed_at_ms: receipt["created_at"],
      terminal_status: nil,
      suggested_action: nil,
      diagnostics: %{
        source: %{
          channel_id: get_in(event, ["bucket", "channel_id"]),
          thread_ts: get_in(event, ["bucket", "thread_ts"]),
          event_type: event["event_type"],
          addressing_kind: event["addressing_kind"],
          trigger_kind: event["trigger_kind"],
          source_mode: event["source_mode"],
          actor_kind: event["actor_kind"],
          fast_path: event["fast_path"] == true
        },
        milestones: %{received_at_ms: receipt["created_at"]},
        trace_ref: nil,
        decision_reason: nil,
        evaluator: nil
      }
    }
  end

  defp processing_group_base(receipts),
    do: receipts |> Enum.max_by(&receipt_order_key/1) |> processing_base()

  defp newest_receipt_key(receipts),
    do: receipts |> Enum.max_by(&receipt_order_key/1) |> receipt_order_key()

  defp receipt_order_key(receipt),
    do:
      {receipt["created_at"], get_in(receipt, ["triage_event", "message_ts"]),
       receipt["event_id"]}

  defp maybe_mark_connect_conflict(item, receipts) do
    if receipts |> Enum.map(& &1["connect_id"]) |> Enum.uniq() |> length() == 1,
      do: item,
      else: %{item | state: :unavailable}
  end

  defp unavailable_bases(receipts),
    do:
      Enum.map(receipts, fn receipt ->
        receipt |> processing_base() |> Map.put(:state, :unavailable)
      end)

  defp bucket_memberships(bucket) do
    open =
      Enum.reduce(bucket["open_receipts"], %{}, fn receipt, memberships ->
        put_membership(memberships, receipt["receipt_ref"], :open)
      end)

    Enum.reduce(bucket["sealed_generations"], open, fn sealed, memberships ->
      Enum.reduce(sealed["receipts"], memberships, fn receipt, memberships ->
        put_membership(
          memberships,
          receipt["receipt_ref"],
          {:sealed, sealed["generation"]}
        )
      end)
    end)
  end

  defp put_membership(memberships, receipt_ref, membership) do
    case Map.fetch(memberships, receipt_ref) do
      :error -> Map.put(memberships, receipt_ref, membership)
      {:ok, ^membership} -> memberships
      {:ok, _other} -> Map.put(memberships, receipt_ref, :conflict)
    end
  end

  defp processing_from_seal(_namespace, _scope, _sealed, base, remaining, _mode)
       when remaining <= 0,
       do: {%{base | state: :unavailable}, 0, true}

  defp processing_from_seal(namespace, scope, sealed, base, remaining, :summary) do
    processing_summary(
      namespace,
      scope,
      sealed["generation"],
      sealed["receipts"],
      base,
      remaining,
      false
    )
  end

  defp processing_from_seal(namespace, scope, sealed, base, remaining, :evidence) do
    observed_at_ms = sealed["sealed_at"]

    base = %{
      base
      | observed_at_ms: observed_at_ms,
        receipt_count: length(sealed["receipts"])
    }

    fence_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      )

    case CasRecord.get_bounded(fence_key, remaining) do
      {:ok, fence, bytes} ->
        remaining = max(0, remaining - bytes)
        processing_from_fence(namespace, scope, sealed, fence, base, remaining)

      {:error, :not_found, _bytes} ->
        {%{base | state: :sealed}, remaining, false}

      {:error, :too_large, _bytes} ->
        {%{base | state: :unavailable}, 0, true}

      {:error, _unreadable, bytes} ->
        {%{base | state: :unavailable}, max(0, remaining - bytes), false}
    end
  end

  # The list reports the fence owner's recorded state, not a verified review.
  # Full input, model proof and ledger agreement are read only for a detail.
  defp processing_summary(namespace, scope, generation, receipts, base, remaining, archived?) do
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    refs = receipts |> Enum.take(20) |> Enum.map(& &1["receipt_ref"])

    case prefetched_fence(key, refs) do
      {:ok, summary} ->
        bytes = byte_size(Jason.encode!(summary))

        cond do
          bytes > remaining ->
            {%{base | state: :unavailable}, 0, true}

          not valid_processing_summary?(summary, scope, generation, archived?) ->
            {%{base | state: :unavailable}, remaining - bytes, false}

          true ->
            base =
              base
              |> put_processing_milestone(:evaluation_started_at_ms, summary["created_at"])
              |> Map.put(:execution_id, summary["run_id"])

            base =
              if archived? do
                base
                |> Map.put(:receipt_count, summary["receipt_count"])
                |> put_processing_milestone(:sealed_at_ms, summary["sealed_at"])
              else
                base
              end

            item =
              case summary["terminal"] do
                nil ->
                  %{base | state: :evaluating, observed_at_ms: summary["created_at"]}

                terminal ->
                  base
                  |> Map.merge(%{
                    state: :settled,
                    terminal_status: terminal["status"],
                    observed_at_ms: terminal["settled_at"]
                  })
                  |> put_processing_milestone(:settled_at_ms, terminal["settled_at"])
              end

            {item, remaining - bytes, false}
        end

      {:error, :not_found} when not archived? ->
        {%{base | state: :sealed}, remaining, false}

      _ ->
        {%{base | state: :unavailable}, remaining, false}
    end
  end

  defp valid_processing_summary?(summary, scope, generation, archived?) do
    terminal = summary["terminal"]

    summary["schema"] in ["comma.triage-bucket-fence.v1", "comma.triage-bucket-fence.v2"] and
      summary["bucket_scope"] == scope and summary["generation"] == generation and
      ULID.valid?(generation) and ULID.valid?(summary["run_id"]) and
      positive_timestamp?(summary["created_at"]) and positive_timestamp?(summary["deadline_at"]) and
      summary["deadline_at"] >= summary["created_at"] and
      (is_nil(terminal) or
         (is_map(terminal) and
            terminal["status"] in ~w(evaluated failed skipped_timeout skipped_already_answered) and
            positive_timestamp?(terminal["settled_at"]))) and
      (not archived? or
         (summary["archived_membership"] == true and positive_timestamp?(summary["sealed_at"]) and
            is_integer(summary["receipt_count"]) and summary["receipt_count"] > 0))
  end

  defp processing_from_fence(namespace, scope, sealed, fence, base, remaining) do
    with :ok <- validate_matching_fence(namespace, scope, sealed, fence) do
      base =
        base
        |> put_processing_milestone(:evaluation_started_at_ms, fence["created_at"])
        |> put_processing_trace(fence["run_id"])
        |> Map.put(:execution_id, fence["run_id"])

      case fence["terminal"] do
        nil ->
          {%{base | state: :evaluating, observed_at_ms: fence["created_at"]}, remaining, false}

        terminal ->
          processing_from_terminal(namespace, sealed, fence, terminal, base, remaining)
      end
    else
      _invalid -> {%{base | state: :unavailable}, remaining, false}
    end
  end

  defp processing_from_terminal(_namespace, _sealed, _fence, _terminal, base, remaining)
       when remaining <= 0,
       do: {%{base | state: :unavailable}, 0, true}

  defp processing_from_terminal(namespace, sealed, fence, terminal, base, remaining) do
    terminal_base =
      base
      |> Map.merge(%{state: :finalizing, observed_at_ms: terminal["settled_at"]})
      |> put_processing_milestone(:settled_at_ms, terminal["settled_at"])

    case Ledger.fetch_bounded(namespace, fence["run_id"], remaining) do
      {:ok, run, bytes} ->
        item =
          if ledger_agrees_with_terminal?(run, sealed, fence, terminal) do
            %{
              terminal_base
              | state: :terminal,
                terminal_status: terminal["status"],
                suggested_action: get_in(terminal, ["decision", "action"]),
                diagnostics: terminal_processing_diagnostics(terminal_base, terminal)
            }
          else
            terminal_base
          end

        {item, max(0, remaining - bytes), false}

      {:error, :too_large, _bytes} ->
        {%{terminal_base | state: :unavailable}, 0, true}

      {:error, _missing_unverified_or_unavailable, bytes} ->
        {terminal_base, max(0, remaining - bytes), false}
    end
  end

  defp ledger_agrees_with_terminal?(run, sealed, fence, terminal) do
    receipt_refs = ledger_receipt_refs(fence)

    bucket =
      if fence["schema"] == "comma.triage-bucket-fence.v2",
        do: fence["public_bucket_ref"],
        else: fence["bucket_scope"]

    is_map(run) and run["run_id"] == fence["run_id"] and run["authoritative"] == true and
      run["bucket"] == bucket and run["generation"] == sealed["generation"] and
      run["generation"] == fence["generation"] and run["created_at"] == terminal["settled_at"] and
      run["status"] == terminal["status"] and run["decision"] == terminal["decision"] and
      run["evaluator"] == terminal["evaluator"] and
      run["input_snapshot"] == fence["input_snapshot"] and
      run["input_receipt_refs"] == receipt_refs
  end

  defp put_processing_milestone(item, key, at_ms)
       when is_atom(key) and is_integer(at_ms) and at_ms >= 0 do
    put_in(item, [:diagnostics, :milestones, key], at_ms)
  end

  defp put_processing_milestone(item, _key, _at_ms), do: item

  defp put_processing_trace(item, run_id) when is_binary(run_id) and run_id != "" do
    digest = :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower)
    put_in(item, [:diagnostics, :trace_ref], "triage-" <> binary_part(digest, 0, 12))
  end

  defp put_processing_trace(item, _run_id), do: item

  defp terminal_processing_diagnostics(item, terminal) do
    item.diagnostics
    |> Map.put(
      :decision_reason,
      product_outcome_reason(get_in(terminal, ["decision", "reason"]))
    )
    |> Map.put(:evaluator, evaluator_diagnostics(terminal["evaluator"]))
  end

  defp product_outcome_reason(reason)
       when reason in [
              "identity_projection_invalid",
              "identity_projection_privacy_rejected",
              "identity_decision_invalid"
            ],
       do: "evidence_invalid"

  defp product_outcome_reason(reason)
       when reason in [
              "identity_diagnostic_indeterminate_transport",
              "identity_diagnostic_interrupted_before_transport",
              "identity_diagnostic_interrupted_after_read",
              "identity_diagnostic_indeterminate_model",
              "identity_diagnostic_internal_error"
            ],
       do: "evaluation_unavailable"

  defp product_outcome_reason(reason)
       when reason in [
              "slack_error",
              "rate_limited",
              "http_error",
              "transport_error",
              "decode_error",
              "page_budget_exceeded",
              "chain_deadline_exceeded",
              "lease_denied",
              "triage_source_target_unavailable"
            ],
       do: "source_read_unavailable"

  defp product_outcome_reason(_reason), do: nil

  defp evaluator_diagnostics(proof) when is_map(proof) do
    with true <- RunFence.valid_model_proof?(proof),
         provider when is_binary(provider) <- safe_evaluator_label(proof["provider"]),
         model when is_binary(model) <- safe_evaluator_label(proof["model"]) do
      %{
        provider: provider,
        model: model,
        prompt_ref: evidence_ref("prompt", proof["prompt_sha256"]),
        policy_ref: evidence_ref("policy", proof["policy_sha256"]),
        request_count: proof["request_count"],
        retry: proof["retry"],
        tool_names: Map.get(proof, "tool_names", [])
      }
    else
      _invalid_or_unsafe -> nil
    end
  end

  defp evaluator_diagnostics(_proof), do: nil

  defp safe_evaluator_label(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.printable?(value) and value == String.trim(value), do: value
  end

  defp safe_evaluator_label(_value), do: nil

  defp evidence_ref(prefix, <<digest::binary-size(64)>>),
    do: prefix <> "-" <> binary_part(digest, 0, 12)

  defp evidence_ref(_prefix, _digest), do: nil

  defp ledger_receipt_refs(%{
         "schema" => "comma.triage-bucket-fence.v2",
         "input_snapshot" => %{
           "schema" => "comma.triage-model-input.v3",
           "snapshot" => %{"receipt_refs" => receipt_refs}
         }
       }),
       do: receipt_refs

  defp ledger_receipt_refs(%{
         "schema" => schema,
         "input_snapshot" => %{"receipt_refs" => receipt_refs}
       })
       when schema in ["comma.triage-bucket-fence.v1", "comma.triage-bucket-fence.v2"],
       do: receipt_refs

  defp ledger_receipt_refs(_fence), do: nil

  defp validate_matching_fence(
         namespace,
         scope,
         sealed,
         %{
           "schema" => "comma.triage-bucket-fence.v2"
         } = fence
       ) do
    with true <- RunFence.valid_record?(fence),
         true <- fence["bucket_scope"] == scope,
         true <- fence["generation"] == sealed["generation"],
         {:ok, winning_input} <- Pipeline.build_input(sealed),
         :ok <- RunFence.validate_chain(fence, winning_input),
         expected_key <-
           SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
             namespace,
             scope,
             sealed["generation"]
           ),
         ^expected_key <- matching_fence_key(namespace, fence) do
      :ok
    else
      _invalid -> {:error, :invalid_triage_processing_fence}
    end
  end

  defp validate_matching_fence(
         namespace,
         scope,
         sealed,
         %{
           "schema" => "comma.triage-bucket-fence.v1"
         } = fence
       ) do
    terminal = fence["terminal"]
    input = fence["input_snapshot"]
    receipt_refs = Enum.map(sealed["receipts"], & &1["receipt_ref"])

    valid? =
      exact_keys?(fence, ~w(
        schema bucket_scope generation run_id created_at deadline_at input_snapshot terminal
      )) and fence["bucket_scope"] == scope and fence["generation"] == sealed["generation"] and
        ULID.valid?(fence["generation"]) and ULID.valid?(fence["run_id"]) and
        positive_timestamp?(fence["created_at"]) and positive_timestamp?(fence["deadline_at"]) and
        fence["deadline_at"] >= fence["created_at"] and
        valid_legacy_fence_input?(input, receipt_refs) and
        valid_legacy_terminal?(terminal) and
        matching_fence_key(namespace, fence) ==
          SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
            namespace,
            scope,
            sealed["generation"]
          )

    if valid?, do: :ok, else: {:error, :invalid_triage_processing_fence}
  end

  defp validate_matching_fence(_namespace, _scope, _sealed, _fence),
    do: {:error, :invalid_triage_processing_fence}

  defp matching_fence_key(namespace, %{
         "bucket_scope" => scope,
         "generation" => generation
       })
       when is_binary(scope) and scope != "" and is_binary(generation) and generation != "",
       do: SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

  defp matching_fence_key(_namespace, _fence), do: nil

  defp valid_legacy_fence_input?(%{"schema" => schema} = input, receipt_refs)
       when schema in ["comma.triage-input-snapshot.v1", "comma.triage-model-input.v1"] and
              is_list(receipt_refs) do
    input["receipt_refs"] == receipt_refs and is_list(input["events"])
  end

  defp valid_legacy_fence_input?(_input, _receipt_refs), do: false

  defp valid_legacy_terminal?(nil), do: true

  defp valid_legacy_terminal?(terminal) when is_map(terminal) do
    status = terminal["status"]
    decision = terminal["decision"]
    action = if is_map(decision), do: decision["action"]

    exact_keys?(terminal, ~w(terminal_id status decision evaluator settled_at)) and
      ULID.valid?(terminal["terminal_id"]) and
      status in ~w(evaluated failed skipped_timeout skipped_already_answered) and
      is_map(decision) and action in ~w(silence reply react delegate remember) and
      is_map(terminal["evaluator"]) and positive_timestamp?(terminal["settled_at"])
  end

  defp valid_legacy_terminal?(_terminal), do: false

  defp positive_timestamp?(value), do: is_integer(value) and value > 0

  # ---- ring ----

  defp runtime_status(nil), do: {:ok, offline_runtime()}

  defp runtime_status(ref) do
    case resolve_server(ref) do
      :not_running ->
        {:ok, offline_runtime()}

      {:ok, server} ->
        case ring_call(server, :status) do
          {:ok,
           %{
             mode: mode,
             namespace: namespace,
             evaluator_wired: evaluator_wired,
             active_evaluations: active_evaluations,
             open_buckets: open_buckets,
             scheduled_buckets: scheduled_buckets,
             observed_at_ms: observed_at_ms
           } = status}
          when mode in [:off, :review] and (is_binary(namespace) or is_nil(namespace)) and
                 is_boolean(evaluator_wired) and is_integer(active_evaluations) and
                 active_evaluations >= 0 and is_integer(open_buckets) and open_buckets >= 0 and
                 is_integer(scheduled_buckets) and scheduled_buckets >= 0 and
                 is_integer(observed_at_ms) ->
            {:ok, Map.put(status, :running, true)}

          _unavailable ->
            {:error, :unavailable}
        end
    end
  end

  defp offline_runtime do
    %{
      running: false,
      mode: nil,
      namespace: nil,
      evaluator_wired: false,
      active_evaluations: 0,
      open_buckets: 0,
      scheduled_buckets: 0,
      observed_at_ms: System.system_time(:millisecond)
    }
  end

  # Runtime wiring and per-Agent provider readiness are separate facts. The
  # resolver read deliberately runs here, outside the Runtime GenServer
  # mailbox, so a slow template store cannot stall bucket serialization. The
  # result is one boolean and exposes no template, model, endpoint, or secret.
  defp attach_evaluation_readiness(%{evaluator_wired: wired?} = runtime, agent_id) do
    ready? = wired? and product_evaluator_ready?(agent_id)

    runtime
    |> Map.delete(:evaluator_wired)
    |> Map.put(:evaluation_ready, ready?)
  end

  defp product_evaluator_ready?(agent_id) when is_binary(agent_id) do
    agent_id = String.trim(agent_id)

    agent_id != "" and Code.ensure_loaded?(@product_evaluator) and
      function_exported?(@product_evaluator, :ready?, 1) and
      apply(@product_evaluator, :ready?, [agent_id]) == true
  rescue
    _unavailable -> false
  catch
    _kind, _reason -> false
  end

  defp product_evaluator_ready?(_agent_id), do: false

  defp recovery_status(nil), do: {:ok, offline_recovery()}

  defp recovery_status(ref) do
    case resolve_server(ref) do
      :not_running ->
        {:ok, offline_recovery()}

      {:ok, server} ->
        case ring_call(server, :status) do
          {:ok, status} when is_map(status) ->
            {:ok, Map.merge(offline_recovery(), Map.put(status, :running, true))}

          _unavailable ->
            {:error, :unavailable}
        end
    end
  end

  defp offline_recovery do
    %{
      running: false,
      phase: nil,
      cursor: nil,
      holder: nil,
      lease_held: false,
      page_limit: nil,
      batch_limit: nil,
      backoff_ms: nil,
      pending_receipts: 0
    }
  end

  defp resolve_server(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :not_running
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(pid) when is_pid(pid), do: {:ok, pid}
  defp resolve_server(_ref), do: :not_running

  defp ring_call(server, request) do
    {:ok, GenServer.call(server, request, @ring_call_timeout_ms)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # ---- product activity ----

  defp product_outcome(%{} = outcome) do
    target = outcome[:target] || %{}
    result = outcome[:result] || %{}
    decision = outcome[:decision] || %{}
    context_candidates = outcome[:context_candidates] || []
    delegations = outcome[:delegations] || []
    companion = outcome[:companion]
    target_cutoff = outcome[:target_cutoff] || %{}
    source_messages = outcome[:source_messages] || []
    communication = public_communication(result["communication"], decision)
    companion_reaction = public_companion_reaction(companion)

    %{
      event_ref: public_event_ref(outcome[:obligation_id]),
      # An opaque existing owner key, used as a locator, not an authorization token.
      obligation_id: public_string(outcome[:obligation_id]),
      source:
        public_product_source(target, target_cutoff, source_messages, result["metadata"] || %{}),
      evidence:
        public_product_evidence(
          decision,
          companion && companion[:decision],
          context_candidates,
          delegations
        ),
      state: public_member(outcome[:state], [:pending, :claimed, :applied, :stale, :failed]),
      attempts: public_non_negative(outcome[:attempts]),
      communication: communication,
      companion_reaction: companion_reaction,
      communications: Enum.reject([communication, companion_reaction], &is_nil/1),
      effect: %{
        adapter: public_member(result["adapter"], ["slack", "audit_sink"]),
        outcome: public_member(result["outcome"], ["applied", "stale", "failed"]),
        external_writes: public_non_negative(result["external_writes"]),
        status: communication.status
      },
      companion_effect: public_companion_effect(companion, companion_reaction),
      context: public_context_summary(result["context"]),
      related_context: public_related_context(context_candidates, result["context"]),
      delegations: public_delegations(delegations, result),
      inserted_at_ms: public_non_negative(outcome[:inserted_at]),
      updated_at_ms: latest_product_update(outcome[:updated_at], companion)
    }
  end

  defp public_product_source(target, target_cutoff, source_messages, metadata) do
    timestamps =
      target_cutoff
      |> Map.get("event_message_timestamps", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    activity_ms = timestamps |> Enum.map(&slack_timestamp_ms/1) |> Enum.filter(&is_integer/1)

    %{
      connect_id: public_string(target["connect_id"]),
      channel_id: public_string(target["channel_id"]),
      thread_ts: public_string(target["thread_ts"]),
      message_count: length(timestamps),
      first_activity_at_ms: Enum.min(activity_ms, fn -> nil end),
      latest_activity_at_ms: Enum.max(activity_ms, fn -> nil end),
      messages: public_source_messages(target, source_messages, metadata)
    }
  end

  defp public_source_messages(target, messages, metadata) when is_list(messages) do
    workspace_id = public_string(target["workspace_id"])
    channel_id = public_string(target["channel_id"])
    thread_ts = public_string(target["thread_ts"])
    labels = public_source_speaker_labels(metadata)

    messages
    |> Enum.take(3)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{
         "actor_kind" => actor_kind,
         "message_ts" => message_ts,
         "excerpt" => excerpt
       } = message, index}
      when actor_kind in ~w(agent human system unknown) and is_binary(message_ts) and
             message_ts != "" and is_binary(excerpt) ->
        actor_id = Map.get(message, "actor_id")

        [
          %{
            actor_kind: source_actor_kind(actor_kind),
            excerpt: excerpt,
            message_ts: message_ts,
            occurred_at_ms: slack_timestamp_ms(message_ts),
            speaker_label: public_source_speaker_label(Enum.at(labels, index), actor_id),
            url: slack_thread_url(workspace_id, channel_id, thread_ts)
          }
          |> public_source_file_attachments(message["file_attachments"])
        ]

      {_invalid, _index} ->
        []
    end)
  end

  defp public_source_messages(_target, _messages, _metadata), do: []

  defp public_source_file_attachments(message, catalogue) do
    if FileAttachments.valid_projected?(catalogue) do
      Map.put(
        message,
        :file_attachments,
        FileAttachments.project(catalogue, &IdentityContract.redact_untrusted_text/1)
      )
    else
      message
    end
  end

  defp public_source_speaker_labels(%{"source_speaker_labels" => labels})
       when is_list(labels) and length(labels) <= 3,
       do: labels

  defp public_source_speaker_labels(_metadata), do: []

  defp public_source_speaker_label(label, actor_id) when is_binary(label) do
    label =
      label
      |> IdentityContract.redact_untrusted_text()
      |> String.split()
      |> Enum.join(" ")
      |> String.slice(0, 80)

    if label == "" or label == actor_id, do: nil, else: label
  end

  defp public_source_speaker_label(_label, _actor_id), do: nil

  defp source_actor_kind("agent"), do: :agent
  defp source_actor_kind("human"), do: :human
  defp source_actor_kind("system"), do: :system
  defp source_actor_kind("unknown"), do: :unknown

  defp slack_thread_url(workspace_id, channel_id, thread_ts)
       when is_binary(workspace_id) and is_binary(channel_id) and is_binary(thread_ts) do
    "https://app.slack.com/client/#{url_path_segment(workspace_id)}/#{url_path_segment(channel_id)}/thread/#{url_path_segment(channel_id <> "-" <> thread_ts)}"
  end

  defp slack_thread_url(_workspace_id, _channel_id, _thread_ts), do: nil

  defp url_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp public_product_evidence(
         communication,
         companion_reaction,
         context_candidates,
         delegations
       ) do
    communication_refs = public_source_refs(communication)
    companion_reaction_refs = public_source_refs(companion_reaction)
    context_refs = Enum.flat_map(List.wrap(context_candidates), &public_source_refs/1)
    delegation_refs = Enum.flat_map(List.wrap(delegations), &public_source_refs/1)

    %{
      communication_sources: communication_refs |> Enum.uniq() |> length(),
      companion_reaction_sources: companion_reaction_refs |> Enum.uniq() |> length(),
      context_sources: context_refs |> Enum.uniq() |> length(),
      delegation_sources: delegation_refs |> Enum.uniq() |> length(),
      total_sources:
        (communication_refs ++ companion_reaction_refs ++ context_refs ++ delegation_refs)
        |> Enum.uniq()
        |> length()
    }
  end

  defp public_related_context(candidates, %{} = context_result) when is_list(candidates) do
    entries = List.wrap(context_result["entries"])

    candidates
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"kind" => kind, "subject" => subject, "value" => value} = candidate, index}
      when kind in ~w(project_fact decision follow_up) and is_binary(subject) and
             subject != "" and is_binary(value) and value != "" ->
        result = Enum.at(entries, index) || %{}

        [
          %{
            kind: kind,
            state: public_context_result_state(result["state"]),
            disposition:
              public_member(result["disposition"], ["created", "reinforced", "duplicate"]),
            subject: subject,
            value: value,
            confidence: public_member(candidate["confidence"], ["explicit", "inferred"]),
            source_count: candidate |> public_source_refs() |> Enum.uniq() |> length()
          }
        ]

      _invalid ->
        []
    end)
    |> Enum.take(3)
  end

  defp public_related_context(_candidates, _context_result), do: []

  defp public_source_refs(%{"source_refs" => refs}) when is_list(refs),
    do: Enum.filter(refs, &(is_binary(&1) and &1 != ""))

  defp public_source_refs(_value), do: []

  defp public_context_result_state("active"), do: :active
  defp public_context_result_state("proposed"), do: :proposed
  defp public_context_result_state("resolved"), do: :resolved
  defp public_context_result_state("superseded"), do: :superseded
  defp public_context_result_state(_state), do: :unknown

  defp slack_timestamp_ms(timestamp) when is_binary(timestamp) do
    case String.split(timestamp, ".", parts: 2) do
      [seconds] -> parse_slack_timestamp_ms(seconds, "0")
      [seconds, fraction] -> parse_slack_timestamp_ms(seconds, fraction)
    end
  end

  defp slack_timestamp_ms(_timestamp), do: nil

  defp parse_slack_timestamp_ms(seconds, fraction) do
    millis = fraction |> String.slice(0, 3) |> String.pad_trailing(3, "0")

    with {seconds, ""} <- Integer.parse(seconds),
         {millis, ""} <- Integer.parse(millis) do
      seconds * 1_000 + millis
    else
      _invalid -> nil
    end
  end

  defp product_context(%{} = entry) do
    payload = entry[:payload] || %{}

    %{
      entry_id: public_string(entry[:entry_id]),
      context_ref: public_event_ref(entry[:entry_id]),
      source_ref: "triage-context://#{entry[:entry_id]}",
      kind: public_member(entry[:kind], ["project_fact", "decision", "follow_up"]),
      state: public_member(entry[:state], [:active, :proposed, :resolved, :stopped, :superseded]),
      subject: public_string(payload["subject"]),
      value: public_string(payload["value"]),
      confidence: public_member(payload["confidence"], ["explicit", "inferred"]),
      knowledge_scope:
        public_member(payload["knowledge_scope"], ["person", "project", "unattributed"]),
      scope_owner: payload["scope_owner"],
      source_attribution: payload["source_attribution"] || [],
      follow_up_basis:
        public_member(payload["follow_up_basis"], [
          "unconfirmed",
          "reminder_confirmed",
          "agent_owned"
        ]),
      source_count: payload["source_refs"] |> List.wrap() |> length(),
      next_check_at_ms: public_datetime_ms(entry[:next_check_at]),
      resolved_at_ms: public_datetime_ms(entry[:resolved_at]),
      resolved_reason:
        public_member(payload["resolved_reason"], ["evidenced_completion", "reminder_delivered"]),
      stopped_at_ms: public_datetime_ms(entry[:stopped_at]),
      stopped_reason:
        if(entry[:state] == :stopped, do: public_string(payload["resolved_reason"])),
      inserted_at_ms: public_non_negative(entry[:inserted_at]),
      updated_at_ms: public_non_negative(entry[:updated_at])
    }
  end

  defp public_communication(%{} = effect, %{} = decision),
    do:
      effect
      |> Map.merge(decision, fn _key, effect_value, _decision_value -> effect_value end)
      |> public_communication()

  defp public_communication(_effect, %{} = decision), do: public_communication(decision)

  defp public_communication(%{"kind" => "reply", "text" => text} = communication)
       when is_binary(text) and text != "" do
    %{
      kind: :reply,
      text: text,
      reason: public_string(communication["reason"]),
      status:
        public_member(communication["status"], [
          "captured",
          "queued",
          "delivered",
          "suppressed_stale",
          "retry_scheduled",
          "failed"
        ]) || "proposed"
    }
  end

  defp public_communication(%{"kind" => "reaction", "emoji" => emoji} = communication)
       when is_binary(emoji) and emoji != "" do
    %{
      kind: :reaction,
      emoji: emoji,
      text: nil,
      reason: public_string(communication["reason"]),
      status:
        public_member(communication["status"], [
          "captured",
          "added",
          "suppressed_stale",
          "retry_scheduled",
          "failed"
        ]) || "proposed"
    }
  end

  defp public_communication(%{"kind" => "silence", "reason" => reason} = communication)
       when is_binary(reason) and reason != "" do
    %{
      kind: :silence,
      text: nil,
      reason: reason,
      explanation: public_string(communication["explanation"]),
      status: public_member(communication["status"], ["recorded", "failed"]) || "proposed"
    }
  end

  defp public_communication(_communication),
    do: %{kind: :unavailable, emoji: nil, text: nil, reason: nil, status: "unavailable"}

  defp public_companion_reaction(%{} = companion) do
    public_communication(get_in(companion, [:result, "communication"]), companion[:decision])
  end

  defp public_companion_reaction(_companion), do: nil

  defp public_companion_effect(%{} = companion, %{status: status}) do
    result = companion[:result] || %{}

    %{
      state: public_member(companion[:state], [:pending, :claimed, :applied, :stale, :failed]),
      attempts: public_non_negative(companion[:attempts]),
      adapter: public_member(result["adapter"], ["slack", "audit_sink"]),
      outcome: public_member(result["outcome"], ["applied", "stale", "failed"]),
      external_writes: public_non_negative(result["external_writes"]),
      status: status
    }
  end

  defp public_companion_effect(_companion, _reaction), do: nil

  defp latest_product_update(primary_updated_at, %{} = companion) do
    [primary_updated_at, companion[:updated_at]]
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.max(fn -> 0 end)
  end

  defp latest_product_update(primary_updated_at, _companion),
    do: public_non_negative(primary_updated_at)

  defp public_context_summary(%{} = context) do
    %{
      candidates: public_non_negative(context["candidate_count"]),
      active: public_non_negative(context["active_count"]),
      proposed: public_non_negative(context["proposed_count"])
    }
  end

  defp public_context_summary(_context), do: %{candidates: 0, active: 0, proposed: 0}

  defp public_delegations(delegations, result) when is_list(delegations) do
    statuses = public_delegation_statuses(result, min(length(delegations), 2))

    delegations
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"task" => task, "source_refs" => refs}, index}
      when is_binary(task) and task != "" ->
        [
          %{
            index: index,
            task: task,
            source_count: refs |> List.wrap() |> length(),
            status: Map.get(statuses, index, "unavailable")
          }
        ]

      _invalid ->
        []
    end)
    |> Enum.take(2)
  end

  defp public_delegations(_delegations, _result), do: []

  defp public_delegation_statuses(
         %{"metadata" => %{"delegations" => results}},
         proposal_count
       )
       when is_list(results) and proposal_count in 0..2 and length(results) <= 2 do
    Enum.reduce_while(results, %{}, fn
      %{"index" => index, "status" => status}, statuses
      when is_integer(index) and index >= 0 and index < proposal_count and
             status in ~w(created routed proposed retry_scheduled suppressed_stale) ->
        if Map.has_key?(statuses, index),
          do: {:halt, %{}},
          else: {:cont, Map.put(statuses, index, status)}

      _invalid, _statuses ->
        {:halt, %{}}
    end)
  end

  defp public_delegation_statuses(_result, _proposal_count), do: %{}

  defp public_event_ref(value) when is_binary(value) and value != "" do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    "triage-" <> binary_part(digest, 0, 12)
  end

  defp public_event_ref(_value), do: nil

  defp public_datetime_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp public_datetime_ms(_value), do: nil

  defp public_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp public_non_negative(_value), do: 0

  defp public_string(value) when is_binary(value) and value != "", do: value
  defp public_string(_value), do: nil

  defp public_member(value, allowed) when is_list(allowed) do
    if value in allowed, do: value, else: nil
  end

  # ---- connects ----

  # The public projection and the raw record are two reads. When the second one
  # fails the row still has display labels, but `provisioned?`, the non-secret
  # installation tuple, and `source_ready?` come out of an empty map. A false
  # derived from a failed read is indistinguishable from an observed false, so
  # the row carries `posture_complete?: false` and callers refuse provisioning,
  # channel-authority, and sourced-context actions. The public enablement bit is
  # deliberately separate so fail-safe disable remains possible.
  defp posture(tenant_id, group_id, router_agent_id, public) do
    {record, complete?} =
      case ProviderConnects.fetch_im_connect(group_id, public["connect_id"]) do
        {:ok, rec} when is_map(rec) -> {rec, true}
        _unavailable -> {%{}, false}
      end

    {configured_channels, channel_scope_complete?, channel_controls_available?, authority_valid?} =
      case ProviderConnects.list_configured_slack_triage_channels(
             record["tenant_id"],
             group_id,
             public["connect_id"]
           ) do
        {:ok,
         %{
           channels: channels,
           scan_complete: complete?,
           channel_controls_available?: controls?,
           authority_valid?: valid?
         }} ->
          {channels, complete?, controls?, valid?}

        _unavailable ->
          {[], false, false, false}
      end

    %{
      connect_id: public["connect_id"],
      posture_complete?: complete?,
      channel_scope_complete?: complete? and channel_scope_complete?,
      channel_controls_available?: complete? and channel_controls_available?,
      authority_valid?: complete? and authority_valid?,
      configured_channels: configured_channels,
      provisioned?: provisioned?(record),
      triage_enabled: public["triage_enabled"] == true,
      approved_channel_id: present(public["approved_channel_id"]),
      # Presentation only, captured at provisioning time. The authority is
      # pinned to the channel id; the name is a label for whoever reads it.
      approved_channel_name: present(public["approved_channel_name"]),
      connect_generation: present(record["connect_generation"]),
      source_ready?: source_ready?(record, public, tenant_id, group_id, router_agent_id),
      app_name: present(public["app_name"]),
      bot_username: present(public["bot_username"]),
      workspace_id: present(record["workspace_id"]),
      workspace_name: present(public["workspace_name"]),
      # Effective non-secret routing identity. New connects carry an explicit
      # binding; legacy connects without that field are current-router-bound by
      # the Provider compatibility contract. BFT receives the resolved identity
      # so it never has to reconstruct that contract across the erpc seam.
      inbound_agent_id: present(public["inbound_agent_id"]) || router_agent_id,
      app_id: present(record["app_id"])
    }
  end

  defp source_ready?(record, public, tenant_id, group_id, router_agent_id) do
    effective_inbound_agent_id = present(record["inbound_agent_id"]) || router_agent_id

    record["provider"] == "slack" and record["tenant_id"] == tenant_id and
      record["group_id"] == group_id and record["connect_id"] == public["connect_id"] and
      ULID.valid?(record["connect_generation"]) and present(record["workspace_id"]) != nil and
      present(record["app_id"]) != nil and present(record["bot_token"]) != nil and
      is_integer(record["oauth_completed_at"]) and record["oauth_completed_at"] > 0 and
      present(router_agent_id) != nil and effective_inbound_agent_id == router_agent_id and
      is_nil(record["disabled_at"]) and is_nil(record["deleted_at"])
  end

  # New records use the one-way family marker. Older records may predate that
  # marker, but a non-empty approved channel was already their durable legacy
  # authority and therefore also proves provisioning.
  defp provisioned?(record) do
    (is_integer(record["triage_provisioned_at"]) and record["triage_provisioned_at"] > 0) or
      present(record["approved_channel_id"]) != nil
  end

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
