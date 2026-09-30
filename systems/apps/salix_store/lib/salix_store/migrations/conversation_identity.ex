defmodule SalixStore.Migrations.ConversationIdentity do
  @moduledoc """
  One-shot migration for Salix conversation aggregate identities.

  Writers are stopped while this module inventories every aggregate, reserves
  durable conversation-scoped maps, moves each segmented subtree, and rewrites
  the Salix-owned references outside those subtrees.
  """

  alias SalixStore.{
    Codec,
    ConversationIdMigration,
    Crypto,
    HierarchyIdMigration,
    Ids,
    Keys,
    S3
  }

  @conversation_meta_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)/meta\.json$|
  @conversation_object_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)/.+$|
  @legacy_conversation_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)\.json$|
  @legacy_dispatch_re ~r|^ctl/group_conversation_dispatch/([^/]+)/([^/]+)/.+$|
  @legacy_dispatch_prefix "ctl/group_conversation_dispatch/"
  @legacy_segmented_marker_prefix "ctl/migrations/conversation_storage_segmented/"
  @participant_state_re ~r|/participant_states/[^/]+\.json$|
  @message_segment_re ~r|/messages/segments/([^/]+)\.jsonl$|
  @max_concurrency 16
  @reference_prefixes [
    "agents/",
    "ctl/groups/",
    "ctl/group_conversation_create_requests/",
    "ctl/conversation_pins/",
    "ctl/group_conversation_delivery_wakeups/",
    "ctl/schedules/",
    "ctl/schedule_runs/",
    "ctl/im_slack_router_status_windows/",
    "ctl/im_slack_thread_bindings/"
  ]
  @conversation_ref_fields ~w(conversation_id router_conversation_id parent_conversation_id)
  @participant_ref_fields ~w(participant_id source_participant_id from_participant_id)
  @message_ref_fields ~w(message_id parent_message_id)
  @runtime_source_fields ~w(source_message_id runtime_message_id dedupe_key)
  @runtime_source_list_fields ~w(source_message_ids active_external_source_message_ids input_dedupe)
  # Billing contexts belong to the product/metering boundary. A field named
  # `conversation_id` inside one is the product conversation identity (for
  # example `commaasst-*`), not a Salix aggregate reference.
  @opaque_reference_fields ~w(
    metadata
    message_metadata
    delivery_result
    billing_context
    delivery_billing_context
    target_billing_context
  )

  def run(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    with {:ok, maps} <- reserve_maps(Keyword.get(opts, :additional_refs, [])),
         {:ok, aggregate_stats} <- migrate_aggregates(maps),
         {:ok, reference_stats} <- rewrite_references(maps),
         :ok <- rebuild_conversation_list(maps),
         :ok <- verify(maps),
         :ok <- cleanup_legacy_segmented_storage(maps),
         :ok <- verify_legacy_segmented_storage_removed(),
         :ok <- maybe_mark_complete(maps, opts) do
      {:ok, %{aggregates: aggregate_stats, references: reference_stats, maps: maps}}
    end
  end

  def reserve_maps(additional_refs \\ []) do
    with {:ok, existing_maps} <- ConversationIdMigration.read_all(),
         {:ok, inventory} <- inventory(existing_maps),
         {:ok, inventory} <- merge_additional_refs(inventory, additional_refs),
         {:ok, inventory} <- canonicalize_inventory(inventory, existing_maps),
         :ok <- reserve_inventory(inventory),
         {:ok, maps} <- ConversationIdMigration.read_all(),
         :ok <- validate_runtime_source_identities(maps) do
      {:ok, maps}
    end
  end

  def inventory(existing_maps \\ %{}) do
    with {:ok, hierarchy_identity} <- hierarchy_identity(),
         {:ok, objects} <- S3.list_all(Keys.ctl_group_conversations_prefix()) do
      with :ok <- validate_aggregate_owners(objects, existing_maps),
           {:ok, aggregate_inventory} <-
             objects
             |> Enum.filter(&Regex.match?(@conversation_meta_re, &1.key))
             |> parallel_map(&inventory_conversation(&1, hierarchy_identity))
             |> collect_inventory(),
           {:ok, runtime_refs} <- inventory_runtime_context_refs(),
           {:ok, structured_refs} <- inventory_structured_refs(),
           {:ok, legacy_dispatch_refs} <-
             inventory_legacy_dispatch_refs(hierarchy_identity),
           {:ok, inventory} <- merge_additional_refs(aggregate_inventory, runtime_refs),
           {:ok, inventory} <- merge_additional_refs(inventory, structured_refs),
           {:ok, inventory} <- merge_additional_refs(inventory, legacy_dispatch_refs) do
        {:ok, inventory}
      end
    end
  end

  defp hierarchy_identity do
    case HierarchyIdMigration.read() do
      {:ok, identity} -> {:ok, identity}
      {:error, :not_found} -> {:ok, HierarchyIdMigration.empty()}
      {:error, _} = error -> error
    end
  end

  defp validate_aggregate_owners(objects, existing_maps) do
    meta_owners =
      objects
      |> Enum.flat_map(&aggregate_owner(&1.key, @conversation_meta_re))
      |> MapSet.new()

    objects
    |> Enum.flat_map(&aggregate_owner(&1.key, @conversation_object_re))
    |> MapSet.new()
    |> MapSet.difference(meta_owners)
    |> Enum.reduce_while(:ok, fn {group_id, conversation_id} = orphan, :ok ->
      case ConversationIdMigration.resolve(existing_maps, group_id, conversation_id) do
        {:ok, map} ->
          source = {group_id, get_in(map, ["conversation_id", "source"])}
          target = {group_id, get_in(map, ["conversation_id", "target"])}

          if MapSet.member?(meta_owners, source) or MapSet.member?(meta_owners, target),
            do: {:cont, :ok},
            else: {:halt, {:error, {:conversation_aggregate_owner_missing, orphan}}}

        {:error, _reason} ->
          {:halt, {:error, {:conversation_aggregate_owner_missing, orphan}}}
      end
    end)
  end

  defp aggregate_owner(key, pattern) do
    case Regex.run(pattern, key) do
      [_, group_id, conversation_id] -> [{group_id, conversation_id}]
      _ -> []
    end
  end

  defp inventory_structured_refs do
    @reference_prefixes
    |> Enum.reject(&(&1 == "agents/"))
    |> Enum.reduce_while({:ok, []}, fn prefix, {:ok, acc} ->
      with {:ok, objects} <- S3.list_all(prefix) do
        objects
        |> Enum.filter(&structured_reference?(&1.key))
        |> parallel_map(&inventory_structured_ref_object/1)
        |> Enum.reduce_while({:ok, acc}, fn
          {:ok, refs}, {:ok, refs_acc} -> {:cont, {:ok, refs ++ refs_acc}}
          {:error, reason}, _refs_acc -> {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, refs} -> {:cont, {:ok, refs}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp inventory_legacy_dispatch_refs(hierarchy_identity) do
    with {:ok, objects} <- S3.list_all(@legacy_dispatch_prefix) do
      objects
      |> Enum.filter(&Regex.match?(@legacy_dispatch_re, &1.key))
      |> parallel_map(&inventory_legacy_dispatch_ref(&1, hierarchy_identity))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, nil}, {:ok, refs} -> {:cont, {:ok, refs}}
        {:ok, ref}, {:ok, refs} -> {:cont, {:ok, [ref | refs]}}
        {:error, reason}, _refs -> {:halt, {:error, reason}}
      end)
    end
  end

  defp inventory_legacy_dispatch_ref(%{key: key}, hierarchy_identity) do
    with {:ok, record} <- read_json(key),
         group_id when is_binary(group_id) <- record["agent_group_id"] || record["group_id"],
         true <- Ids.valid_group_id?(group_id),
         conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           record["conversation_id"] do
      case record["message_id"] do
        message_id when is_binary(message_id) and message_id != "" ->
          with {:ok, participant_ids, participant_aliases} <-
                 legacy_dispatch_participant_refs(record, hierarchy_identity) do
            {:ok,
             %{
               "group_id" => group_id,
               "conversation_id" => conversation_id,
               "participant_ids" => participant_ids,
               "participant_aliases" => participant_aliases,
               "message_ids" => [message_id]
             }}
          end

        _ ->
          {:ok, nil}
      end
    else
      false -> {:error, {:legacy_dispatch_group_invalid, key}}
      {:error, reason} -> {:error, {:legacy_dispatch_inventory_failed, key, reason}}
      _ -> {:error, {:legacy_dispatch_inventory_failed, key, :invalid_record}}
    end
  end

  defp legacy_dispatch_participant_refs(record, hierarchy_identity) do
    participant_ids =
      (@participant_ref_fields ++ ["target_participant_id"])
      |> Enum.flat_map(&optional_inventory_id(record[&1]))

    target_agent_id = record["target_agent_id"] || record["participant_agent_id"]
    target_participant_id = record["target_participant_id"] || record["participant_id"]

    aliases =
      if is_binary(target_agent_id) and is_binary(target_participant_id) do
        hierarchy_identity.agents
        |> Enum.filter(fn {source, target} ->
          target == target_agent_id and source != target_participant_id
        end)
        |> Map.new(fn {source, _target} -> {source, target_participant_id} end)
      else
        %{}
      end

    {:ok, Enum.uniq(participant_ids ++ Map.keys(aliases)), aliases}
  end

  defp inventory_structured_ref_object(%{key: key}) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- decode_structured(key, body),
         group_id <- reference_group_id(record, key),
         refs <- typed_identity_refs(record, group_id, nil) do
      if refs == [] or Ids.valid_group_id?(group_id),
        do: {:ok, refs},
        else: {:error, {:structured_reference_group_missing, key}}
    else
      {:error, reason} -> {:error, {:structured_reference_inventory_failed, key, reason}}
    end
  end

  defp typed_identity_refs(value, group_id, inherited_conversation_id) when is_map(value) do
    group_id = map_field(value, "agent_group_id") || map_field(value, "group_id") || group_id
    conversation_id = map_field(value, "conversation_id") || inherited_conversation_id
    parent_conversation_id = map_field(value, "parent_conversation_id")

    own_refs =
      @conversation_ref_fields
      |> Enum.flat_map(fn field ->
        case map_field(value, field) do
          id when is_binary(id) and id != "" ->
            participant_ids =
              if field == "conversation_id", do: typed_participant_ids(value), else: []

            message_ids = if field == "conversation_id", do: typed_message_ids(value), else: []

            [
              %{
                "group_id" => group_id,
                "conversation_id" => id,
                "participant_ids" => participant_ids,
                "message_ids" => message_ids
              }
            ]

          _ ->
            []
        end
      end)

    inherited_refs =
      if is_binary(inherited_conversation_id) and inherited_conversation_id != "" and
           map_field(value, "conversation_id") in [nil, ""] do
        participant_ids = typed_participant_ids(value)
        message_ids = typed_message_ids(value)

        if participant_ids == [] and message_ids == [] do
          []
        else
          [
            %{
              "group_id" => group_id,
              "conversation_id" => inherited_conversation_id,
              "participant_ids" => participant_ids,
              "message_ids" => message_ids
            }
          ]
        end
      else
        []
      end

    parent_refs =
      case {parent_conversation_id, map_field(value, "parent_message_id")} do
        {conversation_id, message_id}
        when is_binary(conversation_id) and conversation_id != "" and is_binary(message_id) and
               message_id != "" ->
          [
            %{
              "group_id" => group_id,
              "conversation_id" => conversation_id,
              "message_ids" => [message_id]
            }
          ]

        _ ->
          []
      end

    nested_refs =
      value
      |> Enum.reject(fn {field, _nested} -> to_string(field) in @opaque_reference_fields end)
      |> Enum.flat_map(fn {_field, nested} ->
        typed_identity_refs(nested, group_id, conversation_id)
      end)

    own_refs ++ inherited_refs ++ parent_refs ++ nested_refs
  end

  defp typed_identity_refs(value, group_id, inherited_conversation_id) when is_list(value),
    do: Enum.flat_map(value, &typed_identity_refs(&1, group_id, inherited_conversation_id))

  defp typed_identity_refs(value, group_id, inherited_conversation_id) when is_tuple(value),
    do: value |> Tuple.to_list() |> typed_identity_refs(group_id, inherited_conversation_id)

  defp typed_identity_refs(_value, _group_id, _inherited_conversation_id), do: []

  defp typed_participant_ids(value) do
    (@participant_ref_fields ++ ["target_participant_id"])
    |> Enum.flat_map(&optional_inventory_id(map_field(value, &1)))
    |> Enum.uniq()
  end

  defp typed_message_ids(value) do
    current_fields = @message_ref_fields -- ["parent_message_id"]

    current_fields
    |> Enum.flat_map(&optional_inventory_id(map_field(value, &1)))
    |> Enum.uniq()
  end

  defp inventory_runtime_context_refs do
    with {:ok, objects} <- S3.list_all("agents/") do
      objects
      |> Enum.filter(&structured_reference?(&1.key))
      |> parallel_map(&inventory_runtime_context_object/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, refs}, {:ok, acc} -> {:cont, {:ok, refs ++ acc}}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)
    end
  end

  defp inventory_runtime_context_object(%{key: key}) do
    with group_id when is_binary(group_id) <- path_group_id(key),
         {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- decode_structured(key, body) do
      {:ok, runtime_context_refs(record, group_id)}
    else
      nil -> {:error, {:runtime_reference_group_missing, key}}
      {:error, reason} -> {:error, {:runtime_reference_inventory_failed, key, reason}}
    end
  end

  defp validate_runtime_source_identities(maps) do
    with {:ok, objects} <- S3.list_all("agents/") do
      objects
      |> Enum.filter(&structured_reference?(&1.key))
      |> parallel_map(&validate_runtime_source_identity_object(&1, maps))
      |> Enum.reduce_while(:ok, fn
        :ok, :ok -> {:cont, :ok}
        {:error, reason}, :ok -> {:halt, {:error, reason}}
      end)
    end
  end

  defp validate_runtime_source_identity_object(%{key: key}, maps) do
    with group_id when is_binary(group_id) <- path_group_id(key),
         {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- decode_structured(key, body),
         :ok <- validate_runtime_source_identity_record(record, group_id, maps) do
      :ok
    else
      nil -> {:error, {:runtime_reference_group_missing, key}}
      {:error, reason} -> {:error, {:runtime_source_identity_inventory_failed, key, reason}}
    end
  end

  defp validate_runtime_source_identity_record(value, group_id, maps) when is_struct(value) do
    value
    |> Map.from_struct()
    |> validate_runtime_source_identity_record(group_id, maps)
  end

  defp validate_runtime_source_identity_record(value, group_id, maps) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      field = to_string(key)

      result =
        cond do
          field in @opaque_reference_fields ->
            :ok

          field in @runtime_source_fields ->
            validate_runtime_source_identity_value(nested, group_id, maps)

          field in @runtime_source_list_fields ->
            nested
            |> runtime_source_identity_values()
            |> Enum.reduce_while(:ok, fn source_id, :ok ->
              case validate_runtime_source_identity_value(source_id, group_id, maps) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)

          true ->
            validate_runtime_source_identity_record(nested, group_id, maps)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_runtime_source_identity_record(values, group_id, maps) when is_list(values),
    do: validate_runtime_source_identity_records(values, group_id, maps)

  defp validate_runtime_source_identity_record(values, group_id, maps) when is_tuple(values),
    do: values |> Tuple.to_list() |> validate_runtime_source_identity_records(group_id, maps)

  defp validate_runtime_source_identity_record(_value, _group_id, _maps), do: :ok

  defp validate_runtime_source_identity_records(values, group_id, maps) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_runtime_source_identity_record(value, group_id, maps) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_runtime_source_identity_value(value, group_id, maps) when is_binary(value) do
    rewritten = rewrite_runtime_source_identity(value, group_id, maps, nil)

    if runtime_source_identity_canonical?(rewritten),
      do: :ok,
      else: {:error, {:unmapped_runtime_source_identity, value}}
  end

  defp validate_runtime_source_identity_value(_value, _group_id, _maps), do: :ok

  defp runtime_source_identity_values(%MapSet{} = values), do: MapSet.to_list(values)
  defp runtime_source_identity_values(values) when is_list(values), do: values
  defp runtime_source_identity_values(_value), do: []

  defp runtime_context_refs(value, _group_id) when is_binary(value), do: []

  defp runtime_context_refs(%MapSet{} = values, group_id),
    do: Enum.flat_map(values, &runtime_context_refs(&1, group_id))

  defp runtime_context_refs(value, group_id) when is_struct(value) do
    value
    |> Map.from_struct()
    |> runtime_context_refs(group_id)
  end

  defp runtime_context_refs(value, group_id) when is_map(value) do
    own_refs =
      if generated_source_context_record?(value) do
        value
        |> map_field("content")
        |> parse_source_context()
        |> case do
          fields when is_map(fields) -> source_context_refs(fields, group_id)
          _ -> []
        end
      else
        []
      end

    source_refs =
      Enum.flat_map(value, fn {field, nested} ->
        field = to_string(field)

        cond do
          field in @runtime_source_fields ->
            runtime_source_ref(nested, group_id)

          field in @runtime_source_list_fields ->
            nested
            |> runtime_source_identity_values()
            |> Enum.flat_map(&runtime_source_ref(&1, group_id))

          true ->
            []
        end
      end)

    nested_refs =
      value
      |> Enum.reject(fn {field, _nested} -> to_string(field) in @opaque_reference_fields end)
      |> Enum.flat_map(fn {_field, nested} -> runtime_context_refs(nested, group_id) end)

    own_refs ++ source_refs ++ nested_refs
  end

  defp runtime_context_refs(value, group_id) when is_list(value),
    do: Enum.flat_map(value, &runtime_context_refs(&1, group_id))

  defp runtime_context_refs(value, group_id) when is_tuple(value),
    do: value |> Tuple.to_list() |> runtime_context_refs(group_id)

  defp runtime_context_refs(_value, _group_id), do: []

  defp runtime_source_ref("groupconv:" <> source, group_id) do
    source = String.trim_trailing(source, ":source-context")

    case String.split(source, ":") do
      [conversation_id | message_and_participant] when length(message_and_participant) >= 2 ->
        participant_id = List.last(message_and_participant)
        message_id = message_and_participant |> Enum.drop(-1) |> Enum.join(":")

        if conversation_id != "" and message_id != "" and participant_id != "" do
          [
            source_context_ref(
              group_id,
              conversation_id,
              participant_id,
              message_id
            )
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp runtime_source_ref(_value, _group_id), do: []

  defp source_context_refs(fields, group_id) do
    [
      source_context_ref(
        group_id,
        fields["conversation_id"],
        [fields["participant_id"], fields["from_participant_id"]],
        fields["message_id"]
      ),
      source_context_ref(
        group_id,
        fields["parent_conversation_id"],
        nil,
        fields["parent_message_id"]
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp source_context_ref(_group_id, conversation_id, _participant_id, _message_id)
       when conversation_id in [nil, ""],
       do: nil

  defp source_context_ref(group_id, conversation_id, participant_ids, message_ids) do
    %{
      "group_id" => group_id,
      "conversation_id" => conversation_id,
      "participant_ids" =>
        participant_ids |> List.wrap() |> Enum.flat_map(&optional_inventory_id/1),
      "message_ids" => message_ids |> List.wrap() |> Enum.flat_map(&optional_inventory_id/1)
    }
  end

  defp optional_inventory_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      value -> [value]
    end
  end

  defp optional_inventory_id(_value), do: []

  def verify(maps) do
    with {:ok, maps} <- ConversationIdMigration.normalize_all(maps),
         :ok <- verify_aggregate_targets(maps),
         :ok <- verify_no_legacy_aggregate_sources(maps),
         :ok <- verify_reference_objects(maps),
         :ok <- verify_conversation_lists(maps) do
      :ok
    end
  end

  defp inventory_conversation(%{key: key}, hierarchy_identity) do
    with [_, group_id, conversation_id] <- Regex.run(@conversation_meta_re, key),
         true <- Ids.valid_group_id?(group_id),
         {:ok, objects} <- S3.list_all(Keys.ctl_group_conversation_dir(group_id, conversation_id)),
         {:ok, participant_ids} <- collect_participant_identity_ids(objects),
         {:ok, participant_aliases} <-
           collect_participant_aliases(objects, conversation_id, hierarchy_identity),
         {:ok, message_ids} <- collect_message_ids(objects) do
      {:ok,
       {{group_id, conversation_id},
        %{
          group_id: group_id,
          conversation_id: conversation_id,
          materialized: true,
          participant_ids: Enum.uniq(participant_ids ++ Map.keys(participant_aliases)),
          participant_aliases: participant_aliases,
          message_ids: message_ids
        }}}
    else
      false -> {:error, {:invalid_conversation_group_id, key}}
      nil -> {:error, {:invalid_conversation_meta_key, key}}
      {:error, reason} -> {:error, {:conversation_inventory_failed, key, reason}}
    end
  end

  defp collect_participant_ids(objects) do
    objects
    |> Enum.filter(&Regex.match?(@participant_state_re, &1.key))
    |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, ids} ->
      with {:ok, record} <- read_json(key),
           participant_id when is_binary(participant_id) and participant_id != "" <-
             record["participant_id"] do
        {:cont, {:ok, [participant_id | ids]}}
      else
        _ -> {:halt, {:error, {:invalid_participant_state, key}}}
      end
    end)
    |> unique_inventory_ids(:participant)
  end

  defp collect_participant_identity_ids(objects) do
    with {:ok, state_ids} <- collect_participant_ids(objects),
         {:ok, message_ids} <- collect_message_participant_ids(objects) do
      {:ok, Enum.sort(Enum.uniq(state_ids ++ message_ids))}
    end
  end

  defp collect_message_participant_ids(objects) do
    objects
    |> Enum.filter(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, ids} ->
      with {:ok, messages} <- read_jsonl(key) do
        found =
          Enum.flat_map(messages, fn message ->
            optional_inventory_id(message["participant_id"])
          end)

        {:cont, {:ok, found ++ ids}}
      else
        {:error, reason} ->
          {:halt, {:error, {:message_participant_inventory_failed, key, reason}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      {:error, _} = error -> error
    end
  end

  defp collect_participant_aliases(objects, conversation_id, hierarchy_identity) do
    with {:ok, delivery_aliases} <- collect_delivery_participant_aliases(objects, conversation_id),
         {:ok, hierarchy_aliases} <-
           collect_hierarchy_participant_aliases(objects, hierarchy_identity) do
      merge_participant_aliases(delivery_aliases, hierarchy_aliases)
    end
  end

  defp collect_delivery_participant_aliases(objects, conversation_id) do
    objects
    |> Enum.filter(&delivery_state?(&1.key))
    |> Enum.reduce_while({:ok, %{}}, fn %{key: key}, {:ok, aliases} ->
      with {:ok, record} <- read_json(key),
           participant_id when is_binary(participant_id) and participant_id != "" <-
             record["participant_id"],
           delivery_id when is_binary(delivery_id) and delivery_id != "" <-
             record["delivery_id"],
           {:ok, delivery_participant_id} <-
             delivery_participant_id(
               delivery_id,
               conversation_id,
               participant_id,
               record["participant_actor_type"]
             ) do
        next =
          if delivery_participant_id == participant_id do
            {:ok, aliases}
          else
            case aliases[delivery_participant_id] do
              nil ->
                {:ok, Map.put(aliases, delivery_participant_id, participant_id)}

              ^participant_id ->
                {:ok, aliases}

              other ->
                {:error,
                 {:conflicting_participant_alias, delivery_participant_id, other, participant_id}}
            end
          end

        case next do
          {:ok, next_aliases} ->
            {:cont, {:ok, next_aliases}}

          {:error, reason} ->
            {:halt, {:error, {:participant_alias_inventory_failed, key, reason}}}
        end
      else
        {:error, reason} ->
          {:halt, {:error, {:participant_alias_inventory_failed, key, reason}}}

        _ ->
          {:halt, {:error, {:participant_alias_inventory_failed, key, :invalid_delivery_state}}}
      end
    end)
  end

  defp collect_hierarchy_participant_aliases(objects, hierarchy_identity) do
    with {:ok, participants} <- read_participant_states(objects) do
      Enum.reduce_while(participants, {:ok, %{}}, fn participant, {:ok, aliases} ->
        agent_id = participant["agent_id"]

        if participant["actor_type"] in ["agent", "agent_session"] and is_binary(agent_id) do
          hierarchy_identity.agents
          |> Enum.filter(fn {_source, target} -> target == agent_id end)
          |> Enum.reduce_while({:ok, aliases}, fn {source_agent_id, _target}, {:ok, acc} ->
            case merge_participant_alias(acc, source_agent_id, participant["participant_id"]) do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, aliases}}
        end
      end)
    end
  end

  defp merge_participant_aliases(left, right) do
    Enum.reduce_while(right, {:ok, left}, fn {alias_id, participant_id}, {:ok, acc} ->
      case merge_participant_alias(acc, alias_id, participant_id) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp merge_participant_alias(aliases, alias_id, participant_id) do
    case aliases[alias_id] do
      nil -> {:ok, Map.put(aliases, alias_id, participant_id)}
      ^participant_id -> {:ok, aliases}
      other -> {:error, {:conflicting_participant_alias, alias_id, other, participant_id}}
    end
  end

  defp delivery_participant_id(delivery_id, conversation_id, participant_id, actor_type) do
    with [group_id, ^conversation_id, rest] <- String.split(delivery_id, ":", parts: 3),
         true <- group_id != "" and rest != "" do
      cond do
        String.ends_with?(rest, ":" <> participant_id) ->
          {:ok, participant_id}

        actor_type == "agent" ->
          case rest |> String.split(":") |> List.last() do
            alias_id when is_binary(alias_id) and alias_id != "" -> {:ok, alias_id}
            _ -> {:error, {:invalid_delivery_identity, delivery_id}}
          end

        true ->
          {:error, {:invalid_delivery_identity, delivery_id}}
      end
    else
      _ -> {:error, {:invalid_delivery_identity, delivery_id}}
    end
  end

  defp collect_message_ids(objects) do
    with {:ok, segment_ids} <- collect_segment_message_ids(objects),
         {:ok, delivery_ids} <- collect_delivery_message_ids(objects) do
      {:ok, (segment_ids ++ delivery_ids) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp collect_segment_message_ids(objects) do
    objects
    |> Enum.filter(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, [], []}, fn %{key: key}, {:ok, ids, refs} ->
      with {:ok, messages} <- read_jsonl(key) do
        case Enum.reduce_while(messages, {:ok, ids, refs}, fn
               message, {:ok, id_acc, ref_acc} ->
                 case message["message_id"] do
                   message_id when is_binary(message_id) and message_id != "" ->
                     {:cont,
                      {:ok, [message_id | id_acc],
                       aggregate_reply_message_ids(message, "metadata") ++ ref_acc}}

                   _ ->
                     {:halt, {:error, {:missing_message_id, key, message["seq"]}}}
                 end
             end) do
          {:ok, next_ids, next_refs} -> {:cont, {:ok, next_ids, next_refs}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, ids, refs} ->
        with {:ok, ids} <- unique_inventory_ids({:ok, ids}, :message) do
          {:ok, Enum.sort(Enum.uniq(ids ++ refs))}
        end

      {:error, _} = error ->
        error
    end
  end

  defp collect_delivery_message_ids(objects) do
    objects
    |> Enum.reject(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, ids} ->
      case read_records(key) do
        {:ok, records} ->
          found =
            Enum.flat_map(records, fn
              %{"delivery_id" => delivery_id, "message_id" => message_id} = record
              when is_binary(delivery_id) and delivery_id != "" and is_binary(message_id) and
                     message_id != "" ->
                [message_id | aggregate_reply_message_ids(record, "message_metadata")]

              _ ->
                []
            end)

          {:cont, {:ok, found ++ ids}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_message_inventory_failed, key, reason}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      {:error, _} = error -> error
    end
  end

  defp aggregate_reply_message_ids(record, metadata_field) do
    case record[metadata_field] do
      metadata when is_map(metadata) ->
        [metadata["reply_to_message_id"] | List.wrap(metadata["reply_to_message_ids"])]
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

      _ ->
        []
    end
  end

  defp unique_inventory_ids({:ok, ids}, kind) do
    unique = Enum.uniq(ids)

    if length(ids) == length(unique),
      do: {:ok, Enum.sort(unique)},
      else: {:error, {:duplicate_conversation_scoped_identity, kind}}
  end

  defp unique_inventory_ids({:error, _} = error, _kind), do: error

  defp collect_inventory(results) do
    Enum.reduce_while(results, {:ok, %{}}, fn
      {:ok, {identity, entry}}, {:ok, acc} ->
        if Map.has_key?(acc, identity),
          do: {:halt, {:error, {:duplicate_conversation_owner, identity}}},
          else: {:cont, {:ok, Map.put(acc, identity, entry)}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp merge_additional_refs(inventory, refs) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, inventory}, fn raw, {:ok, acc} ->
      ref = stringify(raw)
      group_id = ref["group_id"]
      conversation_id = ref["conversation_id"]

      cond do
        not Ids.valid_group_id?(group_id) or not is_binary(conversation_id) or
            conversation_id == "" ->
          {:halt, {:error, {:invalid_additional_conversation_reference, raw}}}

        true ->
          identity = {group_id, conversation_id}

          with {:ok, participant_ids} <- normalized_ref_ids(ref["participant_ids"]),
               {:ok, message_ids} <- normalized_ref_ids(ref["message_ids"]),
               {:ok, participant_aliases} <-
                 normalized_ref_aliases(ref["participant_aliases"], participant_ids) do
            entry = %{
              group_id: group_id,
              conversation_id: conversation_id,
              materialized: false,
              participant_ids: participant_ids,
              participant_aliases: participant_aliases,
              message_ids: message_ids
            }

            case acc[identity] do
              nil ->
                {:cont, {:ok, Map.put(acc, identity, entry)}}

              current ->
                case merge_participant_aliases(
                       current.participant_aliases,
                       entry.participant_aliases
                     ) do
                  {:ok, aliases} ->
                    merged = %{
                      current
                      | materialized: current.materialized or entry.materialized,
                        participant_ids:
                          Enum.uniq(current.participant_ids ++ entry.participant_ids),
                        participant_aliases: aliases,
                        message_ids: Enum.uniq(current.message_ids ++ entry.message_ids)
                    }

                    {:cont, {:ok, Map.put(acc, identity, merged)}}

                  {:error, reason} ->
                    {:halt, {:error, {:invalid_additional_conversation_reference, raw, reason}}}
                end
            end
          else
            {:error, reason} ->
              {:halt, {:error, {:invalid_additional_conversation_reference, raw, reason}}}
          end
      end
    end)
  end

  defp merge_additional_refs(_inventory, refs),
    do: {:error, {:invalid_additional_conversation_references, refs}}

  defp canonicalize_inventory(inventory, existing_maps) do
    canonical =
      Enum.reduce(inventory, %{}, fn {_identity, entry}, acc ->
        {:ok, identity, canonical} = canonicalize_inventory_entry(entry, existing_maps)
        Map.update(acc, identity, canonical, &merge_inventory_entries(&1, canonical))
      end)

    {:ok, canonical}
  end

  defp canonicalize_inventory_entry(entry, existing_maps) do
    case ConversationIdMigration.resolve(
           existing_maps,
           entry.group_id,
           entry.conversation_id
         ) do
      {:ok, map} ->
        source_id = get_in(map, ["conversation_id", "source"])

        {:ok, {entry.group_id, source_id},
         %{
           entry
           | conversation_id: source_id,
             participant_ids: source_ids(entry.participant_ids, map["participant_ids"]),
             participant_aliases:
               Map.new(entry.participant_aliases, fn {alias_id, participant_id} ->
                 {[alias_id] |> source_ids(map["participant_ids"]) |> hd(),
                  [participant_id] |> source_ids(map["participant_ids"]) |> hd()}
               end),
             message_ids: source_ids(entry.message_ids, map["message_ids"])
         }}

      {:error, {:conversation_identity_not_mapped, _, _}} ->
        {:ok, {entry.group_id, entry.conversation_id}, entry}
    end
  end

  defp source_ids(ids, identity_map) do
    Enum.map(ids, fn id ->
      if Map.has_key?(identity_map, id) do
        id
      else
        Enum.find_value(identity_map, id, fn {source, target} ->
          if target == id, do: source
        end)
      end
    end)
  end

  defp merge_inventory_entries(left, right) do
    %{
      left
      | materialized: left.materialized or right.materialized,
        participant_ids: Enum.uniq(left.participant_ids ++ right.participant_ids),
        participant_aliases: Map.merge(left.participant_aliases, right.participant_aliases),
        message_ids: Enum.uniq(left.message_ids ++ right.message_ids)
    }
  end

  defp normalized_ref_ids(values) do
    values = List.wrap(values)

    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, values |> Enum.map(&String.trim/1) |> Enum.uniq()}
    else
      {:error, :invalid_scoped_identity_reference}
    end
  end

  defp normalized_ref_aliases(nil, _participant_ids), do: {:ok, %{}}

  defp normalized_ref_aliases(values, participant_ids) when is_map(values) do
    aliases = stringify(values)
    participants = MapSet.new(participant_ids)

    if Enum.all?(aliases, fn {alias_id, participant_id} ->
         alias_id != "" and is_binary(participant_id) and
           MapSet.member?(participants, alias_id) and
           MapSet.member?(participants, participant_id)
       end) do
      {:ok, aliases}
    else
      {:error, :invalid_participant_aliases}
    end
  end

  defp normalized_ref_aliases(_values, _participant_ids),
    do: {:error, :invalid_participant_aliases}

  defp reserve_inventory(inventory) do
    inventory
    |> Map.values()
    |> Enum.sort_by(&{&1.group_id, &1.conversation_id})
    |> parallel_map(fn entry ->
      case ConversationIdMigration.reserve(
             entry.group_id,
             entry.conversation_id,
             entry.materialized,
             entry.participant_ids,
             entry.message_ids,
             entry.participant_aliases
           ) do
        {:ok, _map} -> :ok
        {:error, reason} -> {:error, {:conversation_map_reservation_failed, entry, reason}}
      end
    end)
    |> Enum.reduce_while(:ok, fn
      :ok, :ok -> {:cont, :ok}
      {:error, reason}, :ok -> {:halt, {:error, reason}}
    end)
  end

  defp migrate_aggregates(maps) do
    maps
    |> Map.values()
    |> Enum.filter(& &1["materialized"])
    |> parallel_map(&migrate_aggregate(&1, maps))
    |> Enum.reduce_while({:ok, %{migrated: 0, unchanged: 0}}, fn
      {:ok, status}, {:ok, stats} ->
        {:cont, {:ok, Map.update!(stats, status, &(&1 + 1))}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp migrate_aggregate(map, maps) do
    group_id = map["group_id"]
    source_id = get_in(map, ["conversation_id", "source"])
    target_id = get_in(map, ["conversation_id", "target"])
    source_prefix = Keys.ctl_group_conversation_dir(group_id, source_id)
    target_prefix = Keys.ctl_group_conversation_dir(group_id, target_id)

    with {:ok, source_objects, active_prefix} <- aggregate_objects(source_prefix, target_prefix),
         {:ok, target_objects_before} <- S3.list_all(target_prefix),
         identity_objects <- unique_objects(source_objects ++ target_objects_before),
         {:ok, message_identities} <- migrated_message_identities(identity_objects, map, maps),
         {:ok, delivery_ids} <- delivery_id_map(identity_objects, map, message_identities),
         delivery_hashes <- delivery_hash_map(delivery_ids),
         {:ok, changed?} <-
           rewrite_aggregate_objects(
             source_objects,
             active_prefix,
             target_prefix,
             map,
             maps,
             message_identities,
             delivery_ids,
             delivery_hashes
           ),
         :ok <- materialize_missing_user_participants(target_prefix, map),
         :ok <- rebuild_delivery_status_indexes(target_prefix),
         :ok <- remove_message_pointers(source_prefix, target_prefix),
         {:ok, target_objects} <- S3.list_all(target_prefix),
         {:ok, target_messages} <- read_messages(target_objects),
         :ok <- rebuild_message_pointers(group_id, target_id, target_messages),
         :ok <- rebuild_slack_thread_bindings(group_id, target_id, target_objects),
         :ok <- verify_aggregate_target(map, maps) do
      {:ok, if(changed? or source_id != target_id, do: :migrated, else: :unchanged)}
    else
      {:error, reason} ->
        {:error, {:conversation_aggregate_migration_failed, group_id, source_id, reason}}
    end
  end

  defp aggregate_objects(source_prefix, target_prefix) do
    with {:ok, source_objects} <- S3.list_all(source_prefix) do
      if source_objects == [] and source_prefix != target_prefix do
        with {:ok, target_objects} <- S3.list_all(target_prefix),
             false <- target_objects == [] do
          {:ok, target_objects, target_prefix}
        else
          true -> {:error, :conversation_source_and_target_missing}
          {:error, _} = error -> error
        end
      else
        {:ok, source_objects, source_prefix}
      end
    end
  end

  defp unique_objects(objects), do: Enum.uniq_by(objects, & &1.key)

  defp rebuild_slack_thread_bindings(group_id, conversation_id, objects) do
    with {:ok, participants} <- read_participant_states(objects),
         {:ok, worker_agent_id} <- slack_thread_worker_agent_id(participants) do
      participants
      |> Enum.filter(&slack_thread_participant?/1)
      |> Enum.reduce_while(:ok, fn participant, :ok ->
        payload = participant["payload"] || %{}

        binding = %{
          "version" => 1,
          "provider" => "slack",
          "group_id" => group_id,
          "connect_id" => payload["connect_id"],
          "channel_id" => payload["channel_id"],
          "thread_ts" => payload["thread_ts"],
          "worker_agent_id" => worker_agent_id,
          "conversation_id" => conversation_id,
          "participant_id" => participant["participant_id"],
          "created_at" => participant["created_at"],
          "updated_at" => participant["updated_at"] || participant["created_at"]
        }

        key =
          Keys.ctl_im_slack_thread_binding(
            group_id,
            payload["connect_id"],
            payload["channel_id"],
            payload["thread_ts"]
          )

        case put_exact(key, Jason.encode!(binding)) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:slack_thread_binding_rebuild_failed, key, reason}}}
        end
      end)
    end
  end

  defp read_participant_states(objects) do
    objects
    |> Enum.filter(&Regex.match?(@participant_state_re, &1.key))
    |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, acc} ->
      case read_json(key) do
        {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        {:error, reason} -> {:halt, {:error, {:participant_read_failed, key, reason}}}
      end
    end)
  end

  defp slack_thread_worker_agent_id(participants) do
    if Enum.any?(participants, &slack_thread_participant?/1) do
      case Enum.filter(participants, fn participant ->
             participant["actor_type"] == "agent" and participant["role_label"] == "worker" and
               Ids.valid_agent_id?(participant["agent_id"])
           end) do
        [%{"agent_id" => agent_id}] -> {:ok, agent_id}
        _ -> {:error, :slack_thread_worker_participant_missing}
      end
    else
      {:ok, nil}
    end
  end

  defp slack_thread_participant?(participant) do
    payload = participant["payload"] || %{}

    participant["actor_type"] == "provider" and participant["provider"] == "slack" and
      participant["role_label"] == "slack_thread" and
      Ids.valid_participant_id?(participant["participant_id"]) and
      Enum.all?(~w(connect_id channel_id thread_ts), fn field -> present?(payload[field]) end)
  end

  defp migrated_message_identities(objects, map, maps) do
    objects
    |> Enum.filter(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, %{}}, fn %{key: key}, {:ok, acc} ->
      with {:ok, messages} <- read_jsonl(key),
           {:ok, rewritten} <- rewrite_aggregate_records(messages, map, maps, true, %{}) do
        next =
          Enum.reduce(rewritten, acc, fn message, identities ->
            Map.put(identities, message["message_id"], %{
              "request_identity" => message["request_identity"],
              "request_fingerprint" => message["request_fingerprint"]
            })
          end)

        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, {:message_identity_inventory_failed, key, reason}}}
      end
    end)
    |> case do
      {:ok, identities} -> migrated_delivery_message_identities(objects, map, identities)
      {:error, _} = error -> error
    end
  end

  defp migrated_delivery_message_identities(objects, map, identities) do
    objects
    |> Enum.reject(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, identities}, fn %{key: key}, {:ok, acc} ->
      case read_records(key) do
        {:ok, records} ->
          next =
            Enum.reduce(records, acc, fn record, current ->
              record = rewrite_aggregate_message_refs(record, map)
              target_message_id = rewrite_scoped_id(record["message_id"], map["message_ids"])

              cond do
                not present?(record["delivery_id"]) or not present?(target_message_id) ->
                  current

                Map.has_key?(current, target_message_id) ->
                  current

                true ->
                  source_message_id =
                    reverse_lookup(map["message_ids"], target_message_id) || target_message_id

                  Map.put(current, target_message_id, %{
                    "request_identity" =>
                      record["request_identity"] || "idempotency:" <> source_message_id,
                    "request_fingerprint" =>
                      record["request_fingerprint"] || delivery_message_fingerprint(record)
                  })
              end
            end)

          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_message_identity_inventory_failed, key, reason}}}
      end
    end)
  end

  defp delivery_message_fingerprint(record) do
    %{
      "actor_type" => record["source_actor_type"],
      "content" => record["message_content"],
      "metadata" => record["message_metadata"] || %{}
    }
    |> drop_nil_values()
    |> message_fingerprint()
  end

  defp delivery_id_map(objects, map, message_identities) do
    with {:ok, participant_actor_types} <- participant_actor_types(objects, map) do
      Enum.reduce_while(objects, {:ok, %{}}, fn %{key: key}, {:ok, acc} ->
        case read_records(key) do
          {:ok, records} ->
            Enum.reduce_while(records, {:ok, acc}, fn record, {:ok, ids} ->
              case record["delivery_id"] do
                delivery_id when is_binary(delivery_id) and delivery_id != "" ->
                  with {:ok, target} <-
                         migrated_delivery_id(
                           record,
                           map,
                           message_identities,
                           participant_actor_types
                         ),
                       :ok <- ensure_same_mapping(ids, delivery_id, target) do
                    {:cont,
                     {:ok, ids |> Map.put(delivery_id, target) |> Map.put_new(target, target)}}
                  else
                    {:error, reason} -> {:halt, {:error, reason}}
                  end

                _ ->
                  {:cont, {:ok, ids}}
              end
            end)
            |> case do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, {:delivery_inventory_failed, key, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:delivery_inventory_failed, key, reason}}}
        end
      end)
    end
  end

  defp delivery_hash_map(delivery_ids) do
    Map.new(delivery_ids, fn {source, target} -> {Crypto.hex(source), Crypto.hex(target)} end)
  end

  defp rewrite_aggregate_objects(
         objects,
         active_prefix,
         target_prefix,
         map,
         maps,
         message_identities,
         delivery_ids,
         delivery_hashes
       ) do
    Enum.reduce_while(objects, {:ok, false}, fn %{key: source_key}, {:ok, changed?} ->
      relative = String.replace_prefix(source_key, active_prefix, "")

      cond do
        obsolete_message_pointer?(relative) ->
          {:cont, {:ok, true}}

        delivery_status_index?(source_key) ->
          case delete_if_present(source_key) do
            :ok ->
              {:cont, {:ok, true}}

            {:error, reason} ->
              {:halt, {:error, {:aggregate_object_rewrite_failed, source_key, reason}}}
          end

        true ->
          with {:ok, records} <- read_records(source_key),
               target_relative <- rewrite_relative_key(relative, map, delivery_hashes),
               target_key <- target_prefix <> target_relative,
               {:ok, rewritten_records} <-
                 rewrite_aggregate_records(
                   records,
                   map,
                   maps,
                   Regex.match?(@message_segment_re, target_key),
                   message_identities,
                   delivery_ids
                 ),
               rewritten_records <-
                 drop_persisted_participant_count(target_key, rewritten_records),
               rewritten_body <- encode_records(source_key, rewritten_records),
               :ok <- persist_move(source_key, target_key, rewritten_body) do
            {:cont, {:ok, changed? or source_key != target_key}}
          else
            {:error, reason} ->
              {:halt, {:error, {:aggregate_object_rewrite_failed, source_key, reason}}}
          end
      end
    end)
  end

  defp drop_persisted_participant_count(key, records) do
    if Regex.match?(@conversation_meta_re, key),
      do: Enum.map(records, &Map.delete(&1, "participant_count")),
      else: records
  end

  defp rebuild_delivery_status_indexes(target_prefix) do
    with {:ok, objects} <- S3.list_all(target_prefix),
         :ok <- remove_delivery_status_indexes(objects),
         {:ok, objects} <- S3.list_all(target_prefix) do
      objects
      |> Enum.filter(&delivery_state?(&1.key))
      |> Enum.reduce_while(:ok, fn %{key: key}, :ok ->
        with {:ok, record} <- read_json(key),
             status when status in ["pending", "delivering", "retry_waiting"] <- record["status"],
             index_key <-
               Keys.ctl_group_conversation_participant_delivery_status(
                 record["agent_group_id"],
                 record["conversation_id"],
                 record["participant_id"],
                 status,
                 record["delivery_id"]
               ),
             :ok <-
               put_exact(
                 index_key,
                 Jason.encode!(%{
                   "agent_group_id" => record["agent_group_id"],
                   "conversation_id" => record["conversation_id"],
                   "participant_id" => record["participant_id"],
                   "delivery_id" => record["delivery_id"],
                   "status" => status,
                   "state_key" => key,
                   "updated_at" => record["updated_at"]
                 })
               ) do
          {:cont, :ok}
        else
          status when status not in ["pending", "delivering", "retry_waiting"] ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:delivery_status_index_rebuild_failed, key, reason}}}
        end
      end)
    end
  end

  defp remove_delivery_status_indexes(objects) do
    objects
    |> Enum.filter(&delivery_status_index?(&1.key))
    |> Enum.reduce_while(:ok, fn %{key: key}, :ok ->
      case delete_if_present(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delivery_status_index?(key), do: String.contains?(key, "/delivery_status/")
  defp delivery_state?(key), do: Regex.match?(~r|/deliveries/[^/]+/state\.json$|, key)

  defp materialize_missing_user_participants(target_prefix, map) do
    with {:ok, objects} <- S3.list_all(target_prefix),
         {:ok, participants} <- read_participant_states(objects),
         {:ok, messages} <- read_messages(objects) do
      existing_ids = participants |> Enum.map(& &1["participant_id"]) |> MapSet.new()

      map["participant_ids"]
      |> Map.values()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing_ids, &1))
      |> Enum.reduce_while(:ok, fn participant_id, :ok ->
        participant_messages = Enum.filter(messages, &(&1["participant_id"] == participant_id))

        case user_participant_from_messages(
               map["group_id"],
               get_in(map, ["conversation_id", "target"]),
               participant_id,
               participant_messages
             ) do
          {:ok, participant} ->
            key =
              Keys.ctl_group_conversation_participant_state(
                map["group_id"],
                get_in(map, ["conversation_id", "target"]),
                participant_id
              )

            case put_exact(key, Jason.encode!(participant)) do
              :ok ->
                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, {:participant_materialize_failed, key, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:participant_materialize_failed, participant_id, reason}}}
        end
      end)
    end
  end

  defp user_participant_from_messages(
         group_id,
         conversation_id,
         participant_id,
         messages
       ) do
    user_messages = Enum.filter(messages, &(&1["actor_type"] == "user"))
    user_ids = user_messages |> Enum.map(&(&1["user_id"] || "current")) |> Enum.uniq()

    if messages != [] and length(user_messages) == length(messages) and length(user_ids) == 1 do
      timestamps = Enum.map(messages, & &1["created_at"])

      {:ok,
       %{
         "actor_type" => "user",
         "conversation_id" => conversation_id,
         "participant_id" => participant_id,
         "user_id" => hd(user_ids),
         "role_label" => "user",
         "state" => "active",
         "notification_filter" => %{"messages" => "all", "statuses" => "none"},
         "created_at" => Enum.min(timestamps),
         "updated_at" => Enum.max(timestamps)
       }}
    else
      {:error, {:participant_owner_missing, group_id, conversation_id}}
    end
  end

  defp rewrite_aggregate_records(
         records,
         map,
         maps,
         message_segment?,
         message_identities,
         delivery_ids \\ %{}
       ) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      source_delivery_id = record["delivery_id"]

      case rewrite_global_record(record, map["group_id"], maps, map) do
        {:ok, rewritten, _used_maps} ->
          rewritten = rewrite_aggregate_message_refs(rewritten, map)

          result =
            if message_segment? do
              {:ok, migrate_message_record(rewritten, map)}
            else
              migrate_delivery_record(
                rewritten,
                source_delivery_id,
                message_identities,
                delivery_ids
              )
            end

          case result do
            {:ok, migrated} -> {:cont, {:ok, [migrated | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rewritten} -> {:ok, Enum.reverse(rewritten)}
      {:error, _} = error -> error
    end
  end

  defp migrate_delivery_record(
         %{"delivery_id" => delivery_id} = record,
         source_delivery_id,
         message_identities,
         delivery_ids
       )
       when is_binary(delivery_id) and is_binary(source_delivery_id) do
    message_identity = message_identities[record["message_id"]]

    case delivery_ids[source_delivery_id] || delivery_ids[delivery_id] do
      target when is_binary(target) ->
        {:ok,
         record
         |> Map.put("delivery_id", target)
         |> maybe_put_message_identity(message_identity)}

      _ ->
        {:error, {:delivery_identity_not_mapped, source_delivery_id}}
    end
  end

  defp migrate_delivery_record(record, _source_delivery_id, _message_identities, _delivery_ids),
    do: {:ok, record}

  defp rewrite_aggregate_message_refs(record, map) when is_map(record) do
    record
    |> rewrite_message_metadata_field("metadata", map)
    |> rewrite_message_metadata_field("message_metadata", map)
  end

  defp rewrite_message_metadata_field(record, field, map) do
    case record[field] do
      metadata when is_map(metadata) ->
        metadata =
          metadata
          |> update_present_field("reply_to_message_id", fn id ->
            rewrite_scoped_id(id, map["message_ids"])
          end)
          |> update_present_field("reply_to_message_ids", fn ids ->
            if is_list(ids),
              do: Enum.map(ids, &rewrite_scoped_id(&1, map["message_ids"])),
              else: ids
          end)

        Map.put(record, field, metadata)

      _ ->
        record
    end
  end

  defp update_present_field(map, field, fun) do
    if Map.has_key?(map, field), do: Map.update!(map, field, fun), else: map
  end

  defp maybe_put_message_identity(record, %{} = identity) do
    record
    |> Map.put("request_identity", identity["request_identity"])
    |> Map.put("request_fingerprint", identity["request_fingerprint"])
  end

  defp maybe_put_message_identity(record, _identity), do: record

  defp migrated_delivery_id(record, map, message_identities, participant_actor_types) do
    conversation_id = get_in(map, ["conversation_id", "target"])
    delivery_id = record["delivery_id"]

    with {:ok, source_identity, source_participant_id, participant_id} <-
           delivery_components(delivery_id, record["participant_id"], map),
         actor_type when actor_type in ["agent", "provider"] <-
           record["participant_actor_type"] || participant_actor_types[source_participant_id] ||
             participant_actor_types[participant_id],
         {:ok, delivery_identity} <-
           migrated_delivery_identity(actor_type, source_identity, map, message_identities) do
      {:ok, Enum.join([map["group_id"], conversation_id, delivery_identity, participant_id], ":")}
    else
      nil -> {:error, {:delivery_participant_type_missing, delivery_id}}
      {:error, _} = error -> error
    end
  end

  defp participant_actor_types(objects, map) do
    with {:ok, participants} <- read_participant_states(objects) do
      Enum.reduce_while(participants, {:ok, %{}}, fn participant, {:ok, acc} ->
        source_id = reverse_lookup(map["participant_ids"], participant["participant_id"])
        source_id = source_id || participant["participant_id"]
        target_id = rewrite_scoped_id(source_id, map["participant_ids"])
        actor_type = participant["actor_type"]

        if actor_type in ["agent", "provider"] and is_binary(target_id) do
          {:cont,
           {:ok,
            acc
            |> Map.put(source_id, actor_type)
            |> Map.put(target_id, actor_type)}}
        else
          {:cont, {:ok, acc}}
        end
      end)
    end
  end

  defp delivery_components(delivery_id, record_participant_id, map) do
    conversation_ids =
      [
        get_in(map, ["conversation_id", "source"]),
        get_in(map, ["conversation_id", "target"])
      ]
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)

    participant_ids =
      [
        record_participant_id
        | Map.keys(map["participant_ids"]) ++ Map.values(map["participant_ids"])
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)

    Enum.find_value(conversation_ids, fn candidate_conversation_id ->
      case delivery_identity_rest(delivery_id, candidate_conversation_id) do
        {:ok, rest} ->
          Enum.find_value(participant_ids, fn candidate_participant_id ->
            suffix = ":" <> candidate_participant_id

            if String.ends_with?(rest, suffix) do
              source_identity = String.replace_suffix(rest, suffix, "")

              target_participant_id =
                rewrite_scoped_id(candidate_participant_id, map["participant_ids"])

              if source_identity != "" and Ids.valid_participant_id?(target_participant_id) do
                {:ok, source_identity, candidate_participant_id, target_participant_id}
              end
            end
          end)

        :error ->
          nil
      end
    end)
    |> case do
      nil -> {:error, {:invalid_delivery_identity, delivery_id}}
      result -> result
    end
  end

  defp delivery_identity_rest(delivery_id, conversation_id) do
    case String.split(delivery_id, ":", parts: 3) do
      [group_id, ^conversation_id, rest] when group_id != "" and rest != "" -> {:ok, rest}
      _ -> :error
    end
  end

  defp migrated_delivery_identity("agent", source_identity, map, _message_identities) do
    case rewrite_scoped_id(source_identity, map["message_ids"]) do
      message_id when is_binary(message_id) ->
        if Ids.valid_message_id?(message_id),
          do: {:ok, message_id},
          else: {:error, {:delivery_message_identity_not_mapped, source_identity}}

      _ ->
        {:error, {:delivery_message_identity_not_mapped, source_identity}}
    end
  end

  defp migrated_delivery_identity("provider", source_identity, map, message_identities) do
    target_message_id = rewrite_scoped_id(source_identity, map["message_ids"])

    identity =
      message_identities[target_message_id] ||
        Enum.find_value(message_identities, fn {_message_id, identity} ->
          if identity["request_identity"] == source_identity, do: identity
        end)

    case identity do
      %{"request_identity" => request_identity}
      when is_binary(request_identity) and request_identity != "" ->
        {:ok, request_identity}

      _ ->
        {:error, {:provider_delivery_request_identity_not_mapped, source_identity}}
    end
  end

  defp ensure_same_mapping(map, source, target) do
    case map[source] do
      nil -> :ok
      ^target -> :ok
      other -> {:error, {:conflicting_delivery_identity, source, other, target}}
    end
  end

  defp rewrite_global_record(%MapSet{} = values, group_id, maps, inherited_map) do
    rewritten =
      values
      |> Enum.map(&rewrite_runtime_source_identity(&1, group_id, maps, inherited_map))
      |> MapSet.new()

    {:ok, rewritten, []}
  end

  defp rewrite_global_record(value, group_id, maps, inherited_map) when is_map(value) do
    group_id = map_field(value, "agent_group_id") || map_field(value, "group_id") || group_id
    generated_source_context? = generated_source_context_record?(value)

    with {:ok, conversation_maps} <- resolve_conversation_maps(value, group_id, maps) do
      context_map =
        conversation_maps["conversation_id"] || conversation_maps["parent_conversation_id"] ||
          conversation_maps["router_conversation_id"] || inherited_map

      Enum.reduce_while(value, {:ok, %{}, Map.values(conversation_maps)}, fn
        {key, nested}, {:ok, rewritten, used_maps} ->
          field = to_string(key)

          cond do
            field in @opaque_reference_fields ->
              {:cont, {:ok, Map.put(rewritten, key, nested), used_maps}}

            field in @conversation_ref_fields and is_binary(nested) and nested != "" ->
              map = conversation_maps[field]
              target = get_in(map, ["conversation_id", "target"])
              {:cont, {:ok, Map.put(rewritten, key, target), [map | used_maps]}}

            field in @participant_ref_fields and is_binary(nested) ->
              {:cont,
               {:ok,
                Map.put(
                  rewritten,
                  key,
                  rewrite_scoped_id(nested, id_map(context_map, "participant_ids"))
                ), used_maps}}

            field in @message_ref_fields and is_binary(nested) ->
              message_map =
                if field == "parent_message_id",
                  do: conversation_maps["parent_conversation_id"] || context_map,
                  else: context_map

              {:cont,
               {:ok,
                Map.put(
                  rewritten,
                  key,
                  rewrite_scoped_id(nested, id_map(message_map, "message_ids"))
                ), used_maps}}

            field == "delivery_id" and is_binary(nested) and is_map(context_map) ->
              {:cont,
               {:ok, Map.put(rewritten, key, rewrite_embedded_identity(nested, context_map)),
                used_maps}}

            field in @runtime_source_fields and is_binary(nested) ->
              {:cont,
               {:ok,
                Map.put(
                  rewritten,
                  key,
                  rewrite_runtime_source_identity(nested, group_id, maps, context_map)
                ), used_maps}}

            field in @runtime_source_list_fields and is_list(nested) ->
              values =
                Enum.map(
                  nested,
                  &rewrite_runtime_source_identity(&1, group_id, maps, context_map)
                )

              {:cont, {:ok, Map.put(rewritten, key, values), used_maps}}

            field == "content" and is_binary(nested) and generated_source_context? ->
              {:cont,
               {:ok,
                Map.put(
                  rewritten,
                  key,
                  rewrite_runtime_source_context(nested, group_id, maps, context_map)
                ), used_maps}}

            true ->
              case rewrite_global_record(nested, group_id, maps, context_map) do
                {:ok, rewritten_nested, nested_maps} ->
                  {:cont,
                   {:ok, Map.put(rewritten, key, rewritten_nested), nested_maps ++ used_maps}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
          end
      end)
      |> case do
        {:ok, rewritten, used_maps} ->
          {:ok, rewritten, Enum.uniq(used_maps)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp rewrite_global_record(values, group_id, maps, inherited_map) when is_list(values) do
    Enum.reduce_while(values, {:ok, [], []}, fn value, {:ok, rewritten, used_maps} ->
      case rewrite_global_record(value, group_id, maps, inherited_map) do
        {:ok, rewritten_value, nested_maps} ->
          {:cont, {:ok, [rewritten_value | rewritten], nested_maps ++ used_maps}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rewritten, used_maps} -> {:ok, Enum.reverse(rewritten), Enum.uniq(used_maps)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_global_record(value, group_id, maps, inherited_map) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> rewrite_global_record(group_id, maps, inherited_map)
    |> case do
      {:ok, rewritten, used_maps} -> {:ok, List.to_tuple(rewritten), used_maps}
      {:error, _} = error -> error
    end
  end

  defp rewrite_global_record(value, _group_id, _maps, _inherited_map), do: {:ok, value, []}

  defp resolve_conversation_maps(value, group_id, maps) do
    Enum.reduce_while(@conversation_ref_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case map_field(value, field) do
        conversation_id when is_binary(conversation_id) and conversation_id != "" ->
          if Ids.valid_group_id?(group_id) do
            case ConversationIdMigration.resolve(maps, group_id, conversation_id) do
              {:ok, map} ->
                {:cont, {:ok, Map.put(acc, field, map)}}

              {:error, reason} ->
                {:halt,
                 {:error, {:unmapped_conversation_reference, field, conversation_id, reason}}}
            end
          else
            {:halt, {:error, {:conversation_reference_group_missing, field, conversation_id}}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp id_map(map, field) when is_map(map), do: map[field] || %{}
  defp id_map(_map, _field), do: %{}

  defp reference_group_id(record, key) do
    map_field(record, "agent_group_id") || map_field(record, "group_id") ||
      nested_map_field(record, "payload", "agent_group_id") ||
      nested_map_field(record, "payload", "group_id") || path_group_id(key)
  end

  defp migrate_message_record(%{"seq" => seq, "message_id" => message_id} = message, map)
       when is_integer(seq) and is_binary(message_id) do
    source_id = reverse_lookup(map["message_ids"], message_id) || message_id

    request_identity =
      message["request_identity"] ||
        cond do
          present?(message["idempotency_key"]) ->
            "idempotency:" <> message["idempotency_key"]

          present?(message["source_message_id"]) ->
            "provider_message:" <> message["source_message_id"]

          present?(message["client_request_id"]) ->
            "client_request:" <> message["client_request_id"]

          true ->
            legacy_request_identity(message, source_id)
        end

    message = Map.put(message, "request_identity", request_identity)

    Map.put(message, "request_fingerprint", message_fingerprint(message))
  end

  defp migrate_message_record(record, _map), do: record

  defp legacy_request_identity(message, source_id) do
    cond do
      message["actor_type"] in ["provider_user", "provider_system"] ->
        "provider_message:" <> source_id

      String.starts_with?(source_id, "msg-") ->
        "legacy_message:" <> source_id

      true ->
        "client_request:" <> source_id
    end
  end

  defp rewrite_relative_key(relative, map, delivery_hashes) do
    relative
    |> replace_hashes(map["participant_ids"])
    |> replace_hashes(map["message_ids"])
    |> replace_hash_map(delivery_hashes)
  end

  defp replace_hashes(path, id_map) do
    Enum.reduce(id_map || %{}, path, fn {source, target}, acc ->
      String.replace(acc, Crypto.hex(source), Crypto.hex(target))
    end)
  end

  defp replace_hash_map(path, hashes) do
    Enum.reduce(hashes, path, fn {source_hash, target_hash}, acc ->
      String.replace(acc, source_hash, target_hash)
    end)
  end

  defp rebuild_message_pointers(group_id, conversation_id, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      pointer = message_pointer(message)
      identity_key = message_identity_key(group_id, conversation_id, message)
      request_key = message_request_key(group_id, conversation_id, message)

      with :ok <- put_exact(identity_key, Jason.encode!(pointer)),
           :ok <- put_exact(request_key, Jason.encode!(pointer)) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:message_pointer_rebuild_failed, reason}}}
      end
    end)
  end

  defp message_pointer(message) do
    %{
      "message_id" => message["message_id"],
      "request_identity" => message["request_identity"],
      "request_fingerprint" => message["request_fingerprint"],
      "seq" => message["seq"],
      "segment_id" => message["segment_id"],
      "created_at" => message["created_at"]
    }
    |> drop_nil_values()
  end

  defp message_identity_key(group_id, conversation_id, message),
    do:
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        Crypto.hex(message["message_id"])
      )

  defp message_request_key(group_id, conversation_id, message),
    do:
      Keys.ctl_group_conversation_message_idempotency(
        group_id,
        conversation_id,
        Crypto.hex(message["request_identity"])
      )

  defp remove_message_pointers(source_prefix, target_prefix) do
    [source_prefix, target_prefix]
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn prefix, :ok ->
      with {:ok, objects} <- S3.list_all(prefix) do
        objects
        |> Enum.filter(fn %{key: key} ->
          relative = String.replace_prefix(key, prefix, "")
          obsolete_message_pointer?(relative)
        end)
        |> Enum.reduce_while(:ok, fn %{key: key}, :ok ->
          case S3.delete(key) do
            :ok -> {:cont, :ok}
            {:error, :not_found} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp obsolete_message_pointer?(relative),
    do:
      String.starts_with?(relative, "idempotency/messages/") or
        String.starts_with?(relative, "messages/by_id/")

  defp rewrite_references(maps) do
    @reference_prefixes
    |> Enum.flat_map(fn prefix ->
      case S3.list_all(prefix) do
        {:ok, objects} -> Enum.filter(objects, &structured_reference?(&1.key))
        {:error, reason} -> throw({:reference_list_failed, prefix, reason})
      end
    end)
    |> parallel_map(&rewrite_reference_object(&1, maps))
    |> Enum.reduce_while({:ok, %{migrated: 0, unchanged: 0}}, fn
      {:ok, status}, {:ok, stats} ->
        {:cont, {:ok, Map.update!(stats, status, &(&1 + 1))}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  catch
    reason -> {:error, reason}
  end

  defp rewrite_reference_object(%{key: key}, maps) do
    with {:ok, %{body: original_body}} <- S3.get(key),
         {:ok, record} <- decode_structured(key, original_body),
         {:ok, rewritten, used_maps} <- rewrite_reference_record(key, record, maps),
         target_key <- rewrite_reference_key(key, record, rewritten, used_maps),
         body <- encode_structured(key, rewritten, original_body),
         :ok <- persist_move(key, target_key, body) do
      {:ok, if(key == target_key and record == rewritten, do: :unchanged, else: :migrated)}
    else
      {:error, reason} -> {:error, {:conversation_reference_rewrite_failed, key, reason}}
    end
  end

  defp rewrite_reference_record("agents/" <> _rest = key, record, maps) do
    with {:ok, rewritten} <- rewrite_runtime_record(record, path_group_id(key), maps) do
      {:ok, rewritten, []}
    end
  end

  defp rewrite_reference_record(key, record, maps),
    do: rewrite_global_record(record, reference_group_id(record, key), maps, nil)

  defp rewrite_reference_key(key, _record, rewritten, used_maps) do
    cond do
      agent_inbox_kind(key) != nil ->
        rewrite_agent_inbox_key(key, rewritten)

      String.starts_with?(key, "ctl/conversation_pins/") and
          String.ends_with?(key, "/aggregate.json") ->
        Keys.ctl_conversation_pins_aggregate(rewritten["agent_group_id"])

      String.starts_with?(key, "ctl/conversation_pins/") ->
        Keys.ctl_conversation_pin(rewritten["agent_group_id"], rewritten["conversation_id"])

      String.starts_with?(key, "ctl/group_conversation_delivery_wakeups/") ->
        Keys.ctl_group_conversation_participant_delivery_wakeup(
          rewritten["agent_group_id"],
          rewritten["conversation_id"],
          rewritten["participant_id"]
        )

      true ->
        Enum.reduce(used_maps, key, fn map, acc ->
          acc
          |> String.replace(
            Crypto.hex(get_in(map, ["conversation_id", "source"])),
            Crypto.hex(get_in(map, ["conversation_id", "target"]))
          )
          |> replace_hashes(map["participant_ids"])
          |> replace_hashes(map["message_ids"])
        end)
    end
  end

  defp rebuild_conversation_list(maps) do
    group_ids = maps |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    Enum.reduce_while(group_ids, :ok, fn group_id, :ok ->
      prefix = Keys.ctl_group_conversation_list_prefix(group_id)

      with :ok <- delete_prefix(prefix),
           {:ok, objects} <- S3.list_all(Keys.ctl_group_conversations_prefix(group_id)) do
        objects
        |> Enum.filter(&Regex.match?(@conversation_meta_re, &1.key))
        |> Enum.reduce_while(:ok, fn %{key: key}, :ok ->
          with {:ok, meta} <- read_json(key),
               true <- Ids.valid_conversation_id?(meta["conversation_id"]),
               sort_key <- conversation_sort_key(meta["updated_at"] || meta["created_at"] || 0),
               index_key <-
                 Keys.ctl_group_conversation_list_entry(
                   group_id,
                   sort_key,
                   meta["conversation_id"]
                 ),
               :ok <-
                 put_exact(
                   index_key,
                   Jason.encode!(%{
                     "agent_group_id" => group_id,
                     "conversation_id" => meta["conversation_id"],
                     "updated_at" => meta["updated_at"] || meta["created_at"] || 0
                   })
                 ) do
            {:cont, :ok}
          else
            false -> {:halt, {:error, {:invalid_migrated_conversation, key}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp verify_aggregate_targets(maps) do
    maps
    |> Enum.filter(fn {_identity, map} -> map["materialized"] end)
    |> Enum.reduce_while(:ok, fn {_identity, map}, :ok ->
      case verify_aggregate_target(map, maps) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_aggregate_target(map, maps) do
    group_id = map["group_id"]
    conversation_id = get_in(map, ["conversation_id", "target"])
    prefix = Keys.ctl_group_conversation_dir(group_id, conversation_id)

    with {:ok, meta} <- read_json(Keys.ctl_group_conversation(group_id, conversation_id)),
         true <- meta["conversation_id"] == conversation_id,
         {:ok, objects} <- S3.list_all(prefix),
         :ok <- verify_participant_targets(objects, map),
         {:ok, messages} <- verify_message_targets(objects, map),
         false <- Map.has_key?(meta, "participant_count"),
         true <- meta["message_count"] == length(messages),
         :ok <- verify_message_pointers(group_id, conversation_id, messages),
         {:ok, message_identities} <- migrated_message_identities(objects, map, maps),
         {:ok, delivery_ids} <- delivery_id_map(objects, map, message_identities),
         :ok <- verify_aggregate_records(objects, map, maps, message_identities, delivery_ids),
         :ok <- verify_target_paths(objects, prefix, map) do
      :ok
    else
      false ->
        {:error, {:conversation_target_body_mismatch, group_id, conversation_id}}

      {:error, reason} ->
        {:error, {:conversation_target_verify_failed, group_id, conversation_id, reason}}
    end
  end

  defp verify_participant_targets(objects, map) do
    targets = map["participant_ids"] |> Map.values() |> MapSet.new()

    with {:ok, actual} <- collect_participant_ids(objects),
         true <- MapSet.new(actual) == targets do
      :ok
    else
      false -> {:error, :participant_target_set_mismatch}
      {:error, _} = error -> error
    end
  end

  defp verify_message_targets(objects, map) do
    targets = map["message_ids"] |> Map.values() |> MapSet.new()

    with {:ok, actual} <- collect_message_ids(objects),
         true <- MapSet.subset?(MapSet.new(actual), targets),
         {:ok, messages} <- read_messages(objects) do
      {:ok, messages}
    else
      false -> {:error, :message_target_set_mismatch}
      {:error, _} = error -> error
    end
  end

  defp read_messages(objects) do
    objects
    |> Enum.filter(&Regex.match?(@message_segment_re, &1.key))
    |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, messages} ->
      case read_jsonl(key) do
        {:ok, records} ->
          segment = segment_id(key)
          {:cont, {:ok, messages ++ Enum.map(records, &Map.put(&1, "segment_id", segment))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_message_pointers(group_id, conversation_id, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      body = Jason.encode!(message_pointer(message))

      with :ok <- verify_body(message_identity_key(group_id, conversation_id, message), body),
           :ok <- verify_body(message_request_key(group_id, conversation_id, message), body) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:message_pointer_verify_failed, reason}}}
      end
    end)
  end

  defp verify_aggregate_records(objects, map, maps, message_identities, delivery_ids) do
    Enum.reduce_while(objects, :ok, fn %{key: key}, :ok ->
      with {:ok, records} <- read_records(key) do
        case rewrite_aggregate_records(
               records,
               map,
               maps,
               Regex.match?(@message_segment_re, key),
               message_identities,
               delivery_ids
             ) do
          {:ok, ^records} -> :ok
          {:ok, _rewritten} -> {:error, {:legacy_aggregate_reference_remains, key}}
          {:error, reason} -> {:error, {:aggregate_reference_verify_failed, key, reason}}
        end
      else
        {:error, reason} -> {:error, reason}
      end
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_target_paths(objects, prefix, map) do
    old_hashes =
      [map["participant_ids"], map["message_ids"]]
      |> Enum.flat_map(&Enum.to_list/1)
      |> Enum.reject(fn {source, target} -> source == target end)
      |> Enum.map(fn {source, _target} -> Crypto.hex(source) end)

    if Enum.any?(objects, fn %{key: key} ->
         relative = String.replace_prefix(key, prefix, "")
         Enum.any?(old_hashes, &String.contains?(relative, &1))
       end),
       do: {:error, :legacy_aggregate_path_remains},
       else: :ok
  end

  defp verify_no_legacy_aggregate_sources(maps) do
    maps
    |> Enum.filter(fn {_identity, map} -> map["materialized"] end)
    |> Enum.reduce_while(:ok, fn {_identity, map}, :ok ->
      source = get_in(map, ["conversation_id", "source"])
      target = get_in(map, ["conversation_id", "target"])

      if source == target do
        {:cont, :ok}
      else
        case S3.list_all(Keys.ctl_group_conversation_dir(map["group_id"], source)) do
          {:ok, []} -> {:cont, :ok}
          {:ok, _objects} -> {:halt, {:error, {:legacy_conversation_source_remains, source}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp cleanup_legacy_segmented_storage(maps) do
    with :ok <-
           cleanup_legacy_owned_objects(
             Keys.ctl_group_conversations_prefix(),
             @legacy_conversation_re,
             maps
           ),
         :ok <- cleanup_legacy_dispatch_objects(maps),
         :ok <- delete_prefix(@legacy_segmented_marker_prefix) do
      :ok
    end
  end

  defp cleanup_legacy_dispatch_objects(maps) do
    with {:ok, objects} <- S3.list_all(@legacy_dispatch_prefix) do
      objects
      |> Enum.flat_map(fn %{key: key} = object ->
        case Regex.run(@legacy_dispatch_re, key) do
          [_, group_id, conversation_id] -> [{object, group_id, conversation_id}]
          _ -> []
        end
      end)
      |> parallel_map(fn {%{key: key}, path_group_id, path_conversation_id} ->
        with {:ok, record} <- read_json(key),
             :ok <-
               verify_legacy_dispatch_record(
                 record,
                 path_group_id,
                 path_conversation_id,
                 maps
               ),
             :ok <- delete_if_present(key) do
          :ok
        else
          {:error, reason} -> {:error, {:legacy_conversation_storage_cleanup_failed, key, reason}}
        end
      end)
      |> Enum.reduce_while(:ok, fn
        :ok, :ok -> {:cont, :ok}
        {:error, reason}, :ok -> {:halt, {:error, reason}}
      end)
    end
  end

  defp verify_legacy_dispatch_record(record, path_group_id, path_conversation_id, maps) do
    if present?(record["message_id"]),
      do: verify_terminal_legacy_dispatch(record, maps),
      else: verify_legacy_object_migrated(path_group_id, path_conversation_id, maps)
  end

  defp verify_terminal_legacy_dispatch(record, maps) do
    group_id = record["agent_group_id"] || record["group_id"]
    conversation_id = record["conversation_id"]
    message_id = record["message_id"]

    with "delivered" <- record["status"],
         {:ok, _map} <- ConversationIdMigration.resolve(maps, group_id, conversation_id),
         {:ok, _target_message_id} <-
           ConversationIdMigration.message_target(maps, group_id, conversation_id, message_id),
         :ok <- verify_legacy_dispatch_participant_refs(record, maps, group_id, conversation_id) do
      :ok
    else
      status when status != "delivered" -> {:error, {:legacy_dispatch_not_terminal, status}}
      {:error, _} = error -> error
    end
  end

  defp verify_legacy_dispatch_participant_refs(record, maps, group_id, conversation_id) do
    @participant_ref_fields
    |> Enum.flat_map(&optional_inventory_id(record[&1]))
    |> Enum.reduce_while(:ok, fn participant_id, :ok ->
      case ConversationIdMigration.participant_target(
             maps,
             group_id,
             conversation_id,
             participant_id
           ) do
        {:ok, _target} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp cleanup_legacy_owned_objects(prefix, pattern, maps) do
    with {:ok, objects} <- S3.list_all(prefix) do
      objects
      |> Enum.flat_map(fn %{key: key} = object ->
        case Regex.run(pattern, key) do
          [_, group_id, conversation_id] -> [{object, group_id, conversation_id}]
          _ -> []
        end
      end)
      |> parallel_map(fn {%{key: key}, group_id, conversation_id} ->
        with :ok <- verify_legacy_object_migrated(group_id, conversation_id, maps),
             :ok <- delete_if_present(key) do
          :ok
        else
          {:error, reason} -> {:error, {:legacy_conversation_storage_cleanup_failed, key, reason}}
        end
      end)
      |> Enum.reduce_while(:ok, fn
        :ok, :ok -> {:cont, :ok}
        {:error, reason}, :ok -> {:halt, {:error, reason}}
      end)
    end
  end

  defp verify_legacy_object_migrated(group_id, conversation_id, maps) do
    case ConversationIdMigration.resolve(maps, group_id, conversation_id) do
      {:ok, %{"materialized" => true}} -> :ok
      {:ok, _map} -> verify_legacy_segmented_completion(group_id, conversation_id)
      {:error, _reason} -> verify_legacy_segmented_completion(group_id, conversation_id)
    end
  end

  defp verify_legacy_segmented_completion(group_id, conversation_id) do
    source_key = "ctl/group_conversations/#{group_id}/#{conversation_id}.json"
    marker_key = @legacy_segmented_marker_prefix <> Crypto.hex(source_key) <> ".json"

    with {:ok, marker} <- read_json(marker_key),
         true <- marker["name"] == "conversation_storage_segmented",
         true <- marker["source_key"] == source_key,
         true <- marker["agent_group_id"] == group_id,
         true <- marker["conversation_id"] == conversation_id do
      :ok
    else
      false -> {:error, :invalid_legacy_segmented_completion}
      {:error, reason} -> {:error, {:legacy_segmented_completion_missing, reason}}
    end
  end

  defp verify_legacy_segmented_storage_removed do
    with {:ok, conversation_objects} <- S3.list_all(Keys.ctl_group_conversations_prefix()),
         false <- Enum.any?(conversation_objects, &Regex.match?(@legacy_conversation_re, &1.key)),
         {:ok, dispatch_objects} <- S3.list_all(@legacy_dispatch_prefix),
         false <- Enum.any?(dispatch_objects, &Regex.match?(@legacy_dispatch_re, &1.key)),
         {:ok, []} <- S3.list_all(@legacy_segmented_marker_prefix) do
      :ok
    else
      true -> {:error, :legacy_conversation_storage_remains}
      {:ok, _objects} -> {:error, :legacy_conversation_storage_marker_remains}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_reference_objects(maps) do
    @reference_prefixes
    |> Enum.flat_map(fn prefix ->
      case S3.list_all(prefix) do
        {:ok, objects} -> Enum.filter(objects, &structured_reference?(&1.key))
        {:error, reason} -> throw({:reference_verify_list_failed, prefix, reason})
      end
    end)
    |> parallel_map(&verify_reference_object(&1, maps))
    |> Enum.reduce_while(:ok, fn
      :ok, :ok -> {:cont, :ok}
      {:error, _reason} = error, :ok -> {:halt, error}
    end)
  catch
    reason -> {:error, reason}
  end

  defp verify_reference_object(%{key: key}, maps) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- decode_structured(key, body),
         {:ok, rewritten, used_maps} <- rewrite_reference_record(key, record, maps) do
      target_key = rewrite_reference_key(key, record, rewritten, used_maps)

      if rewritten == record and target_key == key and reference_record_canonical?(key, record),
        do: :ok,
        else: {:error, {:legacy_conversation_reference_remains, key}}
    else
      {:error, reason} -> {:error, {:conversation_reference_verify_failed, key, reason}}
    end
  end

  defp verify_conversation_lists(maps) do
    maps
    |> Enum.filter(fn {_identity, map} -> map["materialized"] end)
    |> Enum.group_by(fn {_identity, map} -> map["group_id"] end)
    |> Enum.reduce_while(:ok, fn {group_id, grouped}, :ok ->
      expected =
        grouped
        |> Enum.map(fn {_identity, map} -> get_in(map, ["conversation_id", "target"]) end)
        |> MapSet.new()

      with {:ok, objects} <- S3.list_all(Keys.ctl_group_conversation_list_prefix(group_id)),
           {:ok, actual} <- collect_list_conversation_ids(objects),
           true <- actual == expected do
        {:cont, :ok}
      else
        false ->
          {:halt, {:error, {:conversation_list_mismatch, group_id}}}

        {:error, reason} ->
          {:halt, {:error, {:conversation_list_verify_failed, group_id, reason}}}
      end
    end)
  end

  defp collect_list_conversation_ids(objects) do
    Enum.reduce_while(objects, {:ok, MapSet.new()}, fn %{key: key}, {:ok, ids} ->
      with {:ok, %{"conversation_id" => conversation_id}} <- read_json(key),
           true <- Ids.valid_conversation_id?(conversation_id) do
        {:cont, {:ok, MapSet.put(ids, conversation_id)}}
      else
        false -> {:halt, {:error, {:invalid_conversation_list_entry, key}}}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp persist_move(source_key, target_key, body) do
    case S3.get(source_key) do
      {:ok, %{body: current_body, etag: etag}} when source_key == target_key ->
        if current_body == body do
          :ok
        else
          case S3.put(source_key, body, if_match: etag) do
            {:ok, _} -> :ok
            {:error, {:ambiguous, _}} -> verify_body(source_key, body)
            {:error, reason} -> {:error, {:source_rewrite_failed, source_key, reason}}
          end
        end

      {:ok, %{etag: etag}} ->
        with :ok <- put_exact(target_key, body),
             :ok <- delete_source(source_key, target_key, etag) do
          :ok
        end

      {:error, :not_found} ->
        verify_body(target_key, body)

      {:error, reason} ->
        {:error, {:source_read_failed, source_key, reason}}
    end
  end

  defp put_exact(key, body) do
    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> verify_body(key, body)
      {:error, {:ambiguous, _}} -> verify_body(key, body)
      {:error, reason} -> {:error, {:target_write_failed, key, reason}}
    end
  end

  defp verify_body(key, expected) do
    case S3.get(key) do
      {:ok, %{body: ^expected}} -> :ok
      {:ok, _} -> {:error, {:target_collision, key}}
      {:error, reason} -> {:error, {:target_verify_failed, key, reason}}
    end
  end

  defp delete_source(source, target, etag) do
    case S3.delete(source, if_match: etag) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, {:ambiguous, _}} ->
        case S3.get(source) do
          {:error, :not_found} -> :ok
          {:ok, _} -> {:error, {:source_delete_ambiguous, source, target}}
          {:error, reason} -> {:error, {:source_delete_verify_failed, source, reason}}
        end

      {:error, reason} ->
        {:error, {:source_delete_failed, source, reason}}
    end
  end

  defp delete_if_present(key) do
    case S3.delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_records(key) do
    if String.ends_with?(key, ".jsonl") do
      read_jsonl(key)
    else
      case read_json(key) do
        {:ok, record} -> {:ok, [record]}
        {:error, _} = error -> error
      end
    end
  end

  defp encode_records(key, records) do
    if String.ends_with?(key, ".jsonl") do
      Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    else
      records |> List.first() |> Jason.encode!()
    end
  end

  defp structured_reference?(key) do
    supported? =
      String.ends_with?(key, ".json") or String.ends_with?(key, ".jsonl") or
        String.ends_with?(key, ".etf.zst")

    supported? and (not String.starts_with?(key, "agents/") or agent_runtime_reference?(key))
  end

  defp agent_runtime_reference?(key) do
    String.contains?(key, "/internal_runtime/sessions/") or
      String.contains?(key, "/external_runtime/sessions/") or
      String.contains?(key, "/inbox/") or String.contains?(key, "/dead_letter/")
  end

  defp rewrite_agent_inbox_key(key, rewritten) do
    with ["agents", agent_id, kind, _file] <- String.split(key, "/"),
         source_id when is_binary(source_id) and source_id != "" <-
           map_field(rewritten, "source_message_id") do
      # Historical staged-protocol layout (retired from Keys, A2 §3.4): this
      # migration transforms pre-cutover buckets, so it keeps the literals.
      case kind do
        "inbox" -> "agents/#{agent_id}/inbox/#{Crypto.hex(source_id)}.json"
        "dead_letter" -> "agents/#{agent_id}/dead_letter/#{Crypto.hex(source_id)}.json"
      end
    else
      _ -> key
    end
  end

  defp agent_inbox_kind(key) do
    cond do
      String.contains?(key, "/inbox/") -> :inbox
      String.contains?(key, "/dead_letter/") -> :dead_letter
      true -> nil
    end
  end

  defp decode_structured(key, body) do
    cond do
      String.ends_with?(key, ".json") -> Jason.decode(body)
      String.ends_with?(key, ".jsonl") -> decode_jsonl(body)
      String.ends_with?(key, ".etf.zst") -> decode_snapshot(body, key)
    end
  end

  defp encode_structured(key, value, original_body) do
    cond do
      String.ends_with?(key, ".json") -> Jason.encode!(value)
      String.ends_with?(key, ".jsonl") -> encode_jsonl(value, original_body)
      String.ends_with?(key, ".etf.zst") -> Codec.encode_snapshot(value)
    end
  end

  defp decode_jsonl(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _} = error -> error
    end
  end

  defp encode_jsonl(records, original_body) do
    body = Enum.map_join(records, "\n", &Jason.encode!/1)
    if String.ends_with?(original_body, "\n"), do: body <> "\n", else: body
  end

  defp decode_snapshot(body, key) do
    try do
      {:ok, Codec.decode_snapshot(body)}
    rescue
      error -> {:error, {:snapshot_decode_failed, key, Exception.message(error)}}
    end
  end

  defp read_json(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_json_record}
    end
  end

  defp read_jsonl(key) do
    with {:ok, %{body: body}} <- S3.get(key) do
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, record} when is_map(record) -> {:cont, {:ok, [record | acc]}}
          _ -> {:halt, {:error, :invalid_jsonl_record}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, _} = error -> error
      end
    end
  end

  defp rewrite_scoped_id(value, id_map) when is_binary(value),
    do: Map.get(id_map || %{}, value, value)

  defp rewrite_scoped_id(value, _id_map), do: value

  defp rewrite_runtime_source_identity(value, group_id, maps, _context_map)
       when is_binary(value) do
    case String.trim_leading(value, "groupconv:") do
      ^value ->
        value

      rest ->
        with {:ok, map, after_conversation} <- runtime_source_conversation(rest, group_id, maps),
             {:ok, message_id, after_message} <-
               mapped_identity_prefix(after_conversation, map["message_ids"]),
             {:ok, participant_id, suffix} <-
               mapped_identity_prefix(after_message, map["participant_ids"]) do
          Enum.join(
            [
              "groupconv",
              get_in(map, ["conversation_id", "target"]),
              message_id,
              participant_id
            ],
            ":"
          ) <> if(suffix == "", do: "", else: ":" <> suffix)
        else
          _ -> value
        end
    end
  end

  defp rewrite_runtime_source_identity(value, _group_id, _maps, _context_map), do: value

  defp runtime_source_conversation(rest, group_id, maps) do
    maps
    |> Enum.filter(fn {{candidate_group_id, _source_id}, _map} ->
      candidate_group_id == group_id
    end)
    |> Enum.sort_by(
      fn {_identity, map} ->
        max(
          byte_size(get_in(map, ["conversation_id", "source"])),
          byte_size(get_in(map, ["conversation_id", "target"]))
        )
      end,
      :desc
    )
    |> Enum.find_value(fn {_identity, map} ->
      ids = [
        get_in(map, ["conversation_id", "source"]),
        get_in(map, ["conversation_id", "target"])
      ]

      Enum.find_value(ids, fn id ->
        prefix = id <> ":"

        if String.starts_with?(rest, prefix),
          do: {:ok, map, String.replace_prefix(rest, prefix, "")}
      end)
    end)
    |> case do
      nil -> {:error, :conversation_not_mapped}
      found -> found
    end
  end

  defp mapped_identity_prefix(rest, identity_map) do
    (identity_map || %{})
    |> Enum.flat_map(fn {source, target} -> [{source, target}, {target, target}] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {candidate, _target} -> byte_size(candidate) end, :desc)
    |> Enum.find_value(fn {candidate, target} ->
      cond do
        rest == candidate ->
          {:ok, target, ""}

        String.starts_with?(rest, candidate <> ":") ->
          {:ok, target, String.replace_prefix(rest, candidate <> ":", "")}

        true ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :scoped_identity_not_mapped}
      found -> found
    end
  end

  defp rewrite_runtime_source_context(value, group_id, maps, _context_map)
       when is_binary(value) do
    if is_map(parse_source_context(value)) do
      lines = String.split(value, "\n")
      conversation_id = source_context_value(lines, "conversation_id")
      parent_conversation_id = source_context_value(lines, "parent_conversation_id")

      conversation_map = resolve_optional_map(maps, group_id, conversation_id)
      parent_map = resolve_optional_map(maps, group_id, parent_conversation_id)

      lines
      |> Enum.map(&rewrite_source_context_line(&1, conversation_map, parent_map))
      |> Enum.join("\n")
    else
      value
    end
  end

  defp rewrite_runtime_record(%MapSet{} = values, group_id, maps) do
    {:ok,
     values
     |> Enum.map(&rewrite_runtime_source_identity(&1, group_id, maps, nil))
     |> MapSet.new()}
  end

  defp rewrite_runtime_record(value, group_id, maps) when is_struct(value) do
    module = value.__struct__

    with {:ok, rewritten} <- rewrite_runtime_record(Map.from_struct(value), group_id, maps) do
      {:ok, struct(module, rewritten)}
    end
  end

  defp rewrite_runtime_record(value, group_id, maps) when is_map(value) do
    generated_source_context? = generated_source_context_record?(value)

    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, rewritten} ->
      field = to_string(key)

      cond do
        field in @opaque_reference_fields ->
          {:cont, {:ok, Map.put(rewritten, key, nested)}}

        field in @runtime_source_fields and is_binary(nested) ->
          {:cont,
           {:ok,
            Map.put(
              rewritten,
              key,
              rewrite_runtime_source_identity(nested, group_id, maps, nil)
            )}}

        field in @runtime_source_list_fields and is_list(nested) ->
          values = Enum.map(nested, &rewrite_runtime_source_identity(&1, group_id, maps, nil))
          {:cont, {:ok, Map.put(rewritten, key, values)}}

        field == "content" and is_binary(nested) and generated_source_context? ->
          {:cont,
           {:ok,
            Map.put(
              rewritten,
              key,
              rewrite_runtime_source_context(nested, group_id, maps, nil)
            )}}

        true ->
          case rewrite_runtime_record(nested, group_id, maps) do
            {:ok, rewritten_nested} ->
              {:cont, {:ok, Map.put(rewritten, key, rewritten_nested)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp rewrite_runtime_record(values, group_id, maps) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, rewritten} ->
      case rewrite_runtime_record(value, group_id, maps) do
        {:ok, rewritten_value} -> {:cont, {:ok, [rewritten_value | rewritten]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rewritten} -> {:ok, Enum.reverse(rewritten)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_runtime_record(value, group_id, maps) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> rewrite_runtime_record(group_id, maps)
    |> case do
      {:ok, rewritten} -> {:ok, List.to_tuple(rewritten)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_runtime_record(value, _group_id, _maps), do: {:ok, value}

  defp generated_source_context_record?(value) when is_map(value) do
    role = map_field(value, "role") |> to_string()
    source_message_id = map_field(value, "source_message_id")

    role == "summary" and is_binary(source_message_id) and
      String.ends_with?(source_message_id, ":source-context") and
      is_map(parse_source_context(map_field(value, "content")))
  end

  defp parse_source_context(value) when is_binary(value) do
    if String.starts_with?(String.trim_leading(value), "Inbound message source:") do
      ~r/^\s*-\s*([a-z_]+):\s*(.*)$/m
      |> Regex.scan(value)
      |> Map.new(fn [_line, key, field_value] -> {key, String.trim(field_value)} end)
    end
  end

  defp parse_source_context(_value), do: nil

  defp source_context_value(lines, field) do
    prefix = "- " <> field <> ": "

    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  defp resolve_optional_map(_maps, _group_id, nil), do: nil

  defp resolve_optional_map(maps, group_id, conversation_id) do
    case ConversationIdMigration.resolve(maps, group_id, conversation_id) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  defp rewrite_source_context_line(line, conversation_map, parent_map) do
    case String.split(line, ": ", parts: 2) do
      ["- conversation_id", _value] when is_map(conversation_map) ->
        "- conversation_id: " <> get_in(conversation_map, ["conversation_id", "target"])

      ["- parent_conversation_id", _value] when is_map(parent_map) ->
        "- parent_conversation_id: " <> get_in(parent_map, ["conversation_id", "target"])

      ["- message_id", value] when is_map(conversation_map) ->
        "- message_id: " <> rewrite_scoped_id(value, conversation_map["message_ids"])

      ["- parent_message_id", value] when is_map(parent_map) ->
        "- parent_message_id: " <> rewrite_scoped_id(value, parent_map["message_ids"])

      [field, value]
      when field in ["- participant_id", "- from_participant_id"] and
             is_map(conversation_map) ->
        field <> ": " <> rewrite_scoped_id(value, conversation_map["participant_ids"])

      _ ->
        line
    end
  end

  defp reference_record_canonical?("agents/" <> _rest, value),
    do: runtime_record_canonical?(value)

  defp reference_record_canonical?(_key, _value), do: true

  defp runtime_record_canonical?(%MapSet{} = values),
    do: Enum.all?(values, &runtime_source_identity_canonical?/1)

  defp runtime_record_canonical?(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> runtime_record_canonical?()
  end

  defp runtime_record_canonical?(value) when is_map(value) do
    source_context_canonical? =
      not generated_source_context_record?(value) or
        canonical_source_context?(parse_source_context(map_field(value, "content")))

    source_context_canonical? and
      Enum.all?(value, fn {field, nested} ->
        field = to_string(field)

        cond do
          field in @opaque_reference_fields ->
            true

          field in @runtime_source_fields ->
            runtime_source_identity_canonical?(nested)

          field in @runtime_source_list_fields and is_list(nested) ->
            Enum.all?(nested, &runtime_source_identity_canonical?/1)

          true ->
            runtime_record_canonical?(nested)
        end
      end)
  end

  defp runtime_record_canonical?(value) when is_list(value),
    do: Enum.all?(value, &runtime_record_canonical?/1)

  defp runtime_record_canonical?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> runtime_record_canonical?()

  defp runtime_record_canonical?(_value), do: true

  defp runtime_source_identity_canonical?(value) when is_binary(value) do
    if String.starts_with?(value, "groupconv:"),
      do: canonical_runtime_source_identity?(value),
      else: true
  end

  defp runtime_source_identity_canonical?(_value), do: true

  defp canonical_runtime_source_identity?(value) do
    case String.split(value, ":") do
      ["groupconv", conversation_id, message_id, participant_id | _suffix] ->
        Ids.valid_conversation_id?(conversation_id) and Ids.valid_message_id?(message_id) and
          Ids.valid_participant_id?(participant_id)

      _ ->
        false
    end
  end

  defp canonical_source_context?(fields) do
    parent_conversation_id = fields["parent_conversation_id"]

    canonical_optional_id?(fields["conversation_id"], &Ids.valid_conversation_id?/1) and
      canonical_optional_id?(fields["parent_conversation_id"], &Ids.valid_conversation_id?/1) and
      canonical_optional_id?(fields["message_id"], &Ids.valid_message_id?/1) and
      (parent_conversation_id in [nil, ""] or
         canonical_optional_id?(fields["parent_message_id"], &Ids.valid_message_id?/1)) and
      canonical_optional_id?(fields["participant_id"], &Ids.valid_participant_id?/1) and
      canonical_optional_id?(fields["from_participant_id"], &Ids.valid_participant_id?/1)
  end

  defp canonical_optional_id?(value, _validator) when value in [nil, ""], do: true
  defp canonical_optional_id?(value, validator), do: validator.(value)

  defp rewrite_embedded_identity(value, map) when is_binary(value) do
    value
    |> String.replace(
      get_in(map, ["conversation_id", "source"]),
      get_in(map, ["conversation_id", "target"])
    )
    |> replace_embedded_ids(map["participant_ids"])
    |> replace_embedded_ids(map["message_ids"])
  end

  defp replace_embedded_ids(value, id_map) do
    Enum.reduce(id_map || %{}, value, fn {source, target}, acc ->
      String.replace(acc, source, target)
    end)
  end

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {field, value} when is_atom(field) -> if Atom.to_string(field) == key, do: value
        _ -> nil
      end)
  end

  defp map_field(_map, _key), do: nil

  defp nested_map_field(map, parent, key), do: map |> map_field(parent) |> map_field(key)

  defp path_group_id("agents/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [agent_id, _tail] ->
        if Ids.valid_agent_id?(agent_id), do: Ids.group_id_from_agent!(agent_id)

      _ ->
        nil
    end
  end

  defp path_group_id(_key), do: nil

  defp reverse_lookup(id_map, target) do
    Enum.find_value(id_map || %{}, fn {source, mapped} -> if mapped == target, do: source end)
  end

  defp message_fingerprint(message) do
    message
    |> Map.take(~w(kind participant_id actor_type user_id agent_id content metadata))
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  defp segment_id(key) do
    case Regex.run(@message_segment_re, key) do
      [_, segment_id] -> segment_id
      _ -> ""
    end
  end

  defp delete_prefix(prefix) do
    with {:ok, objects} <- S3.list_all(prefix) do
      Enum.reduce_while(objects, :ok, fn %{key: key}, :ok ->
        case S3.delete(key) do
          :ok -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp conversation_sort_key(value) do
    max_timestamp = 9_999_999_999_999_999_999

    timestamp =
      case value do
        value when is_integer(value) and value >= 0 -> min(value, max_timestamp)
        _ -> 0
      end

    (max_timestamp - timestamp)
    |> Integer.to_string()
    |> String.pad_leading(19, "0")
  end

  defp maybe_mark_complete(maps, opts) do
    if Keyword.get(opts, :mark_complete, true),
      do: ConversationIdMigration.mark_phase_complete(:s3, maps),
      else: :ok
  end

  defp parallel_map(items, fun) do
    items
    |> Task.async_stream(fun,
      ordered: false,
      max_concurrency: @max_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:migration_task_exit, reason}}
    end)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_value), do: %{}

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
