defmodule SalixIM.ConversationArchiveTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationMessage, ConversationPGStore}
  alias SalixStore.{Ids, Keys, Repo, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    scope =
      ConversationPGStore.new(Ids.new_group_id(Ids.new_tenant_id()), Ids.new_conversation_id())

    assert {:ok, :inserted, _, 1} = ConversationPGStore.create(scope, %{"kind" => "agent_task"})

    on_exit(fn ->
      Repo.query!("DELETE FROM conversation_search_jobs WHERE agent_group_id=$1", [scope.group_id])

      Repo.query!("DELETE FROM conversation_log_recovery WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_conversation_archives WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_conversation_messages WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [scope.group_id])

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    {:ok, scope: scope}
  end

  test "a landed JSONL cut is adopted after catalog rollback without rewriting its first-seq object",
       %{scope: scope} do
    first = append!(scope, "first")
    second = append!(scope, "second")
    assert {:ok, frozen} = ConversationPGStore.prepare_archive(scope, 2)
    key = frozen.record.object_key
    assert {:ok, %{body: original}} = S3.get(key)

    Repo.query!(
      "ALTER TABLE salix_conversation_archives ADD CONSTRAINT archive_reject CHECK (conversation_id <> '#{scope.conversation_id}') NOT VALID"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE salix_conversation_archives DROP CONSTRAINT IF EXISTS archive_reject"
      )
    end)

    assert {:error, {:rollback, :check_violation}} = ConversationPGStore.execute(frozen)
    Repo.query!("ALTER TABLE salix_conversation_archives DROP CONSTRAINT archive_reject")

    assert {:ok, adopted} = ConversationPGStore.prepare_archive(scope, 3)
    assert adopted.record.last_seq == 2
    third = append!(scope, "third")
    assert {:ok, descriptor} = ConversationPGStore.execute(adopted)
    assert {:ok, ^descriptor} = ConversationPGStore.execute(frozen)
    assert {:ok, %{body: ^original}} = S3.get(key)
    assert {:ok, [^first, ^second, ^third]} = ConversationPGStore.messages(scope, 1, 3, 3)

    assert %{rows: [[nil], [nil], [hot]]} =
             Repo.query!(
               "SELECT payload FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 ORDER BY seq",
               [scope.group_id, scope.conversation_id]
             )

    assert is_binary(hot)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_archives WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )
  end

  @tag :archive_eviction
  test "publication and hot-body eviction commit together", %{scope: scope} do
    original = append!(scope, "atomic eviction")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, _} = ConversationPGStore.execute(pending)

    assert %{rows: [[nil, 1]]} =
             Repo.query!(
               "SELECT payload, archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )

    assert {:ok, ^original} = ConversationPGStore.message_by_id(scope, original["message_id"])
  end

  test "nested atom-key input converges with an adopted JSONL span and a cold sibling", %{
    scope: scope
  } do
    input =
      message("private input")
      |> Map.put("agent_input", %{
        kind: "message",
        content: [%{type: "text", text: "private context"}],
        billing: %{credits: 1}
      })

    assert {:ok, :inserted, _, _, _} = ConversationPGStore.append(scope, 1, input)
    assert {:ok, original} = ConversationPGStore.message_by_id(scope, input["message_id"])
    sibling = append!(scope, "cold sibling")
    assert {:ok, uploaded} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, descriptor} = ConversationPGStore.execute(uploaded)

    # Recreate a partial publication with one hot record beside its cold sibling.
    Repo.query!(
      "UPDATE salix_conversation_messages SET payload=$4,archive_first_seq=NULL WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
      [
        scope.group_id,
        scope.conversation_id,
        original["message_id"],
        :erlang.term_to_binary(original)
      ]
    )

    assert %{rows: [[nil, 1]]} =
             Repo.query!(
               "SELECT payload,archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
               [scope.group_id, scope.conversation_id, sibling["message_id"]]
             )

    assert {:ok, adopted} = ConversationPGStore.prepare_archive(scope, 10)
    assert adopted.record.object_key == descriptor.object_key
    assert {:ok, ^descriptor} = ConversationPGStore.execute(adopted)

    assert %{rows: [[nil, 1], [nil, 1]]} =
             Repo.query!(
               "SELECT payload,archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 ORDER BY seq",
               [scope.group_id, scope.conversation_id]
             )

    expected =
      Map.put(original, "agent_input", %{
        "kind" => "message",
        "content" => [%{"type" => "text", "text" => "private context"}],
        "billing" => %{"credits" => 1}
      })

    assert {:ok, ^expected} = ConversationPGStore.message_by_id(scope, original["message_id"])
    assert {:ok, ^sibling} = ConversationPGStore.message_by_id(scope, sibling["message_id"])
    assert {:ok, :empty} = ConversationPGStore.prepare_archive(scope, 10)
  end

  @tag :archive_eviction
  test "a changed archived message is archived again and captured readers retain their old body",
       %{scope: scope} do
    original = append!(scope, "rearchive")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, old} = ConversationPGStore.execute(pending)
    assert {:ok, [snapshot]} = ConversationPGStore.message_snapshots(scope, "m.seq=$3", [1])

    assert {:ok, backfill} = ConversationPGStore.prepare_backfill_message_threads(scope, 0)
    assert {:ok, %{updated: 1}} = ConversationPGStore.execute(backfill)
    assert {:ok, changed} = ConversationPGStore.message_by_id(scope, original["message_id"])
    assert changed["thread_root_message_id"] == original["message_id"]

    assert {:ok, %ConversationPGStore.Pending{} = replacement} =
             ConversationPGStore.prepare_archive(scope, 10)

    assert {:ok, current} = ConversationPGStore.execute(replacement)
    assert current.object_key != old.object_key
    assert {:ok, ^changed} = ConversationPGStore.message_by_id(scope, original["message_id"])
    assert {:ok, ^original} = ConversationPGStore.message_from_snapshot(snapshot)

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT payload FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )
  end

  test "a larger current body splits a span while its untouched suffix and captured readers remain readable",
       %{scope: scope} do
    first = append!(scope, "first in span")
    second = append!(scope, "second in span")
    third = append!(scope, "untouched suffix")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, old} = ConversationPGStore.execute(pending)
    assert {:ok, [snapshot]} = ConversationPGStore.message_snapshots(scope, "m.seq=$3", [1])

    large = put_in(first, ["metadata", "detail"], String.duplicate("x", 1_010_000))
    changed = put_in(second, ["metadata", "detail"], String.duplicate("y", 600_000))
    replace!(scope, large)
    replace!(scope, changed)
    assert {:ok, prefix} = ConversationPGStore.prepare_archive(scope, 10)
    assert prefix.record.last_seq == 1
    assert {:ok, _} = ConversationPGStore.execute(prefix)
    assert {:ok, ^large} = ConversationPGStore.message_by_id(scope, first["message_id"])
    assert {:ok, ^third} = ConversationPGStore.message_by_id(scope, third["message_id"])
    assert {:ok, ^first} = ConversationPGStore.message_from_snapshot(snapshot)

    assert {:ok, suffix} = ConversationPGStore.prepare_archive(scope, 10)
    assert suffix.record.first_seq == 2
    assert {:ok, _} = ConversationPGStore.execute(suffix)
    assert {:ok, [^large, ^changed, ^third]} = ConversationPGStore.messages(scope, 1, 3, 3)
    assert {:ok, _} = S3.get(old.object_key)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 AND payload IS NOT NULL",
               [scope.group_id, scope.conversation_id]
             )
  end

  test "an unavailable archive write retains every current hot body", %{scope: scope} do
    original = append!(scope, "upload failure")

    prefix =
      Keys.ctl_group_conversation_messages_segments_prefix(scope.group_id, scope.conversation_id)

    S3.Fake.blackhole({:fail, 503, :put, {:prefix, prefix}})
    assert {:error, _} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, ^original} = ConversationPGStore.message_by_id(scope, original["message_id"])

    assert %{rows: [[true, nil]]} =
             Repo.query!(
               "SELECT payload IS NOT NULL, archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )
  end

  test "a legacy published pointer uses S3 while residual hot-body cleanup retries",
       %{scope: scope} do
    first = append!(scope, "snapshot")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, descriptor} = ConversationPGStore.execute(pending)

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload=$3 WHERE group_id=$1 AND conversation_id=$2",
      [scope.group_id, scope.conversation_id, :erlang.term_to_binary(first)]
    )

    assert {:ok, [snapshot]} = ConversationPGStore.message_snapshots(scope, "m.seq=$3", [1])
    assert is_binary(snapshot.payload)

    Repo.query!(
      "ALTER TABLE salix_conversation_messages ADD CONSTRAINT archive_cleanup_reject CHECK (conversation_id <> '#{scope.conversation_id}' OR payload IS NOT NULL) NOT VALID"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE salix_conversation_messages DROP CONSTRAINT IF EXISTS archive_cleanup_reject"
      )
    end)

    assert {:ok, frozen_cleanup} = ConversationPGStore.prepare_cleanup_archive_bodies(scope, 10)
    assert {:error, {:rollback, :check_violation}} = ConversationPGStore.execute(frozen_cleanup)
    assert :ok = S3.delete(descriptor.object_key)

    assert {:error, :archive_incomplete} =
             ConversationPGStore.message_by_id(scope, first["message_id"])

    assert {:ok, _} =
             S3.put(descriptor.object_key, Jason.encode!(first) <> "\n", if_none_match: "*")

    :ok = S3.Fake.blackhole({:fail, 503, :get, descriptor.object_key})

    assert {:error, :archive_unreadable} =
             ConversationPGStore.message_by_id(scope, first["message_id"])

    :ok = S3.Fake.clear_blackhole()
    Repo.query!("ALTER TABLE salix_conversation_messages DROP CONSTRAINT archive_cleanup_reject")

    cleanup!(scope)
    refute Repo.in_transaction?()
    assert {:ok, ^first} = ConversationPGStore.message_from_snapshot(snapshot)
    assert {:ok, ^first} = ConversationPGStore.message_by_id(scope, first["message_id"])

    Repo.query!(
      "UPDATE salix_conversation_messages SET tombstone=true, revision=revision+1 WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
      [scope.group_id, scope.conversation_id, first["message_id"]]
    )

    assert :ok = S3.delete(descriptor.object_key)
    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, first["message_id"])
  end

  test "a changed message uses its current revision without replacing the orphan's old body", %{
    scope: scope
  } do
    original = append!(scope, "original")
    second = append!(scope, "unchanged")
    assert {:ok, orphan} = ConversationPGStore.prepare_archive(scope, 10)
    edited = put_in(original, ["content"], [%{"type" => "text", "text" => "edited after upload"}])
    replace!(scope, edited)
    assert {:ok, adopted} = ConversationPGStore.prepare_archive(scope, 10)

    assert Enum.map(adopted.record.candidates, & &1.message_id) ==
             [original["message_id"], second["message_id"]]

    assert adopted.record.object_key != orphan.record.object_key
    assert {:ok, _} = ConversationPGStore.execute(adopted)
    assert {:ok, ^edited} = ConversationPGStore.message_by_id(scope, original["message_id"])
    assert {:ok, ^second} = ConversationPGStore.message_by_id(scope, second["message_id"])
    assert {:ok, :empty} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, %{body: body}} = S3.get(orphan.record.object_key)
    assert Jason.decode!(hd(String.split(body, "\n", trim: true))) == original
  end

  test "publication skips changed candidate revisions and backfill clears cold pointers without changing the old segment",
       %{scope: scope} do
    first = append!(scope, "first")
    second = append!(scope, "second")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    edited = Map.put(first, "content", [%{"type" => "text", "text" => "new body"}])
    replace!(scope, edited)
    assert {:ok, descriptor} = ConversationPGStore.execute(pending)

    assert %{rows: [[nil], [1]]} =
             Repo.query!(
               "SELECT archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 ORDER BY seq",
               [scope.group_id, scope.conversation_id]
             )

    Repo.query!(
      "UPDATE salix_conversation_messages SET payload=$4 WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
      [
        scope.group_id,
        scope.conversation_id,
        second["message_id"],
        :erlang.term_to_binary(second)
      ]
    )

    assert {:ok, cleanup} = ConversationPGStore.prepare_cleanup_archive_bodies(scope, 10)
    assert {:ok, backfill} = ConversationPGStore.prepare_backfill_message_threads(scope, 0)
    assert {:ok, %{updated: 2}} = ConversationPGStore.execute(backfill)
    assert {:ok, :more} = ConversationPGStore.execute(cleanup)
    assert {:ok, messages} = ConversationPGStore.messages(scope, 1, 2, 2)
    assert Enum.map(messages, & &1["content"]) == [edited["content"], second["content"]]
    assert Enum.all?(messages, &is_binary(&1["thread_root_message_id"]))

    assert %{rows: [[nil], [nil]]} =
             Repo.query!(
               "SELECT archive_first_seq FROM salix_conversation_messages WHERE group_id=$1 AND conversation_id=$2 ORDER BY seq",
               [scope.group_id, scope.conversation_id]
             )

    assert {:ok, %ConversationPGStore.Pending{} = replacement} =
             ConversationPGStore.prepare_archive(scope, 10)

    assert {:ok, _} = ConversationPGStore.execute(replacement)
    assert {:ok, %{body: body}} = S3.get(descriptor.object_key)
    assert String.contains?(body, "\"text\":\"first\"")
    refute String.contains?(body, "new body")
  end

  test "a tombstone defeats a delayed archive publication and exact catalog cleanup preserves unrelated objects",
       %{scope: scope} do
    first = append!(scope, "deleted")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, _} = ConversationPGStore.execute(pending)
    assert {:ok, backfill} = ConversationPGStore.prepare_backfill_message_threads(scope, 0)
    assert {:ok, _} = ConversationPGStore.execute(backfill)
    assert {:ok, replacement} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, _} = ConversationPGStore.execute(replacement)
    assert {:ok, _} = S3.put("unrelated-object", "keep")

    orphan =
      Keys.ctl_group_conversation_message_segment(
        scope.group_id,
        scope.conversation_id,
        "unpublished-r1"
      )

    assert {:ok, _} = S3.put(orphan, "unpublished body")

    assert {:ok, _, revision} = ConversationPGStore.read(scope)

    assert {:ok, _, _, _} =
             ConversationPGStore.update(scope, revision, &Map.put(&1, "deleted_at", 5_000))

    assert {:error, :not_found} = ConversationPGStore.message_by_id(scope, first["message_id"])
    assert {:ok, cleanup} = ConversationPGStore.prepare_cleanup_archives(scope, 1)
    assert {:ok, :more} = ConversationPGStore.execute(cleanup)
    assert {:error, :not_found} = S3.get(replacement.record.object_key)
    assert {:error, :archive_cleanup_required} = ConversationPGStore.prepare_finish_delete(scope)
    assert {:ok, cleanup} = ConversationPGStore.prepare_cleanup_archives(scope, 1)
    assert {:ok, :more} = ConversationPGStore.execute(cleanup)
    assert {:error, :not_found} = S3.get(pending.record.object_key)
    assert {:ok, cleanup} = ConversationPGStore.prepare_cleanup_archives(scope, 1)
    assert {:ok, :more} = ConversationPGStore.execute(cleanup)
    assert {:error, :not_found} = S3.get(orphan)
    assert {:ok, %{body: "keep"}} = S3.get("unrelated-object")
    assert {:error, :conversation_deleted} = ConversationPGStore.execute(pending)
    assert {:ok, :empty} = ConversationPGStore.prepare_cleanup_archives(scope, 10)
  end

  test "an unknown catalog write settles the same descriptor after a real database disconnect", %{
    scope: scope
  } do
    first = append!(scope, "unknown")
    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)

    Repo.query!(
      "CREATE FUNCTION archive_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.conversation_id = '#{scope.conversation_id}' THEN PERFORM pg_terminate_backend(pg_backend_pid()); END IF; RETURN NEW; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER archive_disconnect BEFORE INSERT ON salix_conversation_archives FOR EACH ROW EXECUTE FUNCTION archive_disconnect()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS archive_disconnect ON salix_conversation_archives")
      Repo.query!("DROP FUNCTION IF EXISTS archive_disconnect()")
    end)

    assert {:error, :commit_indeterminate} = ConversationPGStore.execute(pending)
    Repo.query!("DROP TRIGGER archive_disconnect ON salix_conversation_archives")
    Repo.query!("DROP FUNCTION archive_disconnect()")
    assert {:ok, descriptor} = ConversationPGStore.settle(pending)
    assert descriptor.object_key == pending.record.object_key
    assert {:ok, ^first} = ConversationPGStore.message_by_id(scope, first["message_id"])
  end

  test "legacy missing fingerprints remain absent in cold bodies and request conflicts never fabricate one",
       %{scope: scope} do
    original = message("legacy") |> Map.delete("request_fingerprint")
    assert {:ok, :inserted, _, identity, 2} = ConversationPGStore.append(scope, 1, original)

    key =
      Keys.ctl_group_conversation_message_segment(
        scope.group_id,
        scope.conversation_id,
        "000000000000000001"
      )

    assert {:ok, _} =
             S3.put(key, Jason.encode!(Map.put(original, "seq", 1)) <> "\n", if_none_match: "*")

    assert {:ok, pending} = ConversationPGStore.prepare_archive(scope, 10)
    assert {:ok, _} = ConversationPGStore.execute(pending)
    assert {:ok, cold} = ConversationPGStore.message_by_id(scope, original["message_id"])
    assert is_nil(cold["request_fingerprint"])
    assert {:ok, retained} = ConversationPGStore.identity_by_id(scope, original["message_id"])

    assert Map.take(retained, ~w(message_id seq request_identity)) ==
             Map.take(identity, ~w(message_id seq request_identity))

    assert is_nil(retained["request_fingerprint"])

    assert {:error, :idempotency_conflict} =
             ConversationPGStore.append(scope, 2, message("legacy"))
  end

  defp append!(scope, text) do
    assert {:ok, _, revision} = ConversationPGStore.read(scope)
    input = message(text)
    assert {:ok, :inserted, _, _, _} = ConversationPGStore.append(scope, revision, input)
    assert {:ok, body} = ConversationPGStore.message_by_id(scope, input["message_id"])
    body
  end

  defp message(text) do
    {:ok, attrs} =
      ConversationMessage.prepare(%{
        "kind" => "message",
        "actor_type" => "user",
        "client_request_id" => text,
        "content" => text
      })

    ConversationMessage.build(attrs, %{"actor_type" => "user", "user_id" => "current"}, 1_000)
  end

  defp replace!(scope, body) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE salix_conversations SET revision=revision+1 WHERE group_id=$1 AND conversation_id=$2",
        [scope.group_id, scope.conversation_id]
      )

      Repo.query!(
        "UPDATE salix_conversation_messages SET payload=$4,revision=revision+1,archive_first_seq=NULL,body_updated_at=now() WHERE group_id=$1 AND conversation_id=$2 AND message_id=$3",
        [scope.group_id, scope.conversation_id, body["message_id"], :erlang.term_to_binary(body)]
      )
    end)
  end

  defp cleanup!(scope) do
    assert {:ok, pending} = ConversationPGStore.prepare_cleanup_archive_bodies(scope, 1_000)
    assert {:ok, :more} = ConversationPGStore.execute(pending)
  end
end
