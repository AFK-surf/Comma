defmodule SalixAgent.Stop do
  @moduledoc """
  Stop existing Agent execution. This does not change lifecycle or prevent a
  later task; archive owns admission. No retry worker or durable
  stop-progress record is created. Modeled in tla/salix/AgentStop.tla.
  """
  alias SalixAgent.{Control, Placement}

  def stop(agent_id, tenant_id, _opts \\ []) do
    with {:ok, _agent} <- Control.get_including_archived(agent_id, tenant_id),
         :ok <- Placement.stop_existing(agent_id, reason: :normal, timeout: 5_000, force: true) do
      {:ok, %{next_cursor: nil}}
    end
  end
end
