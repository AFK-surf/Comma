defmodule SalixAgent.GroupRuntime do
  @moduledoc "Dispatches an agent call to a configured group-scoped runtime."

  alias SalixAgent.OAuthStore

  def call(agent_id, config_key, missing_error, command, args) when is_list(args) do
    with {:ok, group_id} <- group_id(agent_id),
         module when is_atom(module) and not is_nil(module) <-
           Application.get_env(:salix_agent, config_key) do
      apply(module, command, [group_id | args])
    else
      nil -> {:error, missing_error}
      {:error, _} = error -> error
      invalid -> {:error, {:invalid_runtime_module, config_key, invalid}}
    end
  end

  defp group_id(agent_id) do
    with {:ok, context} when is_map(context) <- OAuthStore.agent_oauth_context(agent_id),
         group_id when is_binary(group_id) and group_id != "" <-
           context[:group_id] || context["group_id"] do
      {:ok, group_id}
    else
      {:error, _} = error -> error
      _ -> {:error, :missing_group_id}
    end
  end
end
