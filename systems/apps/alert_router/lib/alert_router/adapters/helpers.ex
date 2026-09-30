defmodule AlertRouter.Adapters.Helpers do
  @moduledoc false

  def parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, {:invalid_timestamp, value}}
    end
  end

  def parse_iso8601(value), do: {:error, {:invalid_timestamp, value}}

  def from_unix(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, {:invalid_unix_timestamp, value}}
    end
  end

  def from_unix(value), do: {:error, {:invalid_unix_timestamp, value}}

  def optional_unix(nil), do: {:ok, nil}
  def optional_unix(value), do: from_unix(value)

  def required_string(map, key) when is_map(map) do
    case map[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          value -> {:ok, value}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  def optional_string(map, key) when is_map(map) do
    case map[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def compact_string_map(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end)
    |> Map.new()
  end
end
