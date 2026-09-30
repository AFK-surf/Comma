defmodule SalixStore.JSON do
  @moduledoc "JSON-compatible term normalization shared by storage boundaries."
  def stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  def stringify(value), do: value
end
