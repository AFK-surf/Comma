defmodule SalixStore.Codec do
  @moduledoc """
  Serialization for journal segments and snapshots.

    * **Journal segments** — JSON-lines (one event object per line) so they stay
      tooling/migration/debug-friendly, then compressed.
    * **Snapshots** — Erlang term format (ETF) for speed, then compressed.

  Journal compression uses gzip through `:zlib`; format-3 sessions use OTP's
  `:zstd`. Existing object keys retain their
  historical `.zst` suffix, so readers must use this codec rather than infer
  compression from the suffix. The on-disk representation is internal and is
  never sent to a foreign reader.
  """

  @doc "Encode a list of event maps into a compressed JSON-lines segment."
  @spec encode_segment([map()]) :: binary()
  def encode_segment(events) when is_list(events) do
    events
    |> Enum.map(&Jason.encode!/1)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> compress()
  end

  @doc """
  Decode a compressed JSON-lines segment back into event maps.

  Keys stay **strings**: journal events carry dynamic, externally-influenced keys
  (session ids, message content) and decoding those to atoms would risk atom-table
  exhaustion. State machines match on string keys accordingly.
  """
  @spec decode_segment(binary()) :: [map()]
  def decode_segment(bin) do
    bin
    |> decompress()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # ETF's built-in zlib compression already shrinks snapshots; an extra gzip on
  # top (the old format) burned ~30% more CPU per commit for <1% size gain — pure
  # waste on the hot commit path, where a long-context session is re-encoded on
  # every round. Level 1 keeps compression cheap (snapshots re-encode constantly
  # and are read once on load); it costs a few % size for a ~4x speedup over the
  # zlib default level.
  @snapshot_zlevel 1

  @doc "Encode an arbitrary state term as a compressed ETF snapshot."
  @spec encode_snapshot(term()) :: binary()
  def encode_snapshot(term),
    do: :erlang.term_to_binary(term, [{:compressed, @snapshot_zlevel}])

  @doc """
  Decode an ETF snapshot. Transparently handles the legacy gzip-wrapped format
  (gzip magic `1f 8b`) and the format-3 zstd-wrapped form (zstd frame magic
  `28 b5 2f fd`) so objects written by earlier writers still load; native ETF
  starts with the version tag `131` (`0x83`).

  `:safe` is intentionally omitted because snapshots are written by us and may
  contain non-existing atoms across versions.
  """
  @spec decode_snapshot(binary()) :: term()
  def decode_snapshot(<<0x1F, 0x8B, _::binary>> = bin),
    do: bin |> decompress() |> :erlang.binary_to_term()

  def decode_snapshot(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bin),
    do: bin |> decode_zstd_etf() |> unwrap_session()

  def decode_snapshot(bin), do: :erlang.binary_to_term(bin)

  @doc "Decode a snapshot only after bounded streaming decompression succeeds."
  def decode_snapshot_bounded(bin, limit) when is_integer(limit) and limit > 0 do
    with {:ok, etf} <- SalixStore.BoundedSnapshot.inflate(bin, limit) do
      {:ok, etf |> :erlang.binary_to_term() |> unwrap_session()}
    end
  rescue
    _ -> {:error, :invalid_snapshot}
  catch
    _, _ -> {:error, :invalid_snapshot}
  end

  @doc """
  Encode current internal-session hot state. The envelope is a wire-layout
  boundary: older readers must reject it rather than discard a frozen legacy
  archive prefix while rewriting the snapshot. It is not an identity check.
  """
  def encode_session_snapshot(state), do: encode_zstd_etf({:comma_internal_session, 3, state})

  @doc """
  The ETF bytes inside a stored session snapshot, without decoding them into a
  term: the kernel decodes the session itself. Handles the same three wire
  forms as `decode_snapshot/1`.
  """
  @spec snapshot_etf(binary()) :: binary()
  def snapshot_etf(<<0x1F, 0x8B, _::binary>> = bin), do: bin |> decompress() |> snapshot_etf()

  def snapshot_etf(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bin),
    do: bin |> :zstd.decompress() |> IO.iodata_to_binary() |> snapshot_etf()

  # `term_to_binary(term, compressed: n)` wraps the term in the ETF compressed
  # tag, which the kernel decoder does not read; inflate it to plain ETF.
  def snapshot_etf(<<131, 80, _declared::32, deflated::binary>>),
    do: <<131, :zlib.uncompress(deflated)::binary>>

  def snapshot_etf(bin) when is_binary(bin), do: bin

  @doc "Like `snapshot_etf/1`, only after bounded streaming decompression succeeds."
  @spec snapshot_etf_bounded(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def snapshot_etf_bounded(bin, limit) when is_integer(limit) and limit > 0 do
    SalixStore.BoundedSnapshot.inflate(bin, limit)
  rescue
    _ -> {:error, :invalid_snapshot}
  catch
    _, _ -> {:error, :invalid_snapshot}
  end

  @doc "Compresses kernel-produced ETF bytes for Session snapshots and archive segments."
  @spec compress_snapshot_etf(binary()) :: binary()
  def compress_snapshot_etf(etf) when is_binary(etf) do
    etf |> :zstd.compress(%{compressionLevel: 3}) |> IO.iodata_to_binary()
  end

  defp unwrap_session({:comma_internal_session, 3, state}), do: state
  defp unwrap_session(other), do: other

  # OTP 28+ owns the zstd implementation and its scheduling. The repository
  # builds on OTP 29; no additional NIF or alternative runtime path is needed.
  # ETF minor 1 is a wire-format choice, not a cross-version byte-identity
  # promise. Segment settlement compares immutable decoded records.
  @spec encode_zstd_etf(term(), keyword()) :: binary()
  def encode_zstd_etf(term, opts \\ []) do
    term
    |> :erlang.term_to_binary(minor_version: 1)
    |> :zstd.compress(%{compressionLevel: Keyword.get(opts, :level, 3)})
    |> IO.iodata_to_binary()
  end

  @spec decode_zstd_etf(binary()) :: term()
  def decode_zstd_etf(bin) when is_binary(bin) do
    bin |> :zstd.decompress() |> IO.iodata_to_binary() |> :erlang.binary_to_term()
  end

  # ---- gzip compression seam ----

  @spec compress(iodata()) :: binary()
  def compress(data), do: :zlib.gzip(data)

  @spec decompress(binary()) :: binary()
  def decompress(bin), do: :zlib.gunzip(bin)
end
