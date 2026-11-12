defmodule SalixIM.ConversationPGStoreTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationMessage, ConversationPGStore}
  alias SalixStore.{Ids, Repo}

  setup do
    group = Ids.new_group_id(Ids.new_tenant_id())
    scope = ConversationPGStore.new(group, Ids.new_conversation_id())

    on_exit(fn ->
      Repo.query!("DELETE FROM conversation_search_jobs WHERE agent_group_id = $1", [group])
      Repo.query!("DELETE FROM conversation_log_recovery WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM salix_conversation_messages WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM salix_conversation_deliveries WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM salix_conversation_participants WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM local_file_refs WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM salix_conversations WHERE group_id = $1", [group])
    end)

    {:ok, scope: scope}
  end

  test "a public reservation stays unpublished until append and preserves its first identity", %{
    scope: scope
  } do
    input = message("public reserve", "reserved")
    assert {:error, :not_found} = ConversationPGStore.reserve(scope, input)
    create!(scope)
    assert {:ok, :reserved, before, identity, 1} = ConversationPGStore.reserve(scope, input)
    assert before["message_tail_seq"] == 0
    assert {:ok, []} = ConversationPGStore.messages(scope, 1, 100, 100)

    retry = %{
      input
      | "message_id" => Ids.new_message_id(),
        "created_at" => input["created_at"] + 50
    }

    assert {:ok, :inserted, _, published, _} = ConversationPGStore.append(scope, 1, retry)
    assert published["message_id"] == identity["message_id"]
    assert published["seq"] == 1
    assert {:ok, body} = ConversationPGStore.message_by_id(scope, identity["message_id"])
    assert body["created_at"] == input["created_at"]
  end

  test "metadata derives owner scope and updates only the expected revision", %{scope: scope} do
    assert {:ok, :inserted, original, 1} =
             ConversationPGStore.create(scope, %{
               "kind" => "agent_task",
               "title" => "Before",
               "updated_at" => 1_000,
               "agent_group_id" => "forged",
               "conversation_id" => "forged",
               "participant_count" => 88,
               "source_refs" => %{"task" => "kept"}
             })

    assert original["agent_group_id"] == scope.group_id
    assert original["conversation_id"] == scope.conversation_id
    refute Map.has_key?(original, "participant_count")
    assert {:ok, ^original, 1} = ConversationPGStore.read(scope)
    assert {:error, :precondition_failed} = ConversationPGStore.create(scope, original)

    assert {:ok, ^original, updated, 2} =
             ConversationPGStore.update(scope, 1, &Map.put(&1, "title", "After"))

    assert updated["title"] == "After"
    assert updated["source_refs"] == original["source_refs"]

    assert {:error, :precondition_failed} =
             ConversationPGStore.update(scope, 1, &Map.put(&1, "title", "Stale"))

    assert {:ok, ^updated, 2} = ConversationPGStore.read(scope)
  end

  test "the inserted Message matches the reader when optional identity fields are absent", %{
    scope: scope
  } do
    create!(scope)

    input =
      message(nil, "No request identity")
      |> Map.drop(~w(request_identity request_fingerprint client_request_id))

    assert {:ok, :inserted, _, %{appended_message: message}, 2} =
             ConversationPGStore.append(scope, 1, input)

    assert {:ok, ^message} = ConversationPGStore.message_by_id(scope, input["message_id"])
    assert Map.fetch!(message, "request_identity") == nil
    assert Map.fetch!(message, "request_fingerprint") == nil
  end

  test "append publishes tail and exact identities together and preserves the first request", %{
    scope: scope
  } do
    create!(scope)
    first = message("request-a", "first")
    assert {:ok, :inserted, conversation, stored, 2} = ConversationPGStore.append(scope, 1, first)
    assert stored["seq"] == 1
    assert conversation["message_tail_seq"] == 1
    assert conversation["message_head_seq"] == 1
    assert {:ok, body} = ConversationPGStore.message_by_id(scope, first["message_id"])
    assert body == Map.put(first, "seq", 1)
    assert stored[:appended_message] == body
    stored = Map.delete(stored, :appended_message)
    assert {:ok, ^body} = ConversationPGStore.message_by_seq(scope, 1)

    assert {:ok, ^body} =
             ConversationPGStore.message_by_request_identity(scope, first["request_identity"])

    assert {:ok, ^stored} =
             ConversationPGStore.identity_by_request_identity(scope, first["request_identity"])

    retry = %{first | "message_id" => Ids.new_message_id(), "created_at" => 50_000}
    assert {:ok, :exists, ^conversation, ^stored, 2} = ConversationPGStore.append(scope, 1, retry)

    assert {:error, :idempotency_conflict} =
             ConversationPGStore.append(scope, 2, message("request-a", "changed"))

    assert {:error, :message_id_collision} =
             ConversationPGStore.append(scope, 2, %{
               message("other-request", "other")
               | "message_id" => first["message_id"]
             })

    assert {:error, :precondition_failed} =
             ConversationPGStore.append(scope, 1, message("new", "new"))

    assert {:ok, :inserted, next, second, 3} =
             ConversationPGStore.append(scope, 2, message("new", "new"))

    assert second["seq"] == 2
    assert next["message_tail_seq"] == 2
  end

  test "first message and Conversation creation commit or roll back together", %{scope: scope} do
    input = message("first", "first message")
    constraint = "conversation_pg_first_message_rollback"

    Repo.query!(
      "ALTER TABLE salix_conversation_messages ADD CONSTRAINT " <>
        constraint <> " CHECK (message_id <> '" <> input["message_id"] <> "') NOT VALID"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE salix_conversation_messages DROP CONSTRAINT IF EXISTS " <> constraint
      )
    end)

    record = %{"kind" => "agent_task", "title" => "First"}
    pending = ConversationPGStore.prepare_create_with_message(scope, record, input)
    assert {:error, {:rollback, :check_violation}} = ConversationPGStore.execute(pending)
    assert {:error, :not_found} = ConversationPGStore.read(scope)
    assert {:error, :not_found} = ConversationPGStore.identity_by_id(scope, input["message_id"])
    Repo.query!("ALTER TABLE salix_conversation_messages DROP CONSTRAINT " <> constraint)

    assert {:ok, :inserted, conversation, identity, 1} = ConversationPGStore.execute(pending)
    assert conversation["message_tail_seq"] == 1
    assert identity["seq"] == 1
    identity = Map.delete(identity, :appended_message)
    assert {:ok, :exists, ^conversation, ^identity, 1} = ConversationPGStore.settle(pending)

    assert {:ok, ^conversation} =
             SalixIM.Conversations.get_group_conversation_record(
               scope.group_id,
               scope.conversation_id
             )

    assert {:ok, [body]} = ConversationPGStore.messages(scope, 1, 1, 100)
    assert body["message_id"] == input["message_id"]

    assert {:ok, :reserved, _, _, 1} =
             ConversationPGStore.reserve(scope, message("later", "reserved"))

    assert {:ok, [^body]} = ConversationPGStore.messages(scope, 1, 1_000, 100)

    assert {:ok, %{"messages" => [public], "covered" => %{"first_seq" => 1, "last_seq" => 1}}} =
             SalixIM.Conversations.list_group_conversation_message_page(
               scope.group_id,
               scope.conversation_id
             )

    assert public["message_id"] == input["message_id"]
  end

  test "request identity is scoped to its Conversation and absent identities can repeat", %{
    scope: scope
  } do
    other = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
    create!(scope)
    create!(other)
    input = message("shared", "same")
    assert {:ok, :inserted, _, _, 2} = ConversationPGStore.append(scope, 1, input)
    assert {:ok, :inserted, _, _, 2} = ConversationPGStore.append(other, 1, input)

    assert {:error, :not_found} =
             ConversationPGStore.message_by_id(
               ConversationPGStore.new("other-group", scope.conversation_id),
               input["message_id"]
             )

    assert {:ok, :inserted, _, _, 3} =
             ConversationPGStore.append(
               scope,
               2,
               Map.put(message("x", "no request"), "request_identity", "")
             )

    assert {:ok, :inserted, _, _, 4} =
             ConversationPGStore.append(
               scope,
               3,
               Map.put(message("y", "no request"), "request_identity", nil)
             )
  end

  test "reservation survives a failed append and publishes its original identity and time once",
       %{
         scope: scope
       } do
    create!(scope)
    input = message("reserved", "bind then append")
    assert {:ok, :reserved, original, identity, 1} = ConversationPGStore.reserve(scope, input)
    assert identity["seq"] == nil
    assert original["message_tail_seq"] == 0
    assert original["target_message_count"] == 0

    assert %{rows: [[0, 0]]} =
             Repo.query!(
               "SELECT target_seq, membership_revision FROM conversation_log_recovery WHERE group_id = $1 AND conversation_id = $2",
               [scope.group_id, scope.conversation_id]
             )

    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, input["message_id"])

    assert {:error, :not_found} =
             ConversationPGStore.message_by_request_identity(scope, input["request_identity"])

    assert %{rows: [[payload]]} =
             Repo.query!(
               "SELECT payload FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2",
               [scope.group_id, scope.conversation_id]
             )

    assert :erlang.binary_to_term(payload) == %{"created_at" => input["created_at"]}

    assert {:ok, :reserved, ^original, _, 1} =
             ConversationPGStore.reserve(scope, message("second reservation", "not published"))

    constraint = "conversation_pg_reservation_rollback"

    Repo.query!(
      "ALTER TABLE salix_conversations ADD CONSTRAINT " <>
        constraint <>
        " CHECK (conversation_id <> '" <>
        scope.conversation_id <> "' OR message_tail_seq = 0) NOT VALID"
    )

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT IF EXISTS " <> constraint)
    end)

    retry = %{input | "message_id" => Ids.new_message_id(), "created_at" => 50_000}
    assert {:ok, :exists, ^original, ^identity, 1} = ConversationPGStore.reserve(scope, retry)
    assert {:error, {:rollback, :check_violation}} = ConversationPGStore.append(scope, 1, retry)
    assert {:ok, ^identity} = ConversationPGStore.identity_by_id(scope, input["message_id"])
    assert {:ok, ^original, 1} = ConversationPGStore.read(scope)
    Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT " <> constraint)

    assert {:ok, :inserted, %{"message_tail_seq" => 1}, published, 2} =
             ConversationPGStore.append(scope, 1, retry)

    assert published["message_id"] == input["message_id"]
    assert {:ok, body} = ConversationPGStore.message_by_seq(scope, 1)
    assert body["created_at"] == input["created_at"]
    assert body["message_id"] == input["message_id"]
    assert published[:appended_message] == body
    published = Map.delete(published, :appended_message)
    assert {:ok, :exists, _, ^published, 2} = ConversationPGStore.append(scope, 1, retry)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_messages WHERE group_id = $1 AND conversation_id = $2",
               [scope.group_id, scope.conversation_id]
             )
  end

  test "lost reservation replies settle before or after publication without reading a cold body",
       %{
         scope: scope
       } do
    create!(scope)
    input = message("reserve lost reply", "accepted")
    assert {:ok, pending} = ConversationPGStore.prepare_reserve(scope, input)
    ConversationPGStore.execute(pending)
    assert {:ok, :exists, _, %{"seq" => nil}, 1} = ConversationPGStore.settle(pending)
    assert {:ok, :inserted, _, published, 2} = ConversationPGStore.append(scope, 1, input)

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload = NULL, archive_first_seq = 1 " <>
        "WHERE group_id = $1 AND conversation_id = $2 AND seq = 1",
      [scope.group_id, scope.conversation_id]
    )

    assert {:ok, :exists, _, cold, 2} = ConversationPGStore.settle(pending)
    assert cold["message_id"] == published["message_id"]
    assert {:ok, :exists, _, ^cold, 2} = ConversationPGStore.reserve(scope, input)

    assert {:error, :idempotency_conflict} =
             ConversationPGStore.reserve(scope, message("reserve lost reply", "changed"))
  end

  test "a database failure after inserting a message rolls back both message and tail", %{
    scope: scope
  } do
    create!(scope)
    constraint = "conversation_pg_append_rollback"

    Repo.query!(
      "ALTER TABLE salix_conversations ADD CONSTRAINT " <>
        constraint <>
        " CHECK (conversation_id <> '" <>
        scope.conversation_id <> "' OR message_tail_seq = 0) NOT VALID"
    )

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT IF EXISTS " <> constraint)
    end)

    input = message("rollback", "must roll back")

    assert {:error, {:rollback, :check_violation}} =
             ConversationPGStore.append(scope, 1, input)

    assert {:ok, %{"message_tail_seq" => 0}, 1} = ConversationPGStore.read(scope)
    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, input["message_id"])

    Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT " <> constraint)

    assert {:ok, :inserted, %{"message_tail_seq" => 1}, %{"seq" => 1}, 2} =
             ConversationPGStore.append(scope, 1, input)
  end

  test "a tombstone hides its old payload and a retry cannot create a replacement", %{
    scope: scope
  } do
    create!(scope)
    input = message("deleted", "original")
    assert {:ok, :inserted, _, _, 2} = ConversationPGStore.append(scope, 1, input)

    Repo.query!(
      "UPDATE salix_conversation_messages SET tombstone = true, revision = revision + 1 " <>
        "WHERE group_id = $1 AND conversation_id = $2 AND seq = 1",
      [scope.group_id, scope.conversation_id]
    )

    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, input["message_id"])
    assert {:error, :not_found} = ConversationPGStore.message_by_seq(scope, 1)

    assert {:error, :not_found} =
             ConversationPGStore.message_by_request_identity(scope, input["request_identity"])

    assert {:ok, :exists, _, %{"tombstone" => true}, 2} =
             ConversationPGStore.append(scope, 2, input)

    assert {:ok, %{"message_tail_seq" => 1}, 2} = ConversationPGStore.read(scope)
  end

  test "request identity survives cold body cleanup and later edits keep the accepted fingerprint",
       %{scope: scope} do
    create!(scope)
    input = message("cold", "original accepted request")
    assert {:ok, :inserted, _, stored, 2} = ConversationPGStore.append(scope, 1, input)

    edited = %{
      input
      | "content" => [%{"type" => "text", "text" => "edited"}],
        "request_fingerprint" => "not the accepted fingerprint"
    }

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload = $3, revision = revision + 1 " <>
        "WHERE group_id = $1 AND conversation_id = $2 AND seq = 1",
      [scope.group_id, scope.conversation_id, :erlang.term_to_binary(edited)]
    )

    assert {:ok, body} = ConversationPGStore.message_by_id(scope, input["message_id"])
    assert body["content"] == edited["content"]
    assert body["request_fingerprint"] == input["request_fingerprint"]

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload = NULL, archive_first_seq = 1 " <>
        "WHERE group_id = $1 AND conversation_id = $2 AND seq = 1",
      [scope.group_id, scope.conversation_id]
    )

    assert {:ok, identity} =
             ConversationPGStore.identity_by_request_identity(scope, input["request_identity"])

    assert identity["request_fingerprint"] == stored["request_fingerprint"]
    assert identity["message_id"] == stored["message_id"]

    assert {:error, :archive_incomplete} =
             ConversationPGStore.message_by_request_identity(scope, input["request_identity"])

    assert {:ok, :exists, _, ^identity, 2} = ConversationPGStore.append(scope, 2, input)

    assert {:error, :idempotency_conflict} =
             ConversationPGStore.append(scope, 2, message("cold", "changed"))

    assert {:ok, %{"message_tail_seq" => 1}, 2} = ConversationPGStore.read(scope)
  end

  test "settlement confirms lost replies without rerunning a metadata transform", %{scope: scope} do
    create!(scope)
    parent = SystemsRuntime.Proc.self()

    assert {:ok, pending} =
             ConversationPGStore.prepare_update(scope, 1, fn record ->
               SystemsRuntime.Proc.send(parent, :metadata_transformed)
               Map.put(record, "title", "once")
             end)

    assert_received :metadata_transformed

    # PG committed; the owner never received the success reply.
    ConversationPGStore.execute(pending)
    assert {:ok, _, %{"title" => "once"}, 2} = ConversationPGStore.settle(pending)
    assert {:ok, _, %{"title" => "once"}, 2} = ConversationPGStore.settle(pending)
    refute_received :metadata_transformed

    assert {:ok, _, _, 3} = ConversationPGStore.update(scope, 2, &Map.put(&1, "title", "newer"))
    assert {:error, :precondition_failed} = ConversationPGStore.settle(pending)
    assert {:ok, %{"title" => "newer"}, 3} = ConversationPGStore.read(scope)
  end

  test "lost append replies settle through durable identity even after a newer revision", %{
    scope: scope
  } do
    create!(scope)
    input = message("lost append", "accepted once")
    assert {:ok, pending} = ConversationPGStore.prepare_append(scope, 1, input)
    ConversationPGStore.execute(pending)
    assert {:ok, _, _, 3} = ConversationPGStore.update(scope, 2, &Map.put(&1, "title", "newer"))

    assert {:ok, :exists, %{"title" => "newer"}, %{"seq" => 1}, 3} =
             ConversationPGStore.settle(pending)

    assert {:ok, %{"message_tail_seq" => 1}, 3} = ConversationPGStore.read(scope)
  end

  test "a lost database connection retains the frozen candidate for settlement", %{scope: scope} do
    create!(scope)
    input = message("connection lost", "once")
    assert {:ok, :reserved, _, _, 1} = ConversationPGStore.reserve(scope, input)

    assert {:ok, pending} =
             ConversationPGStore.prepare_append(scope, 1, input)

    Repo.query!("""
    CREATE FUNCTION conversation_pg_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.conversation_id = '#{scope.conversation_id}' AND NEW.message_tail_seq = 1 THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER conversation_pg_disconnect BEFORE UPDATE ON salix_conversations FOR EACH ROW EXECUTE FUNCTION conversation_pg_disconnect()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS conversation_pg_disconnect ON salix_conversations")
      Repo.query!("DROP FUNCTION IF EXISTS conversation_pg_disconnect()")
    end)

    assert {:error, :commit_indeterminate} = ConversationPGStore.execute(pending)
    Repo.query!("DROP TRIGGER conversation_pg_disconnect ON salix_conversations")
    Repo.query!("DROP FUNCTION conversation_pg_disconnect()")

    assert {:ok, :inserted, %{"message_tail_seq" => 1}, %{"seq" => 1}, 2} =
             ConversationPGStore.settle(pending)

    assert {:ok, :exists, _, %{"seq" => 1}, 2} = ConversationPGStore.settle(pending)
  end

  test "a disconnected reservation retries its frozen message identity", %{scope: scope} do
    create!(scope)
    input = message("reserve disconnected", "once")
    assert {:ok, pending} = ConversationPGStore.prepare_reserve(scope, input)

    Repo.query!("""
    CREATE FUNCTION conversation_pg_reserve_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.conversation_id = '#{scope.conversation_id}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER conversation_pg_reserve_disconnect BEFORE INSERT ON salix_conversation_messages FOR EACH ROW EXECUTE FUNCTION conversation_pg_reserve_disconnect()"
    )

    on_exit(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS conversation_pg_reserve_disconnect ON salix_conversation_messages"
      )

      Repo.query!("DROP FUNCTION IF EXISTS conversation_pg_reserve_disconnect()")
    end)

    assert {:error, :commit_indeterminate} = ConversationPGStore.execute(pending)
    Repo.query!("DROP TRIGGER conversation_pg_reserve_disconnect ON salix_conversation_messages")
    Repo.query!("DROP FUNCTION conversation_pg_reserve_disconnect()")

    assert {:ok, :reserved, %{"message_tail_seq" => 0}, identity, 1} =
             ConversationPGStore.settle(pending)

    assert identity["message_id"] == input["message_id"]
    assert {:ok, :exists, _, ^identity, 1} = ConversationPGStore.settle(pending)
  end

  test "concurrent retries commit one canonical message", %{scope: scope} do
    create!(scope)
    input = message("concurrent", "first accepted")

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          ConversationPGStore.append(scope, 1, %{input | "message_id" => Ids.new_message_id()})
        end,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, :inserted, _, _, 2}, &1)) == 1
    assert Enum.count(results, &match?({:ok, :exists, _, _, 2}, &1)) == 3

    assert results
           |> Enum.map(fn {:ok, _, _, message, _} -> Map.delete(message, :appended_message) end)
           |> Enum.uniq()
           |> length() == 1

    assert {:ok, %{"message_tail_seq" => 1}, 2} = ConversationPGStore.read(scope)
  end

  test "first publication and ref binding roll back all initial facts together", %{scope: scope} do
    {input, ref} = local_message!(scope)

    participant = %{
      "participant_id" => Ids.new_participant_id(),
      "actor_type" => "user",
      "user_id" => "current",
      "state" => "active"
    }

    record = %{"kind" => "agent_task", "participants" => [participant]}
    pending = ConversationPGStore.prepare_create_with_message(scope, record, input)

    Repo.query!(
      "ALTER TABLE salix_conversation_messages ADD CONSTRAINT atomic_ref_reject CHECK (message_id <> '#{input["message_id"]}') NOT VALID"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE salix_conversation_messages DROP CONSTRAINT IF EXISTS atomic_ref_reject"
      )
    end)

    assert {:error, {:rollback, :check_violation}} = ConversationPGStore.execute(pending)
    assert {:error, :not_found} = ConversationPGStore.read(scope)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_participants WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )

    assert {:ok, %{"state" => "registered"}} = SalixStore.LocalFileRefs.get(ref)
    Repo.query!("ALTER TABLE salix_conversation_messages DROP CONSTRAINT atomic_ref_reject")
    assert {:ok, :inserted, _, identity, 1} = ConversationPGStore.execute(pending)
    assert identity["message_id"] == input["message_id"]
    assert {:ok, %{"state" => "bound", "message_id" => id}} = SalixStore.LocalFileRefs.get(ref)
    assert id == identity["message_id"]
    identity = Map.delete(identity, :appended_message)

    assert {:ok, [_]} =
             SalixIM.ConversationParticipantPGStore.page(
               scope.group_id,
               scope.conversation_id,
               "",
               10
             )

    assert {:ok, :exists, _, ^identity, 1} = ConversationPGStore.settle(pending)
  end

  test "ordinary append commits all refs and its search target together, and committed retry never rebinds",
       %{scope: scope} do
    previous_generation =
      SystemsRuntime.get_env(:salix_store, :conversation_search_writer_generation)

    SystemsRuntime.put_env(
      :salix_store,
      :conversation_search_writer_generation,
      "test-search-generation"
    )

    on_exit(fn ->
      if is_nil(previous_generation),
        do: SystemsRuntime.delete_env(:salix_store, :conversation_search_writer_generation),
        else:
          SystemsRuntime.put_env(
            :salix_store,
            :conversation_search_writer_generation,
            previous_generation
          )
    end)

    create!(scope)
    {first, ref1} = local_message!(scope)
    {second, ref2} = local_message!(scope)
    input = Map.put(first, "content", first["content"] ++ second["content"])
    input = Map.put(input, "request_fingerprint", ConversationMessage.request_fingerprint(input))

    Repo.query!(
      "ALTER TABLE conversation_search_jobs ADD CONSTRAINT atomic_search_reject CHECK (conversation_id <> '#{scope.conversation_id}') NOT VALID"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE conversation_search_jobs DROP CONSTRAINT IF EXISTS atomic_search_reject"
      )
    end)

    assert {:error, {:rollback, :check_violation}} =
             ConversationPGStore.append(scope, 1, input)

    for ref <- [ref1, ref2],
        do: assert({:ok, %{"state" => "registered"}} = SalixStore.LocalFileRefs.get(ref))

    assert {:ok, %{"message_tail_seq" => 0}, 1} = ConversationPGStore.read(scope)
    assert {:error, :not_found} = ConversationPGStore.identity_by_id(scope, input["message_id"])
    Repo.query!("ALTER TABLE conversation_search_jobs DROP CONSTRAINT atomic_search_reject")
    assert {:ok, :inserted, _, identity, 2} = ConversationPGStore.append(scope, 1, input)

    for ref <- [ref1, ref2] do
      assert {:ok, %{"state" => "bound", "message_id" => id}} = SalixStore.LocalFileRefs.get(ref)
      assert id == identity["message_id"]

      assert :ok =
               SalixStore.LocalFileRefs.revoke(
                 ref,
                 scope.group_id,
                 "current",
                 "device",
                 SystemsClock.system_time(:millisecond)
               )
    end

    assert %{rows: [["rebuild", generation]]} =
             Repo.query!(
               "SELECT operation, generation FROM conversation_search_jobs WHERE agent_group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )

    retry = Map.put(input, "message_id", Ids.new_message_id())
    identity = Map.delete(identity, :appended_message)
    assert {:ok, :exists, _, ^identity, 2} = ConversationPGStore.append(scope, 1, retry)

    assert %{rows: [[^generation]]} =
             Repo.query!(
               "SELECT generation FROM conversation_search_jobs WHERE agent_group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )
  end

  test "an unknown rolled-back ref admission cannot use an expired registration on retry", %{
    scope: scope
  } do
    create!(scope)
    {input, ref} = local_message!(scope)
    assert {:ok, pending} = ConversationPGStore.prepare_append(scope, 1, input)

    Repo.query!("""
    CREATE FUNCTION atomic_ref_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.message_id = '#{input["message_id"]}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER atomic_ref_disconnect BEFORE INSERT ON salix_conversation_messages FOR EACH ROW EXECUTE FUNCTION atomic_ref_disconnect()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS atomic_ref_disconnect ON salix_conversation_messages")
      Repo.query!("DROP FUNCTION IF EXISTS atomic_ref_disconnect()")
    end)

    assert {:error, :commit_indeterminate} = ConversationPGStore.execute(pending)
    assert {:ok, %{"state" => "registered"}} = SalixStore.LocalFileRefs.get(ref)
    SystemsClock.advance(2_000)
    Repo.query!("DROP TRIGGER atomic_ref_disconnect ON salix_conversation_messages")
    Repo.query!("DROP FUNCTION atomic_ref_disconnect()")
    assert {:error, :local_file_unavailable} = ConversationPGStore.settle(pending)
    assert {:ok, %{"message_tail_seq" => 0}, 1} = ConversationPGStore.read(scope)
    assert {:error, :not_found} = ConversationPGStore.identity_by_id(scope, input["message_id"])
  end

  defp local_message!(scope) do
    previous = SystemsRuntime.get_env(:salix_im, :local_file_refs_mod)
    SystemsRuntime.put_env(:salix_im, :local_file_refs_mod, SalixEnv.LocalFileRefs)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_im, :local_file_refs_mod),
        else: SystemsRuntime.put_env(:salix_im, :local_file_refs_mod, previous)
    end)

    ref = "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, _} =
             SalixStore.LocalFileRefs.insert_registration(%{
               "local_file_ref" => ref,
               "tenant_id" => Ids.tenant_id_from_group!(scope.group_id),
               "group_id" => scope.group_id,
               "owner_user_id" => "current",
               "stable_device_id" => "device",
               "version" => 1,
               "state" => "registered",
               "created_at" => now,
               "expires_at" => now + 1_000
             })

    input =
      ConversationMessage.build(
        %{
          "kind" => "message",
          "actor_type" => "user",
          "user_id" => "current",
          "client_request_id" => "atomic-local",
          "content" => [%{"type" => "local_file", "local_file_ref" => ref}]
        },
        %{"user_id" => "current", "actor_type" => "user"},
        now
      )

    {input, ref}
  end

  defp create!(scope) do
    assert {:ok, :inserted, _, 1} =
             ConversationPGStore.create(scope, %{"kind" => "agent_task", "title" => "Task"})
  end

  defp message(request, content) do
    attrs = %{
      "kind" => "message",
      "actor_type" => "user",
      "client_request_id" => request,
      "content" => [%{"type" => "text", "text" => content}]
    }

    ConversationMessage.build(attrs, %{}, 1_000)
  end
end
