defmodule SalixVoice.Carrier.Pacing do
  @moduledoc """
  Real-time pacing for a carrier socket (docs/messaging-voice.md).

  Pure state for the socket handler; the caller supplies monotonic `now_ms`.

  Inbound (`inbound/1`, `ingest/3`): a token bucket of caller audio time.
  Credit accrues at 1.25x real time up to 5 s of audio, and each received
  frame spends its length. After a network stall the client may deliver up to
  5 s of buffered audio at once; a client that streams faster than 1.25x real
  time for long enough to spend the credit is too fast (close 4400).

  Outbound (`outbound/1`, `push/2`, `take/2`, `played/3`, `slow_reader?/2`):
  agent audio is written at most `lead_ms` (500 ms) ahead of real-time
  playback, so a burst from the model waits in Salix, not in the client. After
  each written batch the socket sends `output.mark` with the name `take/2`
  returns; the client answers `output.played`. A client whose playback falls
  more than `slow_reader_ms` (8 s) behind the schedule of written audio, or
  whose held audio exceeds `max_held_ms`, is a slow reader (close 4410). The
  threshold tolerates downlink stalls of several seconds, after which the
  client plays the delayed audio and confirms its marks. `clear/2` drops held
  audio and restarts the schedule after a barge-in.

  For diagnosis, the outbound state keeps the last confirmed mark and a
  bounded trail of the last 80 mark, played and clear events (timing and
  counts only); `diagnostics/2` reports them with the slow-reader cause.
  """

  alias SalixVoice.Carrier

  @burst_ms 5_000
  @max_ratio 1.25
  @lead_ms 500
  @slow_reader_ms 8_000
  @max_held_ms 120_000
  @trail_max 80

  # -- Inbound -----------------------------------------------------------------

  @doc "Inbound pacing state for an audio format. The bucket starts full."
  def inbound(format) do
    rate = Carrier.bytes_per_second(format)
    %{rate: rate, credit: rate * @burst_ms / 1000, at_ms: nil}
  end

  @doc """
  Account `bytes` of caller audio received at `now_ms`. Returns
  `{:error, :too_fast}` when the frame is longer than the remaining credit.
  """
  @spec ingest(map(), non_neg_integer(), integer()) :: {:ok, map()} | {:error, :too_fast}
  def ingest(state, bytes, now_ms) do
    accrued =
      if state.at_ms, do: (now_ms - state.at_ms) * state.rate * @max_ratio / 1000, else: 0

    credit = min(state.credit + accrued, state.rate * @burst_ms / 1000) - bytes
    state = %{state | credit: credit, at_ms: now_ms}

    if credit < 0,
      do: {:error, :too_fast},
      else: {:ok, state}
  end

  # -- Outbound ----------------------------------------------------------------

  @doc "Outbound pacing state. Options: `:lead_ms`, `:slow_reader_ms`, `:max_held_ms`."
  def outbound(format, opts \\ []) do
    %{
      format: format,
      held: :queue.new(),
      held_bytes: 0,
      deadline_ms: nil,
      marks: :queue.new(),
      mark_seq: 0,
      lead_ms: Keyword.get(opts, :lead_ms, @lead_ms),
      slow_reader_ms: Keyword.get(opts, :slow_reader_ms, @slow_reader_ms),
      max_held_ms: Keyword.get(opts, :max_held_ms, @max_held_ms),
      last_played: nil,
      trail: :queue.new(),
      trail_len: 0
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

        written_ms = acc |> Enum.map(&byte_size/1) |> Enum.sum() |> Carrier.audio_ms(state.format)

        state =
          %{
            state
            | deadline_ms: deadline,
              mark_seq: seq,
              marks: :queue.in({name, deadline}, state.marks)
          }
          |> record({:mark, seq, now_ms, deadline, written_ms})

        {Enum.reverse(acc), name, state}
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
  def played(state, name, now_ms) do
    marks = drop_through(state.marks, name)
    matched? = :queue.len(marks) != :queue.len(state.marks)
    state = record(%{state | marks: marks}, {:played, mark_seq(name), now_ms, matched?})
    if matched?, do: %{state | last_played: {mark_seq(name), now_ms}}, else: state
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
  def clear(state, now_ms) do
    %{state | held: :queue.new(), held_bytes: 0, deadline_ms: nil, marks: :queue.new()}
    |> record({:clear, :queue.len(state.marks), now_ms})
  end

  @doc "Milliseconds of agent audio held in Salix."
  def held_ms(state), do: Carrier.audio_ms(state.held_bytes, state.format)

  @doc """
  True when the client stopped reading: its oldest unconfirmed mark was due
  more than `slow_reader_ms` ago, or held audio exceeds the memory bound.
  """
  def slow_reader?(state, now_ms), do: slow_reader(state, now_ms) != nil

  @doc """
  The slow-reader cause at `now_ms`: `:mark_overdue` (the oldest unconfirmed
  mark is more than `slow_reader_ms` past its deadline), `:held_limit` (held audio exceeds
  `max_held_ms`), or nil.
  """
  def slow_reader(state, now_ms) do
    cond do
      overdue?(state, now_ms) -> :mark_overdue
      held_ms(state) > state.max_held_ms -> :held_limit
      true -> nil
    end
  end

  defp overdue?(state, now_ms) do
    case :queue.peek(state.marks) do
      {:value, {_name, deadline}} -> now_ms - deadline > state.slow_reader_ms
      :empty -> false
    end
  end

  @doc """
  Timing and counts for a slow-reader report at `now_ms`. Holds no audio.
  `trail` lists the last events, oldest first: `{:mark, seq, sent_ms,
  deadline_ms, written_ms}`, `{:played, seq, at_ms, matched?}` and
  `{:clear, dropped_marks, at_ms}`.
  """
  def diagnostics(state, now_ms) do
    oldest =
      case :queue.peek(state.marks) do
        {:value, {name, deadline}} -> {mark_seq(name), deadline}
        :empty -> nil
      end

    %{
      cause: slow_reader(state, now_ms),
      slow_reader_ms: state.slow_reader_ms,
      held_ms: held_ms(state),
      oldest_mark: oldest,
      pending_marks: :queue.len(state.marks),
      last_sent_seq: state.mark_seq,
      last_played: state.last_played,
      trail: :queue.to_list(state.trail)
    }
  end

  defp record(state, event) do
    trail = :queue.in(event, state.trail)

    if state.trail_len < @trail_max,
      do: %{state | trail: trail, trail_len: state.trail_len + 1},
      else: %{state | trail: :queue.drop(trail)}
  end

  defp mark_seq("pace:" <> seq) do
    case Integer.parse(seq) do
      {seq, ""} -> seq
      _ -> nil
    end
  end

  defp mark_seq(_name), do: nil
end
