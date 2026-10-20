defmodule SalixStore.ArchiveLogTest do
  use SystemsClock.Case, async: true

  alias SalixStore.ArchiveLog

  defp record(seq, kind \\ "message", data \\ nil) do
    ArchiveLog.shape(kind, seq, data || %{"id" => seq, "content" => "c#{seq}"})
  end

  describe "canonical encoding" do
    test "keys sort recursively so map iteration order cannot change the bytes" do
      wide =
        Map.new(1..40, fn n -> {"k#{n}", %{"z" => n, "a" => %{"y" => n, "b" => n}}} end)

      one = ArchiveLog.encode([ArchiveLog.shape("message", 1, wide)])

      # A structurally identical map built in the opposite insertion order:
      # same content must mean the same bytes, or create-once settlement
      # would read another writer's identical archive as divergent.
      reversed =
        wide
        |> Enum.reverse()
        |> Map.new(fn {k, v} -> {k, v |> Enum.reverse() |> Map.new()} end)

      assert one == ArchiveLog.encode([ArchiveLog.shape("message", 1, reversed)])
    end

    test "seq lives at the top level only and survives a round trip" do
      [decoded] = [record(9)] |> ArchiveLog.encode() |> ArchiveLog.decode!()

      assert decoded.seq == 9
      assert decoded.kind == "message"
      refute Map.has_key?(decoded.data, "seq")
      assert decoded.data["content"] == "c9"
    end
  end

  describe "append shape" do
  end

  describe "message_count" do
  end
end
