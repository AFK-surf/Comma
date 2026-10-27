defmodule SalixMeetNative.ASR.Segmenter do
  @moduledoc false

  @sample_rate 16_000
  @frame_samples div(@sample_rate * 40, 1_000)
  @frame_bytes @frame_samples * 2
  @preroll_frames 8
  @trailing_silence 20
  @max_frames 750
  @voice_mean_amplitude 180
  @max_gap div(@sample_rate * 800, 1_000)

  defstruct cursor: nil, pending: <<>>, open?: false, frames: 0, silence: 0, preroll: []

  @type action :: {:open, non_neg_integer()} | {:audio, binary()} | :seal

  def sample_rate, do: @sample_rate

  @doc "How long speech sounds in `pcm` (16 kHz s16le): its voiced 40 ms frames, in seconds."
  @spec voiced_seconds(binary()) :: float()
  def voiced_seconds(pcm) do
    voiced =
      for <<frame::binary-size(@frame_bytes) <- pcm>>, voiced?(frame), reduce: 0, do: (n -> n + 1)

    voiced * @frame_samples / @sample_rate
  end

  @spec push(%__MODULE__{}, non_neg_integer(), binary()) :: {%__MODULE__{}, [action()]}
  def push(%__MODULE__{cursor: nil} = s, start, pcm), do: push(%{s | cursor: start}, start, pcm)

  def push(s, start, pcm) do
    expected = s.cursor + div(byte_size(s.pending), 2)
    skip = min(byte_size(pcm), max(expected - start, 0) * 2)
    pcm = binary_part(pcm, skip, byte_size(pcm) - skip)
    start = start + div(skip, 2)
    gap = start - expected

    cond do
      pcm == "" ->
        {s, []}

      gap > @max_gap ->
        {s, flushed} = flush(s)
        {s, actions} = push(%{s | cursor: start}, start, pcm)
        {s, flushed ++ actions}

      true ->
        frames(%{s | pending: s.pending <> :binary.copy(<<0, 0>>, gap) <> pcm}, [])
    end
  end

  @spec flush(%__MODULE__{}) :: {%__MODULE__{}, [action()]}
  def flush(%__MODULE__{pending: ""} = s), do: close(s, [])

  def flush(s) do
    padded = s.pending <> :binary.copy(<<0>>, @frame_bytes - byte_size(s.pending))
    {s, actions} = frames(%{s | pending: padded}, [])
    close(s, actions)
  end

  defp close(s, actions) do
    seal = if s.open?, do: [:seal], else: []
    {%__MODULE__{}, actions ++ seal}
  end

  defp frames(%{pending: <<frame::binary-size(@frame_bytes), rest::binary>>} = s, acc) do
    {s, actions} = frame(%{s | pending: rest}, frame)
    frames(s, [actions | acc])
  end

  defp frames(s, acc), do: {s, acc |> Enum.reverse() |> List.flatten()}

  defp frame(s, pcm) do
    at = s.cursor
    s = %{s | cursor: at + @frame_samples}

    cond do
      s.open? ->
        silence = if voiced?(pcm), do: 0, else: s.silence + 1
        s = %{s | frames: s.frames + 1, silence: silence}

        if s.frames >= @max_frames or silence >= @trailing_silence,
          do: {%{s | open?: false, frames: 0, silence: 0}, [{:audio, pcm}, :seal]},
          else: {s, [{:audio, pcm}]}

      voiced?(pcm) ->
        preroll = Enum.reverse(s.preroll)
        start = if preroll == [], do: at, else: elem(hd(preroll), 0)
        audio = Enum.map(preroll, &{:audio, elem(&1, 1)}) ++ [{:audio, pcm}]

        {%{s | open?: true, frames: length(audio), silence: 0, preroll: []},
         [{:open, start} | audio]}

      true ->
        {%{s | preroll: Enum.take([{at, pcm} | s.preroll], @preroll_frames)}, []}
    end
  end

  defp voiced?(pcm) do
    sum = for <<sample::signed-little-16 <- pcm>>, reduce: 0, do: (acc -> acc + abs(sample))
    div(sum, @frame_samples) >= @voice_mean_amplitude
  end
end
