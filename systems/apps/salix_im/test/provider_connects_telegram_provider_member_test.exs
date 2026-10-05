defmodule SalixIM.ProviderConnectsTelegramProviderMemberTest do
  @moduledoc """
  Telegram inbound goes through `enqueue_group_router_im_provider_message/5`,
  which used to leave the Router Conversation with only `agent` and `user`
  Participants. `delivery_target_ids/1` skips other actor types, so the
  wake queue stayed empty and `ConversationDelivery.deliver` was never
  invoked for the conversation - the agent's replies never reached Telegram.

  The fix ensures a `provider` Participant carrying the inbound metadata
  (`provider`, `connect_id`, `chat_id`, ...) as a side effect of a successful
  `append_provider_input/4`. These tests assert that the Provider member is
  written with the expected payload, and that idempotent re-inbound doesn't
  duplicate it.
  """
  use ExUnit.Case, async: false

  alias SalixIM.{Conversations, ProviderConnects}
  alias SalixStore.Keys

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      agent_delivery: Application.get_env(:salix_im, :agent_delivery_mod),
      session_activity: Application.get_env(:salix_im, :session_activity_mod),
      agent_workspace: Application.get_env(:salix_im, :agent_workspace_mod),
      diagnostic_sink: Application.get_env(:salix_im, :diagnostic_sink)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity)
    Application.put_env(:salix_im, :agent_workspace_mod, SalixIM.TestSupport.AgentWorkspace)
    Application.put_env(:salix_im, :diagnostic_sink, nil)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :agent_delivery_mod, previous.agent_delivery)
      restore(:salix_im, :session_activity_mod, previous.session_activity)
      restore(:salix_im, :agent_workspace_mod, previous.agent_workspace)
      restore(:salix_im, :diagnostic_sink, previous.diagnostic_sink)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
        Map.put(rec, "router_agent_id", agent["agent_id"])
      end)

    connect_id = "imc1_tg_test"

    now = System.system_time(:millisecond)

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => connect_id,
        "provider" => "telegram",
        "bot_token" => "tg-test",
        "inbound_agent_id" => agent["agent_id"],
        "oauth_completed_at" => 1,
        "created_at" => now,
        "updated_at" => now
      })

    %{tenant: tenant, group_id: group_id, agent_id: agent["agent_id"], connect_id: connect_id}
  end

  test "telegram inbound adds a provider member carrying chat_id and connect_id", ctx do
    metadata = telegram_metadata(ctx, "123")

    assert {:ok, :queued} =
             ProviderConnects.enqueue_group_router_im_provider_message(
               ctx.group_id,
               "hello",
               metadata,
               "src-1"
             )

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, router_conversation_id(ctx))

    provider_member = Enum.find(participants, &(&1["actor_type"] == "provider"))

    assert provider_member, "expected a provider member on the Router conversation"
    assert provider_member["provider"] == "telegram"
    assert get_in(provider_member, ["payload", "connect_id"]) == ctx.connect_id
    assert get_in(provider_member, ["payload", "chat_id"]) == "123"
    assert provider_member["state"] == "active"
  end

  test "telegram inbound is idempotent across repeated messages from the same chat", ctx do
    metadata = telegram_metadata(ctx, "456")

    for n <- 1..3 do
      assert {:ok, :queued} =
               ProviderConnects.enqueue_group_router_im_provider_message(
                 ctx.group_id,
                 "msg #{n}",
                 metadata,
                 "src-#{n}"
               )
    end

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, router_conversation_id(ctx))

    providers = Enum.filter(participants, &(&1["actor_type"] == "provider"))
    assert length(providers) == 1, "deterministic target_key keeps the second inbound from adding another member"

    [provider] = providers
    assert get_in(provider, ["payload", "chat_id"]) == "456"
    assert get_in(provider, ["payload", "connect_id"]) == ctx.connect_id
  end

  test "the provider member is also ensured when chat_id changes", ctx do
    metadata_a = telegram_metadata(ctx, "111")
    metadata_b = telegram_metadata(ctx, "222")

    assert {:ok, :queued} =
             ProviderConnects.enqueue_group_router_im_provider_message(
               ctx.group_id,
               "hi",
               metadata_a,
               "src-a"
             )

    assert {:ok, :queued} =
             ProviderConnects.enqueue_group_router_im_provider_message(
               ctx.group_id,
               "hi",
               metadata_b,
               "src-b"
             )

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, router_conversation_id(ctx))

    providers = Enum.filter(participants, &(&1["actor_type"] == "provider"))
    # `chat_id` is part of the deterministic `target_key`, so a different chat
    # owns its own provider member. The fix doesn't conflate them; it just
    # makes sure each one exists.
    assert length(providers) == 2

    chat_ids =
      providers
      |> Enum.map(&get_in(&1, ["payload", "chat_id"]))
      |> Enum.sort()

    assert chat_ids == ["111", "222"]

    Enum.each(providers, fn p ->
      assert get_in(p, ["payload", "connect_id"]) == ctx.connect_id
      assert p["provider"] == "telegram"
    end)
  end

  # ---- helpers ----

  defp telegram_metadata(ctx, chat_id) do
    %{
      "provider" => "telegram",
      "connect_id" => ctx.connect_id,
      "chat_id" => chat_id,
      "chat_type" => "private",
      "user_id" => "u_1",
      "message_id" => "m_1",
      "event_type" => "message"
    }
  end

  defp router_conversation_id(ctx) do
    {:ok, conversation} =
      SalixIM.RouterConversationProjection.get_group_router_conversation(ctx.group_id)

    conversation["conversation_id"]
  end

  defp restore(app, key, value) do
    if is_nil(value) do
      Application.delete_env(app, key)
    else
      Application.put_env(app, key, value)
    end
  end
end