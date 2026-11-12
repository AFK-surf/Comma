defmodule SalixStore.AgentPGStoreTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore"]

  alias SalixStore.{AgentPGStore, Codec, Repo}
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  setup do
    id = "opaque-agent-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)

    record = %{
      "agent_id" => id,
      "tenant_id" => "opaque-tenant",
      "group_id" => id <> "-group",
      "role" => "worker",
      "name" => "original",
      "runtime_config" => %{"kind" => "internal"},
      "management_creation_audit" => %{"source" => "test"}
    }

    {:ok, id: id, record: record}
  end

  test "batched imports preserve complete roots and reject any different existing row", %{
    id: id,
    record: record
  } do
    head = %SalixStore.Head{epoch: 7, owner_node: "retired", lease_until: 1234}
    other = id <> "-other"

    other_record =
      record
      |> Map.put("agent_id", other)
      |> Map.put("archived_at", 1_700_000_000)
      |> Map.put("router_session_id", "router")

    one = {id, head, @sm, %{count: 4}, record}
    two = {other, head, @sm, %{count: 8}, other_record}
    assert {:ok, :ok} = Repo.transaction(fn -> AgentPGStore.import_roots!([one, two]) end)
    assert {:ok, :ok} = Repo.transaction(fn -> AgentPGStore.import_roots!([one, one, two]) end)
    assert {:ok, %{record: ^record, revision: 1}} = AgentPGStore.read_config(id)
    assert {:ok, %{record: ^other_record, revision: 1}} = AgentPGStore.read_config(other)
    assert {:ok, root} = AgentPGStore.read_root(other)
    assert root.state == %{count: 8}
    assert root.head == %{head | owner_node: nil, lease_until: nil}

    assert Repo.query!(
             "SELECT archived_at,router_session_id FROM salix_agents WHERE agent_id=$1",
             [id]
           ).rows == [[nil, nil]]

    assert [[archived, "router"]] =
             Repo.query!(
               "SELECT archived_at,router_session_id FROM salix_agents WHERE agent_id=$1",
               [other]
             ).rows

    assert DateTime.to_unix(archived) == 1_700_000_000

    before = payloads(other)
    fresh = id <> "-fresh"
    fresh_record = Map.put(record, "agent_id", fresh)
    conflicting = Map.put(other_record, "name", "conflict")

    assert {:error, {:import_conflict, "salix_agents", %{"agent_id" => ^other}}} =
             Repo.transaction(fn ->
               AgentPGStore.import_roots!([
                 {fresh, head, @sm, %{}, fresh_record},
                 {other, head, @sm, %{count: 8}, conflicting}
               ])
             end)

    assert {:error, :not_found} = AgentPGStore.read_config(fresh)
    assert payloads(other) == before
  end

  test "complete creation and independent configuration/root updates preserve each other", %{
    id: id,
    record: record
  } do
    assert {:ok, %Owned{epoch: 1, root_revision: 1} = first} =
             AgentPGStore.create(id, "owner-a", @sm, record)

    assert {:error, :exists} = AgentPGStore.create(id, "owner-b", @sm, record)
    assert {:ok, %{revision: 1, record: ^record}} = AgentPGStore.read_config(id)

    changed = Map.put(record, "name", "configured")
    assert {:ok, %{revision: 2}} = AgentPGStore.put_config(id, changed, 1)
    assert {:error, :precondition_failed} = AgentPGStore.put_config(id, record, 1)
    assert {:ok, committed} = AgentPGStore.commit(first, [%{op: "inc", by: 5}], hwm: 41)
    assert committed.head.message_id_hwm == 41
    assert {:ok, %{revision: 2, record: ^changed}} = AgentPGStore.read_config(id)

    before = payloads(id)
    assert {:ok, renewed} = AgentPGStore.renew(committed)
    assert payloads(id) == before
    assert :ok = AgentPGStore.release(renewed)
    assert payloads(id) == before
    assert {:ok, %{owner_node: nil, lease_until: nil}} = AgentPGStore.peek(id)

    assert {:ok, claimed} = AgentPGStore.claim(id, "owner-b", @sm)
    assert claimed.epoch == 2
    assert claimed.state == %{counter: 5, ops: 1}
    assert claimed.head.message_id_hwm == 41
    assert claimed.head.journal_tail == %{epoch: 1, seq: 1}
    assert claimed.head.snapshot_seq == 1
    assert {:ok, %{record: ^changed}} = AgentPGStore.read_config(id)
  end

  test "claims retain legal takeover conditions and fence every old-owner mutation", %{
    id: id,
    record: record
  } do
    assert {:ok, first} = AgentPGStore.create(id, "owner-a", @sm, record, ttl_ms: 60_000)
    assert first.head.lease_until == SystemsClock.system_time(:millisecond) + 60_000
    assert {:error, {:held_by, "owner-a", _}} = AgentPGStore.claim(id, "owner-b", @sm)

    assert {:ok, second} = AgentPGStore.claim(id, "owner-a", @sm)
    assert second.epoch == 2
    assert second.prev_owner_node == "owner-a"
    assert {:error, :fenced} = AgentPGStore.commit(first, [%{op: "inc", by: 99}])
    assert {:error, :fenced} = AgentPGStore.renew(first)
    assert {:error, :fenced} = AgentPGStore.release(first)

    SystemsClock.advance(60_001)
    assert {:ok, third} = AgentPGStore.claim(id, "owner-b", @sm)
    assert third.epoch == 3
    assert {:ok, fourth} = AgentPGStore.claim(id, "owner-c", @sm, steal: true)
    assert fourth.epoch == 4
  end

  test "scope lists use bounded Agent-id keyset pages without hydrating roots", %{
    id: id,
    record: record
  } do
    for suffix <- ~w(a b c) do
      next_id = id <> suffix
      next_record = Map.merge(record, %{"agent_id" => next_id, "name" => suffix})
      assert {:ok, _} = AgentPGStore.create(next_id, "owner-a", @sm, next_record)
    end

    scope = %{tenant_id: record["tenant_id"], group_id: record["group_id"]}
    assert {:ok, %{items: [a, b], next: cursor}} = AgentPGStore.page_configs(scope, limit: 2)
    assert a["agent_id"] == id <> "a"
    assert b["agent_id"] == id <> "b"
    assert cursor == b["agent_id"]

    assert {:ok, %{items: [c], next: nil}} =
             AgentPGStore.page_configs(scope, limit: 2, cursor: cursor)

    assert c["agent_id"] == id <> "c"

    assert {:ok, %{items: [], next: nil}} =
             AgentPGStore.page_configs(%{tenant_id: "other", group_id: record["group_id"]})
  end

  test "Agent shared locks coexist and delay takeover until both Session transactions leave", %{
    id: id,
    record: record
  } do
    assert {:ok, old} = AgentPGStore.create(id, "owner-a", @sm, record)
    connections = for _ <- 1..2, do: connection()
    parent = SystemsRuntime.Proc.self()

    try do
      for conn <- connections do
        Postgrex.query!(conn, "BEGIN", [])

        Postgrex.query!(
          conn,
          "SELECT owner_epoch FROM salix_agents WHERE agent_id = $1 FOR SHARE",
          [id]
        )
      end

      takeover =
        SystemsRuntime.Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            SystemsRuntime.Proc.send(parent, {:takeover_backend, backend_pid})
            AgentPGStore.claim(id, "owner-b", @sm, steal: true)
          end)
        end)

      settle_receive({:takeover_backend, backend_pid})
      assert wait_for_lock(backend_pid, nil)
      Postgrex.query!(hd(connections), "COMMIT", [])

      %{rows: [[remaining_pid]]} =
        Postgrex.query!(List.last(connections), "SELECT pg_backend_pid()", [])

      assert wait_for_lock(backend_pid, remaining_pid)
      Postgrex.query!(List.last(connections), "COMMIT", [])
      assert {:ok, claimed} = settled_await(takeover)
      assert claimed.epoch == old.epoch + 1
      assert {:error, :fenced} = AgentPGStore.commit(old, [%{op: "inc", by: 99}])
    after
      for conn <- connections do
        Postgrex.query!(conn, "ROLLBACK", [])
        GenServer.stop(conn)
      end
    end
  end

  test "frozen commit settles a lost reply once and never grants authority after takeover", %{
    id: id,
    record: record
  } do
    assert {:ok, owned} = AgentPGStore.create(id, "owner-a", @sm, record)
    pending = AgentPGStore.prepare_commit(owned, [%{op: "inc", by: 7}])

    # The database applied the command; the caller did not receive its result.
    Repo.query!(pending.sql, pending.params)
    assert {:ok, settled} = AgentPGStore.settle(pending)
    assert settled.state == %{counter: 7, ops: 1}
    assert {:ok, again} = AgentPGStore.settle(pending)
    assert again.root_revision == settled.root_revision
    assert again.state == settled.state

    assert {:ok, _} = AgentPGStore.claim(id, "owner-b", @sm, steal: true)
    assert {:error, :fenced} = AgentPGStore.settle(pending)
    assert {:ok, %{counter: 7, ops: 1}} = AgentPGStore.read_state(id, @sm)
  end

  test "rolled-back frozen commit retries the same delta at the expected revision", %{
    id: id,
    record: record
  } do
    assert {:ok, owned} = AgentPGStore.create(id, "owner-a", @sm, record)
    pending = AgentPGStore.prepare_commit(owned, [%{op: "inc", by: 3}])

    assert {:error, :not_committed} =
             Repo.transaction(fn ->
               Repo.query!(pending.sql, pending.params)
               Repo.rollback(:not_committed)
             end)

    assert {:ok, settled} = AgentPGStore.settle(pending)
    assert settled.state == %{counter: 3, ops: 1}
    assert Codec.decode_snapshot(pending.payload).state == settled.state
  end

  test "a competing shorter renewal cannot confirm the frozen longer lease", %{
    id: id,
    record: record
  } do
    assert {:ok, owned} = AgentPGStore.create(id, "owner-a", @sm, record)
    assert {:ok, pending} = AgentPGStore.prepare_renew(owned)

    # Both attempts name the same revision and root body, but promise different deadlines.
    assert {:ok, short} = AgentPGStore.renew(%{owned | ttl_ms: 1_000})
    assert short.head.lease_until < DateTime.to_unix(pending.lease_until, :millisecond)
    assert {:error, :renew_unconfirmed} = AgentPGStore.settle(pending)

    assert {:ok, landed} = AgentPGStore.prepare_renew(%{short | ttl_ms: 60_000})
    Repo.query!(landed.sql, landed.params)
    assert {:ok, confirmed} = AgentPGStore.settle(landed)
    assert confirmed.head.lease_until >= DateTime.to_unix(landed.lease_until, :millisecond)
  end

  test "a lost configuration reply settles without overwriting a later replacement", %{
    id: id,
    record: record
  } do
    assert {:ok, _} = AgentPGStore.create(id, "owner-a", @sm, record)
    changed = Map.put(record, "name", "changed")
    pending = AgentPGStore.prepare_config(id, changed, 1)
    Repo.query!(pending.sql, pending.params)
    assert {:ok, %{record: ^changed, revision: 2}} = AgentPGStore.settle(pending)

    newer = Map.put(changed, "name", "newer")
    assert {:ok, _} = AgentPGStore.put_config(id, newer, 2)
    assert {:error, :precondition_failed} = AgentPGStore.settle(pending)
    assert {:ok, %{record: ^newer}} = AgentPGStore.read_config(id)
  end

  test "reserved creation stays unpublished until the original owner publishes it", %{
    id: id,
    record: record
  } do
    assert {:ok, owned} = AgentPGStore.begin_create(id, "creator", @sm, record)
    assert {:error, :not_found} = AgentPGStore.read_config(id)
    assert {:error, :not_found} = AgentPGStore.peek(id)
    assert {:ok, %{items: []}} = AgentPGStore.page_configs(%{group_id: record["group_id"]})
    assert {:error, :precondition_failed} = AgentPGStore.put_config(id, record, 0)
    assert {:error, :not_found} = AgentPGStore.claim(id, "creator", @sm, steal: true)
    SystemsClock.advance(60_001)
    assert {:error, :not_found} = AgentPGStore.claim(id, "other", @sm, steal: true)

    assert :ok = AgentPGStore.publish_created(owned)
    assert {:ok, %{record: ^record, revision: 1}} = AgentPGStore.read_config(id)
    assert {:ok, %{owner_node: nil, lease_until: nil}} = AgentPGStore.peek(id)
    assert {:error, :fenced} = AgentPGStore.discard_created(owned)
    assert {:error, :fenced} = AgentPGStore.publish_created(owned)
    assert {:ok, %{epoch: 2}} = AgentPGStore.claim(id, "other", @sm)
  end

  test "publication acknowledgement loss settles the same update and cannot roll back a published Agent",
       %{id: id, record: record} do
    assert {:ok, owned} = AgentPGStore.begin_create(id, "creator", @sm, record)
    pending = AgentPGStore.prepare_publish(owned)
    Repo.query!(pending.sql, pending.params)
    assert :ok = AgentPGStore.settle(pending)
    assert {:error, :fenced} = AgentPGStore.discard_created(owned)
    assert {:ok, %{record: ^record}} = AgentPGStore.read_config(id)
  end

  test "an old creation cannot publish, discard, seed or settle after same-node recreation", %{
    id: id,
    record: record
  } do
    assert {:ok, old} = AgentPGStore.begin_create(id, "creator", @sm, record)
    old_publication = AgentPGStore.prepare_publish(old)
    assert :ok = AgentPGStore.discard_created(old)
    assert {:ok, current} = AgentPGStore.begin_create(id, "creator", @sm, record)
    assert current.epoch == old.epoch
    assert current.root_revision == old.root_revision
    refute current.head.commit_uuid == old.head.commit_uuid

    assert {:error, :fenced} = AgentPGStore.publish_created(old)
    assert {:error, :fenced} = AgentPGStore.discard_created(old)
    assert {:error, :fenced} = AgentPGStore.settle(old_publication)
    assert {:error, :fenced} = insert_created_birth(old, "late")
    assert :ok = AgentPGStore.publish_created(current)
    assert {:ok, %{record: ^record}} = AgentPGStore.read_config(id)
  end

  test "cleanup revokes old creation before its first bounded page and keeps other scopes", %{
    id: id,
    record: record
  } do
    assert {:ok, created} = AgentPGStore.begin_create(id, "creator", @sm, record)
    assert {:ok, :ok} = insert_created_birth(created, "a")
    assert {:ok, :ok} = insert_created_birth(created, "b")
    other_id = id <> "-other"
    other = Map.put(record, "agent_id", other_id)
    assert {:ok, _} = AgentPGStore.create(other_id, "other", @sm, other)

    Repo.query!(
      "INSERT INTO salix_sessions (agent_id,session_id,birth_kind,revision) VALUES ($1,'kept','internal',0)",
      [other_id]
    )

    assert {:ok, cleanup} = AgentPGStore.begin_cleanup(created)
    assert cleanup.root_revision == created.root_revision + 1
    refute cleanup.head.commit_uuid == created.head.commit_uuid

    assert {:ok, %{done: false, deleted: 1}} =
             AgentPGStore.cleanup_page(cleanup, &delete_birth/2, 1)

    assert {:error, :fenced} = AgentPGStore.publish_created(created)
    assert {:error, :fenced} = insert_created_birth(created, "late")
    assert {:error, :fenced} = AgentPGStore.begin_cleanup(created)

    assert {:ok, %{done: true, deleted: 1}} =
             AgentPGStore.cleanup_page(cleanup, &delete_birth/2, 1)

    assert {:ok, %{rows: [[0]]}} =
             Repo.query("SELECT count(*) FROM salix_agents WHERE agent_id=$1", [id])

    assert {:ok, %{rows: [[1]]}} =
             Repo.query("SELECT count(*) FROM salix_sessions WHERE agent_id=$1", [other_id])

    assert {:ok, %{record: ^other}} = AgentPGStore.read_config(other_id)
  end

  test "unknown cleanup start confirms only its exact frozen replacement identity", %{
    id: id,
    record: record
  } do
    assert {:ok, created} = AgentPGStore.begin_create(id, "creator", @sm, record)
    pending = AgentPGStore.prepare_cleanup(created)
    Repo.query!(pending.sql, pending.params)
    assert {:ok, cleanup} = AgentPGStore.settle(pending)
    assert {:ok, same} = AgentPGStore.settle(pending)
    assert same.root_revision == cleanup.root_revision
    assert same.head.commit_uuid == cleanup.head.commit_uuid
    assert :ok = AgentPGStore.cleanup_created(cleanup, &delete_birth/2)
    assert :ok = AgentPGStore.settle(pending)

    assert {:ok, replacement} = AgentPGStore.begin_create(id, "creator", @sm, record)
    assert {:error, :fenced} = AgentPGStore.settle(pending)
    assert :ok = AgentPGStore.publish_created(replacement)
  end

  test "cleanup start retries only its original frozen update after a rollback", %{
    id: id,
    record: record
  } do
    assert {:ok, created} = AgentPGStore.begin_create(id, "creator", @sm, record)
    pending = AgentPGStore.prepare_cleanup(created)

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               Repo.query!(pending.sql, pending.params)
               Repo.rollback(:rolled_back)
             end)

    assert {:ok, cleanup} = AgentPGStore.settle(pending)
    assert Codec.decode_snapshot(pending.payload).head.commit_uuid == cleanup.head.commit_uuid
    assert :ok = AgentPGStore.cleanup_created(cleanup, &delete_birth/2)
  end

  defp insert_created_birth(owned, session_id) do
    Repo.transaction(fn ->
      :ok = AgentPGStore.lock_creation!(owned)

      Repo.query!(
        "INSERT INTO salix_sessions (agent_id,session_id,birth_kind,revision) VALUES ($1,$2,'internal',0)",
        [owned.agent_id, session_id]
      )

      :ok
    end)
  end

  defp delete_birth(agent_id, session_id) do
    Repo.query!("DELETE FROM salix_sessions WHERE agent_id=$1 AND session_id=$2", [
      agent_id,
      session_id
    ])

    :ok
  end

  defp payloads(id) do
    %{rows: [[config, root]]} =
      Repo.query!("SELECT config_payload, root_payload FROM salix_agents WHERE agent_id = $1", [
        id
      ])

    {config, root}
  end

  defp connection do
    opts = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp wait_for_lock(backend_pid, blocker_pid) do
    settle_until(fn ->
      case Repo.query!(
             "SELECT wait_event_type, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
             [backend_pid]
           ) do
        %{rows: [["Lock", blockers]]} when blockers != [] ->
          is_nil(blocker_pid) or blocker_pid in blockers

        _ ->
          false
      end
    end)
  end
end
