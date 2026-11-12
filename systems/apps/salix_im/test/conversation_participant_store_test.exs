defmodule SalixIM.ConversationParticipantStoreTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationParticipantStore, ConversationPGStore}
  alias SalixStore.{CasRecord, Ids, Repo}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    group = Ids.new_group_id(Ids.new_tenant_id())
    conversation = Ids.new_conversation_id()
    participant = Ids.new_participant_id()
    scope = ConversationPGStore.new(group, conversation)
    assert {:ok, :inserted, _, 1} = ConversationPGStore.create(scope, %{"kind" => "user_chat"})

    {:ok, store} =
      ConversationParticipantStore.start_link(
        owner: SystemsRuntime.Proc.self(),
        group_id: group,
        conversation_id: conversation,
        participant_id: participant
      )

    on_exit(fn ->
      Repo.query!("DELETE FROM salix_conversation_deliveries WHERE group_id=$1", [group])
      Repo.query!("DELETE FROM salix_conversation_participants WHERE group_id=$1", [group])
      Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [group])
      Repo.query!("DELETE FROM conversation_log_recovery WHERE group_id=$1", [group])

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    {:ok,
     store: store,
     group_id: group,
     conversation_id: conversation,
     participant_id: participant,
     scope: scope}
  end

  test "delivery claims derive owner identity and a stale revision cannot replace a claim",
       context do
    assert {:ok, :inserted, _} =
             ConversationParticipantStore.put_new(context.store, participant(context))

    assert {:ok, before, _} = ConversationPGStore.read(context.scope)

    assert :inserted =
             ConversationParticipantStore.put_delivery(context.store, %{
               "delivery_id" => "delivery-1",
               "agent_group_id" => "forged",
               "conversation_id" => "forged",
               "participant_id" => "forged",
               "status" => "pending",
               "message_id" => "message-1"
             })

    assert {:ok, stored, revision} =
             ConversationParticipantStore.read_delivery(context.store, "delivery-1")

    assert stored["agent_group_id"] == context.group_id
    assert stored["conversation_id"] == context.conversation_id
    assert stored["participant_id"] == context.participant_id
    claimed = Map.put(stored, "status", "delivering")

    assert {:ok, %{etag: claim_revision}} =
             ConversationParticipantStore.put_delivery_state(
               context.store,
               "delivery-1",
               claimed,
               revision
             )

    assert {:error, :precondition_failed} =
             ConversationParticipantStore.put_delivery_state(
               context.store,
               "delivery-1",
               Map.put(stored, "status", "delivered"),
               revision
             )

    assert {:ok, ^claimed, ^claim_revision} =
             ConversationParticipantStore.read_delivery(context.store, "delivery-1")

    assert {:ok, after_claim, _} = ConversationPGStore.read(context.scope)
    assert after_claim["membership_revision"] == before["membership_revision"]
  end

  test "a guarded lifecycle change preserves generation authority and publishes its membership target",
       context do
    binding_key = "test/binding/#{context.participant_id}"
    binding = %{"version" => 3, "binding_token" => "T1"}
    assert {:ok, _} = CasRecord.create(binding_key, binding)

    assert {:ok, :inserted, _} =
             ConversationParticipantStore.put_new(context.store, participant(context))

    guard = %{
      "record_key" => binding_key,
      "required" => binding,
      "one_of" => %{},
      "optional_expected" => %{}
    }

    transition = fn current ->
      {:ok, :repaired, put_in(current, ["payload", "task_thread_binding_token"], "T1")}
    end

    assert {:ok, :repaired, updated} =
             ConversationParticipantStore.guarded_upsert(context.store, guard, transition)

    assert {:ok, ^updated} = ConversationParticipantStore.load(context.store)
    assert {:ok, source, _} = ConversationPGStore.read(context.scope)

    assert %{rows: [[membership]]} =
             Repo.query!(
               "SELECT membership_revision FROM conversation_log_recovery WHERE group_id=$1 AND conversation_id=$2",
               [context.group_id, context.conversation_id]
             )

    assert membership == source["membership_revision"]
    assert {:ok, _} = CasRecord.update(binding_key, &Map.put(&1, "binding_token", "T2"))

    assert {:error, :guard_record_mismatch} =
             ConversationParticipantStore.guarded_upsert(context.store, guard, fn _ ->
               flunk("stale generation transition ran")
             end)
  end

  test "an unknown Participant mutation retains its frozen candidate without rerunning its function",
       context do
    assert {:ok, :inserted, original} =
             ConversationParticipantStore.put_new(context.store, participant(context))

    Repo.query!("""
    CREATE FUNCTION participant_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.participant_id = '#{context.participant_id}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER participant_disconnect BEFORE UPDATE ON salix_conversation_participants FOR EACH ROW EXECUTE FUNCTION participant_disconnect()"
    )

    on_exit(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS participant_disconnect ON salix_conversation_participants"
      )

      Repo.query!("DROP FUNCTION IF EXISTS participant_disconnect()")
    end)

    test_pid = SystemsRuntime.Proc.self()

    assert {:error, :commit_indeterminate} =
             ConversationParticipantStore.update(context.store, fn current ->
               SystemsRuntime.Proc.send(test_pid, :transition_ran)
               Map.put(current, "state", "inactive")
             end)

    assert_received :transition_ran
    refute_received :transition_ran
    assert {:ok, ^original} = ConversationParticipantStore.load(context.store)

    assert {:error, :commit_indeterminate} =
             ConversationParticipantStore.update(context.store, fn _ ->
               flunk("a new command ran while outcome was unknown")
             end)

    Repo.query!("DROP TRIGGER participant_disconnect ON salix_conversation_participants")
    Repo.query!("DROP FUNCTION participant_disconnect()")

    assert {:ok, %{record: %{"state" => "inactive"}, result: {:ok, _}}} =
             ConversationParticipantStore.settle_pending(context.store)

    assert {:ok, %{"state" => "inactive"}} =
             ConversationParticipantStore.update(context.store, & &1)

    refute_received :transition_ran
  end

  defp participant(context),
    do: %{
      "participant_id" => context.participant_id,
      "conversation_id" => context.conversation_id,
      "actor_type" => "provider",
      "provider" => "slack",
      "target_key" => "target",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "payload" => %{}
    }
end
