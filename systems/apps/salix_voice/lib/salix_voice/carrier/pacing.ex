defmodule SalixVoice.Carrier.Pacing do
  @moduledoc """
  Real-time pacing for a carrier socket (docs/messaging-voice.md).

  Pure state for the socket handler; the caller supplies monotonic `now_ms`.

  Inbound (`inbound/1`, `ingest/3`): caller audio may not arrive faster than
  1.25x real time over any 5 s window. Bytes are summed in 100 ms slots, so the
  state holds at most 50 slots whatever the frame size.

  Outbound (`outbound/1`, `push/2`, `take/2`, `played/3`, `slow_reader?/2`):
  agent audio is written at most `lead_ms` (500 ms) ahead of real-time
  playback, so a burst from the model waits in Salix, not in the client. After
  each written batch the socket sends `output.mark` with the name `take/2`
  returns; the client answers `output.played`. A client whose playback falls
  more than 2 s behind the schedule of written audio, or whose held audio
  exceeds `max_held_ms`, is a slow reader (close 4410). `clear/2` drops held
  audio and restarts the schedule after a barge-in.
  """

  alias SalixVoice.Carrier

  @window_ms 5_000
  @slot_ms 100
  @max_ratio 1.25
  @lead_ms 500
  @slow_reader_ms 2_000
  @max_held_ms 120_000

  # -- Inbound -----------------------------------------------------------------

  @doc "Inbound pacing state for an audio format."
  def inbound(format),
    do: %{rate: Carrier.bytes_per_second(format), slots: %{}}

  @doc """
  Account `bytes` of caller audio received at `now_ms`. Returns
  `{:error, :too_fast}` once the last 5 s carried more than 1.25x real time.
  """
  @spec ingest(map(), non_neg_integer(), integer()) :: {:ok, map()} | {:error, :too_fast}
  def ingest(state, bytes, now_ms) do
    slot = div(now_ms, @slot_ms)
    oldest = slot - div(@window_ms, @slot_ms) + 1

    slots =
      state.slots
      |> Map.update(slot, bytes, &(&1 + bytes))
      |> Map.reject(fn {key, _bytes} -> key < oldest end)

    state = %{state | slots: slots}
    total = slots |> Map.values() |> Enum.sum()

    if total > state.rate * @max_ratio * @window_ms / 1000,
      do: {:error, :too_fast},
      else: {:ok, state}
  end

  # -- Outbound ----------------------------------------------------------------

  @doc "Outbound pacing state. Options: `:lead_ms`, `:max_held_ms`."
  def outbound(format, opts \\ []) do
    %{
      format: format,
      held: :queue.new(),
      held_bytes: 0,
      deadline_ms: nil,
      marks: :queue.new(),
      mark_seq: 0,
      lead_ms: Keyword.get(opts, :lead_ms, @lead_ms),
      max_held_ms: Keyword.get(opts, :max_held_ms, @max_held_ms)
    }
  end

  @doc "Hold agent audio for paced writing."
  def push(state, audio) when is_binary(audio) and audio != "" do
    %{state | held: :queue.in(audio, state.held), held_bytes: state.held_bytes + byte_size(audio)}
  end

  def push(state, _audio), do: state

  @doc """
  Audio due for writing at `now_ms`. Returns `{chunks, mark_name | nil, state}`;
  the socket writes the chunks, then sends `output.mark` with the name when it
  is not nil.
  """
  def take(state, now_ms) do
    deadline = max(state.deadline_ms || now_ms, now_ms)
    take(state, now_ms, deadline, [])
  end

  defp take(state, now_ms, deadline, acc) do
    case :queue.out(state.held) do
      {{:value, audio}, rest} when deadline - now_ms < state.lead_ms ->
        deadline = deadline + Carrier.audio_ms(byte_size(audio), state.format)

        take(
          %{state | held: rest, held_bytes: state.held_bytes - byte_size(audio)},
          now_ms,
          deadline,
          [audio | acc]
        )

      _ when acc == [] ->
        {[], nil, state}

      _ ->
        seq = state.mark_seq + 1
        name = "pace:" <> Integer.to_string(seq)

        {Enum.reverse(acc), name,
         %{
           state
           | deadline_ms: deadline,
             mark_seq: seq,
             marks: :queue.in({name, deadline}, state.marks)
         }}
    end
  end

  @doc "Milliseconds until more audio may be written, or nil when none is held."
  def next_due_ms(state, now_ms) do
    cond do
      :queue.is_empty(state.held) -> nil
      is_nil(state.deadline_ms) -> 0
      true -> max(state.deadline_ms - state.lead_ms - now_ms, 0)
    end
  end

  @doc "True when `name` is a pacing mark (not a CallActor mark)."
  def pacing_mark?("pace:" <> _), do: true
  def pacing_mark?(_name), do: false

  @doc "Record the client's `output.played` for a pacing mark."
  def played(state, name, _now_ms) do
    marks = drop_through(state.marks, name)
    %{state | marks: marks}
  end

  defp drop_through(queue, name) do
    if Enum.any?(:queue.to_list(queue), fn {mark, _deadline} -> mark == name end) do
      {{:value, {mark, _}}, rest} = :queue.out(queue)
      if mark == name, do: rest, else: drop_through(rest, name)
    else
      queue
    end
  end

  @doc "Drop held audio and pending marks after a barge-in."
  def clear(state, _now_ms) do
    %{state | held: :queue.new(), held_bytes: 0, deadline_ms: nil, marks: :queue.new()}
  end

  @doc "Milliseconds of agent audio held in Salix."
  def held_ms(state), do: Carrier.audio_ms(state.held_bytes, state.format)

  @doc """
  True when the client stopped reading: its oldest unconfirmed mark was due
  more than 2 s ago, or held audio exceeds the memory bound.
  """
  def slow_reader?(state, now_ms) do
    overdue? =
      case :queue.peek(state.marks) do
        {:value, {_name, deadline}} -> now_ms - deadline > @slow_reader_ms
        :empty -> false
      end

    overdue? or held_ms(state) > state.max_held_ms
  end
end
