defmodule SalixAgent.InternalSessionArchiveReader do
  @moduledoc """
  Read-only archive compatibility boundary. A session may retain a frozen JSONL
  prefix followed by immutable ETF segments. The shared catalog addresses both
  representations without listing objects or loading unrelated history.
  """
  alias SalixAgent.InternalSession
  alias SalixStore.{ArchiveLog, Keys, S3, SealedSegments}

  def catalog(session) do
    legacy =
      for [first, last, messages, offset, length] <-
            InternalSession.get(session, :archive_chunks) || [],
          do: %{first: first, last: last, messages: messages, offset: offset, length: length}

    segments =
      for [first, last, messages, uncomp] <- InternalSession.get(session, :segment_catalog) || [],
          do: %{first: first, last: last, messages: messages, uncomp: uncomp}

    directory = InternalSession.get(session, :archive_refs)
    refs = directory || %{}

    (legacy ++ segments)
    |> Enum.map(fn span ->
      case refs[span.first] do
        nil when is_map(directory) ->
          Map.put(span, :missing_locator, true)

        nil ->
          span

        row ->
          span =
            Map.merge(span, %{
              object_key: row["object_key"],
              encoding: row["encoding"],
              source_session: row["source_session"]
            })

          if is_binary(row["object_key"]), do: span, else: Map.put(span, :missing_locator, true)
      end
    end)
    |> Enum.sort_by(& &1.first)
  end

  def committed_spans(state) do
    catalog = catalog(state)

    tiled =
      Enum.reduce_while(catalog, {1, 0, :legacy}, fn
        %{first: first, last: last, offset: offset, length: length}, {seq, byte, :legacy}
        when first == seq and last >= first and offset == byte and length > 0 ->
          {:cont, {last + 1, byte + length, :legacy}}

        %{first: first, last: last, uncomp: _}, {seq, byte, _}
        when first == seq and last >= first ->
          {:cont, {last + 1, byte, :segments}}

        _, _ ->
          {:halt, :broken}
      end)

    archived_through = InternalSession.archived_through(state)

    case tiled do
      {next_seq, _, _} when next_seq == archived_through + 1 ->
        {:ok, catalog}

      _ ->
        {:error,
         {:archive_incomplete,
          %{expected_through: archived_through, catalog: catalog, reason: :catalog_mismatch}}}
    end
  end

  def read(agent_id, session, spans) do
    spans
    |> Enum.sort_by(& &1.first)
    |> Enum.chunk_by(&{encoding(&1), &1[:object_key]})
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, acc} ->
      case read_group(agent_id, session, group) do
        {:ok, records} -> {:cont, {:ok, [records | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> flatten_result()
  end

  defp read_group(agent_id, session, [first | _] = spans) do
    case encoding(first) do
      "jsonl" ->
        spans
        |> contiguous_runs()
        |> Enum.reduce_while({:ok, []}, fn run, {:ok, acc} ->
          case read_jsonl(agent_id, session, run) do
            {:ok, records} -> {:cont, {:ok, [records | acc]}}
            error -> {:halt, error}
          end
        end)
        |> flatten_result()

      "etf.zst" ->
        Enum.reduce_while(spans, {:ok, []}, fn span, {:ok, acc} ->
          case read_segment(agent_id, session, span) do
            {:ok, records} -> {:cont, {:ok, [records | acc]}}
            error -> {:halt, error}
          end
        end)
        |> flatten_result()

      other ->
        {:error, {:unsupported_archive_encoding, other}}
    end
  end

  defp encoding(span),
    do: span[:encoding] || if(Map.has_key?(span, :offset), do: "jsonl", else: "etf.zst")

  defp read_jsonl(_agent_id, _session, [%{missing_locator: true} = span | _]),
    do: {:error, {:archive_incomplete, %{missing_locator: {span.first, span.last}}}}

  defp read_jsonl(_agent_id, _session, [%{offset: offset, length: length} = span | _])
       when not is_integer(offset) or not is_integer(length),
       do: {:error, {:archive_incomplete, %{missing_locator: {span.first, span.last}}}}

  defp read_jsonl(agent_id, session, [first | _] = run) do
    key =
      first[:object_key] ||
        Keys.agent_internal_runtime_session_archive(agent_id, InternalSession.session_id(session))

    read_run(key, run)
  end

  defp flatten_result({:ok, runs}), do: {:ok, runs |> Enum.reverse() |> List.flatten()}
  defp flatten_result(error), do: error

  defp read_segment(_agent_id, _session, %{missing_locator: true} = span),
    do: {:error, {:archive_incomplete, %{missing_locator: {span.first, span.last}}}}

  defp read_segment(_agent_id, _session, %{encoding: encoding}) when encoding != "etf.zst",
    do: {:error, {:unsupported_archive_encoding, encoding}}

  defp read_segment(agent_id, session, span) do
    key =
      span[:object_key] ||
        Keys.agent_internal_runtime_session_segment(
          agent_id,
          InternalSession.session_id(session),
          span.first
        )

    expected = {span.first, span.last}

    case S3.get(key) do
      {:ok, %{body: body}} ->
        case segment_records(body, span) do
          {:ok, records} ->
            {:ok, records}

          {:error, detail} ->
            {:error, {:archive_incomplete, Map.merge(detail, %{key: key, expected: expected})}}
        end

      {:error, :not_found} ->
        {:error, {:archive_incomplete, %{missing_span: expected, key: key}}}

      {:error, reason} ->
        {:error, {:archive_unreadable, key, reason}}
    end
  end

  def read_descriptors(spans) do
    spans
    |> Enum.map(fn row ->
      span = %{
        first: row["first_seq"],
        last: row["last_seq"],
        messages: row["message_count"],
        object_key: row["object_key"],
        encoding: row["encoding"],
        source_session: row["source_session"]
      }

      span =
        if row["encoding"] == "jsonl",
          do: Map.merge(span, %{offset: row["byte_offset"], length: row["byte_length"]}),
          else: span

      if is_binary(row["object_key"]), do: span, else: Map.put(span, :missing_locator, true)
    end)
    |> then(&read(nil, nil, &1))
  end

  defp segment_records(body, span) do
    with {:ok, records} <- SealedSegments.decode_safe(body) do
      if hd(records).seq == span.first and List.last(records).seq == span.last and
           ArchiveLog.message_count(records) == span.messages do
        {:ok, records}
      else
        {:error, %{reason: :segment_seq_mismatch}}
      end
    end
  end

  defp contiguous_runs([first | rest]) do
    {runs, current} =
      Enum.reduce(rest, {[], [first]}, fn span, {runs, [previous | _] = current} ->
        if is_integer(previous.offset) and is_integer(previous.length) and
             span.first == previous.last + 1 and span.offset == previous.offset + previous.length and
             span[:object_key] == previous[:object_key] and encoding(span) == encoding(previous) and
             not Map.get(span, :missing_locator, false),
           do: {runs, [span | current]},
           else: {[Enum.reverse(current) | runs], [span]}
      end)

    [Enum.reverse(current) | runs] |> Enum.reverse()
  end

  defp read_run(key, run) do
    offset = run |> List.first() |> Map.fetch!(:offset)
    length = Enum.reduce(run, 0, &(&1.length + &2))
    expected = {List.first(run).first, List.last(run).last}

    case S3.get(key, range: {offset, length}) do
      {:ok, %{body: bytes}} ->
        records = ArchiveLog.decode!(bytes)

        actual =
          {records |> Enum.map(& &1.seq) |> Enum.min(fn -> nil end),
           records |> Enum.map(& &1.seq) |> Enum.max(fn -> nil end)}

        if actual == expected do
          {:ok, records}
        else
          {:error,
           {:archive_incomplete,
            %{expected: expected, actual: actual, reason: :span_bounds_mismatch}}}
        end

      {:error, :not_found} ->
        {:error, {:archive_incomplete, %{missing_span: expected, key: key}}}

      {:error, reason} ->
        {:error, {:archive_unreadable, key, reason}}
    end
  end
end
