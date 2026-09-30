defmodule SalixStore.OAuth.Adapters do
  @moduledoc """
  Registry resolving OAuth adapter modules by provider name. Port of willow's
  `internal/oauth/types.go` `Registry` (`NewRegistry` / `Lookup` / `Providers`).

  Intentional divergences:

    * The registry is a compile-time map rather than a mutable struct; willow's
      `Register` override hook for test fakes is replaced by the
      `:oauth_endpoint_overrides` application-env seam on the real adapters.
    * `MustLookup`'s formatted error becomes the atom `:unsupported_provider`.
  """

  @adapters %{
    "github" => SalixStore.OAuth.Adapters.GitHub,
    "google" => SalixStore.OAuth.Adapters.Google,
    "linear" => SalixStore.OAuth.Adapters.Linear,
    "notion" => SalixStore.OAuth.Adapters.Notion,
    "slack" => SalixStore.OAuth.Adapters.Slack
  }

  @doc """
  Resolve the adapter module for a provider name (case-insensitive, trimmed,
  matching willow's `Lookup` normalization).
  """
  @spec for_provider(String.t()) :: {:ok, module()} | {:error, :unsupported_provider}
  def for_provider(provider) when is_binary(provider) do
    case Map.fetch(@adapters, provider |> String.trim() |> String.downcase()) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unsupported_provider}
    end
  end

  def for_provider(_), do: {:error, :unsupported_provider}

  @doc "Sorted list of supported provider names (willow `Registry.Providers`)."
  @spec supported() :: [String.t()]
  def supported, do: @adapters |> Map.keys() |> Enum.sort()
end
