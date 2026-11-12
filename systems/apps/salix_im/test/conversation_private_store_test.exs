defmodule SalixIM.ConversationPrivateStoreTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_archive]

  use SalixAgent.TestSupport.Settle

  alias SalixIM.{
    ConversationInput,
    ConversationParticipantStore,
    ConversationPlacement,
    ConversationPGStore,
    ConversationServer,
    ConversationStore,
    Conversations
  }

  alias SalixStore.{Ids, Repo}

  defmodule LocalFileBinding do
    def bind_message(_group, _conversation, message, _now) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :conversation_binding_test_pid),
        {:local_file_bind, message}
      )

      if SystemsRuntime.get_env(:salix_im, :conversation_binding_test_fail, false),
        do: {:error, :local_file_registry_unavailable},
        else: :ok
    end
  end

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
       tenant_id: tenant_id,
       conversation_id: conversation_id,
       participant_id: participant["participant_id"]
     }}
  end

  test "a failed first Task binding rolls back metadata participants and message before a retry",
       context do
    binding_port!(true)

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        context.tenant_id,
        context.group_id,
        %{"name" => "Worker", "role" => "worker"}
      )

    conversation_id = Ids.new_conversation_id()
    scope = ConversationPGStore.new(context.group_id, conversation_id)

    spec = %{
      "conversation" => %{
        "title" => "Atomic first Task",
        "participants" => [
          %{"actor_type" => "user", "user_id" => "current", "state" => "active"},
          %{
            "actor_type" => "agent",
            "agent_id" => worker["agent_id"],
            "role_label" => "worker",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"}
          }
        ]
      },
      "worker_agent_id" => worker["agent_id"],
      "initial_message" => %{
        "actor_type" => "user",
        "user_id" => "current",
        "client_request_id" => "first-task",
        "content" => "First instruction"
      }
    }

    assert {:error, :local_file_registry_unavailable} =
             ConversationServer.create_task(context.group_id, conversation_id, spec)

    assert_received {:local_file_bind, first}

    assert {:error, :not_found} =
             Conversations.get_group_conversation_record(context.group_id, conversation_id)

    assert {:error, :not_found} = ConversationPGStore.read_creation(scope)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_participants WHERE group_id=$1 AND conversation_id=$2",
               [context.group_id, conversation_id]
             )

    assert {:error, :not_found} =
             ConversationPGStore.identity_by_request_identity(scope, first["request_identity"])

    SalixIM.TestSupport.Fleet.stop_all!()
    settle_after(20_000)
    SystemsRuntime.put_env(:salix_im, :conversation_binding_test_fail, false)

    assert {:ok, %{"message_id" => id, "seq" => 1}} =
             ConversationServer.create_task(context.group_id, conversation_id, spec)

    assert_received {:local_file_bind, second}
    assert second["message_id"] == id
    assert {:ok, published, _} = ConversationPGStore.read(scope)
    assert map_size(published["_participant_identity_slots"]) == 2
    assert {:ok, [message]} = ConversationPGStore.messages(scope, 1, 100, 100)
    assert message["message_id"] == id

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_participants WHERE group_id=$1 AND conversation_id=$2",
               [context.group_id, conversation_id]
             )
  end

  test "a PostgreSQL unknown blocks a later bind while reads and frozen settlement remain available",
       context do
    binding_port!(false)
    actor = conversation_actor(context)

    Repo.query!("""
    CREATE FUNCTION conversation_owner_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.conversation_id = '#{context.conversation_id}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER conversation_owner_disconnect BEFORE UPDATE ON salix_conversations FOR EACH ROW EXECUTE FUNCTION conversation_owner_disconnect()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS conversation_owner_disconnect ON salix_conversations")
      Repo.query!("DROP FUNCTION IF EXISTS conversation_owner_disconnect()")
    end)

    assert {:error, :commit_indeterminate} =
             ConversationServer.update_group_conversation(
               context.group_id,
               context.conversation_id,
               %{"title" => "Frozen update"}
             )

    assert :sys.get_state(actor, :infinity).commit_indeterminate?

    assert {:ok, %{"title" => "Private store boundary"}} =
             Conversations.get_group_conversation_record(
               context.group_id,
               context.conversation_id
             )

    attrs = %{"client_request_id" => "after-unknown", "content" => "Bind only after settlement"}

    assert {:error, :commit_indeterminate} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               attrs
             )

    refute_received {:local_file_bind, _}
    Repo.query!("DROP TRIGGER conversation_owner_disconnect ON salix_conversations")
    Repo.query!("DROP FUNCTION conversation_owner_disconnect()")
    settle_until(fn -> not :sys.get_state(actor, :infinity).commit_indeterminate? end)

    assert {:ok, %{"title" => "Frozen update"}} =
             Conversations.get_group_conversation_record(
               context.group_id,
               context.conversation_id
             )

    assert :sys.get_state(actor, :infinity).membership_load_error == nil

    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               attrs
             )

    assert_received {:local_file_bind, _}
  end

  test "a committed cold retry returns its identity without rebinding files or loading its body",
       context do
    binding_port!(false)
    attrs = %{"client_request_id" => "cold-retry", "content" => "Accepted content"}

    assert {:ok, %{"message_id" => id, "seq" => 1, "inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               attrs
             )

    assert_received {:local_file_bind, _}

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload = NULL, archive_first_seq = 1 WHERE group_id = $1 AND conversation_id = $2 AND seq = 1",
      [context.group_id, context.conversation_id]
    )

    assert {:ok, %{"message_id" => ^id, "seq" => 1, "inserted" => false}} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               attrs
             )

    refute_received {:local_file_bind, _}

    assert {:error, :archive_incomplete} =
             ConversationPGStore.message_by_id(
               ConversationPGStore.new(context.group_id, context.conversation_id),
               id
             )
  end

  @tag :archive_owner_chain
  test "archive publication clears hot bodies and preserves the public Conversation history",
       context do
    attrs = %{"client_request_id" => "archive-public", "content" => "Read this after hot cleanup"}

    assert {:ok, %{"message_id" => id}} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               attrs
             )

    assert {:ok, %{:first_seq => 1, :last_seq => 1}} =
             ConversationServer.archive_messages(context.group_id, context.conversation_id)

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT payload FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
               [context.group_id, context.conversation_id, id]
             )

    assert {:ok,
            [%{"message_id" => ^id, "content" => [%{"text" => "Read this after hot cleanup"}]}]} =
             Conversations.list_group_conversation_messages(
               context.group_id,
               context.conversation_id,
               limit: 10
             )
  end

  @tag :archive_owner_chain
  test "the archive worker flushes idle Message bodies through the owner after an unrelated metadata update",
       context do
    assert {:ok, %{"message_id" => id}} =
             ConversationServer.append_group_conversation_message(
               context.group_id,
               context.conversation_id,
               %{"client_request_id" => "archive-worker", "content" => "Scheduled history"}
             )

    settle_after(31_000)

    assert {:ok, _} =
             ConversationServer.update_group_conversation(
               context.group_id,
               context.conversation_id,
               %{"title" => "Metadata was just changed"}
             )

    scheduled_at = SystemsClock.system_time(:millisecond)
    start_supervised!(SalixIM.ConversationArchiveWorker)

    settle_until(fn ->
      Repo.query!(
        "SELECT payload IS NULL FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
        [context.group_id, context.conversation_id, id]
      ).rows == [[true]]
    end)

    assert SystemsClock.system_time(:millisecond) - scheduled_at == 1_000

    assert {:ok, [%{"message_id" => ^id, "content" => [%{"text" => "Scheduled history"}]}]} =
             Conversations.list_group_conversation_messages(
               context.group_id,
               context.conversation_id,
               limit: 10
             )
  end

  test "a first publication unknown survives owner restart and a rebuilt creation spec",
       context do
    binding_port!(false)

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        context.tenant_id,
        context.group_id,
        %{"name" => "Prepared Worker", "role" => "worker"}
      )

    id = Ids.new_conversation_id()
    now = SystemsClock.system_time(:millisecond)
    participant_time = %{"created_at" => now, "updated_at" => now}

    spec = %{
      "conversation" => %{
        "title" => "Prepared first publication",
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          Map.merge(participant_time, %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active"
          }),
          Map.merge(participant_time, %{
            "actor_type" => "agent",
            "agent_id" => worker["agent_id"],
            "role_label" => "worker",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"}
          })
        ]
      },
      "worker_agent_id" => worker["agent_id"],
      "initial_message" => %{
        "actor_type" => "user",
        "user_id" => "current",
        "client_request_id" => "prepared-first",
        "content" => "Prepared instruction"
      }
    }

    Repo.query!("""
    CREATE FUNCTION conversation_first_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.conversation_id = '#{id}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER conversation_first_disconnect BEFORE INSERT ON salix_conversation_messages FOR EACH ROW EXECUTE FUNCTION conversation_first_disconnect()"
    )

    on_exit(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS conversation_first_disconnect ON salix_conversation_messages"
      )

      Repo.query!("DROP FUNCTION IF EXISTS conversation_first_disconnect()")
    end)

    assert {:error, :commit_indeterminate} =
             ConversationServer.create_task(context.group_id, id, spec)

    assert_received {:local_file_bind, _first}

    assert {:error, :not_found} =
             ConversationPGStore.read_creation(ConversationPGStore.new(context.group_id, id))

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_participants WHERE group_id=$1 AND conversation_id=$2",
               [context.group_id, id]
             )

    SalixIM.TestSupport.Fleet.stop_all!()
    Repo.query!("DROP TRIGGER conversation_first_disconnect ON salix_conversation_messages")
    Repo.query!("DROP FUNCTION conversation_first_disconnect()")
    settle_after(20_000)

    assert {:ok, %{"message_id" => expected_id, "seq" => 1}} =
             ConversationServer.create_task(context.group_id, id, spec)

    assert {:ok, original_memberships} =
             SalixIM.ConversationParticipantProjection.list_bounded(context.group_id, id)

    SalixIM.TestSupport.Fleet.stop_all!()
    settle_after(20_000)
    rebuilt_at = SystemsClock.system_time(:millisecond)

    rebuilt =
      update_in(spec, ["conversation", "participants"], fn participants ->
        Enum.map(
          participants,
          &Map.merge(&1, %{"created_at" => rebuilt_at, "updated_at" => rebuilt_at})
        )
      end)

    assert {:ok, %{"message_id" => ^expected_id, "seq" => 1}} =
             ConversationServer.create_task(context.group_id, id, rebuilt)

    assert {:ok, ^original_memberships} =
             SalixIM.ConversationParticipantProjection.list_bounded(context.group_id, id)

    assert {:ok, [only]} =
             ConversationPGStore.messages(
               ConversationPGStore.new(context.group_id, id),
               1,
               100,
               100
             )

    assert only["message_id"] == expected_id
  end

  defp binding_port!(fail?) do
    overrides = [
      local_file_refs_mod: LocalFileBinding,
      conversation_binding_test_pid: SystemsRuntime.Proc.self(),
      conversation_binding_test_fail: fail?
    ]

    previous =
      for {key, value} <- overrides do
        old = SystemsRuntime.get_env(:salix_im, key)
        SystemsRuntime.put_env(:salix_im, key, value)
        {key, old}
      end

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- previous, do: restore(:salix_im, key, value)
    end)
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
             conversation_id: ^conversation_id
           } = :sys.get_state(conversation_store, :infinity)

    assert is_reference(owner_ref)

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
             scope: participant_scope
           } = :sys.get_state(participant_store, :infinity)

    assert is_reference(participant_owner_ref)

    assert participant_scope.group_id == context.group_id
    assert participant_scope.conversation_id == context.conversation_id
    assert participant_scope.participant_id == context.participant_id

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
