defmodule SalixAgent.Tools.History do
  @moduledoc "Agent-only retrieval of original records in the current internal Session."
  require Logger
  alias SalixAgent.SessionHistory.{Source, Document, Episodes, Hot, Worker}
  @normal SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @max_terms 8
  @search %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" =>
          "Literal terms separated by spaces, 2 to 128 Unicode code points, at most 8 terms."
      },
      "cursor" => %{"type" => "string", "description" => "Continuation from this query."},
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
    },
    "required" => ["query"]
  }
  @list %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "cursor" => %{"type" => "string", "description" => "Continuation from history.list."},
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
    },
    "required" => []
  }
  @get %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "seq" => %{"type" => "integer", "minimum" => 1},
      "offset" => %{
        "type" => "integer",
        "minimum" => 0,
        "description" => "Original text character offset; use next_offset."
      }
    },
    "required" => ["seq"]
  }

  def entries do
    [
      {"history.search",
       "Search original messages and tool results in this Session, including content removed from model context by compaction.\n\nNo cross-Session search. A hit contains every space-separated term as a normalized substring, in any order. Search for one or two distinctive words (a name, a path, a tool), not a sentence. Inspect complete and indexed_through: no matches in an incomplete index does not establish absence. Use history.get on a hit to read its original text.\n\nResults hold original records only. The first page may also list up to 3 episodes: summaries written at earlier compactions that a later compaction replaced in context, ranked by how many terms they contain. An episode states what was done or decided; history.get on its seq reads the whole summary.",
       @search, &__MODULE__.search/2, @normal, [safety: "read", runtimes: [:internal]]},
      {"history.list",
       "List brief original-history records in this Session, newest first. One entry per record, with seq, type, tool name and a short preview. Inspect complete for index coverage. Use history.get for details.",
       @list, &__MODULE__.list/2, @normal, [safety: "read", runtimes: [:internal]]},
      {"history.get",
       "Read a bounded page of an original record in this Session by its history.search seq. Includes pre-compaction text. Use next_offset for the rest.",
       @get, &__MODULE__.get/2, @normal, [safety: "read", runtimes: [:internal]]}
    ]
  end

  def search(args, ctx) do
    protect(ctx, fn ->
      with true <- Map.keys(args) -- ~w(query cursor limit) == [],
           query when is_binary(query) <- args["query"],
           query <- query |> String.trim() |> Document.fold(),
           terms <- query |> String.split() |> Enum.uniq(),
           true <-
             length(String.codepoints(query)) in 2..128 and not String.contains?(query, <<0>>) and
               length(terms) in 1..@max_terms do
        lookup(args, ctx, query, terms)
      else
        _ -> failure(:invalid_arguments, ctx)
      end
    end)
  end

  def list(args, ctx) do
    if Map.keys(args) -- ~w(cursor limit) == [],
      do: lookup(args, ctx, nil, nil),
      else: failure(:invalid_arguments, ctx)
  end

  # The cursor carries the query text; the indexes match its terms.
  defp lookup(args, ctx, query, terms) do
    Worker.hint(ctx.agent_id, ctx.session_id)

    protect(ctx, fn ->
      with limit <- args["limit"] || 10,
           true <- (is_integer(limit) and limit in 1..20) || {:error, :invalid_arguments},
           {:ok, state} <- Source.read(ctx.agent_id, ctx.session_id),
           {:ok, {ceiling, before_seq, before_part}} <-
             cursor(args["cursor"], query, state.last_seq),
           {:ok, {position, hot, resume}} <-
             Hot.snapshot(
               ctx.agent_id,
               ctx.session_id,
               terms,
               ceiling,
               before_seq,
               before_part,
               limit + 1
             )
             |> stage(:hot_index_unavailable),
           {:ok, cold} <-
             cold(
               ctx,
               terms,
               cold_ceiling(ceiling, position, resume),
               before_seq,
               before_part,
               limit + 1
             )
             |> stage(:cold_index_unavailable) do
        rows = Enum.sort_by(hot ++ cold, &{&1["seq"], &1["part"]}, :desc)
        page = Enum.take(rows, limit)
        # A search that stopped inside the hot range continues there, not below the last hit.
        next = if length(rows) > limit, do: List.last(page), else: resume_row(resume)

        response = %{
          "results" => Enum.map(page, &hit(&1, terms)),
          "scope" => "current_session",
          "source_through" => ceiling,
          "indexed_through" => position.indexed,
          "complete" => position.indexed >= ceiling,
          "has_more" => next != nil,
          "next_cursor" => if(next, do: encode_cursor(query, ceiling, next))
        }

        # Episodes are summaries a later compaction replaced: the summary still
        # in model context sits above compacted_seq and is not one.
        episode_ceiling = min(ceiling, state[:compacted_seq] || 0)
        {episodes, rows} = episodes(ctx, terms, args["cursor"], episode_ceiling)
        response = if episodes, do: Map.put(response, "episodes", episodes), else: response
        # items index results first, then episodes, one each.
        labelled(response, page ++ rows, ctx)
      else
        error -> failure(error, ctx)
      end
    end)
  end

  # The first page of a search also lists the best matching compaction
  # summaries that a later compaction replaced. The episode lookup is
  # additive: no match or a failure leaves it out.
  defp episodes(_ctx, nil, _cursor, _ceiling), do: {nil, []}
  defp episodes(_ctx, _terms, cursor, _ceiling) when not is_nil(cursor), do: {nil, []}
  defp episodes(_ctx, _terms, nil, ceiling) when ceiling <= 0, do: {nil, []}

  defp episodes(ctx, terms, nil, ceiling) do
    kind = Episodes.kind()
    limit = Episodes.scan_limit()

    with {:ok, hot} <- Hot.summaries(ctx.agent_id, ctx.session_id, kind, terms, ceiling, limit),
         {:ok, cold} <-
           Worker.cold().summaries(ctx.agent_id, ctx.session_id, kind, terms, ceiling, limit) do
      case Episodes.rank(hot ++ cold, terms) do
        [] ->
          {nil, []}

        ranked ->
          {Enum.map(ranked, &Map.delete(&1, "label")),
           Enum.map(ranked, &%{"label" => &1["label"]})}
      end
    else
      error ->
        Logger.warning(
          "history episodes skipped detail=#{inspect(error, limit: 8)} " <>
            "agent=#{ctx[:agent_id]} session=#{ctx[:session_id]}"
        )

        {nil, []}
    end
  rescue
    exception ->
      Logger.warning("history episodes skipped exception=#{inspect(exception.__struct__)}")
      {nil, []}
  end

  def get(args, ctx) do
    protect(ctx, fn ->
      with true <- Map.keys(args) -- ~w(seq offset) == [] || {:error, :invalid_arguments},
           seq <- args["seq"],
           true <- (is_integer(seq) and seq > 0) || {:error, :invalid_arguments},
           offset <- args["offset"] || 0,
           true <- (is_integer(offset) and offset >= 0) || {:error, :invalid_arguments},
           {:ok, state} <- Source.read(ctx.agent_id, ctx.session_id),
           {:ok, record} <- Source.record(ctx.agent_id, state, seq) do
        text = Document.text(record)
        length = String.length(text)
        part = String.slice(text, offset, 8000)

        result = %{
          "seq" => seq,
          "kind" => record.kind,
          "role" => record.data["role"],
          "tool_name" => record.data["tool_name"],
          "tool_call_id" => record.data["tool_call_id"],
          "created_at" => record.data["created_at"] || record.data["stored_at_ms"],
          "text" => part,
          "next_offset" => if(offset + 8000 < length, do: offset + 8000)
        }

        labelled(result, [%{"label" => Document.label(record)}], ctx)
      else
        error -> failure(error, ctx)
      end
    end)
  end

  # Cold rows sort below every hot row, so they wait until the hot scan finishes.
  defp cold_ceiling(ceiling, position, nil), do: min(ceiling, position.cold)
  defp cold_ceiling(_ceiling, _position, _resume), do: 0

  defp resume_row(nil), do: nil
  defp resume_row({seq, part}), do: %{"seq" => seq, "part" => part}

  defp cold(_, _, 0, _, _, _), do: {:ok, []}

  defp cold(ctx, q, ceiling, seq, part, limit),
    do: Worker.cold().search(ctx.agent_id, ctx.session_id, q, ceiling, seq, part, limit)

  defp hit(row, nil) do
    row
    |> Map.take(~w(seq kind tool_name))
    |> Map.put("preview", String.slice(row["text"], 0, 160))
  end

  defp hit(row, [first | _]) do
    {byte, _} = :binary.match(row["text"], first)
    prefix = binary_part(row["text"], 0, byte) |> String.length()

    row
    |> Map.take(~w(seq part kind tool_name))
    |> Map.put("snippet", String.slice(row["text"], max(0, prefix - 80), 400))
  end

  defp cursor(nil, _q, last), do: {:ok, {last, last + 1, 0}}

  defp cursor(raw, q, last) when is_binary(raw) and byte_size(raw) <= 1024 do
    with {:ok, json} <- Base.url_decode64(raw, padding: false),
         {:ok, [^q, ceiling, seq, part]} <- Jason.decode(json),
         true <-
           is_integer(ceiling) and ceiling >= 0 and ceiling <= last and
             is_integer(seq) and seq > 0 and seq <= ceiling and is_integer(part) and part >= 0 and
             part < 4_294_967_295 do
      {:ok, {ceiling, seq, part}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_, _, _), do: {:error, :invalid_cursor}

  defp encode_cursor(q, c, last),
    do: Jason.encode!([q, c, last["seq"], last["part"]]) |> Base.url_encode64(padding: false)

  defp labelled(result, rows, ctx) do
    content = Jason.encode!(result)

    if is_map(ctx[:ifc]) do
      labels = Enum.map(rows, & &1["label"])
      joined = Enum.reduce(labels, ["public"], &SalixAgent.IFC.FileLabels.join_encoded/2)

      items =
        labels
        |> Enum.with_index()
        |> Enum.map(fn {label, index} -> %{"index" => index, "label" => label} end)

      {:tool_ifc, content, [], %{"label" => joined, "items" => items}}
    else
      content
    end
  end

  # Hot and cold index stores return their own errors; the stage names which one failed.
  defp stage({:error, reason}, failed), do: {:error, {failed, reason}}
  defp stage(result, _failed), do: result

  @reasons ~w(invalid_arguments invalid_cursor unsupported_storage_format source_gap not_found
              hot_index_unavailable cold_index_unavailable index_timeout index_busy)a

  defp reason({:error, {reason, _detail}}) when reason in @reasons, do: reason
  defp reason({:error, reason}) when reason in @reasons, do: reason
  defp reason(reason) when reason in @reasons, do: reason
  defp reason(_other), do: :unavailable

  defp failure(error, ctx) do
    reason = reason(error)

    Logger.warning(
      "history tool failed reason=#{reason} detail=#{inspect(error, limit: 8)} " <>
        "agent=#{ctx[:agent_id]} session=#{ctx[:session_id]}"
    )

    Jason.encode!(%{
      "error" => "history_unavailable_or_invalid_request",
      "reason" => Atom.to_string(reason),
      "complete" => false,
      "message" =>
        "History lookup failed (#{reason}). Do not interpret this as no matches. " <>
          "Correct the arguments or retry later."
    })
  end

  defp protect(ctx, fun) do
    fun.()
  rescue
    exception in Postgrex.Error ->
      case exception.postgres do
        %{code: :query_canceled} -> failure(:index_timeout, ctx)
        %{code: :lock_not_available} -> failure(:index_busy, ctx)
        _ -> failure({:exception, Postgrex.Error}, ctx)
      end

    exception ->
      failure({:exception, exception.__struct__}, ctx)
  catch
    kind, _ -> failure({:caught, kind}, ctx)
  end
end
