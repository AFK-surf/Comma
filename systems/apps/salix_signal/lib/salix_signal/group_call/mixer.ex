defmodule SalixSignal.GroupCall.Mixer do
  @moduledoc """
  Mixes the decoded audio of every speaker in a group call into the one
  PCM stream that the voice call hears (PLAN C11: multi-party mixing to one
  GPT-Live stream).

  Pure state. Each speaker (by demux ID) has a queue of PCM16 mono
  little-endian samples. `pop/1` takes one tick of audio from every queue
  that holds any, pads a short queue with silence, and adds the samples with
  saturation. It returns nil when no speaker had audio, so silence is not
  sent to the model. A queue holds at most `max_queue_ms`; older audio is
  dropped, so a speaker whose packets bunch up cannot delay the mix.
  """

  defstruct tick_samples: 480, max_queue_bytes: 11_520, queues: %{}

  @type t :: %__MODULE__{}

  @doc """
  A new mixer. Options: `rate` (24_000), `tick_ms` (20), `max_queue_ms`
  (240).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    rate = Keyword.get(opts, :rate, 24_000)
    tick_samples = div(rate * Keyword.get(opts, :tick_ms, 20), 1000)
    max_queue_bytes = div(rate * Keyword.get(opts, :max_queue_ms, 240), 1000) * 2
    %__MODULE__{tick_samples: tick_samples, max_queue_bytes: max_queue_bytes}
  end

  @doc "Appends decoded PCM of `speaker`."
  @spec push(t(), term(), binary()) :: t()
  def push(%__MODULE__{} = mixer, speaker, pcm) when is_binary(pcm) do
    queue = Map.get(mixer.queues, speaker, <<>>) <> pcm
    excess = byte_size(queue) - mixer.max_queue_bytes

    # Both sizes are even (whole samples), so the cut keeps sample alignment.
    queue = if excess > 0, do: binary_part(queue, excess, byte_size(queue) - excess), else: queue

    %{mixer | queues: Map.put(mixer.queues, speaker, queue)}
  end

  @doc "Forgets a speaker that left the call."
  @spec drop(t(), term()) :: t()
  def drop(%__MODULE__{} = mixer, speaker),
    do: %{mixer | queues: Map.delete(mixer.queues, speaker)}

  @doc "One tick of mixed audio, or nil when no speaker had audio."
  @spec pop(t()) :: {binary() | nil, t()}
  def pop(%__MODULE__{} = mixer) do
    bytes = mixer.tick_samples * 2

    {chunks, queues} =
      Enum.reduce(mixer.queues, {[], %{}}, fn
        {speaker, <<>>}, {chunks, queues} ->
          {chunks, Map.put(queues, speaker, <<>>)}

        {speaker, queue}, {chunks, queues} ->
          take = min(bytes, byte_size(queue))
          <<chunk::binary-size(^take), rest::binary>> = queue
          chunk = chunk <> <<0::size((bytes - take) * 8)>>
          {[chunk | chunks], Map.put(queues, speaker, rest)}
      end)

    {mix(chunks), %{mixer | queues: queues}}
  end

  defp mix([]), do: nil
  defp mix([single]), do: single

  defp mix([first | rest]) do
    Enum.reduce(rest, first, fn chunk, acc ->
      for {<<a::little-signed-16>>, <<b::little-signed-16>>} <- zip_samples(acc, chunk),
          into: <<>>,
          do: <<clamp(a + b)::little-signed-16>>
    end)
  end

  defp zip_samples(a, b),
    do: Enum.zip(for(<<s::binary-2 <- a>>, do: s), for(<<s::binary-2 <- b>>, do: s))

  defp clamp(sample) when sample > 32_767, do: 32_767
  defp clamp(sample) when sample < -32_768, do: -32_768
  defp clamp(sample), do: sample
end
