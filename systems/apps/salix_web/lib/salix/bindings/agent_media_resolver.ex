defmodule Salix.Bindings.AgentMediaResolver do
  @moduledoc false

  @behaviour SalixAgent.MediaResolver

  @impl true
  def resolve(agent_id), do: SalixWeb.MediaResolver.resolve(agent_id)
end
