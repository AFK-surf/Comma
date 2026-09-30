defmodule SalixSignalProto.GroupCallTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.{CallSignaling, GroupCall, ServiceId}
  alias SalixSignalProto.Group.{Params, Uid}
  alias SalixSignalProto.GroupCall.{Frame, Messages, Reliable, Sfu, Wire}
  alias SalixSignalProto.GroupCall.Frame.{Receiver, Sender}
  alias SalixSignalProto.Test.Vectors

  defp hex_map(map),
    do: Map.new(map, fn {k, v} -> {k, if(is_binary(v), do: Vectors.hex!(v), else: v)} end)

  # -- Level 1: CRS-14 vectors -------------------------------------------------

  # CRS-14 section 6.2: vectors/CRS-14/sfu-srtp-key-derivation.json
  describe "CRS-14 sfu-srtp-key-derivation" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-14/sfu-srtp-key-derivation.json")["cases"]) do
      @vector vector
      test "case #{index}: the client derives the oracle keys" do
        input = hex_map(@vector["inputs"])
        out = hex_map(@vector["outputs"])
        sfu_public = SalixSignalProto.Crypto.X25519.public_key(input["server_private_for_test"])

        assert SalixSignalProto.Crypto.X25519.public_key(input["client_private"]) ==
                 out["client_dhe_public_key"]

        assert sfu_public == out["server_dhe_public_key"]

        assert {:ok, out["okm_56"]} ==
                 GroupCall.okm(input["client_private"], sfu_public, input["hkdf_extra_info"])

        assert {:ok, keys} =
                 GroupCall.srtp_keys(
                   input["client_private"],
                   sfu_public,
                   input["hkdf_extra_info"]
                 )

        assert keys.send == %{
                 key: out["client_to_sfu_srtp_key"],
                 salt: out["client_to_sfu_srtp_salt"]
               }

        assert keys.receive == %{
                 key: out["sfu_to_client_srtp_key"],
                 salt: out["sfu_to_client_srtp_salt"]
               }
      end
    end

    test "a low-order SFU key is rejected" do
      assert {:error, :invalid_public_key} =
               GroupCall.srtp_keys(:crypto.strong_rand_bytes(32), <<0::256>>)
    end
  end

  # CRS-14 section 8.1: vectors/CRS-14/frame-key-schedule.json
  describe "CRS-14 frame-key-schedule" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-14/frame-key-schedule.json")["cases"]) do
      @vector vector
      test "case #{index}: every ratchet step matches" do
        initial = Vectors.hex!(@vector["inputs"]["initial_secret"])

        for step <- @vector["outputs"]["steps"] do
          counter = step["ratchet_counter"]
          assert {^counter, secret} = Frame.advance({0, initial}, counter)
          assert secret == Vectors.hex!(step["secret"])

          assert Frame.keys(secret) == %{
                   aes_key: Vectors.hex!(step["aes_key"]),
                   hmac_key: Vectors.hex!(step["hmac_key"])
                 }
        end
      end
    end

    test "the ratchet counter wraps at 256" do
      assert {0, _} = Frame.advance({255, :crypto.strong_rand_bytes(32)}, 1)
    end
  end

  # CRS-14 section 8.2: vectors/CRS-14/frame-encryption.json
  describe "CRS-14 frame-encryption" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-14/frame-encryption.json")["cases"]) do
      @vector vector
      test "case #{index}: Comma writes the frame and a receiver of the ratchet-0 key opens it" do
        input = hex_map(@vector["inputs"])
        out = hex_map(@vector["outputs"])
        counter = input["ratchet_counter"]
        {^counter, secret} = Frame.advance({0, input["secret_at_ratchet_0"]}, counter)

        keys = Frame.keys(secret)
        assert keys == %{aes_key: out["aes_key"], hmac_key: out["hmac_key"]}

        frame = Frame.encrypt(input["plaintext"], keys, counter, input["frame_counter"])
        assert frame == out["frame"]

        # The receiver holds the key at counter 0 and advances it itself.
        receiver = Receiver.add_key(Receiver.new(), {0, input["secret_at_ratchet_0"]})
        assert {:ok, plaintext, _receiver} = Receiver.decrypt(receiver, frame)
        assert plaintext == input["plaintext"]
      end
    end
  end

  # CRS-14 section 5.3: vectors/CRS-14/opaque-user-id.json
  describe "CRS-14 opaque-user-id" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-14/opaque-user-id.json")["cases"]) do
      @vector vector
      test "case #{index}: member ID and opaque user ID" do
        params = Params.from_master_key(Vectors.hex!(@vector["inputs"]["group_master_key"]))
        {:ok, aci} = ServiceId.parse(@vector["inputs"]["aci_uuid"])
        member_id = Uid.encrypt(params, aci)
        assert member_id == Vectors.hex!(@vector["outputs"]["encrypted_member_id"])
        assert GroupCall.opaque_user_id(member_id) == @vector["outputs"]["opaque_user_id"]
      end
    end
  end

  # -- Frame receive rules (section 8.3) ----------------------------------------

  describe "frame receive rules" do
    setup do
      secret = :crypto.strong_rand_bytes(32)
      {:ok, sender: Sender.new(secret), secret: secret}
    end

    test "frames under a newer key and reordered frames under the old one both open", %{
      sender: sender,
      secret: secret
    } do
      receiver = Receiver.add_key(Receiver.new(), {0, secret})
      {:ok, old, sender} = Sender.encrypt(sender, "before")
      sender = Sender.advance(sender)
      {:ok, new, _sender} = Sender.encrypt(sender, "after")

      # A receiver of only the counter-0 key advances it to counter 1.
      assert {:ok, "after", receiver} = Receiver.decrypt(receiver, new)
      assert {:ok, "before", _receiver} = Receiver.decrypt(receiver, old)
    end

    test "a rotated key replaces nothing: the five newest keys are held" do
      keys = for _ <- 1..6, do: {0, :crypto.strong_rand_bytes(32)}
      receiver = Enum.reduce(keys, Receiver.new(), &Receiver.add_key(&2, &1))
      assert length(receiver.states) == 5

      [{_, oldest} | _] = keys
      {:ok, frame, _} = Sender.encrypt(Sender.new(oldest), "x")
      assert {:error, :authentication} = Receiver.decrypt(receiver, frame)

      {_, newest} = List.last(keys)
      {:ok, frame, _} = Sender.encrypt(Sender.new(newest), "x")
      assert {:ok, "x", _} = Receiver.decrypt(receiver, frame)
    end

    test "tampered, foreign and short frames are dropped", %{sender: sender, secret: secret} do
      receiver = Receiver.add_key(Receiver.new(), {0, secret})
      {:ok, frame, _} = Sender.encrypt(sender, "payload")
      <<first, rest::binary>> = frame
      assert {:error, :authentication} = Receiver.decrypt(receiver, <<first + 1, rest::binary>>)

      {:ok, other, _} = Sender.encrypt(Sender.new(), "payload")
      assert {:error, :authentication} = Receiver.decrypt(receiver, other)
      assert {:error, :malformed} = Receiver.decrypt(receiver, :binary.copy(<<0>>, 20))
      assert {:error, :authentication} = Receiver.decrypt(Receiver.new(), frame)
    end

    test "the frame counter runs across key changes and stops after 2^32 - 1", %{sender: sender} do
      {:ok, _, sender} = Sender.encrypt(sender, "a")
      sender = Sender.advance(sender)
      assert {:ok, frame, sender} = Sender.encrypt(sender, "b")
      assert {:ok, {_, 1, 2, _}} = Frame.split(frame)

      sender = %{sender | frame_counter: 0xFFFFFFFF}
      assert {:ok, _, sender} = Sender.encrypt(sender, "c")
      assert {:error, :exhausted} = Sender.encrypt(sender, "d")
    end
  end

  # -- SFU API (sections 4 and 5) -----------------------------------------------

  describe "SFU API" do
    test "the authorization header repeats the token's first part (section 4.2 example)" do
      assert {:ok, "Basic YTFiMmMzOmExYjJjMzpkZWFkYmVlZjoxNzAwMDAwMDAw"} =
               GroupCall.authorization("a1b2c3:deadbeef:1700000000")

      assert {:error, :invalid_token} = GroupCall.authorization("no-separator")
    end

    test "the storage token response carries the token in field 1" do
      assert {:ok, "a:b"} = Sfu.decode_token(Sfu.encode_token("a:b"))
      assert {:error, :invalid} = Sfu.decode_token(Sfu.encode_token("ab"))
    end

    test "peek: 404 with an empty body is no call; call-link and other errors fail" do
      assert {:ok, %{era_id: nil, devices: []}} = Sfu.decode_peek(404, "")
      assert {:error, :call_link} = Sfu.decode_peek(404, ~s({"reason":"expired"}))
      assert {:error, {:status, 403}} = Sfu.decode_peek(403, "")

      body =
        ~s({"conferenceId":"era1","maxDevices":16,"creator":"c0","participants":[{"opaqueUserId":"u1","demuxId":16},{"demuxId":32,"requiresSvc":true}]})

      assert {:ok, peek} = Sfu.decode_peek(200, body)
      assert peek.era_id == "era1"

      assert peek.devices == [
               %{demux_id: 16, opaque_user_id: "u1", requires_svc: false},
               %{demux_id: 32, opaque_user_id: nil, requires_svc: true}
             ]

      assert {:error, :invalid} =
               Sfu.decode_peek(200, ~s({"participants":[{"opaqueUserId":"u1"}]}))
    end

    test "join: the response yields ICE candidates and SRTP keys; 413 is a full call" do
      {client_public, client_private} = SalixSignalProto.Crypto.X25519.keypair()
      {sfu_public, sfu_private} = SalixSignalProto.Crypto.X25519.keypair()

      body =
        Sfu.join_body(%{
          ice_ufrag: "Ab12",
          ice_pwd: String.duplicate("x", 22),
          public_key: client_public
        })

      assert body["dhePublicKey"] == Base.encode16(client_public, case: :lower)
      assert body["hkdfExtraInfo"] == ""
      assert body["requiresSvc"] == false

      response =
        JSON.encode!(%{
          "demuxId" => 48,
          "udpAddresses" => ["192.0.2.1:10000", "[2001:db8::1]:10001"],
          "iceUfrag" => "sfu",
          "icePwd" => "sfupassword",
          "dhePublicKey" => Base.encode16(sfu_public, case: :lower),
          "callCreator" => "abc",
          "conferenceId" => "era",
          "clientStatus" => "SOMETHING_NEW"
        })

      assert {:ok, join} = Sfu.decode_join(200, response)
      assert join.demux_id == 48
      assert join.status == :pending
      assert join.udp == [{{192, 0, 2, 1}, 10_000}, {{8193, 3512, 0, 0, 0, 0, 0, 1}, 10_001}]

      assert ["candidate:1 1 udp 2130706430 192.0.2.1 10000 typ host", "candidate:2 " <> _] =
               Sfu.udp_candidates(join)

      # Both sides derive the same keys, in opposite directions.
      {:ok, client} = GroupCall.srtp_keys(client_private, join.public_key)
      {:ok, sfu} = GroupCall.srtp_keys(sfu_private, client_public)
      {:ok, okm} = GroupCall.okm(sfu_private, client_public, "")

      assert okm ==
               client.send.key <> client.send.salt <> client.receive.key <> client.receive.salt

      assert sfu.send == client.send

      assert {:error, :full} = Sfu.decode_join(413, "")
      assert {:error, :invalid} = Sfu.decode_join(200, ~s({"demuxId":48}))
    end
  end

  # -- SSRCs, audio level and rings --------------------------------------------

  test "SSRC classification follows the demux layout (section 7.1)" do
    assert GroupCall.classify(1, 101) == :sfu
    assert GroupCall.classify(32, 102) == {:audio, 32}
    assert GroupCall.classify(GroupCall.data_ssrc(32), 101) == {:data, 32}
    assert GroupCall.classify(32 + 2, 108) == :other
  end

  test "audio level in -dBov with the one-byte extension element ID 5 (RFC 6464)" do
    assert GroupCall.audio_level(<<0::size(960 * 16)>>) == 127

    full =
      for _ <- 1..480, into: <<>>, do: <<32_767::little-signed-16, -32_768::little-signed-16>>

    assert GroupCall.audio_level(full) == 0
    assert {0xBEDE, <<0x50, 1::1, 20::7>>} = GroupCall.audio_level_extension(20)
    assert {0xBEDE, <<0x50, 0::1, 127::7>>} = GroupCall.audio_level_extension(127)
  end

  test "ring IDs from era IDs (section 11 illustrations)" do
    assert GroupCall.ring_id("0123456789abcdef") == 81_985_529_216_486_895
    assert GroupCall.ring_id("0000000000000000") == -1
    assert GroupCall.ring_id("not-hex-era") == 1_983_219_183_532_732_176
  end

  # -- Messages ----------------------------------------------------------------

  describe "messages over Signal" do
    test "a media key call message reads back through the opaque payload" do
      gid = :crypto.strong_rand_bytes(32)
      secret = :crypto.strong_rand_bytes(32)
      message = GroupCall.Messages.media_key(gid, 7, secret, 48)

      assert {:ok, %{payload: {:opaque, data, :droppable}}} = CallSignaling.decode(message)

      assert {:ok,
              {:device,
               %{group_id: ^gid, media_key: %{counter: 7, secret: ^secret, demux_id: 48}}}} =
               Messages.decode_opaque(data)

      assert {:ok, %{payload: {:opaque, leaving, :droppable}}} =
               CallSignaling.decode(Messages.leaving(gid, 48))

      assert {:ok, {:device, %{leaving: 48, media_key: nil}}} = Messages.decode_opaque(leaving)
    end

    test "invalid media keys are ignored (section 9.1)" do
      gid = :crypto.strong_rand_bytes(32)

      for key <- [
            %Wire.MediaKey{ratchet_counter: 256, secret: <<1::256>>, demux_id: 16},
            %Wire.MediaKey{ratchet_counter: 1, secret: <<1::128>>, demux_id: 16},
            %Wire.MediaKey{ratchet_counter: 1, secret: <<1::256>>}
          ] do
        data =
          Wire.OpaqueCallMessage.encode(%Wire.OpaqueCallMessage{
            device_message: %Wire.DeviceToDevice{group_id: gid, media_key: key}
          })

        assert {:ok, {:device, %{media_key: nil}}} = Messages.decode_opaque(data)
      end
    end

    test "a ring intention is examined before the device message (CRS-12 section 5.4)" do
      gid = :crypto.strong_rand_bytes(32)

      assert {:ok, %{payload: {:opaque, data, :immediate}}} =
               CallSignaling.decode(Messages.ring(gid, :ring, -5))

      assert {:ok, {:ring, %{group_id: ^gid, type: :ring, ring_id: -5}}} =
               Messages.decode_opaque(data)

      both =
        Wire.OpaqueCallMessage.encode(%Wire.OpaqueCallMessage{
          device_message: %Wire.DeviceToDevice{group_id: gid},
          ring_response: %Wire.RingResponse{group_id: gid, type: 3, ring_id: 9}
        })

      assert {:ok, {:ring_response, %{type: :busy, ring_id: 9}}} = Messages.decode_opaque(both)
    end
  end

  describe "SFU data" do
    test "a notification without peek info, or with a device lacking a demux ID, asks for a re-peek" do
      assert :repeek =
               Messages.peek_info(%Wire.SfuToDevice{
                 device_joined_or_left: %Wire.DeviceJoinedOrLeft{}
               })

      info = %Wire.PeekInfo{
        era_id: "e",
        devices: [
          %Wire.PeekDevice{demux_id: 16, opaque_user_id: "u"},
          %Wire.PeekDevice{opaque_user_id: "v"}
        ]
      }

      message = %Wire.SfuToDevice{
        device_joined_or_left: %Wire.DeviceJoinedOrLeft{peek_info: info}
      }

      assert :repeek = Messages.peek_info(message)

      info = %{info | devices: [%Wire.PeekDevice{demux_id: 16, opaque_user_id: "u"}]}

      message = %Wire.SfuToDevice{
        device_joined_or_left: %Wire.DeviceJoinedOrLeft{peek_info: info}
      }

      assert {:ok, %{era_id: "e", devices: [%{demux_id: 16, opaque_user_id: "u"}]}} =
               Messages.peek_info(message)
    end

    test "heartbeats and leave notices read back" do
      assert {:ok, {:heartbeat, %{audio_muted: false, video_muted: true}}} =
               Messages.decode_device_data(Messages.heartbeat())

      assert {:ok, :leaving} = Messages.decode_device_data(Messages.leaving_via_sfu())
    end

    test "reliable messages are delivered once, in order, and acknowledged" do
      m = fn seq, extra ->
        struct(
          %Wire.SfuToDevice{reliability: %Wire.ReliabilityHeader{seqnum: seq}},
          extra
        )
      end

      removed = m.(2, removed: %Wire.Empty{})
      speaker = m.(1, speaker: %Wire.Speaker{demux_id: 16})

      state = Reliable.new()
      assert {[], 1, state} = Reliable.receive(state, removed)
      assert {[first, second], 3, state} = Reliable.receive(state, speaker)
      assert %{speaker: %{demux_id: 16}, reliability: nil} = first
      assert %{removed: %Wire.Empty{}} = second

      # A duplicate is acknowledged again but not delivered.
      assert {[], 3, state} = Reliable.receive(state, speaker)

      # Outside the window of 64: dropped.
      assert {[], 3, _} = Reliable.receive(state, m.(3 + 64, removed: %Wire.Empty{}))

      # Unreliable messages pass at once; pure acknowledgements are dropped.
      plain = %Wire.SfuToDevice{removed: %Wire.Empty{}}
      assert {[^plain], nil, _} = Reliable.receive(state, plain)

      ack = %Wire.SfuToDevice{reliability: %Wire.ReliabilityHeader{ack: 5}}
      assert {[], nil, _} = Reliable.receive(state, ack)
    end

    test "fragments are joined in sequence order and decoded as one message" do
      info = %Wire.PeekInfo{
        era_id: String.duplicate("e", 2000),
        devices:
          for(
            d <- 1..40,
            do: %Wire.PeekDevice{demux_id: d * 16, opaque_user_id: String.duplicate("a", 64)}
          )
      }

      whole =
        Wire.SfuToDevice.encode(%Wire.SfuToDevice{
          device_joined_or_left: %Wire.DeviceJoinedOrLeft{peek_info: info}
        })

      chunks = for <<chunk::binary-size(1140) <- pad(whole)>>, do: chunk
      chunks = trim_last(chunks, byte_size(whole))
      count = length(chunks)
      assert count > 2

      packets =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, seq} ->
          header = %Wire.ReliabilityHeader{seqnum: seq, fragment_count: if(seq == 1, do: count)}
          # Other fields of a fragment packet are ignored.
          %Wire.SfuToDevice{reliability: header, fragment: chunk, removed: %Wire.Empty{}}
        end)

      # Deliver out of order: the last one first.
      [last | rest] = Enum.reverse(packets)
      {[], 1, state} = Reliable.receive(Reliable.new(), last)

      {delivered, state} =
        Enum.reduce(Enum.reverse(rest), {[], state}, fn packet, {acc, state} ->
          {messages, _ack, state} = Reliable.receive(state, packet)
          {acc ++ messages, state}
        end)

      assert state.next == count + 1
      assert [%Wire.SfuToDevice{removed: nil} = message] = delivered
      assert {:ok, %{devices: devices}} = Messages.peek_info(message)
      assert length(devices) == 40
    end
  end

  defp pad(bin), do: bin <> :binary.copy(<<0>>, 1140 - rem(byte_size(bin), 1140))

  defp trim_last(chunks, total) do
    {init, [last]} = Enum.split(chunks, -1)
    init ++ [binary_part(last, 0, total - 1140 * length(init))]
  end
end
