defmodule SalixStore.BoundedSnapshot do
  @moduledoc """
  Bounded snapshot decompression using OTP streaming codecs, not frame-size
  estimates. The caller may decode the ETF only after this boundary succeeds.
  Bounds output buffers per layer, not ETF heap expansion or concurrent readers.
  """

  def inflate(bytes, limit), do: inflate(bytes, limit, 0)
  defp inflate(_, _, depth) when depth > 3, do: {:error, :invalid_snapshot}

  defp inflate(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bytes, limit, depth) do
    {:ok, ctx} = :zstd.context(:decompress)

    try do
      with {:ok, raw} <- zstd(ctx, bytes, limit, 0, []) do
        inflate(raw, limit, depth + 1)
      end
    after
      :zstd.close(ctx)
    end
  end

  defp inflate(<<0x1F, 0x8B, _::binary>> = bytes, limit, depth) do
    with {:ok, raw} <- zlib(bytes, limit, 31) do
      inflate(raw, limit, depth + 1)
    end
  end

  defp inflate(<<131, 80, _declared::32, bytes::binary>>, limit, _depth) do
    with {:ok, raw} <- zlib(bytes, limit - 1, 15) do
      {:ok, <<131, raw::binary>>}
    else
      {:error, {:snapshot_too_large, stats}} ->
        {:error, {:snapshot_too_large, %{limit: limit, observed: stats.observed + 1}}}
    end
  end

  defp inflate(bytes, limit, _) when byte_size(bytes) > limit,
    do: oversized(limit, byte_size(bytes))

  defp inflate(bytes, _, _), do: {:ok, bytes}

  defp zstd(ctx, bytes, limit, size, chunks) do
    case :zstd.stream(ctx, bytes) do
      {:continue, rest, out} ->
        seen = size + byte_size(out)

        if seen > limit,
          do: oversized(limit, seen),
          else: zstd(ctx, rest, limit, seen, [out | chunks])

      {:continue, out} ->
        seen = size + byte_size(out)

        if seen > limit do
          oversized(limit, seen)
        else
          # stream/2 drained the input; empty finish validates frame completion,
          # rather than asking finish/2 to expand a large remaining input itself.
          {:done, tail} = :zstd.finish(ctx, <<>>)
          seen = seen + IO.iodata_length(tail)

          if seen > limit,
            do: oversized(limit, seen),
            else: {:ok, IO.iodata_to_binary([Enum.reverse([out | chunks]), tail])}
        end
    end
  end

  defp zlib(bytes, limit, bits) do
    ctx = :zlib.open()

    try do
      :ok = :zlib.inflateInit(ctx, bits)
      result = zlib_stream(ctx, bytes, limit, 0, [])
      if match?({:ok, _}, result), do: :zlib.inflateEnd(ctx)
      result
    after
      :zlib.close(ctx)
    end
  end

  defp zlib_stream(ctx, bytes, limit, size, chunks) do
    {status, out} = :zlib.safeInflate(ctx, bytes)
    seen = size + IO.iodata_length(out)

    cond do
      seen > limit ->
        oversized(limit, seen)

      status == :continue ->
        zlib_stream(ctx, <<>>, limit, seen, [out | chunks])

      status == :finished ->
        {:ok, chunks |> then(&Enum.reverse([out | &1])) |> IO.iodata_to_binary()}
    end
  end

  defp oversized(limit, seen),
    do: {:error, {:snapshot_too_large, %{limit: limit, observed: seen}}}
end
