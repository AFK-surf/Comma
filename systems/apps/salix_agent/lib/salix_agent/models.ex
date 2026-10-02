defmodule SalixAgent.Models do
  @moduledoc """
  The model catalog: which models exist, and how each source asks for them.

  A model has three names. Its catalog id says which model it is, whichever
  source serves it. Each source has a request id for it: `gpt-5.5` is
  `gpt-5.5` at OpenAI and `openai/gpt-5.5` at OpenRouter. Its display name is
  for people, and its family names the line it belongs to across versions
  (Opus 4.8 and Opus 5 are both `Opus`). A source is what a Profile connects to: an API-key provider or a
  subscription plan.

  The catalog is platform data, generated from the provider model data that
  ships with pi-ai by `scripts/generate-model-catalog.mjs`. It holds no tenant
  data and no credentials.
  """

  @path Path.expand("../../priv/model_catalog.json", __DIR__)
  @external_resource @path
  @catalog @path |> File.read!() |> Jason.decode!()
  @sources @catalog["sources"]
  @list @catalog["models"]
  @by_id Map.new(@list, &{&1["id"], &1})

  @doc "Sources by id: `%{\"name\" => ..., \"kind\" => \"api_key\" | \"subscription\"}`."
  def sources, do: @sources

  def source(id) when is_binary(id), do: Map.fetch(@sources, id)
  def source(_), do: :error

  @doc "Catalog models in maker order, each with its `id`."
  def list, do: @list

  def get(id) when is_binary(id), do: Map.fetch(@by_id, id)

  def get(_), do: :error

  @doc "The request id and wire protocol a source uses for a catalog model."
  def route(model_id, source_id) do
    with {:ok, model} <- get(model_id),
         %{^source_id => route} <- model["routes"] do
      {:ok, route}
    else
      _ -> :error
    end
  end

  @doc "Catalog models that at least one of the given sources serves."
  def served_by(source_ids) do
    wanted = MapSet.new(source_ids)

    Enum.filter(list(), fn model ->
      Enum.any?(Map.keys(model["routes"]), &MapSet.member?(wanted, &1))
    end)
  end
end
