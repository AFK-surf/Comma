defmodule SalixStore.SealedSegmentsTest do
  use ExUnit.Case, async: true

  alias SalixStore.{ArchiveLog, Codec, SealedSegments}

  defp rec(seq, content \\ "x") do
    ArchiveLog.shape("message", seq, %{"seq" => seq, "content" => content, "role" => "user"})
  end

  defp fact(seq) do
    ArchiveLog.shape("fact", seq, %{"seq" => seq, "type" => "llm_call_failed"})
  end

  test "segments close when accumulated bytes REACH the line, crossing record included" do
    # ~200 bytes per record, line 500: segments of 3 records (600 >= 500;
    # two records at ~400 do not close).
    records = Enum.map(1..8, &rec(&1, String.duplicate("y", 150)))
    segments = SealedSegments.sealable(records, 500)

    sizes = Enum.map(segments, &length(&1.records))
    assert hd(sizes) == 3
    # The segmentation tiles seq space with no gap and no overlap.
    firsts = Enum.map(segments, & &1.first_seq)
    follows = segments |> Enum.drop(-1) |> Enum.map(&(&1.last_seq + 1))
    assert tl(firsts) == follows
    assert hd(firsts) == 1
  end

  test "a record that crosses the line closes the segment carrying it" do
    records = [rec(1, "tiny"), rec(2, String.duplicate("z", 50_000)), rec(3, "tiny")]
    seg = SealedSegments.next_segment(records, 1000)

    # The oversized record closes the segment it enters.
    # Segment starts are always prior boundaries.
    assert seg.first_seq == 1 and seg.last_seq == 2
    assert seg.uncomp_bytes > 1000
  end

  test "message_count separates messages from facts for paging" do
    records = [
      rec(1, String.duplicate("y", 600)),
      fact(2),
      fact(3),
      rec(4, String.duplicate("y", 600))
    ]

    [seg] = SealedSegments.sealable(records, 1000)
    assert seg.messages == 2
  end

  test "encode/decode round-trips every derived segment exactly" do
    records = Enum.map(1..5, &rec(&1, "content #{&1}")) ++ [fact(6)]

    assert Enum.all?(SealedSegments.sealable(records, 100), fn seg ->
             SealedSegments.decode(SealedSegments.encode(seg.records)) == seg.records
           end)
  end

  @tag :redo_regression
  test "four times the records requires linear work even with one-record segments" do
    # Reductions measure BEAM work, not wall-clock timing. The old implementation
    # validated the entire remaining window on each cut (~16x for a 4x input).
    # Allow 6x for a linear traversal, GC and allocator differences.
    measure = fn count ->
      records = Enum.map(1..count, &rec/1)
      {:reductions, before} = Process.info(self(), :reductions)
      segments = SealedSegments.sealable(records, 1)
      {:reductions, after_count} = Process.info(self(), :reductions)
      assert length(segments) == count
      after_count - before
    end

    small = measure.(1_000)
    large = measure.(4_000)
    assert large < small * 6
  end

  test "parse_entry accepts well-formed entries and drops anything malformed" do
    assert SealedSegments.parse_entry([1, 10, 5, 1200]) == [1, 10, 5, 1200]
    assert SealedSegments.parse_entry([10, 1, 5, 1200]) == nil
    assert SealedSegments.parse_entry([1, 10, -1, 1200]) == nil
    assert SealedSegments.parse_entry([1, 10, 5, 0]) == nil
    assert SealedSegments.parse_entry([1, 10, 5]) == nil
    assert SealedSegments.parse_entry("nope") == nil
  end

  test "sealable rejects non-ascending records loudly" do
    assert_raise ArgumentError, ~r/seq-ascending/, fn ->
      SealedSegments.sealable([rec(2), rec(1)], 1000)
    end
  end

  test "OTP decoder reads the frame produced by ezstd 1.2.4" do
    body = File.read!(Path.join(__DIR__, "fixtures/ezstd-1.2.4.etf.zst"))
    records = [%{seq: 1, kind: "message", data: %{"content" => "legacy ezstd frame"}}]
    assert SealedSegments.decode(body) == records
    assert Codec.decode_snapshot(body) == records
  end

  describe "zstd-ETF wire codec (Codec.encode_zstd_etf/decode_zstd_etf)" do
    test "round-trips a multi-megabyte body" do
      records = Enum.map(1..3_000, &rec(&1, String.duplicate("z", 500)))

      body = SealedSegments.encode(records)

      assert byte_size(body) > 0
      assert SealedSegments.decode(body) == records
    end

    test "round-trips incompressible payloads" do
      # Large random payloads must round-trip even when compression does not
      # reduce their size.
      records = Enum.map(1..20, &rec(&1, :crypto.strong_rand_bytes(64_000)))

      body = SealedSegments.encode(records)

      assert SealedSegments.decode(body) == records
    end

    test "decodes a one-shot-compressed frame: transport is interchangeable" do
      records = Enum.map(1..50, &rec(&1))

      # A different writer (one-shot call, different level) produces
      # different bytes for the same records; readers settle semantically.
      foreign_body =
        IO.iodata_to_binary(
          :zstd.compress(:erlang.term_to_binary(records, minor_version: 1), %{compressionLevel: 9})
        )

      ours = SealedSegments.encode(records)

      refute foreign_body == ours
      assert SealedSegments.decode(foreign_body) == records
    end

    test "the level option changes bytes but never the decoded term" do
      records = Enum.map(1..30, &rec(&1, String.duplicate("n", 200)))

      l3 = Codec.encode_zstd_etf(records)
      l9 = Codec.encode_zstd_etf(records, level: 9)

      assert Codec.decode_zstd_etf(l3) == records
      assert Codec.decode_zstd_etf(l9) == records
    end
  end
end
