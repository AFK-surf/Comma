defmodule Comma.Auth.HostedDomain do
  @moduledoc false

  @pattern ~r/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

  @spec pattern() :: Regex.t()
  def pattern, do: @pattern

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_hosted_domain}
  def normalize(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if Regex.match?(@pattern, normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_hosted_domain}
  end

  def normalize(_value), do: {:error, :invalid_hosted_domain}
end
