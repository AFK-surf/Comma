defmodule SalixSignal.CallMedia.JitterBufferTest do
  use ExUnit.Case, async: true

  alias SalixSignal.CallMedia.JitterBuffer

  # 60 ms packets: 2880 ticks of the 48 kHz clock.
  @ticks 2880

  defp push(jb, seq, now), do: JitterBuffer.push(jb, seq, seq * @ticks, <<seq::16>>, now)

  defp played(items), do: for({:packet, <<seq::16>>, _ts} <- items, do: seq)

  test "reordered packets play in order at their playout time" do
    jb = JitterBuffer.new(delay_ms: 60)
    jb = jb |> push(1, 0) |> push(3, 125) |> push(2, 130)

    {items, jb} = JitterBuffer.pop(jb, 59)
    assert items == []
    {items, jb} = JitterBuffer.pop(jb, 60)
    assert played(items) == [1]
    {items, _jb} = JitterBuffer.pop(jb, 180)
    assert played(items) == [2, 3]
  end

  test "a missing packet is reported as lost with the next packet for FEC" do
    jb = JitterBuffer.new(delay_ms: 60) |> push(1, 0) |> push(3, 120)
    {items, _jb} = JitterBuffer.pop(jb, 300)
    assert [{:packet, <<1::16>>, _}, {:lost, 1, <<3::16>>, gap}, {:packet, <<3::16>>, _}] = items
    assert gap == 2 * @ticks
  end

  test "a packet that arrives after its slot is dropped" do
    jb = JitterBuffer.new(delay_ms: 60) |> push(1, 0) |> push(3, 120)
    {_items, jb} = JitterBuffer.pop(jb, 300)
    jb = push(jb, 2, 310)
    assert JitterBuffer.late_count(jb) == 1
    assert {[], _} = JitterBuffer.pop(jb, 400)
  end

  test "a DTX pause is not a loss" do
    jb = JitterBuffer.new(delay_ms: 60)
    jb = JitterBuffer.push(jb, 1, 0, "a", 0)
    # Next packet in sequence, 2 s of timestamps later.
    jb = JitterBuffer.push(jb, 2, 96_000, "b", 2_000)
    {items, _} = JitterBuffer.pop(jb, 2_100)
    assert [{:packet, "a", _}, {:packet, "b", _}] = items
  end

  test "sequence numbers wrap" do
    jb = JitterBuffer.new(delay_ms: 0)
    jb = JitterBuffer.push(jb, 65_535, 0, "a", 0)
    jb = JitterBuffer.push(jb, 0, @ticks, "b", 60)
    {items, _} = JitterBuffer.pop(jb, 100)
    assert [{:packet, "a", _}, {:packet, "b", _}] = items
  end

  test "the buffer holds at most max_packets" do
    jb =
      Enum.reduce(1..20, JitterBuffer.new(delay_ms: 10_000, max_packets: 5), &push(&2, &1, 0))

    assert JitterBuffer.size(jb) == 5
  end
end
