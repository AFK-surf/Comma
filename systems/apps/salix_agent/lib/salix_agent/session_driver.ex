defmodule SalixAgent.SessionDriver do
  @moduledoc """
  The host side of the kernel's session driver (`session_step`,
  `VerifiedKernel.Session.Drive`). The kernel decides each step of a session;
  the host performs the effect the step names and answers with its result.

  This module holds what every host step shares: the step query, and the
  commit that asks the driver to rebuild a step against a newer revision.
  """

  alias SalixAgent.{InternalSession, InternalSessionStore}
  alias SalixAgent.InternalSessionStore.Revision
  alias SalixVerifiedKernel.SessionStep

  @doc """
  One driver step over `state`: `{driver, effect}`. The step reads the clock
  and nonces here; `read` answers the host's own reads. The driver keeps the
  round's held values (`SalixVerifiedKernel.SessionStep`).
  """
  def step(state, driver, event, read \\ nil) do
    SessionStep.run(
      &InternalSession.query(state, :session_step, &1, &2),
      driver,
      event,
      reader(read)
    )
  end

  defp reader(read) do
    fn
      :nonce -> System.unique_integer([:positive])
      :clock -> System.system_time(:millisecond)
      request when is_function(read, 1) -> read.(request)
      request -> raise ArgumentError, "unanswered session read: #{inspect(request)}"
    end
  end

  @doc """
  Commits the events of a step taken over `revision`. A commit that meets a
  newer revision asks the driver to rebuild the step against it, unless the
  step's mode says `"rebuild" => false`.

  Returns `{:ok, revision, driver}`, `{:rerouted, revision, driver, effect}`
  when the rebuilt step took another branch, or `{:error, reason}`.
  """
  def commit(agent_id, session_id, revision, driver, {events, opts, mode}, read \\ nil) do
    if rebuild?(mode),
      do: commit_rebuilt(agent_id, session_id, revision, driver, events, opts, read),
      else: commit_plain(agent_id, session_id, revision, driver, events, opts)
  end

  defp rebuild?(%{"rebuild" => false}), do: false
  defp rebuild?(_mode), do: true

  defp commit_plain(agent_id, session_id, %Revision{} = revision, driver, events, opts) do
    with {:ok, revision} <-
           InternalSessionStore.commit_revision(agent_id, session_id, revision, events, opts),
         do: {:ok, revision, driver}
  end

  defp commit_plain(agent_id, session_id, nil, driver, events, opts) do
    with {:ok, _session} <- InternalSessionStore.commit(agent_id, session_id, events, opts),
         {:ok, revision} <- InternalSessionStore.read_revision(agent_id, session_id),
         do: {:ok, revision, driver}
  end

  defp commit_rebuilt(agent_id, session_id, revision, driver, events, opts, read) do
    state = if match?(%Revision{}, revision), do: revision.state

    builder = fn current ->
      if current == state do
        {:ok, events, opts, %{driver: driver}}
      else
        case step(current, driver, :rebuild, read) do
          {rebuilt, {:commit, events, opts, _mode}} -> {:ok, events, opts, %{driver: rebuilt}}
          {rebuilt, effect} -> {:error, {:rerouted, rebuilt, effect}}
        end
      end
    end

    case commit_dynamic(agent_id, session_id, revision, builder) do
      {:ok, revision, %{driver: driver}} ->
        {:ok, revision, driver}

      # The fresh session took another branch: continue from it.
      {:error, {:rerouted, driver, effect}} ->
        with {:ok, revision} <- InternalSessionStore.read_revision(agent_id, session_id),
             do: {:rerouted, revision, driver, effect}

      {:error, _} = error ->
        error
    end
  end

  defp commit_dynamic(agent_id, session_id, %Revision{} = revision, builder),
    do: InternalSessionStore.commit_revision_dynamic(agent_id, session_id, revision, builder)

  defp commit_dynamic(agent_id, session_id, nil, builder) do
    with {:ok, _session, meta} <-
           InternalSessionStore.commit_dynamic(agent_id, session_id, builder),
         {:ok, revision} <- InternalSessionStore.read_revision(agent_id, session_id),
         do: {:ok, revision, meta}
  end
end
