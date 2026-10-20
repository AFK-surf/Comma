defmodule SalixSignal.CallSignalingTest do
  # Two Comma accounts on one host call each other: each account's
  # CallSignaling process sends its call messages to the other through a
  # test transport, and the media connections run ICE over real UDP sockets.
  # The callee is the carrier of a real SalixVoice call with the fake model.
  # This proves Comma's two roles agree with each other and follow the CRS-12
  # wire rules; it is not interoperability evidence (test levels 6 and 7).
  use SystemsClock.Case, async: false

  alias SalixSignal.CallSignaling
  alias SalixSignalProto.CallSignaling, as: Proto
  alias SalixStore.{Keys, S3}
  alias SalixVoice.Model.Fake

  @pg SalixVoice.PG
  @alice "00000000-0000-4000-8000-000000000001"
  @comma "00000000-0000-4000-8000-000000000002"
  @alice_device 3
  @comma_device 1

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

    keys = %{
      @alice => SystemsRuntime.Proc.random_bytes(32),
      @comma => <<5>> <> SystemsRuntime.Proc.random_bytes(32)
    }

    {:ok, peers} = Agent.start_link(fn -> %{} end)
    %{keys: keys, peers: peers}
  end

  test "an incoming call rings, connects, is accepted in-band and ends with a hangup", ctx do
    alice = start_account(ctx, @alice, @alice_device, admit: fn _info, _conn -> :ok end)
    comma = start_account(ctx, @comma, @comma_device, admit: &admit_voice_call/2)

    {:ok, _call, call_id} = CallSignaling.call(alice, @comma)

    # The caller broadcasts one urgent offer (CRS-12 sections 6 and 7.1).
    assert_receive {:sent, @alice, {:offer, %{call_id: ^call_id, media_type: :audio}}, nil, true}

    # The callee answers and sends ICE updates targeted at the offering
    # device (CRS-12 section 7.2).
    assert_receive {:sent, @comma, {:answer, %{call_id: ^call_id, parameters: params}},
                    @alice_device, false}

    assert params.encode_video_codecs == [:vp8] and params.decode_video_codecs == [:vp8]
    assert_receive {:sent, @comma, {:ice, ^call_id, [_ | _]}, @alice_device, false}

    # ICE connects, the voice call is admitted, the callee accepts in-band,
    # and the caller tells the other callee devices with hangup type 1.
    assert_receive {:fake_model, model, {:started, _opts}}
    Fake.emit(model, {:started, "session_1"})

    assert_receive {:sent, @alice, {:hangup, ^call_id, :accepted_elsewhere, @comma_device}, nil,
                    true}

    # The callee reports its status after it sends the accept, so the caller's
    # hangup can arrive first.
    assert eventually(fn ->
             match?(
               [%{role: :callee, connected_device: @alice_device, connected_and_accepted: true}],
               CallSignaling.calls(comma)
             )
           end)

    # A local hangup at the caller: broadcast hangup type 0 (CRS-12 section
    # 7.3). The callee sends nothing and its voice call ends.
    [%{pid: caller_call}] = CallSignaling.calls(alice)
    ref = SystemsRuntime.Proc.monitor(caller_call)
    :ok = CallSignaling.hangup(caller_call)

    assert_receive {:sent, @alice, {:hangup, ^call_id, :normal, nil}, nil, true}
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert_receive {:fake_model, ^model, :close}
    assert eventually(fn -> CallSignaling.calls(comma) == [] end)
    refute_received {:sent, @comma, {:hangup, _, _, _}, _, _}
  end

  test "a caller that may not call gets hangup type 4, and the caller propagates it", ctx do
    alice = start_account(ctx, @alice, @alice_device, admit: fn _info, _conn -> :ok end)

    _comma =
      start_account(ctx, @comma, @comma_device, incoming_call: fn _info -> :needs_permission end)

    {:ok, _call, call_id} = CallSignaling.call(alice, @comma)

    assert_receive {:sent, @comma, {:hangup, ^call_id, :needs_permission, nil}, nil, true}

    assert_receive {:sent, @alice, {:hangup, ^call_id, :needs_permission, @comma_device}, nil,
                    true}

    assert eventually(fn -> CallSignaling.calls(alice) == [] end)
    refute_received {:sent, @comma, {:answer, _}, _, _}
  end

  describe "glare (CRS-12 section 8)" do
  end

  # -- Helpers -----------------------------------------------------------------

  defp start_account(ctx, aci, device, opts \\ []) do
    test = SystemsRuntime.Proc.self()
    peers = ctx.peers
    keys = ctx.keys

    send_fun = fn recipient, message, %{urgent: urgent} ->
      {:ok, %{payload: payload, destination_device_id: destination}} = Proto.decode(message)
      SystemsRuntime.Proc.send(test, {:sent, aci, payload, destination, urgent})

      case Agent.get(peers, &Map.get(&1, recipient)) do
        nil ->
          :ok

        pid ->
          now = SystemsClock.system_time(:millisecond)

          CallSignaling.receive_message(pid, %{
            sender_aci: aci,
            sender_device_id: device,
            call_message: message,
            server_timestamp_ms: now,
            delivery_timestamp_ms: now
          })
      end
    end

    base = [
      aci: aci,
      device_id: device,
      identity_key: Map.fetch!(keys, aci),
      peer_identity_key: fn peer -> Map.fetch(keys, peer) end,
      send: send_fun,
      incoming_call: fn _info -> :ring end,
      admit: fn _info, _conn -> :ok end,
      media: [relay_only: false, ice_opts: [ip_filter: &ipv4?/1]]
    ]

    {:ok, pid} = start_supervised({CallSignaling, Keyword.merge(base, opts)}, id: aci)
    Agent.update(peers, &Map.put(&1, aci, pid))
    pid
  end

  # The production admission: a SalixVoice call with this connection as its
  # carrier socket.
  defp admit_voice_call(info, connection) do
    SalixSignal.Carrier.admit(connection, %{
      tenant_id: "ten_1",
      group_id: "grp_" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
      connect_id: "conn_signal",
      caller_aci: info.peer_aci,
      signal_call_id: info.call_id
    })
  end

  defp eventually(fun, tries \\ 1500) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_ip), do: false
end
