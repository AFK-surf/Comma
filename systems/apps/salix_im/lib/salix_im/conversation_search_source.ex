defmodule SalixIM.ConversationSearchSource do
  @moduledoc """
  Bounded discovery of authoritative Conversation metadata in S3.

  Group inventory plus delimiter-based Conversation common prefixes make each
  page proportional to Conversation cardinality, not to Message/Participant
  child objects. Exact raw metadata is the authority for kind/live/tombstone;
  missing metadata never authorizes a projection delete.
  """

  alias SalixStore.{Ids, Keys, S3, SearchDocumentEnvelope}

  @spec next_group(String.t() | nil) :: {:ok, nil | map()} | {:error, term()}
  def next_group(start_after) do
    with {:ok, %{objects: objects}} <-
           S3.list(Keys.ctl_groups_prefix(), max_keys: 1, start_after: start_after) do
      case objects do
        [] -> {:ok, nil}
        [%{key: key}] -> group_from_key(key)
      end
    end
  end

  @spec conversation_page(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, %{sources: [map()], next_start_after: String.t() | nil}} | {:error, term()}
  def conversation_page(group_id, start_after, limit)
      when is_binary(group_id) and is_integer(limit) and limit in 1..100 do
    prefix = Keys.ctl_group_conversations_prefix(group_id)

    with {:ok, %{objects: objects, common_prefixes: common_prefixes}} <-
           S3.list(prefix, delimiter: "/", max_keys: limit, start_after: start_after),
         :ok <- validate_legacy_flat_objects(group_id, prefix, objects),
         {:ok, sources} <- parse_conversation_prefixes(group_id, prefix, common_prefixes) do
      keys =
        Enum.map(objects, & &1.key) ++
          Enum.map(common_prefixes, &common_prefix_end_cursor/1)

      {:ok,
       %{
         sources: sources,
         next_start_after: if(keys == [], do: nil, else: Enum.max(keys))
       }}
    end
  end

  # Replacing the trailing slash with its next ASCII byte moves StartAfter
  # beyond every object below this fixed-width Conversation id while remaining
  # before the next id. This also handles S3-compatible backends that re-emit a
  # CommonPrefix equal to StartAfter after filtering their raw object keys.
  defp common_prefix_end_cursor(prefix), do: String.replace_suffix(prefix, "/", "0")

  @spec classify_conversation(map()) ::
          {:ok, {:task, map()} | {:not_task, map()} | {:deleted, map()} | :missing}
          | {:error, term()}
  def classify_conversation(source) do
    key = Keys.ctl_group_conversation(source.group_id, source.conversation_id)

    case read_json(key) do
      {:ok, meta} when is_map(meta) ->
        with :ok <- validate_meta(source, meta, key),
             {:ok, signature} <- source_signature(source, meta) do
          cond do
            not is_nil(meta["deleted_at"]) -> {:ok, {:deleted, signature}}
            meta["kind"] == "agent_task" -> {:ok, {:task, signature}}
            meta["kind"] == "user_chat" -> {:ok, {:not_task, signature}}
          end
        end

      {:error, :not_found} ->
        {:ok, :missing}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, {:invalid_conversation_meta, key}}
    end
  end

  defp group_from_key(key) do
    prefix = Keys.ctl_groups_prefix()

    with true <- String.starts_with?(key, prefix),
         relative <- String.replace_prefix(key, prefix, ""),
         true <- String.ends_with?(relative, ".json"),
         group_id <- String.trim_trailing(relative, ".json"),
         true <- not String.contains?(group_id, "/") and Ids.valid_group_id?(group_id),
         true <- key == Keys.ctl_group(group_id) do
      {:ok, %{key: key, group_id: group_id}}
    else
      _other -> {:error, {:invalid_group_inventory_key, key}}
    end
  end

  defp parse_conversation_prefixes(group_id, parent, prefixes) do
    Enum.reduce_while(prefixes, {:ok, []}, fn prefix, {:ok, acc} ->
      with true <- String.starts_with?(prefix, parent),
           relative <- String.replace_prefix(prefix, parent, ""),
           true <- String.ends_with?(relative, "/"),
           conversation_id <- String.trim_trailing(relative, "/"),
           true <- not String.contains?(conversation_id, "/"),
           true <- Ids.valid_conversation_id?(conversation_id),
           true <- prefix == Keys.ctl_group_conversation_dir(group_id, conversation_id) do
        {:cont,
         {:ok, [%{key: prefix, group_id: group_id, conversation_id: conversation_id} | acc]}}
      else
        _other -> {:halt, {:error, {:invalid_conversation_inventory_prefix, prefix}}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, _reason} = error -> error
    end
  end

  # The segmented-storage migration intentionally left legacy flat objects for
  # a separate cleanup. They are inventory-only here: canonical metadata is
  # always the exact `<conversation>/meta.json` object and flat bodies are
  # never read or used as a fallback.
  defp validate_legacy_flat_objects(group_id, parent, objects) do
    Enum.reduce_while(objects, :ok, fn %{key: key}, :ok ->
      with true <- String.starts_with?(key, parent),
           relative <- String.replace_prefix(key, parent, ""),
           true <- String.ends_with?(relative, ".json"),
           conversation_id <- String.trim_trailing(relative, ".json"),
           true <- conversation_id != "" and not String.contains?(conversation_id, "/"),
           true <- Ids.valid_conversation_id?(conversation_id),
           true <- key == parent <> conversation_id <> ".json",
           true <- parent == Keys.ctl_group_conversations_prefix(group_id) do
        {:cont, :ok}
      else
        _other -> {:halt, {:error, {:unexpected_direct_object, key}}}
      end
    end)
  end

  defp validate_meta(source, meta, key) do
    valid? =
      meta["agent_group_id"] == source.group_id and
        meta["conversation_id"] == source.conversation_id and
        meta["kind"] in ["agent_task", "user_chat"] and
        (is_nil(meta["title"]) or is_binary(meta["title"]))

    if valid?, do: :ok, else: {:error, {:invalid_conversation_meta, key}}
  end

  defp source_signature(source, meta) do
    tail = meta["message_tail_seq"] || meta["message_count"] || 0
    fallback_head = if is_integer(tail) and tail > 0, do: 1, else: 0
    head = meta["message_head_seq"] || fallback_head
    updated_at = meta["updated_at"] || meta["created_at"] || 0

    if SearchDocumentEnvelope.valid_sequence_range?(head, tail) and
         is_integer(updated_at) and updated_at >= 0 do
      {:ok,
       %{
         key: source.key,
         group_id: source.group_id,
         conversation_id: source.conversation_id,
         kind: meta["kind"],
         title_envelope: SearchDocumentEnvelope.build(:title, meta["title"]),
         message_head_seq: head,
         message_tail_seq: tail,
         updated_at: updated_at
       }}
    else
      {:error, {:invalid_conversation_search_signature, source.key}}
    end
  end

  defp read_json(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value}
    end
  end
end
