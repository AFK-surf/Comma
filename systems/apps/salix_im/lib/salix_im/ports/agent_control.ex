defmodule SalixIM.Ports.AgentControl do
  @moduledoc """
  Outbound port used by SalixIM when an inbound IM control command has to read
  or steer an agent runtime directly, instead of going through the agent loop.

  `SalixIM.Ports.AgentDelivery` stages work *for* the agent to do. This port is
  the opposite direction: the caller is asking the runtime about itself
  (`session_status/2`) or asking it to perform a runtime-owned maintenance
  operation (`compact_session/2`, `emergency_compact_session/2`, or the
  dashboard-shared `switch_router_session/3`). None appends
  anything to the session transcript as user input.
  """

  @callback switch_router_session(
              agent_id :: String.t(),
              tenant_id :: String.t(),
              expected_session_id :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @spec switch_router_session(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def switch_router_session(agent_id, tenant_id, expected_session_id),
    do: impl().switch_router_session(agent_id, tenant_id, expected_session_id)

  @callback session_status(agent_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback compact_session(agent_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback emergency_compact_session(agent_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @spec session_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def session_status(agent_id, session_id), do: impl().session_status(agent_id, session_id)

  @spec compact_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def compact_session(agent_id, session_id), do: impl().compact_session(agent_id, session_id)

  @spec emergency_compact_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def emergency_compact_session(agent_id, session_id),
    do: impl().emergency_compact_session(agent_id, session_id)

  defp impl, do: Application.get_env(:salix_im, :agent_control_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(_agent_id, _tenant_id, _expected_session_id),
      do: {:error, :agent_control_not_configured}

    @impl true
    def session_status(_agent_id, _session_id), do: {:error, :agent_control_not_configured}

    @impl true
    def compact_session(_agent_id, _session_id), do: {:error, :agent_control_not_configured}

    @impl true
    def emergency_compact_session(_agent_id, _session_id),
      do: {:error, :agent_control_not_configured}
  end
end
