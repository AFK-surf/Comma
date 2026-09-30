defmodule SalixIM.VoiceProviderTest do
  @moduledoc """
  The voice provider (`docs/messaging-voice.md`): Router operations reach the
  live call process through `:pg`, voice connects bind caller numbers under a
  global reservation, and caller PINs lock out after repeated failures.
  """
  use ExUnit.Case, async: false

  alias SalixIM.{AgentDeliveryPayload, Provider, ProviderConnects}
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @line "+15550001111"
  @caller "+15551234567"

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    unless Process.whereis(SalixVoice.PG) do
      start_supervised!(%{id: :voice_pg, start: {:pg, :start_link, [SalixVoice.PG]}})
    end

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    {group_id, router_id} = group_with_router(tenant)
    %{tenant: tenant, group_id: group_id, router_id: router_id}
  end

  defp group_with_router(tenant) do
    group_id = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group_id), %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group_id),
        &Map.put(&1, "router_agent_id", router["agent_id"])
      )

    {group_id, router["agent_id"]}
  end

  # A stand-in CallActor: joins the call's group and answers provider calls.
  defp fake_call(call_id, reply) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = :pg.join(SalixVoice.PG, {:call, call_id}, self())
        send(test, {:joined, self()})
        call_loop(test, reply)
      end)

    assert_receive {:joined, ^pid}
    pid
  end

  defp call_loop(test, reply) do
    receive do
      {:"$gen_call", from, message} ->
        send(test, {:call_received, message})
        GenServer.reply(from, reply)
        call_loop(test, reply)
    end
  end

  defp voice_origin(connect_id, call_id, delegation_id) do
    %{
      "provider" => "voice",
      "source_actor_type" => "provider_user",
      "provider_context" => %{
        "connect_id" => connect_id,
        "chat_id" => call_id,
        "message_id" => delegation_id,
        "from_user_id" => @caller
      }
    }
  end

  describe "voice operations" do
    test "the Router sees the voice manual and its connect", ctx do
      assert {:ok, connect} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)

      assert {:ok, connects} = Provider.list_connects(ctx.router_id)

      assert %{"provider" => "voice"} =
               Enum.find(connects, &(&1["connect_id"] == connect["connect_id"]))

      assert {:ok, manual} = Provider.provider_manual("voice", ctx.router_id)

      assert manual["apis"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
               ~w(voice.hang_up voice.note voice.say)
    end

    test "voice.say reaches the call with the source's call and delegation", ctx do
      {:ok, connect} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)
      call_id = "vc_" <> Ids.new_connect_id()
      fake_call(call_id, {:ok, %{"delivered" => true, "chunks" => 1}})

      assert {:ok, %{"delivered" => true, "chunks" => 1, "call_id" => ^call_id}} =
               Provider.call_api(ctx.router_id, "voice", "voice.say", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"text" => "It is sunny today."},
                 "tool_context" => %{
                   "trusted_origin" => voice_origin(connect["connect_id"], call_id, "dlg_1")
                 }
               })

      assert_receive {:call_received, {:voice_provider, :say, request}}

      assert request == %{
               "group_id" => ctx.group_id,
               "connect_id" => connect["connect_id"],
               "agent_id" => ctx.router_id,
               "delegation_id" => "dlg_1",
               "text" => "It is sunny today."
             }

      # Explicit parameters name another call and no delegation default applies.
      other_call = "vc_" <> Ids.new_connect_id()
      fake_call(other_call, {:ok, %{"ended" => true}})

      assert {:ok, %{"ended" => true}} =
               Provider.call_api(ctx.router_id, "voice", "voice.hang_up", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"call_id" => other_call},
                 "tool_context" => %{
                   "trusted_origin" => voice_origin(connect["connect_id"], call_id, "dlg_1")
                 }
               })

      assert_receive {:call_received,
                      {:voice_provider, :hang_up, %{"delegation_id" => nil, "text" => nil}}}
    end

    test "a call without a live process ends the operation", ctx do
      {:ok, connect} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)

      assert {:error, %{"error_class" => "voice_call_ended", "public_summary" => summary}} =
               Provider.call_api(ctx.router_id, "voice", "voice.note", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"text" => "Still checking.", "call_id" => "vc_gone"}
               })

      assert is_binary(summary) and summary != ""

      call_id = "vc_" <> Ids.new_connect_id()
      fake_call(call_id, {:error, :forbidden})

      assert {:error, "this voice call belongs to another connect"} =
               Provider.call_api(ctx.router_id, "voice", "voice.say", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"text" => "Hello", "call_id" => call_id}
               })

      assert_receive {:call_received, {:voice_provider, :say, %{"text" => "Hello"}}}

      assert {:error, "text is required"} =
               Provider.call_api(ctx.router_id, "voice", "voice.say", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"call_id" => call_id}
               })

      refute_receive {:call_received, _}
    end

    @tag :ended_voice
    test "a late reply after hangup retains a public terminal outcome in model context", ctx do
      previous = Application.get_env(:salix_agent, :im_provider_mod)
      Application.put_env(:salix_agent, :im_provider_mod, Provider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:salix_agent, :im_provider_mod, previous),
          else: Application.delete_env(:salix_agent, :im_provider_mod)
      end)

      {:ok, connect} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)
      call_id = "vc_" <> Ids.new_connect_id()
      pid = fake_call(call_id, {:ok, %{"delivered" => true}})

      tool_ctx = %{
        agent_id: ctx.router_id,
        group_id: ctx.group_id,
        role: "router",
        runtime_kind: :internal,
        llm_tool_envelope: true,
        visible_reply_phase: :clean
      }

      entries = SalixAgent.Tools.ImRouter.dynamic_disclosure_entries(tool_ctx)
      tool_ctx = Map.put(tool_ctx, :tool_disclosure, %{"tools" => entries})

      tool = %{
        id: "voice-before-hangup",
        name: "call",
        args: %{
          "tool" => "im_api.voice.say",
          "params" => %{
            "connect_id" => connect["connect_id"],
            "call_id" => call_id,
            "text" => "Hello."
          }
        }
      }

      [delivered] = SalixAgent.Tools.execute([tool], tool_ctx)
      refute delivered.error
      assert_receive {:call_received, {:voice_provider, :say, _}}
      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      [ended] = SalixAgent.Tools.execute([%{tool | id: "voice-after-hangup"}], tool_ctx)
      assert ended.error_class == "voice_call_ended"
      assert ended.diagnostic_visibility == "user_reportable"
      assert is_binary(ended.public_summary)
      assert SalixAgent.VisibleReplyPolicy.transition(:clean, [ended]) == :none

      [rendered] =
        SalixAgent.VisibleReplyPolicy.sanitize_context([Map.put(ended, :role, "tool")], :clean)

      assert Jason.decode!(rendered.content)["public_summary"] == ended.public_summary
      refute rendered.content =~ call_id
    end

    test "a disabled voice connect cannot reach a call", ctx do
      {:ok, connect} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)
      call_id = "vc_" <> Ids.new_connect_id()
      fake_call(call_id, {:ok, %{}})

      :ok = ProviderConnects.disable_im_connect(ctx.tenant, ctx.group_id, connect["connect_id"])

      assert {:error, "connect not found"} =
               Provider.call_api(ctx.router_id, "voice", "voice.say", %{
                 "connect_id" => connect["connect_id"],
                 "params" => %{"text" => "Hello", "call_id" => call_id}
               })

      refute_receive {:call_received, _}
    end
  end

  describe "voice connect and numbers" do
    test "one connect per Group; a number routes to exactly one Group until released", ctx do
      assert {:ok, first} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)
      assert {:ok, ^first} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)

      assert :ok =
               ProviderConnects.check_voice_number_available(
                 ctx.tenant,
                 ctx.group_id,
                 "twilio",
                 @line,
                 @caller
               )

      assert {:ok, %{"numbers" => [%{"e164" => @caller, "pin_configured" => false}]}} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 ctx.group_id,
                 "twilio",
                 @line,
                 @caller
               )

      assert {:ok, %{"group_id" => group_id, "connect_id" => connect_id, "number" => number}} =
               ProviderConnects.find_voice_connect("twilio", @line, @caller)

      assert {group_id, connect_id} == {ctx.group_id, first["connect_id"]}
      assert number["line"] == @line

      # A different line is a different binding.
      assert {:error, :not_found} =
               ProviderConnects.find_voice_connect("twilio", "+15550002222", @caller)

      {other_group, _router} = group_with_router(ctx.tenant)

      assert {:error, :voice_number_in_use} =
               ProviderConnects.check_voice_number_available(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )

      assert {:error, :voice_number_in_use} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )

      assert {:error, {:bad_request, _}} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 "15551234567"
               )

      # Deleting the connect releases its Group election and its numbers.
      :ok = ProviderConnects.delete_im_connect(ctx.tenant, ctx.group_id, first["connect_id"])
      assert {:error, :not_found} = ProviderConnects.find_voice_connect("twilio", @line, @caller)

      assert {:ok, %{"group_id" => ^other_group}} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )

      assert {:ok, %{"group_id" => ^other_group}} =
               ProviderConnects.find_voice_connect("twilio", @line, @caller)

      assert {:ok, second} = ProviderConnects.ensure_voice_im_connect(ctx.tenant, ctx.group_id)
      refute second["connect_id"] == first["connect_id"]
    end

    test "removing a number releases it to another Group", ctx do
      {:ok, _} =
        ProviderConnects.confirm_voice_number(ctx.tenant, ctx.group_id, "twilio", @line, @caller)

      assert {:ok, %{"numbers" => []}} =
               ProviderConnects.remove_voice_number(ctx.tenant, ctx.group_id, @caller)

      assert {:error, :not_found} = ProviderConnects.find_voice_connect("twilio", @line, @caller)

      assert {:error, :not_found} =
               ProviderConnects.remove_voice_number(ctx.tenant, ctx.group_id, @caller)

      {other_group, _router} = group_with_router(ctx.tenant)

      assert {:ok, %{"group_id" => ^other_group}} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )
    end

    test "a stale reservation is taken over only after its holder stops listing it", ctx do
      {:ok, connect} =
        ProviderConnects.confirm_voice_number(ctx.tenant, ctx.group_id, "twilio", @line, @caller)

      # Simulate a crash after the connect write but before the release.
      {:ok, _} =
        CasRecord.update(Keys.ctl_im_connect(ctx.group_id, connect["connect_id"]), fn rec ->
          Map.put(rec, "voice_numbers", [])
        end)

      identity = "twilio:#{@line}:#{@caller}"
      key = Keys.ctl_im_provider_identity("voice", identity)
      {other_group, _router} = group_with_router(ctx.tenant)

      # Within the grace period the holder may still be writing its binding.
      assert {:error, :voice_number_in_use} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )

      {:ok, _} = CasRecord.update(key, &Map.put(&1, "updated_at", 0))

      assert {:ok, %{"group_id" => ^other_group}} =
               ProviderConnects.confirm_voice_number(
                 ctx.tenant,
                 other_group,
                 "twilio",
                 @line,
                 @caller
               )
    end
  end

  describe "caller PIN" do
    test "the PIN is stored hashed, locks after repeated failures, and a success clears failures",
         ctx do
      {:ok, _} =
        ProviderConnects.confirm_voice_number(ctx.tenant, ctx.group_id, "twilio", @line, @caller)

      assert {:error, {:bad_request, _}} =
               ProviderConnects.set_voice_number_pin(ctx.tenant, ctx.group_id, @caller, "12a4")

      assert {:ok, %{"numbers" => [public]}} =
               ProviderConnects.set_voice_number_pin(ctx.tenant, ctx.group_id, @caller, "4821")

      assert public["pin_configured"] == true
      refute Map.has_key?(public, "pin_hash")

      {:ok, %{"connect_id" => connect_id}} =
        ProviderConnects.get_voice_im_connect(ctx.tenant, ctx.group_id)

      {:ok, stored} = CasRecord.get(Keys.ctl_im_connect(ctx.group_id, connect_id))
      [%{"pin_hash" => hash}] = stored["voice_numbers"]
      refute hash =~ "4821"

      {:ok, listed} = ProviderConnects.list_group_im_connects(ctx.group_id, "voice")
      refute inspect(listed) =~ "pbkdf2"

      verify = fn pin, now ->
        ProviderConnects.verify_voice_pin(
          ctx.group_id,
          connect_id,
          "twilio",
          @line,
          @caller,
          pin,
          max_failures: 3,
          lockout_seconds: 60,
          now_ms: now
        )
      end

      now = System.system_time(:millisecond)
      assert {:error, {:invalid_pin, 2}} = verify.("0000", now)
      assert :ok = verify.("4821", now)
      assert {:error, {:invalid_pin, 2}} = verify.("0000", now)
      assert {:error, {:invalid_pin, 1}} = verify.("1111", now)
      assert {:error, {:locked, until}} = verify.("2222", now)
      assert until == now + 60_000

      # The correct PIN is refused while locked.
      assert {:error, {:locked, ^until}} = verify.("4821", now + 1_000)
      assert :ok = verify.("4821", until + 1)

      assert {:ok, %{"numbers" => [%{"pin_configured" => false}]}} =
               ProviderConnects.set_voice_number_pin(ctx.tenant, ctx.group_id, @caller, "")

      assert {:error, :pin_not_configured} = verify.("4821", until + 2)
    end
  end

  describe "Router delivery" do
    test "voice delegation metadata stays in the trusted origin with a caller principal" do
      group_id = Ids.new_group_id(Ids.new_tenant_id())
      router_id = Ids.new_agent_id(group_id)
      group = %{"group_id" => group_id, "router_agent_id" => router_id}

      router = %{
        "agent_id" => router_id,
        "role" => "router",
        "router_session_id" => Ids.new_session_id()
      }

      metadata = %{
        "provider" => "voice",
        "connect_id" => "cnx_voice",
        "chat_id" => "vc_call",
        "chat_type" => "private",
        "message_id" => "dlg_1",
        "from_user_id" => @caller,
        "from_username" => "Ada",
        "event_type" => "voice.delegation",
        "event_id" => "dlg_1",
        "source_sent_at_ms" => 1_700_000_000_000,
        "source_actor_type" => "provider_user"
      }

      assert {:ok, delivery} =
               AgentDeliveryPayload.provider_router_delivery(
                 group,
                 router,
                 "What is on my calendar?",
                 metadata,
                 source_message_id: "im_provider:voice:cnx_voice:vc_call:dlg_1",
                 trusted_source_text: "What is on my calendar?",
                 session_name: "Voice call"
               )

      origin = delivery["trusted_origin"]
      assert origin["provider"] == "voice"
      assert origin["source_actor_type"] == "provider_user"
      assert origin["source_text"] == "What is on my calendar?"

      assert Map.take(origin["provider_context"], ~w(chat_id message_id from_user_id connect_id)) ==
               %{
                 "chat_id" => "vc_call",
                 "message_id" => "dlg_1",
                 "from_user_id" => @caller,
                 "connect_id" => "cnx_voice"
               }

      assert origin["principal_ref"] == %{
               "namespace" => "voice_user",
               "tenant_id" => Ids.tenant_id_from_group!(group_id),
               "subject_id" => @caller,
               "connect_id" => "cnx_voice"
             }

      # A WebSocket call acts with its voice key: no caller principal is sealed.
      ws_metadata =
        Map.merge(metadata, %{
          "from_user_id" => "api_key:gak_v1",
          "api_key_id" => "gak_v1",
          "api_key_name" => "Kiosk",
          "api_key_principal" => "api_key|gak_v1|comma_user|u1",
          "source_actor_type" => "provider_system"
        })

      assert {:ok, ws_delivery} =
               AgentDeliveryPayload.provider_router_delivery(
                 group,
                 router,
                 "Hello",
                 ws_metadata,
                 source_message_id: "im_provider:voice:cnx_voice:vc_call:dlg_2"
               )

      ws_origin = ws_delivery["trusted_origin"]
      assert ws_origin["source_actor_type"] == "provider_system"
      refute Map.has_key?(ws_origin, "principal_ref")
      assert ws_origin["provider_context"]["api_key_id"] == "gak_v1"

      assert delivery["delivery_session_name"] == "Voice call"
      assert delivery["source_sent_at_ms"] == 1_700_000_000_000
      assert delivery["content"] =~ "chat_id=vc_call"
      assert is_nil(delivery["provider_reply_obligation"])
    end
  end
end
