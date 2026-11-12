defmodule SalixAgent.PGImport do
  @moduledoc """
  Offline S authority import after the release runner stops the old writers.

  Each call reads one bounded source page before it opens a SQL transaction.
  Source bodies and external history remain in place. A source that cannot be
  restored precisely stops the unit at that object.
  """

  alias SalixAgent.{CapabilityRequests, InternalSession, InternalSessionArchiveReader}
  alias SalixAgent.InternalSessionStore.ImportTargets
  alias SalixAgent.InternalSessionStore.PG, as: SessionPG
  alias SalixAgent.CapabilityRequestStore.PG, as: CapabilityPG
  alias SalixStore.{AgentPGStore, Head, Keys, PGAuthorityImport, Repo}

  @phases ~w(agents runtimes capabilities complete)

  def step(opts \\ []) do
    with {:ok, state} <- PGAuthorityImport.state(:s) do
      if state && state.cursor["phase"] == "complete",
        do: {:ok, state},
        else: with_context(fn context -> do_step(context, state) end, opts)
    end
  end

  defp do_step(opts, state) do
    with {:ok, budget} <- PGAuthorityImport.limits(opts) do
      position = state || %{cursor: initial(), step: 0}

      if position.cursor["phase"] == "complete" do
        {:ok, position}
      else
        PGAuthorityImport.with_page(budget, fn ->
          with {:ok, facts, next, stats} <- prepare_page(position.cursor, budget, opts) do
            PGAuthorityImport.commit_page(:s, position, next, fn -> import!(facts) end, stats)
          end
        end)
      end
    end
  end

  def settle(%PGAuthorityImport.Pending{unit: :s} = pending),
    do: PGAuthorityImport.settle_page(pending)

  def run(opts \\ []) do
    pages = Keyword.get(opts, :max_pages, 1)

    if is_integer(pages) and pages in 1..1000,
      do: with_context(fn context -> run_pages(context, pages) end, opts),
      else: {:error, :invalid_import_limits}
  end

  @doc "Keep the transient original-identity index across source pages."
  def with_context(fun, opts \\ []) do
    with {:ok, opts} <- cold_result_locations(opts) do
      source_context(fun, opts)
    end
  end

  defp cold_result_locations(opts) do
    if Keyword.has_key?(opts, :cold_result_location_index) do
      {:ok, opts}
    else
      locations =
        Keyword.get_lazy(opts, :cold_result_locations, fn ->
          SystemsRuntime.get_env(:salix_agent, :pg_import_cold_result_locations, [])
        end)

      case location_index(locations) do
        {:ok, index} -> {:ok, Keyword.put(opts, :cold_result_location_index, index)}
        error -> error
      end
    end
  end

  defp location_index(locations) when is_list(locations) do
    Enum.reduce_while(locations, {:ok, %{}}, fn
      %{"agent_id" => agent, "session_id" => session, "tool_call_id" => id, "seq" => seq} =
          location,
      {:ok, index}
      when map_size(location) == 4 and is_binary(agent) and agent != "" and
             is_binary(session) and session != "" and is_binary(id) and id != "" and
             is_integer(seq) and seq > 0 ->
        key = {agent, session, id}

        case Map.fetch(index, key) do
          {:ok, existing} when existing != seq ->
            {:halt, {:error, :conflicting_import_cold_result_location}}

          _ ->
            {:cont, {:ok, Map.put(index, key, seq)}}
        end

      _, _ ->
        {:halt, {:error, :invalid_import_cold_result_locations}}
    end)
  end

  defp location_index(_), do: {:error, :invalid_import_cold_result_locations}

  defp source_context(fun, opts) do
    if Keyword.has_key?(opts, :source_budget),
      do: with_birth_index(fun, opts),
      else:
        PGAuthorityImport.with_source_budget(fn shared ->
          with_birth_index(fun, Keyword.merge(opts, shared))
        end)
  end

  defp with_birth_index(fun, opts) do
    if Keyword.has_key?(opts, :birth_index) do
      fun.(opts)
    else
      index = :ets.new(__MODULE__, [:set])

      try do
        fun.(Keyword.put(opts, :birth_index, index))
      after
        :ets.delete(index)
      end
    end
  end

  defp ensure_birth_index("runtimes", opts) do
    index = Keyword.fetch!(opts, :birth_index)

    if :ets.member(index, :loaded) do
      :ok
    else
      with :ok <- load_birth_index(index, nil) do
        :ets.insert(index, {:loaded, true})
        :ok
      end
    end
  end

  defp ensure_birth_index(_, _opts), do: :ok

  defp load_birth_index(index, cursor) do
    case SessionPG.import_birth_page(cursor) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        for [agent, session, side] <- rows do
          :ets.insert(index, {Keys.agent_session_birth(agent, session), session, side})
        end

        [agent, session, _] = List.last(rows)
        load_birth_index(index, {agent, session})

      error ->
        error
    end
  end

  defp run_pages(opts, remaining) do
    case step(opts) do
      {:ok, %{cursor: %{"phase" => "complete"}}} = done -> done
      {:ok, _} = progress when remaining == 1 -> progress
      {:ok, _} -> run_pages(opts, remaining - 1)
      error -> error
    end
  end

  @doc "Inspect one source page without writing objects, facts or progress."
  def inventory(cursor \\ nil, opts \\ []) do
    with_context(
      fn opts ->
        with {:ok, budget} <- PGAuthorityImport.limits(opts),
             {:ok, facts, next, stats} <-
               prepare_page(cursor || initial(), budget, Keyword.put(opts, :inventory, true)) do
          {:ok,
           %{
             objects: Enum.map(facts, &Map.take(&1, [:key, :kind, :format])),
             next: if(next["phase"] != "complete", do: next),
             stats: stats,
             validation: :source_codec_only
           }}
        end
      end,
      opts
    )
  end

  defp project_delivery(facts, budget, opts) do
    if Keyword.get(opts, :inventory, false) do
      {:ok, facts, budget}
    else
      facts
      |> Enum.filter(
        &(&1.kind == :capability and &1.record["status"] != "cancelled" and
            is_map(&1.record["result"]))
      )
      |> Enum.group_by(&{&1.record["source_agent_id"], &1.record["source_session_id"]})
      |> Enum.reduce_while({:ok, %{}, budget}, fn {{agent, session}, requests},
                                                  {:ok, projections, budget} ->
        ids = Enum.map(requests, & &1.record["tool_call_id"]) |> Enum.uniq()

        case ImportTargets.read(agent, session, ids, budget,
               cold_result_locations: Keyword.fetch!(opts, :cold_result_location_index)
             ) do
          {:ok, targets, budget} ->
            case project_requests(requests, targets, projections) do
              {:ok, projections} -> {:cont, {:ok, projections, budget}}
              error -> {:halt, error}
            end

          error ->
            {:halt, object_error(hd(requests).key, error)}
        end
      end)
      |> case do
        {:ok, projections, budget} ->
          {:ok, Enum.map(facts, &Map.put(&1, :delivery, projections[&1.key] || :none)), budget}

        error ->
          error
      end
    end
  end

  defp project_requests(requests, targets, projections) do
    Enum.reduce_while(requests, {:ok, projections}, fn fact, {:ok, projections} ->
      record = fact.record

      delivery =
        case targets[record["tool_call_id"]] do
          :already_resolved ->
            {:ok, {:acknowledged, SystemsClock.utc_now()}}

          {:running, call} ->
            if call["capability_request_id"] in [nil, "", record["request_id"]] and
                 call["tool_name"] in [nil, "", CapabilityRequests.tool_name_for_request(record)],
               do: {:ok, :due},
               else: {:error, :conflicting_completion_target}

          _ ->
            {:error, :unresolved_completion_target}
        end

      case delivery do
        {:ok, delivery} -> {:cont, {:ok, Map.put(projections, fact.key, delivery)}}
        error -> {:halt, object_error(fact.key, error)}
      end
    end)
  end

  defp initial(phase \\ "agents"), do: %{"phase" => phase, "last_object" => nil}

  defp next_phase(phase),
    do: initial(Enum.at(@phases, Enum.find_index(@phases, &(&1 == phase)) + 1))

  defp prepare_page(%{"phase" => phase} = cursor, budget, opts)
       when phase in @phases and phase != "complete" do
    prefix =
      case phase do
        "agents" -> "ctl/agents/"
        "capabilities" -> "ctl/capability_requests/"
        _ -> "agents/"
      end

    with :ok <- ensure_birth_index(phase, opts),
         {:ok, %{objects: objects, next: next}} <-
           PGAuthorityImport.list_page(prefix, nil, budget, start_after: cursor["last_object"]) do
      with {:ok, facts, following, stats, budget} <-
             read_objects(
               objects,
               cursor,
               next,
               0,
               budget,
               budget,
               [],
               Keyword.put(opts, :prepared_births, %{})
             ) do
        with {:ok, facts, budget} <- project_delivery(facts, budget, opts) do
          {:ok, facts, following,
           Map.merge(stats, %{
             list_requests: 1,
             listed_objects: length(objects),
             objects: budget.objects,
             wire_bytes: budget.wire_bytes,
             inflated_bytes: budget.inflated_bytes
           })}
        end
      end
    end
  end

  defp prepare_page(_, _, _), do: {:error, :invalid_import_progress}

  defp read_objects([], cursor, next, _index, original, budget, facts, _opts) do
    following =
      if is_nil(next),
        do: next_phase(cursor["phase"]),
        else: cursor

    {:ok, Enum.reverse(facts), following, stats(original, budget, facts), budget}
  end

  defp read_objects(
         [%{key: key} | rest] = objects,
         cursor,
         next,
         index,
         original,
         budget,
         facts,
         opts
       ) do
    budget =
      if budget.remaining_bytes == 0 or Map.has_key?(budget.prefetched, key) or
           not readable?(key, cursor["phase"]) do
        budget
      else
        sources = prefetch_keys(objects, cursor["phase"], budget)
        PGAuthorityImport.prefetch(sources, budget)
      end

    before = budget

    result =
      with {:ok, fact, budget} <- prepare_object(key, cursor["phase"], budget, opts),
           {:ok, fact, opts} <- remember_birth(fact, opts) do
        {:ok, fact, budget, opts}
      end

    case result do
      {:ok, _fact, prepared, _opts}
      when index > 0 and prepared.inflated_bytes > prepared.max_page_inflated_bytes ->
        spent = %{
          before
          | objects: prepared.objects,
            wire_bytes: prepared.wire_bytes,
            inflated_bytes: prepared.inflated_bytes
        }

        {:ok, Enum.reverse(facts), cursor, stats(original, spent, facts), spent}

      {:ok, fact, budget, opts} ->
        budget = %{budget | prefetched: Map.delete(budget.prefetched, key)}
        facts = if is_nil(fact), do: facts, else: [fact | facts]

        read_objects(
          rest,
          Map.put(cursor, "last_object", key),
          next,
          index + 1,
          original,
          budget,
          facts,
          opts
        )

      {:error, {:source_byte_limit, _}} when index > 0 ->
        {:ok, Enum.reverse(facts), cursor, stats(original, budget, facts), budget}

      {:error, _} = error ->
        object_error(key, error)
    end
  end

  defp remember_birth(%{kind: :session, frozen: frozen} = fact, opts),
    do: remember_birth(fact, frozen.agent_id, frozen.session_id, :internal, opts)

  defp remember_birth(%{kind: kind, agent: agent, session: session, side: side} = fact, opts)
       when kind in [:birth, :birth_source],
       do: remember_birth(fact, agent, session, side, opts)

  defp remember_birth(fact, opts), do: {:ok, fact, opts}

  defp remember_birth(fact, agent, session, side, opts) do
    index = Keyword.fetch!(opts, :birth_index)
    key = Keys.agent_session_birth(agent, session)
    encoded = Atom.to_string(side)

    case :ets.lookup(index, key) do
      [{^key, ^session, other}] when other != encoded ->
        {:error, :conflicting_session_birth}

      _ ->
        births = Keyword.fetch!(opts, :prepared_births)

        case Map.fetch(births, {agent, session}) do
          :error ->
            :ets.insert(index, {key, session, encoded})

            {:ok, fact,
             Keyword.put(opts, :prepared_births, Map.put(births, {agent, session}, side))}

          {:ok, ^side} ->
            {:ok, if(fact.kind == :birth, do: %{fact | kind: :birth_source}, else: fact), opts}

          {:ok, _} ->
            {:error, :conflicting_session_birth}
        end
    end
  end

  defp readable?(key, "agents"), do: Regex.match?(~r{^ctl/agents/[^/]+\.json$}, key)

  defp readable?(key, "capabilities"),
    do: Regex.match?(~r{^ctl/capability_requests/[^/]+/[^/]+\.json$}, key)

  defp readable?(key, "runtimes"),
    do:
      Regex.match?(
        ~r{^agents/[^/]+/(internal_runtime/sessions/[^/]+/state\.etf\.zst|external_runtime/sessions/[^/]+\.json|session_birth/[0-9a-f]+\.json)$},
        key
      )

  defp prefetch_keys(objects, phase, budget) do
    objects
    |> Enum.reduce_while({[], 0}, fn object, {keys, bytes} ->
      if readable?(object.key, phase) do
        extra =
          if phase == "agents" do
            [_, agent] = Regex.run(~r{^ctl/agents/([^/]+)\.json$}, object.key)
            [Keys.agent_state(agent)]
          else
            []
          end

        size =
          (object[:size] || budget.max_object_bytes) + length(extra) * budget.max_object_bytes

        if keys != [] and bytes + size > budget.remaining_bytes do
          {:halt, {keys, bytes}}
        else
          {:cont, {[object.key | extra] ++ keys, bytes + size}}
        end
      else
        {:cont, {keys, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp stats(original, budget, facts),
    do: %{
      entities: length(facts),
      objects: budget.objects - original.objects,
      wire_bytes: budget.wire_bytes - original.wire_bytes,
      inflated_bytes: budget.inflated_bytes - original.inflated_bytes
    }

  defp object_error(key, {:error, reason}), do: {:error, {:import_source_object, key, reason}}

  defp prepare_object(key, "agents", budget, _opts) do
    case Regex.run(~r{^ctl/agents/([^/]+)\.json$}, key) do
      [_, agent] -> prepare_agent(key, agent, budget)
      _ -> {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "runtimes", budget, opts) do
    cond do
      Regex.match?(~r{^agents/[^/]+/internal_runtime/sessions/[^/]+/state\.etf\.zst$}, key) ->
        prepare_object(key, "sessions", budget, opts)

      Regex.match?(~r{^agents/[^/]+/external_runtime/sessions/[^/]+\.json$}, key) ->
        prepare_object(key, "external", budget, opts)

      Regex.match?(~r{^agents/[^/]+/session_birth/[0-9a-f]+\.json$}, key) ->
        prepare_object(key, "births", budget, opts)

      Regex.match?(~r{^agents/[^/]+/state\.etf\.zst$}, key) ->
        prepare_object(key, "roots", budget, opts)

      true ->
        {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "sessions", budget, _opts) do
    case Regex.run(~r{^agents/([^/]+)/internal_runtime/sessions/[^/]+/state\.etf\.zst$}, key) do
      [_, agent] -> prepare_session(key, agent, budget)
      _ -> {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "external", budget, _opts) do
    case Regex.run(~r{^agents/([^/]+)/external_runtime/sessions/([^/]+)\.json$}, key) do
      [_, agent, session] ->
        with {:ok, %{value: record}, budget} <- PGAuthorityImport.read_json(key, budget),
             true <-
               (record["agent_id"] == agent and record["session_id"] == session) ||
                 {:error, :source_scope_mismatch} do
          {:ok,
           %{
             key: key,
             kind: :birth,
             agent: agent,
             session: session,
             side: :retired,
             format: :external
           }, budget}
        end

      _ ->
        {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "births", budget, opts) do
    case Regex.run(~r{^agents/([^/]+)/session_birth/([0-9a-f]+)\.json$}, key) do
      [_, agent, hash] -> prepare_birth(key, agent, hash, budget, opts)
      _ -> {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "capabilities", budget, _opts) do
    case Regex.run(~r{^ctl/capability_requests/([^/]+)/([^/]+)\.json$}, key) do
      [_, group, request] ->
        with {:ok, %{value: record}, budget} <- PGAuthorityImport.read_json(key, budget),
             true <-
               (record["group_id"] == group and record["request_id"] == request) ||
                 {:error, :source_scope_mismatch} do
          record = CapabilityRequests.ensure_request_deadline(record)
          {:ok, %{key: key, kind: :capability, record: record, format: :json}, budget}
        end

      _ ->
        {:ok, nil, budget}
    end
  end

  defp prepare_object(key, "roots", budget, opts) do
    case Regex.run(~r{^agents/([^/]+)/state\.etf\.zst$}, key) do
      [_, agent] ->
        if Keyword.get(opts, :inventory, false) do
          with {:ok, _source, budget} <- PGAuthorityImport.read_snapshot(key, budget),
               do: {:ok, %{key: key, kind: :root_source, format: 2}, budget}
        else
          case AgentPGStore.read_config(agent) do
            {:ok, _} -> {:ok, %{key: key, kind: :root_source, format: 2}, budget}
            {:error, :not_found} -> {:error, :root_without_complete_configuration}
            error -> error
          end
        end

      _ ->
        {:ok, nil, budget}
    end
  end

  defp prepare_agent(key, agent, budget) do
    with {:ok, %{value: record}, budget} <- PGAuthorityImport.read_json(key, budget),
         true <- record["agent_id"] == agent || {:error, :source_scope_mismatch},
         true <-
           Enum.all?(~w(tenant_id group_id role), &is_binary(record[&1])) ||
             {:error, :incomplete_agent_configuration},
         {:ok, %{value: source}, budget} <- read_agent_root(agent, budget),
         {:ok, root, budget} <- agent_root(agent, source, budget) do
      {:ok, Map.merge(root, %{key: key, agent: agent, record: record, kind: :agent, format: 2}),
       budget}
    end
  end

  defp read_agent_root(agent, budget) do
    key = Keys.agent_state(agent)

    case PGAuthorityImport.read_snapshot(key, budget) do
      {:error, :not_found} -> {:error, {:missing_agent_root, key}}
      result -> result
    end
  end

  defp agent_root(
         _agent,
         %{format: 2, sm: sm, head: %Head{} = head, payload: %{mode: :whole, state: state}},
         budget
       ) do
    if is_map(state) and Map.get(state, :sessions) not in [nil, %{}, []],
      do: {:error, :legacy_whole_sessions_require_owner_conversion},
      else: {:ok, %{sm: sm, head: head, state: state}, budget}
  end

  defp agent_root(agent, %{format: 2, payload: %{mode: :split, refs: refs}}, budget) do
    # The old migration skips missing refs and overwrites workspace state. Its
    # ordinary writer must settle this layout before this lossless handoff.
    case refs[:vfs] do
      nil ->
        {:error, {:unresolved_legacy_split, Keys.agent_state(agent), :missing_vfs_ref}}

      ref ->
        key = "agents/#{agent}/vfs/#{ref}.etf.zst"

        case PGAuthorityImport.read_snapshot(key, budget) do
          {:ok, _source, _budget} ->
            {:error, {:unresolved_legacy_split, Keys.agent_state(agent), key}}

          {:error, :not_found} ->
            {:error, {:missing_split_reference, key}}

          error ->
            error
        end
    end
  end

  defp agent_root(_agent, _source, _budget), do: {:error, :unsupported_agent_source_format}

  defp prepare_session(key, agent, budget) do
    with {:ok, %{value: bytes}, budget} <- PGAuthorityImport.read_etf(key, budget),
         {:ok, state} <-
           PGAuthorityImport.with_decode(budget, fn -> InternalSession.load(bytes) end),
         session = InternalSession.session_id(state),
         true <-
           (InternalSession.agent_id(state) == agent and
              Keys.agent_internal_runtime_session(agent, session) == key) ||
             {:error, :source_scope_mismatch},
         {:ok, refs, budget} <- prepare_archives(state, budget),
         {:ok, frozen} <- SessionPG.prepare_import(agent, state, refs) do
      {:ok,
       %{
         key: key,
         kind: :session,
         frozen: frozen,
         format: InternalSession.storage_format(state)
       }, budget}
    end
  end

  defp prepare_archives(state, budget) do
    with {:ok, spans} <- InternalSessionArchiveReader.committed_spans(state) do
      Enum.reduce_while(spans, {:ok, %{}, budget}, fn span, {:ok, refs, budget} ->
        case prepare_span(state, span, budget) do
          {:ok, rows, budget} ->
            {:cont, {:ok, Map.merge(refs, Map.new(rows, &{&1["first_seq"], &1})), budget}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp prepare_span(state, %{offset: offset, length: length} = span, budget) do
    key =
      span[:object_key] ||
        Keys.agent_internal_runtime_session_archive(
          InternalSession.agent_id(state),
          InternalSession.session_id(state)
        )

    row =
      archive_row(span.first, span.last, span.messages, length, key, span[:source_session])
      |> Map.merge(%{"encoding" => "jsonl", "byte_offset" => offset, "byte_length" => length})

    {:ok, [row], budget}
  end

  defp prepare_span(state, span, budget) do
    key =
      span[:object_key] ||
        Keys.agent_internal_runtime_session_segment(
          InternalSession.agent_id(state),
          InternalSession.session_id(state),
          span.first
        )

    cond do
      span[:missing_locator] ->
        {:error, {:missing_archive_locator, span.first}}

      span[:encoding] not in [nil, "etf.zst"] ->
        {:error, {:unsupported_archive_encoding, key}}

      true ->
        {:ok,
         [
           archive_row(
             span.first,
             span.last,
             span.messages,
             span[:uncomp] || 0,
             key,
             span[:source_session]
           )
         ], budget}
    end
  end

  defp archive_row(first, last, messages, bytes, key, source),
    do: %{
      "first_seq" => first,
      "last_seq" => last,
      "message_count" => messages,
      "record_count" => last - first + 1,
      "uncompressed_bytes" => bytes,
      "object_key" => key,
      "encoding" => "etf.zst",
      "source_session" => source,
      "byte_offset" => nil,
      "byte_length" => nil
    }

  defp prepare_birth(key, agent, hash, budget, opts) do
    with {:ok, %{value: marker}, budget} <- PGAuthorityImport.read_json(key, budget),
         {:ok, side} <- birth_side(marker),
         {:ok, session, present, budget} <- resolve_birth(key, agent, hash, budget, opts),
         true <-
           Keys.agent_session_birth(agent, session) == key || {:error, :source_scope_mismatch},
         true <- present in [nil, Atom.to_string(side)] || {:error, :conflicting_session_birth} do
      {:ok,
       %{
         key: key,
         kind: if(present, do: :birth_source, else: :birth),
         agent: agent,
         session: session,
         side: side,
         format: :birth
       }, budget}
    end
  end

  defp birth_side(%{"runtime" => "internal"}), do: {:ok, :internal}
  defp birth_side(%{"runtime" => "external"}), do: {:ok, :retired}
  defp birth_side(_), do: {:error, :invalid_birth_marker}

  defp resolve_birth(key, agent, hash, budget, opts) do
    case :ets.lookup(Keyword.fetch!(opts, :birth_index), key) do
      [{^key, session, side}] ->
        {:ok, session, side, budget}

      [] ->
        case Keyword.get(opts, :known_sessions, %{})[key] do
          session when is_binary(session) ->
            {:ok, session, nil, budget}

          _ ->
            if Keyword.get(opts, :inventory, false),
              do: inventory_birth(key, agent, hash, budget),
              else: {:error, {:unresolved_birth_identity, key}}
        end
    end
  end

  # Inventory has no committed owner rows between calls. Keep its original
  # source-codec check; the release import resolves identities from its owners.
  defp inventory_birth(key, agent, hash, budget) do
    source_key = "agents/#{agent}/internal_runtime/sessions/#{hash}/state.etf.zst"

    with {:ok, %{value: bytes}, budget} <- PGAuthorityImport.read_etf(source_key, budget),
         {:ok, state} <-
           PGAuthorityImport.with_decode(budget, fn -> InternalSession.load(bytes) end),
         true <- InternalSession.agent_id(state) == agent || {:error, :source_scope_mismatch} do
      {:ok, InternalSession.session_id(state), nil, budget}
    else
      {:error, :not_found} -> {:error, {:unresolved_birth_identity, key}}
      error -> error
    end
  end

  defp import!(facts) do
    facts
    |> Enum.chunk_by(& &1.kind)
    |> Enum.each(fn
      [%{kind: :agent} | _] = agents ->
        agents |> Enum.chunk_every(128) |> Enum.each(&import_agents!/1)

      batch ->
        Enum.each(batch, fn fact -> import_object!(fact, fn -> import_fact!(fact) end) end)
    end)

    :ok
  end

  defp import_agents!([fact]), do: import_object!(fact, fn -> import_fact!(fact) end)

  defp import_agents!([first | _] = facts) do
    import_object!(first, fn ->
      PGAuthorityImport.with_import_batch!(
        fn ->
          roots = Enum.map(facts, &{&1.agent, &1.head, &1.sm, &1.state, &1.record})
          AgentPGStore.import_roots!(roots)
        end,
        fn error ->
          Enum.each(facts, fn fact -> import_object!(fact, fn -> import_fact!(fact) end) end)
          import_object!(first, fn -> raise error end)
        end,
        [ArgumentError, KeyError]
      )
    end)
  end

  defp import_fact!(fact) do
    case fact.kind do
      :agent -> AgentPGStore.import_root!(fact.agent, fact.head, fact.sm, fact.state, fact.record)
      :session -> SessionPG.import_session!(fact.frozen)
      :birth -> SessionPG.import_birth!(fact.agent, fact.session, fact.side)
      :capability -> CapabilityPG.import_record!(fact.record, fact.delivery)
      _ -> :ok
    end
  end

  defp import_object!(fact, apply) do
    apply.()
  rescue
    error in Postgrex.Error ->
      if error.postgres &&
           error.postgres[:code] not in [:admin_shutdown, :crash_shutdown, :cannot_connect_now],
         do: Repo.rollback({:import_object_failed, fact.key, error.postgres[:code]}),
         else: reraise(error, __STACKTRACE__)

    _ in [ArgumentError, KeyError] ->
      Repo.rollback({:invalid_source_object, fact.key})
  end
end
