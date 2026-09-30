defmodule SalixSignalProto.CallMedia.Control do
  @moduledoc """
  The in-band control channel of a 1:1 call, "RTP data" (CRS-13 section 9).

  Control messages are RTP packets with payload type 101 and SSRC 13,
  protected with the sender's SRTP keys like media. The payload is one
  control message (section 9.2).

  Sending (section 9.7): every message a side sends on a connection carries
  all fields it set so far. Each new event (accepted, hangup, status change)
  updates those fields, increments the sequence number (first value 1) and is
  sent at once. The accumulated message is re-sent unchanged once per second.
  The RTP sequence number and timestamp both come from one per-connection
  counter that starts at 1 and counts every RTP data packet sent.

  Receiving: a side accepts RTP data only with payload type 101 and SSRC 13
  and a payload of 1 to `max_payload_bytes/0` bytes. Accepted and hangup are
  processed whatever the sequence number and reported every time a message
  carries them; the sender repeats them once per second, so the owner of the
  connection decides when one takes effect (an accept that arrives before
  ICE connects is ignored there and taken from a later repeat). Sender and
  receiver status are processed only when the sequence number is present and
  greater than the last one processed.
  """

  import Bitwise

  alias SalixSignalProto.CallMedia
  alias SalixSignalProto.CallMedia.Rtp

  # Our receive limit for a control payload. CRS-13 open question 5: the
  # limit is implementation-defined and small; control messages are well
  # under 100 bytes.
  @max_payload_bytes 1_024

  defmodule Accepted do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
  end

  defmodule Hangup do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:type, 2, optional: true, type: :int32)
    field(:device_id, 3, optional: true, type: :uint32)
  end

  defmodule SenderStatus do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:video_enabled, 2, optional: true, type: :bool)
    field(:sharing_screen, 3, optional: true, type: :bool)
    field(:audio_enabled, 4, optional: true, type: :bool)
  end

  defmodule ReceiverStatus do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:max_bitrate_bps, 2, optional: true, type: :uint64)
  end

  defmodule Message do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:accepted, 1, optional: true, type: SalixSignalProto.CallMedia.Control.Accepted)
    field(:hangup, 2, optional: true, type: SalixSignalProto.CallMedia.Control.Hangup)

    field(:sender_status, 3,
      optional: true,
      type: SalixSignalProto.CallMedia.Control.SenderStatus
    )

    field(:sequence_number, 4, optional: true, type: :uint64)

    field(:receiver_status, 5,
      optional: true,
      type: SalixSignalProto.CallMedia.Control.ReceiverStatus
    )
  end

  @type event ::
          {:accepted, call_id :: non_neg_integer()}
          | {:hangup, call_id :: non_neg_integer(), type :: integer(),
             device_id :: non_neg_integer() | nil}
          | {:sender_status, map()}
          | {:receiver_status, map()}

  @doc "Our receive limit for a control payload, in bytes."
  def max_payload_bytes, do: @max_payload_bytes

  # -- Codec -------------------------------------------------------------------

  @doc "Encodes a control message struct."
  @spec encode(Message.t()) :: binary()
  def encode(%Message{} = message), do: Message.encode(message)

  @doc "Decodes a control message payload."
  @spec decode(binary()) :: {:ok, Message.t()} | {:error, :malformed}
  def decode(payload) when is_binary(payload) do
    {:ok, Message.decode(payload)}
  rescue
    _ -> {:error, :malformed}
  end

  # -- Sending -----------------------------------------------------------------

  @doc "Sending state for one connection."
  def sender, do: %{message: %Message{}, sequence_number: 0, counter: 0}

  @doc """
  Applies a local event to the accumulated message and returns the RTP packet
  to send now. Events: `{:accepted, call_id}`,
  `{:hangup, call_id, type, device_id | nil}`,
  `{:sender_status, %{call_id, video_enabled, sharing_screen, audio_enabled}}`,
  `{:receiver_status, %{call_id, max_bitrate_bps}}`.
  """
  @spec send_event(map(), event()) :: {binary(), map()}
  def send_event(sender, event) do
    sequence_number = sender.sequence_number + 1

    message =
      sender.message
      |> apply_event(event)
      |> Map.put(:sequence_number, sequence_number)

    packet(%{sender | message: message, sequence_number: sequence_number})
  end

  @doc """
  The RTP packet that repeats the accumulated message, or nil when no event
  was sent yet. Call it once per second while the connection exists.
  """
  @spec repeat(map()) :: {binary() | nil, map()}
  def repeat(%{sequence_number: 0} = sender), do: {nil, sender}
  def repeat(sender), do: packet(sender)

  defp apply_event(message, {:accepted, call_id}),
    do: %{message | accepted: %Accepted{call_id: call_id}}

  defp apply_event(message, {:hangup, call_id, type, device_id}),
    do: %{message | hangup: %Hangup{call_id: call_id, type: type, device_id: device_id}}

  defp apply_event(message, {:sender_status, status}),
    do: %{message | sender_status: struct(SenderStatus, status)}

  defp apply_event(message, {:receiver_status, status}),
    do: %{message | receiver_status: struct(ReceiverStatus, status)}

  defp packet(sender) do
    counter = sender.counter + 1

    rtp =
      Rtp.encode(%Rtp{
        payload_type: CallMedia.rtp_data_payload_type(),
        sequence_number: band(counter, 0xFFFF),
        timestamp: band(counter, 0xFFFFFFFF),
        ssrc: CallMedia.rtp_data_ssrc(),
        payload: encode(sender.message)
      })

    {rtp, %{sender | counter: counter}}
  end

  # -- Receiving ---------------------------------------------------------------

  @doc "Receiving state for one connection."
  def receiver, do: %{last_sequence_number: nil}

  @doc """
  True when a decoded RTP packet belongs to the control channel.
  """
  @spec control_packet?(Rtp.t()) :: boolean()
  def control_packet?(%Rtp{payload_type: pt, ssrc: ssrc}),
    do: pt == CallMedia.rtp_data_payload_type() and ssrc == CallMedia.rtp_data_ssrc()

  @doc """
  Processes one received control payload. Returns the new events in the
  order accepted, hangup, sender status, receiver status.
  """
  @spec receive_payload(map(), binary()) :: {:ok, [event()], map()} | {:error, :malformed}
  def receive_payload(_receiver, payload)
      when payload == <<>> or byte_size(payload) > @max_payload_bytes,
      do: {:error, :malformed}

  def receive_payload(receiver, payload) do
    with {:ok, message} <- decode(payload) do
      {accepted, receiver} = receive_accepted(receiver, message.accepted)
      {hangup, receiver} = receive_hangup(receiver, message.hangup)
      {statuses, receiver} = receive_statuses(receiver, message)
      {:ok, accepted ++ hangup ++ statuses, receiver}
    end
  end

  defp receive_accepted(receiver, %Accepted{call_id: id}) when is_integer(id),
    do: {[{:accepted, id}], receiver}

  defp receive_accepted(receiver, _accepted), do: {[], receiver}

  defp receive_hangup(receiver, %Hangup{call_id: id} = hangup) when is_integer(id) do
    device_id = if hangup.device_id in [nil, 0], do: nil, else: hangup.device_id
    {[{:hangup, id, hangup.type || 0, device_id}], receiver}
  end

  defp receive_hangup(receiver, _hangup), do: {[], receiver}

  defp receive_statuses(receiver, %Message{sequence_number: seq} = message)
       when is_integer(seq) do
    if is_nil(receiver.last_sequence_number) or seq > receiver.last_sequence_number do
      events =
        [
          status_event(:sender_status, message.sender_status),
          status_event(:receiver_status, message.receiver_status)
        ]
        |> Enum.reject(&is_nil/1)

      {events, %{receiver | last_sequence_number: seq}}
    else
      {[], receiver}
    end
  end

  defp receive_statuses(receiver, _message), do: {[], receiver}

  defp status_event(_kind, nil), do: nil

  defp status_event(kind, status),
    do: {kind, status |> Map.from_struct() |> Map.drop([:__unknown_fields__])}
end
