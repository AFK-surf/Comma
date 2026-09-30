defmodule SalixWeb.LlmResolver do
  @moduledoc """
  Resolves agent control record → `template_id` →
  template `provider_config`, read live from S3 on every activation (willow's
  `ResolveAgentProviderConfig`). Agents reference templates by id only — there
  is no journaled provider snapshot to go stale, so template edits apply on
  the agent's next round. The agent port implementation lives in
  `Salix.Bindings.AgentLlmResolver`.
  """

  def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)
end
