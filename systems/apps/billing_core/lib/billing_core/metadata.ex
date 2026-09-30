defmodule BillingCore.Metadata do
  @moduledoc "Decode the historical billing JSON parameter expressions without losing updates."

  def object(value) when is_map(value), do: value
  def object(value) when is_binary(value), do: value |> Jason.decode!() |> object()

  def object(values) when is_list(values) do
    values
    |> Enum.reduce(%{}, fn value, acc -> Map.merge(acc, object(value)) end)
    |> Map.put("_legacy_updates", values)
  end
end
