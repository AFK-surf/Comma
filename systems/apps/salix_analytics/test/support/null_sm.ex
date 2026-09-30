defmodule SalixAnalytics.NullSM do
  @moduledoc "Minimal state machine for analytics tests."
  @behaviour SalixStore.StateMachine
  @impl true
  def init(_agent), do: %{}
  @impl true
  def apply_event(state, _event), do: state
  @impl true
  def hot(_state), do: %{}
end
