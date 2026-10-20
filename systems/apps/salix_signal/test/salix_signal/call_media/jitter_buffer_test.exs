defmodule SalixSignal.CallMedia.JitterBufferTest do
  use SystemsClock.Case, async: true

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
end
