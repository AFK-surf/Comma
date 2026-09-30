defmodule SalixStore.SessionIdMigration do
  @moduledoc """
  Durable agent-scoped session identity map used only by release migrations.

  Runtime paths validate canonical session IDs directly. Migration writers reserve
  every `{agent_id, legacy_session_id}` target before moving any owner record, so
  retries and interrupted releases always converge on the first target.
  """

  alias SalixStore.{Crypto, Ids, S3}

  @maps_prefix "ctl/migrations/session_identity_v1/maps/"
  @completion_prefix "ctl/migrations/session_identity_v1/completions/"
  @retries 8
  @phases [:s3, :bft, :analytics]
  @session_fields ~w(
    session_id
    default_session_id
    router_session_id
    target_session_id
    source_session_id
    origin_session_id
    fork_session_id
    meeting_session_id
    last_session_id
    last_surface_session_id
  )
  @agent_fields ~w(
    agent_id
    participant_agent_id
    target_agent_id
    source_agent_id
    origin_agent_id
    created_by_agent_id
    router_agent_id
    meeting_agent_id
    runtime_agent_id
    salix_agent_id
  )
  @nested_record_fields ~w(
    participants
    targets
    events
    input_queue
    messages
    state
    delivery
    deliveries
  )
  @nested_record_map_fields ~w(async_tool_calls)
  @nested_session_fields %{
    "participant_payload" => ~w(session_id),
    "payload" => @session_fields,
    "metadata" => ~w(source_session_id origin_session_id),
    "source_refs" => ~w(source_session_id origin_session_id target_session_id)
  }

  def maps_prefix, do: @maps_prefix

  def map_key(agent_id),
    do: @maps_prefix <> Crypto.hex(agent_id) <> ".json"

  @spec reserve(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def reserve(agent_id, source_ids) when is_binary(agent_id) and is_list(source_ids) do
    with true <- Ids.valid_agent_id?(agent_id),
         {:ok, sources} <- normalize_sources(source_ids) do
      reserve(agent_id, sources, @retries)
    else
      false -> {:error, :invalid_agent_id}
      {:error, _} = error -> error
    end
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(agent_id) when is_binary(agent_id) do
    with true <- Ids.valid_agent_id?(agent_id) do
      case S3.get(map_key(agent_id)) do
        {:ok, %{body: body}} -> decode(body, agent_id)
        {:error, _} = error -> error
      end
    else
      false -> {:error, :invalid_agent_id}
    end
  end

  @spec read_all() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def read_all do
    with {:ok, objects} <- S3.list_all(@maps_prefix) do
      objects
      |> Enum.filter(&String.ends_with?(&1.key, ".json"))
      |> Enum.reduce_while({:ok, %{}}, fn %{key: key}, {:ok, acc} ->
        case S3.get(key) do
          {:ok, %{body: body}} ->
            with {:ok, %{agent_id: agent_id, session_ids: session_ids}} <- decode(body),
                 true <- key == map_key(agent_id),
                 false <- Map.has_key?(acc, agent_id) do
              {:cont, {:ok, Map.put(acc, agent_id, session_ids)}}
            else
              false -> {:halt, {:error, {:invalid_session_identity_map_owner, key}}}
              {:error, reason} -> {:halt, {:error, {reason, key}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:session_identity_map_read_failed, key, reason}}}
        end
      end)
    end
  end

  @spec phase_complete?(atom(), map()) :: {:ok, boolean()} | {:error, term()}
  def phase_complete?(phase, maps) when phase in @phases and is_map(maps) do
    with {:ok, maps} <- normalize_all(maps) do
      case S3.get(completion_key(phase)) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"identity_fingerprint" => stored}} ->
              {:ok, stored == fingerprint(maps)}

            _ ->
              {:error, :invalid_session_identity_completion}
          end

        {:error, :not_found} ->
          {:ok, false}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec mark_phase_complete(atom(), map()) :: :ok | {:error, term()}
  def mark_phase_complete(phase, maps) when phase in @phases and is_map(maps) do
    with {:ok, maps} <- normalize_all(maps) do
      body =
        Jason.encode!(%{
          "version" => 1,
          "phase" => Atom.to_string(phase),
          "identity_fingerprint" => fingerprint(maps),
          "completed_at" => System.system_time(:millisecond)
        })

      case S3.put(completion_key(phase), body, if_none_match: "*") do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> verify_completion(phase, maps)
        {:error, {:ambiguous, _}} -> verify_completion(phase, maps)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec normalize_all(map()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def normalize_all(maps) when is_map(maps) do
    maps
    |> Enum.reduce_while({:ok, %{}}, fn {agent_id, session_ids}, {:ok, acc} ->
      with true <- is_binary(agent_id) and Ids.valid_agent_id?(agent_id),
           {:ok, session_ids} <- normalize_session_ids(session_ids),
           false <- Map.has_key?(acc, agent_id) do
        {:cont, {:ok, Map.put(acc, agent_id, session_ids)}}
      else
        false -> {:halt, {:error, :invalid_session_identity_maps}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_all(_maps), do: {:error, :invalid_session_identity_maps}

  @doc "Collect structured agent-session references from a migration-owned value."
  @spec collect_refs(term(), String.t() | nil, keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def collect_refs(value, inherited_agent_id \\ nil, opts \\ []) do
    collect_refs_value(value, inherited_agent_id, opts)
  end

  @doc "Rewrite structured session references with a previously reserved map."
  @spec rewrite_refs(term(), map(), String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def rewrite_refs(value, maps, inherited_agent_id \\ nil, opts \\ []) when is_map(maps) do
    rewrite_refs_value(value, maps, inherited_agent_id, opts)
  end

  defp reserve(_agent_id, _sources, 0), do: {:error, :session_identity_reservation_exhausted}

  defp reserve(agent_id, sources, attempts) do
    key = map_key(agent_id)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, %{session_ids: existing}} <- decode(body, agent_id),
             {:ok, merged} <- add_sources(existing, sources),
             encoded <- encode(agent_id, merged, body) do
          if merged == existing do
            {:ok, merged}
          else
            case S3.put(key, encoded, if_match: etag) do
              {:ok, _} -> {:ok, merged}
              {:error, :precondition_failed} -> reserve(agent_id, sources, attempts - 1)
              {:error, {:ambiguous, _}} -> reserve(agent_id, sources, attempts - 1)
              {:error, reason} -> {:error, reason}
            end
          end
        end

      {:error, :not_found} ->
        with {:ok, session_ids} <- add_sources(%{}, sources) do
          case S3.put(key, encode(agent_id, session_ids, nil), if_none_match: "*") do
            {:ok, _} -> {:ok, session_ids}
            {:error, :precondition_failed} -> reserve(agent_id, sources, attempts - 1)
            {:error, {:ambiguous, _}} -> reserve(agent_id, sources, attempts - 1)
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_sources(existing, sources) do
    canonical_sources = sources |> Enum.filter(&Ids.valid_session_id?/1) |> MapSet.new()
    existing_targets = existing |> Map.values() |> MapSet.new()
    used = MapSet.union(existing_targets, canonical_sources)

    sources
    |> Enum.reduce_while({:ok, existing, used}, fn source, {:ok, acc, used} ->
      case Map.fetch(acc, source) do
        {:ok, _target} ->
          {:cont, {:ok, acc, used}}

        :error ->
          if Ids.valid_session_id?(source) and MapSet.member?(existing_targets, source) do
            # A rerun inventories migrated targets as canonical source IDs. They
            # already identify the mapped session and must not create a second
            # source entry pointing at the same target.
            {:cont, {:ok, acc, used}}
          else
            target = if Ids.valid_session_id?(source), do: source, else: unique_target(used, 8)

            case target do
              {:error, _} = error -> {:halt, error}
              target -> {:cont, {:ok, Map.put(acc, source, target), MapSet.put(used, target)}}
            end
          end
      end
    end)
    |> case do
      {:ok, mappings, _used} -> normalize_session_ids(mappings)
      {:error, _} = error -> error
    end
  end

  defp unique_target(_used, 0), do: {:error, :session_identity_target_collision}

  defp unique_target(used, attempts) do
    target = Ids.new_session_id()

    if MapSet.member?(used, target),
      do: unique_target(used, attempts - 1),
      else: target
  end

  defp collect_refs_value(%MapSet{}, _inherited_agent_id, _opts), do: {:ok, []}

  defp collect_refs_value(%{__struct__: _} = value, inherited_agent_id, opts) do
    value
    |> Map.from_struct()
    |> collect_refs_value(inherited_agent_id, opts)
  end

  defp collect_refs_value(value, inherited_agent_id, opts) when is_map(value) do
    local_agent_id = local_agent_id(value, inherited_agent_id)

    with {:ok, direct} <- collect_direct_refs(value, local_agent_id, opts),
         {:ok, nested} <- collect_nested_refs(value, local_agent_id, opts) do
      {:ok, direct ++ nested}
    end
  end

  defp collect_refs_value(value, inherited_agent_id, opts) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, refs} ->
      case collect_refs_value(item, inherited_agent_id, opts) do
        {:ok, nested} -> {:cont, {:ok, nested ++ refs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_refs_value(value, inherited_agent_id, opts) when is_tuple(value) do
    value |> Tuple.to_list() |> collect_refs_value(inherited_agent_id, opts)
  end

  defp collect_refs_value(_value, _inherited_agent_id, _opts), do: {:ok, []}

  defp collect_direct_refs(value, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, []}, fn {field, field_value}, {:ok, refs} ->
      field_name = to_string(field)
      field_agent_id = session_agent_id(field_name, value, local_agent_id)

      case collect_session_field(field_name, field_value, field_agent_id, value, opts) do
        {:ok, direct} -> {:cont, {:ok, direct ++ refs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_nested_refs(value, local_agent_id, opts) do
    if Keyword.get(opts, :recursive, false) do
      collect_recursive_refs(value, local_agent_id, opts)
    else
      collect_known_nested_refs(value, local_agent_id, opts)
    end
  end

  defp collect_recursive_refs(value, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, []}, fn {_field, field_value}, {:ok, refs} ->
      case collect_refs_value(field_value, local_agent_id, opts) do
        {:ok, nested} -> {:cont, {:ok, nested ++ refs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_known_nested_refs(value, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, []}, fn {field, field_value}, {:ok, refs} ->
      case collect_nested_field(to_string(field), field_value, local_agent_id, opts) do
        {:ok, nested} -> {:cont, {:ok, nested ++ refs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_nested_field(field, value, agent_id, opts) when field in @nested_record_fields,
    do: collect_refs_value(value, agent_id, opts)

  defp collect_nested_field(field, value, agent_id, opts)
       when field in @nested_record_map_fields and is_map(value),
       do: value |> Map.values() |> collect_refs_value(agent_id, opts)

  defp collect_nested_field(field, value, agent_id, opts) do
    case @nested_session_fields[field] do
      nil -> {:ok, []}
      fields -> collect_selected_refs(value, fields, agent_id, opts)
    end
  end

  defp collect_selected_refs(value, fields, agent_id, opts) when is_map(value) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, refs} ->
      field_agent_id = session_agent_id(field, value, agent_id)

      case collect_session_field(field, map_field(value, field), field_agent_id, value, opts) do
        {:ok, direct} -> {:cont, {:ok, direct ++ refs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_selected_refs(_value, _fields, _agent_id, _opts), do: {:ok, []}

  defp collect_session_field("runtime_ref", value, agent_id, record, opts) do
    if trim(value) != "" and trim(value) == trim(map_field(record, "meeting_session_id")) do
      collect_session_values([value], agent_id, opts)
    else
      {:ok, []}
    end
  end

  defp collect_session_field(field, value, agent_id, _record, opts)
       when field in @session_fields do
    collect_session_values(List.wrap(value), agent_id, opts)
  end

  defp collect_session_field(_field, _value, _agent_id, _record, _opts), do: {:ok, []}

  defp collect_session_values(values, agent_id, opts) do
    values =
      values |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      values == [] ->
        {:ok, []}

      Ids.valid_agent_id?(agent_id) ->
        {:ok, Enum.map(values, &{agent_id, &1})}

      true ->
        {:error, {:session_owner_missing, Keyword.get(opts, :context), values}}
    end
  end

  defp rewrite_refs_value(%MapSet{} = value, _maps, _inherited_agent_id, _opts),
    do: {:ok, value}

  defp rewrite_refs_value(%{__struct__: module} = value, maps, inherited_agent_id, opts) do
    with {:ok, fields} <-
           value |> Map.from_struct() |> rewrite_refs_value(maps, inherited_agent_id, opts) do
      {:ok, Map.put(fields, :__struct__, module)}
    end
  end

  defp rewrite_refs_value(value, maps, inherited_agent_id, opts) when is_map(value) do
    local_agent_id = local_agent_id(value, inherited_agent_id)

    with {:ok, direct} <- rewrite_direct_refs(value, maps, local_agent_id, opts),
         {:ok, nested} <- rewrite_nested_refs(direct, maps, local_agent_id, opts) do
      {:ok, nested}
    end
  end

  defp rewrite_refs_value(value, maps, inherited_agent_id, opts) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case rewrite_refs_value(item, maps, inherited_agent_id, opts) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_refs_value(value, maps, inherited_agent_id, opts) when is_tuple(value) do
    with {:ok, list} <-
           value |> Tuple.to_list() |> rewrite_refs_value(maps, inherited_agent_id, opts) do
      {:ok, List.to_tuple(list)}
    end
  end

  defp rewrite_refs_value(value, _maps, _inherited_agent_id, _opts), do: {:ok, value}

  defp rewrite_direct_refs(value, maps, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, value}, fn {field, field_value}, {:ok, acc} ->
      field_name = to_string(field)
      field_agent_id = session_agent_id(field_name, value, local_agent_id)

      case rewrite_session_field(field_name, field_value, field_agent_id, maps, value, opts) do
        {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, field, rewritten)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_nested_refs(value, maps, local_agent_id, opts) do
    if Keyword.get(opts, :recursive, false) do
      rewrite_recursive_refs(value, maps, local_agent_id, opts)
    else
      rewrite_known_nested_refs(value, maps, local_agent_id, opts)
    end
  end

  defp rewrite_recursive_refs(value, maps, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, value}, fn {field, field_value}, {:ok, acc} ->
      case rewrite_refs_value(field_value, maps, local_agent_id, opts) do
        {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, field, rewritten)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_known_nested_refs(value, maps, local_agent_id, opts) do
    Enum.reduce_while(value, {:ok, value}, fn {field, field_value}, {:ok, acc} ->
      case rewrite_nested_field(to_string(field), field_value, maps, local_agent_id, opts) do
        {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, field, rewritten)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_nested_field(field, value, maps, agent_id, opts)
       when field in @nested_record_fields,
       do: rewrite_refs_value(value, maps, agent_id, opts)

  defp rewrite_nested_field(field, value, maps, agent_id, opts)
       when field in @nested_record_map_fields and is_map(value) do
    Enum.reduce_while(value, {:ok, value}, fn {key, record}, {:ok, acc} ->
      case rewrite_refs_value(record, maps, agent_id, opts) do
        {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, key, rewritten)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_nested_field(field, value, maps, agent_id, opts) do
    case @nested_session_fields[field] do
      nil -> {:ok, value}
      fields -> rewrite_selected_refs(value, fields, maps, agent_id, opts)
    end
  end

  defp rewrite_selected_refs(value, fields, maps, agent_id, opts) when is_map(value) do
    Enum.reduce_while(fields, {:ok, value}, fn field, {:ok, acc} ->
      field_agent_id = session_agent_id(field, value, agent_id)
      current = map_field(value, field)

      case rewrite_session_field(field, current, field_agent_id, maps, value, opts) do
        {:ok, ^current} ->
          {:cont, {:ok, acc}}

        {:ok, rewritten} ->
          key = Enum.find(Map.keys(value), &(to_string(&1) == field))
          {:cont, {:ok, Map.put(acc, key, rewritten)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_selected_refs(value, _fields, _maps, _agent_id, _opts), do: {:ok, value}

  defp rewrite_session_field("runtime_ref", value, agent_id, maps, record, opts) do
    if trim(value) != "" and trim(value) == trim(map_field(record, "meeting_session_id")) do
      rewrite_session_value(value, agent_id, maps, opts)
    else
      {:ok, value}
    end
  end

  defp rewrite_session_field(field, value, agent_id, maps, _record, opts)
       when field in @session_fields and is_binary(value),
       do: rewrite_session_value(value, agent_id, maps, opts)

  defp rewrite_session_field(field, values, agent_id, maps, _record, opts)
       when field in @session_fields and is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case rewrite_session_value(value, agent_id, maps, opts) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_session_field(_field, value, _agent_id, _maps, _record, _opts),
    do: {:ok, value}

  defp rewrite_session_value(value, _agent_id, _maps, _opts) when value in [nil, ""],
    do: {:ok, value}

  defp rewrite_session_value(value, agent_id, maps, opts) when is_binary(value) do
    value = String.trim(value)

    cond do
      Ids.valid_agent_id?(agent_id) ->
        case get_in(maps, [agent_id, value]) do
          target when is_binary(target) ->
            {:ok, target}

          nil ->
            if Ids.valid_session_id?(value),
              do: {:ok, value},
              else:
                {:error, {:session_mapping_missing, Keyword.get(opts, :context), agent_id, value}}
        end

      Ids.valid_session_id?(value) ->
        {:ok, value}

      true ->
        {:error, {:session_owner_missing, Keyword.get(opts, :context), value}}
    end
  end

  defp rewrite_session_value(value, _agent_id, _maps, _opts), do: {:ok, value}

  defp local_agent_id(value, inherited_agent_id) do
    @agent_fields
    |> Enum.find_value(&nonblank(map_field(value, &1)))
    |> case do
      nil -> inherited_agent_id
      agent_id -> agent_id
    end
  end

  defp session_agent_id("router_session_id", value, inherited),
    do: first_agent(value, ["router_agent_id", "agent_id"], inherited)

  defp session_agent_id("target_session_id", value, inherited),
    do: first_agent(value, ["target_agent_id", "agent_id"], inherited)

  defp session_agent_id("source_session_id", value, inherited),
    do: first_agent(value, ["source_agent_id", "agent_id", "participant_agent_id"], inherited)

  defp session_agent_id("origin_session_id", value, inherited),
    do:
      first_agent(
        value,
        [
          "origin_agent_id",
          "source_agent_id",
          "created_by_agent_id",
          "agent_id",
          "participant_agent_id"
        ],
        inherited
      )

  defp session_agent_id("meeting_session_id", value, inherited),
    do: first_agent(value, ["meeting_agent_id", "agent_id"], inherited)

  defp session_agent_id(_field, value, inherited),
    do: first_agent(value, @agent_fields, inherited)

  defp first_agent(value, fields, inherited) do
    Enum.find_value(fields, &nonblank(map_field(value, &1))) || inherited
  end

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) ||
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end

  defp nonblank(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp decode(body, expected_agent_id \\ nil) do
    with {:ok, value} when is_map(value) <- Jason.decode(body),
         {:ok, normalized} <- normalize_record(value),
         true <- is_nil(expected_agent_id) or normalized.agent_id == expected_agent_id do
      {:ok, normalized}
    else
      false -> {:error, :session_identity_map_agent_mismatch}
      _ -> {:error, :invalid_session_identity_map}
    end
  end

  defp normalize_record(value) do
    agent_id = value["agent_id"] || value[:agent_id]
    session_ids = value["session_ids"] || value[:session_ids]

    with true <- is_binary(agent_id) and Ids.valid_agent_id?(agent_id),
         {:ok, session_ids} <- normalize_session_ids(session_ids) do
      {:ok, %{agent_id: agent_id, session_ids: session_ids}}
    else
      _ -> {:error, :invalid_session_identity_map}
    end
  end

  defp normalize_session_ids(session_ids) when is_map(session_ids) do
    session_ids
    |> Enum.reduce_while({:ok, %{}}, fn {source, target}, {:ok, acc} ->
      source = if is_binary(source), do: String.trim(source), else: ""

      cond do
        source == "" ->
          {:halt, {:error, :invalid_session_identity_source}}

        not Ids.valid_session_id?(target) ->
          {:halt, {:error, :invalid_session_identity_target}}

        Ids.valid_session_id?(source) and source != target ->
          {:halt, {:error, :canonical_session_identity_changed}}

        Map.has_key?(acc, source) ->
          {:halt, {:error, :duplicate_session_identity_source}}

        true ->
          {:cont, {:ok, Map.put(acc, source, target)}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        if normalized |> Map.values() |> Enum.uniq() |> length() == map_size(normalized),
          do: {:ok, normalized},
          else: {:error, :duplicate_session_identity_target}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_session_ids(_session_ids), do: {:error, :invalid_session_identity_map}

  defp normalize_sources(source_ids) do
    normalized =
      source_ids
      |> Enum.map(fn
        source when is_binary(source) -> String.trim(source)
        _ -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    if length(normalized) == length(Enum.uniq(source_ids)),
      do: {:ok, normalized},
      else: {:error, :invalid_session_identity_source}
  end

  defp encode(agent_id, session_ids, existing_body) do
    created_at =
      case existing_body && Jason.decode(existing_body) do
        {:ok, %{"created_at" => created_at}} -> created_at
        _ -> nil
      end

    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "version" => 1,
      "agent_id" => agent_id,
      "session_ids" => session_ids,
      "created_at" => created_at || now,
      "updated_at" => now
    })
  end

  defp completion_key(phase), do: @completion_prefix <> Atom.to_string(phase) <> ".json"

  defp verify_completion(phase, maps) do
    case phase_complete?(phase, maps) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:session_identity_completion_conflict, phase}}
      {:error, _} = error -> error
    end
  end

  defp fingerprint(maps) do
    maps
    |> Enum.map(fn {agent_id, session_ids} -> {agent_id, Enum.sort(session_ids)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
