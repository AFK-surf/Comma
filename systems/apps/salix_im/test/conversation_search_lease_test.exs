defmodule SalixIM.ConversationSearchLeaseTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationSearchDiscovery, ConversationSearchWorker}
  alias SalixStore.{ConversationSearch, Repo}

  @generation "test-search-generation"
  @marker "conversation_search_projection_v1"

  setup do
    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_jobs, " <>
        "conversation_search_states, conversation_search_discovery_cursors, " <>
        "conversation_search_backfill_runs CASCADE"
    )

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, writer_barrier_authority, writer_barrier_at,
       required_discovery_cycle, inserted_at, updated_at)
    VALUES ('#{@generation}', 'lease-test', now(), 1, now(), now())
    """)

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at, inserted_at, updated_at)
    VALUES ('main', '#{@generation}', 0, now(), now(), now())
    """)

    :ok
  end

  test "job heartbeat cannot outlive a crashing claim owner" do
    assert :ok = ConversationSearch.enqueue_rebuild("group-lease", "task-lease")
    assert {:ok, claim} = ConversationSearch.claim_one("worker-a", 60)

    {owner, owner_ref} =
      spawn_monitor(fn ->
        ConversationSearchWorker.with_heartbeat_for_test(claim, 60, fn ->
          exit(:injected_work_exit)
        end)
      end)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :injected_work_exit}, 1_000
    Process.sleep(120)

    assert {:ok, fresh_claim} = ConversationSearch.claim_one("worker-b", 1_000)
    assert fresh_claim.id == claim.id
    assert fresh_claim.claim_token != claim.claim_token
    assert :ok = ConversationSearch.complete(fresh_claim)
  end

  test "discovery heartbeat cannot outlive a crashing cursor owner" do
    assert {:ok, claim} = ConversationSearch.claim_discovery_cursor("scanner-a", 60)

    {owner, owner_ref} =
      spawn_monitor(fn ->
        ConversationSearchDiscovery.with_heartbeat_for_test(claim, 60, fn _claim ->
          exit(:injected_s3_exit)
        end)
      end)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :injected_s3_exit}, 1_000
    Process.sleep(120)

    assert {:ok, fresh_claim} = ConversationSearch.claim_discovery_cursor("scanner-b", 1_000)
    assert fresh_claim.claim_token != claim.claim_token
    assert :ok = ConversationSearch.release_discovery_cursor(fresh_claim)
  end
end
