defmodule Comma.Accounts.SessionClientMetadata do
  @moduledoc """
  Normalizes display-only Session client metadata.

  Clients report only finite client/platform enums. The server derives the
  stored label; none of these values are device identity, an authentication
  factor, or a fraud signal.
  """

  @client_kinds ~w(web electron android ios watch api ssh)
  @client_platforms ~w(android ios watchos windows macos linux unknown)

  @spec attributes(map()) :: map()
  def attributes(attrs) when is_map(attrs) do
    case client_kind(value(attrs, "client_kind")) do
      nil ->
        %{}

      kind ->
        %{
          "client_kind" => kind,
          "client_platform" => client_platform(value(attrs, "client_platform"))
        }
    end
  end

  def attributes(_attrs), do: %{}

  @spec options(map()) :: keyword()
  def options(attrs) do
    case attributes(attrs) do
      %{} = metadata when map_size(metadata) == 0 ->
        []

      %{"client_kind" => kind, "client_platform" => platform} ->
        [
          client_kind: kind,
          client_platform: platform,
          device_label: device_label(kind, platform)
        ]
    end
  end

  defp client_kind(value) when is_binary(value) do
    kind = String.trim(value)
    if kind in @client_kinds, do: kind
  end

  defp client_kind(_value), do: nil

  defp client_platform(value) when is_binary(value) do
    platform = value |> String.trim() |> String.downcase()
    if platform in @client_platforms, do: platform, else: "unknown"
  end

  defp client_platform(_value), do: "unknown"

  defp device_label("web", "android"), do: "Web on Android"
  defp device_label("web", "ios"), do: "Web on iOS"
  defp device_label("web", "windows"), do: "Web on Windows"
  defp device_label("web", "macos"), do: "Web on macOS"
  defp device_label("web", "linux"), do: "Web on Linux"
  defp device_label("web", _platform), do: "Web browser"

  defp device_label("electron", "windows"), do: "Comma Desktop on Windows"
  defp device_label("electron", "macos"), do: "Comma Desktop on macOS"
  defp device_label("electron", "linux"), do: "Comma Desktop on Linux"
  defp device_label("electron", _platform), do: "Comma Desktop"

  defp device_label("android", _platform), do: "Comma Android app"
  defp device_label("ios", _platform), do: "Comma on iPhone"
  defp device_label("watch", _platform), do: "Comma on Apple Watch"

  defp device_label("ssh", _platform), do: "Comma SSH"

  defp device_label("api", _platform), do: "API client"

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
end
