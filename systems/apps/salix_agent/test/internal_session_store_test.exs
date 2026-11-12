defmodule SalixAgent.InternalSessionStoreTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionActor, InternalSessionStore, OwnershipCell}
  alias SalixAgent.InternalSessionStore.{PG, PGCodec}
  alias SalixStore.Repo

  @session "ses1_0000000000000000001"
  @other "ses1_0000000000000000002"

  setup do
    agent = SalixAgent.TestSupport.new_agent_id()

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      "INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,root_revision) VALUES ($1,'tenant','group','worker',1,$2,'owner',1,1)",
      [agent, PGCodec.encode(%{})]
    )

    :ok = OwnershipCell.install(agent, 1)
    on_exit(fn -> OwnershipCell.clear(agent) end)
    {:ok, agent: agent}
  end

  defp own(agent, session \\ @session),
    do:
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, session), %{
        runtime_epoch: 1
      })

  defp entry(id, body \\ "accepted work"), do: %{source_message_id: id, payload: %{content: body}}

  test "runtime writes require the target Session actor", %{agent: agent} do
    assert {:error, :not_session_owner} = InternalSessionStore.create(agent, @session)
    assert {:error, :not_session_owner} = InternalSessionStore.commit(agent, @session, [])
    assert {:error, :not_session_owner} = InternalSessionStore.ensure(agent, @session, %{})

    assert {:error, :not_session_owner} =
             InternalSessionStore.seed(agent, InternalSession.new(agent, @session))

    assert {:error, :not_found} = InternalSessionStore.read(agent, @session)
  end

  test "first durable input creates birth and state together and the returned SQL revision is resident",
       %{agent: agent} do
    own(agent)
    assert {:ok, fresh} = InternalSessionStore.read_or_new_revision(agent, @session)
    assert fresh.revision == nil
    assert {:ok, :new} = InternalSessionStore.birth(agent, @session)

    assert {{:ok, :committed}, committed, nil} =
             InternalSession.Command.run(agent, @session, fresh, :input, {entry("source"), true})

    assert committed.revision == 1
    assert committed.pending == nil
    assert {:ok, :internal} = InternalSessionStore.birth(agent, @session)
    assert {:ok, loaded} = InternalSessionStore.read_revision(agent, @session)
    assert loaded.revision == committed.revision
    assert [%{"dedupe_key" => "source"}] = InternalSession.get(loaded.state, :input_queue)
  end

  test "a stale materialization cannot discard accepted work or acknowledge its candidate", %{
    agent: agent
  } do
    own(agent)
    assert {:ok, fresh} = InternalSessionStore.read_or_new_revision(agent, @session)

    assert {{:ok, :committed}, accepted, nil} =
             InternalSession.Command.run(
               agent,
               @session,
               fresh,
               :input,
               {entry("first", "保留 🌱"), true}
             )

    [queued] = InternalSession.get(accepted.state, :input_queue)
    fact = {queued["queue_id"], queued["kind"], queued["dedupe_key"], queued["payload"]}
    {events, true, hwm} = InternalSession.materialize_pending_input_events(accepted.state)
    assert {:ok, staged} = InternalSessionStore.write_revision(accepted, events, hwm: hwm)
    assert InternalSession.get(staged.state, :input_queue) == []
    assert {:ok, durable} = InternalSessionStore.read(agent, @session)
    assert InternalSession.get(durable, :input_queue) == [queued]

    assert {{:ok, :committed}, newer, nil} =
             InternalSession.Command.run(
               agent,
               @session,
               accepted,
               :input,
               {entry("later"), false}
             )

    assert {:error, {:stale_revision, revision}} =
             InternalSessionStore.durable_fence(agent, @session, staged)

    assert revision == newer.revision
    {events, true, hwm} = InternalSession.materialize_pending_input_events(newer.state)

    assert {:ok, final} =
             InternalSessionStore.commit_revision(agent, @session, newer, events, hwm: hwm)

    assert [%{accepted_input: ^fact}, %{content: "accepted work"}] =
             InternalSession.get(final.state, :messages)

    assert {:ok, reloaded} = InternalSessionStore.read(agent, @session)
    assert InternalSession.get(reloaded, :input_queue) == []
    assert length(InternalSession.get(reloaded, :messages)) == 2
  end

  test "multiple resident writes retain pending aliases without a durable journal", %{
    agent: agent
  } do
    own(agent)
    assert {:ok, _} = InternalSessionStore.create(agent, @session)
    assert {:ok, initial} = InternalSessionStore.read_revision(agent, @session)
    log = %{source_message_id: "pending-alias", payload: %{role: "event", content: "once"}}

    assert {{:awaiting_fence, _}, first, nil} =
             InternalSession.Command.prepare(agent, @session, initial, :log, log)

    assert {{:awaiting_fence, _}, second, nil} =
             InternalSession.Command.prepare(agent, @session, first, :log, log)

    assert length(InternalSession.get(second.state, :messages)) == 1
    assert {:ok, before} = InternalSessionStore.read(agent, @session)
    assert InternalSession.get(before, :messages) == []
    assert {:ok, committed} = InternalSessionStore.durable_fence(agent, @session, second)
    assert committed.revision == initial.revision + 1

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_session_input_dedupe WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             )

    assert {:ok, loaded} = InternalSessionStore.read(agent, @session)
    assert length(InternalSession.get(loaded, :messages)) == 1
  end

  test "a dynamic builder runs once and a conflicting revision rejects its frozen work", %{
    agent: agent
  } do
    own(agent)
    assert {:ok, _} = InternalSessionStore.create(agent, @session)
    assert {:ok, initial} = InternalSessionStore.read_revision(agent, @session)
    key = make_ref()

    builder = fn _state ->
      Process.put(key, (Process.get(key) || 0) + 1)

      assert {:ok, _} =
               PG.commit_revision(initial, 1, [%{"type" => "assistant", "content" => "winner"}])

      {:ok, [%{"type" => "assistant", "content" => "loser"}]}
    end

    assert {:error, {:stale_revision, _}} =
             InternalSessionStore.commit_revision_dynamic(agent, @session, initial, builder)

    assert Process.get(key) == 1
    assert {:ok, current} = InternalSessionStore.read(agent, @session)
    assert [%{content: "winner"}] = InternalSession.get(current, :messages)
  end

  test "Session-local identities and monotone sequences are independent", %{agent: agent} do
    for session <- [@session, @other] do
      own(agent, session)
      assert {:ok, fresh} = InternalSessionStore.read_or_new_revision(agent, session)

      assert {{:ok, :committed}, accepted, nil} =
               InternalSession.Command.run(
                 agent,
                 session,
                 fresh,
                 :input,
                 {entry("same-source"), true}
               )

      assert [%{"queue_id" => 1}] = InternalSession.get(accepted.state, :input_queue)
      {events, _, hwm} = InternalSession.materialize_pending_input_events(accepted.state)

      assert {:ok, committed} =
               InternalSessionStore.commit_revision(agent, session, accepted, events, hwm: hwm)

      assert [%{id: 1, seq: 1}] = InternalSession.get(committed.state, :messages)
    end

    assert {:ok, sessions} = InternalSessionStore.list(agent)
    assert Enum.sort(Enum.map(sessions, &InternalSession.session_id/1)) == [@session, @other]
  end

  test "hidden reads a Session's visibility from its row", %{agent: agent} do
    assert {:error, :not_found} = InternalSessionStore.hidden(agent, @session)

    own(agent)
    assert {:ok, _} = InternalSessionStore.create(agent, @session, %{hidden: true})
    assert {:ok, true} = InternalSessionStore.hidden(agent, @session)

    own(agent, @other)
    assert {:ok, _} = InternalSessionStore.create(agent, @other)
    assert {:ok, false} = InternalSessionStore.hidden(agent, @other)

    Repo.query!(
      "UPDATE salix_sessions SET deleted_at=clock_timestamp() WHERE agent_id=$1 AND session_id=$2",
      [agent, @other]
    )

    assert {:error, :not_found} = InternalSessionStore.hidden(agent, @other)
  end

  test "retired and deleted birth identities cannot be recreated", %{agent: agent} do
    own(agent)

    Repo.query!(
      "INSERT INTO salix_sessions (agent_id,session_id,birth_kind,revision) VALUES ($1,$2,'retired',0)",
      [agent, @session]
    )

    assert {:error, :session_read_only} = InternalSessionStore.create(agent, @session)

    assert {:error, :session_read_only} =
             InternalSessionStore.read_or_new_revision(agent, @session)

    own(agent, @other)
    assert {:ok, _} = InternalSessionStore.create(agent, @other)

    Repo.query!(
      "UPDATE salix_sessions SET deleted_at=clock_timestamp() WHERE agent_id=$1 AND session_id=$2",
      [agent, @other]
    )

    assert {:error, :not_found} = InternalSessionStore.create(agent, @other)
    assert {:error, :session_read_only} = InternalSessionStore.read_or_new_revision(agent, @other)
  end
end
