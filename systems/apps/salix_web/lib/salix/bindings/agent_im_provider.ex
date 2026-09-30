defmodule Salix.Bindings.AgentIMProvider do
  @moduledoc false

  @behaviour SalixAgent.Tools.ImRouter

  @impl true
  def list_connects(agent_id), do: SalixIM.Provider.list_connects(agent_id)

  @impl true
  def list_connects(agent_id, context), do: SalixIM.Provider.list_connects(agent_id, context)

  @impl true
  def discovery_catalog(agent_id, context),
    do: SalixIM.Provider.discovery_catalog(agent_id, context)

  @impl true
  def provider_manual(platform), do: SalixIM.Provider.provider_manual(platform)

  @impl true
  def provider_manual(platform, agent_id),
    do: SalixIM.Provider.provider_manual(platform, agent_id)

  @impl true
  def provider_manual(platform, agent_id, context),
    do: SalixIM.Provider.provider_manual(platform, agent_id, context)

  @impl true
  def task_execution_request(name, args, context),
    do: SalixIM.Provider.task_execution_request(name, args, context)

  @impl true
  def call_api(agent_id, platform, api, args),
    do: SalixIM.Provider.call_api(agent_id, platform, api, args)
end
