defmodule Salix.Bindings.AgentComposioStore do
  @moduledoc false

  @behaviour SalixAgent.ComposioStore

  @impl true
  def settings(tenant), do: Salix.Control.ComposioSettings.get(tenant)
end
