defmodule SalixAgent.State do
  @moduledoc """
  Agent root state shell used by the generic lease/claim store.

  Runtime session state does not live here. Internal sessions are owned by
  `SalixAgent.InternalSessionStore` / `SalixAgent.InternalSessionActor`; external
  runtime sessions are owned by `SalixAgent.ExternalAgentRuntime` /
  `SalixAgent.ExternalSessionActor`. This module intentionally ignores runtime
  session events so new code cannot rebuild the old agent-global session map.
  """

  @behaviour SalixStore.StateMachine

  defstruct agent_id: nil

  @type t :: %__MODULE__{agent_id: String.t() | nil}

  @impl true
  def init(agent_id), do: %__MODULE__{agent_id: agent_id}

  @impl true
  def apply_event(%__MODULE__{} = state, _event), do: state

  @impl true
  def hot(%__MODULE__{} = state), do: %{"agent_id" => state.agent_id}
end
