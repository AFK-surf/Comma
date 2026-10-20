defmodule SalixIM.ConversationParticipantStoreTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.ConversationParticipantStore
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    conversation_id = Ids.new_conversation_id()
    participant_id = Ids.new_participant_id()

    {:ok, store} =
      ConversationParticipantStore.start_link(
        owner: SystemsRuntime.Proc.self(),
        group_id: group_id,
        conversation_id: conversation_id,
        participant_id: participant_id
      )

    {:ok,
     store: store,
     group_id: group_id,
     conversation_id: conversation_id,
     participant_id: participant_id}
  end

  test "delivery operations derive keys and overwrite fixed owner identity", context do
    delivery_id = "delivery-1"

    assert :inserted =
             ConversationParticipantStore.put_delivery(context.store, %{
               "delivery_id" => delivery_id,
               "agent_group_id" => "forged-group",
               "conversation_id" => "forged-conversation",
               "participant_id" => "forged-participant",
               "status" => "pending",
               "message_id" => "message-1",
               "created_at" => 1
             })

    assert {:ok, stored, revision} =
             ConversationParticipantStore.read_delivery(context.store, delivery_id)

    assert is_binary(revision)
    assert stored["agent_group_id"] == context.group_id
    assert stored["conversation_id"] == context.conversation_id
    assert stored["participant_id"] == context.participant_id
    assert stored["delivery_id"] == delivery_id

    assert {:ok, _result} =
             ConversationParticipantStore.put_delivery_state(
               context.store,
               delivery_id,
               Map.merge(stored, %{
                 "agent_group_id" => "other-group",
                 "conversation_id" => "other-conversation",
                 "participant_id" => "other-participant",
                 "status" => "retry_waiting"
               }),
               revision
             )

    assert {:ok, updated} =
             ConversationParticipantStore.delivery_by_id(context.store, delivery_id)

    assert updated["agent_group_id"] == context.group_id
    assert updated["conversation_id"] == context.conversation_id
    assert updated["participant_id"] == context.participant_id
  end

  for {name, fault} <- [
        {"adopts an ambiguous write only after exact read-back", :ambiguous_after},
        {"retries only after read-back proves an ambiguous write did not land", :ambiguous_before}
      ] do
    @fault fault
  end

  # A write that did not land must restart both guard reads (at least four);
  # one that landed is adopted after read-back with only the original two.
  for {name, fault, read_bound} <- [
        {"fully restarts after an ambiguous write that did not land", :ambiguous_before,
         {:at_least, 4}},
        {"adopts an ambiguous write only after exact read-back", :ambiguous_after, {:exactly, 2}}
      ] do
    @fault fault
    @read_bound read_bound
    test "guarded participant upsert #{name}", context do
      {binding_key, guard, participant, transition} = guarded_upsert_fixture!(context)

      assert {:ok, :inserted, ^participant} =
               ConversationParticipantStore.put_new(context.store, participant)

      participant_key =
        Keys.ctl_group_conversation_participant_state(
          context.group_id,
          context.conversation_id,
          context.participant_id
        )

      :ok = S3.Fake.set_fault_for(context.store, {@fault, :put, participant_key})
      :ok = S3.Fake.reset_read_log()

      assert {:ok, :repaired, %{"payload" => %{"task_thread_binding_token" => "T1"}} = updated} =
               ConversationParticipantStore.guarded_upsert(context.store, guard, transition)

      assert {:ok, ^updated} = ConversationParticipantStore.load(context.store)

      case @read_bound do
        {:at_least, n} -> assert count_guard_reads(context.store, binding_key) >= n
        {:exactly, n} -> assert count_guard_reads(context.store, binding_key) == n
      end
    end
  end

  defp guarded_upsert_fixture!(context) do
    binding_key = "test/task-thread-bindings/#{context.participant_id}.json"

    binding = %{
      "version" => 3,
      "binding_type" => "task",
      "binding_status" => "active",
      "binding_token" => "T1",
      "participant_id" => context.participant_id
    }

    assert {:ok, ^binding} = CasRecord.create(binding_key, binding)

    guard = %{
      "record_key" => binding_key,
      "required" => %{
        "version" => 3,
        "binding_type" => "task",
        "binding_status" => "active",
        "binding_token" => "T1"
      },
      "one_of" => %{},
      "optional_expected" => %{"participant_id" => context.participant_id}
    }

    participant = %{
      "participant_id" => context.participant_id,
      "conversation_id" => context.conversation_id,
      "actor_type" => "provider",
      "provider" => "slack",
      "target_key" => "task-thread-target",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "payload" => %{}
    }

    transition = fn
      :not_found ->
        {:ok, :inserted, put_in(participant, ["payload", "task_thread_binding_token"], "T1")}

      current when is_map(current) ->
        {:ok, :repaired, put_in(current, ["payload", "task_thread_binding_token"], "T1")}
    end

    {binding_key, guard, participant, transition}
  end

  defp count_guard_reads(store, binding_key) do
    store
    |> S3.Fake.read_log()
    |> Enum.count(&(&1 == {:get, binding_key}))
  end
end
