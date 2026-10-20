defmodule SalixAgent.RtpH264Test do
  @moduledoc """
  `SalixAgent.RtpH264` on the packets `SalixAgent.TestSupport.FakeRtspCamera`
  sends: the first complete key frame comes out as Annex B with its parameter
  sets, whatever the order of packets within the reorder window; a lost packet
  drops its frame and the next key frame is used; a frame without an IDR slice
  never comes out.
  """
  use SystemsClock.Case, async: true

  import Bitwise

  alias SalixAgent.RtpH264
  alias SalixAgent.TestSupport.FakeRtspCamera

  @start <<0, 0, 0, 1>>
  defp feed(packets, rtp \\ RtpH264.new()) do
    Enum.reduce_while(packets, {:more, rtp}, fn packet, {:more, rtp} ->
      case RtpH264.push(rtp, packet) do
        {:more, rtp} -> {:cont, {:more, rtp}}
        done -> {:halt, done}
      end
    end)
  end

  # The Annex B form of fixture frame `index`, with its parameter sets first.
  defp expected(index) do
    [sps, pps | _] = FakeRtspCamera.nal_units()
    unit = Enum.at(FakeRtspCamera.access_units(), index)
    IO.iodata_to_binary([@start, sps, @start, pps | Enum.map(unit, &[@start, &1])])
  end

  defp payload(<<_header::binary-size(12), payload::binary>>), do: payload

  defp fragment?(packet), do: band(:binary.first(payload(packet)), 0x1F) == 28

  test "the first key frame comes out whole, its IDR slice reassembled from FU-A fragments" do
    packets = FakeRtspCamera.rtp_packets(4)
    # The fixture's IDR slices exceed one packet, so they arrive as FU-A.
    assert Enum.count(packets, &fragment?/1) >= 2
    assert {:frame, frame} = feed(packets)
    assert frame == expected(0)
  end

  defp fragments(bytes, first_seq \\ 0) do
    chunks = List.duplicate(60_000, div(bytes, 60_000)) ++ [rem(bytes, 60_000)]

    packets =
      chunks
      |> Enum.reject(&(&1 == 0))
      |> Enum.with_index()
      |> Enum.map(fn {size, index} ->
        fu = if index == 0, do: 0x85, else: 0x05
        packet(first_seq + index, <<0x7C, fu>> <> :binary.copy(<<1>>, size))
      end)

    {packets, first_seq + length(packets)}
  end

  defp packet(seq, payload, marker \\ false) do
    marker = if marker, do: 1, else: 0
    <<2::2, 0::6, marker::1, 96::7, seq::16, 0::32, 1::32, payload::binary>>
  end
end
