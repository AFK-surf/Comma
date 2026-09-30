defmodule SalixCluster.CounterSM do
  @moduledoc """
  A tiny deterministic state machine for the cluster chaos tests — a mirror of
  `SalixStore.TestSM` (which lives in salix_store's own `test/support` and is not
  visible across umbrella apps). A counter with an op log; events use string-
  friendly keys so they survive the JSON-lines journal round-trip unchanged.
  """
  @behaviour SalixStore.StateMachine

  @impl true
  def init(_agent_id), do: %{counter: 0, ops: 0}

  @impl true
  def apply_event(state, event) do
    case normalize(event) do
      %{"op" => "inc", "by" => n} -> %{state | counter: state.counter + n, ops: state.ops + 1}
      %{"op" => "set", "value" => v} -> %{state | counter: v, ops: state.ops + 1}
      _ -> %{state | ops: state.ops + 1}
    end
  end

  defp normalize(event), do: Map.new(event, fn {k, v} -> {to_string(k), v} end)

  @impl true
  def hot(state), do: %{counter: state.counter, ops: state.ops}
end
