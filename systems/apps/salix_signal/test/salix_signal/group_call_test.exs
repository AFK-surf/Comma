defmodule SalixSignal.GroupCallTest do
  # Group calls end to end on one host (CRS-14). A Comma session joins a fake
  # calling server (test/support/fake_sfu.ex) over HTTPS, runs ICE and
  # AEAD_AES_128_GCM SRTP to it over real UDP sockets, and exchanges
  # frame-encrypted audio and data with simulated remote devices whose keys
  # travel as call messages. The session is the carrier of a real SalixVoice
  # call with the fake model. This proves Comma agrees with its reading of
  # CRS-14 end to end; it is not interoperability evidence (test levels 6
  # and 7 are).
  use ExUnit.Case, async: false

  alias SalixSignal.GroupCall
  alias SalixSignal.GroupCall.{Session, Sfu}
  alias SalixSignal.CallMedia.Opus
  alias SalixSignal.Test.{Audio, FakeChat, FakeSfu, FakeStorage}
  alias SalixSignalProto.{CallSignaling, ServiceId}
  alias SalixSignalProto.CallMedia.Rtp
  alias SalixSignalProto.Group.{AuthCredential, Params, ServerParams, Storage, Uid, Wire}
  alias SalixSignalProto.GroupCall, as: Proto
  alias SalixSignalProto.GroupCall.{Messages}
  alias SalixSignalProto.GroupCall.Frame.{Receiver, Sender}
  alias SalixSignalProto.GroupCall.Wire, as: CallWire
  alias SalixStore.{Keys, S3}
  alias SalixVoice.Model.Fake

  @pg SalixVoice.PG
  @own "00000000-0000-4000-8000-000000000031"
  @bob "00000000-0000-4000-8000-000000000032"
  @carol "00000000-0000-4000-8000-000000000033"
  @token "fake:token"
  @bob_demux 0x20
  @carol_demux 0x30

  # Upper bound for any wait on a loaded machine; a wait ends as soon as
  # its message arrives.
  @wait_ms 30_000

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    S3.delete(Keys.ctl_system_voice())

    {:ok, _} =
      SalixVoice.Settings.update(%{
        "enabled" => true,
        "openai_api_key" => "sk-test",
        "max_calls_per_node" => 50
      })

    env = [model_mod: Fake, fake_model_observer: self(), metering_mod: nil]
    previous = Enum.map(env, fn {key, _} -> {key, Application.fetch_env(:salix_voice, key)} end)
    Enum.each(env, fn {key, value} -> Application.put_env(:salix_voice, key, value) end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:salix_voice, key, value)
          :error -> Application.delete_env(:salix_voice, key)
        end
      end

      for pid <- :pg.get_members(@pg, :calls), do: Process.exit(pid, :kill)
      S3.delete(Keys.ctl_system_voice())
    end)

    params = Params.from_master_key(:crypto.strong_rand_bytes(32))

    members =
      for aci <- [@own, @bob, @carol] do
        {:ok, service_id} = ServiceId.parse(aci)
        %{aci: aci, member_id: Uid.encrypt(params, service_id)}
      end

    opaque = Map.new(members, &{&1.aci, Proto.opaque_user_id(&1.member_id)})
    sfu = start_supervised!({FakeSfu, {self(), @token, []}})
    server = start_supervised!({Bandit, FakeSfu.bandit_options(sfu, chain)}, id: :sfu_http)

    %{
      params: params,
      members: members,
      opaque: opaque,
      sfu: sfu,
      sfu_url: "https://localhost:#{FakeChat.port(server)}",
      bob: Sender.new(),
      carol: Sender.new()
    }
  end

  test "join, key exchange, mixed audio both ways, rotation when an account leaves, and leave",
       ctx do
    FakeSfu.put_devices(ctx.sfu, [
      {@bob_demux, ctx.opaque[@bob]},
      {@carol_demux, ctx.opaque[@carol]}
    ])

    session = join!(ctx)

    # Join: a fresh key, ICE credentials of letters and digits like deployed
    # clients', no SVC; then the era goes to the group (sections 3, 5.4).
    assert_receive {:fake_sfu, :join_request, request}, @wait_ms
    assert request["iceUfrag"] =~ ~r/\A[A-Za-z0-9]{4,}\z/
    assert request["icePwd"] =~ ~r/\A[A-Za-z0-9]{22,}\z/
    assert request["requiresSvc"] == false

    assert_receive {:signal_group_call, ^session, {:joined, %{demux_id: 0x10, era_id: era}}},
                   @wait_ms

    assert_receive {:announce, ^era}, @wait_ms

    # Two devices appeared: the key advances to counter 1 and goes to both
    # accounts as a droppable call message (sections 9.1 to 9.3).
    assert_receive {:sent, recipients, message, %{urgent: false}}, @wait_ms
    assert Enum.sort(recipients) == [@bob, @carol]
    %{counter: 1, secret: comma_secret, demux_id: 0x10} = media_key!(ctx, message)
    comma = Receiver.add_key(Receiver.new(), {1, comma_secret})

    assert_receive {:fake_sfu, :ice, :connected}, @wait_ms

    # Through the SFU: a video request for no video on SSRC 1 and
    # frame-encrypted heartbeats on SSRC demux + 13 (sections 10.2, 10.5).
    assert %CallWire.DeviceToSfu{video_request: request} = sfu_message!()

    assert Enum.sort(Enum.map(request.requests, &{&1.demux_id, &1.height})) == [
             {0x20, 0},
             {0x30, 0}
           ]

    assert request.active_speaker_height == 0
    # Heartbeats sent before Comma switched to the advanced key do not open
    # under it; later ones do.
    assert eventually_receive(fn ->
             match?(
               {:heartbeat, %{video_muted: true, audio_muted: false}},
               device_data!(comma, 0x10)
             )
           end)

    # A key that Carol's account sends for Bob's device is ignored
    # (section 9.4); Bob's own key is accepted.
    wrong = Sender.new()
    deliver_key(ctx, @carol, @bob_demux, wrong)
    deliver_key(ctx, @bob, @bob_demux, ctx.bob)

    voice_call = admit!(session, ctx)
    model = voice_call.model

    # Frames under the foreign key are dropped; Bob's audio reaches the call.
    speak(ctx.sfu, wrong, @bob_demux, Audio.sine(440, 180), 0)
    assert eventually(fn -> Session.info(session).undecryptable >= 3 end)
    assert Session.info(session).audio_in == 0

    # Media is real time: frames that a loaded host delivers too late are
    # dropped, as on a network. Bob speaks for longer than the audio the
    # test needs, so drops do not starve it.
    speak(ctx.sfu, ctx.bob, @bob_demux, Audio.sine(440, 1_800), 100)
    heard = collect_model_audio(model, 500)
    assert_in_delta Audio.frequency(Audio.skip_ms(heard, 100)), 440, 25

    # Agent audio goes out on SSRC = own demux ID, payload type 102, with the
    # audio-level extension (ID 5), frame-encrypted under Comma's key.
    Fake.emit(model, {:audio, Audio.sine(300, 1_200)})
    pcm = collect_sent_audio(comma, 0x10, 300)
    assert_in_delta Audio.frequency(pcm), 300, 25

    # Carol's account leaves: the SFU notifies reliably without peek info,
    # Comma acknowledges and re-peeks, then rotates: a new key with counter 0
    # goes to Bob, and Comma switches to it after the rotation delay.
    FakeSfu.put_devices(ctx.sfu, [{@bob_demux, ctx.opaque[@bob]}])

    notify_sfu(ctx.sfu, %CallWire.SfuToDevice{
      device_joined_or_left: %CallWire.DeviceJoinedOrLeft{},
      reliability: %CallWire.ReliabilityHeader{seqnum: 1}
    })

    assert eventually_receive(fn ->
             match?(%CallWire.DeviceToSfu{reliability: %{ack: 2}}, sfu_message!())
           end)

    assert_receive {:sent, [@bob], rotated, %{urgent: false}}, @wait_ms
    %{counter: 0, secret: new_secret} = media_key!(ctx, rotated)
    refute new_secret == comma_secret

    # After the rotation delay Comma's heartbeats decrypt under the new key;
    # the ones sent before do not.
    rotated_receiver = Receiver.add_key(Receiver.new(), {0, new_secret})

    assert eventually_receive(fn ->
             match?({:heartbeat, _}, device_data!(rotated_receiver, 0x10))
           end)

    # Leave (section 10.3): a leaving notice through the SFU and over
    # signaling, the SFU leave twice, and the era update to the group.
    ref = Process.monitor(session)
    GroupCall.leave(session)
    assert eventually_receive(fn -> device_data!(rotated_receiver, 0x10) == :leaving end)
    assert_receive {:sent, [@bob], leaving, _}, @wait_ms
    assert {:ok, {:device, %{leaving: 0x10}}} = decode_opaque(leaving)
    assert eventually_receive(fn -> match?(%{leave: %CallWire.Empty{}}, sfu_message!()) end)
    assert %CallWire.DeviceToSfu{leave: %CallWire.Empty{}} = sfu_message!()
    assert_receive {:announce, ^era}, @wait_ms
    assert_receive {:DOWN, ^ref, :process, _, _}, @wait_ms
    assert_receive {:fake_model, ^model, :close}, @wait_ms
  end

  test "a device appearing later gets the advanced key and the pending rotated key", ctx do
    FakeSfu.put_devices(ctx.sfu, [{@bob_demux, ctx.opaque[@bob]}])
    session = join!(ctx, rotation_delay_ms: 5_000)
    assert_receive {:sent, [@bob], first, _}, @wait_ms
    %{counter: 1} = media_key!(ctx, first)
    assert_receive {:fake_sfu, :ice, :connected}, @wait_ms

    # Bob's account leaves and a rotation starts (no one is left to tell).
    FakeSfu.put_devices(ctx.sfu, [])

    notify_sfu(ctx.sfu, %CallWire.SfuToDevice{
      device_joined_or_left: %CallWire.DeviceJoinedOrLeft{}
    })

    assert eventually(fn -> Session.info(session).pending_key != nil end)

    # Carol's key arrives, through the call-signaling dispatcher, before her
    # device is in the call: it is held until the device appears (section
    # 9.4).
    signaling = start_signaling()
    now = System.system_time(:millisecond)
    {counter, secret} = Sender.key(ctx.carol)

    SalixSignal.CallSignaling.receive_message(signaling, %{
      sender_aci: @carol,
      sender_device_id: 1,
      call_message: Messages.media_key(ctx.params.group_id, counter, secret, @carol_demux),
      server_timestamp_ms: now,
      delivery_timestamp_ms: now
    })

    assert_receive {:fake_sfu, "GET"}, @wait_ms

    # Carol joins while the rotation is pending: she gets the advanced
    # current key (counter 2) and the pending key with counter 0 (section
    # 9.3). The notification carries the peek itself (section 10.7).
    FakeSfu.put_devices(ctx.sfu, [{@carol_demux, ctx.opaque[@carol]}])

    notify_sfu(ctx.sfu, %CallWire.SfuToDevice{
      device_joined_or_left: %CallWire.DeviceJoinedOrLeft{
        peek_info: %CallWire.PeekInfo{
          era_id: "0123456789abcdef",
          devices: [
            %CallWire.PeekDevice{demux_id: 0x10, opaque_user_id: ctx.opaque[@own]},
            %CallWire.PeekDevice{demux_id: @carol_demux, opaque_user_id: ctx.opaque[@carol]}
          ]
        }
      }
    })

    # The two sends run concurrently, so their order is not fixed.
    assert_receive {:sent, [@carol], one, _}, @wait_ms
    assert_receive {:sent, [@carol], two, _}, @wait_ms

    assert [%{counter: 0, secret: secret}, %{counter: 2}] =
             Enum.sort_by([media_key!(ctx, one), media_key!(ctx, two)], & &1.counter)

    assert Session.info(session).pending_key == secret

    # Her held key now opens her audio.
    speak(ctx.sfu, ctx.carol, @carol_demux, Audio.sine(500, 240), 0)
    assert eventually(fn -> Session.info(session).audio_in >= 3 end)
    assert Session.info(session).undecryptable == 0
  end

  test "the first video request waits for the first peek and lists its devices", ctx do
    # CRS-14 sections 10.5 and 12: the video request names every remote
    # demux ID. When ICE connects before the first peek answers, Comma sends
    # no video request until the peek has told it the devices.
    FakeSfu.put_devices(ctx.sfu, [{@bob_demux, ctx.opaque[@bob]}])
    :ok = FakeSfu.hold_peeks(ctx.sfu)
    session = join!(ctx)

    assert_receive {:fake_sfu, :ice, :connected}, @wait_ms
    assert_receive {:signal_group_call, ^session, {:ice, :connected}}, @wait_ms
    assert_receive {:fake_sfu, "GET"}, @wait_ms
    refute_receive {:fake_sfu, :rtp, %Rtp{ssrc: 1}}, 300

    :ok = FakeSfu.release_peeks(ctx.sfu)
    assert %CallWire.DeviceToSfu{video_request: request} = sfu_message!()
    assert Enum.map(request.requests, &{&1.demux_id, &1.height}) == [{@bob_demux, 0}]
  end

  test "a token the SFU refuses fails the join; a key for a group without a call is ignored",
       ctx do
    {:ok, session} =
      GroupCall.join(session_opts(ctx, token: fn -> {:ok, "wrong:token"} end))

    ref = Process.monitor(session)

    assert_receive {:signal_group_call, ^session, {:left, {:join_failed, {:status, 401}}}},
                   @wait_ms

    assert_receive {:DOWN, ^ref, :process, _, _}, @wait_ms

    # No session: the key is dropped without error.
    data = opaque_data(Messages.media_key(ctx.params.group_id, 0, <<1::256>>, @bob_demux))
    assert :ok = GroupCall.handle_opaque(@own, %{sender_aci: @bob, data: data, age_s: 0})
  end

  test "rings younger than 60 seconds reach the ring handler", ctx do
    data =
      opaque_data(Messages.ring(ctx.params.group_id, :ring, Proto.ring_id("0123456789abcdef")))

    test = self()
    on_ring = fn ring -> send(test, {:ring, ring}) end

    GroupCall.handle_opaque(@own, %{sender_aci: @bob, data: data, age_s: 61}, on_ring: on_ring)
    refute_receive {:ring, _}, 100

    GroupCall.handle_opaque(@own, %{sender_aci: @bob, data: data, age_s: 3}, on_ring: on_ring)
    assert_receive {:ring, %{type: :ring, ring_id: 81_985_529_216_486_895, sender_aci: @bob}}
  end

  test "the membership token comes from the storage service with a group auth presentation",
       %{chain: chain} do
    now = 1_758_758_400 + 7_200
    secret = ServerParams.generate(:binary.copy(<<0x78>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    aci = <<0x00000000000040008000000000000031::128>>
    pni = <<0x00000000000040008000000000000034::128>>
    storage = start_supervised!({FakeStorage, {self(), secret, now}})

    storage_server =
      start_supervised!({Bandit, FakeStorage.bandit_options(storage, chain)}, id: :storage)

    day = now - rem(now, 86_400)

    {:ok, credentials} =
      Storage.receive_credentials(
        server,
        aci,
        %{
          "credentials" => [
            %{
              "credential" =>
                Base.encode64(
                  AuthCredential.issue(secret, aci, pni, day, :crypto.strong_rand_bytes(32))
                ),
              "redemptionTime" => day
            }
          ],
          "pni" => ServiceId.uuid_string(pni)
        },
        nil
      )

    client =
      SalixSignal.Groups.client(server, credentials,
        storage_url: "https://localhost:#{FakeChat.port(storage_server)}",
        http: [roots: [chain.root]],
        now: fn -> now end
      )

    params = Params.from_master_key(:crypto.strong_rand_bytes(32))
    FakeStorage.put_group(storage, params, %Wire.Group{revision: 1, members: []})
    assert {:error, _} = Sfu.fetch_token(client, params)

    other = Params.from_master_key(:crypto.strong_rand_bytes(32))

    FakeStorage.put_group(storage, other, %Wire.Group{
      revision: 1,
      members: [%Wire.Member{user_id: Uid.encrypt(other, {:aci, aci}), role: 1}]
    })

    assert {:ok, "fake:" <> _ = token} = Sfu.fetch_token(client, other)
    assert {:ok, "Basic " <> _} = Proto.authorization(token)
  end

  # -- Helpers -----------------------------------------------------------------

  defp session_opts(ctx, overrides) do
    test = self()

    Keyword.merge(
      [
        group_id: ctx.params.group_id,
        aci: @own,
        owner: test,
        token: fn -> {:ok, @token} end,
        members: fn -> {:ok, ctx.members} end,
        send: fn acis, message, opts -> send(test, {:sent, acis, message, opts}) && :ok end,
        announce: fn era -> send(test, {:announce, era}) && :ok end,
        sfu_url: ctx.sfu_url,
        http: [roots: [ctx.chain.root]],
        ice_opts: [ip_filter: &ipv4?/1],
        rotation_delay_ms: 300
      ],
      overrides
    )
  end

  # A call-signaling dispatcher of this account whose opaque payloads go to
  # the group calls (SalixSignal.CallSignaling option `opaque`).
  defp start_signaling do
    start_supervised!(
      {SalixSignal.CallSignaling,
       aci: @own,
       device_id: 1,
       identity_key: :crypto.strong_rand_bytes(32),
       peer_identity_key: fn _aci -> {:ok, :crypto.strong_rand_bytes(32)} end,
       send: fn _aci, _message, _opts -> :ok end,
       incoming_call: fn _info -> :busy end,
       admit: fn _info, _connection -> {:error, :unused} end,
       opaque: &GroupCall.handle_opaque(@own, &1)}
    )
  end

  defp join!(ctx, overrides \\ []) do
    {:ok, session} = GroupCall.join(session_opts(ctx, overrides))
    session
  end

  defp admit!(session, ctx) do
    {:ok, _voice_call_id} =
      SalixSignal.Carrier.admit_group_call(session, %{
        tenant_id: "ten_1",
        group_id: "grp_" <> Integer.to_string(System.unique_integer([:positive])),
        connect_id: "conn_signal",
        signal_group_id: ctx.params.group_id,
        era_id: "0123456789abcdef"
      })

    assert_receive {:fake_model, model, {:started, _opts}}, @wait_ms
    Fake.emit(model, {:started, "session_1"})
    %{model: model}
  end

  defp deliver_key(ctx, sender_aci, demux, %Sender{} = sender) do
    {counter, secret} = Sender.key(sender)
    data = opaque_data(Messages.media_key(ctx.params.group_id, counter, secret, demux))
    GroupCall.handle_opaque(@own, %{sender_aci: sender_aci, data: data, age_s: 0})
  end

  defp opaque_data(call_message) do
    {:ok, %{payload: {:opaque, data, _}}} = CallSignaling.decode(call_message)
    data
  end

  defp decode_opaque(call_message), do: Messages.decode_opaque(opaque_data(call_message))

  defp media_key!(ctx, call_message) do
    {:ok, {:device, %{group_id: gid, media_key: key}}} = decode_opaque(call_message)
    assert gid == ctx.params.group_id
    key
  end

  # Sends `pcm` as a remote device: 60 ms Opus frames, frame-encrypted,
  # RTP payload type 102 on SSRC = demux ID, paced at real time.
  defp speak(sfu, sender, demux, pcm, first_seq) do
    {:ok, encoder} = Opus.encoder()

    pcm
    |> Audio.frames(Opus.frame_bytes())
    |> Enum.with_index()
    |> Enum.reduce(sender, fn {frame, i}, sender ->
      {:ok, opus} = Opus.encode(encoder, frame)
      {:ok, encrypted, sender} = Sender.encrypt(sender, opus)

      packet =
        Rtp.encode(%Rtp{
          payload_type: 102,
          sequence_number: first_seq + i,
          timestamp: (first_seq + i) * 2880,
          ssrc: demux,
          extension: Proto.audio_level_extension(30),
          payload: encrypted
        })

      :ok = FakeSfu.send_rtp(sfu, packet)
      Process.sleep(60)
      sender
    end)
  end

  defp notify_sfu(sfu, message) do
    Process.put(:sfu_seq, (Process.get(:sfu_seq) || 0) + 1)
    seq = Process.get(:sfu_seq)

    packet =
      Rtp.encode(%Rtp{
        payload_type: 101,
        sequence_number: seq,
        timestamp: seq,
        ssrc: 1,
        payload: CallWire.SfuToDevice.encode(message)
      })

    :ok = FakeSfu.send_rtp(sfu, packet)
  end

  # The next device-to-SFU message from the client (SSRC 1, no frame
  # encryption).
  defp sfu_message! do
    receive do
      {:fake_sfu, :rtp, %Rtp{ssrc: 1, payload_type: 101, payload: payload}} ->
        CallWire.DeviceToSfu.decode(payload)
    after
      @wait_ms -> flunk("no device-to-SFU message")
    end
  end

  # The next device-to-device message that `demux` sends through the SFU,
  # decrypted with `receiver`.
  defp device_data!(receiver, demux) do
    data_ssrc = Proto.data_ssrc(demux)

    receive do
      {:fake_sfu, :rtp, %Rtp{ssrc: ^data_ssrc, payload_type: 101, payload: payload}} ->
        case Receiver.decrypt(receiver, payload) do
          {:ok, plaintext, _} ->
            {:ok, message} = Messages.decode_device_data(plaintext)
            message

          {:error, reason} ->
            {:error, reason}
        end
    after
      @wait_ms -> flunk("no device-to-device message")
    end
  end

  defp collect_sent_audio(receiver, demux, ms, acc \\ <<>>, decoder \\ nil) do
    {:ok, decoder} = if decoder, do: {:ok, decoder}, else: Opus.decoder()

    if byte_size(acc) >= div(24_000 * ms, 1000) * 2 do
      acc
    else
      receive do
        {:fake_sfu, :rtp, %Rtp{ssrc: ^demux, payload_type: 102} = rtp} ->
          assert {0xBEDE, <<5::4, 0::4, _v::1, _level::7, _::binary>>} = rtp.extension
          {:ok, opus, _} = Receiver.decrypt(receiver, rtp.payload)
          {:ok, pcm} = Opus.decode(decoder, opus)
          collect_sent_audio(receiver, demux, ms, acc <> pcm, decoder)
      after
        @wait_ms -> flunk("received #{byte_size(acc)} bytes of agent audio")
      end
    end
  end

  defp collect_model_audio(model, ms, acc \\ <<>>) do
    if byte_size(acc) >= div(24_000 * ms, 1000) * 2 do
      acc
    else
      receive do
        {:fake_model, ^model, {:audio, pcm}} -> collect_model_audio(model, ms, acc <> pcm)
      after
        @wait_ms -> flunk("model received #{byte_size(acc)} bytes of group audio")
      end
    end
  end

  # Reads messages until `fun` returns true (it may consume one message per
  # call), for at most @wait_ms.
  defp eventually_receive(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> eventually_receive(fun, deadline)
    end
  end

  # Polls `fun` every 100 ms until it returns true, for at most @wait_ms.
  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(100) && eventually(fun, deadline)
    end
  end

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_ip), do: false
end
