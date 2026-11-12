defmodule SalixIM.ConversationSearchDiscoveryTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_search_jobs]

  alias SalixIM.{ConversationPGStore, ConversationSearchDiscovery, ConversationSearchProjection}
  alias SalixStore.{ConversationSearch, Ids, Repo, S3}

  @generation "test-search-generation"

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)

    previous_generation =
      SystemsRuntime.get_env(:salix_store, :conversation_search_writer_generation)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, @generation)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!(
        "TRUNCATE salix_conversations, conversation_search_gc_runs, conversation_search_states, conversation_search_backfill_runs CASCADE"
      )
    end)

    Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name = 'conversation_search_projection_v1'"
    )

    group = Ids.new_group_id(Ids.new_tenant_id())
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Search backfill"})

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      restore(:s3_backend, previous_backend)
      restore(:conversation_search_writer_generation, previous_generation)
    end)

    %{group: group}
  end

  test "the bounded scan captures an upper key without losing incremental jobs", %{group: group} do
    historical(group, 1, "agent_task")
    historical(group, 2, "user_chat")
    assert :ok = ConversationSearch.begin_backfill(@generation)
    create(group, 3, "agent_task")
    assert {:ok, 1} = ConversationSearch.pending_job_count()
    assert :ok = ConversationSearch.record_writer_barrier(@generation, "release-test")
    assert {:ok, 1} = ConversationSearch.pending_job_count()

    create(group, 4, "agent_task")
    assert {:ok, %{scanned: 1, complete: false}} = ConversationSearch.scan_page(@generation, 1)

    assert {:ok, %{scan_conversation_id: first, scan_completed_at: nil}} =
             ConversationSearch.backfill_state(@generation)

    assert first == id(1)
    assert {:ok, %{scanned: 1, complete: false}} = ConversationSearch.scan_page(@generation, 1)
    assert {:ok, %{scanned: 1, complete: true}} = ConversationSearch.scan_page(@generation, 1)
    assert {:ok, :draining} = ConversationSearch.scan_page(@generation, 1)
    assert {:ok, 4} = ConversationSearch.pending_job_count()
    assert {:error, :not_ready} = ConversationSearch.seal_backfill(@generation)

    drain_jobs(4)
    server = start_supervised!({ConversationSearchDiscovery, interval_ms: 3_600_000})
    ConversationSearchDiscovery.drain_once(server)
    assert ConversationSearch.ready?()

    assert {:ok, %{scan_conversation_id: last, scan_completed_at: completed}} =
             ConversationSearch.backfill_state(@generation)

    assert last == id(3)
    assert completed != nil
    assert {:ok, [%{"conversation_id" => indexed}]} = ConversationSearch.search(group, "Task 4")
    assert indexed == id(4)

    create(group, 5, "agent_task")
    assert :idle = ConversationSearchDiscovery.drain_once(server)
    assert {:ok, 1} = ConversationSearch.pending_job_count()
    assert ConversationSearch.ready?()

    assert {:ok, %{scan_conversation_id: ^last, scan_completed_at: ^completed}} =
             ConversationSearch.backfill_state(@generation)
  end

  test "a failed page commits neither jobs nor its cursor", %{group: group} do
    historical(group, 11, "agent_task")
    historical(group, 12, "agent_task")
    assert :ok = ConversationSearch.begin_backfill(@generation)
    assert :ok = ConversationSearch.record_writer_barrier(@generation, "release-test")

    Repo.query!(
      "ALTER TABLE conversation_search_jobs ADD CONSTRAINT reject_scan_page CHECK (conversation_id <> '#{id(12)}')"
    )

    try do
      assert {:error, :unavailable} = ConversationSearch.scan_page(@generation, 2)
      assert {:ok, 0} = ConversationSearch.pending_job_count()

      assert {:ok, %{scan_conversation_id: nil, scan_completed_at: nil}} =
               ConversationSearch.backfill_state(@generation)
    after
      Repo.query!("ALTER TABLE conversation_search_jobs DROP CONSTRAINT reject_scan_page")
    end

    assert {:ok, %{scanned: 2, complete: true}} = ConversationSearch.scan_page(@generation, 2)
    assert {:ok, 2} = ConversationSearch.pending_job_count()
  end

  test "a canonical non-Task settles without creating a search projection", %{group: group} do
    assert :ok = ConversationSearch.begin_backfill(@generation)
    create(group, 21, "future_kind")
    assert :ok = ConversationSearch.record_writer_barrier(@generation, "release-test")
    assert {:ok, %{complete: true}} = ConversationSearch.scan_page(@generation)
    drain_jobs(1)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_states WHERE agent_group_id=$1",
               [group]
             )
  end

  defp drain_jobs(count) do
    for _ <- 1..count do
      assert {:ok, claim} = ConversationSearch.claim_one("backfill-test", 30_000)
      assert :ok = ConversationSearchProjection.process_claim(claim)
      assert :ok = ConversationSearch.complete(claim)
    end

    assert {:ok, 0} = ConversationSearch.pending_job_count()
  end

  defp historical(group, n, kind) do
    SystemsRuntime.delete_env(:salix_store, :conversation_search_writer_generation)

    try do
      create(group, n, kind)
    after
      SystemsRuntime.put_env(:salix_store, :conversation_search_writer_generation, @generation)
    end
  end

  defp create(group, n, kind) do
    assert {:ok, :inserted, record, _} =
             ConversationPGStore.create(ConversationPGStore.new(group, id(n)), %{
               "kind" => kind,
               "title" => "Task #{n}",
               "status" => "completed",
               "created_at" => 1,
               "updated_at" => 1,
               "participants" => []
             })

    record
  end

  defp id(n), do: "cnv1_" <> String.pad_leading(to_string(n), 19, "0")
  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_store, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_store, key, value)
end
