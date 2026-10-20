defmodule SalixAgent.ComputeAccess do
  @moduledoc "Product-owned access to explicitly selected workspace Workloads."

  @callback list(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback authorize(map(), String.t(), String.t()) :: {:ok, struct()} | {:error, term()}

  def list(ctx, args), do: invoke(:list, [ctx, args])
  def authorize(ctx, id, permission), do: invoke(:authorize, [ctx, id, permission])

  defp invoke(function, args) do
    case SystemsRuntime.get_env(:salix_agent, :compute_access_mod) do
      module when is_atom(module) and not is_nil(module) -> apply(module, function, args)
      _ -> {:error, :compute_workspace_unavailable}
    end
  end
end
