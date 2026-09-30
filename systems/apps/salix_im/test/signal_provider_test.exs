defmodule SalixIM.SignalProviderTest do
  @moduledoc """
  The Signal provider (`docs/messaging-voice.md`): a claim code binds a
  Signal chat to one Group under a global reservation, bound messages enter
  the Group's Router Conversation, and Router operations reach only chats
  bound to the connect.
  """
  use ExUnit.Case, async: false

  alias SalixIM.{Provider, ProviderConnects, ProviderIdentity, SignalConnects, SignalInbound}
  alias SalixStore.{CasRecord, Ids, Keys, S3}
  alias SalixStore.S3.Fake

  @account "00000000-0000-4000-8000-00000000a001"
  @alice "00000000-0000-4000-8000-000000000011"
  @bob "00000000-0000-4000-8000-000000000012"
  @group_peer "group:" <> Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

  defmodule FakeAccount do
    @moduledoc false
    @behaviour SalixIM.Ports.SignalAccount

    defp record(message) do
      if pid = Application.get_env(:salix_im, :signal_test_pid), do: send(pid, message)
    end

    @impl true
    def send_text(account_id, peer, "rate limited" = body, opts) do
      record({:signal_send, account_id, peer, body, opts})
      {:error, {:rate_limited, 30}}
    end

    def send_text(account_id, peer, body, opts) do
      record({:signal_send, account_id, peer, body, opts})
      {:ok, %{"timestamp" => 1_800_000_000_000 + byte_size(body)}}
    end

    @impl true
    def send_reaction(account_id, peer, emoji, author, timestamp, remove?) do
      record({:signal_reaction, account_id, peer, emoji, author, timestamp, remove?})
      {:ok, %{"timestamp" => 1_800_000_000_001}}
    end

    @impl true
    def send_edit(account_id, peer, timestamp, body) do
      record({:signal_edit, account_id, peer, timestamp, body})
      {:ok, %{"timestamp" => 1_800_000_000_003}}
    end

    @impl true
    def send_delete(account_id, peer, timestamp) do
      record({:signal_delete, account_id, peer, timestamp})
      {:ok, %{"timestamp" => 1_800_000_000_002}}
    end

    @impl true
    def send_typing(account_id, peer, action) do
      record({:signal_typing, account_id, peer, action})
      {:ok, %{"timestamp" => 1_800_000_000_004}}
    end

    @impl true
    def upload_attachment(_account_id, _data, _opts), do: {:ok, :attachment}

    @impl true
    def join_group(account_id, url) do
      record({:signal_join, account_id, url})

      Application.get_env(
        :salix_im,
        :signal_join_result,
        {:ok,
         %{
           "status" => "joined",
           "peer" => "group:" <> Base.url_encode64(:binary.copy(<<9>>, 32), padding: false)
         }}
      )
    end

    @impl true
    def groups(_account_id), do: {:ok, []}
    @impl true
    def change_members(account_id, peer, action, members) do
      record({:signal_members, account_id, peer, action, members})

      if action == :remove,
        do: {:error, :forbidden},
        else: {:ok, %{"revision" => 7}}
    end

    @impl true
    def leave_group(_account_id, _peer), do: {:ok, %{}}
  end

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      port: Application.get_env(:salix_im, :signal_account_mod),
      delivery: Application.get_env(:salix_im, :agent_delivery_mod)
    }

    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    Application.put_env(:salix_im, :signal_account_mod, FakeAccount)
    Application.put_env(:salix_im, :signal_test_pid, self())

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :signal_account_mod, previous.port)
      restore(:salix_im, :agent_delivery_mod, previous.delivery)
      Application.delete_env(:salix_im, :signal_test_pid)
      Application.delete_env(:salix_im, :signal_join_result)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    {group_id, router_id} = group_with_router(tenant)
    %{tenant: tenant, group_id: group_id, router_id: router_id}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

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

  defp message(sender, text, opts \\ []) do
    %{
      "account_id" => Keyword.get(opts, :account, @account),
      "sender" => sender,
      "timestamp" => Keyword.get(opts, :timestamp, 1_700_000_000_000),
      "guid" => "guid-#{System.unique_integer([:positive])}",
      "chat" => Keyword.get(opts, :chat, %{"kind" => "user", "peer" => sender}),
      "type" => "message",
      "text" => text
    }
  end

  defp bind!(ctx, sender, chat \\ nil) do
    {:ok, claim} = SignalConnects.start_claim(ctx.tenant, ctx.group_id, @account, "comma_user:u1")
    chat = chat || %{"kind" => "user", "peer" => sender}
    assert :ok = SignalInbound.deliver(message(sender, claim["command"], chat: chat))
    assert_receive {:signal_send, @account, peer, "Signal is connected" <> _, []}
    assert peer == chat["peer"]
    {:ok, connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)
    connect
  end

  defp signal_origin(connect_id, chat_id, sender, timestamp) do
    %{
      "provider" => "signal",
      "source_actor_type" => "provider_user",
      "provider_context" => %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "message_id" => Integer.to_string(timestamp),
        "from_user_id" => sender
      }
    }
  end

  defp call(ctx, api, connect_id, params, origin) do
    Provider.call_api(ctx.router_id, "signal", api, %{
      "connect_id" => connect_id,
      "params" => params,
      "tool_context" => %{"trusted_origin" => origin}
    })
  end

  describe "claim binding" do
    test "a claim code binds its sender once, and only to one Group", ctx do
      assert {:ok, claim} =
               SignalConnects.start_claim(ctx.tenant, ctx.group_id, @account, "comma_user:u1")

      assert claim["command"] =~ ~r/\Acomma connect [2-9A-Z]{4}-[2-9A-Z]{4}\z/

      # The pending claim is visible without its code or digest.
      {:ok, connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)
      assert [%{"claim_id" => claim_id} = pending] = connect["pending_claims"]
      assert claim_id == claim["claim_id"]
      refute Map.has_key?(pending, "code_digest")
      refute inspect(connect) =~ String.replace(claim["code"], "-", "")

      # Case, spacing and the dash do not matter.
      command =
        "  COMMA Connect " <> String.downcase(String.replace(claim["code"], "-", " ")) <> " "

      assert :ok = SignalInbound.deliver(message(@alice, command))
      assert_receive {:signal_send, @account, @alice, "Signal is connected" <> _, []}

      {:ok, connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)

      assert [%{"kind" => "user", "peer" => @alice, "account_id" => @account}] =
               connect["bindings"]

      assert connect["pending_claims"] == []

      assert {:ok, %{"group_id" => group_id, "binding" => %{"peer" => @alice}}} =
               SignalConnects.find_signal_connect(@account, @alice)

      assert group_id == ctx.group_id

      # The code is single use: another sender cannot reuse it.
      assert :ok = SignalInbound.deliver(message(@bob, claim["command"]))
      assert_receive {:signal_send, @account, @bob, "Could not connect Signal" <> _, []}
      assert {:error, :not_found} = SignalConnects.find_signal_connect(@account, @bob)

      # A second Group cannot take the bound peer; its claim stays pending.
      {other_group, _router} = group_with_router(ctx.tenant)

      {:ok, other} =
        SignalConnects.start_claim(ctx.tenant, other_group, @account, "comma_user:u1")

      assert :ok = SignalInbound.deliver(message(@alice, other["command"]))

      assert_receive {:signal_send, @account, @alice,
                      "This Signal chat is already connected" <> _, []}

      {:ok, other_connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, other_group)
      assert other_connect["bindings"] == []
      assert [_pending] = other_connect["pending_claims"]

      # After removal the reservation is free for the other Group.
      [binding] = connect["bindings"]

      assert {:ok, _connect, %{"peer" => @alice}} =
               SignalConnects.remove_binding(ctx.tenant, ctx.group_id, binding["binding_id"])

      assert {:error, :not_found} = SignalConnects.find_signal_connect(@account, @alice)
      assert :ok = SignalInbound.deliver(message(@alice, other["command"]))
      assert_receive {:signal_send, @account, @alice, "Signal is connected" <> _, []}

      assert {:ok, %{"group_id" => ^other_group}} =
               SignalConnects.find_signal_connect(@account, @alice)
    end

    test "an expired or wrong-account code does not bind", ctx do
      now = System.system_time(:millisecond)

      {:ok, expired} =
        SignalConnects.start_claim(ctx.tenant, ctx.group_id, @account, "u",
          now_ms: now - SignalConnects.claim_ttl_ms() - 1
        )

      assert {:error, :invalid_claim} =
               SignalConnects.redeem_claim(@account, expired["code"], %{
                 "kind" => "user",
                 "peer" => @alice
               })

      {:ok, live} = SignalConnects.start_claim(ctx.tenant, ctx.group_id, @account, "u")

      assert {:error, :invalid_claim} =
               SignalConnects.redeem_claim(
                 "00000000-0000-4000-8000-00000000a002",
                 live["code"],
                 %{
                   "kind" => "user",
                   "peer" => @alice
                 }
               )

      assert {:ok, %{"binding" => %{"peer" => @alice}}} =
               SignalConnects.redeem_claim(@account, live["code"], %{
                 "kind" => "user",
                 "peer" => @alice
               })
    end

    test "a message from an unbound chat gets no reply and no Router input", ctx do
      assert :ok = SignalInbound.deliver(message(@bob, "hello"))
      refute_receive {:signal_send, _, _, _, _}, 100

      assert {:error, :not_found} =
               ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)
    end

    test "a claim sent in a Signal group binds the group", ctx do
      connect = bind!(ctx, @alice, %{"kind" => "group", "peer" => @group_peer})
      assert [%{"kind" => "group", "peer" => @group_peer}] = connect["bindings"]
      assert {:error, :not_found} = SignalConnects.find_signal_connect(@account, @alice)
    end
  end

  describe "concurrent claim and binding writes" do
    test "a claim cancelled while its redemption writes the binding binds nothing", ctx do
      {:ok, claim} = SignalConnects.start_claim(ctx.tenant, ctx.group_id, @account, "u")
      {:ok, connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)
      [%{"claim_id" => claim_id}] = connect["pending_claims"]
      connect_key = Keys.ctl_im_connect(ctx.group_id, connect["connect_id"])

      redeem =
        paused_task(
          fn ->
            SignalConnects.redeem_claim(@account, claim["code"], %{
              "kind" => "user",
              "peer" => @alice
            })
          end,
          {:pause, :put, connect_key}
        )

      # The redemption has read the live claim and waits on its binding write.
      assert {:ok, %{"pending_claims" => []}} =
               SignalConnects.cancel_claim(ctx.tenant, ctx.group_id, claim_id)

      assert :ok = Fake.release_pause()
      assert {:error, :invalid_claim} = Task.await(redeem)
      assert {:error, :not_found} = SignalConnects.find_signal_connect(@account, @alice)
      {:ok, connect} = ProviderConnects.get_signal_im_connect(ctx.tenant, ctx.group_id)
      assert connect["bindings"] == []
    end

    test "a delayed release of a removed binding keeps the next Group's reservation", ctx do
      connect = bind!(ctx, @alice)
      [binding] = connect["bindings"]

      peer_key =
        Keys.ctl_im_provider_identity(
          "signal",
          ProviderIdentity.signal_peer_identity(@account, @alice)
        )

      # Past the grace window, a holder that no longer lists the peer loses it.
      {:ok, _} =
        CasRecord.update(peer_key, &Map.merge(&1, %{"created_at" => 0, "updated_at" => 0}))

      {other_group, _router} = group_with_router(ctx.tenant)
      {:ok, other} = SignalConnects.start_claim(ctx.tenant, other_group, @account, "u")

      remove =
        paused_task(
          fn ->
            SignalConnects.remove_binding(ctx.tenant, ctx.group_id, binding["binding_id"])
          end,
          {:pause, :get, peer_key}
        )

      # The first Group no longer lists the peer and has read its reservation.
      assert {:ok, %{"group_id" => ^other_group, "binding" => %{"peer" => @alice}}} =
               SignalConnects.redeem_claim(@account, other["code"], %{
                 "kind" => "user",
                 "peer" => @alice
               })

      assert :ok = Fake.release_pause()
      assert {:ok, _connect, %{"peer" => @alice}} = Task.await(remove)

      assert {:ok, %{"group_id" => ^other_group, "binding" => %{"peer" => @alice}}} =
               SignalConnects.find_signal_connect(@account, @alice)
    end
  end

  describe "Router ingress" do
    test "a bound sender's message reaches the Router Conversation once", ctx do
      connect = bind!(ctx, @alice)
      event = message(@alice, "What is on my calendar?", timestamp: 1_700_000_000_123)
      assert :ok = SignalInbound.deliver(event)
      # A replay of the same message is the same Router input.
      assert :ok = SignalInbound.deliver(event)

      source_id = "im_provider:signal:#{connect["connect_id"]}:#{@alice}:1700000000123"
      assert [message] = router_inputs(ctx.group_id, source_id)
      origin = message["agent_input"]["trusted_origin"]

      assert origin["provider"] == "signal"
      assert origin["source_text"] == "What is on my calendar?"
      assert origin["principal_ref"]["subject_id"] == @alice

      assert Map.take(
               origin["provider_context"],
               ~w(connect_id chat_id chat_type message_id from_user_id)
             ) ==
               %{
                 "connect_id" => connect["connect_id"],
                 "chat_id" => @alice,
                 "chat_type" => "private",
                 "message_id" => "1700000000123",
                 "from_user_id" => @alice
               }
    end

    test "a reaction reaches the Router as a described event", ctx do
      connect = bind!(ctx, @alice)

      event =
        @alice
        |> message("", timestamp: 1_700_000_000_200)
        |> Map.merge(%{
          "type" => "reaction",
          "reaction" => %{
            "emoji" => "👍",
            "remove" => false,
            "target_author" => @account,
            "target_timestamp" => 1_700_000_000_100
          }
        })

      assert :ok = SignalInbound.deliver(event)
      source_id = "im_provider:signal:#{connect["connect_id"]}:#{@alice}:1700000000200"
      assert [message] = router_inputs(ctx.group_id, source_id)
      assert message["agent_input"]["content"] =~ "reacted 👍 on message 1700000000100"
      assert message["agent_input"]["trusted_origin"]["source_text"] in [nil, ""]
    end
  end

  describe "Router operations" do
    test "the Router sees the Signal manual and its connect", ctx do
      connect = bind!(ctx, @alice)
      assert {:ok, connects} = Provider.list_connects(ctx.router_id)

      assert %{"provider" => "signal"} =
               Enum.find(connects, &(&1["connect_id"] == connect["connect_id"]))

      assert {:ok, manual} = Provider.provider_manual("signal", ctx.router_id)
      assert "signal.send_message" in Enum.map(manual["apis"], & &1["name"])
    end

    test "send_message answers the source chat through its binding's account", ctx do
      connect = bind!(ctx, @alice)
      origin = signal_origin(connect["connect_id"], @alice, @alice, 1_700_000_000_000)

      assert {:ok, %{"chat_id" => @alice, "timestamps" => [_]}} =
               call(
                 ctx,
                 "signal.send_message",
                 connect["connect_id"],
                 %{"text" => "Sunny."},
                 origin
               )

      assert_receive {:signal_send, @account, @alice, "Sunny.", [attachments: []]}

      # Long text goes as one message; the account runtime carries text over
      # the 2,048-byte body limit as a long-text attachment.
      long = String.trim(String.duplicate("word ", 900))

      assert {:ok, %{"timestamps" => [_stamp]}} =
               call(ctx, "signal.send_message", connect["connect_id"], %{"text" => long}, origin)

      assert_receive {:signal_send, @account, @alice, ^long, _opts}

      # A reaction defaults to the source message.
      assert {:ok, _} =
               call(ctx, "signal.react", connect["connect_id"], %{"emoji" => "👍"}, origin)

      assert_receive {:signal_reaction, @account, @alice, "👍", @alice, 1_700_000_000_000, false}
    end

    test "a chat that is not bound to the connect cannot be addressed", ctx do
      connect = bind!(ctx, @alice)
      origin = signal_origin(connect["connect_id"], @alice, @alice, 1_700_000_000_000)

      assert {:error, message} =
               call(
                 ctx,
                 "signal.send_message",
                 connect["connect_id"],
                 %{"chat_id" => @bob, "text" => "hi"},
                 origin
               )

      assert message =~ "only address chats bound to it"
      refute_receive {:signal_send, _, @bob, _, _}, 50

      # Outside a Signal source there is no default chat.
      assert {:error, "chat_id is required outside a Signal source"} =
               call(ctx, "signal.send_message", connect["connect_id"], %{"text" => "hi"}, %{})
    end

    test "a rate-limited send keeps its retry facts in model context after repair", ctx do
      previous = Application.get_env(:salix_agent, :im_provider_mod)
      Application.put_env(:salix_agent, :im_provider_mod, Provider)
      on_exit(fn -> restore(:salix_agent, :im_provider_mod, previous) end)
      connect = bind!(ctx, @alice)

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

      call = %{
        id: "signal-rate-limited",
        name: "call",
        args: %{
          "tool" => "im_api.signal.send_message",
          "params" => %{
            "connect_id" => connect["connect_id"],
            "chat_id" => @alice,
            "text" => "rate limited"
          }
        }
      }

      [limited] = SalixAgent.Tools.execute([call], tool_ctx)
      assert_receive {:signal_send, @account, @alice, "rate limited", _}
      assert limited.error_class == "signal_rate_limited"

      private =
        limited
        |> Map.merge(%{role: "tool", tool_call_id: limited.id})
        |> SalixAgent.VisibleReplyPolicy.label_result()

      assert private.diagnostic_visibility == "model_only"
      assert SalixAgent.VisibleReplyPolicy.transition(:clean, [private]) == {:required, 0}

      # Repair shows the diagnostic. After repair, only the closed facts and
      # the target tool remain.
      assistant = %{role: "assistant", content: "", tool_calls: [call]}

      [^assistant, ^private] =
        SalixAgent.VisibleReplyPolicy.sanitize_context(
          [assistant, private],
          {:repair_required, 0}
        )

      [redacted, retained] =
        SalixAgent.VisibleReplyPolicy.sanitize_context([assistant, private], :clean)

      assert [%{args: %{"tool" => "im_api.signal.send_message", "repair_context" => "redacted"}}] =
               redacted.tool_calls

      assert %{
               "status" => "failed",
               "error_class" => "signal_rate_limited",
               "effect" => "not_applied",
               "retry" => "after_delay"
             } = Jason.decode!(retained.content)

      refute retained.content =~ "30 seconds"
      refute inspect(redacted) =~ @alice
    end

    test "membership changes reach the account of the group binding", ctx do
      connect = bind!(ctx, @alice, %{"kind" => "group", "peer" => @group_peer})
      origin = signal_origin(connect["connect_id"], @group_peer, @alice, 1_700_000_000_000)

      assert {:ok, %{"revision" => 7}} =
               call(
                 ctx,
                 "signal.add_members",
                 connect["connect_id"],
                 %{"members" => [@bob]},
                 origin
               )

      assert_receive {:signal_members, @account, @group_peer, :add, [@bob]}

      # A refusal by the group (not an administrator) reads as signal_forbidden.
      assert {:error, %{"error_class" => "signal_forbidden"}} =
               call(
                 ctx,
                 "signal.remove_members",
                 connect["connect_id"],
                 %{"members" => [@alice]},
                 origin
               )
    end

    test "join failures identify missing profiles and disabled links", ctx do
      connect = bind!(ctx, @alice)
      origin = signal_origin(connect["connect_id"], @alice, @alice, 1_700_000_000_000)

      for {reason, code} <- [
            {:no_profile_credential, "signal_profile_unavailable"},
            {:link_disabled, "signal_group_link_invalid"}
          ] do
        Application.put_env(:salix_im, :signal_join_result, {:error, reason})

        assert {:error, %{"error_class" => ^code}} =
                 call(
                   ctx,
                   "signal.join_group",
                   connect["connect_id"],
                   %{"invite_url" => "https://signal.group/#CjQKIA"},
                   origin
                 )
      end
    end

    test "join_group binds the joined group to the connect", ctx do
      connect = bind!(ctx, @alice)
      origin = signal_origin(connect["connect_id"], @alice, @alice, 1_700_000_000_000)

      assert {:ok, %{"status" => "joined", "chat_id" => "group:" <> _ = group}} =
               call(
                 ctx,
                 "signal.join_group",
                 connect["connect_id"],
                 %{"invite_url" => "https://signal.group/#CjQKIA"},
                 origin
               )

      assert_receive {:signal_join, @account, "https://signal.group/#CjQKIA"}

      assert {:ok, %{"group_id" => group_id}} =
               SignalConnects.find_signal_connect(@account, group)

      assert group_id == ctx.group_id

      assert {:error, "invite_url must be a https://signal.group/# link"} =
               call(
                 ctx,
                 "signal.join_group",
                 connect["connect_id"],
                 %{"invite_url" => "https://example.com/#x"},
                 origin
               )
    end
  end

  defp paused_task(fun, fault) do
    task =
      Task.async(fn ->
        receive do
          :go -> fun.()
        end
      end)

    Fake.set_fault_for(task.pid, fault)
    send(task.pid, :go)
    assert wait_paused(200)
    task
  end

  defp wait_paused(0), do: false

  defp wait_paused(attempts) do
    if Fake.paused?() do
      true
    else
      Process.sleep(10)
      wait_paused(attempts - 1)
    end
  end

  defp router_inputs(group_id, source_id, retries \\ 200) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        conversation["conversation_id"],
        limit: 50
      )

    found =
      Enum.filter(messages, fn message ->
        get_in(message, ["agent_input", "trusted_origin", "source_message_id"]) == source_id
      end)

    cond do
      found != [] -> found
      retries > 0 -> Process.sleep(25) && router_inputs(group_id, source_id, retries - 1)
      true -> flunk("Router input missing #{inspect(source_id)}")
    end
  end
end
