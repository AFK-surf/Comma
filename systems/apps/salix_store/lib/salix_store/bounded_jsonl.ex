defmodule SalixStore.BoundedJsonl do
  @moduledoc """
  CAS append/read helpers for bounded JSONL objects.

  `append/3` returns `{:ok, %{rows: rows, body: body}}` on success: the
  object's decoded rows and encoded bytes as settled by this call — the
  freshly written object on the put path, the already-present object on the
  duplicate path. Callers maintaining a derived index over the object can
  compute it from this payload instead of reading the object back. On the put
  path the appended row is the caller's own map, not a JSON round-trip of it.
  """

  alias SalixStore.S3

  def append(key, record, opts), do: append(key, record, opts, opts[:attempts] || 8)
  defp append(_key, _record, _opts, 0), do: {:error, :precondition_failed}

  defp append(key, record, opts, attempts) do
    case (opts[:store] || S3).get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, rows} <- decode_strict(body, opts[:decode_error] || :invalid_jsonl) do
          cond do
            duplicate?(rows, record, opts[:identity_fields]) ->
              {:ok, %{rows: rows, body: body}}

            conflict?(rows, record, opts[:conflict_fields]) ->
              {:error, :precondition_failed}

            length(rows) >= opts[:max_lines] ->
              {:error, :segment_full}

            true ->
              put(key, rows ++ [record], [if_match: etag], opts, attempts)
          end
        end

      {:error, :not_found} ->
        put(key, [record], [if_none_match: "*"], opts, attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put(key, rows, condition, opts, attempts) do
    body = encode(rows)

    if byte_size(body) > opts[:max_bytes] do
      if length(rows) == 1,
        do: {:error, opts[:oversize_error] || :segment_full},
        else: {:error, :segment_full}
    else
      case (opts[:store] || S3).put(key, body, condition) do
        {:ok, _} -> {:ok, %{rows: rows, body: body}}
        {:error, :precondition_failed} -> append(key, List.last(rows), opts, attempts - 1)
        {:error, {:ambiguous, _}} -> append(key, List.last(rows), opts, attempts - 1)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp duplicate?(rows, record, fields) do
    identity = Enum.find_value(fields || [], &record[&1])

    not is_nil(identity) and
      Enum.any?(rows, &(Enum.find_value(fields, fn field -> &1[field] end) == identity))
  end

  defp conflict?(rows, record, fields) do
    Enum.any?(fields || [], fn {sequence_field, identity_field} ->
      sequence = record[sequence_field]

      is_integer(sequence) and
        Enum.any?(rows, &(&1[sequence_field] == sequence and not is_nil(&1[identity_field])))
    end)
  end

  def decode(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, record} when is_map(record) -> [record]
        _ -> []
      end
    end)
  end

  def decode_strict(body, error_reason \\ :invalid_jsonl)

  def decode_strict(body, error_reason) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case Jason.decode(line) do
        {:ok, record} when is_map(record) -> {:cont, {:ok, [record | rows]}}
        _invalid -> {:halt, {:error, error_reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  def decode_strict(_body, error_reason), do: {:error, error_reason}

  def encode(records), do: Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
end
