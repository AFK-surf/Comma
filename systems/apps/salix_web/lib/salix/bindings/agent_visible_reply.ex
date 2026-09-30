defmodule Salix.Bindings.AgentVisibleReply do
  @moduledoc false

  @behaviour SalixAgent.VisibleReply

  @impl true
  def authorize(agent_id, scope), do: SalixIM.SourceBoundVisibleReply.authorize(agent_id, scope)
end
