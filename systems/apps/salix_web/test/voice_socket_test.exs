defmodule SalixWeb.VoiceSocketTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The `comma.voice.v1` WebSocket voice API end to end (docs/messaging-voice.md):
  a voice agent key opens a session on the real listener, audio flows both
  ways through a fake GPT-Live model, a delegation reaches the Router ingress
  with voice metadata, and the Router's `voice.say` reaches the model and the
  client. Key, busy and limit failures close with their documented codes.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixVoice"]
  import ExUnit.CaptureLog

  alias SalixIM.Provider
  alias SalixVoice.Model.Fake
  alias SalixWeb.VoiceWsClient

  setup do
    keys = [
      {:salix_web, :api_token},
      {:salix_web, :voice_socket_timers},
      {:salix_voice, :model_mod},
      {:salix_voice, :fake_model_observer},
      {:salix_voice, :metering_mod},
      {:salix_voice, :ingress_mod},
      {:salix_voice, :test_pid},
      {:salix_voice, :timers}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_web, :api_token, "test-token")
    SystemsRuntime.put_env(:salix_voice, :model_mod, Fake)
    SystemsRuntime.put_env(:salix_voice, :fake_model_observer, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_voice, :metering_mod, nil)
    SystemsRuntime.put_env(:salix_voice, :ingress_mod, SalixVoice.TestStubs.Ingress)
    SystemsRuntime.put_env(:salix_voice, :test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_voice, :timers, notice_max_ms: 200, quiet_ms: 100)

    SalixStore.S3.Fake.reset()
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    Comma.PodLifecycle.reset_for_test()
    SalixCluster.NodeLifecycle.reset()

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end

      for pid <- :pg.get_local_members(SalixVoice.PG, :calls),
          do: DynamicSupervisor.terminate_child(SalixVoice.CallSupervisor, pid)
    end)

    {:ok, _} = SalixVoice.Settings.update(%{"enabled" => true, "openai_api_key" => "sk-test"})

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "Voice WS"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body["key"]

    group = req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Voice"}).body
    group_id = group["group_id"]

    router =
      req_as(tenant_key, :post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Router", role: "router"}
      ).body

    assert req_as(tenant_key, :patch, "/v1/runtime/agent-groups/#{group_id}",
             json: %{router_agent_id: router["agent_id"]}
           ).status == 200

    minted =
      req_as(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/voice/api-keys",
        json: %{name: "comma-voice"}
      )

    assert minted.status == 201

    {:ok,
     tenant_id: tenant_id,
     tenant_key: tenant_key,
     group_id: group_id,
     router_id: router["agent_id"],
     key: minted.body["key"],
     key_id: minted.body["key_id"]}
  end

  defp sessions_url(group_id) do
    SalixWeb.TwilioWebhook.ws_url(SalixWeb.Application.base_url()) <>
      "/v1/agent-groups/#{group_id}/voice/sessions"
  end

  defp open(ctx, key \\ nil, opts \\ []) do
    headers = [
      {"authorization", "Bearer " <> (key || ctx.key)},
      {"sec-websocket-protocol", "comma.voice.v1"}
    ]

    VoiceWsClient.start(
      sessions_url(ctx.group_id),
      SystemsRuntime.Proc.self(),
      [headers: headers] ++ opts
    )
  end

  defp start_session(client, format \\ "pcmu_8k") do
    VoiceWsClient.send_json(client, %{
      "type" => "session.start",
      "audio_format" => format,
      "client" => "comma-voice/test",
      "display_name" => "Ada"
    })

    settle_receive({:ws, ^client, {:json, %{"type" => "session.started"} = started}})
    settle_receive({:fake_model, model, {:started, _opts}})
    Fake.emit(model, {:started, "sess_ws"})
    # The call has seen the model start before the test acts on it: the
    # fake forwards the cast, then the call handles it.
    %{opts: %{owner: call}} = :sys.get_state(model, :infinity)
    _ = :sys.get_state(call, :infinity)
    # Both ends are ready, so the call asks the model to greet the caller.
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _greeting}})
    {started, model}
  end

  test "a session carries audio, delegation and the Router's spoken reply", ctx do
    ready = req_as(ctx.key, :get, "/v1/agent-groups/#{ctx.group_id}/voice")
    assert ready.status == 200
    assert ready.body["ready"] == true

    {:ok, client} = open(ctx, nil, auto_played: true)
    {started, model} = start_session(client)
    call_id = started["call_id"]
    assert "vc_" <> _ = call_id
    assert started["audio_format"] == "pcmu_8k"
    assert started["max_duration_s"] == 1800

    # last_used_at records the session start.
    assert {:ok, [%{"last_used_at" => used}]} =
             Salix.Control.GroupApiKeys.list(ctx.group_id, ctx.tenant_id, "voice")

    assert is_integer(used)

    caller_audio = :binary.copy(<<0x7F>>, 160)
    VoiceWsClient.send_binary(client, caller_audio)
    settle_receive({:fake_model, ^model, {:audio, ^caller_audio}})
    agent_audio = :binary.copy(<<0x55>>, 800)
    Fake.emit(model, {:audio, agent_audio})
    settle_receive({:ws, ^client, {:binary, ^agent_audio}})
    settle_receive({:ws, ^client, {:json, %{"type" => "output.mark", "name" => "pace:" <> _}}})
    Fake.emit(model, {:input_transcript, "What is the weather in Paris?", true, 1_200})

    settle_receive(
      {:ws, ^client,
       {:json,
        %{
          "type" => "transcript",
          "role" => "caller",
          "text" => "What is the weather in Paris?",
          "final" => true
        }}}
    )

    Fake.emit(model, {:delegation, "dlg_1", 1_500})

    settle_receive(
      {:ingress, group_id, content, %{"event_type" => "voice.delegation"} = metadata, source_id,
       opts}
    )

    assert group_id == ctx.group_id
    assert content =~ "What is the weather in Paris?"
    assert opts[:trusted_source_text] == "What is the weather in Paris?"

    connect_id = metadata["connect_id"]

    key_id = ctx.key_id

    # A WebSocket caller is the key: the Router input carries its principal,
    # so the caller acts with the key creator's authority.
    assert %{
             "provider" => "voice",
             "chat_id" => ^call_id,
             "message_id" => "dlg_1",
             "event_type" => "voice.delegation",
             "from_username" => "Ada",
             "api_key_id" => ^key_id,
             "api_key_name" => "comma-voice",
             "api_key_principal" => "api_key|" <> _
           } = metadata

    assert metadata["from_user_id"] =~ key_id
    assert source_id == "im_provider:voice:#{connect_id}:#{call_id}:dlg_1"

    assert {:ok, %{"delivered" => true}} =
             Provider.call_api(ctx.router_id, "voice", "voice.say", %{
               "connect_id" => connect_id,
               "params" => %{
                 "text" => "It is sunny in Paris.",
                 "call_id" => call_id,
                 "delegation_id" => "dlg_1"
               }
             })

    settle_receive(
      {:fake_model, ^model, {:append, :commentary, "dlg_1", "It is sunny in Paris."}}
    )

    Fake.emit(model, {:output_transcript, "It is sunny in Paris.", true})
    reply_audio = :binary.copy(<<0x33>>, 400)
    Fake.emit(model, {:audio, reply_audio})

    settle_receive(
      {:ws, ^client,
       {:json,
        %{
          "type" => "transcript",
          "role" => "agent",
          "text" => "It is sunny in Paris."
        }}}
    )

    settle_receive({:ws, ^client, {:binary, ^reply_audio}})
    # Barge-in clears queued playback.
    Fake.emit(model, :speech_started)
    settle_receive({:ws, ^client, {:json, %{"type" => "output.clear"}}})
    VoiceWsClient.send_json(client, %{"type" => "session.end"})

    settle_receive(
      {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "caller_hangup"}}}
    )

    settle_receive({:ws_closed, ^client, {1000, _}})
    settle_receive({:fake_model, ^model, :close})
  end

  test "the Router hears the call start, speaks before the caller, and hears the end", ctx do
    {:ok, client} = open(ctx, nil, auto_played: true)
    {started, model} = start_session(client)
    call_id = started["call_id"]

    settle_receive(
      {:ingress, group_id, _content,
       %{"event_type" => "voice.call_started", "chat_id" => ^call_id} = metadata, source_id,
       _opts}
    )

    assert group_id == ctx.group_id
    assert source_id == "im_provider:voice:#{metadata["connect_id"]}:#{call_id}:start"

    # The Router answers the call-start source; no delegation exists yet.
    assert {:ok, %{"delivered" => true, "call_id" => ^call_id}} =
             Provider.call_api(ctx.router_id, "voice", "voice.say", %{
               "connect_id" => metadata["connect_id"],
               "params" => %{"text" => "Your report is ready."},
               "tool_context" => %{
                 "trusted_origin" => %{
                   "provider" => "voice",
                   "source_actor_type" => metadata["source_actor_type"],
                   "provider_context" => Map.take(metadata, ~w(connect_id chat_id from_user_id))
                 }
               }
             })

    settle_receive({:fake_model, ^model, {:append, :commentary, nil, "Your report is ready."}})
    VoiceWsClient.send_json(client, %{"type" => "session.end"})
    settle_receive({:ws_closed, ^client, {1000, _}})

    settle_receive(
      {:ingress, _, content, %{"event_type" => "voice.call_ended", "chat_id" => ^call_id},
       end_source_id, _opts}
    )

    assert end_source_id == "im_provider:voice:#{metadata["connect_id"]}:#{call_id}:end"
    assert content =~ "reason caller_hangup"
  end

  test "an inbound key cannot open a session; a missing subprotocol is refused", ctx do
    inbound =
      req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups/#{ctx.group_id}/router/api-keys",
        json: %{name: "Zendesk"}
      ).body["key"]

    assert {:error, %WebSockex.RequestError{code: 401}} = open(ctx, inbound)

    assert {:error, %WebSockex.RequestError{code: 400}} =
             VoiceWsClient.start(sessions_url(ctx.group_id), SystemsRuntime.Proc.self(),
               headers: [{"authorization", "Bearer " <> ctx.key}]
             )
  end

  test "a second session of the Group closes with 4409", ctx do
    {:ok, first} = open(ctx)
    {_started, _model} = start_session(first)

    {:ok, second} = open(ctx)

    VoiceWsClient.send_json(second, %{
      "type" => "session.start",
      "audio_format" => "pcm16_24k",
      "client" => "comma-voice/test"
    })

    settle_receive({:ws, ^second, {:json, %{"type" => "error", "code" => 4409}}})
    settle_receive({:ws_closed, ^second, {4409, _}})
    refute_received {:ws_closed, ^first, _}
  end

  test "disabling the key mid-session ends it with 4401", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    assert req_as(
             ctx.tenant_key,
             :patch,
             "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys/#{ctx.key_id}",
             json: %{status: "disabled"}
           ).status == 200

    # The call asks the model to tell the caller, then ends.
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, notice}})
    assert notice =~ "revoked"

    settle_receive({:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}})
    settle_receive({:ws_closed, ^client, {4401, _}})
  end

  test "a new key expiry reaches a live session; the key expiring ends it with 4401", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    # The nearest whole second at least 300 ms away keeps the wait short.
    expires_at = div(SystemsClock.system_time(:millisecond) + 1_300, 1_000)

    assert req_as(
             ctx.tenant_key,
             :patch,
             "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys/#{ctx.key_id}",
             json: %{expires_at: expires_at}
           ).status == 200

    refute_received {:ws_closed, ^client, _}
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, notice}})
    assert notice =~ "revoked"

    settle_receive({:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}})
    settle_receive({:ws_closed, ^client, {4401, _}})
  end

  test "a key disabled after the upgrade cannot start a session", ctx do
    {:ok, client} = open(ctx)

    assert req_as(
             ctx.tenant_key,
             :patch,
             "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys/#{ctx.key_id}",
             json: %{status: "disabled"}
           ).status == 200

    group = {:group_call, ctx.group_id}
    {monitor, []} = :pg.monitor(SalixVoice.PG, group)
    on_exit(fn -> :pg.demonitor(SalixVoice.PG, monitor) end)

    VoiceWsClient.send_json(client, %{
      "type" => "session.start",
      "audio_format" => "pcmu_8k",
      "client" => "comma-voice/test"
    })

    settle_receive({:ws, ^client, {:json, %{"type" => "error", "code" => 4401}}})
    settle_receive({:ws_closed, ^client, {4401, _}})
    settle_receive({^monitor, :join, ^group, [call]})
    settle_receive({^monitor, :leave, ^group, [^call]})
    refute SalixVoice.group_busy?(ctx.group_id)
  end

  test "deleting the Group ends a live session with 4401", ctx do
    # A Group with agents cannot be deleted, so this one has none.
    group = req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Bare"}).body

    key =
      req_as(
        ctx.tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group["group_id"]}/voice/api-keys",
        json: %{name: "bare"}
      ).body[
        "key"
      ]

    ctx = %{ctx | group_id: group["group_id"], key: key}
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    assert :ok = Salix.Control.Groups.delete(ctx.group_id, ctx.tenant_id)

    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})
    settle_receive({:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}})
    settle_receive({:ws_closed, ^client, {4401, _}})
  end

  test "a node drain ends the session with a notice and close 4503", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    log =
      capture_log(fn ->
        assert :ok = SalixVoice.Drain.drain()
        settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})

        settle_receive(
          {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "draining"}}}
        )

        settle_receive({:ws_closed, ^client, {4503, _}})
      end)

    assert log =~
             ~r/voice session ended call=vc_\S+ pod=\S+ app_revision=\S+ reason=draining code=4503/
  end

  test "a call that dies closes with 4503 and logs only its exit class", ctx do
    {:ok, client} = open(ctx)
    {_started, _model} = start_session(client)
    [call] = :pg.get_local_members(SalixVoice.PG, :calls)

    log =
      capture_log(fn ->
        SystemsRuntime.Proc.exit(call, :kill)
        settle_receive({:ws, ^client, {:json, %{"type" => "error", "code" => 4503}}})
        settle_receive({:ws_closed, ^client, {4503, _}})
      end)

    assert log =~ ~r/voice call exited call=vc_\S+ pod=\S+ app_revision=\S+ exit=killed/
    assert log =~ ~r/voice socket closed call=vc_\S+ .* reason=unavailable code=4503/
  end

  test "bad frames and a missing session.start close with their codes", ctx do
    SystemsRuntime.put_env(:salix_web, :voice_socket_timers, start_timeout_ms: 200)

    {:ok, silent} = open(ctx)
    settle_receive({:ws, ^silent, {:json, %{"type" => "error", "code" => 4408}}})
    settle_receive({:ws_closed, ^silent, {4408, _}})
    {:ok, early} = open(ctx)
    VoiceWsClient.send_binary(early, <<0, 0>>)
    settle_receive({:ws, ^early, {:json, %{"type" => "error", "code" => 4400}}})
    settle_receive({:ws_closed, ^early, {4400, _}})
  end

  test "a frame over 16 KB closes with 4400", ctx do
    {:ok, text} = open(ctx)

    VoiceWsClient.send_json(text, %{
      "type" => "session.start",
      "audio_format" => "pcmu_8k",
      "client" => String.duplicate("c", 17_000)
    })

    settle_receive({:ws, ^text, {:json, %{"type" => "error", "code" => 4400}}})
    settle_receive({:ws_closed, ^text, {4400, _}})
    {:ok, audio} = open(ctx)
    {_started, _model} = start_session(audio)
    VoiceWsClient.send_binary(audio, :binary.copy(<<0x7F>>, 16 * 1024 + 1))
    settle_receive({:ws, ^audio, {:json, %{"type" => "error", "code" => 4400}}})
    settle_receive({:ws_closed, ^audio, {4400, _}})
  end

  test "caller audio faster than real time closes with 4400", ctx do
    {:ok, client} = open(ctx)
    {_started, _model} = start_session(client)

    # 8 kHz mu-law: the catch-up burst is 5 s, 40,000 bytes; the third 2 s
    # frame exceeds it. No frame follows, so the close is not reset by
    # unread client data.
    for _ <- 1..3, do: VoiceWsClient.send_binary(client, :binary.copy(<<0x7F>>, 16_000))

    settle_receive({:ws, ^client, {:json, %{"type" => "error", "code" => 4400}}})
    settle_receive({:ws_closed, ^client, {4400, _}})
  end

  test "a client that stops reading agent audio closes with 4410", ctx do
    # The default is 8 s; a shorter configured threshold keeps the test quick.
    SystemsRuntime.put_env(:salix_web, :voice_socket_timers, slow_reader_ms: 200)
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    # Ten seconds of agent audio; the client confirms only the first mark.
    log =
      capture_log(fn ->
        Fake.emit(model, {:audio, :binary.copy(<<0x55>>, 80_000)})
        settle_receive({:ws, ^client, {:json, %{"type" => "output.mark", "name" => first}}})
        VoiceWsClient.send_json(client, %{"type" => "output.played", "name" => first})
        settle_receive({:ws, ^client, {:json, %{"type" => "error", "code" => 4410}}})
        settle_receive({:ws_closed, ^client, {4410, _}})
      end)

    assert log =~
             ~r/voice slow reader call=vc_\S+ pod=\S+ app_revision=\S+ cause=mark_overdue slow_reader_ms=200 /

    assert [_, overdue] =
             Regex.run(~r/ oldest_mark=pace:2 oldest_deadline_ms=\d+ overdue_ms=(\d+) /, log)

    assert String.to_integer(overdue) > 200
    assert log =~ ~r/ last_played=pace:1@\d+ trail=m1@\d+\/d\d+\+\d+ /
    assert log =~ ~r/ p1@\d+ /
    assert log =~ ~r/voice socket closed call=vc_\S+ .* reason=slow_reader code=4410/
  end

  alias SalixWeb.VoiceHTTPClient, as: HTTP

  defp open_http(ctx, opts \\ []) do
    url = SalixWeb.Application.base_url() <> "/v1/agent-groups/#{ctx.group_id}/voice/http"
    {:ok, client} = HTTP.start(url, SystemsRuntime.Proc.self(), ctx.key, opts)
    settle_receive({:http, ^client, {:ready, _}})
    client
  end

  defp start_http(ctx, opts \\ []) do
    client = open_http(ctx, opts)

    assert HTTP.upload(
             client,
             HTTP.json(%{type: "session.start", audio_format: "pcm16_24k", client: "watch/test"})
           ).status == 204

    settle_receive(
      {:http, ^client, {:json, %{"type" => "session.started", "call_id" => call_id}}}
    )

    settle_receive({:fake_model, model, {:started, _}})
    Fake.emit(model, {:started, "http_test"})
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _}})
    {client, model, call_id}
  end

  test "HTTPS carries duplex audio, barge-in, playback receipts and hangup", ctx do
    {client, model, call_id} = start_http(ctx)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client) end)
    audio = :binary.copy(<<1, 0>>, 480)
    assert HTTP.upload(client, HTTP.audio(audio)).status == 204
    settle_receive({:fake_model, ^model, {:audio, ^audio}})
    Fake.emit(model, {:audio, audio})
    settle_receive({:http, ^client, {:binary, ^audio}})
    settle_receive({:http, ^client, {:json, %{"type" => "output.mark", "name" => mark}}})
    assert HTTP.upload(client, HTTP.json(%{type: "output.played", name: mark})).status == 204
    Fake.emit(model, :speech_started)
    settle_receive({:http, ^client, {:json, %{"type" => "output.clear"}}})
    assert HTTP.upload(client, HTTP.json(%{type: "session.end"})).status == 204
    settle_receive({:http, ^client, {:json, %{"type" => "session.ended"}}})
    settle_receive({:http_closed, ^client})
    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
    assert settle_until(fn -> not SalixVoice.group_busy?(ctx.group_id) end)
  end

  test "HTTPS audio uploads keep a call alive across repeated heartbeat windows", ctx do
    {client, model, call_id} = start_http(ctx)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client) end)
    audio = <<0, 0>>

    for _ <- 1..6 do
      assert HTTP.upload(client, HTTP.audio(audio)).status == 204
      settle_receive({:fake_model, ^model, {:audio, ^audio}})
      SystemsClock.run_for(15_000)
      settle_receive({:http, ^client, :heartbeat})
      assert SalixVoice.whereis(call_id) != nil
    end

    assert HTTP.upload(client, HTTP.json(%{type: "session.end"})).status == 204
    settle_receive({:http_closed, ^client})
    assert settle_until(fn -> not SalixVoice.group_busy?(ctx.group_id) end)
  end

  test "HTTPS rejects another key, stale sequence and unknown owner without duplicating audio",
       ctx do
    {client, model, _} = start_http(ctx)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client) end)

    minted =
      req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys",
        json: %{name: "other"}
      )

    audio = HTTP.audio(<<1, 0>>)
    assert HTTP.upload(client, audio, key: minted.body["key"]).status == 404
    assert HTTP.upload(client, audio, sequence: 0).status == 409
    assert HTTP.upload(client, audio, node: "absent@node").status == 503
    assert HTTP.upload(client, audio).status == 204
    settle_receive({:fake_model, ^model, {:audio, <<1, 0>>}})
    assert HTTP.upload(client, audio, sequence: 1).status == 409
    assert HTTP.upload(client, <<2, 0, 1, 0, 0>>).status == 400
    assert HTTP.upload(client, "", method: :delete).status == 204
    settle_receive({:http_closed, ^client})
  end

  test "HTTPS disconnect releases the Group and revoked keys end the call", ctx do
    {client, _, call_id} = start_http(ctx)
    HTTP.close(client)
    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
    assert settle_until(fn -> not SalixVoice.group_busy?(ctx.group_id) end)
    {client, _, call_id} = start_http(ctx)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client) end)

    assert req_as(
             ctx.tenant_key,
             :delete,
             "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys/#{ctx.key_id}"
           ).status == 200

    settle_receive({:http, ^client, {:closed, %{"code" => 4401}}})
    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
  end

  test "HTTPS continuation authenticates the original connection without database reads", ctx do
    {client, model, _} = start_http(ctx)
    id = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        id,
        [:salix_store, :repo, :query],
        fn _, _, meta, owner ->
          if String.contains?(meta.query, "agent_group_api_keys"),
            do: SystemsRuntime.Proc.send(owner, :voice_key_query)
        end,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(id) end)
    assert HTTP.upload(client, HTTP.audio(<<42, 0>>)).status == 204
    settle_receive({:fake_model, ^model, {:audio, <<42, 0>>}})
    settle_refute_receive(:voice_key_query)
    assert HTTP.upload(client, "", method: :delete).status == 204
    HTTP.close(client)
  end

  test "HTTPS drain ends the original call and refuses new admission", ctx do
    {client, model, call_id} = start_http(ctx)
    on_exit(fn -> if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client) end)

    log =
      capture_log(fn ->
        assert :ok = SalixVoice.Drain.drain()
        settle_receive({:fake_model, ^model, {:append, :instructions, nil, _}})
        settle_receive({:http, ^client, {:closed, %{"code" => 4503}}})
        assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
      end)

    assert log =~ ~r/voice session ended call=#{call_id} .* reason=draining .* transport=https/
  end

  @tag :multinode
  test "a different node forwards HTTPS uploads to the original carrier", ctx do
    assert Node.alive?(), "run with elixir --sname watch_http -S mix test --include multinode"
    {client, model, call_id} = start_http(ctx)
    ready = :sys.get_state(client).ready

    [_, host] = String.split(Atom.to_string(node()), "@")

    {:ok, peer, peer_node} =
      :peer.start_link(%{
        name: :"voice_http_peer_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        host: String.to_charlist(host),
        longnames: String.contains?(host, "."),
        connection: :standard_io,
        args: [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end

      if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client)
    end)

    true = Node.connect(peer_node)
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    scope = {ctx.group_id, :crypto.hash(:sha256, ctx.key) |> Base.encode16(case: :lower)}
    frames = [{<<42, 0>>, [opcode: :binary]}]
    args = [ready["node"], ready["handle"], scope, {:upload, 1, frames}]
    assert :ok = :erpc.call(peer_node, SalixWeb.VoiceHTTP, :dispatch, args)
    settle_receive({:fake_model, ^model, {:audio, <<42, 0>>}})
    assert {:error, 409} = :erpc.call(peer_node, SalixWeb.VoiceHTTP, :dispatch, args)

    assert {:error, 404} =
             :erpc.call(peer_node, SalixWeb.VoiceHTTP, :dispatch, [
               ready["node"],
               ready["handle"],
               {"other_group", elem(scope, 1)},
               :close
             ])

    assert :ok =
             :erpc.call(peer_node, SalixWeb.VoiceHTTP, :dispatch, [
               ready["node"],
               ready["handle"],
               scope,
               :close
             ])

    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
  end

  test "an upload timeout cannot unlock a still pending batch", ctx do
    {client, model, _} = start_http(ctx)
    ready = :sys.get_state(client).ready
    [{owner, {_scope, gate}}] = Registry.lookup(SalixWeb.VoiceHTTP.Registry, ready["handle"])
    scope = {ctx.group_id, :crypto.hash(:sha256, ctx.key) |> Base.encode16(case: :lower)}
    true = :erlang.suspend_process(owner)

    try do
      task =
        SystemsRuntime.Task.async(fn ->
          SalixWeb.VoiceHTTP.dispatch(
            ready["node"],
            ready["handle"],
            scope,
            {:upload, 1, [{<<42, 0>>, [opcode: :binary]}]}
          )
        end)

      assert settle_until(fn -> :atomics.get(gate, 1) == 1 end)

      assert {:error, 409} =
               SalixWeb.VoiceHTTP.dispatch(
                 ready["node"],
                 ready["handle"],
                 scope,
                 {:upload, 2, [{<<43, 0>>, [opcode: :binary]}]}
               )

      assert {:error, 503} = settled_await(task)
      assert :atomics.get(gate, 1) == 1
    after
      :erlang.resume_process(owner)
    end

    settle_receive({:fake_model, ^model, {:audio, <<42, 0>>}})
    assert :ok = SalixWeb.VoiceHTTP.dispatch(ready["node"], ready["handle"], scope, :close)
    HTTP.close(client)
  end

  test "a hang-up ends the call while an upload holds the gate", ctx do
    {client, _, call_id} = start_http(ctx)
    ready = :sys.get_state(client).ready
    refute ready["node"] =~ "@"
    [{_, {_scope, gate}}] = Registry.lookup(SalixWeb.VoiceHTTP.Registry, ready["handle"])
    :atomics.put(gate, 1, 1)
    assert HTTP.upload(client, "", method: :delete).status == 204
    settle_receive({:http_closed, ^client})
    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
  end

  test "a draining pod still forwards uploads and hang-ups of an open call", ctx do
    {client, model, call_id} = start_http(ctx)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(client), do: HTTP.close(client)
      # Drain state is node-global; later modules must not see this pod draining.
      Comma.PodLifecycle.reset_for_test()
      SalixCluster.NodeLifecycle.reset()
    end)

    Comma.PodLifecycle.begin_drain()

    assert req_as(ctx.key, :get, "/v1/agent-groups/#{ctx.group_id}/voice").status == 503
    assert HTTP.upload(client, HTTP.audio(<<1, 0>>)).status == 204
    settle_receive({:fake_model, ^model, {:audio, <<1, 0>>}})
    assert HTTP.upload(client, "", method: :delete).status == 204
    settle_receive({:http_closed, ^client})
    assert settle_until(fn -> SalixVoice.whereis(call_id) == nil end)
  end

  @tag :voice_swift_http
  test "the shipping Swift HTTPS client speaks to the Salix listener", ctx do
    # The external Swift process uses real Foundation timers.
    SystemsClock.reset()
    package = Path.expand("../../../../clients/packages/apple-core", __DIR__)
    url = SalixWeb.Application.base_url() <> "/v1/agent-groups/#{ctx.group_id}/voice"

    task =
      SystemsRuntime.Task.async(fn ->
        System.cmd(
          "swift",
          ["test", "--package-path", package, "--filter", "HTTPVoiceIntegrationTests"],
          env: [
            {"COMMA_VOICE_HTTP_TEST_URL", url},
            {"COMMA_VOICE_HTTP_TEST_KEY", ctx.key}
          ],
          stderr_to_stdout: true
        )
      end)

    model =
      SystemsRuntime.Proc.receive do
        {:fake_model, model, {:started, _}} -> model
      end

    Fake.emit(model, {:started, "swift_http"})

    SystemsRuntime.Proc.receive do
      {:fake_model, ^model, {:append, :instructions, nil, _}} -> :ok
    end

    Fake.emit(model, {:audio, <<1, 0>>})
    Fake.emit(model, {:input_transcript, "first", true, 50})
    microphone = :binary.copy(<<42>>, 960)

    SystemsRuntime.Proc.receive do
      {:fake_model, ^model, {:audio, ^microphone}} -> :ok
    end

    Fake.emit(model, :speech_started)
    Fake.emit(model, {:audio, <<2, 0>>})
    Fake.emit(model, {:input_transcript, "done", true, 100})
    ref = task.ref

    SystemsRuntime.Proc.receive do
      {^ref, {output, status}} ->
        SystemsRuntime.Proc.demonitor(ref, [:flush])
        assert status == 0, output
    end

    SystemsRuntime.Proc.receive do
      {:fake_model, ^model, :close} -> :ok
    end
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
