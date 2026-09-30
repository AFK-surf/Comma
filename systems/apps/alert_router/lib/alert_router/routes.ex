defmodule AlertRouter.Routes do
  @moduledoc """
  Fail-closed route resolver. Shadow remains pinned to `#xp-test`; live routes
  use the reviewed public-channel ID materialized from environment desired
  state.
  """

  alias AlertRouter.CanonicalEvent

  @approved_shadow_channel_id "C0ALMF2AD70"

  @spec resolve(CanonicalEvent.t(), atom()) :: {:ok, map()} | {:error, term()}
  def resolve(event, mode \\ configured_mode())

  def resolve(%CanonicalEvent{}, :disabled), do: {:error, :router_disabled}

  def resolve(%CanonicalEvent{}, :shadow) do
    with {:ok, channel_id} <- configured_channel("shadow") do
      {:ok,
       %{
         route_id: "shadow",
         route_revision: 1,
         channel_id: channel_id,
         shadow: true
       }}
    end
  end

  def resolve(%CanonicalEvent{environment: "staging"}, :live) do
    with {:ok, channel_id} <- configured_channel("live") do
      {:ok,
       %{
         route_id: "live",
         route_revision: 1,
         channel_id: channel_id,
         shadow: false
       }}
    end
  end

  def resolve(%CanonicalEvent{environment: environment}, :live),
    do: {:error, {:unapproved_route_environment, "live", environment}}

  def resolve(_event, mode), do: {:error, {:unsupported_route_mode, mode}}

  defp configured_mode, do: Application.get_env(:alert_router, :mode, :disabled)

  defp configured_channel(route_id) do
    routes = Application.get_env(:alert_router, :slack, []) |> Keyword.get(:routes, %{})

    case routes[route_id] do
      @approved_shadow_channel_id = channel_id when route_id == "shadow" ->
        {:ok, channel_id}

      <<"C", rest::binary>> = channel_id when route_id == "live" and byte_size(rest) > 0 ->
        if String.match?(rest, ~r/^[A-Z0-9]+$/) do
          {:ok, channel_id}
        else
          {:error, {:unapproved_route_destination, route_id, channel_id}}
        end

      channel_id when is_binary(channel_id) and channel_id != "" ->
        {:error, {:unapproved_route_destination, route_id, channel_id}}

      _ ->
        {:error, {:route_not_configured, route_id}}
    end
  end
end
