defmodule SalixMeet.PreparationRecentMeetings do
  @moduledoc """
  Bounded navigation pointers for recently completed meetings published to an
  authorized Slack channel or Feishu/Lark chat.

  Intended to be invoked through `SalixMeet.PreparationSources.read/2`
  (`operation: "recent_meetings"`), which enforces channel/chat authorization
  before and after reading (Slack public workspace channel; Feishu/Lark allows
  the designated notice chat per existing policy and requires public internal
  groups for other chats) and attaches the channel's IFC `source_label`.

  Walks bounded keyset pages of `MeetingGroupProjections` and object-store
  reads under one shared monotonic scan budget (`@scan_deadline_ms`),
  distinguishes deterministic filter misses from object store failures and
  timeouts, preserves partial matches, and returns an unambiguous `status`
  (`complete` | `partial` | `unavailable`) and `truncated`. Provider visibility
  checks use the standard provider HTTP client timeouts outside this scan
  budget.

  Returns metadata pointers only — never summaries, transcripts, private
  content, or tokens.
  """

  alias SalixMeet.Store
  alias SalixStore.{MeetingGroupProjectionReadiness, MeetingGroupProjections}
  alias SystemsObservability.Context

  @default_limit 12
  @projection_page_size 30
  @max_scan_pages 4
  @read_concurrency 8
  @scan_deadline_ms 1_500
  @max_title_length 160
  @slack_file_id_pattern ~r/\AF[A-Z0-9]+\z/
  @lark_history_pad_before_s 300
  @lark_history_default_duration_s 7_200
  @lark_history_pad_after_s 1_800

  @doc """
  List bounded recent completed, published meetings for an already-authorized
  `scope` (`%{group_id, provider, connect_id, channel_id}`) that started
  strictly before the plan's occurrence.
  """
  @spec list_for_scope(map(), map(), keyword()) :: map()
  def list_for_scope(plan, scope, opts \\ []) when is_map(plan) and is_map(scope) do
    limit = Keyword.get(opts, :limit, @default_limit)
    page_size = Keyword.get(opts, :page_size, @projection_page_size)
    max_pages = Keyword.get(opts, :max_pages, @max_scan_pages)

    deadline_at =
      Keyword.get_lazy(opts, :deadline_at, fn ->
        deadline_ms = Keyword.get(opts, :deadline_ms, @scan_deadline_ms)
        SystemsClock.monotonic_time(:millisecond) + deadline_ms
      end)

    before_start_ms = occurrence_start_ms(plan)

    if MeetingGroupProjectionReadiness.ready?() do
      scan_pages(scope, before_start_ms, limit, page_size, max_pages, deadline_at)
    else
      unavailable("projection_not_ready")
    end
  end

  defp scan_pages(scope, before_start_ms, limit, page_size, max_pages, deadline_at) do
    do_scan_pages(
      scope,
      before_start_ms,
      limit,
      page_size,
      max_pages,
      deadline_at,
      nil,
      []
    )
  end

  defp do_scan_pages(
         _scope,
         _before_start_ms,
         limit,
         _page_size,
         0,
         _deadline_at,
         _cursor,
         acc
       ) do
    finalize(acc, limit, true, "partial")
  end

  defp do_scan_pages(
         scope,
         before_start_ms,
         limit,
         page_size,
         pages_left,
         deadline_at,
         cursor,
         acc
       ) do
    remaining = deadline_at - SystemsClock.monotonic_time(:millisecond)

    if remaining <= 0 do
      timeout_result(acc, limit)
    else
      query_opts =
        [limit: page_size, timeout: min(remaining, 2_000)]
        |> then(&if(is_nil(cursor), do: &1, else: Keyword.put(&1, :cursor, cursor)))

      case MeetingGroupProjections.list_recent_group(scope.group_id, query_opts) do
        {:ok, %{meeting_ids: meeting_ids, truncated: more_rows?, next_cursor: next_cursor}} ->
          {matched, page_incomplete?} =
            read_records_within_deadline(meeting_ids, scope, before_start_ms, deadline_at)

          next_acc = acc ++ matched

          cond do
            page_incomplete? ->
              incomplete_result(next_acc, limit)

            length(next_acc) > limit ->
              finalize(next_acc, limit, true, "partial")

            length(next_acc) == limit and more_rows? ->
              finalize(next_acc, limit, true, "partial")

            not more_rows? or is_nil(next_cursor) ->
              finalize(next_acc, limit, false, "complete")

            true ->
              do_scan_pages(
                scope,
                before_start_ms,
                limit,
                page_size,
                pages_left - 1,
                deadline_at,
                next_cursor,
                next_acc
              )
          end

        {:error, _reason} ->
          if acc == [],
            do: unavailable("projection_unavailable"),
            else: finalize(acc, limit, true, "partial")
      end
    end
  end

  defp timeout_result([], _limit), do: unavailable("deadline_exceeded")
  defp timeout_result(acc, limit), do: finalize(acc, limit, true, "partial")

  defp incomplete_result([], _limit), do: unavailable("store_unavailable")
  defp incomplete_result(acc, limit), do: finalize(acc, limit, true, "partial")

  defp finalize(records, limit, truncated?, status) do
    meetings =
      records
      |> Enum.uniq_by(
        &{&1["channel"], &1["start_ms"],
         &1["thread_ts"] || &1["thread_id"] || &1["message_id"] || &1["title"]}
      )
      |> Enum.sort_by(&(-(&1["start_ms"] || 0)))
      |> Enum.take(limit)

    %{
      "status" => status,
      "truncated" => truncated?,
      "meetings" => meetings
    }
  end

  defp unavailable(reason) do
    %{
      "status" => "unavailable",
      "reason" => reason,
      "truncated" => true,
      "meetings" => []
    }
  end

  defp read_records_within_deadline([], _scope, _before_start_ms, _deadline_at), do: {[], false}

  defp read_records_within_deadline(meeting_ids, scope, before_start_ms, deadline_at) do
    context_obs = Context.capture()

    meeting_ids
    |> Enum.chunk_every(@read_concurrency)
    |> Enum.reduce_while({[], false}, fn chunk, {acc, had_error?} ->
      remaining = deadline_at - SystemsClock.monotonic_time(:millisecond)

      if remaining <= 0 do
        {:halt, {acc, true}}
      else
        {chunk_matched, chunk_error?} =
          read_chunk(chunk, scope, before_start_ms, remaining, context_obs)

        {:cont, {acc ++ chunk_matched, had_error? or chunk_error?}}
      end
    end)
  end

  defp read_chunk(chunk, scope, before_start_ms, timeout_ms, context_obs) do
    chunk
    |> SystemsClock.async_stream(
      fn meeting_id ->
        Context.run(context_obs, fn -> read_record(meeting_id, scope, before_start_ms) end)
      end,
      max_concurrency: @read_concurrency,
      ordered: false,
      timeout: max(timeout_ms, 1),
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], false}, fn
      {:ok, {:ok, record}}, {acc, err?} -> {[record | acc], err?}
      {:ok, :skip}, {acc, err?} -> {acc, err?}
      {:ok, {:error, _reason}}, {acc, _err?} -> {acc, true}
      {:exit, _reason}, {acc, _err?} -> {acc, true}
    end)
  end

  defp read_record(meeting_id, scope, before_start_ms) do
    case Store.get_indexed(meeting_id) do
      {:ok, %{"state" => state} = doc, _etag} when is_map(state) ->
        with true <- matches_scope?(state, scope),
             true <- completed_and_published?(state),
             start_ms when is_integer(start_ms) <- meeting_start_ms(state, doc),
             true <- is_nil(before_start_ms) or start_ms < before_start_ms do
          {:ok, pointer(state, scope, start_ms)}
        else
          _ -> :skip
        end

      {:ok, _doc, _etag} ->
        :skip

      {:error, :not_found} ->
        :skip

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matches_scope?(state, scope) do
    state["group_id"] == scope.group_id and
      state["provider"] == scope.provider and
      state["connect_id"] == scope.connect_id and
      channel_matches?(scope.provider, state, scope.channel_id)
  end

  defp channel_matches?("slack", state, channel_id),
    do: trim(get_in(state, ["slack_ref", "channel_id"])) == channel_id

  defp channel_matches?("feishu", state, chat_id),
    do: trim(get_in(state, ["feishu_ref", "chat_id"])) == chat_id

  defp channel_matches?("lark", state, chat_id),
    do: trim(get_in(state, ["lark_ref", "chat_id"])) == chat_id

  defp channel_matches?(_provider, _state, _channel_id), do: false

  defp completed_and_published?(state) do
    delivery = state["delivery"] || %{}
    notes_status = get_in(delivery, ["notes_delivery", "status"])

    state["status"] == "done" and
      (delivery["published_at"] not in [nil, "", false] or
         notes_status == "visible" or
         trim(delivery["summary_message_ts"]) != "")
  end

  defp pointer(state, %{provider: "slack", channel_id: channel_id}, start_ms) do
    delivery = state["delivery"] || %{}

    base_pointer(state, channel_id, start_ms)
    |> maybe_put("thread_ts", trim(get_in(state, ["slack_ref", "thread_ts"])))
    |> maybe_put("summary_message_ts", trim(delivery["summary_message_ts"]))
    |> maybe_put("transcript_file_id", slack_transcript_file_id(delivery))
  end

  defp pointer(state, %{provider: provider, channel_id: chat_id}, start_ms)
       when provider in ["feishu", "lark"] do
    ref = state[provider <> "_ref"] || %{}
    delivery = state["delivery"] || %{}
    thread_id = lark_thread_container_id(ref["thread_id"])
    message_id = first_nonblank([ref["trigger_message_id"], ref["root_message_id"]])

    base_pointer(state, chat_id, start_ms)
    |> maybe_put("thread_id", thread_id)
    |> maybe_put("message_id", message_id)
    |> maybe_put("summary_message_id", trim(delivery["summary_message_id"]))
    |> then(fn ptr ->
      if thread_id == "",
        do: Map.put(ptr, "history_window", lark_history_window(state, delivery, start_ms)),
        else: ptr
    end)
  end

  defp base_pointer(state, channel_id, start_ms) do
    %{
      "title" => title(state["title"]),
      "started_at" => iso_timestamp(start_ms),
      "start_ms" => start_ms,
      "channel" => channel_id
    }
  end

  # Feishu/Lark replies API requires a real thread container ID (`omt_...`),
  # never a message ID (`om_...`).
  defp lark_thread_container_id(value) do
    trimmed = trim(value)
    if String.starts_with?(trimmed, "omt_"), do: trimmed, else: ""
  end

  defp lark_history_window(state, delivery, start_ms) do
    start_s = div(start_ms, 1_000)

    end_s =
      [
        state["end_at"],
        delivery["published_at"],
        start_s + @lark_history_default_duration_s
      ]
      |> Enum.filter(&is_integer/1)
      |> Enum.max()

    %{
      "start_time" => Integer.to_string(max(start_s - @lark_history_pad_before_s, 0)),
      "end_time" => Integer.to_string(end_s + @lark_history_pad_after_s)
    }
  end

  defp slack_transcript_file_id(delivery) do
    file_id = trim(get_in(delivery, ["artifacts", "transcript", "file_id"]))
    if Regex.match?(@slack_file_id_pattern, file_id), do: file_id, else: ""
  end

  defp occurrence_start_ms(plan) do
    get_in(plan, ["effective_occurrence", "start_ms"]) ||
      get_in(plan, ["occurrence_ref", "start_ms"])
  end

  defp meeting_start_ms(state, doc) do
    cond do
      is_integer(state["start_at"]) -> state["start_at"] * 1_000
      is_integer(doc["created_at"]) -> doc["created_at"]
      true -> nil
    end
  end

  defp iso_timestamp(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp title(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @max_title_length) do
      "" -> "Meeting"
      trimmed -> trimmed
    end
  end

  defp title(_value), do: "Meeting"

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp first_nonblank(values) do
    Enum.find_value(values, "", fn value ->
      trimmed = trim(value)
      if trimmed != "", do: trimmed
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
