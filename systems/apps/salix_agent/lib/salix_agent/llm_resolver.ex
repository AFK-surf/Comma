defmodule SalixAgent.LlmResolver do
  @moduledoc """
  Live per-agent provider resolution seam (willow's
  `ResolveAgentProviderConfig`): an agent references its template **by id
  only**; the template's `provider_config` is read at activation time, never
  snapshotted into the agent journal, so template edits apply on the agent's
  next round. The control plane implements this by mapping the agent record →
  `template_id` → template, and wires itself at startup via
  `Application.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)`
  (same seam pattern as `:notifier` / `:placement`).

  `{:ok, nil}` means no template-backed config is available through the
  configured resolver. Product-created agents are expected to have a control
  record and template. An error return means the agent is template-backed but
  the template can't be read right now; the round must fail rather than silently
  call the wrong provider.
  """

  @callback resolve(agent_id :: String.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback resolve_record(agent_record :: map()) :: {:ok, map() | nil} | {:error, term()}
  @optional_callbacks resolve_record: 1

  @spec resolve(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def resolve(agent_id) do
    case Application.get_env(:salix_agent, :llm_resolver) do
      nil -> {:ok, nil}
      mod -> mod.resolve(agent_id)
    end
  end

  @spec resolve_runtime(String.t()) :: {:ok, term()} | {:error, term()}
  def resolve_runtime(agent_id) do
    case resolve(agent_id) do
      {:ok, nil} -> {:ok, []}
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm_resolver, reason}}
    end
  end

  @doc false
  @spec resolve_runtime(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def resolve_runtime(agent_id, agent_record) when is_binary(agent_id) and is_map(agent_record) do
    SalixStore.ReadScope.fetch({:agent_llm, agent_id, agent_record}, fn ->
      do_resolve_runtime(agent_id, agent_record)
    end)
  end

  defp do_resolve_runtime(agent_id, agent_record) do
    result =
      case Application.get_env(:salix_agent, :llm_resolver) do
        nil ->
          {:ok, nil}

        mod ->
          if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve_record, 1) do
            mod.resolve_record(agent_record)
          else
            mod.resolve(agent_id)
          end
      end

    case result do
      {:ok, nil} -> {:ok, []}
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm_resolver, reason}}
    end
  end
end
