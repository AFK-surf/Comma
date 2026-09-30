defmodule SalixWeb.MediaResolver do
  @moduledoc """
  Resolves template-backed image, video, vision describer, and analyzer configs
  live from the agent template store. The agent port implementation lives in
  `Salix.Bindings.AgentMediaResolver`.
  """

  def resolve(agent_id), do: SalixAgent.Templates.resolve_media_for_agent(agent_id)
end
