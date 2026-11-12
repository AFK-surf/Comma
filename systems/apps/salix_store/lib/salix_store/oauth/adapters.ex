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
    "feishu" => SalixStore.OAuth.Adapters.Feishu,
    "github" => SalixStore.OAuth.Adapters.GitHub,
    "google" => SalixStore.OAuth.Adapters.Google,
    "lark" => SalixStore.OAuth.Adapters.Lark,
    "linear" => SalixStore.OAuth.Adapters.Linear,
    "notion" => SalixStore.OAuth.Adapters.Notion,
    "secret" => SalixStore.OAuth.Adapters.Secret,
    "slack" => SalixStore.OAuth.Adapters.Slack,
    "x" => SalixStore.OAuth.Adapters.X
  }

  @doc """
  Resolve the adapter module for a provider name (case-insensitive, trimmed,
  matching willow's `Lookup` normalization).
  """
  @spec for_provider(String.t()) :: {:ok, module()} | {:error, :unsupported_provider}
  def for_provider(provider) when is_binary(provider) do
    name = provider |> String.trim() |> String.downcase()

    cond do
      custom?(name) ->
        {:ok, SalixWeb.OAuthCustomAdapter}

      true ->
        case Map.fetch(@adapters, name) do
          {:ok, mod} -> {:ok, mod}
          :error -> {:error, :unsupported_provider}
        end
    end
  end

  def for_provider(_), do: {:error, :unsupported_provider}

  @doc "Sorted list of supported provider names (willow `Registry.Providers`)."
  @spec supported() :: [String.t()]
  def supported, do: @adapters |> Map.keys() |> Enum.sort()

  @doc "The providers that sign in through an OAuth app a tenant or the deployment configures."
  @spec with_app() :: [String.t()]
  def with_app, do: List.delete(supported(), "secret")

  @doc "True for a provider a Workspace defined itself: `custom.<key>`."
  @spec custom?(term()) :: boolean()
  def custom?(provider) when is_binary(provider),
    do: Regex.match?(~r/\Acustom\.[a-z0-9][a-z0-9_-]{0,63}\z/, provider)

  def custom?(_provider), do: false
end
