defmodule SalixIM.TaskActivityProjection do
  @moduledoc """
  Rebuildable Group index for the two latest running or attention Tasks.

  ConversationStore writes each entry from its Conversation owner. The Group
  owner rebuilds only this display index from canonical metadata in bounded
  pages; Messages, Participants and Conversation facts are never rewritten.
  Reads validate the indexed address and status against canonical metadata.
  """

  alias SalixIM.{ConversationSearchSource, ConversationServer, Conversations}
  alias SalixStore.{CasRecord, Keys, S3}

  @statuses ~w(active in_progress running working needs_review ready_for_review escalated review waiting_for_review)
  @max_timestamp 9_999_999_999_999_999_999
  @max_identity 18_446_744_073_709_551_615
  @read_limit 20
  @read_pages 5
  @rebuild_page_size 20
  @rebuild_concurrency 4
  @rebuild_item_timeout_ms 5_000

  def eligible?(%{"kind" => "agent_task", "status" => status} = conversation),
    do: is_nil(conversation["deleted_at"]) and status in @statuses

  def eligible?(_), do: false

  @doc false
  def key(group_id, conversation) do
    "cnv1_" <> identity = conversation["conversation_id"]
    {identity, ""} = Integer.parse(identity)
    timestamp = normalize_timestamp(conversation["updated_at"])

    sort_key =
      reverse(timestamp, @max_timestamp, 19) <>
        "/" <> reverse(identity, @max_identity, 20)

    Keys.ctl_group_task_activity_entry(group_id, sort_key)
  end

  # Called only by ConversationStore's owner-scoped mutation/repair path.
  @doc false
  def put_current(group_id, conversation, io \\ S3) do
    if eligible?(conversation) do
      entry = %{
        "conversation_id" => conversation["conversation_id"],
        "updated_at" => conversation["updated_at"] || 0
      }

      case io.put(key(group_id, conversation), Jason.encode!(entry)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  @doc false
  def delete_previous(group_id, previous, current, io \\ S3) do
    previous_key = if is_map(previous), do: key(group_id, previous)
    current_key = if eligible?(current), do: key(group_id, current)

    if previous_key && previous_key != current_key,
      do: delete(previous_key, io),
      else: :ok
  end

  @doc false
  def delete(address, io \\ S3) do
    case io.delete(address) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  def list(group_id) do
    case rebuild_state(group_id) do
      {:ok, %{"state" => "ready"}} -> list_pages(group_id, nil, [], @read_pages)
      {:ok, _building} -> {:error, :activity_projection_pending}
      {:error, :not_found} -> {:error, :activity_projection_pending}
      {:error, _} = error -> error
    end
  end

  # Reads delete the stale entries they find, so a later read converges even
  # when this bounded scan ends before it finds two current Tasks.
  defp list_pages(_group_id, _token, _records, 0),
    do: {:error, :activity_projection_unavailable}

  defp list_pages(group_id, token, records, pages) do
    opts =
      if token,
        do: [max_keys: @read_limit, continuation_token: token],
        else: [max_keys: @read_limit]

    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_group_task_activity_prefix(group_id), opts),
         {:ok, records} <- hydrate(group_id, objects, records) do
      if length(records) < 2 and not is_nil(next),
        do: list_pages(group_id, next, records, pages - 1),
        else: {:ok, %{"data" => Enum.reverse(records)}}
    end
  end

  def rebuild_state(group_id), do: read_json(Keys.ctl_group_task_activity_rebuild(group_id))

  # Group owner persistence. Ready is absorbing and a stale page never moves
  # the canonical inventory cursor backwards under owner overlap.
  def advance_rebuild(group_id, cursor, complete?) do
    CasRecord.update(
      Keys.ctl_group_task_activity_rebuild(group_id),
      fn
        %{"state" => "ready"} = state ->
          {:unchanged, state}

        state ->
          state = state || %{"state" => "building", "cursor" => nil}
          current_cursor = state["cursor"]

          next_cursor =
            cond do
              is_nil(current_cursor) -> cursor
              is_nil(cursor) -> current_cursor
              true -> max(current_cursor, cursor)
            end

          %{
            "state" => if(complete?, do: "ready", else: "building"),
            "cursor" => next_cursor
          }
      end,
      invalid: :invalid_task_activity_rebuild,
      validate: fn value ->
        if is_map(value) and value["state"] in ["building", "ready"] and
             (is_nil(value["cursor"]) or is_binary(value["cursor"])),
           do: :ok,
           else: {:error, :invalid_task_activity_rebuild}
      end
    )
  end

  # One worker page per Group, at most four candidates in flight. Each candidate
  # has a five-second caller timeout; canonical inventory IO is separate.
  def rebuild_page(group_id, cursor) do
    started_at = SystemsClock.monotonic_time()

    result =
      with {:ok, page} <-
             ConversationSearchSource.conversation_page(group_id, cursor, @rebuild_page_size),
           :ok <- repair_sources(page.sources) do
        {:ok, page.next_start_after}
      end

    SystemsRuntime.Telemetry.execute(
      [:salix_im, :task_activity, :rebuild_page],
      %{duration: SystemsClock.monotonic_time() - started_at},
      %{outcome: if(match?({:ok, _}, result), do: :ok, else: :error)}
    )

    result
  end

  defp repair_sources(sources) do
    sources
    |> SystemsClock.async_stream(
      fn source ->
        case Conversations.get_group_conversation_record(source.group_id, source.conversation_id) do
          {:ok, conversation} ->
            if eligible?(conversation),
              do:
                ConversationServer.repair_task_activity_projection(
                  source.group_id,
                  source.conversation_id
                ),
              else: :ok

          {:error, :not_found} ->
            :ok

          {:error, _} = error ->
            error
        end
      end,
      max_concurrency: @rebuild_concurrency,
      timeout: @rebuild_item_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, :not_found}}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, {:activity_projection_repair_failed, reason}}}
    end)
  end

  # Records accumulate newest first in reverse. An entry is stale once its
  # canonical record has moved to another address or left eligibility: the
  # owner writes only the current address after commit, never an older one.
  defp hydrate(_group_id, _objects, records) when length(records) == 2, do: {:ok, records}
  defp hydrate(_group_id, [], records), do: {:ok, records}

  defp hydrate(group_id, [object | rest], records) do
    with {:ok, %{"conversation_id" => id}} <- read_json(object.key),
         {:ok, conversation} <- Conversations.get_group_conversation_record(group_id, id) do
      if eligible?(conversation) and key(group_id, conversation) == object.key,
        do: hydrate(group_id, rest, [conversation | records]),
        else: drop_stale(group_id, object, rest, records)
    else
      {:error, :not_found} -> drop_stale(group_id, object, rest, records)
      # The owner writes only well-formed entries; a malformed one is never current.
      {:error, :invalid_task_activity_index} -> drop_stale(group_id, object, rest, records)
      {:error, _} = error -> error
      _ -> drop_stale(group_id, object, rest, records)
    end
  end

  defp drop_stale(group_id, object, rest, records) do
    with :ok <- delete(object.key), do: hydrate(group_id, rest, records)
  end

  defp read_json(address), do: CasRecord.get(address, :invalid_task_activity_index)

  defp normalize_timestamp(value) when is_integer(value) and value >= 0, do: value

  defp normalize_timestamp(value) do
    case Integer.parse(to_string(value || 0)) do
      {timestamp, ""} when timestamp >= 0 -> timestamp
      _ -> 0
    end
  end

  defp reverse(value, maximum, width),
    do:
      (maximum - min(max(value, 0), maximum))
      |> Integer.to_string()
      |> String.pad_leading(width, "0")
end
