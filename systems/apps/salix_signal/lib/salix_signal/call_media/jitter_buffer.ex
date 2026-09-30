defmodule SalixSignal.CallMedia.JitterBuffer do
  @moduledoc """
  Receive-side reordering and playout timing for one audio stream.

  Pure state; the caller supplies a monotonic `now_ms`. Packets are held by
  extended sequence number and released in order at their playout time:
  the arrival time of the anchor packet plus the RTP timestamp distance
  (48 kHz clock) plus a fixed `delay_ms`. A late packet whose predecessors
  were already released is dropped. When the next packet in sequence is
  missing and a later packet is due, `pop/2` reports the loss so the decoder
  can use the later packet's FEC data or conceal it.

  With DTX the sender stops sending during silence: the sequence stays
  contiguous and only the timestamps jump, so this is not a loss.

  The anchor moves to a packet that arrives more than `delay_ms` after its
  playout time, so network delay growth and clock drift do not accumulate.
  At most `max_packets` are held; beyond that the oldest are released.
  """

  import Bitwise

  @clock_per_ms 48

  defstruct delay_ms: 60,
            max_packets: 50,
            packets: %{},
            next_seq: nil,
            highest: nil,
            anchor: nil,
            last_ts: nil,
            late: 0

  @type item ::
          {:packet, payload :: binary(), timestamp :: non_neg_integer()}
          | {:lost, missing :: pos_integer(), next :: binary(), gap_ticks :: non_neg_integer()}

  @doc "A new buffer. Options: `:delay_ms` (60), `:max_packets` (50)."
  def new(opts \\ []), do: struct(__MODULE__, opts)

  @doc "Holds one packet with 16-bit `seq` and 32-bit RTP `timestamp`."
  def push(%__MODULE__{} = jb, seq, timestamp, payload, now_ms) do
    ext = extend(jb.highest, seq)

    cond do
      jb.next_seq != nil and ext < jb.next_seq ->
        %{jb | late: jb.late + 1}

      Map.has_key?(jb.packets, ext) ->
        jb

      true ->
        jb = %{jb | highest: max(jb.highest || ext, ext), next_seq: jb.next_seq || ext}
        jb = reanchor(jb, timestamp, now_ms)
        jb = %{jb | packets: Map.put(jb.packets, ext, {timestamp, payload})}
        trim(jb)
    end
  end

  @doc """
  Releases what is due at `now_ms`, in order. Items are
  `{:packet, payload, timestamp}` and, before a packet that follows a loss,
  `{:lost, missing_count, that_packet_payload, gap_ticks}` where `gap_ticks`
  is the timestamp distance from the last released packet (nil before any).
  """
  @spec pop(%__MODULE__{}, integer()) :: {[item()], %__MODULE__{}}
  def pop(%__MODULE__{} = jb, now_ms), do: pop(jb, now_ms, [])

  defp pop(%{next_seq: nil} = jb, _now_ms, acc), do: {Enum.reverse(acc), jb}

  defp pop(jb, now_ms, acc) do
    case Map.fetch(jb.packets, jb.next_seq) do
      {:ok, {ts, payload}} ->
        if due?(jb, ts, now_ms),
          do: pop(release(jb, jb.next_seq, ts), now_ms, [{:packet, payload, ts} | acc]),
          else: {Enum.reverse(acc), jb}

      :error ->
        case earliest(jb) do
          {seq, {ts, payload}} ->
            if due?(jb, ts, now_ms) do
              gap = if jb.last_ts, do: band(ts - jb.last_ts, 0xFFFFFFFF), else: nil
              lost = {:lost, seq - jb.next_seq, payload, gap}
              pop(release(jb, seq, ts), now_ms, [{:packet, payload, ts}, lost | acc])
            else
              {Enum.reverse(acc), jb}
            end

          nil ->
            {Enum.reverse(acc), jb}
        end
    end
  end

  @doc "Packets dropped because they arrived after their slot was released."
  def late_count(%__MODULE__{late: late}), do: late

  @doc "Number of held packets."
  def size(%__MODULE__{packets: packets}), do: map_size(packets)

  defp release(jb, seq, ts),
    do: %{jb | packets: Map.delete(jb.packets, seq), next_seq: seq + 1, last_ts: ts}

  defp earliest(%{packets: packets}) when map_size(packets) == 0, do: nil
  defp earliest(%{packets: packets}), do: Enum.min_by(packets, fn {seq, _} -> seq end)

  defp due?(jb, ts, now_ms), do: playout_ms(jb, ts) <= now_ms

  defp playout_ms(%{anchor: {anchor_ts, anchor_ms}} = jb, ts),
    do: anchor_ms + div(signed32(ts - anchor_ts), @clock_per_ms) + jb.delay_ms

  defp reanchor(%{anchor: nil} = jb, ts, now_ms), do: %{jb | anchor: {ts, now_ms}}

  defp reanchor(jb, ts, now_ms) do
    if now_ms - playout_ms(jb, ts) > jb.delay_ms,
      do: %{jb | anchor: {ts, now_ms}},
      else: jb
  end

  defp trim(jb) do
    if map_size(jb.packets) > jb.max_packets do
      {seq, _} = earliest(jb)
      trim(%{jb | packets: Map.delete(jb.packets, seq), next_seq: max(jb.next_seq, seq + 1)})
    else
      jb
    end
  end

  # Extends a 16-bit sequence number to the value closest to the highest seen.
  defp extend(nil, seq), do: seq + 0x10000

  defp extend(highest, seq) do
    base = highest - band(highest, 0xFFFF)
    candidates = [base - 0x10000 + seq, base + seq, base + 0x10000 + seq]
    Enum.min_by(candidates, &abs(&1 - highest))
  end

  defp signed32(value) do
    value = band(value, 0xFFFFFFFF)
    if value >= 0x80000000, do: value - 0x100000000, else: value
  end
end
