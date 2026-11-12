defmodule SalixAgent.SessionFixtureTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.InternalSessionStore.PG
  alias SalixAgent.TestSupport.SessionFixture
  alias SalixStore.{AgentPGStore, Ids, Repo}

  test "cleanup excludes late input and Session creation until their Agent is gone" do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    session = Ids.new_session_id()
    next_session = Ids.new_session_id()
    {:ok, head} = AgentPGStore.peek(agent)
    {:ok, initial} = PG.create(agent, session, head.epoch)

    assert {{:ok, :committed}, accepted} =
             PG.input_revision(initial, head.epoch, %{
               source_message_id: "before-cleanup",
               payload: %{content: "accepted"}
             })

    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata.query =~ "DELETE FROM salix_session_input_dedupe" and
               metadata.params == [agent, session] do
            send(parent, {:cleanup_deleted_dedupe, self()})
            receive do: (:continue_cleanup -> :ok)
          end
        end,
        nil
      )

    cleanup =
      SystemsRuntime.Task.async(fn ->
        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:cleanup_backend, backend})

          try do
            SessionFixture.cleanup(agent)
          rescue
            error in Postgrex.Error -> {:error, error.postgres.code}
          end
        end)
      end)

    settle_receive({:cleanup_backend, cleanup_backend})
    settle_receive({:cleanup_deleted_dedupe, cleanup_pid})

    try do
      writer =
        SystemsRuntime.Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:writer_backend, backend})

            input =
              PG.input_revision(accepted, head.epoch, %{
                source_message_id: "during-cleanup",
                payload: %{content: "too late"}
              })

            created = PG.create(agent, next_session, head.epoch)
            send(parent, {:writer_finished, {input, created}})
            {input, created}
          end)
        end)

      settle_receive({:writer_backend, writer_backend})

      # The old cleanup lets this writer finish between child deletion and
      # parent deletion. The owner transaction makes it wait on the Agent.
      writer_state =
        settle_until(fn ->
          receive do
            {:writer_finished, _result} -> :finished
          after
            0 ->
              if Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   cleanup_backend,
                   writer_backend
                 ]).rows == [[true]], do: :blocked
          end
        end)

      send(cleanup_pid, :continue_cleanup)
      assert :ok = settled_await(cleanup)
      assert writer_state == :blocked

      assert {{:error, :agent_not_found}, {:error, :agent_not_found}} =
               settled_await(writer)

      assert {:error, :not_found} = AgentPGStore.peek(agent)
      assert {:error, :not_found} = PG.read(agent, session)
      assert {:error, :not_found} = PG.read(agent, next_session)
    after
      :telemetry.detach(handler)
      send(cleanup_pid, :continue_cleanup)
    end
  end
end
