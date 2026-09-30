defmodule SalixMeet.Ports.OwnerAttribution do
  @moduledoc false

  # Enriches a summary in memory by attributing each action item's free-text
  # `owner` to a Slack `owner_slack_id`. Delivery extracts the ids into its
  # product-owned snapshot and never persists the enriched summary.
  @callback attribute(state :: map(), summary :: map()) ::
              {:ok, map()} | :skip | {:error, term()}
  @callback attribute(state :: map(), summary :: map(), context :: map()) ::
              {:ok, map()} | :skip | {:error, term()}

  @optional_callbacks attribute: 3

  @spec attribute(map(), map()) :: {:ok, map()} | :skip | {:error, term()}
  def attribute(state, summary) when is_map(state) and is_map(summary),
    do: impl().attribute(state, summary)

  @spec attribute(map(), map(), map()) :: {:ok, map()} | :skip | {:error, term()}
  def attribute(state, summary, context)
      when is_map(state) and is_map(summary) and is_map(context) do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :attribute, 3) do
      mod.attribute(state, summary, context)
    else
      mod.attribute(state, summary)
    end
  end

  defp impl do
    Application.get_env(:salix_meet, :owner_attribution_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(_state, _summary), do: :skip
  end
end
