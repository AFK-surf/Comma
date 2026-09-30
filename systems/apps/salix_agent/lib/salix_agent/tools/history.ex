defmodule SalixAgent.Tools.History do
  @moduledoc "Agent-only retrieval of original records in the current internal Session."
  alias SalixAgent.SessionHistory.{Source, Document, Hot, Worker}
  @normal SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @search %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Literal text, 2 to 128 Unicode code points."
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
       "Search original messages and tool results in this Session, including content removed from model context by compaction. No cross-Session search. Literal normalized substring matching. Inspect complete and indexed_through: no matches in an incomplete index does not establish absence. Use history.get on a hit to read its original text.",
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
    protect(fn ->
      with true <- Map.keys(args) -- ~w(query cursor limit) == [],
           query when is_binary(query) <- args["query"],
           query <- query |> String.trim() |> Document.fold(),
           true <-
             length(String.codepoints(query)) in 2..128 and not String.contains?(query, <<0>>) do
        lookup(args, ctx, query)
      else
        _ -> failure()
      end
    end)
  end

  def list(args, ctx) do
    if Map.keys(args) -- ~w(cursor limit) == [],
      do: lookup(args, ctx, nil),
      else: failure()
  end

  defp lookup(args, ctx, query) do
    Worker.hint(ctx.agent_id, ctx.session_id)

    protect(fn ->
      with limit <- args["limit"] || 10,
           true <- is_integer(limit) and limit in 1..20,
           {:ok, state} <- Source.read(ctx.agent_id, ctx.session_id),
           {:ok, {ceiling, before_seq, before_part}} <-
             cursor(args["cursor"], query, SalixAgent.InternalSession.get(state, :last_seq)),
           {:ok, {position, hot}} <-
             Hot.snapshot(
               ctx.agent_id,
               ctx.session_id,
               query,
               ceiling,
               before_seq,
               before_part,
               limit + 1
             ),
           {:ok, cold} <-
             cold(ctx, query, min(ceiling, position.cold), before_seq, before_part, limit + 1) do
        Worker.hint(ctx.agent_id, ctx.session_id)
        rows = Enum.sort_by(hot ++ cold, &{&1["seq"], &1["part"]}, :desc)
        page = Enum.take(rows, limit)
        last = List.last(page)

        response = %{
          "results" => Enum.map(page, &hit(&1, query)),
          "scope" => "current_session",
          "source_through" => ceiling,
          "indexed_through" => position.indexed,
          "complete" => position.indexed >= ceiling,
          "has_more" => length(rows) > limit,
          "next_cursor" => if(length(rows) > limit, do: encode_cursor(query, ceiling, last))
        }

        labelled(response, page, ctx)
      else
        _ -> failure()
      end
    end)
  end

  def get(args, ctx) do
    protect(fn ->
      with true <- Map.keys(args) -- ~w(seq offset) == [],
           seq when is_integer(seq) and seq > 0 <- args["seq"],
           offset <- args["offset"] || 0,
           true <- is_integer(offset) and offset >= 0,
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

        labelled(
          result,
          [%{"label" => get_in(record.data, ["ifc", "label"]) || ["agent_private"]}],
          ctx
        )
      else
        _ -> failure()
      end
    end)
  end

  defp cold(_, _, 0, _, _, _), do: {:ok, []}

  defp cold(ctx, q, ceiling, seq, part, limit),
    do: Worker.cold().search(ctx.agent_id, ctx.session_id, q, ceiling, seq, part, limit)

  defp hit(row, nil) do
    row
    |> Map.take(~w(seq kind tool_name))
    |> Map.put("preview", String.slice(row["text"], 0, 160))
  end

  defp hit(row, q) do
    {byte, _} = :binary.match(row["text"], q)
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

  defp failure,
    do:
      Jason.encode!(%{
        "error" => "history_unavailable_or_invalid_request",
        "complete" => false,
        "message" =>
          "History search did not complete. Do not interpret this as no matches. Retry later or correct the arguments. External runtime history is unsupported."
      })

  defp protect(fun) do
    fun.()
  rescue
    _ -> failure()
  catch
    _, _ -> failure()
  end
end
