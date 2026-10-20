defmodule SalixStore.BoundedSnapshotTest do
  use SystemsClock.Case, async: true
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
end
