defmodule SalixSignal.CallMedia.ConnectionTest do
  require SystemsRuntime.Proc

  # End to end on one host: a Comma caller connection and a Comma callee
  # connection run ICE over real UDP sockets, derive their SRTP keys from the
  # exchanged parameters (CRS-13 section 4), and exchange Opus audio and
  # control messages. The callee is the carrier of a real SalixVoice call
  # with the fake model. This proves Comma agrees with itself end to end; it is
  # not interoperability evidence (test levels 6 and 7 are).
  use SystemsClock.Case, async: false

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

    env = [model_mod: Fake, fake_model_observer: SystemsRuntime.Proc.self(), metering_mod: nil]

    previous =
      Enum.map(env, fn {key, _} -> {key, SystemsRuntime.fetch_env(:salix_voice, key)} end)

    Enum.each(env, fn {key, value} -> SystemsRuntime.put_env(:salix_voice, key, value) end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> SystemsRuntime.put_env(:salix_voice, key, value)
          :error -> SystemsRuntime.delete_env(:salix_voice, key)
        end
      end

      for pid <- :pg.get_members(@pg, :calls), do: SystemsRuntime.Proc.exit(pid, :kill)
      S3.delete(Keys.ctl_system_voice())
    end)

    :ok
  end

  test "an accepted call carries audio both ways, and none before acceptance" do
    %{caller: caller, callee: callee, model: model} = connected_call()

    # The caller holds its audio until the callee accepts (CRS-13 section 8).
    Connection.send_audio(caller, Audio.sine(440, 900))
    refute_receive {:fake_model, ^model, {:audio, _}}, 200
    assert %{audio_in: 0} = Connection.stats(callee)

    :ok = Connection.accept(callee)
    assert_receive {:media, :caller, :accepted}

    caller_audio = collect_model_tone(model, 700)
    assert_in_delta Audio.frequency(Audio.skip_ms(caller_audio, 100)), 440, 25
    assert Audio.rms(caller_audio) > 2_000

    # Agent audio from the model reaches the caller.
    Fake.emit(model, {:audio, Audio.sine(300, 600)})
    assert eventually(fn -> Connection.stats(caller).audio_in >= 5 end)
  end

  # -- Helpers -----------------------------------------------------------------

  defp connected_call do
    signaling = start_signaling(SystemsRuntime.Proc.self())
    caller_ik = SystemsRuntime.Proc.random_bytes(32)
    callee_ik = SystemsRuntime.Proc.random_bytes(32)

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

    SystemsRuntime.Proc.send(
      signaling,
      {:peers, %{caller => callee, callee => caller}, %{caller => :caller, callee => :callee}}
    )

    :ok = Connection.set_remote(caller, Connection.local_parameters(callee))

    assert_receive {:media, :caller, {:ice, :connected}}
    assert_receive {:media, :callee, {:ice, :connected}}

    {:ok, _voice_call_id} =
      SalixSignal.Carrier.admit(callee, %{
        tenant_id: "ten_1",
        group_id: "grp_" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
        connect_id: "conn_signal",
        caller_aci: "00000000-0000-4000-8000-000000000031",
        signal_call_id: @call_id
      })

    assert_receive {:fake_model, model, {:started, _opts}}
    Fake.emit(model, {:started, "session_1"})
    %{caller: caller, callee: callee, model: model}
  end

  # Stands in for the call-signaling layer: carries ICE candidates between
  # the two connections and reports every other event to the test.
  defp start_signaling(test) do
    SystemsRuntime.Proc.spawn_link(fn ->
      SystemsRuntime.Proc.receive do
        {:peers, peers, roles} -> signaling_loop(test, peers, roles)
      end
    end)
  end

  defp signaling_loop(test, peers, roles) do
    SystemsRuntime.Proc.receive do
      {:signal_call_media, from, {:local_candidate, candidate}} ->
        Connection.add_remote_candidate(Map.fetch!(peers, from), candidate)

      {:signal_call_media, from, event} ->
        SystemsRuntime.Proc.send(test, {:media, Map.fetch!(roles, from), event})
    end

    signaling_loop(test, peers, roles)
  end

  # Acceptance starts playout before the first RTP packet has crossed ICE
  # and the jitter buffer. Those leading silent frames have no tone to
  # measure; keep every frame once actual audio arrives, including gaps.
  defp collect_model_tone(model, ms) do
    deadline = SystemsRuntime.Proc.monotonic_time(:millisecond) + 5_000
    first = first_model_audio(model, deadline)
    collect_model_audio(model, ms, first)
  end

  defp first_model_audio(model, deadline) do
    remaining = max(deadline - SystemsRuntime.Proc.monotonic_time(:millisecond), 0)

    SystemsRuntime.Proc.receive do
      {:fake_model, ^model, {:audio, pcm}} ->
        if pcm == :binary.copy(<<0>>, byte_size(pcm)),
          do: first_model_audio(model, deadline),
          else: pcm
    after
      remaining -> flunk("model received no caller audio")
    end
  end

  defp collect_model_audio(model, ms, acc \\ <<>>) do
    if byte_size(acc) >= div(24_000 * ms, 1000) * 2 do
      acc
    else
      SystemsRuntime.Proc.receive do
        {:fake_model, ^model, {:audio, pcm}} -> collect_model_audio(model, ms, acc <> pcm)
      after
        5_000 -> flunk("model received #{byte_size(acc)} bytes of caller audio")
      end
    end
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_ip), do: false
end
