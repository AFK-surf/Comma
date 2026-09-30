defmodule SalixSignalProto.CallMedia.ControlTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.CallMedia.{Control, Rtp}

  @call_id 0x0123456789ABCDEF

  # CRS-13 sections 9.1, 9.2 and 9.7.
  test "the callee's accepted message has the CRS-13 wire layout" do
    {packet, _sender} = Control.send_event(Control.sender(), {:accepted, @call_id})
    {:ok, rtp} = Rtp.decode(packet)

    assert %Rtp{payload_type: 101, ssrc: 13, sequence_number: 1, timestamp: 1, marker: false} =
             rtp

    # Field 1 (accepted) holding field 1 = call ID, then field 4 = 1.
    assert rtp.payload == Base.decode16!("0A0A08EF9BAFCDF8ACD191012001")
  end

  test "each event accumulates fields and advances the sequence number; repeats do not" do
    sender = Control.sender()
    assert {nil, ^sender} = Control.repeat(sender)

    {_p1, sender} = Control.send_event(sender, {:accepted, @call_id})
    {repeat, sender} = Control.repeat(sender)
    {p3, sender} = Control.send_event(sender, {:hangup, @call_id, 0, nil})

    {:ok, r2} = Rtp.decode(repeat)
    {:ok, r3} = Rtp.decode(p3)
    assert {r2.sequence_number, r3.sequence_number} == {2, 3}

    {:ok, m2} = Control.decode(r2.payload)
    {:ok, m3} = Control.decode(r3.payload)
    assert m2.sequence_number == 1 and m2.accepted.call_id == @call_id and m2.hangup == nil
    assert m3.sequence_number == 2 and m3.accepted.call_id == @call_id
    assert m3.hangup.call_id == @call_id and m3.hangup.type == 0
    assert sender.counter == 3
  end

  # Accepted and hangup are reported from every message that carries them:
  # a caller ignores an accept that arrives before ICE connects and must see
  # a later repeat (CRS-13 section 9.7). Statuses need a newer sequence number.
  test "the receiver reports accepted and hangup from every repeat, and statuses only for newer messages" do
    sender = Control.sender()
    {p1, sender} = Control.send_event(sender, {:accepted, @call_id})

    {p2, sender} =
      Control.send_event(
        sender,
        {:sender_status,
         %{call_id: @call_id, video_enabled: false, sharing_screen: false, audio_enabled: false}}
      )

    {repeat, sender} = Control.repeat(sender)
    {p4, _sender} = Control.send_event(sender, {:hangup, @call_id, 2, 3})

    receiver = Control.receiver()
    {:ok, [{:accepted, @call_id}], receiver} = Control.receive_payload(receiver, payload(p1))

    {:ok, [{:accepted, @call_id}, {:sender_status, %{audio_enabled: false, call_id: @call_id}}],
     receiver} = Control.receive_payload(receiver, payload(p2))

    {:ok, [{:accepted, @call_id}], receiver} = Control.receive_payload(receiver, payload(repeat))
    {:ok, events, receiver} = Control.receive_payload(receiver, payload(p4))
    assert [{:accepted, @call_id}, {:hangup, @call_id, 2, 3}, {:sender_status, _}] = events

    assert {:ok, [{:accepted, @call_id}, {:hangup, @call_id, 2, 3}], _receiver} =
             Control.receive_payload(receiver, payload(p4))
  end

  test "a status without a sequence number is ignored, accepted is not" do
    message = %Control.Message{
      accepted: %Control.Accepted{call_id: 7},
      receiver_status: %Control.ReceiverStatus{call_id: 7, max_bitrate_bps: 1}
    }

    assert {:ok, [{:accepted, 7}], _} =
             Control.receive_payload(Control.receiver(), Control.encode(message))
  end

  test "empty, oversized and undecodable payloads are refused" do
    receiver = Control.receiver()
    assert {:error, :malformed} = Control.receive_payload(receiver, <<>>)

    assert {:error, :malformed} =
             Control.receive_payload(
               receiver,
               :binary.copy(<<0>>, Control.max_payload_bytes() + 1)
             )

    assert {:error, :malformed} = Control.receive_payload(receiver, <<0x0A, 0x7F>>)
  end

  test "only payload type 101 on SSRC 13 is the control channel" do
    assert Control.control_packet?(%Rtp{payload_type: 101, ssrc: 13})
    refute Control.control_packet?(%Rtp{payload_type: 101, ssrc: 2002})
    refute Control.control_packet?(%Rtp{payload_type: 102, ssrc: 13})
  end

  defp payload(packet) do
    {:ok, rtp} = Rtp.decode(packet)
    rtp.payload
  end
end
