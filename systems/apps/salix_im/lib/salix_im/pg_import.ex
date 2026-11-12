defmodule SalixIM.PGImport do
  @moduledoc false

  alias SalixIM.{ConversationMessageCodec, ConversationPGStore, ConversationParticipantPGStore}
  alias SalixStore.{Keys, PGAuthorityImport, Repo}

  @root "ctl/group_conversations/"
  @requests "ctl/group_conversation_create_requests/"
  @phases ~w(metadata messages pointers participants receipts create_requests recovery_marks complete)
  @scan_phases ~w(metadata_fused messages_fused json_fused)
  # A window stays within one bounded page. Concurrency is independent so a
  # finished read can refill its slot while an earlier response is still pending.
  @json_concurrency 48
  @source_batch_bytes 4 * 1_048_576

  def inventory(cursor \\ nil, opts \\ []),
    do: with_source_budget(opts, fn opts -> do_inventory(cursor, opts) end)

  defp do_inventory(cursor, opts) do
    cursor = cursor || initial("metadata")

    with {:ok, budget} <- PGAuthorityImport.limits(opts),
         {:ok, facts, next, stats} <- inventory_page(cursor, budget) do
      objects =
        Enum.map(facts, fn fact ->
          %{
            key: fact.key,
            family: fact.kind,
            format: Map.get(fact, :format, if(fact.kind == :segment, do: :jsonl, else: :json))
          }
          |> Map.merge(Map.take(fact, [:facts]))
        end)

      {:ok,
       %{
         objects: objects,
         next: if(next["phase"] == "complete", do: nil, else: next),
         stats: stats,
         validation: :source_codec_only
       }}
    end
  end

  def step(opts \\ []), do: with_context(&do_step/1, opts)

  def with_context(fun, opts \\ []) do
    with_source_budget(opts, fn opts ->
      if Keyword.has_key?(opts, :c_source_index) do
        fun.(opts)
      else
        index = :ets.new(__MODULE__, [:ordered_set, :private])

        try do
          fun.(Keyword.put(opts, :c_source_index, index))
        after
          :ets.delete(index)
        end
      end
    end)
  end

  defp do_step(opts) do
    with {:ok, budget} <- PGAuthorityImport.limits(opts),
         {:ok, state} <- PGAuthorityImport.state(:c) do
      position = state || %{cursor: initial(), step: 0}

      if position.cursor["phase"] == "complete" do
        {:ok, position}
      else
        PGAuthorityImport.with_page(budget, fn ->
          with {:ok, index} <- source_index(position, budget, opts),
               {:ok, facts, next, stats} <-
                 prepare_page(position.cursor, budget, &read_objects/9, index) do
            PGAuthorityImport.commit_page(:c, position, next, fn -> import!(facts) end, stats)
          end
        end)
      end
    end
  end

  def settle(%PGAuthorityImport.Pending{unit: :c} = pending),
    do: PGAuthorityImport.settle_page(pending)

  def run(opts \\ []) do
    pages = Keyword.get(opts, :max_pages, 1)

    if is_integer(pages) and pages in 1..1_000,
      do: with_context(fn opts -> run_pages(opts, pages) end, opts),
      else: {:error, :invalid_import_limits}
  end

  defp with_source_budget(opts, fun) do
    if is_pid(Keyword.get(opts, :source_budget)),
      do: fun.(opts),
      else:
        PGAuthorityImport.with_source_budget(fn shared -> fun.(Keyword.merge(opts, shared)) end)
  end

  defp run_pages(opts, remaining) do
    case step(opts) do
      {:ok, %{cursor: %{"phase" => "complete"}}} = done -> done
      {:ok, _} = progress when remaining == 1 -> progress
      {:ok, _} -> run_pages(opts, remaining - 1)
      error -> error
    end
  end

  def import!(facts) do
    facts
    |> Enum.chunk_by(fn
      %{kind: :locator, scope: scope} -> {:locator, scope}
      %{kind: kind} when kind in [:participant, :receipt] -> kind
      %{kind: :create_request, scope: scope} -> {:create_request, scope.group_id}
      fact -> fact.key
    end)
    |> Enum.each(fn [fact | _] = batch ->
      case fact.kind do
        :locator ->
          import_object!(fact, fn ->
            ConversationPGStore.import_locators!(fact.scope, Enum.map(batch, & &1.record))
          end)

        kind when kind in [:participant, :receipt, :create_request] ->
          batch
          |> Enum.chunk_every(128)
          |> Enum.each(&import_object_batch!/1)

        _ ->
          Enum.each(batch, fn fact -> import_object!(fact, fn -> import_fact!(fact) end) end)
      end
    end)

    :ok
  end

  defp import_object!(fact, apply) do
    apply.()
  rescue
    error in Postgrex.Error ->
      if error.postgres &&
           error.postgres[:code] not in [:admin_shutdown, :crash_shutdown, :cannot_connect_now],
         do: Repo.rollback({:import_object_failed, fact.key, error.postgres[:code]}),
         else: reraise(error, __STACKTRACE__)

    _error in ArgumentError ->
      Repo.rollback({:invalid_source_object, fact.key})
  end

  defp import_object_batch!([fact]),
    do: import_object!(fact, fn -> import_fact!(fact) end)

  defp import_object_batch!([first | _] = facts) do
    PGAuthorityImport.with_import_batch!(
      fn ->
        case first.kind do
          :participant ->
            ConversationParticipantPGStore.import_participants!(facts)

          :receipt ->
            ConversationParticipantPGStore.import_receipts!(facts)

          :create_request ->
            ConversationPGStore.import_create_requests!(
              first.scope.group_id,
              Enum.map(facts, & &1.record)
            )
        end
      end,
      fn error ->
        Enum.each(facts, fn fact -> import_object!(fact, fn -> import_fact!(fact) end) end)
        import_object!(first, fn -> raise error end)
      end
    )
  end

  defp import_fact!(%{kind: :metadata, scope: scope, record: record, revision: revision}),
    do: ConversationPGStore.import_metadata!(scope, record, revision)

  defp import_fact!(%{kind: :segment, scope: scope, messages: messages, archives: archives}) do
    ConversationPGStore.import_archives!(scope, archives)
    ConversationPGStore.import_messages!(scope, messages)
  end

  defp import_fact!(%{kind: :reservation, scope: scope, record: record}),
    do: ConversationPGStore.import_reservations!(scope, [record])

  defp import_fact!(%{kind: :participant, scope: scope} = fact),
    do: ConversationParticipantPGStore.import_participants!(scope, [fact])

  defp import_fact!(%{kind: :receipt, scope: scope} = fact),
    do: ConversationParticipantPGStore.import_receipts!(scope, [fact])

  defp import_fact!(%{kind: :create_request, scope: scope, record: record}),
    do: ConversationPGStore.import_create_requests!(scope.group_id, [record])

  defp import_fact!(%{kind: :historical}), do: :ok

  defp initial(phase \\ "metadata_fused"), do: %{"phase" => phase, "last_object" => nil}

  defp next_phase("metadata_fused"), do: initial("messages_fused")
  defp next_phase("messages_fused"), do: initial("json_fused")
  defp next_phase("json_fused"), do: initial("create_requests")

  defp next_phase(phase),
    do: initial(Enum.at(@phases, Enum.find_index(@phases, &(&1 == phase)) + 1))

  defp source_index(%{cursor: %{"phase" => phase}} = position, budget, opts)
       when phase in @scan_phases do
    index = Keyword.fetch!(opts, :c_source_index)

    with :ok <- ensure_source_index(index, position.step, budget) do
      [{:enumeration, step, stats}] = :ets.lookup(index, :enumeration)
      stats = if step == position.step, do: stats, else: %{list_requests: 0, listed_objects: 0}
      {:ok, {index, stats}}
    end
  end

  defp source_index(_position, _budget, _opts), do: {:ok, nil}

  defp ensure_source_index(index, step, budget) do
    if :ets.member(index, :enumeration) do
      :ok
    else
      :ets.delete_all_objects(index)
      enumerate_source(index, step, nil, budget, %{list_requests: 0, listed_objects: 0})
    end
  end

  defp enumerate_source(index, step, cursor, budget, stats) do
    with {:ok, %{objects: objects, next: next}} <-
           PGAuthorityImport.list_page(@root, cursor, budget),
         true <- objects != [] or is_nil(next) do
      for object <- objects do
        object = Map.take(object, [:key, :size])

        for phase <- @scan_phases,
            not is_nil(classify(object.key, phase)) or index_size?(object.key, phase),
            do: :ets.insert(index, {{phase, object.key}, object})
      end

      stats = %{
        list_requests: stats.list_requests + 1,
        listed_objects: stats.listed_objects + length(objects)
      }

      if is_nil(next) do
        :ets.insert(index, {:enumeration, step, stats})
        :ok
      else
        enumerate_source(index, step, next, budget, stats)
      end
    else
      false -> {:error, {:invalid_source_page, @root}}
      error -> error
    end
  end

  # Only the existing message reader uses these LIST sizes; they produce no facts.
  defp index_size?(key, "messages_fused"),
    do:
      Regex.match?(
        ~r|^ctl/group_conversations/[^/]+/[^/]+/messages/segment_index/[^/]+\.json$|,
        key
      )

  defp index_size?(_key, _phase), do: false

  defp index_page(index, phase, last, limit, objects \\ [])

  defp index_page(index, phase, last, 0, objects),
    do: {Enum.reverse(objects), match?({^phase, _}, :ets.next(index, {phase, last}))}

  defp index_page(index, phase, last, limit, objects) do
    case :ets.next(index, {phase, last || ""}) do
      {^phase, key} = position ->
        [{^position, object}] = :ets.lookup(index, position)
        index_page(index, phase, key, limit - 1, [object | objects])

      _ ->
        {Enum.reverse(objects), false}
    end
  end

  defp source_page(%{"phase" => phase} = cursor, budget, {index, stats}) do
    {objects, more?} = index_page(index, phase, cursor["last_object"], budget.page_size)
    {:ok, %{objects: objects, next: if(more?, do: true), stats: stats}}
  end

  defp source_page(%{"phase" => phase} = cursor, budget, nil) do
    prefix = if phase == "create_requests", do: @requests, else: @root

    with {:ok, page} <-
           PGAuthorityImport.list_page(prefix, nil, budget, start_after: cursor["last_object"]),
         do:
           {:ok, Map.put(page, :stats, %{list_requests: 1, listed_objects: length(page.objects)})}
  end

  defp prepare_page(cursor, budget, reader, index \\ nil)

  defp prepare_page(%{"phase" => "recovery_marks"} = cursor, budget, _reader, _index),
    do: recovery_page(cursor, budget)

  defp prepare_page(%{"phase" => "complete"} = cursor, _budget, _reader, _index),
    do: {:ok, [], cursor, %{objects: 0, wire_bytes: 0, inflated_bytes: 0}}

  defp prepare_page(%{"phase" => phase} = cursor, budget, reader, index)
       when phase in @phases or phase in @scan_phases do
    prefix = if phase == "create_requests", do: @requests, else: @root

    with {:ok, %{objects: objects, next: next, stats: list_stats}} <-
           source_page(cursor, budget, index),
         true <- objects != [] or is_nil(next),
         {:ok, cache} <- page_cache(phase, objects),
         {:ok, facts, following, stats} <-
           reader.(objects, phase, cursor, next, 0, budget, budget, [], cache) do
      {:ok, facts, following, Map.merge(stats, list_stats)}
    else
      false -> {:error, {:invalid_source_page, prefix}}
      error -> error
    end
  end

  defp prepare_page(_, _, _, _), do: {:error, :invalid_import_progress}

  defp page_cache("messages_fused", objects) do
    segments =
      for object <- objects,
          {:segment, scope, _} <- [classify(object.key, "messages_fused")],
          do: {object, scope, :segment}

    sizes =
      Map.new(
        for object <- objects,
            is_integer(Map.get(object, :size)),
            object.size >= 0,
            do: {{:object_size, object.key}, max(object.size, 1)}
      )

    imported_metadata(segments, sizes)
  end

  defp page_cache(_phase, _objects), do: {:ok, %{}}

  defp read_objects([], phase, cursor, next, _index, original, budget, facts, _cache) do
    next_cursor = if is_nil(next), do: next_phase(phase), else: cursor

    {:ok, Enum.reverse(facts), next_cursor, page_stats(original, budget)}
  end

  defp read_objects(
         [object | _] = objects,
         phase,
         cursor,
         next,
         index,
         original,
         budget,
         facts,
         cache
       )
       when phase in ["pointers", "participants", "receipts", "json_fused"] do
    case classify(object.key, phase) do
      {kind, _scope, nil} when kind in [:pointer, :participant, :receipt] ->
        read_json_objects(
          objects,
          phase,
          kind,
          cursor,
          next,
          index,
          original,
          budget,
          facts,
          cache
        )

      _ ->
        read_object(objects, phase, cursor, next, index, original, budget, facts, cache)
    end
  end

  defp read_objects(objects, phase, cursor, next, index, original, budget, facts, cache) do
    case source_batch(objects, phase, budget, cache, [], 0, 0) do
      {[], _rest} ->
        read_object(objects, phase, cursor, next, index, original, budget, facts, cache)

      {batch, rest} ->
        results =
          batch
          |> Enum.reject(fn {_object, reserved} -> reserved == 0 end)
          |> SystemsClock.async_stream(
            fn {object, reserved} ->
              child = %{
                budget
                | remaining_bytes: reserved,
                  objects: 0,
                  wire_bytes: 0,
                  inflated_bytes: 0
              }

              {object.key, prepare_object(object.key, phase, child, cache)}
            end,
            max_concurrency: @json_concurrency,
            ordered: true,
            timeout: :infinity
          )
          |> Map.new(fn {:ok, result} -> result end)

        ordered =
          Enum.map(batch, fn {object, reserved} = entry ->
            result =
              if reserved == 0,
                do: {:ok, nil, %{budget | objects: 0, wire_bytes: 0, inflated_bytes: 0}, cache},
                else: Map.fetch!(results, object.key)

            {entry, {:ok, result}}
          end)

        prepared =
          ordered
          |> Enum.reduce_while({:ok, facts, cursor, index, budget}, fn
            {{object, _}, {:ok, {:ok, fact, child, _cache}}},
            {:ok, facts, cursor, index, budget} ->
              budget = merge_budget(budget, child)
              facts = if is_nil(fact), do: facts, else: [fact | facts]
              {:cont, {:ok, facts, Map.put(cursor, "last_object", object.key), index + 1, budget}}

            {{object, _}, {:ok, {:error, reason, _child}}}, {:ok, facts, cursor, index, budget} ->
              {:halt,
               {:finished,
                source_error(object.key, reason, index, original, budget, facts, cursor)}}

            {{object, _}, {:ok, {:error, reason}}}, {:ok, facts, cursor, index, budget} ->
              {:halt,
               {:finished,
                source_error(object.key, reason, index, original, budget, facts, cursor)}}
          end)

        case prepared do
          {:ok, facts, cursor, index, budget} ->
            read_objects(rest, phase, cursor, next, index, original, budget, facts, cache)

          {:finished, result} ->
            result
        end
    end
  end

  defp merge_budget(budget, child) do
    %{
      budget
      | remaining_bytes: budget.remaining_bytes - child.wire_bytes,
        objects: budget.objects + child.objects,
        wire_bytes: budget.wire_bytes + child.wire_bytes,
        inflated_bytes: budget.inflated_bytes + child.inflated_bytes
    }
  end

  defp source_batch([object | rest] = objects, phase, budget, cache, batch, count, bytes)
       when count < budget.page_size do
    size = Map.get(object, :size)

    reservation =
      case classify(object.key, phase) do
        nil ->
          0

        {kind, _scope, _} when kind in [:metadata, :create_request] ->
          if is_integer(size) and size >= 0, do: max(size, 1)

        {:segment, scope, segment} when phase == "messages_fused" ->
          index_key =
            Keys.ctl_group_conversation_message_segment_index(
              scope.group_id,
              scope.conversation_id,
              segment
            )

          if is_integer(size),
            do: size + Map.get(cache, {:object_size, index_key}, budget.max_object_bytes)

        _ ->
          nil
      end

    cond do
      reservation == 0 ->
        source_batch(rest, phase, budget, cache, [{object, 0} | batch], count, bytes)

      is_integer(reservation) and reservation > 0 and is_integer(size) and
        size <= budget.max_object_bytes and reservation <= budget.remaining_bytes and
          (bytes == 0 or bytes + max(size, 1) <= @source_batch_bytes) ->
        source_batch(
          rest,
          phase,
          %{budget | remaining_bytes: budget.remaining_bytes - reservation},
          cache,
          [{object, reservation} | batch],
          count + 1,
          bytes + max(size, 1)
        )

      true ->
        {Enum.reverse(batch), objects}
    end
  end

  defp source_batch(objects, _phase, _budget, _cache, batch, _count, _bytes),
    do: {Enum.reverse(batch), objects}

  defp read_source_objects([], phase, cursor, next, index, original, budget, facts, cache),
    do: read_objects([], phase, cursor, next, index, original, budget, facts, cache)

  defp read_source_objects(objects, phase, cursor, next, index, original, budget, facts, cache),
    do:
      read_object(
        objects,
        phase,
        cursor,
        next,
        index,
        original,
        budget,
        facts,
        cache,
        &read_source_objects/9
      )

  defp read_object(
         [object | rest],
         phase,
         cursor,
         next,
         index,
         original,
         budget,
         facts,
         cache,
         continue \\ &read_objects/9
       ) do
    key = object.key

    case prepare_object(key, phase, budget, cache) do
      {:ok, prepared, budget, cache} ->
        cursor = Map.put(cursor, "last_object", key)
        facts = if is_nil(prepared), do: facts, else: [prepared | facts]
        continue.(rest, phase, cursor, next, index + 1, original, budget, facts, cache)

      {:error, reason, budget} ->
        source_error(key, reason, index, original, budget, facts, cursor)

      {:error, reason} ->
        source_error(key, reason, index, original, budget, facts, cursor)
    end
  end

  defp read_json_objects(
         objects,
         phase,
         kind,
         cursor,
         next,
         index,
         original,
         budget,
         facts,
         cache
       ) do
    key = hd(objects).key

    case json_batch(objects, phase, kind, budget, [], 0) do
      {[], _} ->
        size = Map.get(hd(objects), :size)

        reason =
          if is_integer(size) and size >= 0,
            do: {:source_byte_limit, key},
            else: {:invalid_source_object_size, key}

        source_error(key, reason, index, original, budget, facts, cursor)

      {batch, rest} ->
        with {:ok, metadata} <- imported_metadata(batch, cache) do
          results =
            batch
            |> Enum.reject(fn {_object, scope, _kind} -> is_nil(scope) end)
            |> SystemsClock.async_stream(
              fn {object, _scope, _kind} ->
                child = %{
                  budget
                  | remaining_bytes: max(object.size, 1),
                    objects: 0,
                    wire_bytes: 0,
                    inflated_bytes: 0
                }

                {object.key, json(object.key, child)}
              end,
              max_concurrency: @json_concurrency,
              ordered: true,
              timeout: :infinity
            )
            |> Map.new(fn {:ok, result} -> result end)

          budget =
            Enum.reduce(results, budget, fn
              {_key, {:ok, _, child}}, budget ->
                %{
                  budget
                  | remaining_bytes: budget.remaining_bytes - child.wire_bytes,
                    objects: budget.objects + child.objects,
                    wire_bytes: budget.wire_bytes + child.wire_bytes,
                    inflated_bytes: budget.inflated_bytes + child.inflated_bytes
                }

              {_key, {:error, _}}, budget ->
                budget
            end)

          prepared =
            Enum.reduce_while(batch, {:ok, facts, cursor, index}, fn
              {object, scope, fact_kind}, {:ok, facts, cursor, index} ->
                result =
                  if is_nil(scope) do
                    {:ok, nil}
                  else
                    with {:ok, meta} <- imported_metadata(metadata, scope, object.key),
                         {:ok, record, _} <- Map.fetch!(results, object.key),
                         do: prepare_json(fact_kind, object.key, scope, meta, record)
                  end

                case result do
                  {:ok, fact} ->
                    facts = if is_nil(fact), do: facts, else: [fact | facts]
                    {:cont, {:ok, facts, Map.put(cursor, "last_object", object.key), index + 1}}

                  {:error, reason} ->
                    {:halt,
                     {:finished,
                      source_error(object.key, reason, index, original, budget, facts, cursor)}}
                end
            end)

          case prepared do
            {:ok, facts, cursor, index} ->
              read_objects(rest, phase, cursor, next, index, original, budget, facts, metadata)

            {:finished, result} ->
              result
          end
        else
          {:error, reason} -> source_error(key, reason, index, original, budget, facts, cursor)
        end
    end
  end

  defp json_batch([object | rest] = objects, phase, kind, budget, batch, count)
       when count < budget.page_size do
    size = Map.get(object, :size)

    case classify(object.key, phase) do
      nil ->
        json_batch(rest, phase, kind, budget, [{object, nil, nil} | batch], count)

      {fact_kind, scope, nil}
      when (fact_kind == kind or phase == "json_fused") and is_integer(size) and size >= 0 and
             max(size, 1) <= min(budget.max_object_bytes, budget.remaining_bytes) ->
        json_batch(
          rest,
          phase,
          kind,
          %{budget | remaining_bytes: budget.remaining_bytes - max(size, 1)},
          [{object, scope, fact_kind} | batch],
          count + 1
        )

      _ ->
        {Enum.reverse(batch), objects}
    end
  end

  defp json_batch(objects, _phase, _kind, _budget, batch, _count),
    do: {Enum.reverse(batch), objects}

  defp imported_metadata(batch, cache) do
    scopes =
      for {_object, scope, _kind} <- batch,
          not is_nil(scope) and not Map.has_key?(cache, scope),
          uniq: true,
          do: scope

    if scopes == [] do
      {:ok, cache}
    else
      load_imported_metadata(scopes, cache)
    end
  end

  defp load_imported_metadata(scopes, cache) do
    tuples =
      scopes
      |> Enum.with_index()
      |> Enum.map_join(",", fn {_scope, index} ->
        first = index * 2 + 1
        "($#{first}::text,$#{first + 1}::text)"
      end)

    params = Enum.flat_map(scopes, &[&1.group_id, &1.conversation_id])

    case Repo.query(
           "SELECT group_id,conversation_id,message_tail_seq FROM salix_conversations " <>
             "WHERE (group_id,conversation_id) IN (#{tuples})",
           params
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.reduce(rows, cache, fn [group, conversation, tail], cache ->
           Map.put(cache, ConversationPGStore.new(group, conversation), %{
             "message_tail_seq" => tail
           })
         end)}

      {:error, _} ->
        {:error, :import_source_database_unavailable}
    end
  end

  defp imported_metadata(metadata, scope, key) do
    case Map.fetch(metadata, scope) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, {:unsettled_publication, key, :metadata_missing}}
    end
  end

  defp source_error(_key, {:source_byte_limit, _}, index, original, budget, facts, cursor)
       when index > 0,
       do: {:ok, Enum.reverse(facts), cursor, page_stats(original, budget)}

  defp source_error(key, reason, _index, _original, _budget, _facts, _cursor),
    do: {:error, {:import_source_object, key, reason}}

  defp prepare_object(key, phase, budget, cache) do
    case classify(key, phase) do
      {:segment, scope, extra} when phase == "messages_fused" ->
        with {:ok, record} <- imported_metadata(cache, scope, key) do
          meta_key = Keys.ctl_group_conversation_meta(scope.group_id, scope.conversation_id)
          prepare_kind(:segment, key, scope, extra, budget, Map.put(cache, meta_key, record))
        end

      nil ->
        {:ok, nil, budget, cache}

      {kind, scope, extra} ->
        prepare_kind(kind, key, scope, extra, budget, cache)
    end
  end

  defp classify(key, "create_requests") do
    case Regex.run(~r|^ctl/group_conversation_create_requests/([^/]+)/[^/]+\.json$|, key) do
      [_, group] -> {:create_request, %{group_id: group}, nil}
      _ -> nil
    end
  end

  defp classify(key, "metadata_fused"), do: classify(key, "metadata")

  defp classify(key, phase) do
    match =
      if phase == "metadata",
        do: Regex.run(~r|^ctl/group_conversations/([^/]+)/([^/]+)\.json$|, key)

    case match || Regex.run(~r|^ctl/group_conversations/([^/]+)/([^/]+)/(.*)$|, key) do
      [_, group, conversation] ->
        {:legacy_conversation, ConversationPGStore.new(group, conversation), nil}

      [_, group, conversation, suffix] ->
        scope = ConversationPGStore.new(group, conversation)

        cond do
          phase == "metadata" and suffix == "meta.json" ->
            {:metadata, scope, nil}

          phase in ["messages", "messages_fused"] and
              Regex.match?(~r|^messages/segments/[^/]+\.jsonl$|, suffix) ->
            {:segment, scope, suffix |> Path.basename(".jsonl")}

          phase in ["pointers", "json_fused"] and
              Regex.match?(
                ~r{^(messages/by_id|idempotency/messages)/[^/]+\.json$},
                suffix
              ) ->
            {:pointer, scope, nil}

          phase in ["participants", "json_fused"] and
              Regex.match?(~r|^participant_states/[^/]+\.json$|, suffix) ->
            {:participant, scope, nil}

          phase in ["participants", "messages_fused"] and
              Regex.match?(~r|^participants/[^/]+/state\.json$|, suffix) ->
            {:legacy_participant, scope, nil}

          phase in ["receipts", "json_fused"] and
              Regex.match?(~r|^participants/[^/]+/deliveries/[^/]+/state\.json$|, suffix) ->
            {:receipt, scope, nil}

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp prepare_kind(:legacy_conversation, key, scope, _, budget, cache) do
    case metadata(scope, key, budget, cache) do
      {:ok, _meta, budget, cache} ->
        {:ok, %{kind: :historical, key: key}, budget, cache}

      {:error, {:unsettled_publication, ^key, :metadata_missing}} ->
        {:error, {:unsettled_conversation_format, key}}

      error ->
        error
    end
  end

  defp prepare_kind(:metadata, key, scope, _, budget, cache) do
    with {:ok, record, budget} <- json(key, budget),
         :ok <- record_scope(record, scope, key),
         true <-
           is_binary(record["kind"]) and record["kind"] != "" and is_integer(tail(record)) and
             tail(record) >= 0 do
      {:ok,
       %{kind: :metadata, key: key, scope: scope, record: record, revision: revision(record)},
       budget, cache}
    else
      false -> {:error, :invalid_conversation_metadata}
      error -> error
    end
  end

  defp prepare_kind(:segment, key, scope, segment, budget, cache) do
    with {:ok, meta, budget, cache} <- metadata(scope, key, budget, cache),
         {:ok, source, budget} <- PGAuthorityImport.read_binary(key, budget),
         {:ok, rows} <-
           PGAuthorityImport.with_decode(budget, fn ->
             ConversationMessageCodec.decode_segment(source.value)
           end),
         true <- rows != [],
         :ok <- published(rows, meta, key),
         {:ok, index, budget} <-
           optional_json(
             Keys.ctl_group_conversation_message_segment_index(
               scope.group_id,
               scope.conversation_id,
               segment
             ),
             budget
           ) do
      budget = %{budget | inflated_bytes: budget.inflated_bytes + source.bytes}
      segment_facts = ConversationMessageCodec.segment_facts(rows)
      first = segment_facts["start_seq"]
      last = segment_facts["end_seq"]
      cold? = is_map(index) and index["status"] == "sealed"

      archives =
        if cold?,
          do: [%{first_seq: first, last_seq: last, object_key: key, encoding: "jsonl"}],
          else: []

      messages =
        Enum.map(rows, fn row ->
          %{
            record: row,
            revision: revision(row),
            tombstone: row["tombstone"] == true,
            archive_first_seq: if(cold?, do: first)
          }
        end)

      {:ok, %{kind: :segment, key: key, scope: scope, messages: messages, archives: archives},
       budget, cache}
    else
      false -> {:error, :invalid_message_segment}
      error -> error
    end
  end

  defp prepare_kind(kind, key, scope, _, budget, cache)
       when kind in [:pointer, :participant, :receipt] do
    with {:ok, meta, budget, cache} <- metadata(scope, key, budget, cache) do
      case json(key, budget) do
        {:ok, record, budget} ->
          with {:ok, fact} <- prepare_json(kind, key, scope, meta, record),
               do: {:ok, fact, budget, cache}

        {:error, {:source_byte_limit, _} = reason} ->
          {:error, reason, budget}

        error ->
          error
      end
    end
  end

  defp prepare_kind(:legacy_participant, key, scope, _, budget, cache) do
    with {:ok, record, budget} <- json(key, budget),
         id when is_binary(id) and id != "" <- record["participant_id"],
         {:ok, _current, budget} <-
           json(
             Keys.ctl_group_conversation_participant_state(
               scope.group_id,
               scope.conversation_id,
               id
             ),
             budget
           ) do
      {:ok, %{kind: :historical, key: key}, budget, cache}
    else
      {:error, :not_found} -> {:error, {:unsettled_participant_state, key}}
      {:error, _} = error -> error
      _ -> {:error, :invalid_participant_identity}
    end
  end

  defp prepare_kind(:create_request, key, scope, _, budget, cache) do
    with {:ok, record, budget} <- json(key, budget),
         true <- record["group_id"] == scope.group_id,
         true <-
           Enum.all?(
             ~w(request_identity conversation_id request_fingerprint),
             &(is_binary(record[&1]) and record[&1] != "")
           ),
         true <- is_nil(record["task_placement"]) or is_map(record["task_placement"]) do
      {:ok, %{kind: :create_request, key: key, scope: scope, record: record}, budget, cache}
    else
      false -> {:error, :invalid_conversation_create_request}
      error -> error
    end
  end

  defp prepare_json(:pointer, key, scope, meta, record) do
    with :ok <- ConversationMessageCodec.validate_pointer(record, %{}, allow_reservation: true) do
      cond do
        record["status"] == "reserved" ->
          if is_integer(record["created_at"]) and is_binary(record["request_identity"]) and
               String.trim(record["request_identity"]) != "",
             do: {:ok, %{kind: :reservation, key: key, scope: scope, record: record}},
             else: {:error, :invalid_message_reservation}

        record["seq"] > tail(meta) ->
          {:error, {:unsettled_publication, key, record["seq"], tail(meta)}}

        true ->
          {:ok, %{kind: :locator, key: key, scope: scope, record: record}}
      end
    end
  end

  defp prepare_json(kind, key, scope, _meta, record) when kind in [:participant, :receipt] do
    with :ok <- record_scope(record, scope, key),
         true <- is_binary(record["participant_id"]) and record["participant_id"] != "",
         true <-
           kind != :receipt or (is_binary(record["delivery_id"]) and record["delivery_id"] != "") do
      {:ok, %{kind: kind, key: key, scope: scope, record: record, revision: revision(record)}}
    else
      false -> {:error, :invalid_participant_identity}
      error -> error
    end
  end

  defp metadata(scope, object, budget, cache) do
    key = Keys.ctl_group_conversation_meta(scope.group_id, scope.conversation_id)

    case Map.fetch(cache, key) do
      {:ok, record} ->
        {:ok, record, budget, cache}

      :error ->
        with {:ok, record, budget} <- json(key, budget),
             :ok <- record_scope(record, scope, key) do
          {:ok, record, budget, Map.put(cache, key, record)}
        else
          {:error, :not_found} -> {:error, {:unsettled_publication, object, :metadata_missing}}
          error -> error
        end
    end
  end

  defp json(key, budget) do
    case PGAuthorityImport.read_json(key, budget) do
      {:ok, %{value: record}, budget} when is_map(record) -> {:ok, record, budget}
      {:ok, _, _} -> {:error, {:invalid_source_json, key}}
      error -> error
    end
  end

  defp optional_json(key, budget) do
    case json(key, budget) do
      {:error, :not_found} -> {:ok, nil, budget}
      result -> result
    end
  end

  defp record_scope(record, scope, key) do
    if record["conversation_id"] in [nil, scope.conversation_id] and
         record["agent_group_id"] in [nil, scope.group_id],
       do: :ok,
       else: {:error, {:source_scope_conflict, key}}
  end

  defp published(rows, meta, key) do
    case Enum.find(rows, &(&1["seq"] > tail(meta))) do
      nil -> :ok
      row -> {:error, {:unsettled_publication, key, row["seq"], tail(meta)}}
    end
  end

  defp tail(meta), do: meta["message_tail_seq"] || meta["message_count"] || 0
  defp revision(record), do: record["revision"] || 1

  defp page_stats(original, budget) do
    Map.new([:objects, :wire_bytes, :inflated_bytes], fn field ->
      {field, budget[field] - original[field]}
    end)
  end

  defp inventory_page(%{"phase" => "recovery_marks"} = cursor, budget) do
    case Repo.query(
           "SELECT group_id,conversation_id,target_seq,status_version,membership_revision,due_at_ms " <>
             "FROM conversation_log_recovery WHERE (group_id,conversation_id)>($1,$2) " <>
             "ORDER BY group_id,conversation_id LIMIT $3",
           (cursor["after"] || ["", ""]) ++ [budget.page_size]
         ) do
      {:ok, %{rows: rows}} ->
        facts =
          Enum.map(rows, fn [group, conversation, target, status, membership, due] ->
            %{
              key: "conversation_log_recovery/#{group}/#{conversation}",
              kind: :recovery_mark,
              format: :postgresql,
              facts: %{
                target_seq: target,
                status_version: status,
                membership_revision: membership,
                due_at_ms: due
              }
            }
          end)

        next =
          if rows == [],
            do: %{"phase" => "complete"},
            else: %{"phase" => "recovery_marks", "after" => Enum.take(List.last(rows), 2)}

        {:ok, facts, next, %{objects: length(rows), wire_bytes: 0, inflated_bytes: 0}}

      {:error, _} ->
        {:error, :import_source_database_unavailable}
    end
  end

  defp inventory_page(%{"phase" => phase} = cursor, budget) when phase in @phases,
    do: prepare_page(cursor, budget, &read_source_objects/9)

  defp inventory_page(_, _), do: {:error, :invalid_import_progress}

  defp recovery_page(cursor, budget) do
    after_key = cursor["after"] || ["", ""]

    case Repo.query(
           "SELECT r.group_id,r.conversation_id,r.target_seq,r.status_version,c.message_tail_seq,c.provider_status_version " <>
             "FROM conversation_log_recovery r LEFT JOIN salix_conversations c USING(group_id,conversation_id) " <>
             "WHERE (r.group_id,r.conversation_id)>($1,$2) ORDER BY r.group_id,r.conversation_id LIMIT $3",
           after_key ++ [budget.page_size]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, [], %{"phase" => "complete"}, %{objects: 0, wire_bytes: 0, inflated_bytes: 0}}

      {:ok, %{rows: rows}} ->
        case Enum.find(rows, fn [_group, _conversation, target, status, tail, version] ->
               is_nil(tail) or target > tail or status > (version || 0)
             end) do
          nil ->
            {:ok, [], %{"phase" => "recovery_marks", "after" => Enum.take(List.last(rows), 2)},
             %{objects: 0, wire_bytes: 0, inflated_bytes: 0}}

          [group, conversation, target, status | _] ->
            {:error,
             {:unsettled_publication, "conversation_log_recovery", group, conversation, target,
              status}}
        end

      {:error, _} ->
        {:error, :import_source_database_unavailable}
    end
  end
end
