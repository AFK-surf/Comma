defmodule SalixSignalProto.CallMedia.Rtcp do
  @moduledoc """
  RTCP reports for an audio-only peer (CRS-13 section 10; RFC 3550 section 6).

  Comma sends one compound packet per report interval: a sender report (SR)
  when it sent audio since the previous report, else a receiver report (RR),
  followed by an SDES chunk with the fixed CNAME. The report block describes
  the peer's audio stream.

  `ReceiveStats` state tracks what a report block needs (RFC 3550 appendix
  A.3 and A.8). `parse/1` reads the packet types of a compound packet and the
  NTP time of a peer's sender report; Comma ignores all video feedback.
  """

  import Bitwise

  alias SalixSignalProto.CallMedia

  @sr 200
  @rr 201
  @sdes 202

  @doc """
  New receive statistics for one remote SSRC. `clock_rate` is the RTP clock
  rate of the stream.
  """
  def receive_stats(ssrc, clock_rate \\ CallMedia.opus_clock_rate()) do
    %{
      ssrc: ssrc,
      clock_rate: clock_rate,
      base_seq: nil,
      max_seq: 0,
      cycles: 0,
      received: 0,
      expected_prior: 0,
      received_prior: 0,
      transit: nil,
      jitter: 0,
      last_sr: 0,
      last_sr_at_ms: nil
    }
  end

  @doc """
  Records one received RTP packet with sequence number `seq` and RTP
  `timestamp` that arrived at `arrival_ms` (a monotonic clock).
  """
  def record(stats, seq, timestamp, arrival_ms) do
    stats =
      case stats.base_seq do
        nil ->
          %{stats | base_seq: seq, max_seq: seq, received: 1}

        _ ->
          delta = band(seq - stats.max_seq, 0xFFFF)

          cond do
            delta > 0 and delta < 0x8000 ->
              cycles = if seq < stats.max_seq, do: stats.cycles + 0x10000, else: stats.cycles
              %{stats | max_seq: seq, cycles: cycles, received: stats.received + 1}

            true ->
              %{stats | received: stats.received + 1}
          end
      end

    arrival = div(arrival_ms * stats.clock_rate, 1000)
    transit = arrival - timestamp

    case stats.transit do
      nil ->
        %{stats | transit: transit}

      previous ->
        d = abs(transit - previous)
        %{stats | transit: transit, jitter: stats.jitter + div(d * 16 - stats.jitter, 16)}
    end
  end

  @doc "Records the NTP time of a sender report from the peer."
  def record_sender_report(stats, ntp_middle32, arrival_ms),
    do: %{stats | last_sr: ntp_middle32, last_sr_at_ms: arrival_ms}

  @doc """
  Builds a compound report. `sender` is nil for a receiver report, or
  `%{ssrc, ntp_ms, rtp_timestamp, packets, octets}` for a sender report.
  `stats` is the receive statistics of the peer's audio, or nil before any
  audio arrived. `cname` is the SDES CNAME: the fixed 1:1 value by default;
  group calls use the decimal demux ID (CRS-14 section 7.1). Returns
  `{packet, stats}`.
  """
  def report(own_ssrc, sender, stats, now_ms, cname \\ CallMedia.cname()) do
    {blocks, count, stats} =
      case stats do
        %{base_seq: nil} -> {<<>>, 0, stats}
        %{} -> report_block(stats, now_ms)
        nil -> {<<>>, 0, stats}
      end

    first =
      case sender do
        nil ->
          packet(@rr, count, <<own_ssrc::32, blocks::binary>>)

        %{} ->
          {ntp_sec, ntp_frac} = ntp(sender.ntp_ms)

          packet(
            @sr,
            count,
            <<own_ssrc::32, ntp_sec::32, ntp_frac::32, band(sender.rtp_timestamp, 0xFFFFFFFF)::32,
              band(sender.packets, 0xFFFFFFFF)::32, band(sender.octets, 0xFFFFFFFF)::32,
              blocks::binary>>
          )
      end

    {first <> sdes(own_ssrc, cname), stats}
  end

  defp report_block(stats, now_ms) do
    extended_max = stats.cycles + stats.max_seq
    expected = extended_max - stats.base_seq + 1
    lost = max(expected - stats.received, 0)
    expected_interval = expected - stats.expected_prior
    received_interval = stats.received - stats.received_prior
    lost_interval = expected_interval - received_interval

    fraction =
      if expected_interval == 0 or lost_interval <= 0,
        do: 0,
        else: div(lost_interval <<< 8, expected_interval)

    dlsr =
      case stats.last_sr_at_ms do
        nil -> 0
        at -> div((now_ms - at) * 65_536, 1000)
      end

    block =
      <<stats.ssrc::32, min(fraction, 255)::8, min(lost, 0x7FFFFF)::24,
        band(extended_max, 0xFFFFFFFF)::32, stats.jitter >>> 4::32, stats.last_sr::32,
        band(dlsr, 0xFFFFFFFF)::32>>

    {block, 1, %{stats | expected_prior: expected, received_prior: stats.received}}
  end

  defp sdes(ssrc, cname) do
    item = <<1, byte_size(cname), cname::binary>>
    # The item list ends with a null octet, then pads to a 32-bit boundary.
    chunk = <<ssrc::32, item::binary, 0>>
    chunk = chunk <> <<0::size(rem(4 - rem(byte_size(chunk), 4), 4) * 8)>>
    packet(@sdes, 1, chunk)
  end

  defp packet(type, count, body) do
    length_words = div(byte_size(body) + 4, 4) - 1
    <<2::2, 0::1, count::5, type::8, length_words::16, body::binary>>
  end

  defp ntp(ms) do
    unix_to_ntp = 2_208_988_800
    sec = div(ms, 1000) + unix_to_ntp
    frac = div(rem(ms, 1000) <<< 32, 1000)
    {band(sec, 0xFFFFFFFF), frac}
  end

  @doc """
  Splits a compound packet. Returns a list of `{type, count, ssrc, body}`,
  where `ssrc` is the first 32-bit word after the header. For a sender report
  the entry is `{:sender_report, ssrc, ntp_middle32}`.
  """
  @spec parse(binary()) :: {:ok, list()} | {:error, :malformed}
  def parse(packet), do: parse(packet, [])

  defp parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse(<<2::2, _p::1, count::5, type::8, words::16, rest::binary>>, acc)
       when byte_size(rest) >= words * 4 do
    body_len = words * 4
    <<body::binary-size(^body_len), rest::binary>> = rest

    entry =
      case {type, body} do
        {@sr, <<ssrc::32, _ntp_hi::16, middle::32, _::bitstring>>} ->
          {:sender_report, ssrc, middle}

        {type, <<ssrc::32, _::binary>>} ->
          {type, count, ssrc, body}

        {type, _} ->
          {type, count, nil, body}
      end

    parse(rest, [entry | acc])
  end

  defp parse(_packet, _acc), do: {:error, :malformed}
end
