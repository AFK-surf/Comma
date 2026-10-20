defmodule SalixStore.SealedSegmentsTest do
  use SystemsClock.Case, async: true

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

  test "encode/decode round-trips every derived segment exactly" do
    records = Enum.map(1..5, &rec(&1, "content #{&1}")) ++ [fact(6)]

    assert Enum.all?(SealedSegments.sealable(records, 100), fn seg ->
             SealedSegments.decode(SealedSegments.encode(seg.records)) == seg.records
           end)
  end

  test "OTP decoder reads the frame produced by ezstd 1.2.4" do
    body = File.read!(Path.join(__DIR__, "fixtures/ezstd-1.2.4.etf.zst"))
    records = [%{seq: 1, kind: "message", data: %{"content" => "legacy ezstd frame"}}]
    assert SealedSegments.decode(body) == records
    assert Codec.decode_snapshot(body) == records
  end

  describe "zstd-ETF wire codec (Codec.encode_zstd_etf/decode_zstd_etf)" do
  end
end
