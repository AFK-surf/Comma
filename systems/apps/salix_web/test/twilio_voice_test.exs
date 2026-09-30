defmodule SalixWeb.TwilioVoiceTest do
  @moduledoc """
  Twilio voice (docs/messaging-voice.md): signed webhooks admit a verified
  caller, the media stream socket carries the call to a fake GPT-Live model,
  and the control routes verify caller numbers through Twilio Verify.
  """
  use ExUnit.Case, async: false

  alias SalixIM.ProviderConnects
  alias SalixVoice.Carrier.Twilio
  alias SalixVoice.Model.Fake
  alias SalixWeb.VoiceWsClient

  @public "https://voice.example.test"
  @token "twilio-auth-token"
  @line "+15550001111"
  @caller "+15551234567"

  defmodule TwilioStub do
    @moduledoc false
    # Twilio REST stand-in: reports each request and answers from the script
    # in `:twilio_stub_replies` (path suffix => {status, body}).
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      params = URI.decode_query(body)

      send(
        Application.fetch_env!(:salix_web, :twilio_stub_pid),
        {:twilio, conn.request_path, params}
      )

      {status, reply} =
        Application.get_env(:salix_web, :twilio_stub_replies, %{})
        |> Enum.find_value({200, %{"status" => "pending"}}, fn {suffix, reply} ->
          if String.ends_with?(conn.request_path, suffix), do: reply
        end)

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(reply))
    end
  end

  setup do
    prev =
      for {app, key} <- env_keys(), into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:salix_web, :api_token, "test-token")
    Application.put_env(:salix_voice, :model_mod, Fake)
    Application.put_env(:salix_voice, :fake_model_observer, self())
    Application.put_env(:salix_voice, :metering_mod, nil)
    Application.put_env(:salix_voice, :ingress_mod, SalixVoice.TestStubs.Ingress)
    Application.put_env(:salix_voice, :test_pid, self())
    Application.put_env(:salix_web, :twilio_stub_pid, self())
    Application.delete_env(:salix_web, :twilio_stub_replies)
    # The fixed test caller number would otherwise exhaust its Redis bucket
    # across repeated runs.
    Application.put_env(:salix_web, :voice_verify_rate_limits, number_per_hour: 1_000_000)

    stub = start_supervised!({Bandit, plug: TwilioStub, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(stub)
    Application.put_env(:salix_web, :twilio_api_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_web, :twilio_verify_base_url, "http://127.0.0.1:#{port}")

    SalixStore.S3.Fake.reset()
    Comma.PodLifecycle.reset_for_test()
    SalixCluster.NodeLifecycle.reset()

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      for pid <- :pg.get_local_members(SalixVoice.PG, :calls),
          do: DynamicSupervisor.terminate_child(SalixVoice.CallSupervisor, pid)
    end)

    {:ok, _} =
      SalixVoice.Settings.update(%{
        "enabled" => true,
        "openai_api_key" => "sk-test",
        "twilio_account_sid" => "AC123",
        "twilio_auth_token" => @token,
        "twilio_verify_service_sid" => "VA123",
        "twilio_numbers" => [@line],
        "public_base_url" => @public,
        "pin_max_failures" => 2
      })

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "Twilio"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body["key"]

    group = req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Phone"}).body

    {:ok, tenant_id: tenant_id, tenant_key: tenant_key, group_id: group["group_id"]}
  end

  defp env_keys do
    [
      {:salix_web, :api_token},
      {:salix_voice, :model_mod},
      {:salix_voice, :fake_model_observer},
      {:salix_voice, :metering_mod},
      {:salix_voice, :ingress_mod},
      {:salix_voice, :test_pid},
      {:salix_web, :twilio_stub_pid},
      {:salix_web, :twilio_stub_replies},
      {:salix_web, :twilio_api_base_url},
      {:salix_web, :twilio_verify_base_url},
      {:salix_web, :voice_verify_rate_limits},
      {:salix_web, :twilio_webhook_rate_limits}
    ]
  end

  defp bind_caller(ctx) do
    {:ok, _} =
      ProviderConnects.confirm_voice_number(ctx.tenant_id, ctx.group_id, "twilio", @line, @caller)

    :ok
  end

  defp call_params(overrides \\ %{}) do
    Map.merge(
      %{
        "AccountSid" => "AC123",
        "CallSid" => "CA" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        "From" => @caller,
        "To" => @line,
        "CallStatus" => "ringing",
        "Direction" => "inbound"
      },
      overrides
    )
  end

  defp twilio_post(path, params, opts \\ []) do
    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        Twilio.signature(@public <> path, params, @token)
      end)

    Req.post!(SalixWeb.Application.base_url() <> path,
      form: Enum.to_list(params),
      headers: [{"x-twilio-signature", signature}],
      retry: false
    )
  end

  test "one flooding source is rate limited without blocking other sources" do
    Application.put_env(:salix_web, :twilio_webhook_rate_limits, source_per_minute: 2)
    # Fresh addresses, so an earlier run's window does not count.
    address = fn -> {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)} end
    flood = address.()
    twilio = address.()

    admit = fn ip ->
      :post
      |> Plug.Test.conn("/v1/voice/twilio/incoming")
      |> Map.put(:remote_ip, ip)
      |> SalixWeb.TwilioWebhook.admit()
    end

    refute admit.(flood).halted
    refute admit.(flood).halted
    limited = admit.(flood)
    assert limited.halted and limited.status == 429
    assert Plug.Conn.get_resp_header(limited, "retry-after") != []

    refute admit.(twilio).halted
  end

  describe "incoming webhook" do
    test "a bad or missing signature gets 403 and no TwiML", ctx do
      bind_caller(ctx)
      params = call_params(%{"StirVerstat" => "TN-Validation-Passed-A"})

      assert twilio_post("/v1/voice/twilio/incoming", params, signature: "bogus").status == 403

      # A signature over another URL (not the configured public one) fails.
      wrong = Twilio.signature("http://127.0.0.1/v1/voice/twilio/incoming", params, @token)
      response = twilio_post("/v1/voice/twilio/incoming", params, signature: wrong)
      assert response.status == 403
      assert response.body == ""
      assert SalixVoice.local_call_count() == 0
    end

    test "an unregistered caller hears why and the call hangs up" do
      response = twilio_post("/v1/voice/twilio/incoming", call_params())
      assert response.status == 200
      assert response.body =~ "This number is not registered with Comma."
      assert response.body =~ "<Hangup/>"
      refute response.body =~ "<Stream"
    end

    test "a fully attested caller is connected to a media stream", ctx do
      bind_caller(ctx)
      params = call_params(%{"StirVerstat" => "TN-Validation-Passed-A"})

      response = twilio_post("/v1/voice/twilio/incoming", params)
      assert response.status == 200

      assert [_, token] =
               Regex.run(
                 ~r|<Stream url="wss://voice\.example\.test/v1/voice/twilio/stream/([^"]+)"|,
                 response.body
               )

      assert {:ok, claims} = SalixVoice.StreamToken.verify(token, System.system_time(:second))
      assert claims["group_id"] == ctx.group_id
      assert claims["carrier_call_id"] == params["CallSid"]
      assert_receive {:fake_model, _model, {:started, %{audio_format: :pcmu_8k}}}
    end

    test "an unattested caller enters a PIN; wrong PINs lock the number", ctx do
      bind_caller(ctx)

      {:ok, _} =
        ProviderConnects.set_voice_number_pin(ctx.tenant_id, ctx.group_id, @caller, "4321")

      params = call_params(%{"StirVerstat" => "TN-Validation-Passed-C"})
      response = twilio_post("/v1/voice/twilio/incoming", params)
      assert response.body =~ ~s(<Gather input="dtmf")
      assert response.body =~ ~s(action="#{@public}/v1/voice/twilio/pin")

      wrong = twilio_post("/v1/voice/twilio/pin", Map.put(params, "Digits", "1111"))
      assert wrong.body =~ "That PIN is not correct"
      assert wrong.body =~ "<Gather"

      # pin_max_failures is 2: the second failure locks the binding.
      locked = twilio_post("/v1/voice/twilio/pin", Map.put(params, "Digits", "2222"))
      assert locked.body =~ "locked"
      assert locked.body =~ "<Hangup/>"

      # Even the right PIN is refused while locked, and a new call hears the lock.
      assert twilio_post("/v1/voice/twilio/pin", Map.put(params, "Digits", "4321")).body =~
               "locked"

      assert twilio_post("/v1/voice/twilio/incoming", call_params()).body =~ "locked"
      assert SalixVoice.local_call_count() == 0

      # After the owner resets the PIN, the right PIN connects the call.
      {:ok, _} =
        ProviderConnects.set_voice_number_pin(ctx.tenant_id, ctx.group_id, @caller, "4321")

      ok = twilio_post("/v1/voice/twilio/pin", Map.put(call_params(), "Digits", "4321"))
      assert ok.body =~ "<Connect><Stream"
    end

    test "an unattested caller without a PIN is refused with a spoken reason", ctx do
      bind_caller(ctx)
      response = twilio_post("/v1/voice/twilio/incoming", call_params())
      assert response.body =~ "could not be verified"
      assert response.body =~ "<Hangup/>"
    end

    test "a second call to a busy Group hears that it is busy", ctx do
      bind_caller(ctx)
      attested = %{"StirVerstat" => "TN-Validation-Passed-A"}
      assert twilio_post("/v1/voice/twilio/incoming", call_params(attested)).body =~ "<Stream"
      busy = twilio_post("/v1/voice/twilio/incoming", call_params(attested))
      assert busy.body =~ "on another call"
    end

    # The Group is held by an admitted call until its media stream attaches.
    # A call that Twilio reports finished first, or a stream that closes
    # before its `start`, frees the Group at once instead of after the 20 s
    # attach timeout.
    test "a call that ends before its media stream attaches frees the Group", ctx do
      bind_caller(ctx)
      attested = %{"StirVerstat" => "TN-Validation-Passed-A"}

      first = call_params(attested)
      assert twilio_post("/v1/voice/twilio/incoming", first).body =~ "<Stream"
      assert SalixVoice.group_busy?(ctx.group_id)

      # A status for another call of the Group changes nothing.
      other = Map.merge(first, %{"CallSid" => "CAother", "CallStatus" => "completed"})
      assert twilio_post("/v1/voice/twilio/status", other).status == 204
      assert SalixVoice.group_busy?(ctx.group_id)

      done = Map.put(first, "CallStatus", "completed")
      assert twilio_post("/v1/voice/twilio/status", done).status == 204
      assert_group_free(ctx.group_id)

      second = call_params(attested)
      body = twilio_post("/v1/voice/twilio/incoming", second).body
      assert [_, token] = Regex.run(~r|/v1/voice/twilio/stream/([^"]+)"|, body)

      ws = SalixWeb.TwilioWebhook.ws_url(SalixWeb.Application.base_url())
      {:ok, client} = VoiceWsClient.start(ws <> "/v1/voice/twilio/stream/" <> token, self())
      VoiceWsClient.send_json(client, %{"event" => "connected", "protocol" => "Call"})
      VoiceWsClient.close(client)
      assert_group_free(ctx.group_id)

      assert twilio_post("/v1/voice/twilio/incoming", call_params(attested)).body =~ "<Stream"
    end
  end

  defp assert_group_free(group_id, attempts \\ 50) do
    cond do
      not SalixVoice.group_busy?(group_id) ->
        :ok

      attempts == 0 ->
        flunk("the Group is still busy")

      true ->
        Process.sleep(20)
        assert_group_free(group_id, attempts - 1)
    end
  end

  # A fully attested phone call with its media stream attached.
  defp live_phone_call(ctx, stream_sid) do
    bind_caller(ctx)
    params = call_params(%{"StirVerstat" => "TN-Validation-Passed-A"})
    body = twilio_post("/v1/voice/twilio/incoming", params).body
    [_, token] = Regex.run(~r|/v1/voice/twilio/stream/([^"]+)"|, body)
    assert_receive {:fake_model, model, {:started, _opts}}
    Fake.emit(model, {:started, "sess_" <> stream_sid})

    ws = SalixWeb.TwilioWebhook.ws_url(SalixWeb.Application.base_url())
    {:ok, client} = VoiceWsClient.start(ws <> "/v1/voice/twilio/stream/" <> token, self())

    VoiceWsClient.send_json(client, %{
      "event" => "start",
      "streamSid" => stream_sid,
      "start" => %{"streamSid" => stream_sid, "callSid" => params["CallSid"]}
    })

    call = :sys.get_state(model).opts.owner
    assert_attached(call)
    # Both ends are ready, so the call asks the model to greet the caller.
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, _greeting}}, 3_000
    {model, client, params["CallSid"]}
  end

  # The caller hears a short notice, the stream closes, and Salix ends the
  # phone call over the Calls API.
  defp assert_revoked_call_ends(ctx, model, client, call_sid) do
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, notice}}, 2_000
    assert notice =~ "revoked"
    assert_receive {:ws_closed, ^client, _close}, 8_000

    assert_receive {:twilio, "/2010-04-01/Accounts/AC123/Calls/" <> ^call_sid <> ".json",
                    %{"Status" => "completed"}},
                   3_000

    refute SalixVoice.group_busy?(ctx.group_id)
  end

  test "deleting the Group ends its live phone call", ctx do
    {model, client, call_sid} = live_phone_call(ctx, "MZdel")
    assert :ok = Salix.Control.Groups.delete(ctx.group_id, ctx.tenant_id)
    assert_revoked_call_ends(ctx, model, client, call_sid)
  end

  test "removing the caller number ends that number's live phone call", ctx do
    {model, client, call_sid} = live_phone_call(ctx, "MZrm")

    assert {:ok, %{"numbers" => []}} =
             Salix.Control.VoiceNumbers.remove_number(ctx.group_id, ctx.tenant_id, @caller)

    assert_revoked_call_ends(ctx, model, client, call_sid)
  end

  defp assert_attached(call, attempts \\ 50) do
    cond do
      is_pid(:sys.get_state(call).socket) ->
        :ok

      attempts == 0 ->
        flunk("the stream did not attach")

      true ->
        Process.sleep(20)
        assert_attached(call, attempts - 1)
    end
  end

  test "the media stream carries audio, barge-in and marks both ways", ctx do
    bind_caller(ctx)
    params = call_params(%{"StirVerstat" => "TN-Validation-Passed-A"})
    body = twilio_post("/v1/voice/twilio/incoming", params).body
    [_, token] = Regex.run(~r|/v1/voice/twilio/stream/([^"]+)"|, body)
    assert_receive {:fake_model, model, {:started, _opts}}
    Fake.emit(model, {:started, "sess_1"})

    # Another token is refused before the upgrade.
    assert Req.get!(
             SalixWeb.Application.base_url() <>
               "/v1/voice/twilio/stream/AAAAAAAAAAAAAAAAAAAA.BBBB",
             retry: false
           ).status == 404

    ws = SalixWeb.TwilioWebhook.ws_url(SalixWeb.Application.base_url())
    {:ok, client} = VoiceWsClient.start(ws <> "/v1/voice/twilio/stream/" <> token, self())
    stream_sid = "MZ0001"

    VoiceWsClient.send_json(client, %{
      "event" => "connected",
      "protocol" => "Call",
      "version" => "1.0.0"
    })

    VoiceWsClient.send_json(client, %{
      "event" => "start",
      "sequenceNumber" => "1",
      "streamSid" => stream_sid,
      "start" => %{
        "accountSid" => "AC123",
        "streamSid" => stream_sid,
        "callSid" => params["CallSid"],
        "tracks" => ["inbound"],
        "mediaFormat" => %{"encoding" => "audio/x-mulaw", "sampleRate" => 8000, "channels" => 1},
        "customParameters" => %{}
      }
    })

    caller_audio = :binary.copy(<<0x7F>>, 160)

    VoiceWsClient.send_json(client, %{
      "event" => "media",
      "sequenceNumber" => "2",
      "streamSid" => stream_sid,
      "media" => %{
        "track" => "inbound",
        "chunk" => "1",
        "timestamp" => "20",
        "payload" => Base.encode64(caller_audio)
      }
    })

    assert_receive {:fake_model, ^model, {:audio, ^caller_audio}}, 2_000

    agent_audio = :binary.copy(<<0x55>>, 320)
    Fake.emit(model, {:audio, agent_audio})

    assert_receive {:ws, ^client,
                    {:json, %{"event" => "media", "streamSid" => ^stream_sid} = media}},
                   2_000

    assert Base.decode64!(media["media"]["payload"]) == agent_audio

    Fake.emit(model, :speech_started)

    assert_receive {:ws, ^client, {:json, %{"event" => "clear", "streamSid" => ^stream_sid}}},
                   2_000

    # A call mark reaches Twilio, and Twilio's echo returns to the call.
    call = :sys.get_state(model).opts.owner
    socket = :sys.get_state(call).socket
    send(socket, {:voice_call, :mark, "greeting-done"})

    assert_receive {:ws, ^client,
                    {:json, %{"event" => "mark", "mark" => %{"name" => "greeting-done"}}}},
                   2_000

    :erlang.trace(call, true, [:receive])

    VoiceWsClient.send_json(client, %{
      "event" => "mark",
      "streamSid" => stream_sid,
      "mark" => %{"name" => "greeting-done"}
    })

    assert_receive {:trace, ^call, :receive, {:voice_carrier, :mark_played, "greeting-done"}},
                   2_000

    :erlang.trace(call, false, [:receive])

    # A second socket with the same token is refused: one socket per call.
    {:ok, replay} = VoiceWsClient.start(ws <> "/v1/voice/twilio/stream/" <> token, self())

    VoiceWsClient.send_json(replay, %{
      "event" => "start",
      "streamSid" => "MZ0002",
      "start" => %{"streamSid" => "MZ0002", "callSid" => params["CallSid"]}
    })

    assert_receive {:ws_closed, ^replay, {1008, _}}, 2_000

    VoiceWsClient.send_json(client, %{
      "event" => "stop",
      "streamSid" => stream_sid,
      "stop" => %{"callSid" => params["CallSid"]}
    })

    assert_receive {:fake_model, ^model, :close}, 2_000
    assert_receive {:ws_closed, ^client, _close}, 5_000
    # The caller hung up; Salix does not also end the call over REST.
    refute_received {:twilio, "/2010-04-01/" <> _, _}
  end

  describe "caller number control routes" do
    test "status, SMS verification, PIN and removal", ctx do
      base = "/v1/runtime/agent-groups/#{ctx.group_id}/im-connects/voice"

      status = req_as(ctx.tenant_key, :get, base)
      assert status.status == 200
      assert status.body["lines"] == [@line]
      assert status.body["numbers"] == []
      assert status.body["readiness"] == %{"ready" => true, "reason" => nil}

      assert status.body["urls"]["sessions_url"] ==
               "wss://voice.example.test/v1/agent-groups/#{ctx.group_id}/voice/sessions"

      started =
        req_as(ctx.tenant_key, :post, base <> "/numbers/verify-start", json: %{e164: @caller})

      assert started.status == 200
      assert started.body == %{"e164" => @caller, "line" => @line, "status" => "pending"}

      assert_receive {:twilio, "/v2/Services/VA123/Verifications",
                      %{"To" => @caller, "Channel" => "sms"}}

      Application.put_env(:salix_web, :twilio_stub_replies, %{
        "VerificationCheck" => {200, %{"status" => "pending"}}
      })

      wrong =
        req_as(ctx.tenant_key, :post, base <> "/numbers/verify-check",
          json: %{e164: @caller, code: "000000"}
        )

      assert wrong.status == 422

      Application.put_env(:salix_web, :twilio_stub_replies, %{
        "VerificationCheck" => {200, %{"status" => "approved"}}
      })

      checked =
        req_as(ctx.tenant_key, :post, base <> "/numbers/verify-check",
          json: %{e164: @caller, code: "123456"}
        )

      assert checked.status == 200

      assert [%{"e164" => @caller, "line" => @line, "pin_configured" => false}] =
               checked.body["numbers"]

      assert_receive {:twilio, "/v2/Services/VA123/VerificationCheck",
                      %{"To" => @caller, "Code" => "123456"}}

      # Another Group cannot bind the same caller on the same line.
      other =
        req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Other"}).body

      other_base = "/v1/runtime/agent-groups/#{other["group_id"]}/im-connects/voice"

      assert req_as(ctx.tenant_key, :post, other_base <> "/numbers/verify-start",
               json: %{e164: @caller}
             ).status ==
               409

      pinned = req_as(ctx.tenant_key, :put, base <> "/pin", json: %{e164: @caller, pin: "2468"})
      assert pinned.status == 200
      assert [%{"pin_configured" => true} = number] = pinned.body["numbers"]
      refute Map.has_key?(number, "pin_hash")

      assert req_as(ctx.tenant_key, :put, base <> "/pin", json: %{e164: @caller, pin: "12"}).status ==
               400

      removed =
        req_as(ctx.tenant_key, :delete, base <> "/numbers/" <> URI.encode_www_form(@caller))

      assert removed.status == 200
      assert removed.body["numbers"] == []
      assert twilio_post("/v1/voice/twilio/incoming", call_params()).body =~ "not registered"
    end

    test "verification is refused when Twilio Verify is not configured", ctx do
      {:ok, _} = SalixVoice.Settings.update(%{"twilio_verify_service_sid" => nil})
      base = "/v1/runtime/agent-groups/#{ctx.group_id}/im-connects/voice"

      assert req_as(ctx.tenant_key, :post, base <> "/numbers/verify-start",
               json: %{e164: @caller}
             ).status ==
               503

      assert req_as(ctx.tenant_key, :post, base <> "/numbers/verify-start",
               json: %{e164: "12345"}
             ).status ==
               400
    end
  end

  test "admin voice settings are write-only for secrets" do
    got = req(:get, "/v1/admin/voice/settings", [])
    assert got.status == 200
    assert got.body["twilio_auth_token_configured"] == true
    refute Map.has_key?(got.body, "twilio_auth_token")
    refute got.body |> Jason.encode!() |> String.contains?(@token)

    put =
      req(:put, "/v1/admin/voice/settings", json: %{max_call_seconds: 600, twilio_auth_token: ""})

    assert put.status == 200
    assert put.body["max_call_seconds"] == 600
    assert put.body["twilio_auth_token_configured"] == true
    assert req(:put, "/v1/admin/voice/settings", json: %{max_call_seconds: 1}).status == 400
  end

  defp req(method, path, opts), do: req_as("test-token", method, path, opts)

  defp req_as(token, method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: [{"authorization", "Bearer " <> token}],
        retry: false
      ] ++ opts
    )
  end
end
