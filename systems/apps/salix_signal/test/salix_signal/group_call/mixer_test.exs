defmodule SalixSignal.GroupCall.MixerTest do
  use SystemsClock.Case, async: true

  alias SalixSignal.GroupCall.Mixer

  defp pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)
  defp samples(pcm), do: for(<<s::little-signed-16 <- pcm>>, do: s)

  test "speakers are added sample by sample with saturation" do
    mixer =
      Mixer.new(rate: 400, tick_ms: 10)
      |> Mixer.push(:a, pcm([100, -200, 30_000, -30_000]))
      |> Mixer.push(:b, pcm([1, 2, 10_000, -10_000]))

    assert {mixed, _} = Mixer.pop(mixer)
    assert samples(mixed) == [101, -198, 32_767, -32_768]
  end
end
