defmodule SalixStore.BoundedSnapshotTest do
  use ExUnit.Case, async: true
  alias SalixStore.Codec

  test "all supported snapshot encodings load within the actual output budget" do
    state = %{hello: "world", data: Enum.to_list(1..100)}
    raw = :erlang.term_to_binary(state)
    compressed = Codec.encode_snapshot(state)

    for bytes <- [
          raw,
          compressed,
          Codec.compress(raw),
          Codec.compress(compressed),
          Codec.encode_zstd_etf(state)
        ] do
      assert {:ok, ^state} = Codec.decode_snapshot_bounded(bytes, 4096)
    end
  end

  test "stream output, not frame size metadata or compressed size, triggers the limit" do
    raw = :erlang.term_to_binary(%{data: String.duplicate("x", 2_000_000)})
    # Disable content size in the zstd frame: a header-based guard cannot work.
    zstd = raw |> :zstd.compress(%{contentSizeFlag: false}) |> IO.iodata_to_binary()
    compressed = :erlang.term_to_binary(%{data: String.duplicate("x", 2_000_000)}, [:compressed])

    for bytes <- [raw, zstd, compressed, Codec.compress(raw), Codec.compress(compressed)] do
      assert {:error, {:snapshot_too_large, %{limit: 32_768, observed: seen}}} =
               Codec.decode_snapshot_bounded(bytes, 32_768)

      assert seen > 32_768
    end
  end

  test "oversized invalid ETF stops at size detection, before decoding" do
    bytes = :zstd.compress(String.duplicate("not ETF", 500_000)) |> IO.iodata_to_binary()
    assert {:error, {:snapshot_too_large, _}} = Codec.decode_snapshot_bounded(bytes, 32_768)
    assert {:error, :invalid_snapshot} = Codec.decode_snapshot_bounded(<<131, 1>>, 100)
  end
end
