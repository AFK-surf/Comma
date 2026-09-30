defmodule SalixAgent.TestSupport.SessionData do
  @moduledoc """
  Reads a stored session as data for assertions. Tests may look at the
  exported state; production code reads sessions only through the handle.

  Session semantics live in the Lean kernel. Tests that build or inspect a
  `%State{}` go through these helpers instead of an Elixir reimplementation.
  """

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore

  @doc "`InternalSessionStore.read/2`, with the state exported."
  def read(agent_id, session_id) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} -> {:ok, InternalSession.export(session)}
      other -> other
    end
  end

  @doc "Applies one event through the kernel and returns the exported state."
  def apply_event(state, event), do: apply_events(state, [event])

  @doc "Applies events in order through the kernel and returns the exported state."
  def apply_events(state, events) when is_list(events) do
    Enum.reduce(events, InternalSession.open(state), &InternalSession.apply_event(&2, &1))
    |> InternalSession.export()
  end

  @doc "Normalizes an exported state through the kernel."
  def normalize(state),
    do: state |> InternalSession.open() |> InternalSession.normalize() |> InternalSession.export()

  @doc "Round-trips an exported state through the kernel's storage encoding."
  def reload(state) do
    {:ok, session} =
      state |> InternalSession.open() |> InternalSession.persist() |> InternalSession.load()

    InternalSession.export(session)
  end

  @doc "Forks an exported state through the kernel."
  def fork(state, session_id, attrs \\ %{}) do
    with {:ok, child} <-
           state |> InternalSession.open() |> InternalSession.fork(session_id, attrs),
         do: {:ok, InternalSession.export(child)}
  end

  @doc "Runs a kernel query against an exported state."
  def query(state, name, args \\ nil),
    do: InternalSession.query(InternalSession.open(state), name, args)
end
