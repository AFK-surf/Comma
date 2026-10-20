defmodule SalixIM.ConversationPrivateStoreTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixIM.{
    ConversationActor,
    ConversationInput,
    ConversationParticipantActor,
    ConversationParticipantStore,
    ConversationPlacement,
    ConversationStore,
    Conversations
  }

  alias SalixStore.{Ids, Keys}

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Private stores"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    now = SystemsClock.system_time(:millisecond)

    {:ok, %{"conversation_id" => conversation_id}} =
      ConversationInput.create_group_conversation(group_id, %{
        "title" => "Private store boundary",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          }
        ]
      })

    {:ok, %{"participants" => [participant]}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    {:ok,
     %{
       group_id: group_id,
       conversation_id: conversation_id,
       participant_id: participant["participant_id"]
     }}
  end

  test "each actor owns exactly one unnamed stateful store and external mutations are rejected",
       context do
    group_id = context.group_id
    conversation_id = context.conversation_id
    participant_id = context.participant_id
    conversation_actor = conversation_actor(context)
    conversation_state = :sys.get_state(conversation_actor, :infinity)
    conversation_store = conversation_state.store_pid

    assert conversation_store == :sys.get_state(conversation_actor, :infinity).store_pid
    assert [] == Registry.keys(SalixIM.ConversationRegistry, conversation_store)
    assert {:registered_name, []} == Process.info(conversation_store, :registered_name)
    assert {:links, [^conversation_actor]} = Process.info(conversation_store, :links)

    assert %{
             owner: ^conversation_actor,
             owner_ref: owner_ref,
             group_id: ^group_id,
             conversation_id: ^conversation_id,
             meta_key: meta_key,
             pending_list_repair: nil
           } = :sys.get_state(conversation_store, :infinity)

    assert is_reference(owner_ref)
    assert meta_key == Keys.ctl_group_conversation(group_id, conversation_id)

    assert {:error, :unauthorized_store_caller} =
             ConversationStore.update(conversation_store, &Map.put(&1, "title", "forbidden"))

    assert {:ok, %{"title" => "Private store boundary"}} =
             Conversations.get_group_conversation(
               context.group_id,
               context.conversation_id
             )

    participant_actor = participant_actor(context)
    participant_state = :sys.get_state(participant_actor, :infinity)
    participant_store = participant_state.store_pid

    assert participant_store == :sys.get_state(participant_actor, :infinity).store_pid
    assert [] == Registry.keys(SalixIM.ConversationRegistry, participant_store)
    assert {:registered_name, []} == Process.info(participant_store, :registered_name)
    assert {:links, [^participant_actor]} = Process.info(participant_store, :links)

    assert %{
             owner: ^participant_actor,
             owner_ref: participant_owner_ref,
             group_id: ^group_id,
             conversation_id: ^conversation_id,
             participant_id: ^participant_id,
             participant_key: participant_key
           } = :sys.get_state(participant_store, :infinity)

    assert is_reference(participant_owner_ref)

    assert participant_key ==
             Keys.ctl_group_conversation_participant_state(
               group_id,
               conversation_id,
               participant_id
             )

    assert {:error, :unauthorized_store_caller} =
             ConversationParticipantStore.update(
               participant_store,
               &Map.put(&1, "state", "inactive")
             )

    assert {:ok, %{"state" => "active"}} =
             Conversations.get_group_conversation_participant(
               context.group_id,
               context.conversation_id,
               context.participant_id
             )
  end

  defp conversation_actor(context) do
    {:ok, actor} =
      ConversationPlacement.ensure_started(
        context.group_id,
        context.conversation_id
      )

    actor
  end

  defp participant_actor(context) do
    {:ok, actor} =
      SalixIM.ConversationFleet.ensure_participant_started(
        context.group_id,
        context.conversation_id,
        context.participant_id
      )

    actor
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
