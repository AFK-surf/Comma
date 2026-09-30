defmodule SalixStore.ArchiveLogTest do
  use ExUnit.Case, async: true

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

    test "atom and string keys converge on the same wire form" do
      atoms = ArchiveLog.shape("message", 1, %{id: 7, content: "hi", meta: %{tool: "fs"}})

      strings =
        ArchiveLog.shape("message", 1, %{
          "id" => 7,
          "content" => "hi",
          "meta" => %{"tool" => "fs"}
        })

      assert ArchiveLog.encode([atoms]) == ArchiveLog.encode([strings])
    end

    test "seq lives at the top level only and survives a round trip" do
      [decoded] = [record(9)] |> ArchiveLog.encode() |> ArchiveLog.decode!()

      assert decoded.seq == 9
      assert decoded.kind == "message"
      refute Map.has_key?(decoded.data, "seq")
      assert decoded.data["content"] == "c9"
    end

    test "an inbound record carrying its own seq cannot smuggle it into data" do
      shaped = ArchiveLog.shape("message", 3, %{"seq" => 98, "id" => 3, seq: 99})

      assert shaped.seq == 3
      refute Map.has_key?(shaped.data, "seq")
    end
  end

  describe "append shape" do
    test "every line is newline-terminated so appends concatenate" do
      first = ArchiveLog.encode([record(1), record(2)])
      rest = ArchiveLog.encode([record(3)])

      assert String.ends_with?(first, "\n")
      assert (first <> rest) |> ArchiveLog.decode!() |> Enum.map(& &1.seq) == [1, 2, 3]
    end

    test "encoding the same records twice yields the same bytes" do
      records = Enum.map(1..50, &record/1)

      assert ArchiveLog.encode(records) == ArchiveLog.encode(records)

      # Encoding a prefix is a byte prefix of encoding the whole. This is NOT
      # a licence to rebuild the object from memory — the object is the
      # authority and is only ever extended. It is what lets the writer
      # compare what the object already holds ABOVE the catalog against its
      # own encoding of those records, which is how its own landed-but-
      # uncommitted append is told apart from a foreign object.
      prefix = ArchiveLog.encode(Enum.take(records, 20))
      assert binary_part(ArchiveLog.encode(records), 0, byte_size(prefix)) == prefix
    end

    test "out-of-order records are a programming error, not silent corruption" do
      assert_raise ArgumentError, fn -> ArchiveLog.encode([record(2), record(1)]) end
      assert_raise ArgumentError, fn -> ArchiveLog.encode([record(1), record(1)]) end
    end
  end

  describe "message_count" do
    test "counts only messages — the catalog's paging credit" do
      records = [
        record(1),
        record(2, "fact", %{"kind" => "connector_reconnected"}),
        record(3, "async_result", %{"tool_call_id" => "c"}),
        record(4)
      ]

      assert ArchiveLog.message_count(records) == 2
      assert ArchiveLog.message_count([]) == 0
    end
  end

  test "a malformed line is a hard decode failure, never a partial read" do
    bytes = ArchiveLog.encode([record(1), record(2)]) <> "{ truncated\n"

    assert_raise Jason.DecodeError, fn -> ArchiveLog.decode!(bytes) end
  end
end
