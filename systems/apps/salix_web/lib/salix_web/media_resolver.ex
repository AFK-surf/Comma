defmodule SalixWeb.MediaResolver do
  @moduledoc """
  Resolves an Agent's image, video, vision describer, and analyzer configs
  live from its model (`SalixAgent.AgentModel`). The agent port implementation
  lives in `Salix.Bindings.AgentMediaResolver`.
  """

  def resolve(agent_id), do: SalixAgent.AgentModel.resolve_media_for_agent(agent_id)
end
