defmodule SalixIM.PGImportTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationCreateRequests, ConversationMessage, ConversationPGStore, PGImport}
  alias SalixIM.ConversationParticipantPGStore, as: ParticipantPG
  alias SalixStore.{Crypto, Ids, Keys, PGAuthorityImport, Repo, S3}

  @marker "salix_pg_authority_c_v1"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    # This offline fixture owns the old recovery source as well as the fake bucket.
    Repo.query!("DELETE FROM conversation_log_recovery")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name=$1", [@marker])

    scope =
      ConversationPGStore.new(Ids.new_group_id(Ids.new_tenant_id()), Ids.new_conversation_id())

    on_exit(fn ->
      Repo.query!("DELETE FROM salix_conversation_deliveries WHERE group_id=$1", [scope.group_id])

      Repo.query!("DELETE FROM salix_conversation_participants WHERE group_id=$1", [
        scope.group_id
      ])

      Repo.query!("DELETE FROM salix_conversation_archives WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_conversation_messages WHERE group_id=$1", [scope.group_id])

      Repo.query!("DELETE FROM salix_conversation_create_requests WHERE group_id=$1", [
        scope.group_id
      ])

      Repo.query!("DELETE FROM conversation_log_recovery WHERE group_id=$1", [scope.group_id])

      Repo.query!("DELETE FROM conversation_search_jobs WHERE agent_group_id=$1", [scope.group_id])

      Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_cutover_markers WHERE name=$1", [@marker])

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    {:ok, scope: scope}
  end

  @tag :scan_fusion
  test "bounded source pages preserve publication, reservations, opaque members and provider unknown",
       %{scope: scope} do
    opaque = "provider member / opaque:old"
    meta = metadata(scope, 2)
    meta = Map.put(meta, "_participant_identity_slots", %{"worker" => opaque})
    meta_key = put_meta!(scope, meta)
    first = message(1, "cold")
    second = message(2, "hot")
    {first_key, original} = put_segment!(scope, [first], "sealed")
    put_segment!(scope, [second], "open")

    reservation = %{
      "status" => "reserved",
      "message_id" => Ids.new_message_id(),
      "request_identity" => "original reservation",
      "request_fingerprint" => "accepted fingerprint",
      "created_at" => 777
    }

    reservation_key = put_pointer!(scope, reservation, :request)

    participant = %{
      "conversation_id" => scope.conversation_id,
      "participant_id" => opaque,
      "actor_type" => "agent",
      "agent_id" => "worker",
      "state" => "inactive",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "source_start_seq" => 1,
      "delivery_log_cursor_seq" => 1,
      "payload" => %{
        "session_id" => "original session",
        "task_thread_binding_token" => "incarnation"
      },
      "task_thread_delivery_fence" => %{"fence_token" => "fence", "cutoff_seq" => 2}
    }

    participant_key =
      Keys.ctl_group_conversation_participant_state(scope.group_id, scope.conversation_id, opaque)

    put_json!(participant_key, participant)

    legacy_key =
      Keys.ctl_group_conversation_participant_dir(scope.group_id, scope.conversation_id, opaque) <>
        "state.json"

    put_json!(legacy_key, Map.put(participant, "state", "historical legacy value"))

    receipt = %{
      "agent_group_id" => scope.group_id,
      "conversation_id" => scope.conversation_id,
      "participant_id" => opaque,
      "delivery_id" => "original delivery:opaque",
      "status" => "unknown",
      "attempt_id" => "attempt",
      "provider_message_id" => "provider receipt",
      "binding_token" => "incarnation",
      "fence_token" => "fence",
      "created_at" => 555
    }

    receipt_key =
      Keys.ctl_group_conversation_participant_delivery_state(
        scope.group_id,
        scope.conversation_id,
        opaque,
        receipt["delivery_id"]
      )

    put_json!(receipt_key, receipt)

    binding = %{
      "version" => 1,
      "group_id" => scope.group_id,
      "request_identity" => "create request",
      "request_fingerprint" => "original creation",
      "conversation_id" => Ids.new_conversation_id(),
      "created_at" => 333,
      "task_placement" => %{"runs_on" => %{"station_id" => "pinned"}, "session_model" => "model"}
    }

    binding_key =
      Keys.ctl_group_conversation_create_request(
        scope.group_id,
        Crypto.hex(binding["request_identity"])
      )

    put_json!(binding_key, binding)

    complete =
      PGImport.with_context(fn context ->
        assert {:ok, progress} = PGImport.run(Keyword.merge(context, page_size: 2, max_pages: 1))
        assert progress.phase == "importing"

        assert {:ok, %{phase: "complete"} = complete} =
                 PGImport.run(Keyword.merge(context, page_size: 2, max_pages: 1_000))

        complete
      end)

    assert complete.stats["list_requests"] ==
             Enum.count(S3.Fake.read_log(), &match?({:list, _, _}, &1))

    assert complete.stats["listed_objects"] > 0

    root = "ctl/group_conversations/"
    source_objects = Enum.count(S3.Fake.dump(), fn {key, _} -> String.starts_with?(key, root) end)
    root_lists = Enum.count(S3.Fake.read_log(), &match?({:list, ^root, _}, &1))

    assert root_lists == div(source_objects + 1, 2),
           "root LIST requests: #{root_lists}; source objects: #{source_objects}; expected one enumeration"

    assert {:ok, imported, 1} = ConversationPGStore.read(scope)

    assert Map.take(
             imported,
             ~w(message_tail_seq message_head_seq log_start_seq provider_status_version membership_revision _participant_identity_slots created_at)
           ) ==
             Map.take(
               meta,
               ~w(message_tail_seq message_head_seq log_start_seq provider_status_version membership_revision _participant_identity_slots created_at)
             )

    refute Map.has_key?(imported, "participant_count")
    assert {:ok, [^first, ^second]} = ConversationPGStore.messages(scope, 1, 2, 2)

    assert %{rows: [[nil, 1], [hot, nil], [reserved, nil]]} =
             Repo.query!(
               "SELECT payload,archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 ORDER BY seq NULLS LAST",
               [scope.group_id]
             )

    assert :erlang.binary_to_term(hot, [:safe]) == second
    assert :erlang.binary_to_term(reserved, [:safe]) == %{"created_at" => 777}

    assert {:ok, identity} =
             ConversationPGStore.identity_by_request_identity(
               scope,
               reservation["request_identity"]
             )

    assert identity["message_id"] == reservation["message_id"]
    assert identity["seq"] == nil
    participant_scope = ParticipantPG.new(scope.group_id, scope.conversation_id, opaque)
    assert {:ok, ^participant, 1} = ParticipantPG.read(participant_scope)

    assert {:ok, ^receipt, 1} =
             ParticipantPG.read_delivery(participant_scope, receipt["delivery_id"])

    assert {:ok, imported_binding} =
             ConversationCreateRequests.read(scope.group_id, binding["request_identity"])

    assert Map.take(imported_binding, Map.keys(binding)) == binding

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM conversation_log_recovery WHERE group_id=$1", [
               scope.group_id
             ])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_jobs WHERE agent_group_id=$1",
               [scope.group_id]
             )

    assert {:ok, %{body: ^original}} = S3.get(first_key)

    for key <- [meta_key, reservation_key, participant_key, legacy_key, receipt_key, binding_key],
        do: assert({:ok, _} = S3.get(key))

    assert {:ok, ^complete} = PGImport.step(page_size: 1)
  end

  @tag :scan_fusion
  test "messages resume across pages without rereading the committed source metadata",
       %{scope: scope} do
    meta_key = put_meta!(scope, metadata(scope, 2))
    first = message(1, "first")
    second = message(2, "second")
    {first_key, _} = put_segment!(scope, [first], "open")
    {second_key, second_body} = put_segment!(scope, [second], "open")
    put_pointer!(scope, pointer(first), :request)
    put_pointer!(scope, pointer(second), :request)
    assert {:ok, _} = S3.put(second_key, "invalid segment")
    S3.Fake.reset_read_log()

    before =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        assert {:ok, progress} = PGImport.step(page_size: 1)

        if progress.cursor["phase"] == "messages_fused" and
             progress.cursor["last_object"] == first_key,
           do: {:halt, progress},
           else: {:cont, progress}
      end)

    assert before.cursor["phase"] == "messages_fused"
    assert {:ok, ^first} = ConversationPGStore.message_by_id(scope, first["message_id"])

    assert {:error, {:import_source_object, ^second_key, :invalid_message_segment}} =
             PGImport.step(page_size: 1)

    assert {:ok, ^before} = PGAuthorityImport.state(:c)
    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, second["message_id"])
    assert {:ok, _} = S3.put(second_key, second_body)
    assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 1, max_pages: 100)
    assert {:ok, ^second} = ConversationPGStore.message_by_id(scope, second["message_id"])
    assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, meta_key})) == 1
  end

  @tag :scan_fusion
  test "mixed JSON reads refill idle slots across scopes and retain source error order", %{
    scope: scope
  } do
    records =
      for _ <- 1..16 do
        current = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
        put_meta!(current, metadata(current, 1))
        body = message(1, current.conversation_id)
        put_segment!(current, [body], "open")
        pointer_key = put_pointer!(current, pointer(body), :request)
        [{receipt_key, receipt}] = put_related!(:receipt, current, 1)

        participant_key =
          Keys.ctl_group_conversation_participant_state(
            current.group_id,
            current.conversation_id,
            receipt["participant_id"]
          )

        {current, pointer_key, participant_key, receipt_key, receipt}
      end
      |> Enum.sort_by(&elem(&1, 1))

    keys =
      records
      |> Enum.flat_map(fn {_, pointer, participant, receipt, _} ->
        [pointer, participant, receipt]
      end)
      |> Enum.sort()

    [{first_scope, _pointer, invalid, later, receipt} | _] = records
    source = S3.Fake.dump()
    put_json!(invalid, %{})
    put_json!(later, %{})
    assert {:ok, _} = PGImport.step(page_size: 1_000)
    assert {:ok, before} = PGImport.step(page_size: 1_000)

    assert %{rows: [[16]]} =
             Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
               scope.group_id
             ])

    S3.Fake.reset_read_log()
    S3.Fake.set_fault({:pause, :get, hd(keys)})
    importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

    try do
      assert :ok = S3.Fake.await_pause()
      settle()

      assert Enum.sort(pointer_gets(keys)) == keys,
             "a paused first read must not hold up the remaining mixed JSON reads"

      assert {:ok, ^before} = PGAuthorityImport.state(:c)
      assert :ok = S3.Fake.release_pause()

      assert {:error, {:import_source_object, ^invalid, :invalid_participant_identity}} =
               settled_await(importing)

      assert {:ok, ^before} = PGAuthorityImport.state(:c)
      assert {:error, :not_found} = read_related(:receipt, first_scope, receipt)

      assert {:ok, _} = S3.put(invalid, source[invalid].body)
      assert {:ok, _} = S3.put(later, source[later].body)
      prefix_bytes = byte_size(source[hd(keys)].body) + byte_size(source[invalid].body)

      assert {:ok, prefix} = PGImport.step(page_size: 1_000, max_page_bytes: prefix_bytes)
      assert prefix.cursor == %{"phase" => "json_fused", "last_object" => invalid}
      assert prefix.stats["objects"] - before.stats["objects"] == 2
      assert {:error, :not_found} = read_related(:receipt, first_scope, receipt)
      assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 1_000, max_pages: 20)

      for {current, _pointer, _participant, receipt_key, receipt} <- records do
        assert_related!(:receipt, current, [{receipt_key, receipt}])
      end
    after
      if S3.Fake.paused?() do
        S3.Fake.release_pause()
        settled_await(importing)
      end
    end
  end

  @tag :scan_fusion
  test "a new scope retains whole metadata conflicts and rolls back earlier page facts", %{
    scope: scope
  } do
    other = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
    [first_scope, conflict_scope] = Enum.sort_by([scope, other], & &1.conversation_id)

    for current <- [first_scope, conflict_scope] do
      put_meta!(current, metadata(current, 1))
      put_segment!(current, [message(1, current.conversation_id)], "open")
    end

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               ConversationPGStore.import_metadata!(
                 conflict_scope,
                 Map.put(metadata(conflict_scope, 1), "title", "different target fact")
               )
             end)

    assert {:error, {:import_conflict, "salix_conversations", _}} = PGImport.step()
    assert {:ok, nil} = PGAuthorityImport.state(:c)
    assert {:error, :not_found} = ConversationPGStore.read(first_scope)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
               scope.group_id
             ])
  end

  test "locator identities fill only missing values and a conflict rolls back the page and cursor",
       %{scope: scope} do
    put_meta!(scope, metadata(scope, 1))

    body =
      message(1, "legacy") |> Map.delete("request_identity") |> Map.delete("request_fingerprint")

    put_segment!(scope, [body], "open")

    good =
      pointer(body)
      |> Map.put("request_identity", "source request")
      |> Map.put("request_fingerprint", "original fingerprint")

    bad = Map.put(good, "request_fingerprint", "different fingerprint")

    good_key =
      Keys.ctl_group_conversation_message_idempotency(scope.group_id, scope.conversation_id, "a")

    bad_key =
      Keys.ctl_group_conversation_message_identity(scope.group_id, scope.conversation_id, "z")

    put_json!(good_key, good)
    put_json!(bad_key, bad)
    progress = reach_phase!("pointers")

    assert {:error, {:import_conflict, "salix_conversation_messages", id}} =
             PGImport.step(page_size: 1_000)

    assert id == body["message_id"]
    assert {:ok, ^progress} = PGAuthorityImport.state(:c)

    assert %{rows: [[nil, nil, bytes]]} =
             Repo.query!(
               "SELECT request_identity,request_fingerprint,payload FROM salix_conversation_messages WHERE group_id=$1",
               [scope.group_id]
             )

    assert :erlang.binary_to_term(bytes, [:safe]) == body
    assert {:ok, _} = S3.get(bad_key)
    put_json!(bad_key, Map.drop(good, ~w(request_identity request_fingerprint)))
    assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 1_000, max_pages: 20)
    assert {:ok, restored} = ConversationPGStore.message_by_id(scope, body["message_id"])
    assert restored["request_identity"] == "source request"
    assert restored["request_fingerprint"] == "original fingerprint"
    assert Map.drop(restored, ~w(request_identity request_fingerprint)) == body

    assert %{rows: [[^bytes]]} =
             Repo.query!("SELECT payload FROM salix_conversation_messages WHERE group_id=$1", [
               scope.group_id
             ])

    assert {:ok, %{body: source}} = S3.get(segment_key(scope, 1))
    refute String.contains?(source, "original fingerprint")
  end

  test "locator batches preserve duplicate identities and roll back earlier writes on a late conflict",
       %{scope: scope} do
    put_meta!(scope, metadata(scope, 130))

    messages =
      for seq <- 1..130,
          do: message(seq, "legacy #{seq}") |> Map.drop(~w(request_identity request_fingerprint))

    put_segment!(scope, messages, "open")

    pointers =
      for body <- messages do
        suffix = body["seq"] |> to_string() |> String.pad_leading(3, "0")

        put_json!(
          Keys.ctl_group_conversation_message_idempotency(
            scope.group_id,
            scope.conversation_id,
            suffix
          ),
          pointer(body)
          |> Map.put("request_identity", " request #{body["seq"]} ")
          |> Map.put("request_fingerprint", "fingerprint #{body["seq"]}")
        )

        key =
          Keys.ctl_group_conversation_message_identity(
            scope.group_id,
            scope.conversation_id,
            suffix
          )

        put_json!(key, pointer(body))
        {key, body}
      end

    {bad_key, last} = List.last(pointers)
    put_json!(bad_key, pointer(last) |> Map.put("request_fingerprint", "conflicting fingerprint"))
    progress = reach_phase!("pointers")
    id = last["message_id"]

    assert {:error, {:import_conflict, "salix_conversation_messages", ^id}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^progress} = PGAuthorityImport.state(:c)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1 AND (request_identity IS NOT NULL OR request_fingerprint IS NOT NULL)",
               [scope.group_id]
             )

    put_json!(bad_key, pointer(last))

    {result, queries} = import_queries(fn -> PGImport.step(page_size: 1_000) end)
    assert {:ok, %{cursor: %{"phase" => "participants"}}} = result
    assert length(queries) in 1..16
    assert Enum.all?(queries, &(&1 <= 400))

    %{rows: rows} =
      Repo.query!(
        "SELECT request_identity,request_fingerprint,payload FROM salix_conversation_messages WHERE group_id=$1 ORDER BY seq",
        [scope.group_id]
      )

    assert length(rows) == length(messages)

    for {[identity, fingerprint, payload], body} <- Enum.zip(rows, messages) do
      assert identity == "request #{body["seq"]}"
      assert fingerprint == "fingerprint #{body["seq"]}"
      assert :erlang.binary_to_term(payload, [:safe]) == body
    end
  end

  test "metadata and progress commit together after a database rejection", %{scope: scope} do
    key = put_meta!(scope, metadata(scope, 0))

    Repo.query!(
      "ALTER TABLE salix_conversations ADD CONSTRAINT pg_import_reject CHECK (group_id <> '#{scope.group_id}') NOT VALID"
    )

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT IF EXISTS pg_import_reject")
    end)

    assert {:error, {:import_object_failed, ^key, :check_violation}} = PGImport.step()
    assert {:ok, nil} = PGAuthorityImport.state(:c)
    assert {:error, :not_found} = ConversationPGStore.read(scope)
    assert {:ok, _} = S3.get(key)
    Repo.query!("ALTER TABLE salix_conversations DROP CONSTRAINT pg_import_reject")
    assert {:ok, %{step: 1}} = PGImport.step()
    assert {:ok, _, 1} = ConversationPGStore.read(scope)
    assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 20)
  end

  test "a disconnected marker keeps frozen facts instead of rereading changed source", %{
    scope: scope
  } do
    original = metadata(scope, 0)
    key = put_meta!(scope, original)

    Repo.query!("""
    CREATE FUNCTION pg_import_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.name = '#{@marker}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER pg_import_disconnect BEFORE UPDATE ON salix_cutover_markers FOR EACH ROW EXECUTE FUNCTION pg_import_disconnect()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS pg_import_disconnect ON salix_cutover_markers")
      Repo.query!("DROP FUNCTION IF EXISTS pg_import_disconnect()")
    end)

    assert {:error, :import_outcome_unknown, %PGAuthorityImport.Pending{} = pending} =
             PGImport.step()

    assert {:error, :not_found} = ConversationPGStore.read(scope)
    put_json!(key, Map.put(original, "title", "source changed after frozen page"))
    Repo.query!("DROP TRIGGER pg_import_disconnect ON salix_cutover_markers")
    Repo.query!("DROP FUNCTION pg_import_disconnect()")
    reads_before_settle = S3.Fake.read_log()
    assert {:ok, %{step: 1, cursor: %{"phase" => "messages_fused"}}} = PGImport.settle(pending)
    assert S3.Fake.read_log() == reads_before_settle
    assert {:ok, restored, 1} = ConversationPGStore.read(scope)
    assert restored["title"] == original["title"]
    assert restored["created_at"] == original["created_at"]
    assert {:ok, %{step: 1}} = PGImport.settle(pending)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM salix_conversations WHERE group_id=$1", [
               scope.group_id
             ])
  end

  test "unsettled publication and absent-metadata reservation refuse exact sources without discarding them",
       %{scope: scope} do
    put_meta!(scope, metadata(scope, 0))
    {segment, _} = put_segment!(scope, [message(1, "prepared")], "open")
    progress = reach_phase!("messages")

    assert {:error, {:import_source_object, ^segment, {:unsettled_publication, ^segment, 1, 0}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^progress} = PGAuthorityImport.state(:c)
    assert {:ok, _} = S3.get(segment)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
               scope.group_id
             ])

    :ok = S3.delete(segment)
    Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [scope.group_id])

    reservation = %{
      "status" => "reserved",
      "message_id" => Ids.new_message_id(),
      "request_identity" => "first unpublished request",
      "created_at" => 100,
      "request_fingerprint" => "accepted"
    }

    key = put_pointer!(scope, reservation, :request)
    reach_phase!("pointers")

    assert {:error,
            {:import_source_object, ^key, {:unsettled_publication, ^key, :metadata_missing}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, _} = S3.get(key)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
               scope.group_id
             ])
  end

  test "page byte exhaustion resumes the same object page and oversized objects remain actionable",
       %{scope: scope} do
    other = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
    first = put_meta!(scope, metadata(scope, 0))
    second = put_meta!(other, metadata(other, 0))
    {:ok, %{body: bytes}} = S3.get(first)

    assert {:ok, %{cursor: %{"phase" => "metadata_fused"}, step: 1}} =
             PGImport.step(page_size: 2, max_page_bytes: byte_size(bytes))

    assert {:ok, %{cursor: %{"phase" => "messages_fused"}, step: 2}} =
             PGImport.step(page_size: 1, max_page_bytes: byte_size(bytes))

    assert {:ok, _, 1} = ConversationPGStore.read(scope)
    assert {:ok, _, 1} = ConversationPGStore.read(other)
    assert {:ok, _} = S3.get(second)
    Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [scope.group_id])
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name=$1", [@marker])

    assert {:error, {:import_source_object, key, {:source_byte_limit, key}}} =
             PGImport.step(page_size: 2, max_object_bytes: 10)

    assert key in [first, second]
    assert {:ok, nil} = PGAuthorityImport.state(:c)
    assert {:ok, _} = S3.get(key)
    assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 2, max_pages: 30)
  end

  test "pointer reads refill idle slots and commit all source identities", %{
    scope: scope
  } do
    put_meta!(scope, metadata(scope, 0))
    pointers = put_reservations!(scope, 33)
    keys = Enum.map(pointers, &elem(&1, 0))
    before = reach_phase!("pointers")
    S3.Fake.reset_read_log()
    S3.Fake.set_fault({:pause, :get, hd(keys)})
    importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

    try do
      assert :ok = S3.Fake.await_pause()
      settle()
      assert Enum.sort(pointer_gets(keys)) == keys
      assert {:ok, ^before} = PGAuthorityImport.state(:c)
      assert :ok = S3.Fake.release_pause()

      assert {:ok, %{cursor: %{"phase" => "participants"}} = after_page} =
               settled_await(importing)

      assert Enum.sort(pointer_gets(keys)) == keys

      bytes =
        S3.Fake.dump()
        |> Map.take(keys)
        |> Map.values()
        |> Enum.map(&byte_size(&1.body))
        |> Enum.sum()

      assert after_page.stats["objects"] - before.stats["objects"] == 33
      assert after_page.stats["wire_bytes"] - before.stats["wire_bytes"] == bytes
      assert after_page.stats["inflated_bytes"] - before.stats["inflated_bytes"] == bytes
      assert_reservations!(scope, pointers)
    after
      if S3.Fake.paused?() do
        S3.Fake.release_pause()
        settled_await(importing)
      end
    end
  end

  test "pointer byte exhaustion commits the fitting source prefix and resumes the next identity",
       %{
         scope: scope
       } do
    put_meta!(scope, metadata(scope, 0))
    pointers = put_reservations!(scope, 3)
    [{first, _}, {second, _}, {third, third_record}] = pointers
    before = reach_phase!("pointers")
    objects = S3.Fake.dump()
    bytes = Enum.sum(for key <- [first, second], do: byte_size(objects[key].body))
    S3.Fake.reset_read_log()

    assert {:ok, %{cursor: %{"phase" => "pointers", "last_object" => ^second}} = prefix} =
             PGImport.step(page_size: 1_000, max_page_bytes: bytes)

    assert pointer_gets([first, second, third]) |> Enum.sort() == [first, second]
    assert prefix.stats["objects"] - before.stats["objects"] == 2
    assert prefix.stats["wire_bytes"] - before.stats["wire_bytes"] == bytes
    assert prefix.stats["inflated_bytes"] - before.stats["inflated_bytes"] == bytes
    assert_reservations!(scope, Enum.take(pointers, 2))

    assert {:error, :not_found} =
             ConversationPGStore.identity_by_request_identity(
               scope,
               third_record["request_identity"]
             )

    assert {:ok, %{cursor: %{"phase" => "participants"}}} =
             PGImport.step(page_size: 1_000, max_page_bytes: bytes)

    assert_reservations!(scope, pointers)
  end

  test "an empty pointer JSON wins over a later completed error and rolls back the page", %{
    scope: scope
  } do
    put_meta!(scope, metadata(scope, 0))

    [{first, _}, {empty, empty_record}, {later, later_record}] =
      pointers = put_reservations!(scope, 3)

    assert {:ok, _} = S3.put(empty, "")
    put_json!(later, %{})
    before = reach_phase!("pointers")
    S3.Fake.reset_read_log()
    S3.Fake.set_fault({:pause, :get, empty})
    importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

    try do
      assert :ok = S3.Fake.await_pause()
      settle()
      assert pointer_gets([first, empty, later]) |> Enum.sort() == [first, empty, later]
      assert :ok = S3.Fake.release_pause()

      assert {:error, {:import_source_object, ^empty, {:invalid_source_json, ^empty}}} =
               settled_await(importing)

      assert {:ok, ^before} = PGAuthorityImport.state(:c)

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
                 scope.group_id
               ])

      put_json!(empty, empty_record)
      put_json!(later, later_record)
      assert {:ok, %{cursor: %{"phase" => "participants"}}} = PGImport.step(page_size: 1_000)
      assert_reservations!(scope, pointers)
    after
      if S3.Fake.paused?(), do: S3.Fake.release_pause()
    end
  end

  @tag :cross_scope_read
  test "a later missing Conversation cannot overtake a JSON error or a fitting byte prefix", %{
    scope: scope
  } do
    records =
      for _ <- 1..3 do
        current = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
        put_meta!(current, metadata(current, 0))
        [{key, record}] = put_reservations!(current, 1)
        {current, key, record}
      end
      |> Enum.sort_by(&elem(&1, 1))

    [
      {first_scope, first, first_record},
      {second_scope, second, second_record},
      {missing_scope, missing, missing_record}
    ] = records

    before = reach_phase!("pointers")

    Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1 AND conversation_id=$2", [
      missing_scope.group_id,
      missing_scope.conversation_id
    ])

    assert {:ok, _} = S3.put(second, "")

    assert {:error, {:import_source_object, ^second, {:invalid_source_json, ^second}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^before} = PGAuthorityImport.state(:c)

    put_json!(second, second_record)
    objects = S3.Fake.dump()
    bytes = byte_size(objects[first].body) + byte_size(objects[second].body)

    assert {:ok, prefix} = PGImport.step(page_size: 1_000, max_page_bytes: bytes)
    assert prefix.cursor["phase"] == "pointers"
    assert prefix.cursor["last_object"] >= second and prefix.cursor["last_object"] < missing
    assert prefix.stats["objects"] - before.stats["objects"] == 2
    assert_reservations!(first_scope, [{first, first_record}])
    assert_reservations!(second_scope, [{second, second_record}])

    assert {:error,
            {:import_source_object, ^missing,
             {:unsettled_publication, ^missing, :metadata_missing}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^prefix} = PGAuthorityImport.state(:c)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               ConversationPGStore.import_metadata!(missing_scope, metadata(missing_scope, 0))
             end)

    assert {:ok, %{cursor: %{"phase" => "participants"}}} = PGImport.step(page_size: 1_000)
    assert_reservations!(missing_scope, [{missing, missing_record}])
  end

  for {kind, phase, following} <- [
        {:participant, "participants", "receipts"},
        {:receipt, "receipts", "create_requests"}
      ] do
    @related_kind kind
    @related_phase phase
    @related_following following

    @tag :related_read_batch
    @tag :cross_scope_read
    test "#{phase} overlap 32 Conversation scopes and settle before committing", %{scope: scope} do
      records =
        for _ <- 1..32 do
          current = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
          put_meta!(current, metadata(current, 0))
          [{key, record}] = put_related!(@related_kind, current, 1)
          {current, key, record}
        end
        |> Enum.sort_by(&elem(&1, 1))

      keys = Enum.map(records, &elem(&1, 1))
      before = reach_phase!(@related_phase)
      S3.Fake.reset_read_log()
      S3.Fake.set_fault({:pause, :get, hd(keys)})
      importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

      try do
        assert :ok = S3.Fake.await_pause()
        settle()
        assert Enum.sort(pointer_gets(keys)) == keys
        assert {:ok, ^before} = PGAuthorityImport.state(:c)

        for {current, _key, record} <- records do
          assert {:error, :not_found} = read_related(@related_kind, current, record)
        end

        assert :ok = S3.Fake.release_pause()
        assert {:ok, after_page} = settled_await(importing)
        assert after_page.cursor["phase"] == @related_following
        assert after_page.stats["objects"] - before.stats["objects"] == 32

        for {current, key, record} <- records do
          assert_related!(@related_kind, current, [{key, record}])
        end
      after
        if S3.Fake.paused?() do
          S3.Fake.release_pause()
          settled_await(importing)
        end
      end
    end

    @tag :related_read_batch
    test "#{phase} byte exhaustion commits only the fitting source prefix", %{scope: scope} do
      put_meta!(scope, metadata(scope, 0))

      [{first, _}, {second, _}, {third, third_record}] =
        records = put_related!(@related_kind, scope, 3)

      before = reach_phase!(@related_phase)
      objects = S3.Fake.dump()
      bytes = Enum.sum(for key <- [first, second], do: byte_size(objects[key].body))
      S3.Fake.reset_read_log()

      assert {:ok, prefix} = PGImport.step(page_size: 1_000, max_page_bytes: bytes)
      assert prefix.cursor == %{"phase" => @related_phase, "last_object" => second}
      assert Enum.sort(pointer_gets([first, second, third])) == [first, second]
      assert prefix.stats["objects"] - before.stats["objects"] == 2
      assert prefix.stats["wire_bytes"] - before.stats["wire_bytes"] == bytes
      assert prefix.stats["inflated_bytes"] - before.stats["inflated_bytes"] == bytes
      assert_related!(@related_kind, scope, Enum.take(records, 2))
      assert {:error, :not_found} = read_related(@related_kind, scope, third_record)

      assert {:ok, after_page} = PGImport.step(page_size: 1_000, max_page_bytes: bytes)
      assert after_page.cursor["phase"] == @related_following
      assert_related!(@related_kind, scope, records)
    end

    @tag :related_read_batch
    test "#{phase} retain source error order and roll back all facts", %{scope: scope} do
      put_meta!(scope, metadata(scope, 0))

      [{first, _}, {invalid, invalid_record}, {later, later_record}] =
        records = put_related!(@related_kind, scope, 3)

      put_json!(invalid, Map.put(invalid_record, "conversation_id", "different conversation"))
      put_json!(later, Map.put(later_record, "participant_id", ""))
      before = reach_phase!(@related_phase)
      S3.Fake.reset_read_log()
      S3.Fake.set_fault({:pause, :get, invalid})
      importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

      try do
        assert :ok = S3.Fake.await_pause()
        settle()
        assert Enum.sort(pointer_gets([first, invalid, later])) == [first, invalid, later]
        assert :ok = S3.Fake.release_pause()

        assert {:error, {:import_source_object, ^invalid, {:source_scope_conflict, ^invalid}}} =
                 settled_await(importing)

        assert {:ok, ^before} = PGAuthorityImport.state(:c)

        for {_key, record} <- records do
          assert {:error, :not_found} = read_related(@related_kind, scope, record)
        end

        put_json!(invalid, invalid_record)
        put_json!(later, later_record)
        assert {:ok, _} = PGImport.step(page_size: 1_000)
        assert_related!(@related_kind, scope, records)
      after
        if S3.Fake.paused?() do
          S3.Fake.release_pause()
          settled_await(importing)
        end
      end
    end
  end

  test "legacy-only membership and conflicting scope retain their precise source objects", %{
    scope: scope
  } do
    put_meta!(scope, metadata(scope, 0))

    participant = %{
      "participant_id" => "original opaque",
      "conversation_id" => scope.conversation_id,
      "actor_type" => "provider",
      "state" => "active",
      "notification_filter" => %{"messages" => "none", "statuses" => "none"}
    }

    key =
      Keys.ctl_group_conversation_participant_dir(
        scope.group_id,
        scope.conversation_id,
        participant["participant_id"]
      ) <> "state.json"

    put_json!(key, participant)
    progress = reach_phase!("participants")

    assert {:error, {:import_source_object, ^key, {:unsettled_participant_state, ^key}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^progress} = PGAuthorityImport.state(:c)
    assert {:ok, _} = S3.get(key)

    current =
      Keys.ctl_group_conversation_participant_state(
        scope.group_id,
        scope.conversation_id,
        participant["participant_id"]
      )

    put_json!(current, Map.put(participant, "conversation_id", "different conversation"))

    assert {:error, {:import_source_object, ^current, {:source_scope_conflict, ^current}}} =
             PGImport.step(page_size: 1_000)

    assert {:ok, ^progress} = PGAuthorityImport.state(:c)
    assert {:ok, _} = S3.get(current)
    put_json!(current, participant)
    assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 1_000, max_pages: 20)

    assert {:ok, ^participant, 1} =
             ParticipantPG.read(
               ParticipantPG.new(
                 scope.group_id,
                 scope.conversation_id,
                 participant["participant_id"]
               )
             )
  end

  test "inventory is read only and distinguishes retained flat history from unfinished conversion",
       %{scope: scope} do
    old = "ctl/group_conversations/#{scope.group_id}/#{scope.conversation_id}.json"
    assert {:ok, _} = S3.put(old, "retained source bytes")

    assert {:error, {:import_source_object, ^old, {:unsettled_conversation_format, ^old}}} =
             PGImport.inventory()

    assert {:error, {:import_source_object, ^old, {:unsettled_conversation_format, ^old}}} =
             PGImport.step()

    assert {:ok, nil} = PGAuthorityImport.state(:c)
    key = put_meta!(scope, metadata(scope, 0))
    [{reservation, _}] = put_reservations!(scope, 1)

    assert {:error, :invalid_import_progress} =
             PGImport.inventory(%{"phase" => "messages_fused", "last_object" => nil})

    Repo.query!(
      "INSERT INTO conversation_log_recovery(group_id,conversation_id,target_seq,status_version,membership_revision,due_at_ms) VALUES($1,$2,0,4,7,1)",
      [scope.group_id, scope.conversation_id]
    )

    assert {:ok, %{objects: objects, next: next, stats: stats, validation: :source_codec_only}} =
             PGImport.inventory()

    assert Enum.any?(objects, &(&1.key == old and &1.family == :historical))
    assert Enum.any?(objects, &(&1.key == key and &1.family == :metadata and &1.format == :json))
    assert stats.objects > 0 and stats.wire_bytes > 0 and stats.inflated_bytes > 0

    source = S3.Fake.dump()
    meta_bytes = byte_size(source[key].body)

    assert {:ok, %{stats: prefix_stats}} =
             PGImport.inventory(%{"phase" => "pointers", "last_object" => nil},
               max_page_bytes: meta_bytes + byte_size(source[reservation].body) - 1
             )

    assert prefix_stats.objects == 1
    assert prefix_stats.wire_bytes == meta_bytes
    reports = finish_inventory!(next, 20)
    assert Enum.any?(reports, &(&1.key == reservation and &1.family == :reservation))

    assert Enum.any?(reports, fn report ->
             report.family == :recovery_mark and report.format == :postgresql and
               report.facts == %{
                 target_seq: 0,
                 status_version: 4,
                 membership_revision: 7,
                 due_at_ms: 1
               }
           end)

    assert {:ok, nil} = PGAuthorityImport.state(:c)
    assert {:error, :not_found} = ConversationPGStore.read(scope)
    assert {:ok, %{body: "retained source bytes"}} = S3.get(old)
    assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 30)
    assert {:ok, %{"title" => "original title"}, 1} = ConversationPGStore.read(scope)
  end

  test "metadata and create requests refill idle slots and retain their frozen page", %{
    scope: scope
  } do
    metadata_keys =
      for _ <- 1..64 do
        current = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
        put_meta!(current, metadata(current, 0))
      end
      |> Enum.sort()

    request_keys =
      for index <- 1..64 do
        identity = "create #{index}"
        key = Keys.ctl_group_conversation_create_request(scope.group_id, Crypto.hex(identity))

        put_json!(key, %{
          "group_id" => scope.group_id,
          "request_identity" => identity,
          "conversation_id" => scope.conversation_id,
          "request_fingerprint" => "fingerprint #{index}"
        })

        key
      end
      |> Enum.sort()

    assert_concurrent_page!(metadata_keys, nil)
    before = reach_phase!("create_requests")
    assert_concurrent_page!(request_keys, before)
  end

  test "segments and their indexes overlap without changing metadata dependency", %{scope: scope} do
    records =
      for _ <- 1..16 do
        current = ConversationPGStore.new(scope.group_id, Ids.new_conversation_id())
        put_meta!(current, metadata(current, 1))
        {segment, _} = put_segment!(current, [message(1, current.conversation_id)], "sealed")

        index =
          Keys.ctl_group_conversation_message_segment_index(
            current.group_id,
            current.conversation_id,
            segment_id(1)
          )

        {current, segment, index}
      end
      |> Enum.sort_by(&elem(&1, 1))

    assert {:ok, before} = PGImport.step(page_size: 1_000)
    keys = Enum.flat_map(records, fn {_, segment, index} -> [segment, index] end)
    {_first_scope, _first_segment, first_index} = hd(records)
    S3.Fake.reset_read_log()
    S3.Fake.set_fault({:pause, :get, first_index})
    importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

    try do
      assert :ok = S3.Fake.await_pause()
      settle()
      assert Enum.sort(pointer_gets(keys)) == Enum.sort(keys)
      assert {:ok, ^before} = PGAuthorityImport.state(:c)

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1", [
                 scope.group_id
               ])

      assert :ok = S3.Fake.release_pause()
      assert {:ok, _} = settled_await(importing)

      for {current, _, _} <- records do
        assert {:ok, [_]} = ConversationPGStore.messages(current, 1, 1, 1)
      end
    after
      if S3.Fake.paused?() do
        S3.Fake.release_pause()
        settled_await(importing)
      end
    end
  end

  test "message SQL batches retain null identities and reject a later whole-row conflict", %{
    scope: scope
  } do
    put_meta!(scope, metadata(scope, 260))

    messages =
      for seq <- 1..260,
          do: message(seq, "batch #{seq}") |> Map.drop(~w(request_identity request_fingerprint))

    {key, _} = put_segment!(scope, messages, "open")
    before = reach_phase!("messages")
    {result, queries} = import_queries(fn -> PGImport.step(page_size: 1_000) end)
    assert {:ok, after_page} = result
    assert length(queries) < 24
    assert Enum.all?(queries, &(&1 <= 1_600))

    projected =
      Enum.map(
        messages,
        &Map.merge(&1, %{"request_identity" => nil, "request_fingerprint" => nil})
      )

    assert {:ok, ^projected} = ConversationPGStore.messages(scope, 1, 260, 260)

    assert %{rows: [[260]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1 AND request_identity IS NULL AND request_fingerprint IS NULL",
               [scope.group_id]
             )

    last = List.last(messages)
    conflicting = Map.put(last, "created_at", last["created_at"] + 1)

    facts = [
      %{
        kind: :segment,
        key: key,
        scope: scope,
        archives: [],
        messages:
          Enum.map(Enum.drop(messages, -1) ++ [conflicting], fn record ->
            %{record: record, revision: 1, tombstone: false, archive_first_seq: nil}
          end)
      }
    ]

    assert {:error, {:import_conflict, "salix_conversation_messages", identity}} =
             Repo.transaction(fn -> PGImport.import!(facts) end)

    assert identity.message_id == last["message_id"]
    assert {:ok, ^after_page} = PGAuthorityImport.state(:c)
    assert before.step < after_page.step
    assert {:ok, ^projected} = ConversationPGStore.messages(scope, 1, 260, 260)
  end

  for {kind, phase} <- [{:participant, "participants"}, {:receipt, "receipts"}] do
    @batch_kind kind
    @batch_phase phase
    test "#{phase} batches preserve facts and a late database rejection rolls back the entire page",
         %{scope: scope} do
      put_meta!(scope, metadata(scope, 0))
      records = put_related!(@batch_kind, scope, 130)
      before = reach_phase!(@batch_phase)
      {bad_key, bad} = List.last(records)

      table =
        if @batch_kind == :participant,
          do: "salix_conversation_participants",
          else: "salix_conversation_deliveries"

      Repo.query!(
        "ALTER TABLE #{table} ADD CONSTRAINT pg_import_batch_reject CHECK (participant_id <> '#{bad["participant_id"]}') NOT VALID"
      )

      on_exit(fn ->
        Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS pg_import_batch_reject")
      end)

      assert {:error, {:import_object_failed, ^bad_key, :check_violation}} =
               PGImport.step(page_size: 1_000)

      assert {:ok, ^before} = PGAuthorityImport.state(:c)

      for {_key, record} <- records,
          do: assert({:error, :not_found} = read_related(@batch_kind, scope, record))

      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT pg_import_batch_reject")

      {result, queries} = import_queries(fn -> PGImport.step(page_size: 1_000) end)
      assert {:ok, _} = result
      assert length(queries) < 32
      assert Enum.all?(queries, &(&1 <= 2_200))
      assert_related!(@batch_kind, scope, records)
    end
  end

  test "a rebuilt key index resumes an ignored source cursor without repeating root enumeration",
       %{scope: scope} do
    put_meta!(scope, metadata(scope, 2))
    first = message(1, "index restart first")
    second = message(2, "index restart second")
    put_segment!(scope, [first], "sealed")
    put_segment!(scope, [second], "open")

    ignored =
      "ctl/group_conversations/#{scope.group_id}/#{scope.conversation_id}/messages/legacy/unused.json"

    assert {:ok, _} = S3.put(ignored, "ignored source bytes")
    assert {:ok, %{cursor: %{"phase" => "messages_fused"}}} = PGImport.step(page_size: 1)

    Repo.query!(
      "UPDATE salix_cutover_markers SET evidence=jsonb_set(evidence,'{cursor,last_object}',to_jsonb($2::text)) WHERE name=$1",
      [@marker, ignored]
    )

    S3.Fake.reset_read_log()
    assert {:ok, %{phase: "complete"}} = PGImport.run(page_size: 1, max_pages: 20)
    root = "ctl/group_conversations/"
    objects = Enum.count(S3.Fake.dump(), fn {key, _} -> String.starts_with?(key, root) end)
    assert Enum.count(S3.Fake.read_log(), &match?({:list, ^root, _}, &1)) == objects
    assert {:ok, [^first, ^second]} = ConversationPGStore.messages(scope, 1, 2, 2)
    meta_key = Keys.ctl_group_conversation_meta(scope.group_id, scope.conversation_id)
    assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, meta_key})) == 0
    reads = S3.Fake.read_log()
    assert {:ok, %{phase: "complete"}} = PGImport.step()
    assert S3.Fake.read_log() == reads
  end

  test "a failed root enumeration leaves facts and marker untouched and can rebuild its short context",
       %{scope: scope} do
    put_meta!(scope, metadata(scope, 0))
    root = "ctl/group_conversations/"
    S3.Fake.set_fault({:fail, 503, :list, root})

    PGImport.with_context(fn context ->
      assert {:error, _} = PGImport.step(context)
      assert {:ok, nil} = PGAuthorityImport.state(:c)
      assert {:error, :not_found} = ConversationPGStore.read(scope)
      assert {:ok, %{phase: "complete"}} = PGImport.run(Keyword.merge(context, max_pages: 20))
    end)

    assert {:ok, _, 1} = ConversationPGStore.read(scope)
  end

  defp assert_concurrent_page!([first | _] = keys, before) do
    S3.Fake.reset_read_log()
    S3.Fake.set_fault({:pause, :get, first})
    importing = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1_000) end)

    try do
      assert :ok = S3.Fake.await_pause()
      settle()
      assert Enum.sort(pointer_gets(keys)) == keys
      assert {:ok, ^before} = PGAuthorityImport.state(:c)
      assert :ok = S3.Fake.release_pause()
      assert {:ok, _} = settled_await(importing)
    after
      if S3.Fake.paused?() do
        S3.Fake.release_pause()
        settled_await(importing)
      end
    end
  end

  defp import_queries(fun) do
    owner = SystemsRuntime.Proc.self()
    table = :ets.new(:import_queries, [:bag, :public])
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _event, _measurements, metadata, {owner, table} ->
          if SystemsRuntime.Proc.self() == owner,
            do: :ets.insert(table, {make_ref(), length(metadata.params || [])})
        end,
        {owner, table}
      )

    try do
      result = fun.()
      {result, for({_ref, count} <- :ets.tab2list(table), do: count)}
    after
      :telemetry.detach(handler)
      :ets.delete(table)
    end
  end

  defp finish_inventory!(nil, _), do: []
  defp finish_inventory!(_, 0), do: flunk("inventory did not complete within 20 pages")

  defp finish_inventory!(cursor, remaining) do
    assert {:ok, %{next: next, objects: objects}} = PGImport.inventory(cursor)
    objects ++ finish_inventory!(next, remaining - 1)
  end

  defp reach_phase!(phase, remaining \\ 20)

  defp reach_phase!(_phase, 0),
    do: flunk("import did not reach the requested phase within 20 pages")

  defp reach_phase!(phase, remaining) do
    case PGAuthorityImport.state(:c) do
      {:ok, nil} when phase in ~w(metadata messages pointers participants receipts) ->
        Repo.query!(
          "INSERT INTO salix_cutover_markers(name,completed_at,evidence) VALUES($1,statement_timestamp(),$2)",
          [
            @marker,
            %{
              "phase" => "importing",
              "step" => 0,
              "cursor" => %{"phase" => "metadata", "last_object" => nil},
              "stats" => %{}
            }
          ]
        )

        reach_phase!(phase, remaining)

      {:ok, %{cursor: %{"phase" => ^phase}} = progress} ->
        progress

      _ ->
        assert {:ok, _} = PGImport.step(page_size: 1_000)
        reach_phase!(phase, remaining - 1)
    end
  end

  defp metadata(scope, tail) do
    %{
      "agent_group_id" => scope.group_id,
      "conversation_id" => scope.conversation_id,
      "kind" => "agent_task",
      "title" => "original title",
      "status" => "archived",
      "created_at" => 123,
      "updated_at" => 456,
      "archived_at" => 600,
      "message_tail_seq" => tail,
      "message_head_seq" => tail,
      "log_start_seq" => 1,
      "provider_status_version" => 4,
      "membership_revision" => 7,
      "participant_count" => 99
    }
  end

  defp put_meta!(scope, record) do
    key = Keys.ctl_group_conversation_meta(scope.group_id, scope.conversation_id)
    put_json!(key, record)
    key
  end

  defp message(seq, text) do
    {:ok, attrs} =
      ConversationMessage.prepare(%{
        "kind" => "message",
        "actor_type" => "user",
        "client_request_id" => text,
        "content" => text
      })

    ConversationMessage.build(
      attrs,
      %{"actor_type" => "user", "user_id" => "original author"},
      1_000 + seq
    )
    |> Map.put("seq", seq)
  end

  defp segment_key(scope, seq),
    do:
      Keys.ctl_group_conversation_message_segment(
        scope.group_id,
        scope.conversation_id,
        segment_id(seq)
      )

  defp segment_id(seq), do: seq |> to_string() |> String.pad_leading(18, "0")

  defp put_segment!(scope, rows, status) do
    first = hd(rows)["seq"]
    key = segment_key(scope, first)
    body = Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
    assert {:ok, _} = S3.put(key, body)

    put_json!(
      Keys.ctl_group_conversation_message_segment_index(
        scope.group_id,
        scope.conversation_id,
        segment_id(first)
      ),
      %{"status" => status, "start_seq" => first, "end_seq" => List.last(rows)["seq"]}
    )

    {key, body}
  end

  defp pointer(message),
    do:
      Map.take(message, ~w(message_id seq request_identity request_fingerprint created_at))
      |> Map.put("segment_id", segment_id(message["seq"]))

  defp put_pointer!(scope, record, :request) do
    key =
      Keys.ctl_group_conversation_message_idempotency(
        scope.group_id,
        scope.conversation_id,
        Crypto.hex(record["request_identity"])
      )

    put_json!(key, record)
    key
  end

  defp put_reservations!(scope, count) do
    for index <- 1..count do
      record = %{
        "status" => "reserved",
        "message_id" => Ids.new_message_id(),
        "request_identity" => "reservation #{index}",
        "request_fingerprint" => "original fingerprint",
        "created_at" => 777
      }

      {put_pointer!(scope, record, :request), record}
    end
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp pointer_gets(keys), do: for({:get, key} <- S3.Fake.read_log(), key in keys, do: key)

  defp put_related!(kind, scope, count) do
    for index <- 1..count do
      record = %{
        "agent_group_id" => scope.group_id,
        "conversation_id" => scope.conversation_id,
        "participant_id" => "opaque member #{index}",
        "actor_type" => "provider",
        "state" => "inactive",
        "notification_filter" => %{"messages" => "none", "statuses" => "none"}
      }

      {key, record} =
        if kind == :participant do
          {Keys.ctl_group_conversation_participant_state(
             scope.group_id,
             scope.conversation_id,
             record["participant_id"]
           ), record}
        else
          put_json!(
            Keys.ctl_group_conversation_participant_state(
              scope.group_id,
              scope.conversation_id,
              record["participant_id"]
            ),
            record
          )

          record =
            Map.merge(record, %{
              "delivery_id" => "opaque delivery #{index}",
              "status" => "unknown"
            })

          {Keys.ctl_group_conversation_participant_delivery_state(
             scope.group_id,
             scope.conversation_id,
             record["participant_id"],
             record["delivery_id"]
           ), record}
        end

      put_json!(key, record)
      {key, record}
    end
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp read_related(kind, scope, record) do
    participant_scope =
      ParticipantPG.new(scope.group_id, scope.conversation_id, record["participant_id"])

    if kind == :participant,
      do: ParticipantPG.read(participant_scope),
      else: ParticipantPG.read_delivery(participant_scope, record["delivery_id"])
  end

  defp assert_related!(kind, scope, records) do
    for {_key, record} <- records,
        do: assert({:ok, ^record, 1} = read_related(kind, scope, record))
  end

  defp assert_reservations!(scope, pointers) do
    for {_key, record} <- pointers do
      assert {:ok, identity} =
               ConversationPGStore.identity_by_request_identity(scope, record["request_identity"])

      assert identity["message_id"] == record["message_id"]
      assert identity["seq"] == nil
    end
  end

  defp put_json!(key, value), do: assert({:ok, _} = S3.put(key, Jason.encode!(value)))
end
