defmodule SalixStore.SealedSegments do
  @moduledoc """
  Format-3 sealed-segment encoding, first-crossing cuts, and record validation.
  Objects are named by first seq; a landed object's decoded immutable records
  own its boundary. Readers use only the hot object's committed catalog;
  sealers may adopt matching orphans. See
  docs/storage-search.md and
  tla/salix/SessionSegmentSeal.tla.
  """

  alias SalixStore.{ArchiveLog, Codec}

  @default_line_bytes 16 * 1024 * 1024

  @type entry :: [integer()]

  @typedoc """
  A derived segment: the records it holds plus the catalog entry fields.
  """
  @type segment :: %{
          required(:records) => [ArchiveLog.log_record()],
          required(:first_seq) => pos_integer(),
          required(:last_seq) => pos_integer(),
          required(:messages) => non_neg_integer(),
          required(:uncomp_bytes) => pos_integer()
        }

  @doc "The effective seal line in bytes."
  @spec line_bytes() :: pos_integer()
  def line_bytes,
    do: Application.get_env(:salix_store, :seal_line_bytes, @default_line_bytes)

  @doc """
  The next segment through the optional ceiling, including a partial tail.
  The crossing record stays in the segment, including oversized records.
  Only the consumed prefix is visited, so successive cuts take linear work.
  """
  @spec next_segment([ArchiveLog.log_record()], pos_integer(), non_neg_integer() | nil) ::
          segment() | nil
  def next_segment(records, line_bytes, ceiling \\ nil)
      when is_integer(line_bytes) and line_bytes > 0 do
    walk(records, [], 0, line_bytes, ceiling, nil)
  end

  defp walk([], current, bytes, _line, _ceiling, _previous), do: finish(current, bytes)

  defp walk([%{seq: seq} | _], current, bytes, _line, ceiling, _previous)
       when is_integer(ceiling) and seq > ceiling,
       do: finish(current, bytes)

  defp walk([%{seq: seq} = record | rest], current, bytes, line, ceiling, previous) do
    if previous != nil and seq != previous + 1 do
      raise ArgumentError, "sealed segment records must be seq-ascending and contiguous"
    end

    bytes = bytes + record_uncomp_bytes(record)
    current = [record | current]

    if bytes >= line,
      do: finish(current, bytes),
      else: walk(rest, current, bytes, line, ceiling, seq)
  end

  defp finish([], _bytes), do: nil
  defp finish(current, bytes), do: build_segment(Enum.reverse(current), bytes)

  @doc "Segments in an eligible stream, including the partial tail."
  @spec sealable([ArchiveLog.log_record()], pos_integer()) :: [segment()]
  def sealable(records, line_bytes) when is_integer(line_bytes) and line_bytes > 0 do
    do_sealable(records, line_bytes, [])
  end

  defp do_sealable(records, line, done) do
    case next_segment(records, line) do
      nil ->
        Enum.reverse(done)

      segment ->
        rest = Enum.drop_while(records, &(&1.seq <= segment.last_seq))
        do_sealable(rest, line, [segment | done])
    end
  end

  @doc """
  Encode one segment body: the shaped records as pinned-minor ETF inside one
  zstd stream.
  """
  @spec encode([ArchiveLog.log_record()]) :: binary()
  def encode(records), do: Codec.encode_zstd_etf(records)

  @doc "Decode a segment body back into its shaped records."
  @spec decode(binary()) :: [ArchiveLog.log_record()]
  def decode(bin) when is_binary(bin), do: Codec.decode_zstd_etf(bin)

  @doc "Decode and validate the record envelope without raising into a reader."
  @spec decode_safe(binary()) :: {:ok, [ArchiveLog.log_record()]} | {:error, map()}
  def decode_safe(bin) when is_binary(bin) do
    records = decode(bin)

    case validate_records(records, nil) do
      :ok -> {:ok, records}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, %{reason: :segment_body_invalid}}
  end

  @doc false
  def validate([]), do: :ok
  def validate(records), do: validate_records(records, nil)

  # The envelope is shared with ArchiveLog; payload keys remain strings.
  # Validate every field consumed by paging/redaction, not just seq. A record
  # with seq but no data would otherwise pass the boundary check then crash
  # redaction or silently disappear from the transcript.
  defp validate_records([], previous) when is_integer(previous), do: :ok

  defp validate_records([%{seq: seq, kind: kind, data: data} | rest], previous)
       when is_integer(seq) and seq > 0 and is_binary(kind) and
              is_map(data) do
    if is_nil(previous) or seq == previous + 1,
      do: validate_records(rest, seq),
      else: {:error, %{reason: :segment_seq_mismatch}}
  end

  defp validate_records(_, _), do: {:error, %{reason: :segment_body_invalid}}

  @doc """
  The catalog entry for a derived segment. Entries are positional
  `[first_seq, last_seq, message_count, uncomp_bytes]`: the seq interval the
  segment covers, how many of its records are messages (so paging can skip
  message-less segments without reading them), and the sum of per-record ETF
  sizes (diagnostic only; not a hard transfer or decompression bound).
  """
  @spec entry(segment()) :: entry()
  def entry(%{first_seq: first, last_seq: last, messages: messages, uncomp_bytes: uncomp}),
    do: [first, last, messages, uncomp]

  @doc """
  The catalog entry for an ADOPTED segment (records decoded from a landed
  object): same shape as `entry/1`, sizes measured with the same per-record
  encoding the fresh cut uses.
  """
  @spec entry_for([ArchiveLog.log_record()]) :: entry()
  def entry_for(records) do
    uncomp = Enum.reduce(records, 0, fn record, acc -> acc + record_uncomp_bytes(record) end)
    entry(build_segment(records, uncomp))
  end

  @doc """
  Parse a persisted catalog entry, dropping anything malformed. Mirrors
  `ArchiveLog`'s contract that a corrupt entry surfaces as a reader-side
  tiling gap, never a silently shortened history.
  """
  @spec parse_entry(term()) :: entry() | nil
  def parse_entry([first, last, messages, uncomp] = entry)
      when is_integer(first) and is_integer(last) and is_integer(messages) and
             is_integer(uncomp) and first > 0 and last >= first and messages >= 0 and
             messages <= last - first + 1 and uncomp > 0,
      do: entry

  def parse_entry(_other), do: nil

  # Per-record uncompressed size: the same pinned-minor encoding the segment
  # body uses, measured once per record in the walk so segmentation stays
  # linear.
  defp record_uncomp_bytes(record),
    do: record |> :erlang.term_to_binary(minor_version: 1) |> byte_size()

  defp build_segment(records, uncomp_bytes) do
    %{
      records: records,
      first_seq: hd(records).seq,
      last_seq: List.last(records).seq,
      messages: Enum.count(records, &(&1.kind == "message")),
      uncomp_bytes: uncomp_bytes
    }
  end
end
