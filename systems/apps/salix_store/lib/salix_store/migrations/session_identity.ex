defmodule SalixStore.Migrations.SessionIdentity do
  @moduledoc """
  One-shot Salix session public-ID migration.

  The migration inventories structured Salix session references, reserves every
  agent-scoped target, moves session-derived keys, and rewrites record fields.
  It is release-only and assumes serving writers are stopped.
  """

  alias SalixStore.{Codec, Crypto, Ids, Keys, S3, SessionIdMigration, Timers}

  @legacy_external_sessions_prefix "ctl/external_runtime_sessions/"

  @structured_prefixes [
    "agents/",
    "ctl/agents/",
    "ctl/group_conversations/",
    "ctl/group_conversation_delivery_wakeups/",
    "ctl/timers/",
    "ctl/schedules/",
    "ctl/schedule_runs/",
    "ctl/runtime_capabilities/",
    "ctl/capability_requests/",
    "ctl/oauth/auth_states/",
    "ctl/im_slack_router_status_windows/",
    "ctl/meeting_agents/",
    "meet/"
  ]
  @inventory_prefixes [@legacy_external_sessions_prefix | @structured_prefixes]
  @max_concurrency 24
  @external_runtime_binding_fields ~w(kind provider device_id connector_id connector_run_id runtime_id device_runtime_id process_name command working_dir model model_provider reasoning_effort)

  def run(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    try do
      with {:ok, maps} <- reserve_maps(Keyword.get(opts, :additional_refs, [])),
           {:ok, structured} <- list_structured_objects(),
           {:ok, stats} <- rewrite_objects(structured, maps),
           {:ok, legacy_external_stats} <- cleanup_legacy_external_sessions(maps),
           :ok <- verify(maps),
           :ok <- verify_legacy_external_sessions_removed(),
           :ok <- SessionIdMigration.mark_phase_complete(:s3, maps) do
        stats = Map.put(stats, :legacy_external_sessions, legacy_external_stats)
        CommaLog.log("migrate_salix_session_identity", stats)
        {:ok, stats}
      else
        {:error, reason} -> abort(reason)
      end
    catch
      {:session_identity_abort, reason} ->
        {:error, {:session_identity_migration_failed, reason}}
    end
  end

  @doc """
  Inventory every current and pre-split session owner/reference and durably
  reserve its canonical target before any owner object moves.
  """
  def reserve_maps(additional_refs \\ []) do
    with {:ok, inventory} <- list_inventory_objects(),
         {:ok, sources} <- collect_sources(inventory),
         {:ok, sources} <- merge_additional_refs(sources, additional_refs) do
      reserve_all(sources)
    end
  end

  defp merge_additional_refs(sources, refs) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, sources}, fn
      {agent_id, session_id}, {:ok, acc}
      when is_binary(agent_id) and is_binary(session_id) ->
        session_id = String.trim(session_id)

        if Ids.valid_agent_id?(agent_id) and session_id != "" do
          {:cont,
           {:ok, Map.update(acc, agent_id, MapSet.new([session_id]), &MapSet.put(&1, session_id))}}
        else
          {:halt, {:error, {:invalid_additional_session_reference, agent_id, session_id}}}
        end

      ref, _acc ->
        {:halt, {:error, {:invalid_additional_session_reference, ref}}}
    end)
  end

  defp merge_additional_refs(_sources, refs),
    do: {:error, {:invalid_additional_session_references, refs}}

  defp collect_sources(objects) do
    objects
    |> parallel_map(fn %{key: key} ->
      with {:ok, value} <- read_structured(key),
           {:ok, refs} <-
             SessionIdMigration.collect_refs(value, path_agent_id(key),
               context: key,
               missing_owner: :error
             ) do
        {:ok, refs}
      end
    end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, refs}, {:ok, acc} ->
        next =
          Enum.reduce(refs, acc, fn {agent_id, session_id}, grouped ->
            Map.update(grouped, agent_id, MapSet.new([session_id]), &MapSet.put(&1, session_id))
          end)

        {:cont, {:ok, next}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp reserve_all(sources) do
    sources
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {agent_id, source_ids}, :ok ->
      case SessionIdMigration.reserve(agent_id, MapSet.to_list(source_ids)) do
        {:ok, _map} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:reserve_session_map_failed, agent_id, reason}}}
      end
    end)
    |> case do
      :ok -> SessionIdMigration.read_all()
      {:error, _} = error -> error
    end
  end

  defp rewrite_objects(objects, maps) do
    objects
    |> parallel_map(fn %{key: key} -> rewrite_object(key, maps) end)
    |> Enum.reduce_while({:ok, %{migrated: 0, unchanged: 0}}, fn
      {:ok, status}, {:ok, stats} ->
        {:cont, {:ok, Map.update!(stats, status, &(&1 + 1))}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp rewrite_object(key, maps) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, value} <- decode_structured(key, body),
         {:ok, rewritten} <-
           SessionIdMigration.rewrite_refs(value, maps, path_agent_id(key),
             context: key,
             missing_owner: :error
           ),
         {:ok, target_key} <- target_key(key, rewritten, maps),
         rewritten_body <- encode_structured(key, rewritten, body) do
      persist_rewrite(key, target_key, body, rewritten_body, etag)
    else
      {:error, :not_found} -> {:ok, :unchanged}
      {:error, reason} -> {:error, {:rewrite_session_object_failed, key, reason}}
    end
  end

  defp persist_rewrite(key, key, body, body, _etag), do: {:ok, :unchanged}

  defp persist_rewrite(key, key, _body, rewritten_body, etag) do
    case S3.put(key, rewritten_body, if_match: etag) do
      {:ok, _} -> {:ok, :migrated}
      {:error, {:ambiguous, _}} -> verify_same_body(key, rewritten_body, :migrated)
      {:error, reason} -> {:error, {:rewrite_failed, reason}}
    end
  end

  defp persist_rewrite(source, target, _body, rewritten_body, etag) do
    with :ok <- put_target(target, rewritten_body),
         :ok <- delete_source(source, target, etag) do
      {:ok, :migrated}
    end
  end

  defp put_target(key, body) do
    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> verify_same_body(key, body, :ok)
      {:error, {:ambiguous, _}} -> verify_same_body(key, body, :ok)
      {:error, reason} -> {:error, {:target_write_failed, key, reason}}
    end
  end

  defp verify_same_body(key, expected, success) do
    case S3.get(key) do
      {:ok, %{body: ^expected}} -> success
      {:ok, _} -> {:error, {:target_collision, key}}
      {:error, reason} -> {:error, {:target_verify_failed, key, reason}}
    end
  end

  defp delete_source(source, target, etag) do
    case S3.delete(source, if_match: etag) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, {:ambiguous, _}} -> verify_source_deleted(source, target)
      {:error, reason} -> {:error, {:source_delete_failed, source, target, reason}}
    end
  end

  defp cleanup_legacy_external_sessions(maps) do
    with {:ok, objects} <- S3.list_all(@legacy_external_sessions_prefix) do
      objects
      |> Enum.filter(&String.ends_with?(&1.key, ".json"))
      |> parallel_map(&cleanup_legacy_external_session(&1.key, maps))
      |> Enum.reduce_while({:ok, %{migrated: 0, unchanged: 0}}, fn
        {:ok, status}, {:ok, stats} ->
          {:cont, {:ok, Map.update!(stats, status, &(&1 + 1))}}

        {:error, reason}, _acc ->
          {:halt, {:error, reason}}
      end)
    end
  end

  defp cleanup_legacy_external_session(key, maps) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        cleanup_loaded_legacy_external_session(key, body, etag, maps)

      {:error, :not_found} ->
        {:ok, :unchanged}

      {:error, reason} ->
        {:error, {:legacy_external_session_cleanup_failed, key, reason}}
    end
  end

  defp cleanup_loaded_legacy_external_session(key, body, etag, maps) do
    with {:ok, record} when is_map(record) <- Jason.decode(body),
         agent_id when is_binary(agent_id) <- map_field(record, "agent_id"),
         true <- Ids.valid_agent_id?(agent_id),
         source_session_id when is_binary(source_session_id) <- map_field(record, "session_id"),
         {:ok, target_session_id} <- mapped_session_id(maps, agent_id, source_session_id),
         {:ok, expected} <-
           SessionIdMigration.rewrite_refs(record, maps, agent_id,
             context: key,
             missing_owner: :error
           ),
         target_key = Keys.agent_external_runtime_session(agent_id, target_session_id),
         {:ok, target_record} <- read_json_record(target_key),
         :ok <- verify_legacy_external_record(expected, target_record),
         :ok <- delete_source(key, target_key, etag) do
      {:ok, :migrated}
    else
      false -> {:error, {:invalid_legacy_external_agent, key}}
      {:error, reason} -> {:error, {:legacy_external_session_cleanup_failed, key, reason}}
      _ -> {:error, {:invalid_legacy_external_session, key}}
    end
  end

  defp mapped_session_id(maps, agent_id, source_session_id) do
    case get_in(maps, [agent_id, source_session_id]) do
      target when is_binary(target) ->
        {:ok, target}

      nil ->
        if Ids.valid_session_id?(source_session_id),
          do: {:ok, source_session_id},
          else: {:error, {:session_mapping_missing, agent_id, source_session_id}}
    end
  end

  defp read_json_record(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_json_record}
    end
  end

  defp verify_legacy_external_record(expected, target) do
    expected_dedupe = expected |> Map.get("input_dedupe", []) |> normalized_strings()
    target_dedupe = target |> Map.get("input_dedupe", []) |> normalized_strings()
    binding = get_in(target, ["runtime", "binding"])
    payload = get_in(target, ["runtime", "payload"])

    binding_matches? =
      is_map(binding) and
        expected
        |> Map.take(@external_runtime_binding_fields)
        |> Enum.all?(fn {field, value} -> Map.get(binding, field) == value end)

    payload_matches? =
      is_map(payload) and
        case expected["codex_thread_id"] do
          thread_id when is_binary(thread_id) and thread_id != "" ->
            payload["thread_id"] == thread_id

          _missing ->
            true
        end

    cond do
      target["agent_id"] != expected["agent_id"] or
          target["session_id"] != expected["session_id"] ->
        {:error, :legacy_external_identity_mismatch}

      not binding_matches? or not payload_matches? ->
        {:error, :legacy_external_runtime_mismatch}

      not is_list(target["input_message_queue"]) or not is_integer(target["message_count"]) ->
        {:error, :invalid_external_session_state}

      Enum.any?(
        ~w(messages events next_message_id last_accepted_message_id codex_thread_id),
        &Map.has_key?(target, &1)
      ) ->
        {:error, :legacy_external_fields_remain}

      not MapSet.subset?(expected_dedupe, target_dedupe) ->
        {:error, :legacy_external_dedupe_mismatch}

      true ->
        :ok
    end
  end

  defp normalized_strings(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp verify_source_deleted(source, target) do
    case S3.get(source) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, {:ambiguous_source_delete, source, target}}
      {:error, reason} -> {:error, {:source_delete_verify_failed, source, target, reason}}
    end
  end

  defp verify_legacy_external_sessions_removed do
    with {:ok, objects} <- S3.list_all(@legacy_external_sessions_prefix) do
      case Enum.find(objects, &String.ends_with?(&1.key, ".json")) do
        nil -> :ok
        %{key: key} -> {:error, {:legacy_external_session_remains, key}}
      end
    end
  end

  defp target_key("agents/" <> rest = key, _rewritten, maps) do
    case String.split(rest, "/") do
      [agent_id, "internal_runtime", "sessions", hash, "state.etf.zst"] ->
        session_hash_key(key, agent_id, hash, maps)

      [agent_id, "external_runtime", "sessions", source_session_id, "segments", file] ->
        with {:ok, target_session_id} <-
               external_session_target_id(agent_id, source_session_id, maps) do
          {:ok,
           Keys.agent_external_runtime_session_segments_prefix(agent_id, target_session_id) <>
             file}
        end

      [agent_id, "external_runtime", "sessions", file] ->
        session_id = String.trim_trailing(file, ".json")

        if String.ends_with?(file, ".json") and Ids.valid_session_id?(session_id),
          do: {:ok, key},
          else: external_session_file_key(key, agent_id, file, maps)

      [agent_id, "trajectory_evals", file] ->
        session_hash_file_key(key, agent_id, file, ".json", maps)

      [agent_id, "session_work_index", runtime_kind, file] ->
        session_hash_file_key(key, agent_id, file, ".json", maps, [runtime_kind])

      _ ->
        {:ok, key}
    end
  end

  defp target_key("ctl/timers/" <> _ = key, rewritten, _maps) when is_map(rewritten) do
    with agent_id when is_binary(agent_id) <- map_field(rewritten, "agent_id"),
         session_id when is_binary(session_id) <- map_field(rewritten, "session_id"),
         timer_id when is_binary(timer_id) <- map_field(rewritten, "timer_id"),
         deadline_ms when is_integer(deadline_ms) <- map_field(rewritten, "deadline_ms"),
         true <- Ids.valid_agent_id?(agent_id),
         true <- Ids.valid_session_id?(session_id) do
      {:ok, Keys.timer(agent_id, session_id, timer_id, Timers.minute_bucket(deadline_ms))}
    else
      _ -> {:error, {:invalid_timer_record, key}}
    end
  end

  defp target_key(key, _rewritten, _maps), do: {:ok, key}

  defp session_hash_key(key, agent_id, hash, maps) do
    with {:ok, target_hash} <- target_session_hash(agent_id, hash, maps) do
      {:ok, "agents/#{agent_id}/internal_runtime/sessions/#{target_hash}/state.etf.zst"}
    else
      {:error, reason} -> {:error, {reason, key}}
    end
  end

  defp session_hash_file_key(key, agent_id, file, suffix, maps, middle \\ []) do
    if String.ends_with?(file, suffix) do
      source_hash = String.trim_trailing(file, suffix)

      with {:ok, target_hash} <- target_session_hash(agent_id, source_hash, maps) do
        prefix = ["agents", agent_id] ++ key_session_directory(key, middle)
        {:ok, Enum.join(prefix ++ [target_hash <> suffix], "/")}
      end
    else
      {:ok, key}
    end
  end

  defp external_session_file_key(key, agent_id, file, maps) do
    if String.ends_with?(file, ".json") do
      source_session_id = String.trim_trailing(file, ".json")

      with {:ok, target_id} <- external_session_target_id(agent_id, source_session_id, maps) do
        {:ok, Keys.agent_external_runtime_session(agent_id, target_id)}
      end
    else
      {:ok, key}
    end
  end

  defp external_session_target_id(agent_id, source_session_id, maps) do
    case get_in(maps, [agent_id, source_session_id]) do
      target_id when is_binary(target_id) ->
        {:ok, target_id}

      nil when is_binary(source_session_id) ->
        if Ids.valid_session_id?(source_session_id),
          do: {:ok, source_session_id},
          else: target_session_id(agent_id, source_session_id, maps)
    end
  end

  defp key_session_directory(key, middle) do
    cond do
      String.contains?(key, "/external_runtime/sessions/") -> ["external_runtime", "sessions"]
      String.contains?(key, "/trajectory_evals/") -> ["trajectory_evals"]
      String.contains?(key, "/session_work_index/") -> ["session_work_index"] ++ middle
    end
  end

  defp target_session_hash(agent_id, source_hash, maps) do
    with {:ok, target_id} <- target_session_id(agent_id, source_hash, maps) do
      {:ok, Crypto.hex(target_id)}
    end
  end

  defp target_session_id(agent_id, source_hash, maps) do
    targets =
      maps
      |> Map.get(agent_id, %{})
      |> Enum.filter(fn {source_id, target_id} ->
        Crypto.hex(source_id) == source_hash or Crypto.hex(target_id) == source_hash
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    case targets do
      [target_id] -> {:ok, target_id}
      [] -> {:error, {:session_hash_mapping_missing, agent_id, source_hash}}
      _ -> {:error, {:session_hash_mapping_ambiguous, agent_id, source_hash}}
    end
  end

  defp path_agent_id("agents/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [agent_id, _] -> if(Ids.valid_agent_id?(agent_id), do: agent_id)
      _ -> nil
    end
  end

  defp path_agent_id(_key), do: nil

  defp structured_object?(%{key: key}) do
    Enum.any?(@structured_prefixes, &String.starts_with?(key, &1)) and
      not String.starts_with?(key, SessionIdMigration.maps_prefix()) and
      not legacy_external_event_object?(key) and
      (String.ends_with?(key, ".json") or String.ends_with?(key, ".jsonl") or
         String.ends_with?(key, ".etf.zst"))
  end

  defp legacy_external_event_object?(key) do
    String.contains?(key, "/external_runtime/sessions/") and
      String.contains?(key, "/events/")
  end

  defp read_structured(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> decode_structured(key, body)
      {:error, _} = error -> error
    end
  end

  defp decode_structured(key, body) do
    cond do
      String.ends_with?(key, ".json") -> Jason.decode(body)
      String.ends_with?(key, ".jsonl") -> decode_jsonl(body)
      String.ends_with?(key, ".etf.zst") -> decode_snapshot(body, key)
    end
  end

  defp decode_jsonl(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp decode_snapshot(body, key) do
    try do
      {:ok, Codec.decode_snapshot(body)}
    rescue
      error -> {:error, {:snapshot_decode_failed, key, Exception.message(error)}}
    end
  end

  defp encode_structured(key, value, original_body) do
    cond do
      String.ends_with?(key, ".json") -> Jason.encode!(value)
      String.ends_with?(key, ".jsonl") -> encode_jsonl(value, original_body)
      String.ends_with?(key, ".etf.zst") -> Codec.encode_snapshot(value)
    end
  end

  defp encode_jsonl(values, original_body) do
    body = Enum.map_join(values, "\n", &Jason.encode!/1)
    if String.ends_with?(original_body, "\n"), do: body <> "\n", else: body
  end

  defp verify(maps) do
    with {:ok, structured} <- list_structured_objects(),
         results <-
           parallel_map(structured, fn %{key: key} -> verify_object(key, maps) end),
         nil <- Enum.find(results, &match?({:error, _}, &1)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, key} -> {:error, {reason, key}}
      result -> result
    end
  end

  defp verify_object(key, maps) do
    with {:ok, value} <- read_structured(key),
         {:ok, refs} <-
           SessionIdMigration.collect_refs(value, path_agent_id(key),
             context: key,
             missing_owner: :error
           ),
         true <-
           Enum.all?(refs, fn {agent_id, session_id} ->
             Ids.valid_session_id?(session_id) and
               get_in(maps, [agent_id, session_id]) in [nil, session_id]
           end),
         {:ok, ^key} <- target_key(key, value, maps) do
      :ok
    else
      false -> {:error, {:legacy_session_reference_remains, key}}
      {:ok, target} -> {:error, {:legacy_session_key_remains, key, target}}
      {:error, reason} -> {:error, {:session_verification_failed, key, reason}}
    end
  end

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) ||
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end

  defp parallel_map(items, fun) do
    items
    |> Task.async_stream(fun,
      max_concurrency: @max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:migration_worker_exit, reason}}
    end)
  end

  defp list_structured_objects do
    @structured_prefixes
    |> parallel_map(&S3.list_all/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, objects}, {:ok, acc} -> {:cont, {:ok, objects ++ acc}}
      {:error, reason}, _acc -> {:halt, {:error, {:session_inventory_list_failed, reason}}}
    end)
    |> case do
      {:ok, objects} ->
        {:ok,
         objects
         |> Enum.uniq_by(& &1.key)
         |> Enum.filter(&structured_object?/1)}

      {:error, _} = error ->
        error
    end
  end

  defp list_inventory_objects do
    @inventory_prefixes
    |> parallel_map(&S3.list_all/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, objects}, {:ok, acc} -> {:cont, {:ok, objects ++ acc}}
      {:error, reason}, _acc -> {:halt, {:error, {:session_inventory_list_failed, reason}}}
    end)
    |> case do
      {:ok, objects} ->
        {:ok,
         objects
         |> Enum.uniq_by(& &1.key)
         |> Enum.filter(&inventory_object?/1)}

      {:error, _} = error ->
        error
    end
  end

  defp inventory_object?(%{key: key}) do
    (structured_object?(%{key: key}) or String.starts_with?(key, @legacy_external_sessions_prefix)) and
      (String.ends_with?(key, ".json") or String.ends_with?(key, ".jsonl") or
         String.ends_with?(key, ".etf.zst"))
  end

  defp abort(reason), do: throw({:session_identity_abort, reason})
end
