defmodule SalixStore.ConversationSearchTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_search_jobs]

  alias SalixStore.{ConversationSearch, Repo, SearchDocumentEnvelope}

  @generation "test-search-generation"
  @marker "conversation_search_projection_v1"

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :conversation_search_writer_generation)
    SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, @generation)

    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_states, " <>
        "conversation_search_discovery_cursors, conversation_search_backfill_runs CASCADE"
    )

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])
    seed_ready(@generation)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_store, :conversation_search_writer_generation),
        else:
          SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, previous)
    end)

    :ok
  end

  test "mail lookup is scoped and changed association forces message rebuild" do
    snapshot = %{
      group_id: "group-mail",
      conversation_id: "task-mail",
      title_envelope: SearchDocumentEnvelope.build(:title, "Mail Task"),
      source_version: 1,
      message_head_seq: 1,
      message_tail_seq: 1,
      mail_account_id: "account-a",
      mail_thread_id: "thread-a"
    }

    assert :ok = ConversationSearch.enqueue_rebuild("group-mail", "task-mail")
    assert {:ok, claim} = ConversationSearch.claim_one("mail-projector", 30_000)

    assert :ok =
             ConversationSearch.replace_task(claim, snapshot, [message("mail-1", 1, "source")])

    assert :ok = ConversationSearch.complete(claim)

    assert {:ok, [%{conversation_id: "task-mail"}]} =
             ConversationSearch.mail_tasks("group-mail", "account-a", ["thread-a"])

    assert {:ok, []} = ConversationSearch.mail_tasks("other-group", "account-a", ["thread-a"])
    assert {:ok, []} = ConversationSearch.mail_tasks("group-mail", "other-account", ["thread-a"])
    assert :ok = ConversationSearch.enqueue_message("group-mail", "task-mail", "mail-2", 2)
    assert {:ok, append} = ConversationSearch.claim_one("mail-projector", 30_000)
    changed = %{snapshot | source_version: 2, message_tail_seq: 2, mail_thread_id: "thread-b"}

    assert {:error, :requires_rebuild} =
             ConversationSearch.apply_message(append, changed, message("mail-2", 2, "reply"))

    assert :ok =
             ConversationSearch.replace_task(append, changed, [
               message("mail-1", 1, "source"),
               message("mail-2", 2, "reply")
             ])

    assert :ok = ConversationSearch.complete(append)
    assert {:ok, []} = ConversationSearch.mail_tasks("group-mail", "account-a", ["thread-a"])

    assert {:ok, [%{conversation_id: "task-mail"}]} =
             ConversationSearch.mail_tasks("group-mail", "account-a", ["thread-b"])
  end

  test "atomic replacement inserts title and differently sized message gram arrays" do
    project("group-a", "task-a", "Alpha 🚀 plan", [
      message("message-a", 1, "tiny alpha"),
      message("message-b", 2, "a much longer alpha message with many different bigrams")
    ])

    project("group-b", "task-b", "Alpha elsewhere", [])

    assert {:ok, [%{"conversation_id" => "task-a"} = title_hit]} =
             ConversationSearch.search("group-a", "alpha")

    assert title_hit["matched_field"] == "title"
    assert title_hit["snippet"] == title_hit["title"]
    assert title_hit["updated_at"] == 2
    assert_utf16_highlight(title_hit, "Alpha")

    assert %{"snippet" => content_snippet} = content_match = title_hit["content_match"]
    assert content_snippet == "a much longer alpha message with many different bigrams"
    assert_utf16_highlight(content_match, "alpha")

    assert {:ok, [%{"conversation_id" => "task-a", "matched_field" => "content"}]} =
             ConversationSearch.search("group-a", "longer alpha")
  end

  test "two-codepoint CJK and English plus punctuation use bigram acceleration and exact fold" do
    project("group-short", "task-short", "AI 深色 Budget 50%_done ---", [])

    for query <- ["AI", "深色", "50%", "---"] do
      assert {:ok, [%{"conversation_id" => "task-short"} = title_only_hit]} =
               ConversationSearch.search("group-short", query)

      refute Map.has_key?(title_only_hit, "content_match")
    end

    assert {:ok, []} = ConversationSearch.search("group-short", "50_")
    assert {:error, :invalid} = ConversationSearch.search("group-short", "A")
    assert {:error, :invalid} = ConversationSearch.search("group-short", "A" <> <<0>>)
  end

  test "fresh begin atomically unseals an older generation and fences stale seal/read" do
    project("group-rollout", "task-rollout", "Visible in A", [])
    assert {:ok, [_hit]} = ConversationSearch.search("group-rollout", "Visible")

    SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")
    assert :ok = ConversationSearch.begin_backfill("generation-b")

    SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, @generation)
    assert {:error, :unavailable} = ConversationSearch.search("group-rollout", "Visible")
    assert {:error, :not_ready} = ConversationSearch.seal_backfill(@generation)
  end

  test "queue coalesces per Task and fences stale or expired claimants" do
    assert :ok = ConversationSearch.enqueue_message("group-job", "task-job", "message-1", 1)
    assert :ok = ConversationSearch.enqueue_message("group-job", "task-job", "message-2", 2)

    assert {:ok, first} = ConversationSearch.claim_one("worker-a", 30_000)
    assert first.operation == :rebuild

    assert :ok = ConversationSearch.enqueue_delete("group-job", "task-job")
    assert {:error, :claim_lost} = ConversationSearch.complete(first)

    assert {:ok, second} = ConversationSearch.claim_one("worker-b", 30_000)
    assert second.operation == :delete
    assert :ok = ConversationSearch.renew_job_claim(second, 30_000)
    assert :ok = ConversationSearch.apply_delete(second)
    assert :ok = ConversationSearch.complete(second)
  end

  defp project(group_id, conversation_id, title, messages) do
    head = if messages == [], do: 0, else: hd(messages).seq
    tail = if messages == [], do: 0, else: List.last(messages).seq

    snapshot = %{
      group_id: group_id,
      conversation_id: conversation_id,
      title_envelope: SearchDocumentEnvelope.build(:title, title),
      source_version: max(tail, 1),
      message_head_seq: head,
      message_tail_seq: tail
    }

    assert :ok = ConversationSearch.enqueue_rebuild(group_id, conversation_id)
    assert {:ok, claim} = ConversationSearch.claim_one("test-projector", 30_000)
    assert :ok = ConversationSearch.replace_task(claim, snapshot, messages)
    assert :ok = ConversationSearch.complete(claim)
  end

  defp seed_ready(generation) do
    Repo.query!(
      """
      INSERT INTO conversation_search_backfill_runs
        (writer_generation, writer_barrier_authority, writer_barrier_at,
         required_discovery_cycle, sealed_at, inserted_at, updated_at)
      VALUES ($1, 'test-fixture', now(), 1, now(), now(), now())
      """,
      [generation]
    )

    Repo.query!(
      """
      INSERT INTO conversation_search_discovery_cursors
        (id, writer_generation, completed_cycles, cycle_started_at,
         last_cycle_completed_at, inserted_at, updated_at)
      VALUES ('main', $1, 1, now(), now(), now(), now())
      """,
      [generation]
    )

    Repo.query!(
      """
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ($1, now(), jsonb_build_object('writer_generation', $2::text, 'mode', 'test-fixture'))
      """,
      [@marker, generation]
    )
  end

  defp message(id, seq, content) do
    assert {:ok, %{message: message}} =
             SearchDocumentEnvelope.message_slot(%{
               id: id,
               seq: seq,
               created_at: seq,
               content: content
             })

    message
  end

  defp assert_utf16_highlight(hit, expected) do
    assert [%{"start" => start, "end" => finish}] = hit["highlights"]
    assert utf16_slice(hit["snippet"], start, finish) == expected
  end

  defp utf16_slice(value, start, finish) do
    utf16 = :unicode.characters_to_binary(value, :utf8, {:utf16, :little})
    bytes = binary_part(utf16, start * 2, (finish - start) * 2)
    :unicode.characters_to_binary(bytes, {:utf16, :little}, :utf8)
  end
end
