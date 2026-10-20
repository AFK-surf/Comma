defmodule SalixIM.ConversationSearchDiscoveryTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationSearchDiscovery, ConversationSearchSource}
  alias SalixStore.{ConversationSearch, Ids, Keys, Repo, S3}

  @generation "test-search-generation"

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_jobs, " <>
        "conversation_search_states, conversation_search_discovery_cursors, " <>
        "conversation_search_backfill_runs CASCADE"
    )

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, writer_barrier_authority, writer_barrier_at,
       required_discovery_cycle, inserted_at, updated_at)
    VALUES ('#{@generation}', 'discovery-test', now(), 1, now(), now())
    """)

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at, inserted_at, updated_at)
    VALUES ('main', '#{@generation}', 0, now(), now(), now())
    """)

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "scanner repairs source-version-only drift after a lost relay" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    conversation_id = Ids.new_conversation_id()
    title = "Version-only drift"

    put_json(
      Keys.ctl_group_conversation(group_id, conversation_id),
      meta(group_id, conversation_id, title)
      |> Map.put("updated_at", 200)
    )

    Repo.query!(
      """
      INSERT INTO conversation_search_states
        (writer_generation, agent_group_id, conversation_id, conversation_kind,
         title, source_version, message_head_seq, message_tail_seq, updated_at)
      VALUES ($1, $2, $3, 'agent_task', $4, 100, 0, 0, now())
      """,
      [@generation, group_id, conversation_id, title]
    )

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors " <>
        "SET current_group_id = $1 WHERE id = 'main'",
      [group_id]
    )

    assert {:ok, claim} =
             ConversationSearch.claim_discovery_cursor("version-repair-scanner", 30_000)

    assert :ok = ConversationSearchDiscovery.discover_claim_for_test(claim)

    assert %{rows: [["rebuild"]]} =
             Repo.query!(
               "SELECT operation FROM conversation_search_jobs " <>
                 "WHERE writer_generation = $1 AND agent_group_id = $2 " <>
                 "AND conversation_id = $3",
               [@generation, group_id, conversation_id]
             )
  end

  defp meta(group_id, conversation_id, title) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "title" => title,
      "message_head_seq" => 0,
      "message_tail_seq" => 0,
      "created_at" => 1,
      "updated_at" => 1
    }
  end

  defp put_json(key, value) do
    assert {:ok, _result} = S3.put(key, Jason.encode!(value))
  end
end
