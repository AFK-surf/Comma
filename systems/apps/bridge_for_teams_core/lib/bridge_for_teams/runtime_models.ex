defmodule BridgeForTeams.RuntimeModels do
  @moduledoc """
  The runtime model a Worker bound to a station runs (`SalixAgent.StationBinding`).
  A Codex or Claude Code station runs only the models its own sign-in serves,
  so the binding stores a runtime choice (`SalixAgent.ModelChoice` of kind
  `runtime`: provider, catalog model, reasoning effort). Without a model the
  station runs its default model for that runtime.
  """

  alias BridgeForTeams.Salix.Client

  @providers ~w(codex claude)

  @doc """
  Catalog models `provider` serves, for the picker: `id`, `name` and `efforts`.
  """
  @spec catalog(String.t()) :: {:ok, [map()]} | {:error, term()}
  def catalog(provider) when provider in @providers do
    with {:ok, models} <- Client.impl().runtime_catalog(provider) do
      {:ok,
       for %{"id" => id, "routes" => %{^provider => %{"model" => _route}}} = model <- models do
         %{"id" => id, "name" => model["name"] || id, "efforts" => model["efforts"] || []}
       end}
    end
  end

  @doc """
  The choice to store for `params` (`model`, `reasoning_effort`) on a Worker
  of `provider`: a catalog model the provider serves and one of its efforts.
  """
  @spec choose(String.t(), map()) :: {:ok, map()} | {:error, :invalid_runtime_model}
  def choose(provider, %{"model" => model} = params) when is_binary(model) do
    effort = params["reasoning_effort"]

    with {:ok, catalog} <- catalog(provider),
         %{"efforts" => efforts} <- Enum.find(catalog, &(&1["id"] == model)),
         true <- effort in [nil, ""] or effort in efforts do
      {:ok,
       %{"kind" => "runtime", "provider" => provider, "model" => model}
       |> then(&if(effort in [nil, ""], do: &1, else: Map.put(&1, "reasoning_effort", effort)))}
    else
      _ -> {:error, :invalid_runtime_model}
    end
  end

  def choose(_provider, _params), do: {:error, :invalid_runtime_model}
end
