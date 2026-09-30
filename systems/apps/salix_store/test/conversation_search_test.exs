defmodule SalixStore.ConversationSearchTest do
  use ExUnit.Case, async: false

  alias SalixStore.{ConversationSearch, Repo, SearchDocumentEnvelope}

  @generation "test-search-generation"
  @marker "conversation_search_projection_v1"

  setup do
    previous = Application.get_env(:salix_store, :conversation_search_writer_generation)
    Application.put_env(:salix_store, :conversation_search_writer_generation, @generation)

    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_jobs, conversation_search_states, " <>
        "conversation_search_discovery_cursors, conversation_search_backfill_runs CASCADE"
    )

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])
    seed_ready(@generation)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_store, :conversation_search_writer_generation),
        else: Application.put_env(:salix_store, :conversation_search_writer_generation, previous)
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

  test "full replacement and exact append persist identical envelope rows" do
    messages = [
      message("parity-1", 1, "Alpha body"),
      message("parity-2", 2, "İX expansion"),
      message("parity-3", 3, "Straße finish")
      |> Map.put(:role_label, String.duplicate("unused-role", 80_000))
    ]

    project("group-parity", "task-full", "Parity Task", messages)
    project("group-parity", "task-incremental", "Parity Task", Enum.take(messages, 2))

    assert :ok =
             ConversationSearch.enqueue_message(
               "group-parity",
               "task-incremental",
               "parity-3",
               3
             )

    assert {:ok, claim} = ConversationSearch.claim_one("parity-incremental-worker", 30_000)

    snapshot = %{
      group_id: "group-parity",
      conversation_id: "task-incremental",
      title_envelope: SearchDocumentEnvelope.build(:title, "Parity Task"),
      source_version: 3,
      message_head_seq: 1,
      message_tail_seq: 3
    }

    assert :ok = ConversationSearch.apply_message(claim, snapshot, List.last(messages))
    assert :ok = ConversationSearch.complete(claim)

    assert projection_rows("group-parity", "task-full") ==
             projection_rows("group-parity", "task-incremental")
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

  test "content snippets align grapheme boundaries and expose UTF-16 ranges" do
    content =
      String.duplicate("before ", 60) <> "😀e\u0301深色 match" <> String.duplicate(" after", 90)

    project("group-unicode", "task-unicode", "Unicode task", [message("unicode", 1, content)])

    assert {:ok, [hit]} = ConversationSearch.search("group-unicode", "e\u0301深")
    assert String.starts_with?(hit["snippet"], "…")
    assert String.ends_with?(hit["snippet"], "…")
    assert_utf16_highlight(hit, "e\u0301深")

    assert {:ok, [emoji_hit]} = ConversationSearch.search("group-unicode", "😀e\u0301")
    assert_utf16_highlight(emoji_hit, "😀e\u0301")

    long_cluster = "e" <> String.duplicate("\u0301", 9_000) <> "😀x"

    project("group-long-cluster", "task-long-cluster", "Long cluster", [
      message("long-cluster", 1, long_cluster)
    ])

    assert {:ok, [cluster_hit]} =
             ConversationSearch.search("group-long-cluster", "e\u0301\u0301")

    assert byte_size(cluster_hit["snippet"]) > 16_384
    assert byte_size(cluster_hit["snippet"]) <= 32_768
    assert_utf16_highlight(cluster_hit, long_cluster |> String.graphemes() |> hd())

    assert ConversationSearch.short_grams_for_test("e\u0301") == []
    assert {:error, :invalid} = ConversationSearch.search("group-unicode", "e\u0301")
  end

  test "application Unicode fold is shared by PostgreSQL matching and original-text ranges" do
    project("group-greek-fold", "task-greek-fold", "ΟΣ Task", [])

    assert {:ok, [greek_hit]} = ConversationSearch.search("group-greek-fold", "ος")
    assert_utf16_highlight(greek_hit, "ΟΣ")

    project("group-greek-month-fold", "task-greek-month-fold", "ΜΆΪΟΣ Task", [])

    assert {:ok, [greek_month_hit]} =
             ConversationSearch.search("group-greek-month-fold", "Μάϊος")

    assert_utf16_highlight(greek_month_hit, "ΜΆΪΟΣ")

    project("group-sharp-s-fold", "task-sharp-s-fold", "Straße Task", [])

    assert {:ok, [sharp_s_hit]} =
             ConversationSearch.search("group-sharp-s-fold", "STRASSE")

    assert_utf16_highlight(sharp_s_hit, "Straße")

    project("group-sharp-s-reverse", "task-sharp-s-reverse", "STRASSE Task", [])

    assert {:ok, [sharp_s_reverse_hit]} =
             ConversationSearch.search("group-sharp-s-reverse", "Straße")

    assert_utf16_highlight(sharp_s_reverse_hit, "STRASSE")

    project("group-turkish-fold", "task-turkish-fold", "İX Task", [])

    assert {:ok, [turkish_hit]} =
             ConversationSearch.search("group-turkish-fold", "i\u0307x")

    assert_utf16_highlight(turkish_hit, "İX")

    project("group-normalization-fold", "task-normalization-fold", "Normalization", [
      message("normalization", 1, "prefix Cafe\u0301 suffix")
    ])

    assert {:ok, [normalization_hit]} =
             ConversationSearch.search("group-normalization-fold", "Café")

    assert_utf16_highlight(normalization_hit, "Cafe\u0301")

    project("group-expansion-fold", "task-expansion-fold", "ﬃ Task", [])

    assert {:ok, [expansion_hit]} = ConversationSearch.search("group-expansion-fold", "ffi")
    assert_utf16_highlight(expansion_hit, "ﬃ")
  end

  test "NUL is normalized before PostgreSQL projection" do
    project("group-nul", "task-nul", "Null" <> <<0>> <> "title", [
      message("nul-body", 1, "body" <> <<0>> <> " searchable")
    ])

    assert {:ok, [%{"title" => "Null�title"}]} =
             ConversationSearch.search("group-nul", "Null�")

    assert {:ok, [%{"snippet" => snippet}]} =
             ConversationSearch.search("group-nul", "� searchable")

    assert snippet =~ "� searchable"
  end

  test "incremental append budgets original and folded content and ignores role labels" do
    expansion = String.duplicate("İ", 1_300)

    initial_messages =
      Enum.map(1..63, fn seq ->
        message("expansion-#{seq}", seq, expansion)
        |> Map.put(:role_label, String.duplicate("unused-role", 80_000))
      end)

    project(
      "group-incremental-budget",
      "task-incremental-budget",
      "Fold budget",
      initial_messages
    )

    assert :ok =
             ConversationSearch.enqueue_message(
               "group-incremental-budget",
               "task-incremental-budget",
               "expansion-64",
               64
             )

    assert {:ok, claim} = ConversationSearch.claim_one("incremental-budget-worker", 30_000)

    snapshot = %{
      group_id: "group-incremental-budget",
      conversation_id: "task-incremental-budget",
      title_envelope: SearchDocumentEnvelope.build(:title, "Fold budget"),
      source_version: 64,
      message_head_seq: 1,
      message_tail_seq: 64
    }

    newest =
      message("expansion-64", 64, String.duplicate("İ", 6_000))
      |> Map.put(:role_label, String.duplicate("unused-role", 80_000))

    assert :ok = ConversationSearch.apply_message(claim, snapshot, newest)
    assert :ok = ConversationSearch.complete(claim)

    assert %{rows: [[count, original_bytes, budget_bytes]]} =
             Repo.query!(
               """
               SELECT count(*), sum(octet_length(content)),
                      sum(greatest(octet_length(content), octet_length(folded_content)))
               FROM conversation_search_documents
               WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
                 AND document_type = 'message'
               """,
               [@generation, "group-incremental-budget", "task-incremental-budget"]
             )

    assert count == 63
    assert original_bytes < 262_144
    assert budget_bytes <= 262_144

    assert %{rows: []} =
             Repo.query!("""
             SELECT column_name FROM information_schema.columns
             WHERE table_name = 'conversation_search_documents' AND column_name = 'role_label'
             """)
  end

  test "generated weight and storage checks mirror the application envelope" do
    projected = message("weight-message", 1, String.duplicate("İ", 1_000))
    project("group-weight", "task-weight", String.duplicate("T", 20_000), [projected])

    assert %{rows: [[content, folded_content, short_grams, weight_bytes]]} =
             Repo.query!(
               """
               SELECT content, folded_content, short_grams, weight_bytes
               FROM conversation_search_documents
               WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
                 AND document_type = 'message'
               """,
               [@generation, "group-weight", "task-weight"]
             )

    assert content == projected.envelope.content
    assert folded_content == projected.envelope.folded_content
    assert short_grams == projected.envelope.short_grams
    assert weight_bytes == projected.envelope.weight_bytes

    assert %{rows: [["ALWAYS", generation_expression]]} =
             Repo.query!("""
             SELECT is_generated, generation_expression
             FROM information_schema.columns
             WHERE table_name = 'conversation_search_documents' AND column_name = 'weight_bytes'
             """)

    assert String.downcase(generation_expression) =~
             "greatest(octet_length(content), octet_length(folded_content))"

    assert %{rows: [[constraint]]} =
             Repo.query!("""
             SELECT pg_get_constraintdef(oid)
             FROM pg_constraint
             WHERE conname = 'conversation_search_documents_shape'
             """)

    assert constraint =~ "octet_length(content) <= #{SearchDocumentEnvelope.max_bytes(:title)}"
    assert constraint =~ "octet_length(content) <= #{SearchDocumentEnvelope.max_bytes(:message)}"

    assert {:error, _generated_column_error} =
             Repo.query(
               """
               INSERT INTO conversation_search_documents
                 (writer_generation, agent_group_id, conversation_id, document_type,
                  document_id, source_id, content, folded_content, weight_bytes, short_grams)
               VALUES ($1, $2, $3, 'message', 'forged-weight', 'forged-weight',
                       'AI', 'ai', 1, ARRAY['b:ai']::text[])
               """,
               [@generation, "group-weight", "task-weight"]
             )
  end

  test "fresh begin atomically unseals an older generation and fences stale seal/read" do
    project("group-rollout", "task-rollout", "Visible in A", [])
    assert {:ok, [_hit]} = ConversationSearch.search("group-rollout", "Visible")

    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")
    assert :ok = ConversationSearch.begin_backfill("generation-b")

    Application.put_env(:salix_store, :conversation_search_writer_generation, @generation)
    assert {:error, :unavailable} = ConversationSearch.search("group-rollout", "Visible")
    assert {:error, :not_ready} = ConversationSearch.seal_backfill(@generation)
  end

  test "retired begin and writer barrier cannot replace the active generation" do
    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")
    assert :ok = ConversationSearch.begin_backfill("generation-b")

    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-c")
    assert :ok = ConversationSearch.begin_backfill("generation-c")

    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")

    assert {:error, :invalid} = ConversationSearch.begin_backfill("generation-b")

    assert {:error, :invalid} =
             ConversationSearch.record_writer_barrier(
               "generation-b",
               "stale-release-owner/rollout-b"
             )

    assert %{rows: [["generation-c"]]} =
             Repo.query!(
               "SELECT writer_generation FROM conversation_search_discovery_cursors " <>
                 "WHERE id = 'main'"
             )

    assert {:ok, %{writer_barrier_at: nil}} =
             ConversationSearch.backfill_state("generation-b")
  end

  test "begin racing seal cannot leave the retired reader marker behind" do
    Repo.query!(
      "UPDATE conversation_search_backfill_runs SET sealed_at = NULL " <>
        "WHERE writer_generation = $1",
      [@generation]
    )

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, inserted_at, updated_at)
    VALUES ('generation-b', statement_timestamp(), statement_timestamp())
    """)

    parent = self()

    new_run_locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT 1 FROM conversation_search_backfill_runs " <>
              "WHERE writer_generation = 'generation-b' FOR UPDATE"
          )

          send(parent, :new_run_locked)

          receive do
            :release_new_run -> :ok
          after
            10_000 -> Repo.rollback(:lock_barrier_timeout)
          end
        end)
      end)

    assert_receive :new_run_locked, 1_000
    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")

    begin_task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:begin_backend, backend_pid})
          ConversationSearch.begin_backfill("generation-b")
        end)
      end)

    assert_receive {:begin_backend, begin_backend}, 1_000
    await_backend_lock!(begin_backend)

    Application.put_env(:salix_store, :conversation_search_writer_generation, @generation)

    seal_task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:seal_backend, backend_pid})
          ConversationSearch.seal_backfill(@generation)
        end)
      end)

    assert_receive {:seal_backend, seal_backend}, 1_000
    seal_before_release = await_backend_lock_or_result!(seal_task, seal_backend)

    send(new_run_locker.pid, :release_new_run)
    assert {:ok, :ok} = Task.await(new_run_locker, 1_000)
    assert :ok = Task.await(begin_task, 1_000)

    seal_result =
      case seal_before_release do
        {:result, result} -> result
        :locked -> Task.await(seal_task, 1_000)
      end

    assert {:error, :not_ready} = seal_result

    assert %{rows: [["generation-b"]]} =
             Repo.query!(
               "SELECT writer_generation FROM conversation_search_discovery_cursors " <>
                 "WHERE id = 'main'"
             )

    assert %{rows: []} =
             Repo.query!("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker])
  end

  test "writer barrier is one-shot, discards pre-barrier jobs, and requires a later cycle" do
    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")
    assert :ok = ConversationSearch.begin_backfill("generation-b")
    assert :ok = ConversationSearch.enqueue_rebuild("group-b", "task-before-barrier")

    assert :ok =
             ConversationSearch.record_writer_barrier("generation-b", "release-owner/rollout-42")

    assert {:ok, 0} = ConversationSearch.pending_job_count()
    assert {:error, :invalid} = ConversationSearch.begin_backfill("generation-b")

    assert {:error, :invalid} =
             ConversationSearch.record_writer_barrier("generation-b", "release-owner/retry")

    assert {:error, :not_ready} = ConversationSearch.seal_backfill("generation-b")

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors SET completed_cycles = 1 " <>
        "WHERE id = 'main' AND writer_generation = 'generation-b'"
    )

    assert :ok = ConversationSearch.seal_backfill("generation-b")
  end

  test "different workers apply concurrently while begin remains fenced" do
    project("group-parallel", "task-parallel-a", "Parallel A", [])
    project("group-parallel", "task-parallel-b", "Parallel B", [])

    assert :ok = ConversationSearch.enqueue_rebuild("group-parallel", "task-parallel-a")
    assert {:ok, first_claim} = ConversationSearch.claim_one("parallel-worker-a", 30_000)
    assert first_claim.conversation_id == "task-parallel-a"

    assert :ok = ConversationSearch.enqueue_rebuild("group-parallel", "task-parallel-b")
    assert {:ok, second_claim} = ConversationSearch.claim_one("parallel-worker-b", 30_000)
    assert second_claim.conversation_id == "task-parallel-b"

    parent = self()

    first_locker = lock_projection_state(parent, "task-parallel-a", :first_state_locked)
    second_locker = lock_projection_state(parent, "task-parallel-b", :second_state_locked)
    assert_receive :first_state_locked, 1_000
    assert_receive :second_state_locked, 1_000

    first_apply = apply_blocked_snapshot(parent, first_claim, "Parallel A updated", 2)
    assert_receive {:apply_backend, "task-parallel-a", first_backend}, 1_000
    await_backend_lock!(first_backend)

    second_apply = apply_blocked_snapshot(parent, second_claim, "Parallel B updated", 2)
    assert_receive {:apply_backend, "task-parallel-b", second_backend}, 1_000
    await_backend_lock!(second_backend)

    send(second_locker.pid, :release_projection_state)
    assert {:ok, :ok} = Task.await(second_locker, 1_000)
    second_before_first_release = Task.yield(second_apply, 1_000)

    send(first_locker.pid, :release_projection_state)
    assert {:ok, :ok} = Task.await(first_locker, 1_000)
    assert :ok = Task.await(first_apply, 1_000)

    second_result =
      case second_before_first_release do
        nil -> Task.await(second_apply, 1_000)
        {:ok, result} -> result
      end

    assert second_before_first_release == {:ok, :ok}
    assert second_result == :ok
  end

  test "retired generation GC is fenced, resumable, and cannot race a stale claimant" do
    project("group-old", "task-old", "Old alpha", [
      message("old-1", 1, "old alpha one"),
      message("old-2", 2, "old alpha two")
    ])

    project("group-old", "task-delete", "Old delete", [])

    assert :ok = ConversationSearch.enqueue_rebuild("group-old", "task-old")
    assert {:ok, old_claim} = ConversationSearch.claim_one("old-writer", 30_000)
    assert :ok = ConversationSearch.enqueue_delete("group-old", "task-delete")
    assert {:ok, old_delete_claim} = ConversationSearch.claim_one("old-writer", 30_000)
    assert {:error, :active} = ConversationSearch.gc_retired_generation(@generation)

    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")
    assert {:error, :ready} = ConversationSearch.gc_retired_generation(@generation)

    Repo.query!(
      "UPDATE conversation_search_backfill_runs " <>
        "SET sealed_at = statement_timestamp() - interval '1000 hours' " <>
        "WHERE writer_generation = $1",
      [@generation]
    )

    assert :ok = ConversationSearch.begin_backfill("generation-b")
    assert {:error, :too_young} = ConversationSearch.gc_retired_generation(@generation)

    assert %{rows: [[retired_at]]} =
             Repo.query!(
               "SELECT retired_at FROM conversation_search_backfill_runs " <>
                 "WHERE writer_generation = $1",
               [@generation]
             )

    refute is_nil(retired_at)

    Application.put_env(:salix_store, :conversation_search_writer_generation, @generation)

    assert {:error, :claim_lost} = ConversationSearch.renew_job_claim(old_claim, 30_000)

    stale_snapshot = %{
      group_id: "group-old",
      conversation_id: "task-old",
      title_envelope: SearchDocumentEnvelope.build(:title, "Late stale write"),
      source_version: 99,
      message_head_seq: 0,
      message_tail_seq: 0
    }

    assert {:error, :claim_lost} =
             ConversationSearch.replace_task(old_claim, stale_snapshot, [])

    assert {:error, :claim_lost} = ConversationSearch.apply_delete(old_delete_claim)
    assert {:error, :claim_lost} = ConversationSearch.complete(old_claim)
    assert {:error, :claim_lost} = ConversationSearch.retry(old_delete_claim, :late_retry)

    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")

    assert :ok =
             ConversationSearch.record_writer_barrier(
               "generation-b",
               "release-owner/gc-regression"
             )

    project_unsealed("group-new", "task-new", "New beta", [])

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors SET completed_cycles = 1 " <>
        "WHERE id = 'main' AND writer_generation = 'generation-b'"
    )

    assert :ok = ConversationSearch.seal_backfill("generation-b")

    assert {:ok, [%{"conversation_id" => "task-new"}]} =
             ConversationSearch.search("group-new", "beta")

    previous_retention =
      Application.get_env(:salix_store, :conversation_search_gc_retention_hours)

    Application.put_env(:salix_store, :conversation_search_gc_retention_hours, 0)

    on_exit(fn ->
      if is_nil(previous_retention),
        do: Application.delete_env(:salix_store, :conversation_search_gc_retention_hours),
        else:
          Application.put_env(
            :salix_store,
            :conversation_search_gc_retention_hours,
            previous_retention
          )
    end)

    assert {:error, :too_young} = ConversationSearch.gc_retired_generation(@generation)

    Repo.query!(
      "UPDATE conversation_search_backfill_runs " <>
        "SET retired_at = statement_timestamp() - interval '169 hours' " <>
        "WHERE writer_generation = $1",
      [@generation]
    )

    assert {:ok, %{phase: :documents, deleted_in_batch: 1, done: false} = first} =
             ConversationSearch.gc_retired_generation(@generation, batch_size: 1)

    assert first.cursor != %{}
    assert {:ok, %{done: true}} = finish_gc(@generation, 32)

    Application.put_env(:salix_store, :conversation_search_writer_generation, @generation)
    assert {:error, :invalid} = ConversationSearch.begin_backfill(@generation)
    Application.put_env(:salix_store, :conversation_search_writer_generation, "generation-b")

    for table <- [
          "conversation_search_documents",
          "conversation_search_states",
          "conversation_search_jobs",
          "conversation_search_backfill_runs"
        ] do
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE writer_generation = $1", [
                 @generation
               ])
    end

    assert {:ok, [%{"conversation_id" => "task-new"}]} =
             ConversationSearch.search("group-new", "beta")
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

  test "late rebuild after an admitted delete settles only when projection state is absent" do
    project("group-race", "task-race", "Race alpha", [])
    assert :ok = ConversationSearch.enqueue_delete("group-race", "task-race")
    assert {:ok, delete_claim} = ConversationSearch.claim_one("delete-writer", 30_000)
    assert :ok = ConversationSearch.apply_delete(delete_claim)
    assert :ok = ConversationSearch.complete(delete_claim)

    assert :ok = ConversationSearch.enqueue_rebuild("group-race", "task-race")
    assert {:ok, late_claim} = ConversationSearch.claim_one("late-scanner", 30_000)
    assert {:ok, true} = ConversationSearch.missing_source_safe_noop?(late_claim)
    assert :ok = ConversationSearch.complete(late_claim)
    assert {:ok, []} = ConversationSearch.search("group-race", "alpha")
    assert {:ok, 0} = ConversationSearch.pending_job_count()
  end

  test "hostile 32-KiB text has a bounded lossless bigram set" do
    content = String.duplicate(Enum.join(Enum.map(0..127, &<<&1>>)), 256)
    content = binary_part(content, 0, 32_768)
    grams = ConversationSearch.short_grams_for_test(content)

    assert length(grams) <= 32_768
    assert Enum.all?(grams, &String.starts_with?(&1, "b:"))
  end

  test "production query uses bounded indexed candidates with the default planner" do
    Repo.query!("""
    INSERT INTO conversation_search_states
      (writer_generation, agent_group_id, conversation_id, conversation_kind, title,
       source_version, message_head_seq, message_tail_seq, updated_at)
    SELECT '#{@generation}', 'group-explain', 'task-' || value, 'agent_task', '',
           value, 0, 0, now()
    FROM generate_series(1, 20000) AS value
    """)

    Repo.query!("""
    INSERT INTO conversation_search_states
      (writer_generation, agent_group_id, conversation_id, conversation_kind, title,
       source_version, message_head_seq, message_tail_seq, updated_at)
    SELECT '#{@generation}', 'unrelated-' || (value % 10), 'other-' || value,
           'agent_task', '', value, 0, 0, now()
    FROM generate_series(1, 10000) AS value
    """)

    # Keep the planner fixture cardinality without one long GIN-indexed insert.
    for first <- 1..20_000//2_000 do
      Repo.query!(
        """
        INSERT INTO conversation_search_documents
          (writer_generation, agent_group_id, conversation_id, document_type, document_id,
           source_id, content, folded_content, short_grams, updated_at)
        SELECT '#{@generation}', 'group-explain', 'task-' || value, 'title', 'title', 'title',
           CASE WHEN value = 20000 THEN 'alpha 深色 50% --- common'
                ELSE 'common ordinary document ' || value END,
           CASE WHEN value = 20000 THEN 'alpha 深色 50% --- common'
                ELSE 'common ordinary document ' || value END,
           CASE WHEN value = 20000
             THEN ARRAY['b:al','b:lp','b:ph','b:ha','b:深色','b:50','b:0%','b:--',
                        'b:co','b:om','b:mm','b:mo','b:on']::text[]
             ELSE ARRAY['b:co','b:om','b:mm','b:mo','b:on','b:or']::text[] END,
           now()
        FROM generate_series($1::integer, $2::integer) AS value
        """,
        [first, first + 1_999]
      )
    end

    for first <- 1..10_000//2_000 do
      Repo.query!(
        """
        INSERT INTO conversation_search_documents
          (writer_generation, agent_group_id, conversation_id, document_type, document_id,
           source_id, content, folded_content, short_grams, updated_at)
        SELECT '#{@generation}', 'unrelated-' || (value % 10), 'other-' || value,
               'title', 'title', 'title', 'unrelated zzz document ' || value,
               'unrelated zzz document ' || value,
               ARRAY['b:un','b:zz']::text[], now()
        FROM generate_series($1::integer, $2::integer) AS value
        """,
        [first, first + 1_999]
      )
    end

    Repo.query!("""
    INSERT INTO conversation_search_documents
      (writer_generation, agent_group_id, conversation_id, document_type, document_id,
       source_id, source_seq, source_created_at, content, folded_content,
       short_grams, updated_at)
    SELECT '#{@generation}', 'group-explain', 'task-' || value, 'message',
           'message-' || value, 'message-' || value, 1, value,
           'common message ' || value, 'common message ' || value,
           ARRAY['b:co','b:om','b:mm','b:mo','b:on']::text[], now()
    FROM generate_series(1, 1000) AS value
    """)

    # Finish the bulk fixture's pending GIN writes before checking the steady
    # query plan. ANALYZE alone leaves this dependent on autovacuum timing.
    Repo.query!("VACUUM (ANALYZE) conversation_search_documents")

    for query <- ["alpha", "深色", "50%", "---", "common"] do
      assert {:ok, plan} = ConversationSearch.explain_for_test("group-explain", query, limit: 5)
      encoded = Jason.encode!(plan)

      if query == "common" do
        assert encoded =~ "conversation_search_documents_group_short_grams_idx" or
                 encoded =~ "conversation_search_documents_scope_idx"
      else
        assert encoded =~ "conversation_search_documents_group_short_grams_idx"
      end

      assert cte_actual_rows(plan, "CTE title_documents") <= 5
      assert cte_actual_rows(plan, "CTE message_documents") <= 5 * 64
    end

    assert {:ok, restricted_plan} =
             ConversationSearch.explain_for_test("group-explain", "common",
               limit: 5,
               conversation_id: "task-20000"
             )

    restricted = Jason.encode!(restricted_plan)
    assert restricted =~ "conversation_search_documents_scope_idx"
    assert restricted =~ "task-20000"
  end

  defp lock_projection_state(parent, conversation_id, message) do
    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          """
          SELECT 1
          FROM conversation_search_states
          WHERE writer_generation = $1 AND agent_group_id = 'group-parallel'
            AND conversation_id = $2
          FOR UPDATE
          """,
          [@generation, conversation_id]
        )

        send(parent, message)

        receive do
          :release_projection_state -> :ok
        after
          10_000 -> Repo.rollback(:lock_barrier_timeout)
        end
      end)
    end)
  end

  defp apply_blocked_snapshot(parent, claim, title, source_version) do
    snapshot = %{
      group_id: claim.agent_group_id,
      conversation_id: claim.conversation_id,
      title_envelope: SearchDocumentEnvelope.build(:title, title),
      source_version: source_version,
      message_head_seq: 0,
      message_tail_seq: 0
    }

    Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:apply_backend, claim.conversation_id, backend_pid})
        ConversationSearch.replace_task(claim, snapshot, [])
      end)
    end)
  end

  defp await_backend_lock!(backend_pid, attempts \\ 100)

  defp await_backend_lock!(_backend_pid, 0),
    do: flunk("query never reached its row-lock barrier")

  defp await_backend_lock!(backend_pid, attempts) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]).rows do
      [["Lock"]] ->
        :ok

      _other ->
        Process.sleep(10)
        await_backend_lock!(backend_pid, attempts - 1)
    end
  end

  defp await_backend_lock_or_result!(task, backend_pid, attempts \\ 100)

  defp await_backend_lock_or_result!(_task, _backend_pid, 0),
    do: flunk("seal neither completed nor reached its cursor-lock barrier")

  defp await_backend_lock_or_result!(task, backend_pid, attempts) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        {:result, result}

      nil ->
        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [
               backend_pid
             ]).rows do
          [["Lock"]] ->
            :locked

          _other ->
            Process.sleep(10)
            await_backend_lock_or_result!(task, backend_pid, attempts - 1)
        end
    end
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

  defp project_unsealed(group_id, conversation_id, title, messages) do
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

  defp finish_gc(generation, remaining) when remaining > 0 do
    case ConversationSearch.gc_retired_generation(generation, batch_size: 1) do
      {:ok, %{done: true}} = done -> done
      {:ok, %{done: false}} -> finish_gc(generation, remaining - 1)
      other -> flunk("retired generation GC failed: #{inspect(other)}")
    end
  end

  defp finish_gc(_generation, 0), do: flunk("retired generation GC did not finish")

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

  defp projection_rows(group_id, conversation_id) do
    Repo.query!(
      """
      SELECT document_type, document_id, source_id, source_seq, source_created_at,
             content, folded_content, short_grams, weight_bytes
      FROM conversation_search_documents
      WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3
      ORDER BY document_type, source_seq NULLS FIRST, document_id
      """,
      [@generation, group_id, conversation_id]
    ).rows
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

  defp cte_actual_rows(plan, subplan_name) do
    plan
    |> plan_nodes()
    |> Enum.find(fn node -> node["Subplan Name"] == subplan_name end)
    |> case do
      %{"Actual Rows" => rows} -> rows
      _other -> flunk("missing #{subplan_name} in #{inspect(plan, limit: 20)}")
    end
  end

  defp plan_nodes(value) when is_list(value), do: Enum.flat_map(value, &plan_nodes/1)

  defp plan_nodes(value) when is_map(value),
    do: [value | Enum.flat_map(Map.values(value), &plan_nodes/1)]

  defp plan_nodes(_value), do: []
end
