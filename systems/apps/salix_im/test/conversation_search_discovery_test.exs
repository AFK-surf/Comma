defmodule SalixIM.ConversationSearchDiscoveryTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationSearchDiscovery, ConversationSearchSource}
  alias SalixStore.{ConversationSearch, Ids, Keys, Repo, S3}

  @generation "test-search-generation"

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

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
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "delimiter pagination advances past returned prefixes without counting child objects" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    conversation_ids = Enum.map(1..3, fn _index -> Ids.new_conversation_id() end)
    sources = Enum.sort_by(conversation_ids, &Keys.ctl_group_conversation_dir(group_id, &1))

    put_json(Keys.ctl_group(group_id), %{"agent_group_id" => group_id})

    Enum.each(conversation_ids, fn conversation_id ->
      put_json(
        Keys.ctl_group_conversation(group_id, conversation_id),
        meta(group_id, conversation_id, "Task #{conversation_id}")
      )
    end)

    first_id = hd(sources)
    child_prefix = Keys.ctl_group_conversation_dir(group_id, first_id)

    Enum.each(1..250, fn index ->
      put_json(child_prefix <> "messages/segments/#{index}.json", %{"seq" => index})
      put_json(child_prefix <> "participants/#{index}/state.json", %{"id" => index})
    end)

    assert {:ok, first_page} = ConversationSearchSource.conversation_page(group_id, nil, 2)
    assert Enum.map(first_page.sources, & &1.conversation_id) == Enum.take(sources, 2)

    last_prefix = Keys.ctl_group_conversation_dir(group_id, Enum.at(sources, 1))
    expected_start_after = String.trim_trailing(last_prefix, "/") <> "0"

    assert first_page.next_start_after == expected_start_after

    # This Fake deliberately models the conservative S3-compatible ordering:
    # filtering raw keys before delimiter rollup can re-emit an equal prefix.
    assert {:ok, %{common_prefixes: [^last_prefix | _rest]}} =
             S3.list(Keys.ctl_group_conversations_prefix(group_id),
               delimiter: "/",
               max_keys: 2,
               start_after: last_prefix
             )

    assert {:ok, second_page} =
             ConversationSearchSource.conversation_page(group_id, first_page.next_start_after, 2)

    assert Enum.map(second_page.sources, & &1.conversation_id) == Enum.drop(sources, 2)

    list_reads =
      S3.Fake.read_log()
      |> Enum.filter(fn
        {:list, prefix, _opts} -> prefix == Keys.ctl_group_conversations_prefix(group_id)
        _other -> false
      end)

    assert {:list, _first_prefix, first_opts} = hd(list_reads)
    assert {:list, _second_prefix, second_opts} = List.last(list_reads)

    assert first_opts[:delimiter] == "/"
    assert first_opts[:max_keys] == 2
    assert second_opts[:start_after] == expected_start_after
  end

  test "scanner completes a Group when equal CommonPrefixes can be re-emitted" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    conversation_ids = Enum.map(1..2, fn _index -> Ids.new_conversation_id() end)

    Enum.each(conversation_ids, fn conversation_id ->
      put_json(
        Keys.ctl_group_conversation(group_id, conversation_id),
        meta(group_id, conversation_id, "Task #{conversation_id}")
      )
    end)

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors " <>
        "SET current_group_id = $1 WHERE id = 'main'",
      [group_id]
    )

    Enum.each(1..3, fn turn ->
      assert {:ok, claim} =
               ConversationSearch.claim_discovery_cursor("scanner-turn-#{turn}", 30_000)

      assert :ok =
               ConversationSearchDiscovery.discover_claim_for_test(claim, page_size: 1)
    end)

    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!(
               "SELECT current_group_id, conversation_start_after, claim_token " <>
                 "FROM conversation_search_discovery_cursors WHERE id = 'main'"
             )

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_jobs " <>
                 "WHERE writer_generation = $1 AND agent_group_id = $2",
               [@generation, group_id]
             )
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

  test "scanner advances across retained legacy flat keys without reading them as authority" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())

    [first_id, legacy_id, last_id] =
      Enum.sort(Enum.map(1..3, fn _ -> Ids.new_conversation_id() end))

    legacy_key = Keys.ctl_group_conversations_prefix(group_id) <> legacy_id <> ".json"

    put_json(Keys.ctl_group(group_id), %{"agent_group_id" => group_id})

    for conversation_id <- [first_id, last_id] do
      put_json(
        Keys.ctl_group_conversation(group_id, conversation_id),
        meta(group_id, conversation_id, "Canonical #{conversation_id}")
      )
    end

    put_json(legacy_key, %{
      "agent_group_id" => group_id,
      "conversation_id" => legacy_id,
      "kind" => "agent_task",
      "title" => "deprecated body must not be read"
    })

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors " <>
        "SET current_group_id = $1 WHERE id = 'main'",
      [group_id]
    )

    assert {:ok, first_claim} =
             ConversationSearch.claim_discovery_cursor("scanner-before-restart", 30_000)

    assert :ok =
             ConversationSearchDiscovery.discover_claim_for_test(first_claim, page_size: 2)

    assert %{rows: [[^legacy_key, nil]]} =
             Repo.query!(
               "SELECT conversation_start_after, claim_token " <>
                 "FROM conversation_search_discovery_cursors WHERE id = 'main'"
             )

    # A fresh holder proves the durable cursor resumes after process/Pod restart.
    assert {:ok, second_claim} =
             ConversationSearch.claim_discovery_cursor("scanner-after-restart", 30_000)

    assert :ok =
             ConversationSearchDiscovery.discover_claim_for_test(second_claim, page_size: 2)

    last_prefix = Keys.ctl_group_conversation_dir(group_id, last_id)
    expected_cursor = String.trim_trailing(last_prefix, "/") <> "0"

    assert %{rows: [[^expected_cursor, nil]]} =
             Repo.query!(
               "SELECT conversation_start_after, claim_token " <>
                 "FROM conversation_search_discovery_cursors WHERE id = 'main'"
             )

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_jobs " <>
                 "WHERE writer_generation = $1 AND agent_group_id = $2",
               [@generation, group_id]
             )

    reads = S3.Fake.read_log()
    refute {:get, legacy_key} in reads
    assert {:get, Keys.ctl_group_conversation(group_id, first_id)} in reads
    assert {:get, Keys.ctl_group_conversation(group_id, last_id)} in reads

    assert Enum.any?(reads, fn
             {:list, _prefix, opts} -> opts[:start_after] == legacy_key
             _other -> false
           end)
  end

  test "unknown direct objects fail closed without advancing discovery" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    unexpected_key = Keys.ctl_group_conversations_prefix(group_id) <> "unexpected.txt"
    put_json(unexpected_key, %{"unexpected" => true})

    assert {:error, {:unexpected_direct_object, ^unexpected_key}} =
             ConversationSearchSource.conversation_page(group_id, nil, 10)
  end

  test "scanner skips missing metadata, preserves live projection, and advances its cursor" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    missing_id = Ids.new_conversation_id()
    legacy_id = Ids.new_conversation_id()

    put_json(Keys.ctl_group(group_id), %{"agent_group_id" => group_id})

    # The child makes the Conversation common prefix discoverable while the
    # exact canonical metadata object is temporarily absent.
    put_json(
      Keys.ctl_group_conversation_dir(group_id, missing_id) <> "messages/segments/1.json",
      %{"rows" => []}
    )

    legacy_source = %{
      key: Keys.ctl_group_conversation_dir(group_id, legacy_id),
      group_id: group_id,
      conversation_id: legacy_id
    }

    put_json(
      Keys.ctl_group_conversation(group_id, legacy_id),
      meta(group_id, legacy_id, "Legacy message count")
      |> Map.put("message_count", 5)
      |> Map.delete("message_head_seq")
      |> Map.delete("message_tail_seq")
    )

    assert {:ok,
            {:task, %{message_head_seq: 1, message_tail_seq: 5, conversation_id: ^legacy_id}}} =
             ConversationSearchSource.classify_conversation(legacy_source)

    Repo.query!(
      """
      INSERT INTO conversation_search_states
        (writer_generation, agent_group_id, conversation_id, conversation_kind,
         title, source_version, message_head_seq, message_tail_seq, updated_at)
      VALUES ($1, $2, $3, 'agent_task', 'Must survive missing meta', 1, 0, 0, now())
      """,
      [@generation, group_id, missing_id]
    )

    Repo.query!(
      "UPDATE conversation_search_discovery_cursors " <>
        "SET current_group_id = $1 WHERE id = 'main'",
      [group_id]
    )

    assert {:ok, claim} = ConversationSearch.claim_discovery_cursor("scanner-test", 30_000)
    assert :ok = ConversationSearchDiscovery.discover_claim_for_test(claim)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_states " <>
                 "WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3",
               [@generation, group_id, missing_id]
             )

    assert %{rows: [["rebuild"]]} =
             Repo.query!(
               "SELECT operation FROM conversation_search_jobs " <>
                 "WHERE writer_generation = $1 AND agent_group_id = $2 AND conversation_id = $3",
               [@generation, group_id, legacy_id]
             )

    expected_cursor =
      [missing_id, legacy_id]
      |> Enum.map(&Keys.ctl_group_conversation_dir(group_id, &1))
      |> Enum.max()
      |> then(&(String.trim_trailing(&1, "/") <> "0"))

    assert %{rows: [[^expected_cursor, nil]]} =
             Repo.query!(
               "SELECT conversation_start_after, claim_token " <>
                 "FROM conversation_search_discovery_cursors WHERE id = 'main'"
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
