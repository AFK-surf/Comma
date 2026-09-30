defmodule SalixSignalProto.GroupCall.Reliable do
  @moduledoc """
  Receive side of the reliability layer on the SFU data stream (CRS-14
  section 10.6).

  `receive/2` takes one decoded SFU-to-device message and returns the
  messages to act on, in order, and the acknowledgement to send:

    * a message without a sequence number is unreliable and is delivered at
      once (a pure acknowledgement is dropped: this client sends nothing
      reliably);
    * a reliable message is held in a window of 64 and delivered in
      sequence order; every reliable message, also a duplicate, asks for an
      acknowledgement of the next expected sequence number;
    * fragments (field 12) are joined in sequence order, starting at the
      fragment whose header gives the count, and decoded as one message.

  The caller sends the acknowledgement within 200 ms.
  """

  alias SalixSignalProto.GroupCall.{Messages, Wire}

  @window 64

  defstruct next: 1, held: %{}, assembly: nil

  @type t :: %__MODULE__{}

  @doc "A new receive state; the first reliable sequence number is 1."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Handles one SFU-to-device message. Returns `{messages, ack, state}`, where
  `ack` is the next expected sequence number to acknowledge, or nil.
  """
  @spec receive(t(), struct()) :: {[struct()], pos_integer() | nil, t()}
  def receive(%__MODULE__{} = state, %Wire.SfuToDevice{reliability: header} = message) do
    case header do
      %Wire.ReliabilityHeader{seqnum: seq} when is_integer(seq) and seq > 0 ->
        reliable(state, seq, message)

      %Wire.ReliabilityHeader{ack: ack} when is_integer(ack) ->
        {[], nil, state}

      _ ->
        {[message], nil, state}
    end
  end

  defp reliable(state, seq, message) do
    cond do
      seq < state.next or seq >= state.next + @window or Map.has_key?(state.held, seq) ->
        {[], state.next, state}

      true ->
        state = %{state | held: Map.put(state.held, seq, message)}
        {delivered, state} = drain(state, [])
        {Enum.reverse(delivered), state.next, state}
    end
  end

  defp drain(%{held: held, next: next} = state, delivered) do
    case Map.pop(held, next) do
      {nil, _held} ->
        {delivered, state}

      {message, held} ->
        state = %{state | held: held, next: next + 1}
        {delivered, state} = take(state, message, delivered)
        drain(state, delivered)
    end
  end

  # When a packet has the fragment field, its other fields are ignored.
  defp take(state, %Wire.SfuToDevice{fragment: chunk, reliability: header}, delivered)
       when is_binary(chunk) do
    count = header.fragment_count

    case state.assembly do
      _ when is_integer(count) and count in 1..@window ->
        complete(%{state | assembly: {count - 1, [chunk]}}, delivered)

      {remaining, chunks} when remaining > 0 ->
        complete(%{state | assembly: {remaining - 1, [chunk | chunks]}}, delivered)

      _ ->
        {delivered, %{state | assembly: nil}}
    end
  end

  defp take(state, message, delivered),
    do: {[strip(message) | delivered], %{state | assembly: nil}}

  defp complete(%{assembly: {0, chunks}} = state, delivered) do
    state = %{state | assembly: nil}

    case chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Messages.decode_sfu() do
      {:ok, message} -> {[strip(message) | delivered], state}
      {:error, _} -> {delivered, state}
    end
  end

  defp complete(state, delivered), do: {delivered, state}

  defp strip(message), do: %{message | reliability: nil, fragment: nil}
end
