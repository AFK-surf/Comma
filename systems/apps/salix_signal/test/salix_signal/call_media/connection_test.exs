defmodule SalixSignal.CallMedia.ConnectionTest do
  # End to end on one host: a Comma caller connection and a Comma callee
  # connection run ICE over real UDP sockets, derive their SRTP keys from the
  # exchanged parameters (CRS-13 section 4), and exchange Opus audio and
  # control messages. The callee is the carrier of a real SalixVoice call
  # with the fake model. This proves Comma agrees with itself end to end; it is
  # not interoperability evidence (test levels 6 and 7 are).
  use ExUnit.Case, async: false

  alias SalixSignal.CallMedia.Connection
  alias SalixSignal.Test.Audio
  alias SalixStore.{Keys, S3}
  alias SalixVoice.Model.Fake

  @pg SalixVoice.PG
  @call_id 0x0123456789ABCDEF

  setup do
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

    :ok
  end

  test "an accepted call carries audio both ways, and none before acceptance" do
    %{caller: caller, callee: callee, model: model} = connected_call()

    # The caller holds its audio until the callee accepts (CRS-13 section 8).
    Connection.send_audio(caller, Audio.sine(440, 900))
    refute_receive {:fake_model, ^model, {:audio, _}}, 500
    assert %{audio_in: 0} = Connection.stats(callee)

    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}, 5_000

    caller_audio = collect_model_audio(model, 700)
    assert_in_delta Audio.frequency(Audio.skip_ms(caller_audio, 100)), 440, 25
    assert Audio.rms(caller_audio) > 2_000

    # Agent audio from the model reaches the caller.
    Fake.emit(model, {:audio, Audio.sine(300, 600)})
    assert eventually(fn -> Connection.stats(caller).audio_in >= 5 end)
  end

  @tag :silent_caller
  test "an accepted silent call keeps the model audio stream running across DTX gaps" do
    %{caller: caller, callee: callee, model: model} = connected_call()
    refute_receive {:fake_model, ^model, {:audio, _}}, 50
    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}, 5_000

    silence = collect_model_audio(model, 200)
    assert silence == :binary.copy(<<0>>, byte_size(silence))
    assert Connection.stats(callee).audio_in == 0

    Connection.send_audio(caller, Audio.sine(440, 180))
    mixed = collect_model_audio(model, 600)
    assert Audio.rms(mixed) > 500
    tail = binary_part(mixed, byte_size(mixed) - 5_760, 5_760)
    assert tail == :binary.copy(<<0>>, byte_size(tail))
  end

  test "the voice call ending sends an in-band hangup to the peer" do
    %{caller: caller, callee: callee, model: model} = connected_call()
    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}, 5_000

    caller_ref = Process.monitor(caller)
    callee_ref = Process.monitor(callee)
    Fake.emit(model, {:closed, "remote_hangup", %{}})

    assert_receive {:media, :callee, {:call_ended, :caller_hangup}}, 5_000
    assert_receive {:media, :caller, {:remote_hangup, 0, nil}}, 5_000
    assert_receive {:DOWN, ^caller_ref, :process, _, _}, 5_000
    assert_receive {:DOWN, ^callee_ref, :process, _, _}, 5_000
  end

  test "an in-band hangup from the peer ends the voice call" do
    %{caller: caller, callee: callee, model: model} = connected_call()
    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}, 5_000

    Connection.hangup(caller)
    assert_receive {:media, :callee, {:remote_hangup, 0, nil}}, 5_000
    assert_receive {:fake_model, ^model, :close}, 5_000
  end

  test "a callee ignores an in-band hangup about its own device (CRS-12 section 7.1)" do
    %{caller: caller, callee: callee} = connected_call()
    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}, 5_000

    # Hangup type 1, "accepted on another device", naming the callee's device.
    Connection.hangup(caller, 1, 2)
    refute_receive {:media, :callee, {:remote_hangup, _, _}}, 1_500
    assert Process.alive?(callee)
  end

  # The peer picks every candidate address in its ICE updates; each one adds
  # candidate pairs and connectivity checks sent to that address.
  test "a peer cannot hand a connection an unbounded number of ICE candidates" do
    {peer_public, _peer_private} = SalixSignalProto.CallMedia.Keys.generate_keypair()

    {:ok, callee} =
      Connection.start_link(%{
        role: :callee,
        call_id: @call_id,
        owner: self(),
        caller_identity_key: :crypto.strong_rand_bytes(32),
        callee_identity_key: :crypto.strong_rand_bytes(32),
        remote: %{public_key: peer_public, ice_ufrag: "Ab3x", ice_pwd: String.duplicate("p", 22)},
        local_device_id: 2,
        ice_opts: [ip_filter: &ipv4?/1]
      })

    for i <- 1..200 do
      Connection.add_remote_candidate(
        callee,
        "candidate:#{i} 1 udp 2122260223 192.0.2.#{rem(i, 250) + 1} #{40_000 + i} typ host"
      )
    end

    # The ICE agent parses candidates in tasks; wait until its count settles.
    %{ice: ice} = :sys.get_state(callee)
    count = settled(fn -> length(ExICE.ICEAgent.get_remote_candidates(ice)) end)
    assert count == Connection.max_remote_candidates()
  end

  # -- Helpers -----------------------------------------------------------------

  defp connected_call do
    signaling = start_signaling(self())
    caller_ik = :crypto.strong_rand_bytes(32)
    callee_ik = :crypto.strong_rand_bytes(32)

    common = %{
      call_id: @call_id,
      owner: signaling,
      caller_identity_key: caller_ik,
      callee_identity_key: callee_ik,
      ice_opts: [ip_filter: &ipv4?/1]
    }

    {:ok, caller} = Connection.start_link(Map.put(common, :role, :caller))
    offer = Connection.local_parameters(caller)

    {:ok, callee} =
      Connection.start_link(
        Map.merge(common, %{role: :callee, remote: offer, local_device_id: 2})
      )

    send(
      signaling,
      {:peers, %{caller => callee, callee => caller}, %{caller => :caller, callee => :callee}}
    )

    :ok = Connection.set_remote(caller, Connection.local_parameters(callee))

    assert_receive {:media, :caller, {:ice, :connected}}, 10_000
    assert_receive {:media, :callee, {:ice, :connected}}, 10_000

    {:ok, _voice_call_id} =
      SalixSignal.Carrier.admit(callee, %{
        tenant_id: "ten_1",
        group_id: "grp_" <> Integer.to_string(System.unique_integer([:positive])),
        connect_id: "conn_signal",
        caller_aci: "00000000-0000-4000-8000-000000000031",
        signal_call_id: @call_id
      })

    assert_receive {:fake_model, model, {:started, _opts}}, 5_000
    Fake.emit(model, {:started, "session_1"})
    %{caller: caller, callee: callee, model: model}
  end

  # Stands in for the call-signaling layer: carries ICE candidates between
  # the two connections and reports every other event to the test.
  defp start_signaling(test) do
    spawn_link(fn ->
      receive do
        {:peers, peers, roles} -> signaling_loop(test, peers, roles)
      end
    end)
  end

  defp signaling_loop(test, peers, roles) do
    receive do
      {:signal_call_media, from, {:local_candidate, candidate}} ->
        Connection.add_remote_candidate(Map.fetch!(peers, from), candidate)

      {:signal_call_media, from, event} ->
        send(test, {:media, Map.fetch!(roles, from), event})
    end

    signaling_loop(test, peers, roles)
  end

  defp collect_model_audio(model, ms, acc \\ <<>>) do
    if byte_size(acc) >= div(24_000 * ms, 1000) * 2 do
      acc
    else
      receive do
        {:fake_model, ^model, {:audio, pcm}} -> collect_model_audio(model, ms, acc <> pcm)
      after
        5_000 -> flunk("model received #{byte_size(acc)} bytes of caller audio")
      end
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  defp settled(fun, last \\ nil, tries \\ 50) do
    Process.sleep(100)
    value = fun.()

    if value == last or tries == 0,
      do: value,
      else: settled(fun, value, tries - 1)
  end

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_ip), do: false
end
