defmodule SalixWeb.VoiceSocketTest do
  @moduledoc """
  The `comma.voice.v1` WebSocket voice API end to end (docs/messaging-voice.md):
  a voice agent key opens a session on the real listener, audio flows both
  ways through a fake GPT-Live model, a delegation reaches the Router ingress
  with voice metadata, and the Router's `voice.say` reaches the model and the
  client. Key, busy and limit failures close with their documented codes.
  """
  use ExUnit.Case, async: false

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

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:salix_web, :api_token, "test-token")
    Application.put_env(:salix_voice, :model_mod, Fake)
    Application.put_env(:salix_voice, :fake_model_observer, self())
    Application.put_env(:salix_voice, :metering_mod, nil)
    Application.put_env(:salix_voice, :ingress_mod, SalixVoice.TestStubs.Ingress)
    Application.put_env(:salix_voice, :test_pid, self())
    Application.put_env(:salix_voice, :timers, notice_max_ms: 200, quiet_ms: 100)

    SalixStore.S3.Fake.reset()
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
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

    VoiceWsClient.start(sessions_url(ctx.group_id), self(), [headers: headers] ++ opts)
  end

  defp start_session(client, format \\ "pcmu_8k") do
    VoiceWsClient.send_json(client, %{
      "type" => "session.start",
      "audio_format" => format,
      "client" => "comma-voice/test",
      "display_name" => "Ada"
    })

    assert_receive {:ws, ^client, {:json, %{"type" => "session.started"} = started}}, 3_000
    assert_receive {:fake_model, model, {:started, _opts}}, 3_000
    Fake.emit(model, {:started, "sess_ws"})
    # The call has seen the model start before the test acts on it: the
    # fake forwards the cast, then the call handles it.
    %{opts: %{owner: call}} = :sys.get_state(model)
    _ = :sys.get_state(call)
    # Both ends are ready, so the call asks the model to greet the caller.
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, _greeting}}, 3_000
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
    assert_receive {:fake_model, ^model, {:audio, ^caller_audio}}, 2_000

    agent_audio = :binary.copy(<<0x55>>, 800)
    Fake.emit(model, {:audio, agent_audio})
    assert_receive {:ws, ^client, {:binary, ^agent_audio}}, 2_000
    assert_receive {:ws, ^client, {:json, %{"type" => "output.mark", "name" => "pace:" <> _}}}

    Fake.emit(model, {:input_transcript, "What is the weather in Paris?", true, 1_200})

    assert_receive {:ws, ^client,
                    {:json,
                     %{
                       "type" => "transcript",
                       "role" => "caller",
                       "text" => "What is the weather in Paris?",
                       "final" => true
                     }}}

    Fake.emit(model, {:delegation, "dlg_1", 1_500})

    assert_receive {:ingress, group_id, content, %{"event_type" => "voice.delegation"} = metadata,
                    source_id, opts},
                   3_000

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

    assert_receive {:fake_model, ^model,
                    {:append, :commentary, "dlg_1", "It is sunny in Paris."}},
                   2_000

    Fake.emit(model, {:output_transcript, "It is sunny in Paris.", true})
    reply_audio = :binary.copy(<<0x33>>, 400)
    Fake.emit(model, {:audio, reply_audio})

    assert_receive {:ws, ^client,
                    {:json,
                     %{
                       "type" => "transcript",
                       "role" => "agent",
                       "text" => "It is sunny in Paris."
                     }}}

    assert_receive {:ws, ^client, {:binary, ^reply_audio}}, 2_000

    # Barge-in clears queued playback.
    Fake.emit(model, :speech_started)
    assert_receive {:ws, ^client, {:json, %{"type" => "output.clear"}}}

    VoiceWsClient.send_json(client, %{"type" => "session.end"})

    assert_receive {:ws, ^client,
                    {:json, %{"type" => "session.ended", "reason" => "caller_hangup"}}},
                   3_000

    assert_receive {:ws_closed, ^client, {1000, _}}, 3_000
    assert_receive {:fake_model, ^model, :close}
  end

  test "the Router hears the call start, speaks before the caller, and hears the end", ctx do
    {:ok, client} = open(ctx, nil, auto_played: true)
    {started, model} = start_session(client)
    call_id = started["call_id"]

    assert_receive {:ingress, group_id, _content,
                    %{"event_type" => "voice.call_started", "chat_id" => ^call_id} = metadata,
                    source_id, _opts},
                   3_000

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

    assert_receive {:fake_model, ^model, {:append, :commentary, nil, "Your report is ready."}},
                   2_000

    VoiceWsClient.send_json(client, %{"type" => "session.end"})
    assert_receive {:ws_closed, ^client, {1000, _}}, 3_000

    assert_receive {:ingress, _, content,
                    %{"event_type" => "voice.call_ended", "chat_id" => ^call_id}, end_source_id,
                    _opts},
                   3_000

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
             VoiceWsClient.start(sessions_url(ctx.group_id), self(),
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

    assert_receive {:ws, ^second, {:json, %{"type" => "error", "code" => 4409}}}, 3_000
    assert_receive {:ws_closed, ^second, {4409, _}}, 3_000
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
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, notice}}, 2_000
    assert notice =~ "revoked"

    assert_receive {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}},
                   3_000

    assert_receive {:ws_closed, ^client, {4401, _}}, 3_000
  end

  test "a new key expiry reaches a live session; the key expiring ends it with 4401", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    expires_at = System.system_time(:second) + 2

    assert req_as(
             ctx.tenant_key,
             :patch,
             "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys/#{ctx.key_id}",
             json: %{expires_at: expires_at}
           ).status == 200

    refute_receive {:ws_closed, ^client, _}, 500
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, notice}}, 4_000
    assert notice =~ "revoked"

    assert_receive {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}},
                   3_000

    assert_receive {:ws_closed, ^client, {4401, _}}, 3_000
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

    assert_receive {:ws, ^client, {:json, %{"type" => "error", "code" => 4401}}}, 3_000
    assert_receive {:ws_closed, ^client, {4401, _}}, 3_000
    assert_receive {^monitor, :join, ^group, [call]}, 3_000
    assert_receive {^monitor, :leave, ^group, [^call]}, 3_000
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

    assert_receive {:fake_model, ^model, {:append, :instructions, nil, _notice}}, 2_000

    assert_receive {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "revoked"}}},
                   3_000

    assert_receive {:ws_closed, ^client, {4401, _}}, 3_000
  end

  test "a node drain ends the session with a notice and close 4503", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    assert :ok = SalixVoice.Drain.drain()
    assert_receive {:fake_model, ^model, {:append, :instructions, nil, _notice}}

    assert_receive {:ws, ^client, {:json, %{"type" => "session.ended", "reason" => "draining"}}},
                   3_000

    assert_receive {:ws_closed, ^client, {4503, _}}, 3_000
  end

  test "bad frames and a missing session.start close with their codes", ctx do
    Application.put_env(:salix_web, :voice_socket_timers, start_timeout_ms: 200)

    {:ok, silent} = open(ctx)
    assert_receive {:ws, ^silent, {:json, %{"type" => "error", "code" => 4408}}}, 2_000
    assert_receive {:ws_closed, ^silent, {4408, _}}, 2_000

    {:ok, early} = open(ctx)
    VoiceWsClient.send_binary(early, <<0, 0>>)
    assert_receive {:ws, ^early, {:json, %{"type" => "error", "code" => 4400}}}, 2_000
    assert_receive {:ws_closed, ^early, {4400, _}}, 2_000
  end

  test "a frame over 16 KB closes with 4400", ctx do
    {:ok, text} = open(ctx)

    VoiceWsClient.send_json(text, %{
      "type" => "session.start",
      "audio_format" => "pcmu_8k",
      "client" => String.duplicate("c", 17_000)
    })

    assert_receive {:ws, ^text, {:json, %{"type" => "error", "code" => 4400}}}, 2_000
    assert_receive {:ws_closed, ^text, {4400, _}}, 2_000

    {:ok, audio} = open(ctx)
    {_started, _model} = start_session(audio)
    VoiceWsClient.send_binary(audio, :binary.copy(<<0x7F>>, 16 * 1024 + 1))
    assert_receive {:ws, ^audio, {:json, %{"type" => "error", "code" => 4400}}}, 2_000
    assert_receive {:ws_closed, ^audio, {4400, _}}, 2_000
  end

  test "caller audio faster than real time closes with 4400", ctx do
    {:ok, client} = open(ctx)
    {_started, _model} = start_session(client)

    # 8 kHz mu-law: 1.25x real time over 5 s is 50,000 bytes.
    for _ <- 1..4, do: VoiceWsClient.send_binary(client, :binary.copy(<<0x7F>>, 16_000))

    assert_receive {:ws, ^client, {:json, %{"type" => "error", "code" => 4400}}}, 3_000
    assert_receive {:ws_closed, ^client, {4400, _}}, 3_000
  end

  test "a client that stops reading agent audio closes with 4410", ctx do
    {:ok, client} = open(ctx)
    {_started, model} = start_session(client)

    # Ten seconds of agent audio; the client never answers output.played.
    Fake.emit(model, {:audio, :binary.copy(<<0x55>>, 80_000)})
    assert_receive {:ws, ^client, {:json, %{"type" => "error", "code" => 4410}}}, 6_000
    assert_receive {:ws_closed, ^client, {4410, _}}, 3_000
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
