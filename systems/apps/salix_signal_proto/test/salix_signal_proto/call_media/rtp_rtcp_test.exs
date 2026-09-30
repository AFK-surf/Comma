defmodule SalixSignalProto.CallMedia.RtpRtcpTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.CallMedia.{Rtcp, Rtp}

  test "RTP decoding accepts CSRCs, a header extension and padding" do
    packet =
      Rtp.encode(%Rtp{
        marker: true,
        payload_type: 102,
        sequence_number: 65_535,
        timestamp: 4_294_967_295,
        ssrc: 1002,
        csrcs: [1, 2],
        # One-byte form (RFC 8285), ID 1, two bytes: a transport-wide sequence number.
        extension: {0xBEDE, <<0x11, 0x12, 0x34, 0>>},
        payload: "opus",
        padding: 3
      })

    assert {:ok, 12 + 8 + 8} == Rtp.header_size(packet)

    assert {:ok,
            %Rtp{marker: true, csrcs: [1, 2], extension: {0xBEDE, _}, payload: "opus", padding: 3}} =
             Rtp.decode(packet)
  end

  test "RTP decoding refuses bad versions, truncation and bad padding" do
    assert {:error, :malformed} = Rtp.decode(<<1::2, 0::6, 102, 0::80>>)
    assert {:error, :malformed} = Rtp.decode(<<0x90, 102, 0::80>>)
    assert {:error, :malformed} = Rtp.decode(<<0xA0, 102, 0::80, "ab", 9>>)
  end

  test "RTP and RTCP are told apart on the bundled transport" do
    assert Rtp.rtcp?(<<0x80, 200, 0, 6>>)
    refute Rtp.rtcp?(<<0x80, 102, 0, 1>>)
    refute Rtp.rtp_or_rtcp?(<<0x00, 0x01, 0, 0>>)
  end

  test "a report describes the peer stream and carries the fixed CNAME" do
    stats =
      Enum.reduce([1, 2, 4, 5], Rtcp.receive_stats(2002), fn seq, stats ->
        Rtcp.record(stats, seq, seq * 2880, seq * 60)
      end)

    sender = %{ntp_ms: 1_700_000_000_000, rtp_timestamp: 5760, packets: 2, octets: 160}
    {packet, _stats} = Rtcp.report(1002, sender, stats, 1_000)

    assert {:ok,
            [
              {:sender_report, 1002, _ntp},
              {202, 1, 1002, <<1002::32, 1, 16, "CNAMECNAMECNAME!", 0, _::binary>>}
            ]} = Rtcp.parse(packet)

    # SR header (8) + sender info (20) + one report block (24).
    <<_::binary-28, 2002::32, fraction, lost::24, max_seq::32, _::binary>> = packet
    assert {lost, max_seq} == {1, 5}
    assert fraction == div(256, 5)
  end

  test "a report before any sent audio is a receiver report" do
    {packet, _} = Rtcp.report(2002, nil, Rtcp.receive_stats(1002), 0)
    assert {:ok, [{201, 0, 2002, _}, {202, 1, 2002, _}]} = Rtcp.parse(packet)
  end
end
