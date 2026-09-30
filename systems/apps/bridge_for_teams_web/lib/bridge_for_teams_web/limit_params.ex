defmodule BridgeForTeamsWeb.LimitParams do
  @moduledoc false

  @max_limit 500

  @spec read(map(), String.t(), pos_integer()) :: {:ok, pos_integer()} | {:error, :invalid_limit}
  def read(params, key, default \\ 100) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      value when is_integer(value) and value > 0 ->
        {:ok, min(value, @max_limit)}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {limit, ""} when limit > 0 -> {:ok, min(limit, @max_limit)}
          _ -> {:error, :invalid_limit}
        end

      _ ->
        {:error, :invalid_limit}
    end
  end
end
