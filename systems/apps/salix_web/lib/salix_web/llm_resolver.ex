defmodule SalixWeb.LlmResolver do
  @moduledoc """
  Resolves an Agent's provider config live on every activation (willow's
  `ResolveAgentProviderConfig`): its model choice, else the platform model of
  its role (`SalixAgent.AgentModel`). No provider snapshot is journaled, so a
  changed choice or platform model applies on the agent's next round. The
  agent port implementation lives in `Salix.Bindings.AgentLlmResolver`.
  """

  def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)
end
