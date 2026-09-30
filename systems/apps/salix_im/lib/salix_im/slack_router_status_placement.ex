defmodule SalixIM.SlackRouterStatusPlacement do
  @moduledoc false

  @callback ensure_started(agent_id :: String.t(), connect_id :: String.t()) ::
              {:ok, pid()} | {:error, term()}
  @callback local_owner?(agent_id :: String.t()) :: boolean()

  def ensure_started(agent_id, connect_id), do: impl().ensure_started(agent_id, connect_id)
  def local_owner?(agent_id), do: impl().local_owner?(agent_id)

  defp impl do
    Application.get_env(
      :salix_im,
      :slack_router_status_placement,
      __MODULE__.LocalFleet
    )
  end

  defmodule LocalFleet do
    @moduledoc false
    @behaviour SalixIM.SlackRouterStatusPlacement

    @impl true
    def ensure_started(agent_id, connect_id),
      do: SalixIM.SlackRouterStatus.ensure_actor_local(connect_id, agent_id)

    @impl true
    def local_owner?(_agent_id), do: true
  end
end
