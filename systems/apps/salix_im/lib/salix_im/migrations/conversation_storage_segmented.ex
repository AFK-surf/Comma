defmodule SalixIM.Migrations.ConversationStorageSegmented do
  @moduledoc """
  Exclusive cutover from legacy flat conversations to the owner-backed layout.

  This module only reads and normalizes legacy records. Canonical conversation,
  participant, message, and delivery writes all go through `ConversationServer`
  and the exact owner actors; the migration contains no copy of their physical
  persistence protocol. Stable identities and a completion marker make reruns
  safe after any partial attempt.
  """

  alias SalixIM.{
    ConversationFleet,
    Conversations,
    ConversationServer
  }

  alias SalixStore.{CasRecord, Crypto, Ids, Keys, S3}

  @migration_name "conversation_storage_segmented"
  @legacy_conversations_prefix "ctl/group_conversations/"
  @legacy_dispatch_prefix "ctl/group_conversation_dispatch/"
  @legacy_conversation_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)\.json$|
  @scan_page_size 100

  @type counts :: %{
          migrated: non_neg_integer(),
          resumed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @type stats :: %{
          migrated: non_neg_integer(),
          resumed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          dispatches: counts()
        }

  @spec run() :: {:ok, stats()} | {:error, {:conversation_storage_migration_failed, stats()}}
  def run do
    with {:ok, stats} <- reduce_legacy_conversation_pages(nil, zero_stats()) do
      CommaLog.log("migrate_conversation_storage_segmented", stats)

      if stats.failed == 0 and stats.dispatches.failed == 0,
        do: {:ok, stats},
        else: {:error, {:conversation_storage_migration_failed, stats}}
    end
  end

  @spec migrate_conversation(String.t()) ::
          {:migrated | :resumed | :skipped, counts()} | {:error, term()}
  def migrate_conversation(legacy_key) when is_binary(legacy_key) do
    with {:ok, group_id, conversation_id} <- parse_legacy_key(legacy_key),
         {:ok, complete?} <- complete?(legacy_key) do
      if complete? do
        with :ok <- cleanup_completed_marker(group_id, conversation_id, legacy_key) do
          {:skipped, zero_counts()}
        end
      else
        migrate_incomplete(group_id, conversation_id, legacy_key)
      end
    end
  end

  defp migrate_incomplete(group_id, conversation_id, legacy_key) do
    with true <- Ids.valid_group_id?(group_id) and Ids.valid_conversation_id?(conversation_id),
         action when action in [:migrated, :resumed] <-
           migration_action(group_id, conversation_id),
         {:ok, _pid} <-
           ConversationFleet.ensure_started(
             group_id,
             conversation_id,
             wake_on_recovery: false
           ),
         {:ok, legacy} <- read_json(legacy_key),
         {:ok, seed_payload} <-
           SalixIM.ConversationSeedInput.prepare(
             group_id,
             conversation_id,
             seed(group_id, conversation_id, legacy)
           ),
         {:ok, _seeded} <-
           ConversationServer.seed_group_conversation_transcript(
             group_id,
             conversation_id,
             seed_payload
           ),
         {:ok, dispatches} <- migrate_dispatches(group_id, conversation_id),
         :ok <- write_complete_marker(group_id, conversation_id, legacy_key, dispatches) do
      {action, dispatches}
    else
      false -> {:error, :not_legacy_conversation_key}
      {:error, _reason} = error -> error
    end
  end

  defp migration_action(group_id, conversation_id) do
    case S3.head(Keys.ctl_group_conversation(group_id, conversation_id)) do
      {:ok, _} -> :resumed
      {:error, :not_found} -> :migrated
      {:error, reason} -> {:error, {:read_new_conversation_meta_failed, reason}}
    end
  end

  defp seed(group_id, conversation_id, legacy) do
    messages = legacy_messages(legacy, conversation_id)

    conversation =
      legacy
      |> Map.drop(
        ~w(messages participant_count message_count target_message_count message_head_seq message_tail_seq current_message_segment current_message_segment_start_seq storage_migration)
      )
      |> Map.put("agent_group_id", group_id)
      |> Map.put("conversation_id", conversation_id)
      |> Map.put_new("created_by_agent_id", nil)
      |> Map.put("participants", legacy_participants(legacy, conversation_id))

    %{
      "conversation" => conversation,
      "messages" => messages,
      "mark_participants_delivered" => true,
      "created_at" => legacy["created_at"]
    }
  end

  defp legacy_participants(%{"participants" => participants}, conversation_id)
       when is_list(participants) do
    participants
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.put(&1, "conversation_id", conversation_id))
  end

  defp legacy_participants(_legacy, _conversation_id), do: []

  defp legacy_messages(%{"messages" => messages}, conversation_id) when is_list(messages) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {message, index} ->
      message
      |> Map.put_new("kind", "message")
      |> Map.put_new("metadata", %{})
      |> put_message_request_identity(conversation_id, index)
    end)
  end

  defp legacy_messages(_legacy, _conversation_id), do: []

  defp put_message_request_identity(message, conversation_id, index) do
    if Enum.any?(
         ~w(idempotency_key source_message_id client_request_id),
         &(trim(message[&1]) != "")
       ) do
      message
    else
      Map.put(message, "client_request_id", "migration:#{conversation_id}:#{index}")
    end
  end

  defp migrate_dispatches(group_id, conversation_id) do
    prefix = @legacy_dispatch_prefix <> group_id <> "/" <> conversation_id <> "/"

    with {:ok, stats} <-
           reduce_dispatch_pages(group_id, conversation_id, prefix, nil, zero_counts()) do
      if stats.failed == 0,
        do: {:ok, stats},
        else: {:error, {:legacy_dispatch_migration_failed, stats}}
    else
      {:error, reason} -> {:error, {:list_legacy_dispatches_failed, reason}}
    end
  end

  defp reduce_dispatch_pages(group_id, conversation_id, prefix, token, stats) do
    opts =
      if is_binary(token),
        do: [max_keys: @scan_page_size, continuation_token: token],
        else: [max_keys: @scan_page_size]

    case S3.list(prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        stats =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.reduce(stats, &reduce_dispatch(group_id, conversation_id, &1, &2))

        if is_binary(next) and next != "",
          do: reduce_dispatch_pages(group_id, conversation_id, prefix, next, stats),
          else: {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce_dispatch(group_id, conversation_id, key, stats) do
    case migrate_dispatch(group_id, conversation_id, key) do
      :migrated -> Map.update!(stats, :migrated, &(&1 + 1))
      :skipped -> Map.update!(stats, :skipped, &(&1 + 1))
      {:error, _reason} -> Map.update!(stats, :failed, &(&1 + 1))
    end
  end

  defp migrate_dispatch(group_id, conversation_id, key) do
    with {:ok, dispatch} <- read_json(key),
         participant_id when participant_id != "" <- trim(dispatch["target_participant_id"]),
         true <- Ids.valid_participant_id?(participant_id),
         {:ok, conversation} <-
           Conversations.get_group_conversation(group_id, conversation_id),
         {:ok, facts} <- legacy_delivery_facts(dispatch, key, conversation),
         result <-
           ConversationServer.import_legacy_group_conversation_delivery(
             group_id,
             conversation_id,
             participant_id,
             facts
           ) do
      case result do
        :inserted -> :migrated
        :exists -> :skipped
        {:error, reason} -> {:error, reason}
      end
    else
      "" -> :skipped
      false -> :skipped
      {:error, :not_found} -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp legacy_delivery_facts(dispatch, key, conversation) do
    {delivery_kind, notification_kind} =
      canonical_delivery_kind(dispatch["delivery_kind"] || dispatch["dispatch_kind"])

    with {:ok, message} <- legacy_message(conversation, dispatch["message_id"]) do
      {:ok,
       dispatch
       |> Map.take(
         ~w(request_identity request_fingerprint message_id source_participant_id source_actor_type source_user_id source_agent_id source_role_label message_content message_metadata message_created_at)
       )
       |> Map.put(
         "delivery_id",
         dispatch["delivery_id"] || dispatch["dispatch_id"] ||
           "migrated-dispatch:" <> Crypto.hex(key)
       )
       |> Map.put("delivery_kind", delivery_kind)
       |> maybe_put("notification_kind", notification_kind)
       |> maybe_put("delivery_session_name", dispatch["target_session_name"])
       |> maybe_put("delivery_billing_context", dispatch["target_billing_context"])
       |> maybe_put("message_seq", if(is_map(message), do: message["seq"]))}
    end
  end

  defp legacy_message(_conversation, message_id) when message_id in [nil, ""], do: {:ok, nil}

  defp legacy_message(conversation, message_id) do
    case Conversations.get_group_conversation_message(
           conversation["agent_group_id"],
           conversation["conversation_id"],
           message_id
         ) do
      {:ok, message} -> {:ok, message}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_delivery_kind("conversation_link"),
    do: {"participant_notification", "conversation_link"}

  defp canonical_delivery_kind("provider_participant_message"),
    do: {"participant_notification", "provider_participant_message"}

  defp canonical_delivery_kind("participant_notification"),
    do: {"participant_notification", nil}

  defp canonical_delivery_kind(_kind), do: {"group_conversation", nil}

  defp write_complete_marker(group_id, conversation_id, legacy_key, dispatches) do
    record = %{
      "name" => @migration_name,
      "source_key" => legacy_key,
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "dispatches" => dispatches,
      "completed_at" => now()
    }

    case S3.put(marker_key(legacy_key), Jason.encode!(record), if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> :ok
      {:error, reason} -> {:error, {:write_complete_marker_failed, reason}}
    end
  end

  defp complete?(legacy_key) do
    case S3.head(marker_key(legacy_key)) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, reason} -> {:error, {:read_complete_marker_failed, reason}}
    end
  end

  defp cleanup_completed_marker(group_id, conversation_id, legacy_key) do
    if Ids.valid_group_id?(group_id) and Ids.valid_conversation_id?(conversation_id) do
      with {:ok, _pid} <-
             ConversationFleet.ensure_started(
               group_id,
               conversation_id,
               wake_on_recovery: false
             ) do
        ConversationServer.finish_seed_group_conversation(group_id, conversation_id)
      end
    else
      key = Keys.ctl_group_conversation(group_id, conversation_id)

      case CasRecord.update(key, fn
             %{"storage_migration" => %{"source_key" => ^legacy_key}} = record ->
               Map.delete(record, "storage_migration")

             record ->
               {:unchanged, record}
           end) do
        {:ok, _record} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp marker_key(legacy_key),
    do: "ctl/migrations/conversation_storage_segmented/" <> Crypto.hex(legacy_key) <> ".json"

  defp reduce_legacy_conversation_pages(token, stats) do
    opts =
      if is_binary(token),
        do: [max_keys: @scan_page_size, continuation_token: token],
        else: [max_keys: @scan_page_size]

    case S3.list(@legacy_conversations_prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        stats =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&match?({:ok, _, _}, parse_legacy_key(&1)))
          |> Enum.reduce(stats, &reduce_conversation/2)

        if is_binary(next) and next != "",
          do: reduce_legacy_conversation_pages(next, stats),
          else: {:ok, stats}

      {:error, reason} ->
        {:error, {:list_legacy_conversations_failed, reason}}
    end
  end

  defp parse_legacy_key(key) do
    case Regex.run(@legacy_conversation_re, key) do
      [_, group_id, conversation_id]
      when is_binary(group_id) and is_binary(conversation_id) ->
        {:ok, group_id, conversation_id}

      _ ->
        {:error, :not_legacy_conversation_key}
    end
  end

  defp read_json(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp reduce_conversation(key, stats) do
    case migrate_conversation(key) do
      {:migrated, dispatches} ->
        stats |> Map.update!(:migrated, &(&1 + 1)) |> merge_dispatches(dispatches)

      {:resumed, dispatches} ->
        stats |> Map.update!(:resumed, &(&1 + 1)) |> merge_dispatches(dispatches)

      {:skipped, dispatches} ->
        stats |> Map.update!(:skipped, &(&1 + 1)) |> merge_dispatches(dispatches)

      {:error, _reason} ->
        Map.update!(stats, :failed, &(&1 + 1))
    end
  end

  defp merge_dispatches(stats, dispatches) do
    Map.update!(stats, :dispatches, fn current ->
      Map.new(current, fn {key, value} -> {key, value + dispatches[key]} end)
    end)
  end

  defp zero_counts, do: %{migrated: 0, resumed: 0, skipped: 0, failed: 0}
  defp zero_stats, do: Map.put(zero_counts(), :dispatches, zero_counts())
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp now, do: System.system_time(:millisecond)
end
