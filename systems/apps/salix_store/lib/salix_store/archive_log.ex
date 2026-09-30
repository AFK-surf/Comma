defmodule SalixStore.ArchiveLog do
  @moduledoc """
  The canonical WIRE FORM of a session's append-only archive object.

  A format-2 session keeps ONE archive object (`.../archive.jsonl`). Every
  compaction appends the records the summary now covers and advances
  `archived_through` to `compacted_seq` in the same hot-object CAS, so no
  compacted record ever lingers in the window
  (docs/storage-search.md, 归档).

  This module only shapes, encodes and decodes those bytes. It does NOT
  decide what to write: the archive object itself is the authority on what
  is already durable, and `InternalSessionStore.append_archive/6` only ever
  EXTENDS it — validating what the object already holds, appending the
  suffix it lacks under the ETag read in the same GET, and aborting with
  `archive_ahead` when another owner has archived further. A stale owner
  must never re-derive or rewrite the prefix; that whole-object rebuild was
  tried in #798's first cut and falsified (it let a stale owner roll the
  object back, and wedged a lost advance on `archive_divergence`).

  Wire form is canonical JSONL — one record per line, every object's keys
  sorted recursively — so identical content encodes to identical bytes on
  any writer and any OTP release. That determinism is what lets the writer
  tell its OWN landed-but-uncommitted append from a foreign object: it
  compares the object's bytes above the catalog against its own encoding of
  the same records, and settles the very first append's create-once by byte
  equality. It is emphatically not a licence to re-materialize the whole
  object — the ETag precondition, not byte identity, is what fences a
  concurrent writer (`tla/salix/ArchiveAppend.tla`).

  `BoundedJsonl.encode/1` is deliberately NOT reused: it encodes maps as-is,
  which is deterministic within one VM but is not a cross-version contract.
  """

  @span_records 256

  @type log_record :: %{seq: pos_integer(), kind: String.t(), data: map()}

  @doc """
  Shape a raw in-memory record into the archive record form. Data keys are
  stringified recursively; the seq lives at the top level only.
  """
  @spec shape(String.t(), pos_integer(), map()) :: log_record()
  def shape(kind, seq, data) when is_binary(kind) and is_integer(seq) and is_map(data) do
    data =
      data
      |> Map.drop([:seq, "seq"])
      |> stringify_keys()

    %{seq: seq, kind: kind, data: data}
  end

  @doc "Encode one record as its canonical JSONL line (without the newline)."
  @spec encode_record(log_record()) :: binary()
  def encode_record(%{seq: seq, kind: kind, data: data}) do
    %{"seq" => seq, "kind" => kind, "data" => data}
    |> canonicalize()
    |> Jason.encode!()
  end

  @doc """
  Encode seq-ascending records into the bytes appended to the archive
  object. Every line is newline-terminated, so appends concatenate without
  a separator and the object is always a whole number of records.
  """
  @spec encode([log_record()]) :: binary()
  def encode(records) when is_list(records) do
    records
    |> assert_ascending!()
    |> Enum.map(&(encode_record(&1) <> "\n"))
    |> IO.iodata_to_binary()
  end

  @doc "Decode archive bytes back into records; raises on any malformed line."
  @spec decode!(binary()) :: [log_record()]
  def decode!(bytes) when is_binary(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      %{"seq" => seq, "kind" => kind, "data" => data} = Jason.decode!(line)
      %{seq: seq, kind: kind, data: data}
    end)
  end

  @doc """
  Catalog spans for `records`, which begin at byte `start_offset` of the
  archive object: `[first_seq, last_seq, messages, offset, length]`, at most
  `span_records` records each.

  Subdividing the catalog is what bounds how much a page transfers. It costs
  no object operation — the whole range is still written by ONE PUT — so
  every producer of archived records (runtime archival and the format-1
  cutover alike) must build spans through here rather than recording one
  unbounded range.
  """
  @spec spans([log_record()], non_neg_integer(), pos_integer()) :: [[non_neg_integer()]]
  def spans(records, start_offset, span_records \\ @span_records) do
    records
    |> Enum.chunk_every(span_records)
    |> Enum.map_reduce(start_offset, fn group, offset ->
      length = group |> encode() |> byte_size()

      span = [
        List.first(group).seq,
        List.last(group).seq,
        message_count(group),
        offset,
        length
      ]

      {span, offset + length}
    end)
    |> elem(0)
  end

  @doc "How many of the records are messages (the catalog's paging credit)."
  @spec message_count([log_record()]) :: non_neg_integer()
  def message_count(records) when is_list(records),
    do: Enum.count(records, &(&1.kind == "message"))

  defp assert_ascending!(records) do
    Enum.reduce(records, 0, fn %{seq: seq}, last ->
      if seq <= last, do: raise(ArgumentError, "records must ascend by seq: #{seq} after #{last}")
      seq
    end)

    records
  end

  # ---- canonical encoding ------------------------------------------------

  # Sorted-key ordered objects all the way down: byte output is independent
  # of map insertion and iteration order.
  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {key_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: to_string(key)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {key_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
