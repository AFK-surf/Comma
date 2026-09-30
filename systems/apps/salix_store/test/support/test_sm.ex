defmodule SalixStore.TestSM do
  @moduledoc """
  A tiny deterministic state machine for exercising the storage protocol:
  a counter with an append-only op log. Event maps use string values so they
  survive the JSON-lines journal round-trip unchanged (atom keys are restored
  by the decoder).
  """
  @behaviour SalixStore.StateMachine

  @impl true
  def init(_agent_id), do: %{counter: 0, ops: 0}

  # Production state machines receive string-keyed events (the kernel
  # canonicalizes through the JSON-lines codec). This test SM is deliberately
  # lenient — it normalizes atom- or string-keyed events — so tests can both
  # commit through the store AND fold a local expected-model with hand-built
  # (atom-keyed) events and get identical results.
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
