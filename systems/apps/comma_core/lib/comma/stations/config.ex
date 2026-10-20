defmodule Comma.Stations.Config do
  @moduledoc """
  Deployment configuration of the station control plane (`config :comma_core,
  :stations`, set from COMMA_STATION_* in runtime.exs).

  Every setting has a default, so the control plane is on wherever the server
  has a key to derive its signing KEK from:

    * KEK: Salix keeps the signing keys and their KEK
      (`SalixStore.Stations.SigningKeys.kek/0`: `COMMA_STATION_SIGNING_KEK`,
      else derived from the subscription storage key). Without either the
      control plane is unavailable and fails closed.
    * Origin: `COMMA_STATION_ORIGIN`, else the origin of the request that
      reached it (`origin/1`).
    * Relays: `COMMA_STATION_RELAY_URLS`, else n0's public iroh relays.
    * Releases: still.fail's stable `station.json`.
  """

  @default_release_base "https://app.still.fail/releases"
  @default_release_manifest_url "https://app.still.fail/releases/station.json"
  # n0's public production relays (iroh `defaults::prod`), until Comma runs its own.
  @default_relay_urls [
    "https://use1-1.relay.n0.iroh.link./",
    "https://usw1-1.relay.n0.iroh.link./",
    "https://euc1-1.relay.n0.iroh.link./",
    "https://aps1-1.relay.n0.iroh.link./"
  ]

  @doc "The configured public origin, else `fallback` (the request's own origin)."
  def origin(fallback \\ nil), do: string(:origin) || fallback

  def relay_urls do
    case list(:relay_urls) do
      [] -> @default_relay_urls
      urls -> urls
    end
  end

  def gateway_keys, do: list(:gateway_keys)
  def release_base_url, do: string(:release_base_url) || @default_release_base
  def release_manifest, do: get()[:release_manifest]

  def release_manifest_url,
    do: string(:release_manifest_url) || @default_release_manifest_url

  @doc "Whether the keys that sign member credentials are available (the KEK is set or derivable)."
  def enabled?, do: match?({:ok, _}, SalixStore.Stations.SigningKeys.kek())

  @doc """
  `COMMA_STATIONS_DEVICE_CUTOVER` (on unless set to `false`): user devices of
  members who use stations run Worker turns as station chats and get the
  station installer instead of the device Connector. It never applies to a
  member without an enrolled station (`CommaWeb.StationWorkers`,
  `CommaWeb.Stations.DeviceInstall`), and has no effect while the control
  plane itself is unavailable.
  """
  def device_cutover?, do: get()[:device_cutover] != false and enabled?()

  defp get, do: SystemsRuntime.get_env(:comma_core, :stations, [])

  defp string(key) do
    case get()[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp list(key) do
    case get()[key] do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end
end
