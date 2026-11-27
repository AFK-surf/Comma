defmodule Comma.TaskFeed do
  @moduledoc """
  Group-addressed Comma facade for the read-only Task Feed projection.

  Authorizes the exact Group through `Comma.Workspaces.authorize_group/3`,
  enforces single-Task scoping for restricted sessions, reads the indexed
  `salix_task_feed_entries` projection via `Comma.Salix.Client`, and enriches
  the returned page (at most 50 entries) with batched Loop and pull-request
  metadata without N+1 queries or transcript scans.
  """

  alias Comma.Workspaces

  @default_limit 25
  @max_limit 50
  @max_cursor_bytes 1_024
  @batch_size 50

  @doc """
  Lists one keyset-paginated page of Task Feed entries for `group_id`.

  Query parameters:
  - `"limit"` — integer `1..50` (default `25`)
  - `"cursor"` — opaque base64url keyset cursor
  - `"attention"` — `"1"` / `"true"` to return only entries requiring human attention
  """
  @spec list(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(user, session, group_id, params) when is_map(params) do
    with {:ok, opts} <- parse_options(params),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, opts} <- apply_session_scope(session, group_id, opts),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"entries" => entries} = page} <- salix_list_task_feed(workspace, opts) do
      enriched = enrich_page(workspace, entries)

      {:ok,
       %{
         "entries" => enriched,
         "has_more" => page["has_more"] == true,
         "next_cursor" => page["next_cursor"]
       }}
    else
      {:error, :invalid} -> {:error, :invalid_task_feed_query}
      {:error, :unavailable} -> {:error, :salix_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp parse_options(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, cursor} <- parse_cursor(Map.get(params, "cursor")),
         {:ok, attention} <- parse_attention(Map.get(params, "attention")) do
      opts =
        [limit: limit, attention: attention]
        |> maybe_put_keyword(:cursor, cursor)

      {:ok, opts}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(""), do: {:ok, @default_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> parse_limit(parsed)
      _invalid -> {:error, :invalid_task_feed_query}
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_limit,
    do: {:ok, limit}

  defp parse_limit(_limit), do: {:error, :invalid_task_feed_query}

  defp parse_cursor(nil), do: {:ok, nil}
  defp parse_cursor(""), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes,
    do: {:ok, cursor}

  defp parse_cursor(_cursor), do: {:error, :invalid_task_feed_query}

  defp parse_attention(nil), do: {:ok, false}
  defp parse_attention(""), do: {:ok, false}
  defp parse_attention(false), do: {:ok, false}
  defp parse_attention(true), do: {:ok, true}

  defp parse_attention(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ["1", "true"] -> {:ok, true}
      v when v in ["0", "false", ""] -> {:ok, false}
      _invalid -> {:error, :invalid_task_feed_query}
    end
  end

  defp parse_attention(_other), do: {:error, :invalid_task_feed_query}

  defp apply_session_scope(session, group_id, opts) do
    case session["conversation_id"] do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        with :ok <- Workspaces.group_session_scope(session, group_id, conversation_id) do
          {:ok, Keyword.put(opts, :conversation_id, conversation_id)}
        end

      _unscoped ->
        {:ok, opts}
    end
  end

  defp salix_list_task_feed(workspace, opts) do
    client = Comma.Salix.Client.impl()

    if Code.ensure_loaded?(client) and function_exported?(client, :list_task_feed, 2) do
      client.list_task_feed(workspace, opts)
    else
      {:error, :salix_conversation_read_not_supported}
    end
  end

  defp enrich_page(_workspace, []), do: []

  defp enrich_page(workspace, entries) do
    ids =
      entries
      |> Enum.map(& &1["conversation_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    loops = fetch_task_loops(workspace, ids)
    pull_requests = fetch_task_pull_requests(workspace, ids)

    Enum.map(entries, fn entry ->
      cid = entry["conversation_id"]
      loop = loops[cid]
      pr = pull_requests[cid]

      entry
      |> merge_loop(loop)
      |> merge_pull_request(pr)
    end)
  end

  defp merge_loop(entry, %{"trigger" => %{} = trigger}) do
    kind =
      case trigger do
        %{"every_minutes" => _} -> "every_minutes"
        %{"cron" => _} -> "cron"
        %{"events" => _} -> "events"
        _other -> entry["loop_kind"]
      end

    entry
    |> Map.put("is_loop", true)
    |> Map.put("loop_kind", kind || entry["loop_kind"])
  end

  defp merge_loop(entry, _loop), do: entry

  defp merge_pull_request(entry, %{} = pr), do: Map.put(entry, "pull_request", pr)
  defp merge_pull_request(entry, _pr), do: entry

  defp fetch_task_loops(_workspace, []), do: %{}

  defp fetch_task_loops(workspace, ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(%{}, fn batch, acc ->
      case Comma.Salix.Client.task_loops(workspace, batch) do
        {:ok, %{} = read} -> Map.merge(acc, read)
        _other -> acc
      end
    end)
  end

  defp fetch_task_pull_requests(_workspace, []), do: %{}

  defp fetch_task_pull_requests(workspace, ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(%{}, fn batch, acc ->
      {:ok, read} = Comma.Salix.Client.task_pull_requests(workspace, batch)
      Map.merge(acc, read)
    end)
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)
end
