defmodule SalixSignal.GroupCall.MixerTest do
  use ExUnit.Case, async: true

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

  test "a speaker with less than a tick is padded with silence; no audio is nil" do
    mixer = Mixer.new(rate: 400, tick_ms: 10) |> Mixer.push(:a, pcm([5, 6]))
    assert {mixed, mixer} = Mixer.pop(mixer)
    assert samples(mixed) == [5, 6, 0, 0]
    assert {nil, _} = Mixer.pop(mixer)
  end

  test "a queue keeps only the newest max_queue_ms; a speaker that left is dropped" do
    mixer =
      Mixer.new(rate: 400, tick_ms: 10, max_queue_ms: 10)
      |> Mixer.push(:a, pcm([1, 2, 3, 4, 5, 6]))

    assert {mixed, mixer} = Mixer.pop(mixer)
    assert samples(mixed) == [3, 4, 5, 6]

    mixer = mixer |> Mixer.push(:b, pcm([7, 7, 7, 7])) |> Mixer.drop(:b)
    assert {nil, _} = Mixer.pop(mixer)
  end
end
