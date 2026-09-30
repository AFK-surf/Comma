defmodule SalixAgent.AgentRuntimeConfig do
  @moduledoc """
  Runtime-facing view of agent identity/config.

  Runtime modules use this boundary when they need agent-level facts such as
  role and prompt overrides. The primary source is the agent control record.
  """

  alias SalixAgent.AgentControl

  @type t :: %{
          required(:role) => String.t(),
          required(:prompts) => map(),
          optional(:tenant_id) => String.t() | nil,
          optional(:group_id) => String.t() | nil,
          optional(:purpose) => String.t() | nil,
          optional(:disabled_tools) => [String.t()],
          optional(:inspector_policy) => map() | nil
        }

  @spec resolve(String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(agent_id) do
    case AgentControl.get_record(agent_id) do
      {:ok, agent} ->
        {:ok, from_control(agent)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Fill tenant/group facts from the agent control record when a runtime context
  only has `agent_id`.
  """
  @spec complete_context(map()) :: {:ok, map()} | {:error, term()}
  def complete_context(ctx) when is_map(ctx) do
    cond do
      present?(value(ctx, :tenant_id)) and present?(value(ctx, :group_id)) ->
        {:ok, ctx}

      present?(value(ctx, :agent_id)) ->
        with {:ok, runtime_config} <- resolve(value(ctx, :agent_id)) do
          {:ok,
           ctx
           |> Map.put_new(:tenant_id, runtime_config[:tenant_id])
           |> Map.put_new(:group_id, runtime_config[:group_id])}
        end

      true ->
        {:error, :missing_agent_runtime_context}
    end
  end

  def complete_context(_ctx), do: {:error, :missing_agent_runtime_context}

  @doc false
  def from_control(agent) when is_map(agent) do
    %{
      role: normalize_role(agent["role"]),
      tenant_id: agent["tenant_id"],
      group_id: agent["group_id"],
      purpose: agent["purpose"],
      disabled_tools: disabled_tools(agent["disabled_tools"]),
      inspector_policy: agent["inspector_policy"],
      prompts:
        %{}
        |> put_prompt("system_prompt", agent["system_prompt"])
        |> put_prompt("router_system_prompt", agent["router_system_prompt"])
    }
  end

  defp normalize_role("router"), do: "router"
  defp normalize_role("meeting"), do: "meeting"
  defp normalize_role(_role), do: "worker"

  defp disabled_tools(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp disabled_tools(_tools), do: []

  defp put_prompt(prompts, _key, nil), do: prompts
  defp put_prompt(prompts, _key, ""), do: prompts
  defp put_prompt(prompts, key, prompt) when is_binary(prompt), do: Map.put(prompts, key, prompt)
  defp put_prompt(prompts, _key, _prompt), do: prompts

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp present?(value), do: is_binary(value) and value != ""
end
