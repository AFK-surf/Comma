defmodule Salix.Bindings.AgentLlmResolver do
  @moduledoc false

  @behaviour SalixAgent.LlmResolver

  @impl true
  def resolve(agent_id), do: SalixWeb.LlmResolver.resolve(agent_id)

  @impl true
  def resolve_record(agent_record),
    do: SalixAgent.Templates.resolve_llm_for_record(agent_record)
end
