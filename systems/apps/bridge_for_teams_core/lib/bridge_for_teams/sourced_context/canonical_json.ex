defmodule BridgeForTeams.SourcedContext.CanonicalJSON do
  @moduledoc "Deterministic JSON bytes and hashes for sourced-context evidence."

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    {:ok, encode_value(value)}
  rescue
    error in [ArgumentError, Jason.EncodeError] -> {:error, Exception.message(error)}
  end

  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "invalid canonical JSON: #{inspect(reason)}"
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn
        {key, child} when is_binary(key) ->
          {key, encode_value(child)}

        {key, _child} ->
          raise ArgumentError, "canonical JSON key is not a string: #{inspect(key)}"
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, encoded} -> Jason.encode!(key) <> ":" <> encoded end)

    "{" <> entries <> "}"
  end

  defp encode_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"
  end

  defp encode_value(value) when value in [true, false, nil], do: Jason.encode!(value)
  defp encode_value(value) when is_binary(value) or is_number(value), do: Jason.encode!(value)

  defp encode_value(value),
    do: raise(ArgumentError, "unsupported canonical JSON value: #{inspect(value)}")
end
