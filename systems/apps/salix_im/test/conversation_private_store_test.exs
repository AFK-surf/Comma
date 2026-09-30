defmodule SalixIM.ConversationPrivateStoreTest do
  use ExUnit.Case, async: false

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

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
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

    now = System.system_time(:millisecond)

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
    conversation_state = :sys.get_state(conversation_actor)
    conversation_store = conversation_state.store_pid

    assert conversation_store == :sys.get_state(conversation_actor).store_pid
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
           } = :sys.get_state(conversation_store)

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
    participant_state = :sys.get_state(participant_actor)
    participant_store = participant_state.store_pid

    assert participant_store == :sys.get_state(participant_actor).store_pid
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
           } = :sys.get_state(participant_store)

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

  test "owner termination also terminates its private store", context do
    participant_actor = participant_actor(context)
    participant_store = :sys.get_state(participant_actor).store_pid
    participant_store_ref = Process.monitor(participant_store)

    assert :ok =
             DynamicSupervisor.terminate_child(
               SalixIM.ConversationFleetSup,
               participant_actor
             )

    assert_receive {:DOWN, ^participant_store_ref, :process, ^participant_store, _reason}, 1_000
    refute Process.alive?(participant_store)

    actor = conversation_actor(context)
    store = :sys.get_state(actor).store_pid
    store_ref = Process.monitor(store)

    assert :ok =
             DynamicSupervisor.terminate_child(
               SalixIM.ConversationFleetSup,
               actor
             )

    assert_receive {:DOWN, ^store_ref, :process, ^store, _reason}, 1_000
    refute Process.alive?(store)
  end

  test "store exits restart the owner with one fresh store and no parallel writer", context do
    assert :ok =
             DynamicSupervisor.terminate_child(
               SalixIM.ConversationFleetSup,
               participant_actor(context)
             )

    assert :ok =
             DynamicSupervisor.terminate_child(
               SalixIM.ConversationFleetSup,
               conversation_actor(context)
             )

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, actor} =
      DynamicSupervisor.start_child(
        supervisor,
        {ConversationActor,
         group_id: context.group_id,
         conversation_id: context.conversation_id,
         wake_on_recovery: false}
      )

    store = :sys.get_state(actor).store_pid
    actor_ref = Process.monitor(actor)

    assert :ok = GenServer.stop(store, :normal)

    assert_receive {:DOWN, ^actor_ref, :process, ^actor, _reason}, 1_000
    refute Process.alive?(store)

    restarted_actor =
      eventually(fn ->
        case Registry.lookup(
               SalixIM.ConversationRegistry,
               ConversationActor.key(context.group_id, context.conversation_id)
             ) do
          [{pid, _}] when pid != actor and is_pid(pid) -> pid
          _ -> nil
        end
      end)

    restarted_store = :sys.get_state(restarted_actor).store_pid

    assert restarted_store != store
    assert Process.alive?(restarted_store)
    assert [] == Registry.keys(SalixIM.ConversationRegistry, restarted_store)
    refute Process.alive?(store)

    {:ok, participant_actor} =
      DynamicSupervisor.start_child(
        supervisor,
        {ConversationParticipantActor,
         group_id: context.group_id,
         conversation_id: context.conversation_id,
         participant_id: context.participant_id}
      )

    participant_store = :sys.get_state(participant_actor).store_pid
    participant_ref = Process.monitor(participant_actor)

    Process.exit(participant_store, :kill)

    assert_receive {:DOWN, ^participant_ref, :process, ^participant_actor, _reason}, 1_000
    refute Process.alive?(participant_store)

    restarted_participant =
      eventually(fn ->
        case Registry.lookup(
               SalixIM.ConversationRegistry,
               ConversationParticipantActor.key(
                 context.group_id,
                 context.conversation_id,
                 context.participant_id
               )
             ) do
          [{pid, _}] when pid != participant_actor and is_pid(pid) -> pid
          _ -> nil
        end
      end)

    restarted_participant_store = :sys.get_state(restarted_participant).store_pid

    assert restarted_participant_store != participant_store
    assert Process.alive?(restarted_participant_store)
    assert [] == Registry.keys(SalixIM.ConversationRegistry, restarted_participant_store)
    refute Process.alive?(participant_store)
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not converge")

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
