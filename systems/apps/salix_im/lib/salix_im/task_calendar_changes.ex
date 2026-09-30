defmodule SalixIM.TaskCalendarChanges do
  @moduledoc "Bounded public change feed for the read-only Calendar Task source."

  alias SalixIM.Conversations
  alias SalixStore.{CasRecord, Crypto, Ids, Keys, S3}

  @max_page 200
  @cas_attempts 8

  def record(conversation, schedule_definition) when is_map(conversation) do
    group_id = conversation["agent_group_id"]
    schedule = conversation["schedule"] || %{}

    state = %{
      "group_id" => group_id,
      "conversation_id" => conversation["conversation_id"],
      "kind" => "agent_task",
      "title" => conversation["title"],
      "status" => conversation["status"],
      "source_updated_at" => conversation["updated_at"],
      "schedule" => Map.take(schedule, ["schedule_id"]),
      "schedule_definition" => schedule_definition,
      "recurrence_anchor_at" =>
        schedule_definition && schedule_definition["recurrence_anchor_at"],
      "next_fire_at" => schedule_definition && schedule_definition["next_fire_at"]
    }

    digest = state_digest(state)
    bind_state(group_id, digest, state, @cas_attempts)
  end

  def page(group_id, opts \\ [])

  def page(group_id, opts) when is_list(opts) do
    continuation = opts[:continuation]
    start_after = opts[:start_after]
    limit = opts[:limit] || 100

    if not (is_integer(limit) and limit > 0 and limit <= @max_page) do
      {:error, :invalid_task_change_page}
    else
      do_page(group_id, continuation, start_after, limit)
    end
  end

  def page(_group_id, _opts), do: {:error, :invalid_task_change_page}

  defp do_page(group_id, continuation, start_after, limit) do
    list_opts = [max_keys: limit]

    list_opts =
      cond do
        is_binary(continuation) and continuation != "" ->
          Keyword.put(list_opts, :continuation_token, continuation)

        is_binary(start_after) and start_after != "" ->
          Keyword.put(list_opts, :start_after, start_after)

        true ->
          list_opts
      end

    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_task_calendar_changes_prefix(group_id), list_opts),
         {:ok, changes} <- hydrate(objects) do
      completed_cursor =
        case List.last(objects) do
          %{key: key} -> key
          nil -> start_after || Keys.ctl_task_calendar_changes_prefix(group_id)
        end

      {:ok,
       %{
         "changes" => changes,
         "next_continuation" => next,
         "completed_cursor" => if(is_nil(next), do: completed_cursor)
       }}
    end
  end

  defp hydrate(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, records} ->
      case CasRecord.get(object.key, :invalid_task_calendar_change) do
        {:ok, record} ->
          {:cont, {:ok, [record | records]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp bind_state(_group_id, _digest, _state, 0), do: {:error, :conflict}

  defp bind_state(group_id, digest, state, attempts) do
    key = Keys.ctl_task_calendar_change_state(group_id, digest)
    record = new_record(state)
    binding = %{"state_digest" => digest, "record" => record}

    case S3.put(key, Jason.encode!(binding), if_none_match: "*") do
      {:ok, _} -> put_record(group_id, record)
      {:error, :precondition_failed} -> use_bound_state(key, group_id, digest, state, attempts)
      {:error, {:ambiguous, _}} -> use_bound_state(key, group_id, digest, state, attempts)
      {:error, _} = error -> error
    end
  end

  defp use_bound_state(key, group_id, digest, state, attempts) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, %{"state_digest" => ^digest, "record" => record}} <- Jason.decode(body),
         :ok <- require_same_state(record, state) do
      case verify_record(group_id, record["change_id"], record) do
        {:ok, _} = ok ->
          ok

        {:error, :not_found} ->
          rotate_missing_binding(key, etag, group_id, digest, state, attempts - 1)

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_task_calendar_change_state}
    end
  end

  defp rotate_missing_binding(_key, _etag, _group_id, _digest, _state, 0),
    do: {:error, :conflict}

  defp rotate_missing_binding(key, etag, group_id, digest, state, attempts) do
    record = new_record(state)
    binding = %{"state_digest" => digest, "record" => record}

    case S3.put(key, Jason.encode!(binding), if_match: etag) do
      {:ok, _} ->
        put_record(group_id, record)

      {:error, :precondition_failed} ->
        bind_state(group_id, digest, state, attempts)

      {:error, {:ambiguous, _}} ->
        case verify_binding(key, binding) do
          :ok -> put_record(group_id, record)
          {:error, _} -> bind_state(group_id, digest, state, attempts)
        end

      {:error, _} = error ->
        error
    end
  end

  defp put_record(group_id, %{"change_id" => change_id} = record) do
    case S3.put(Keys.ctl_task_calendar_change(group_id, change_id), Jason.encode!(record),
           if_none_match: "*"
         ) do
      {:ok, _} -> {:ok, record}
      {:error, :precondition_failed} -> verify_record(group_id, change_id, record)
      {:error, {:ambiguous, _}} -> verify_record(group_id, change_id, record)
      {:error, _} = error -> error
    end
  end

  defp new_record(state) do
    state
    |> Map.put("change_id", Ids.new_calendar_change_id())
    |> Map.put("created_at", System.system_time(:millisecond))
  end

  defp state_digest(state),
    do: state |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()

  defp require_same_state(record, state) do
    if Map.drop(record, ["change_id", "created_at"]) == state,
      do: :ok,
      else: {:error, :task_calendar_change_state_conflict}
  end

  defp verify_binding(key, expected) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, ^expected} <- Jason.decode(body) do
      :ok
    else
      _ -> {:error, :ambiguous_task_calendar_change_state}
    end
  end

  defp verify_record(group_id, change_id, expected) do
    with {:ok, %{body: body}} <- S3.get(Keys.ctl_task_calendar_change(group_id, change_id)),
         {:ok, ^expected} <- Jason.decode(body) do
      {:ok, expected}
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :ambiguous_task_calendar_change}
    end
  end

  @doc false
  def repair_current_states(group_id, limit, schedule_projection)
      when is_function(schedule_projection, 3) do
    key = Keys.ctl_task_calendar_repair_track(group_id)

    with {:ok, track} <-
           CasRecord.ensure(
             key,
             fn -> %{"group_id" => group_id, "cursor" => nil, "revision" => 1} end,
             invalid: :invalid_task_calendar_repair_track
           ),
         true <- track["group_id"] == group_id,
         {:ok, page} <-
           Conversations.list_group_conversations(
             group_id,
             cursor: track["cursor"],
             limit: limit
           ),
         :ok <- record_task_states(group_id, page["data"] || [], schedule_projection),
         next_cursor <- if(page["has_more"], do: page["next_cursor"], else: nil),
         :ok <- checkpoint_repair_track(key, track, next_cursor) do
      :ok
    else
      false -> {:error, :invalid_task_calendar_repair_track}
      {:error, _} = error -> error
    end
  end

  defp record_task_states(group_id, conversations, schedule_projection) do
    Enum.reduce_while(conversations, :ok, fn
      %{"kind" => "agent_task", "conversation_id" => conversation_id} = conversation, :ok ->
        with {:ok, definition} <-
               schedule_projection.(group_id, conversation_id, conversation["schedule"]),
             {:ok, _change} <- record(conversation, definition) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end

      _conversation, :ok ->
        {:cont, :ok}
    end)
  end

  defp checkpoint_repair_track(key, track, next_cursor) do
    updated =
      track
      |> Map.put("cursor", next_cursor)
      |> Map.update("revision", 1, &(&1 + 1))

    with {:ok, _} <-
           CasRecord.update(
             key,
             fn
               ^track -> updated
               current -> {:unchanged, current}
             end,
             create: false,
             invalid: :invalid_task_calendar_repair_track
           ),
         do: :ok
  end
end
