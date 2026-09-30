defmodule SalixStore.StateMachine do
  @moduledoc """
  The seam between the generic storage kernel and application semantics.

  The store knows how to claim/commit/snapshot/replay; it does NOT know what an
  event means. A state machine supplies that: `init/1` builds the empty state
  for a fresh agent, `apply_event/2` folds one journal event into the state, and
  `hot/1` projects the small set of fields that must live in the head's commit
  point (status rows, watermarks) so the scheduler can decide without a replay.

  The agent state (sessions/messages/VFS) implements this behaviour; storage
  protocol tests use a small reducer in `test/support`.
  """

  @type state :: term()
  @type event :: map()

  @doc "Initial state for a freshly created agent."
  @callback init(agent_id :: String.t()) :: state()

  @doc """
  Fold one event into the state. Must be deterministic (replay-safe).

  Events are **string-keyed**: every committed batch is canonicalized through the
  JSON-lines codec before being applied in memory, and replay decodes the same
  way, so an implementation always receives string keys (`%{"type" => ...}`) and
  never atoms derived from dynamic/external data.
  """
  @callback apply_event(state(), event()) :: state()

  @doc """
  Project the hot fields to embed in the head's commit point. Must serialize to
  well under the 64KB head cap; cold data stays in snapshot/journal only.
  Defaults to `%{}`.
  """
  @callback hot(state()) :: map()

  @optional_callbacks hot: 1

  @doc "Apply a list of events in order."
  @spec apply_events(module(), term(), [map()]) :: term()
  def apply_events(sm, state, events) do
    Enum.reduce(events, state, fn ev, acc -> sm.apply_event(acc, ev) end)
  end

  @doc "Hot projection with a safe default when the SM doesn't implement it."
  @spec hot(module(), term()) :: map()
  def hot(sm, state) do
    if function_exported?(sm, :hot, 1), do: sm.hot(state), else: %{}
  end
end
