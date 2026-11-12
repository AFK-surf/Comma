defmodule SalixAgent.TestSupport.SessionFixture do
  @moduledoc "Cold Session fixtures written through the PostgreSQL owner."

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore.PG
  alias SalixStore.AgentPGStore

  def create(agent_id, session_id, attrs \\ %{}) do
    {:ok, head} = AgentPGStore.peek(agent_id)

    case PG.create(agent_id, session_id, head.epoch, attrs) do
      {:ok, version} -> {:ok, version.state}
      {:error, {:stale_revision, _}} -> {:error, :exists}
      error -> error
    end
  end

  def commit(agent_id, session_id, events, opts \\ []) do
    {:ok, head} = AgentPGStore.peek(agent_id)

    base =
      case PG.read(agent_id, session_id) do
        {:ok, version} ->
          version

        {:error, :not_found} ->
          {:ok, version} = PG.create(agent_id, session_id, head.epoch, opts[:create_attrs] || %{})
          version
      end

    with {:ok, committed} <- PG.commit_revision(base, head.epoch, events, opts),
         do: {:ok, committed.state}
  end

  def reject_writes(agent_id) do
    quoted = String.replace(agent_id, "'", "''")

    SalixStore.Repo.query!(
      "ALTER TABLE salix_sessions ADD CONSTRAINT fixture_session_write_reject CHECK (agent_id <> '#{quoted}') NOT VALID"
    )

    :ok
  end

  def allow_writes do
    SalixStore.Repo.query!(
      "ALTER TABLE salix_sessions DROP CONSTRAINT IF EXISTS fixture_session_write_reject"
    )

    :ok
  end

  def cleanup_on_exit(agent_id), do: SalixAgent.TestSupport.cleanup_agent_on_exit(agent_id)

  def cleanup(agent_id) do
    :ok = SalixAgent.Fleet.stop_existing(agent_id)

    {:ok, :ok} =
      SalixStore.Repo.transaction(fn ->
        # Late Session writes and claims take this same Agent row first.
        # Keep it locked through every child page and the parent deletion.
        SalixStore.Repo.query!(
          "SELECT agent_id FROM salix_agents WHERE agent_id=$1 FOR UPDATE",
          [agent_id]
        )

        delete_sessions(agent_id)
        SalixStore.Repo.query!("DELETE FROM salix_agents WHERE agent_id=$1", [agent_id])
        :ok
      end)

    :ok
  end

  defp delete_sessions(agent_id) do
    case SalixStore.Repo.query!(
           "SELECT session_id FROM salix_sessions WHERE agent_id=$1 LIMIT 128",
           [agent_id]
         ).rows do
      [] ->
        :ok

      rows ->
        for [session_id] <- rows, do: PG.delete_created_session!(agent_id, session_id)
        delete_sessions(agent_id)
    end
  end

  def seed(agent_id, state) do
    {:ok, head} = AgentPGStore.peek(agent_id)
    state = InternalSession.stamp(state, runtime_epoch: head.epoch)
    {:ok, frozen} = PG.prepare_import(agent_id, state, [])
    :ok = PG.import_session!(frozen)
  end
end
