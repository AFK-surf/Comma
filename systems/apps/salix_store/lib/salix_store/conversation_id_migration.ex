defmodule SalixStore.ConversationIdMigration do
  @moduledoc """
  Durable conversation-scoped identity maps for the release cutover.

  Runtime code never reads these records. A map is reserved before any owner or
  reference is moved, and every retry reuses the first canonical targets.
  """

  alias SalixStore.{Crypto, Ids, S3}

  @maps_prefix "ctl/migrations/conversation_identity_v1/maps/"
  @completion_prefix "ctl/migrations/conversation_identity_v1/completions/"
  @phases [:s3, :bft, :analytics]
  @retries 8

  def maps_prefix, do: @maps_prefix

  def map_key(group_id, conversation_id) do
    @maps_prefix <> Crypto.hex(group_id) <> "/" <> Crypto.hex(conversation_id) <> ".json"
  end

  def reserve(
        group_id,
        conversation_id,
        materialized,
        participant_ids,
        message_ids,
        participant_aliases
      )
      when is_binary(group_id) and is_binary(conversation_id) and is_list(participant_ids) and
             is_list(message_ids) and is_map(participant_aliases) and is_boolean(materialized) do
    with true <- Ids.valid_group_id?(group_id),
         {:ok, participant_ids} <- normalize_sources(participant_ids),
         {:ok, message_ids} <- normalize_sources(message_ids),
         {:ok, participant_aliases} <-
           normalize_aliases(participant_aliases, participant_ids) do
      reserve(
        group_id,
        conversation_id,
        materialized,
        participant_ids,
        message_ids,
        participant_aliases,
        @retries
      )
    else
      false -> {:error, :invalid_group_id}
      {:error, _} = error -> error
    end
  end

  def read_all do
    with {:ok, objects} <- S3.list_all(@maps_prefix) do
      Enum.reduce_while(objects, {:ok, %{}}, fn %{key: key}, {:ok, acc} ->
        case read_map_object(key) do
          {:ok, map} ->
            identity = {map["group_id"], get_in(map, ["conversation_id", "source"])}

            if key == map_key(elem(identity, 0), elem(identity, 1)) and
                 not Map.has_key?(acc, identity) do
              {:cont, {:ok, Map.put(acc, identity, map)}}
            else
              {:halt, {:error, {:invalid_conversation_identity_map_owner, key}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:conversation_identity_map_read_failed, key, reason}}}
        end
      end)
    end
  end

  def normalize_all(maps) when is_map(maps) do
    with {:ok, normalized} <-
           Enum.reduce_while(maps, {:ok, %{}}, fn
             {{group_id, source_id} = identity, map}, {:ok, acc}
             when is_binary(group_id) and is_binary(source_id) and is_map(map) ->
               case normalize(map, group_id, source_id) do
                 {:ok, value} -> {:cont, {:ok, Map.put(acc, identity, value)}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end

             _entry, _acc ->
               {:halt, {:error, :invalid_conversation_identity_maps}}
           end),
         :ok <- validate_global_targets(normalized) do
      {:ok, normalized}
    end
  end

  def normalize_all(_maps), do: {:error, :invalid_conversation_identity_maps}

  def lookup(maps, group_id, conversation_id) do
    case Map.get(maps, {group_id, conversation_id}) do
      %{} = map -> {:ok, map}
      nil -> {:error, {:conversation_identity_not_mapped, group_id, conversation_id}}
    end
  end

  def resolve(maps, group_id, conversation_id) do
    case lookup(maps, group_id, conversation_id) do
      {:ok, map} ->
        {:ok, map}

      {:error, _} ->
        case Enum.find_value(maps, fn
               {{^group_id, _source_id}, map} ->
                 if get_in(map, ["conversation_id", "target"]) == conversation_id, do: map

               _entry ->
                 nil
             end) do
          %{} = map -> {:ok, map}
          nil -> {:error, {:conversation_identity_not_mapped, group_id, conversation_id}}
        end
    end
  end

  def conversation_target(maps, group_id, conversation_id) do
    with {:ok, map} <- lookup(maps, group_id, conversation_id) do
      {:ok, get_in(map, ["conversation_id", "target"])}
    end
  end

  def participant_target(maps, group_id, conversation_id, participant_id) do
    scoped_target(maps, group_id, conversation_id, "participant_ids", participant_id)
  end

  def message_target(maps, group_id, conversation_id, message_id) do
    scoped_target(maps, group_id, conversation_id, "message_ids", message_id)
  end

  def phase_complete?(phase, maps) when phase in @phases do
    with {:ok, maps} <- normalize_all(maps) do
      case S3.get(completion_key(phase)) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"identity_fingerprint" => stored}} -> {:ok, stored == fingerprint(maps)}
            _ -> {:error, :invalid_conversation_identity_completion}
          end

        {:error, :not_found} ->
          {:ok, false}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def mark_phase_complete(phase, maps) when phase in @phases do
    with {:ok, maps} <- normalize_all(maps) do
      record = %{
        "version" => 1,
        "phase" => Atom.to_string(phase),
        "identity_fingerprint" => fingerprint(maps),
        "completed_at" => System.system_time(:millisecond)
      }

      case S3.put(completion_key(phase), Jason.encode!(record), if_none_match: "*") do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> verify_completion(phase, maps)
        {:error, {:ambiguous, _}} -> verify_completion(phase, maps)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fingerprint(maps) do
    maps
    |> Enum.sort_by(fn {{group_id, conversation_id}, _map} -> {group_id, conversation_id} end)
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  defp reserve(
         _group_id,
         _conversation_id,
         _materialized,
         _participant_ids,
         _message_ids,
         _participant_aliases,
         0
       ),
       do: {:error, :conversation_identity_reservation_exhausted}

  defp reserve(
         group_id,
         conversation_id,
         materialized,
         participant_ids,
         message_ids,
         participant_aliases,
         attempts
       ) do
    key = map_key(group_id, conversation_id)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, existing} <- decode(body, group_id, conversation_id),
             {:ok, merged} <-
               merge_sources(
                 existing,
                 materialized,
                 participant_ids,
                 message_ids,
                 participant_aliases
               ) do
          if merged == existing do
            {:ok, merged}
          else
            case S3.put(key, Jason.encode!(merged), if_match: etag) do
              {:ok, _} ->
                {:ok, merged}

              {:error, :precondition_failed} ->
                reserve(
                  group_id,
                  conversation_id,
                  materialized,
                  participant_ids,
                  message_ids,
                  participant_aliases,
                  attempts - 1
                )

              {:error, {:ambiguous, _}} ->
                reserve(
                  group_id,
                  conversation_id,
                  materialized,
                  participant_ids,
                  message_ids,
                  participant_aliases,
                  attempts - 1
                )

              {:error, reason} ->
                {:error, reason}
            end
          end
        end

      {:error, :not_found} ->
        with {:ok, map} <-
               new_map(
                 group_id,
                 conversation_id,
                 materialized,
                 participant_ids,
                 message_ids,
                 participant_aliases
               ) do
          case S3.put(key, Jason.encode!(map), if_none_match: "*") do
            {:ok, _} ->
              {:ok, map}

            {:error, :precondition_failed} ->
              reserve(
                group_id,
                conversation_id,
                materialized,
                participant_ids,
                message_ids,
                participant_aliases,
                attempts - 1
              )

            {:error, {:ambiguous, _}} ->
              reserve(
                group_id,
                conversation_id,
                materialized,
                participant_ids,
                message_ids,
                participant_aliases,
                attempts - 1
              )

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_map(
         group_id,
         conversation_id,
         materialized,
         participant_ids,
         message_ids,
         participant_aliases
       ) do
    conversation_target =
      if Ids.valid_conversation_id?(conversation_id),
        do: conversation_id,
        else: Ids.new_conversation_id()

    participant_targets =
      participant_ids
      |> allocate_targets(&Ids.valid_participant_id?/1, &Ids.new_participant_id/0)
      |> apply_aliases(participant_aliases)

    {:ok,
     %{
       "version" => 1,
       "group_id" => group_id,
       "materialized" => materialized,
       "conversation_id" => %{"source" => conversation_id, "target" => conversation_target},
       "participant_ids" => participant_targets,
       "message_ids" =>
         allocate_targets(message_ids, &Ids.valid_message_id?/1, &Ids.new_message_id/0),
       "created_at" => System.system_time(:millisecond),
       "updated_at" => System.system_time(:millisecond)
     }}
  end

  defp merge_sources(map, materialized, participant_ids, message_ids, participant_aliases) do
    merged =
      map
      |> Map.put("materialized", map["materialized"] or materialized)
      |> Map.put(
        "participant_ids",
        map["participant_ids"]
        |> merge_targets(
          participant_ids,
          &Ids.valid_participant_id?/1,
          &Ids.new_participant_id/0
        )
        |> apply_aliases(participant_aliases)
      )
      |> Map.put(
        "message_ids",
        merge_targets(
          map["message_ids"],
          message_ids,
          &Ids.valid_message_id?/1,
          &Ids.new_message_id/0
        )
      )

    {:ok,
     if(merged == map,
       do: map,
       else: Map.put(merged, "updated_at", System.system_time(:millisecond))
     )}
  end

  defp allocate_targets(sources, valid?, generate) do
    Map.new(sources, fn source -> {source, if(valid?.(source), do: source, else: generate.())} end)
  end

  defp merge_targets(existing, sources, valid?, generate) do
    Enum.reduce(sources, existing || %{}, fn source, acc ->
      Map.put_new(acc, source, if(valid?.(source), do: source, else: generate.()))
    end)
  end

  defp apply_aliases(targets, aliases) do
    Enum.reduce(aliases, targets, fn {alias_id, participant_id}, acc ->
      target = Map.fetch!(acc, participant_id)
      previous_target = acc[alias_id]
      acc = Map.put(acc, alias_id, target)

      if is_binary(previous_target) and previous_target != target,
        do: Map.put(acc, previous_target, target),
        else: acc
    end)
  end

  defp normalize_sources(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, values |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_conversation_identity_source}
    end
  end

  defp normalize_aliases(aliases, participant_ids) do
    participants = MapSet.new(participant_ids)

    if Enum.all?(aliases, fn {alias_id, participant_id} ->
         is_binary(alias_id) and String.trim(alias_id) != "" and
           is_binary(participant_id) and MapSet.member?(participants, participant_id)
       end) do
      {:ok,
       Map.new(aliases, fn {alias_id, participant_id} ->
         {String.trim(alias_id), participant_id}
       end)}
    else
      {:error, :invalid_conversation_participant_aliases}
    end
  end

  defp normalize(map, group_id, conversation_id) do
    with 1 <- map["version"],
         ^group_id <- map["group_id"],
         %{"source" => ^conversation_id, "target" => target} <- map["conversation_id"],
         materialized when is_boolean(materialized) <- map["materialized"],
         true <- Ids.valid_conversation_id?(target),
         {:ok, participant_ids} <-
           normalize_id_map(map["participant_ids"], &Ids.valid_participant_id?/1),
         {:ok, message_ids} <- normalize_id_map(map["message_ids"], &Ids.valid_message_id?/1) do
      {:ok,
       map
       |> Map.put("materialized", materialized)
       |> Map.put("participant_ids", participant_ids)
       |> Map.put("message_ids", message_ids)}
    else
      _ -> {:error, :invalid_conversation_identity_map}
    end
  end

  defp normalize_id_map(map, valid?) when is_map(map) do
    if Enum.all?(map, fn {source, target} ->
         is_binary(source) and source != "" and valid?.(target)
       end) do
      {:ok, map}
    else
      {:error, :invalid_conversation_scoped_identity_map}
    end
  end

  defp normalize_id_map(_map, _valid?), do: {:error, :invalid_conversation_scoped_identity_map}

  defp validate_global_targets(maps) do
    targets = [
      {:conversation,
       Enum.map(maps, fn {identity, map} ->
         {get_in(map, ["conversation_id", "target"]), identity}
       end)},
      {:participant, scoped_targets(maps, "participant_ids")},
      {:message, scoped_targets(maps, "message_ids")}
    ]

    Enum.reduce_while(targets, :ok, fn {kind, entries}, :ok ->
      case Enum.reduce_while(entries, %{}, fn {target, identity}, owners ->
             case owners[target] do
               nil -> {:cont, Map.put(owners, target, identity)}
               ^identity -> {:cont, owners}
               _other -> {:halt, :duplicate}
             end
           end) do
        :duplicate -> {:halt, {:error, {:duplicate_conversation_identity_target, kind}}}
        _owners -> {:cont, :ok}
      end
    end)
  end

  defp scoped_targets(maps, field) do
    Enum.flat_map(maps, fn {identity, map} ->
      map[field]
      |> Map.values()
      |> Enum.uniq()
      |> Enum.map(&{&1, identity})
    end)
  end

  defp scoped_target(maps, group_id, conversation_id, field, source_id) do
    with {:ok, map} <- resolve(maps, group_id, conversation_id) do
      targets = map[field] || %{}

      cond do
        is_binary(targets[source_id]) -> {:ok, targets[source_id]}
        source_id in Map.values(targets) -> {:ok, source_id}
        true -> {:error, {:conversation_scoped_identity_not_mapped, field, source_id}}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp read_map_object(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> decode(body)
      {:error, _} = error -> error
    end
  end

  defp decode(body, expected_group_id \\ nil, expected_conversation_id \\ nil) do
    with {:ok, map} when is_map(map) <- Jason.decode(body),
         group_id when is_binary(group_id) <- map["group_id"],
         %{"source" => conversation_id} when is_binary(conversation_id) <- map["conversation_id"],
         true <- expected_group_id in [nil, group_id],
         true <- expected_conversation_id in [nil, conversation_id] do
      normalize(map, group_id, conversation_id)
    else
      _ -> {:error, :invalid_conversation_identity_map}
    end
  end

  defp verify_completion(phase, maps) do
    case phase_complete?(phase, maps) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :conversation_identity_completion_conflict}
      {:error, _} = error -> error
    end
  end

  defp completion_key(phase), do: @completion_prefix <> Atom.to_string(phase) <> ".json"
end
