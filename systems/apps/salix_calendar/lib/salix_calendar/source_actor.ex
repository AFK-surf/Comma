defmodule SalixCalendar.SourceActor do
  @moduledoc "The aggregate, lifecycle and persistence owner for one CalendarSource."

  use GenServer

  alias SalixCalendar.{Item, Query, Recurrence, SourceSyncOutcome}
  alias SalixStore.{CasRecord, Crypto, Ids, JSON, Keys, Lease, S3}

  @max_page_size 200
  @max_pages_per_refresh 100
  @max_source_members 10_000
  @max_item_month_buckets 24
  @max_retirements_per_operation 200
  @source_identity_fields ~w(source_id calendar_id group_id adapter adapter_contract_id source_locator access_profile audience)
  @source_fact_fields ~w(copy_role object scheduling_identity scheduling_revision source_version source_revision present_fields participant_set_state attachment_set_state normalization_state source_fresh_at meeting_qualification tombstoned_at scheduling_link_id revision created_at updated_at)
  @default_operation_timeout_ms 120_000
  @lease_ttl_ms 300_000

  def child_spec(opts) do
    identity =
      {Keyword.fetch!(opts, :group_id), Keyword.fetch!(opts, :calendar_id),
       Keyword.fetch!(opts, :source_id)}

    %{
      id: key(elem(identity, 0), elem(identity, 1), elem(identity, 2)),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    calendar_id = Keyword.fetch!(opts, :calendar_id)
    source_id = Keyword.fetch!(opts, :source_id)
    GenServer.start_link(__MODULE__, opts, name: via(group_id, calendar_id, source_id))
  end

  def key(group_id, calendar_id, source_id),
    do: {:calendar_source, group_id, calendar_id, source_id}

  def read_source(g, c, s), do: get_record(Keys.ctl_calendar_source(g, c, s))

  defp via(group_id, calendar_id, source_id),
    do: {:via, Registry, {SalixCalendar.Registry, key(group_id, calendar_id, source_id)}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    group_id = Keyword.fetch!(opts, :group_id)
    calendar_id = Keyword.fetch!(opts, :calendar_id)
    source_id = Keyword.fetch!(opts, :source_id)

    {:ok,
     %{
       group_id: group_id,
       calendar_id: calendar_id,
       source_id: source_id,
       lease_key: Keys.ctl_calendar_source_lease(group_id, calendar_id, source_id),
       holder: lease_holder(),
       lease_guard: nil,
       busy: nil,
       pending: :queue.new(),
       dirty_query: nil
     }}
  end

  @impl true
  def handle_call({:ensure, attrs}, _from, %{busy: %{}} = state),
    do: {:reply, ensure_source(state, attrs), state}

  def handle_call({:ensure, attrs}, _from, state) do
    result = with_lease(state, &ensure_source(&1, attrs))
    {:reply, result, state}
  end

  def handle_call({kind, _arg} = command, from, %{busy: %{}} = state)
      when kind == :refresh,
      do: {:noreply, enqueue(state, from, command)}

  def handle_call({kind, _arg, _other} = command, from, %{busy: %{}} = state)
      when kind == :revalidate,
      do: {:noreply, enqueue(state, from, command)}

  def handle_call({:refresh, query_contract}, from, state),
    do: start_operation(state, from, {:refresh, JSON.stringify(query_contract)})

  def handle_call({:revalidate, item, occurrence}, from, state),
    do:
      start_operation(
        state,
        from,
        {:revalidate, JSON.stringify(item), JSON.stringify(occurrence)}
      )

  def handle_call(:get_source, _from, state),
    do: {:reply, source_record(state), state}

  def handle_call({:get_item, item_id}, _from, state),
    do: {:reply, with_source(state, &Query.get_item(&1, item_id)), state}

  def handle_call({:list_items, opts}, _from, state),
    do: {:reply, with_source(state, &Query.list_items(&1, opts)), state}

  def handle_call({:query_items, start_ms, end_ms}, _from, state),
    do: {:reply, with_source(state, &Query.query_items(&1, start_ms, end_ms)), state}

  def handle_call({:list_link_items, link_id}, _from, state),
    do: {:reply, with_source(state, &Query.list_link_items(&1, link_id)), state}

  def handle_call(:drain_retirements, _from, %{busy: %{}} = state),
    do: {:reply, {:error, :sync_source_busy}, state}

  def handle_call(:drain_retirements, _from, state) do
    result = with_lease(state, &drain_retirements/1)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:provider_dirty, query_contract}, %{busy: %{}} = state),
    do: {:noreply, %{state | dirty_query: JSON.stringify(query_contract)}}

  def handle_cast({:provider_dirty, query_contract}, state),
    do: start_operation(state, nil, {:refresh, JSON.stringify(query_contract)})

  defp start_operation(state, from, command) do
    case start_lease_guard(state) do
      {:ok, guard} ->
        owned = %{state | lease_guard: guard}

        case prepare_flow(owned, command) do
          {:ok, flow} ->
            busy = %{from: from, worker: nil, timeout_ref: nil, flow: flow}
            {:noreply, start_provider(%{owned | busy: busy})}

          {:error, _} = error ->
            stop_lease_guard(guard)
            operation_reply(from, error, state)
        end

      {:error, _} = error ->
        operation_reply(from, error, state)
    end
  end

  defp prepare_flow(state, {:refresh, query_contract}) do
    with {:ok, source} <- source_record(state),
         {:ok, adapter} <- adapter(source),
         {:ok, source, sync} <- ensure_sync(state, source, adapter, query_contract) do
      {:ok,
       %{kind: :refresh, source: source, adapter: adapter, sync: sync, pages: 0, applied: []}}
    end
  end

  defp prepare_flow(state, {:revalidate, item, occurrence}) do
    with {:ok, source} <- source_record(state),
         {:ok, adapter} <- adapter(source) do
      {:ok,
       %{kind: :revalidate, source: source, adapter: adapter, item: item, occurrence: occurrence}}
    end
  end

  defp start_provider(%{busy: busy} = state) do
    owner = self()
    flow = busy.flow

    worker =
      spawn_link(fn ->
        result =
          case flow.kind do
            :refresh ->
              read_page(flow.adapter, flow.source, flow.sync)

            :revalidate ->
              flow.adapter.exact_refresh(flow.source, flow.item, flow.occurrence)
          end

        send(owner, {:source_provider_result, self(), result})
      end)

    timeout_ref =
      Process.send_after(
        self(),
        {:source_provider_timeout, worker},
        operation_timeout_ms()
      )

    put_in(state, [:busy], %{
      busy
      | worker: worker,
        timeout_ref: timeout_ref
    })
  end

  @impl true
  def handle_info(
        {:source_provider_result, worker, result},
        %{busy: %{worker: worker} = busy} = state
      ) do
    Process.unlink(worker)
    cancel_timer(busy.timeout_ref)
    commit_provider_result(state, busy, result)
  end

  def handle_info(
        {:source_provider_timeout, worker},
        %{busy: %{worker: worker} = busy} = state
      ) do
    Process.exit(worker, :kill)
    finish_operation(state, %{busy | timeout_ref: nil}, {:error, :source_operation_timeout})
  end

  def handle_info({:EXIT, worker, reason}, %{busy: %{worker: worker} = busy} = state),
    do: finish_operation(state, busy, {:error, {:source_operation_crashed, reason}})

  def handle_info(
        {:source_lease_lost, guard, reason},
        %{lease_guard: guard, busy: busy} = state
      )
      when is_map(busy) do
    if is_pid(busy.worker), do: Process.exit(busy.worker, :kill)
    finish_operation(state, busy, {:error, {:source_lease_failed, reason}})
  end

  def handle_info({:source_provider_result, _worker, _result}, state),
    do: {:noreply, state}

  def handle_info({:source_provider_timeout, _worker}, state), do: {:noreply, state}
  def handle_info({:source_lease_lost, _guard, _reason}, state), do: {:noreply, state}
  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  defp commit_provider_result(state, busy, {:error, :cursor_expired})
       when busy.flow.kind == :refresh do
    case rebuild_sync(state, busy.flow) do
      {:ok, flow} -> {:noreply, start_provider(put_in(state, [:busy], %{busy | flow: flow}))}
      {:error, _} = error -> finish_operation(state, busy, error)
    end
  end

  defp commit_provider_result(state, busy, {:ok, %{"changes" => changes} = page})
       when busy.flow.kind == :refresh and is_list(changes) do
    flow = busy.flow

    with true <- length(changes) <= @max_page_size,
         true <- flow.pages < @max_pages_per_refresh,
         {:ok, source} <- source_record(state),
         :ok <- require_flow_owner(source, flow),
         {:ok, applied} <- apply_records(state, source, flow.sync["generation"], changes),
         {:ok, source, sync, complete?} <- checkpoint_page(state, source, flow.sync, page),
         :ok <- if(complete?, do: drain_retirements(state), else: :ok) do
      next_flow = %{
        flow
        | source: source,
          sync: sync,
          pages: flow.pages + 1,
          applied: flow.applied ++ applied
      }

      if complete? do
        finish_operation(
          state,
          busy,
          {:ok,
           %{"applied" => next_flow.applied, "sync" => sync, "sync_status" => sync["status"]}}
        )
      else
        {:noreply, start_provider(put_in(state, [:busy], %{busy | flow: next_flow}))}
      end
    else
      false -> finish_operation(state, busy, {:error, :source_refresh_budget_exceeded})
      {:error, _} = error -> finish_operation(state, busy, error)
    end
  end

  defp commit_provider_result(state, busy, {:ok, record}) when busy.flow.kind == :revalidate do
    flow = busy.flow

    with {:ok, source} <- source_record(state),
         :ok <- require_source_contract(source, flow.source, flow.adapter),
         generations <- exact_generations(source),
         {:ok, [result | _]} <- apply_to_generations(state, source, generations, [record]),
         :ok <- drain_retirements(state) do
      finish_operation(state, busy, {:ok, result})
    else
      {:error, _} = error -> finish_operation(state, busy, error)
    end
  end

  defp commit_provider_result(state, busy, {:error, _} = error),
    do: finish_operation(state, busy, error)

  defp commit_provider_result(state, busy, _invalid),
    do: finish_operation(state, busy, {:error, :invalid_adapter_page})

  defp finish_operation(state, busy, result) do
    result = settle_refresh_outcome(state, busy, result)
    cancel_timer(busy.timeout_ref)
    if is_pid(busy.worker), do: Process.unlink(busy.worker)
    stop_lease_guard(state.lease_guard)
    if busy.from, do: GenServer.reply(busy.from, result)

    state = %{state | busy: nil, lease_guard: nil}

    case :queue.out(state.pending) do
      {{:value, {from, command}}, rest} ->
        start_operation(%{state | pending: rest}, from, command)

      {:empty, _} when is_map(state.dirty_query) ->
        start_operation(
          %{state | dirty_query: nil},
          nil,
          {:refresh, state.dirty_query}
        )

      {:empty, _} ->
        {:noreply, state}
    end
  end

  defp settle_refresh_outcome(state, busy, result) do
    case persist_refresh_outcome(state, busy, result) do
      :ok -> result
      {:ok, source} -> settled_refresh_result(result, source)
      {:error, _} = error when elem(result, 0) == :ok -> error
      {:error, _} -> result
    end
  end

  defp settled_refresh_result({:ok, %{"sync" => _sync} = value}, %{"sync" => sync}),
    do: {:ok, Map.put(value, "sync", sync)}

  defp settled_refresh_result(result, _source), do: result

  defp persist_refresh_outcome(
         state,
         %{flow: %{kind: :refresh} = flow},
         {:error, reason}
       ) do
    attempted_at = now_ms()
    outcome = SourceSyncOutcome.failure(reason, attempted_at)

    update_record(state, source_key(state), fn
      %{"sync" => sync} = current ->
        if same_refresh_flow?(current, sync, flow) do
          settled_sync =
            sync
            |> Map.put("last_outcome", outcome)
            |> SourceSyncOutcome.clear_unsettled()

          current
          |> Map.put("sync", settled_sync)
          |> bump(attempted_at)
        else
          {:error, :source_sync_advanced}
        end

      _current ->
        {:error, :source_sync_advanced}
    end)
  end

  defp persist_refresh_outcome(
         state,
         %{flow: %{kind: :refresh} = flow},
         {:ok, _result}
       ) do
    update_record(state, source_key(state), fn
      %{"sync" => sync} = current ->
        if same_refresh_flow?(current, sync, flow) do
          settled_sync =
            sync
            |> SourceSyncOutcome.clear_failure()
            |> SourceSyncOutcome.clear_unsettled()

          current
          |> Map.put("sync", settled_sync)
          |> bump(now_ms())
        else
          {:error, :source_sync_advanced}
        end

      _current ->
        {:error, :source_sync_advanced}
    end)
  end

  defp persist_refresh_outcome(_state, _busy, _result), do: :ok

  defp same_refresh_flow?(current, sync, flow) do
    sync["generation"] == flow.sync["generation"] and
      sync["sync_policy_revision"] == flow.sync["sync_policy_revision"] and
      sync["query_contract_hash"] == flow.sync["query_contract_hash"] and
      current["adapter_contract_id"] == flow.source["adapter_contract_id"]
  end

  defp operation_reply(nil, _result, state), do: {:noreply, state}
  defp operation_reply(_from, result, state), do: {:reply, result, state}

  defp enqueue(state, from, command) do
    if :queue.len(state.pending) >= 50 do
      GenServer.reply(from, {:error, :sync_source_busy})
      state
    else
      %{state | pending: :queue.in({from, command}, state.pending)}
    end
  end

  defp ensure_source(state, attrs) do
    attrs = JSON.stringify(attrs)

    with {:ok, adapter_name} <- required_text(attrs, "adapter"),
         {:ok, contract_id} <- required_text(attrs, "adapter_contract_id"),
         {:ok, locator} <- required_map(attrs, "source_locator"),
         :ok <- require_read_access(attrs["access_profile"]),
         {:ok, audience} <- require_group_audience(attrs["audience"], state.group_id) do
      expected = %{
        "source_id" => state.source_id,
        "calendar_id" => state.calendar_id,
        "group_id" => state.group_id,
        "adapter" => adapter_name,
        "adapter_contract_id" => contract_id,
        "source_locator" => locator,
        "access_profile" => attrs["access_profile"],
        "audience" => audience
      }

      update_record(state, source_key(state), fn
        nil ->
          now = now_ms()

          expected
          |> Map.merge(%{
            "sync_policy" => attrs["sync_policy"] || %{},
            "sync_policy_revision" => 1,
            "active_generation" => 0,
            "generation_counter" => 0,
            "status" => "active",
            "revision" => 1,
            "created_at" => now,
            "updated_at" => now
          })

        current ->
          watch = attrs["watch"] || current["watch"]

          cond do
            Map.take(current, @source_identity_fields) != expected ->
              {:error, :source_identity_conflict}

            current["sync_policy"] == (attrs["sync_policy"] || %{}) and
                current["watch"] == watch ->
              {:unchanged, current}

            current["sync_policy"] == (attrs["sync_policy"] || %{}) ->
              current |> Map.put("watch", watch) |> bump(now_ms())

            true ->
              updated =
                current
                |> Map.put("sync_policy", attrs["sync_policy"] || %{})
                |> Map.put("watch", watch)
                |> Map.update("sync_policy_revision", 2, &(&1 + 1))

              updated
              |> retain_source_state(current["sync"])
              |> bump(now_ms())
          end
      end)
    end
  end

  defp ensure_sync(state, source, adapter, query_contract) do
    contract = sync_contract(source, adapter, query_contract)
    current = source["sync"]

    sync =
      if same_sync_contract?(current, contract) do
        current
      else
        generation = next_generation(source)

        contract
        |> Map.merge(%{
          "completed_cursor" => nil,
          "page_continuation" => nil,
          "generation" => generation,
          "status" => "bootstrap"
        })
        |> SourceSyncOutcome.retain_state(current)
      end

    sync =
      sync
      |> Map.put("attempted_at", now_ms())
      |> SourceSyncOutcome.mark_unsettled()

    persist_sync(state, source, sync, sync["generation"])
  end

  defp rebuild_sync(state, flow) do
    with {:ok, source} <- source_record(state),
         :ok <- require_flow_owner(source, flow) do
      generation = next_generation(source)

      rebuilt =
        flow.sync
        |> Map.put("completed_cursor", nil)
        |> Map.put("page_continuation", nil)
        |> Map.put("generation", generation)
        |> Map.put("status", "bootstrap")

      case persist_sync(state, source, rebuilt, generation) do
        {:ok, updated, sync} -> {:ok, %{flow | source: updated, sync: sync}}
        {:error, _} = error -> error
      end
    end
  end

  defp persist_sync(state, source, sync, generation) do
    update_record(state, source_key(state), fn
      current when current == source ->
        source
        |> Map.put("generation_counter", generation)
        |> Map.put("sync", sync)
        |> bump(now_ms())

      current ->
        if current["sync_policy_revision"] == source["sync_policy_revision"],
          do: {:error, :source_sync_advanced},
          else: {:error, :calendar_source_contract_mismatch}
    end)
    |> case do
      {:ok, updated} -> {:ok, updated, updated["sync"]}
      {:error, _} = error -> error
    end
  end

  defp next_generation(source),
    do: max(source["generation_counter"] || 0, source["active_generation"] || 0) + 1

  defp retain_source_state(source, previous_sync) do
    retained = SourceSyncOutcome.retain_state(%{}, previous_sync)

    if map_size(retained) == 0,
      do: Map.delete(source, "sync"),
      else: Map.put(source, "sync", retained)
  end

  defp checkpoint_page(state, source, sync, page) do
    continuation = page["next_continuation"]
    completed_cursor = page["completed_cursor"]

    cond do
      is_binary(continuation) and continuation != "" ->
        next_sync = Map.put(sync, "page_continuation", continuation)

        update_source_sync(state, sync, next_sync, false)

      is_nil(continuation) and is_binary(completed_cursor) and completed_cursor != "" ->
        with :ok <-
               if(sync["status"] == "bootstrap",
                 do: prepare_activation(state, source, sync["generation"]),
                 else: :ok
               ) do
          next_sync =
            sync
            |> Map.put("completed_cursor", completed_cursor)
            |> Map.put("completed_at", now_ms())
            |> Map.put("page_continuation", nil)
            |> Map.put("status", "active")

          update_source_sync(state, sync, next_sync, true)
        end

      true ->
        {:error, :invalid_adapter_page}
    end
  end

  defp update_source_sync(state, expected_sync, sync, activate?) do
    update_record(state, source_key(state), fn
      %{"sync" => ^expected_sync} = current ->
        next =
          if activate?,
            do: Map.put(current, "active_generation", sync["generation"]),
            else: current

        next |> Map.put("sync", sync) |> bump(now_ms())

      _ ->
        {:error, :source_sync_advanced}
    end)
    |> case do
      {:ok, updated} -> {:ok, updated, updated["sync"], activate?}
      {:error, _} = error -> error
    end
  end

  defp prepare_activation(state, source, generation),
    do: prepare_activation(state, source, generation, nil, 0)

  defp prepare_activation(_state, _source, _generation, _cursor, count)
       when count > @max_source_members,
       do: {:error, :calendar_source_member_budget_exceeded}

  defp prepare_activation(state, source, generation, cursor, count) do
    remaining = @max_source_members - count

    with true <- remaining > 0,
         {:ok, members, next} <-
           Query.source_member_page(source, cursor, min(@max_page_size, remaining)),
         :ok <- each_ok(members, &activation_retirement(state, source, generation, &1)) do
      if next,
        do: prepare_activation(state, source, generation, next, count + length(members)),
        else: :ok
    else
      false -> {:error, :calendar_source_member_budget_exceeded}
      {:error, _} = error -> error
    end
  end

  defp activation_retirement(state, source, generation, item_id) do
    with {:ok, envelope} <- Query.envelope(state.group_id, state.calendar_id, item_id) do
      previous = Query.materialize(envelope, source["active_generation"] || 0)
      next = Query.materialize(envelope, generation)

      if retired_link = retired_link(previous, next),
        do: enqueue_retirement(state, generation, retired_link),
        else: :ok
    end
  end

  defp require_flow_owner(source, flow) do
    if source["sync"] == flow.sync and
         source["sync_policy_revision"] == flow.source["sync_policy_revision"] and
         source["adapter_contract_id"] == flow.adapter.adapter_contract_id(),
       do: :ok,
       else: {:error, :calendar_source_contract_mismatch}
  end

  defp require_source_contract(current, supplied, adapter) do
    if Map.take(current, @source_identity_fields) == Map.take(supplied, @source_identity_fields) and
         current["sync_policy_revision"] == supplied["sync_policy_revision"] and
         current["adapter_contract_id"] == adapter.adapter_contract_id(),
       do: :ok,
       else: {:error, :calendar_source_contract_mismatch}
  end

  defp sync_contract(source, adapter, query_contract) do
    contract = %{
      "sync_policy_revision" => source["sync_policy_revision"] || 1,
      "query_contract" => query_contract
    }

    Map.put(
      contract,
      "query_contract_hash",
      "sha256:" <> digest({adapter.adapter_contract_id(), source["source_id"], contract})
    )
  end

  defp same_sync_contract?(sync, contract) when is_map(sync),
    do: Map.take(sync, ~w(sync_policy_revision query_contract query_contract_hash)) == contract

  defp same_sync_contract?(_sync, _contract), do: false

  defp read_page(adapter, source, sync) do
    case sync["page_continuation"] do
      continuation when is_binary(continuation) and continuation != "" ->
        adapter.continue_sync(source, sync["query_contract"], continuation)

      _ ->
        adapter.start_sync(source, sync["query_contract"], sync["completed_cursor"])
    end
  end

  defp apply_to_generations(state, source, generations, records) do
    Enum.reduce_while(generations, {:ok, nil}, fn generation, {:ok, _} ->
      case apply_records(state, source, generation, records) do
        {:ok, results} -> {:cont, {:ok, results}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_records(state, source, generation, records) do
    case batch_records_by_locator(records) do
      {:ok, batches} ->
        batches
        |> Enum.reduce_while({:ok, []}, fn batch, {:ok, applied} ->
          case apply_record_batch(state, source, generation, batch) do
            {:ok, results} ->
              {:cont, {:ok, results ++ applied}}

            {:error, reason} ->
              {:halt, {:error, %{reason: reason, applied: applied_results(applied)}}}
          end
        end)
        |> case do
          {:ok, applied} -> {:ok, applied_results(applied)}
          error -> error
        end

      {:error, reason} ->
        {:error, %{reason: reason, applied: []}}
    end
  end

  defp batch_records_by_locator(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, []}, fn {record, index}, {:ok, groups, order} ->
      record = JSON.stringify(record)

      case required_map(record, "external_locator") do
        {:ok, locator} ->
          first? = not Map.has_key?(groups, locator)
          groups = Map.update(groups, locator, [{index, record}], &[{index, record} | &1])
          order = if first?, do: [locator | order], else: order
          {:cont, {:ok, groups, order}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, groups, order} ->
        {:ok,
         order
         |> Enum.reverse()
         |> Enum.map(fn locator -> groups |> Map.fetch!(locator) |> Enum.reverse() end)}

      {:error, _} = error ->
        error
    end
  end

  defp apply_record_batch(state, source, generation, [{_index, first} | _] = records) do
    with {:ok, locator} <- required_map(first, "external_locator"),
         {:ok, binding} <- ensure_item_binding(state, locator),
         {:ok, envelope} <- item_envelope(state, binding),
         {:ok, updated, results} <-
           compose_record_batch(state, source, generation, binding, envelope, records),
         result <- Query.materialize(updated, generation) || batch_fallback_result(results),
         :ok <- persist_item_projection(state, generation, updated, result),
         {:ok, _stored} <-
           update_record(state, item_key(state, binding["calendar_item_id"]), fn _ -> updated end) do
      {:ok, results}
    end
  end

  defp compose_record_batch(state, source, generation, binding, envelope, records) do
    Enum.reduce_while(records, {:ok, envelope, []}, fn {index, record}, {:ok, current, results} ->
      with true <- record["external_locator"] == binding["external_locator"],
           {:ok, version, fallback} <-
             update_version(state, source, generation, binding, current, record) do
        updated = put_in(current, ["versions", Integer.to_string(generation)], version)
        result = Query.materialize(updated, generation) || fallback
        {:cont, {:ok, updated, [{index, result} | results]}}
      else
        false -> {:halt, {:error, :external_locator_conflict}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, updated, results} -> {:ok, updated, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp batch_fallback_result(results) do
    case List.last(results) do
      {_index, result} -> result
      nil -> %{}
    end
  end

  defp applied_results(results) do
    results
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp update_version(
         _state,
         source,
         generation,
         binding,
         envelope,
         %{"object_patch" => patch} = record
       )
       when is_map(patch) do
    key = Integer.to_string(generation)
    version = envelope["versions"][key] || %{"base" => nil, "overrides" => %{}}
    active_generation = source["active_generation"] || 0
    active_version = envelope["versions"][Integer.to_string(active_generation)] || %{}
    base = version["base"] || if(generation != active_generation, do: active_version["base"])

    current_overrides =
      case version["overrides"] do
        overrides when generation != active_generation and overrides == %{} ->
          active_version["overrides"] || %{}

        overrides ->
          overrides || %{}
      end

    with {:ok, entries} <- validate_override_patch(record),
         {:ok, overrides} <- merge_overrides(current_overrides, entries) do
      updated =
        version
        |> Map.put("base", base)
        |> Map.put("overrides", overrides)

      {:ok, updated, %{"status" => "deferred", "calendar_item_id" => binding["calendar_item_id"]}}
    end
  end

  defp update_version(state, source, generation, binding, envelope, record) do
    key = Integer.to_string(generation)
    version = envelope["versions"][key] || %{"base" => nil, "overrides" => %{}}
    current = version["base"]

    active =
      get_in(envelope, ["versions", Integer.to_string(source["active_generation"] || 0), "base"])

    baseline = current || active

    if record["tombstone"] == true and is_nil(baseline) do
      {:ok, %{"base" => nil, "overrides" => %{}},
       %{"status" => "ignored", "calendar_item_id" => binding["calendar_item_id"]}}
    else
      with {:ok, candidate} <- normalized_base(record, baseline, generation),
           {:ok, link_id} <- resolve_link(state, binding, candidate, baseline),
           candidate <- Map.put(candidate, "scheduling_link_id", link_id),
           {:ok, selected} <- select_base(candidate, current, active),
           selected <- assign_fact_revision(selected, baseline),
           updated <- version |> Map.put("base", selected) |> Map.put_new("overrides", %{}),
           previous <- Query.materialize(envelope, generation),
           projected <-
             Query.materialize(
               put_in(envelope, ["versions", key], updated),
               generation
             ),
           :ok <-
             if(link = retired_link(previous, projected),
               do: enqueue_retirement(state, generation, link),
               else: :ok
             ) do
        {:ok, updated,
         projected || %{"status" => "ignored", "calendar_item_id" => binding["calendar_item_id"]}}
      end
    end
  end

  defp normalized_base(%{"tombstone" => true} = record, baseline, generation) do
    {:ok,
     baseline
     |> Map.take(@source_fact_fields)
     |> Map.put("source_generation", generation)
     |> Map.put("source_revision", record["source_revision"])
     |> Map.put("source_version", record["source_version"] || baseline["source_version"])
     |> Map.put("tombstoned_at", baseline["tombstoned_at"] || now_ms())}
  end

  defp normalized_base(record, _baseline, generation) do
    record
    |> Map.put("source_generation", generation)
    |> Item.validate()
    |> case do
      {:ok, normalized} -> {:ok, Map.put(normalized, "tombstoned_at", nil)}
      {:error, _} = error -> error
    end
  end

  defp select_base(incoming, nil, active) when is_map(active),
    do: select_fact(incoming, active, &same_calendar_facts?/2)

  defp select_base(incoming, nil, _active), do: {:ok, incoming}

  defp select_base(incoming, current, _active),
    do: select_fact(incoming, current, &same_calendar_facts?/2)

  defp assign_fact_revision(selected, baseline) do
    now = now_ms()
    same? = is_map(baseline) and same_calendar_facts?(selected, baseline)

    revision =
      if same?, do: baseline["revision"] || 1, else: ((baseline && baseline["revision"]) || 0) + 1

    selected
    |> Map.put("revision", revision)
    |> Map.put("created_at", (baseline && baseline["created_at"]) || now)
    |> Map.put("updated_at", now)
  end

  defp same_calendar_facts?(left, right) do
    operational = ~w(revision created_at updated_at source_generation source_fresh_at)
    Map.drop(left, operational) == Map.drop(right, operational)
  end

  defp resolve_link(_state, _binding, %{"tombstoned_at" => tombstone}, baseline)
       when not is_nil(tombstone) and is_map(baseline),
       do: {:ok, baseline["scheduling_link_id"]}

  defp resolve_link(state, _binding, normalized, baseline) do
    identity = normalized["scheduling_identity"]

    cond do
      is_map(baseline) and baseline["scheduling_identity"] == identity and
          Ids.valid_scheduling_link_id?(baseline["scheduling_link_id"]) ->
        {:ok, baseline["scheduling_link_id"]}

      is_nil(identity) ->
        {:ok, Ids.new_scheduling_link_id()}

      true ->
        with :ok <- validate_scheduling_identity(identity),
             {:ok, index} <-
               ensure_once(
                 state,
                 Keys.ctl_calendar_link_by_scheduling_identity(
                   state.group_id,
                   state.calendar_id,
                   digest(identity)
                 ),
                 fn ->
                   %{"identity" => identity, "scheduling_link_id" => Ids.new_scheduling_link_id()}
                 end
               ),
             true <- index["identity"] == identity,
             true <- Ids.valid_scheduling_link_id?(index["scheduling_link_id"]) do
          {:ok, index["scheduling_link_id"]}
        else
          false -> {:error, :scheduling_identity_conflict}
          {:error, _} = error -> error
        end
    end
  end

  defp persist_item_projection(state, generation, updated, result) do
    item_id = updated["calendar_item_id"]

    with {:ok, query_keys} <- query_index_keys(state, generation, updated) do
      keys =
        [
          Keys.ctl_calendar_source_member(
            state.group_id,
            state.calendar_id,
            state.source_id,
            item_id
          )
          | link_index_keys(state, result) ++ query_keys
        ]

      each_ok(keys, &put_marker(state, &1))
    end
  end

  defp link_index_keys(state, %{
         "scheduling_link_id" => link_id,
         "calendar_item_id" => item_id
       })
       when is_binary(link_id) do
    [Keys.ctl_calendar_link_member(state.group_id, state.calendar_id, link_id, item_id)]
  end

  defp link_index_keys(_state, _result), do: []

  defp query_index_keys(state, generation, envelope) do
    case Query.materialize(envelope, generation) do
      nil ->
        {:ok, []}

      %{"tombstoned_at" => tombstone} when not is_nil(tombstone) ->
        {:ok, []}

      %{"normalization_state" => "unsupported_timing"} ->
        {:ok, []}

      item ->
        case get_in(item, ["object", "recurrenceRules"]) || [] do
          [_ | _] ->
            {:ok,
             [
               Keys.ctl_calendar_query_recurring(
                 state.group_id,
                 state.calendar_id,
                 item["calendar_item_id"]
               )
             ]}

          [] ->
            query_keys_for_single(state, item)

          _ ->
            {:error, :unsupported_recurrence}
        end
    end
  end

  defp query_keys_for_single(state, item) do
    occurrence_ref = %{
      "calendar_id" => state.calendar_id,
      "scheduling_link_id" => item["scheduling_link_id"],
      "recurrence_key" => %{"kind" => "single"}
    }

    case Recurrence.resolve(item, occurrence_ref) do
      {:ok, %{"start_ms" => start_ms, "end_ms" => end_ms}} ->
        case Query.interval_months(start_ms, end_ms, @max_item_month_buckets) do
          {:ok, months} ->
            {:ok,
             Enum.map(
               months,
               &Keys.ctl_calendar_query_month(
                 state.group_id,
                 state.calendar_id,
                 &1,
                 item["calendar_item_id"]
               )
             )}

          {:error, :calendar_query_range_too_large} ->
            {:ok,
             [
               Keys.ctl_calendar_query_spanning(
                 state.group_id,
                 state.calendar_id,
                 item["calendar_item_id"]
               )
             ]}

          {:error, _} = error ->
            error
        end

      {:error, :undated_item} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp validate_override_patch(record) do
    overrides = get_in(record, ["object_patch", "recurrenceOverrides"])
    instances = get_in(record, ["source_version_patch", "recurrence_instances"]) || %{}
    revisions = record["source_revision_patch"] || %{}

    if is_map(overrides) and
         Map.keys(overrides) |> Enum.sort() == Map.keys(instances) |> Enum.sort() and
         Map.keys(overrides) |> Enum.sort() == Map.keys(revisions) |> Enum.sort() do
      {:ok,
       Map.new(overrides, fn {key, override} ->
         {key,
          %{
            "override" => override,
            "instance_id" => instances[key],
            "source_revision" => revisions[key]
          }}
       end)}
    else
      {:error, :invalid_source_object_patch}
    end
  end

  defp merge_overrides(current, incoming) do
    Enum.reduce_while(incoming, {:ok, current}, fn {key, entry}, {:ok, merged} ->
      case select_fact(entry, merged[key], fn left, right ->
             Map.drop(left, ["source_revision"]) == Map.drop(right, ["source_revision"])
           end) do
        {:ok, selected} -> {:cont, {:ok, Map.put(merged, key, selected)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp select_fact(incoming, nil, _equal?), do: {:ok, incoming}

  defp select_fact(incoming, current, equal?) do
    case compare_revision(incoming["source_revision"], current["source_revision"]) do
      :newer ->
        {:ok, incoming}

      :older ->
        {:ok, current}

      :equal ->
        if equal?.(incoming, current),
          do: {:ok, incoming},
          else: {:error, :source_revision_conflict}

      :unordered ->
        {:ok, incoming}

      :error ->
        {:error, :incomparable_source_revision}
    end
  end

  defp compare_revision(left, right) do
    cond do
      comparable_revisions?(left, right) and left > right -> :newer
      comparable_revisions?(left, right) and left < right -> :older
      comparable_revisions?(left, right) -> :equal
      Item.valid_source_revision?(left) and Item.valid_source_revision?(right) -> :error
      true -> :unordered
    end
  end

  defp comparable_revisions?(left, right) do
    Item.valid_source_revision?(left) and Item.valid_source_revision?(right) and
      length(left) == length(right) and
      Enum.all?(Enum.zip(left, right), fn {a, b} ->
        (is_integer(a) and is_integer(b)) or (is_binary(a) and is_binary(b))
      end)
  end

  defp item_envelope(state, binding) do
    case Query.envelope(state.group_id, state.calendar_id, binding["calendar_item_id"]) do
      {:ok, %{"origin" => %{"source_id" => source_id}} = envelope}
      when source_id == state.source_id ->
        {:ok, envelope}

      {:error, :not_found} ->
        {:ok,
         %{
           "calendar_item_id" => binding["calendar_item_id"],
           "calendar_id" => state.calendar_id,
           "origin" => %{
             "kind" => "source",
             "source_id" => state.source_id,
             "external_locator" => binding["external_locator"]
           },
           "versions" => %{}
         }}

      {:ok, _} ->
        {:error, :calendar_item_identity_conflict}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_item_binding(state, locator) do
    key =
      Keys.ctl_calendar_item_by_external_locator(
        state.group_id,
        state.calendar_id,
        digest({state.source_id, locator})
      )

    with {:ok, binding} <-
           ensure_once(state, key, fn ->
             %{
               "source_id" => state.source_id,
               "external_locator" => locator,
               "calendar_item_id" => Ids.new_calendar_item_id()
             }
           end),
         true <-
           binding["source_id"] == state.source_id and binding["external_locator"] == locator,
         true <- Ids.valid_calendar_item_id?(binding["calendar_item_id"]) do
      {:ok, binding}
    else
      false -> {:error, :external_locator_conflict}
      {:error, _} = error -> error
    end
  end

  defp retired_link(previous, next) when is_map(previous) do
    previous_live? =
      is_nil(previous["tombstoned_at"]) and
        previous["normalization_state"] != "unsupported_timing"

    next_live? =
      is_map(next) and is_nil(next["tombstoned_at"]) and
        next["normalization_state"] != "unsupported_timing"

    if previous_live? and
         (not next_live? or previous["scheduling_link_id"] != next["scheduling_link_id"]),
       do: previous["scheduling_link_id"]
  end

  defp retired_link(_previous, _next), do: nil

  defp enqueue_retirement(state, generation, link_id) do
    if Ids.valid_scheduling_link_id?(link_id) do
      record = %{
        "source_id" => state.source_id,
        "source_generation" => generation,
        "scheduling_link_id" => link_id,
        "consumer_cursor" => nil
      }

      with {:ok, _} <-
             ensure_once(
               state,
               Keys.ctl_calendar_retirement(
                 state.group_id,
                 state.calendar_id,
                 state.source_id,
                 generation,
                 link_id
               ),
               fn -> record end
             ),
           do: :ok
    else
      :ok
    end
  end

  defp drain_retirements(state), do: drain_retirements(state, nil, 0)

  defp drain_retirements(_state, _cursor, count) when count >= @max_source_members,
    do: {:error, :calendar_retirement_budget_exceeded}

  defp drain_retirements(state, cursor, count) do
    opts = [max_keys: @max_retirements_per_operation]
    opts = if cursor, do: Keyword.put(opts, :continuation_token, cursor), else: opts

    with {:ok, source} <- source_record(state),
         {:ok, %{objects: objects, next: next}} <-
           S3.list(
             Keys.ctl_calendar_retirements_source_prefix(
               state.group_id,
               state.calendar_id,
               state.source_id
             ),
             opts
           ) do
      with :ok <- each_ok(objects, &drain_retirement(state, source, &1.key)) do
        if next,
          do: drain_retirements(state, next, count + length(objects)),
          else: :ok
      end
    end
  end

  defp drain_retirement(state, source, key) do
    with {:ok, candidate} <- get_record(key),
         true <- candidate["source_id"] == state.source_id,
         true <- candidate["source_generation"] <= (source["active_generation"] || 0),
         {:ok, live?} <-
           Query.scheduling_link_live?(
             state.group_id,
             state.calendar_id,
             candidate["scheduling_link_id"]
           ) do
      if live?, do: delete_record(state, key), else: deliver_retirement(state, key, candidate)
    else
      false -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp deliver_retirement(state, key, candidate) do
    sink = Application.get_env(:salix_calendar, :retirement_sink)

    with :ok <- require_lease(state) do
      result =
        if is_atom(sink) and function_exported?(sink, :cancel_scheduling_link, 4) do
          sink.cancel_scheduling_link(
            state.group_id,
            state.calendar_id,
            candidate["scheduling_link_id"],
            candidate["consumer_cursor"]
          )
        else
          {:ok, nil}
        end

      case result do
        {:ok, cursor} when is_binary(cursor) and cursor != "" ->
          with {:ok, _} <-
                 update_record(state, key, fn
                   ^candidate ->
                     Map.put(candidate, "consumer_cursor", cursor)

                   %{"consumer_cursor" => ^cursor} = current ->
                     {:unchanged, current}

                   _ ->
                     {:error, :retirement_candidate_advanced}
                 end),
               do: :ok

        {:ok, nil} ->
          delete_record(state, key)

        {:error, _} = error ->
          error
      end
    end
  end

  defp source_record(state), do: get_record(source_key(state))

  defp source_key(state),
    do: Keys.ctl_calendar_source(state.group_id, state.calendar_id, state.source_id)

  defp item_key(state, item_id),
    do: Keys.ctl_calendar_item(state.group_id, state.calendar_id, item_id)

  defp with_source(state, fun), do: with({:ok, source} <- source_record(state), do: fun.(source))

  defp each_ok(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp update_record(state, key, fun) do
    CasRecord.update(key, fun,
      invalid: :invalid_calendar_source_record,
      guard: fn -> require_lease(state) end
    )
  end

  defp ensure_once(state, key, build) do
    CasRecord.ensure(key, build,
      invalid: :invalid_calendar_source_record,
      guard: fn -> require_lease(state) end
    )
  end

  defp put_marker(state, key),
    do: with({:ok, _} <- ensure_once(state, key, fn -> %{} end), do: :ok)

  defp get_record(key), do: CasRecord.get(key, :invalid_calendar_source_record)

  defp delete_record(state, key),
    do: with(:ok <- require_lease(state), do: S3.delete(key))

  defp adapter(source) do
    adapters = Application.get_env(:salix_calendar, :source_adapters, %{})

    case adapters[source["adapter"]] do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :adapter_contract_id, 0) and
             module.adapter_contract_id() == source["adapter_contract_id"],
           do: {:ok, module},
           else: {:error, :calendar_source_contract_mismatch}

      _ ->
        {:error, :calendar_source_adapter_not_configured}
    end
  end

  defp exact_generations(source) do
    active = source["active_generation"] || 0

    case source["sync"] do
      %{"status" => "bootstrap", "generation" => staging} when is_integer(staging) ->
        Enum.uniq([active, staging])

      _ ->
        [active]
    end
  end

  defp validate_scheduling_identity(identity) do
    required = ~w(identity_version namespace series_uid scheduling_authority_key)

    if Map.keys(identity) -- required == [] and
         Enum.all?(required, &(is_binary(identity[&1]) and String.trim(identity[&1]) != "")),
       do: :ok,
       else: {:error, :invalid_scheduling_identity}
  end

  defp required_text(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp required_map(attrs, key) do
    case attrs[key] do
      value when is_map(value) and map_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp require_read_access(profile)
       when profile in ~w(events_read free_busy redacted scheduled_tasks_read),
       do: :ok

  defp require_read_access(_profile), do: {:error, :calendar_source_must_be_read_only}

  defp require_group_audience(nil, group_id),
    do: {:ok, %{"kind" => "group", "group_id" => group_id}}

  defp require_group_audience(%{"kind" => "group", "group_id" => group_id} = audience, group_id),
    do: {:ok, audience}

  defp require_group_audience(_audience, _group_id),
    do: {:error, :calendar_source_audience_mismatch}

  defp acquire_lease(state) do
    case Lease.acquire(state.lease_key, state.holder, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} -> {:ok, lease}
      {:error, {:held_by, _holder, _until}} -> {:error, :sync_source_busy}
      {:error, reason} -> {:error, {:source_lease_failed, reason}}
    end
  end

  defp with_lease(state, fun) do
    with {:ok, guard} <- start_lease_guard(state) do
      try do
        fun.(%{state | lease_guard: guard})
      after
        stop_lease_guard(guard)
      end
    end
  end

  defp start_lease_guard(state) do
    with {:ok, lease} <- acquire_lease(state) do
      owner = self()
      interval = lease_renew_interval_ms()

      {:ok,
       spawn_link(fn ->
         lease_guard(owner, lease, interval, monotonic_ms() + interval)
       end)}
    end
  end

  defp lease_guard(owner, lease, interval, renew_at) do
    wait_ms = max(renew_at - monotonic_ms(), 0)

    receive do
      {:assert_source_lease, caller, ref} ->
        # Every durable mutation proves the live ETag. Renew only once per
        # interval (or synchronously after the deadline) so a large bootstrap
        # remains fenced without exceeding object-store per-key mutation limits.
        case renew_source_lease_if_due(lease, interval, renew_at) do
          {:ok, current, next_renew_at} ->
            send(caller, {ref, :ok})
            lease_guard(owner, current, interval, next_renew_at)

          {:error, reason} ->
            send(caller, {ref, {:error, reason}})
            send(owner, {:source_lease_lost, self(), reason})
            lost_lease_guard(reason)
        end

      {:stop_source_lease, caller, ref} ->
        Lease.release(lease)
        send(caller, ref)
    after
      wait_ms ->
        case renew_source_lease(lease, interval) do
          {:ok, renewed, next_renew_at} ->
            lease_guard(owner, renewed, interval, next_renew_at)

          {:error, reason} ->
            send(owner, {:source_lease_lost, self(), reason})
            lost_lease_guard(reason)
        end
    end
  end

  defp renew_source_lease_if_due(lease, interval, renew_at) do
    if monotonic_ms() >= renew_at do
      renew_source_lease(lease, interval)
    else
      case Lease.assert_owner(lease) do
        :ok -> {:ok, lease, renew_at}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp renew_source_lease(lease, interval) do
    case Lease.renew(lease, ttl_ms: @lease_ttl_ms) do
      {:ok, renewed} -> {:ok, renewed, monotonic_ms() + interval}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lost_lease_guard(reason) do
    receive do
      {:assert_source_lease, caller, ref} ->
        send(caller, {ref, {:error, reason}})
        lost_lease_guard(reason)

      {:stop_source_lease, caller, ref} ->
        send(caller, ref)
    end
  end

  defp require_lease(%{lease_guard: guard}) when is_pid(guard) do
    if Process.alive?(guard) do
      ref = make_ref()
      send(guard, {:assert_source_lease, self(), ref})

      receive do
        {^ref, :ok} -> :ok
        {^ref, {:error, reason}} -> {:error, {:source_lease_failed, reason}}
      after
        5_000 -> {:error, {:source_lease_failed, :guard_unavailable}}
      end
    else
      {:error, {:source_lease_failed, :guard_unavailable}}
    end
  end

  defp require_lease(_state), do: {:error, {:source_lease_failed, :not_owned}}

  defp stop_lease_guard(guard) when is_pid(guard) do
    if Process.alive?(guard) do
      ref = make_ref()
      send(guard, {:stop_source_lease, self(), ref})
      receive do: (^ref -> :ok), after: (5_000 -> :ok)
    end
  end

  defp stop_lease_guard(_guard), do: :ok

  defp lease_renew_interval_ms,
    do: bounded_config(:source_lease_renew_interval_ms, div(@lease_ttl_ms, 3))

  defp operation_timeout_ms,
    do: bounded_config(:source_operation_timeout_ms, @default_operation_timeout_ms)

  defp bounded_config(key, maximum) do
    case Application.get_env(:salix_calendar, key) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _ -> maximum
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref, async: false, info: false)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp lease_holder,
    do:
      "#{Node.self()}:#{inspect(self())}:" <>
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp bump(record, now),
    do: record |> Map.put("updated_at", now) |> Map.update("revision", 1, &(&1 + 1))

  defp digest(value),
    do: value |> JSON.stringify() |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()

  defp now_ms, do: System.system_time(:millisecond)
end
