defmodule Salix.Bindings.AgentTrajectoryEvalSettings do
  @moduledoc false

  @behaviour SalixAgent.TrajectoryEval.TenantSettings

  @impl true
  def get(tenant_id), do: Salix.Control.Tenants.get_config(tenant_id, "trajectory_eval", %{})
end
