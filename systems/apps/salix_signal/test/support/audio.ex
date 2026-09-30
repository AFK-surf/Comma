defmodule SalixSignal.Test.Audio do
  @moduledoc false
  # PCM16 mono 24 kHz helpers for call media tests.

  @rate 24_000

  def sine(freq, ms, amplitude \\ 8_000) do
    samples = div(@rate * ms, 1000)

    for n <- 0..(samples - 1), into: <<>> do
      value = round(amplitude * :math.sin(2 * :math.pi() * freq * n / @rate))
      <<value::little-signed-16>>
    end
  end

  def frames(pcm, frame_bytes), do: for(<<frame::binary-size(^frame_bytes) <- pcm>>, do: frame)

  def skip_ms(pcm, ms) do
    skip = min(div(@rate * ms, 1000) * 2, byte_size(pcm))
    binary_part(pcm, skip, byte_size(pcm) - skip)
  end

  def samples(pcm), do: for(<<s::little-signed-16 <- pcm>>, do: s)

  def rms(pcm) do
    case samples(pcm) do
      [] -> 0.0
      s -> :math.sqrt(Enum.sum(Enum.map(s, &(&1 * &1))) / length(s))
    end
  end

  # Dominant frequency estimated from zero crossings.
  def frequency(pcm) do
    s = samples(pcm)

    crossings =
      s
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> (a < 0 and b >= 0) or (a >= 0 and b < 0) end)

    crossings / 2 / (length(s) / @rate)
  end
end
