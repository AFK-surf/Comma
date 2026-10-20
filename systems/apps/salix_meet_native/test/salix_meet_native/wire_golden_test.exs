defmodule SalixMeetNative.WireGoldenTest do
  use ExUnit.Case, async: true

  alias SalixMeetNative.{Codec, Device, Events, Frames, MediaSession, Sync, Wire}

  @root "test/fixtures/golden/root.json" |> File.read!() |> Jason.decode!()
  @mediartc "test/fixtures/golden/mediartc.json" |> File.read!() |> Jason.decode!()
  @meet "test/fixtures/golden/meet.json" |> File.read!() |> Jason.decode!()

  defp fixture(name) do
    case File.read("test/fixtures/" <> name) do
      {:ok, raw} ->
        raw

      {:error, _} ->
        "test/fixtures/#{name}.b64" |> File.read!() |> String.trim() |> Base.decode64!()
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  test "the offer keeps every template byte except DTLS/ICE credentials and start_bitrate" do
    {:ok, offer} =
      MediaSession.build_offer(
        fixture("createmediasession-offer.bin.gz"),
        "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89",
        "uFrg",
        "pwd0123456789abcdefghij"
      )

    assert hex(offer) == @mediartc["offer"]
  end

  test "the media answer yields the SFU transport and negotiated channels" do
    {:ok, answer} = MediaSession.decode_answer(fixture("createmediasession-answer.bin"))
    want = @root["media_answer"]

    assert answer.session_id == want["SessionID"]
    assert answer.fingerprint == want["SFUFingerprint"]
    assert answer.setup_role == want["SFUSetupRole"]
    assert {answer.ice_ufrag, answer.ice_pwd} == {want["ICEUfrag"], want["ICEPwd"]}

    assert Enum.map(answer.candidates, &{&1.transport, &1.ip, &1.port, &1.priority}) ==
             Enum.map(want["Candidates"], fn c ->
               {if(c["TransportType"] == 3, do: :tcp, else: :udp), c["IP"], c["Port"],
                c["Priority"]}
             end)

    assert Enum.map(answer.channels, &{&1.label, &1.id, &1.ordered, &1.max_packet_life_time}) ==
             Enum.map(
               want["DataChannels"],
               &{&1["Label"], &1["ID"], &1["Ordered"], &1["MaxPacketLifeTime"]}
             )

    preferred = MediaSession.preferred_candidate(answer)

    assert {preferred.ip, preferred.port} ==
             {@root["preferred_candidate"]["IP"], @root["preferred_candidate"]["Port"]}
  end

  test "data channel frames match the web client bytes" do
    assert hex(Frames.chat(3, 1_700_000_000_123, "你好 hello")) == @mediartc["chat"]
    assert hex(Frames.reaction(2, "🎉")) == @mediartc["reaction"]
    assert hex(Frames.meeting_agent_heartbeat(1_791_000_000)) == @mediartc["heartbeat"]
    assert hex(Frames.media_session_initial(1)) == @mediartc["media_session_initial"]
    assert hex(Frames.media_session_outbound(5, 8)) == @mediartc["media_session_outbound"]
    assert hex(Frames.media_session_ack(7)) == @mediartc["media_session_ack"]
    assert hex(Frames.media_director_video(4)) == @mediartc["media_director_video"]
    assert hex(Frames.media_director_initial()) == @mediartc["media_director_initial"]
    assert hex(Frames.media_director_second()) == @mediartc["media_director_second"]
    assert hex(Frames.caption_enable(9000, "cmn-Hans-CN", "en-US")) == @root["caption_enable"]

    session = "qsn79H57w1D4swoKAAiKYigCIAQQ"

    assert hex(Frames.dcrpc_refresh(183, session, Frames.refresh_client_info(), 1, nil)) ==
             @root["dcrpc_refresh_nil"]

    assert hex(Frames.dcrpc_refresh(185, session, Frames.refresh_client_info(), 2, 42)) ==
             @root["dcrpc_refresh_counter"]
  end

  test "a captured video subscribe re-encodes byte for byte and rebuilds from its streams" do
    raw = fixture("live/dcrpc-subscribe-videostreams.bin")
    {:ok, frame} = Codec.decode(Wire.DCRPCFrame, raw)
    assert hex(Codec.encode(frame)) == @root["video_subscribe_reencode"]

    descs =
      for s <- frame.subscribe_video_streams.streams,
          do: %{device: s.device, ssrc: s.ssrc, fid: s.fid_group}

    assert hex(
             Frames.video_subscribe(
               9,
               "msid-1",
               "msid-1",
               Frames.replay_client_info(),
               descs,
               1280,
               720
             )
           ) ==
             @root["video_subscribe"]
  end

  test "sync requests carry per-collection resume cursors" do
    assert hex(Sync.encode_request("spaces/abc", %{})) == @root["sync_request_empty"]

    assert hex(Sync.encode_request("spaces/abc", %{meeting_space: 5, devices: 9})) ==
             @root["sync_request_cursors"]

    assert hex(Sync.encode_request("spaces/abc", %{devices: 0})) ==
             @root["sync_request_zero_cursor"]
  end

  test "device RPC bodies match the web client" do
    assert hex(Device.bulk_admit_body("spaces/abc", "spaces/abc/devices/7")) ==
             @root["bulk_admit"]

    assert hex(Device.create_hand_raise_body("spaces/abc")) == @root["hand_raise_create"]

    assert hex(Device.delete_hand_raise_body("spaces/abc/handRaises/3")) ==
             @root["hand_raise_delete"]

    assert hex(Device.ack_operation_body("spaces/abc/devices/7", 5)) == @root["ack_operation"]
    assert hex(Device.mark_joined_body("spaces/abc/devices/7", "msid-1")) == @root["mark_joined"]
    assert hex(Device.mark_left_body("spaces/abc/devices/7")) == @root["mark_left"]
  end

  test "device registration binds the native media session and keeps the space" do
    body = fixture("createmeetingdevice-req.bin")
    {:ok, bound} = Device.bind_media_session(:create, body, "msid-native")
    assert hex(bound) == @meet["create_device_substituted"]
    assert Device.space(:create, body) == @meet["create_device_space"]

    {:ok, knock} =
      Device.bind_media_session(
        :create,
        fixture("createmeetingdevice-req-knock.bin"),
        "msid-native"
      )

    assert hex(knock) == @meet["knock_device_substituted"]
  end

  test "chat and reaction frames decode into the same events as the Go runtime" do
    for {channel, file} <- [
          {"collections", "chat-gif-collections.bin"},
          {"collections", "chat-reaction-collections.bin"},
          {"meet_messages", "meet_messages-in.bin"}
        ] do
      got =
        Events.decode(channel, fixture(file))
        |> Enum.map(&(&1 |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)))
        |> Jason.encode!()
        |> Jason.decode!()

      want = Enum.map(@root["events"][file], &Map.put_new(&1, "actor", ""))
      assert got == want, file
    end
  end
end
