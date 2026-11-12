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
    * Releases: the Comma station's latest (`.github/workflows/station-release.yml`); a
      Comma release pins its own revision's (`COMMA_STATION_RELEASE_MANIFEST_URL`).
  """

  @default_release_base "https://cue-release.afk.surf/station-release"
  @default_release_manifest_url "https://cue-release.afk.surf/station-release/latest.json"
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

  @doc """
  Which way goes first for a desktop's station and its client: `salix-first` (direct and Salix race, an iroh relay is the
  backup) until a relay of our own is deployed, as the rest would go through n0's public ones; then `relay-first`
  (direct, an iroh relay, then Salix).
  """
  def route_policy do
    case string(:route_policy) do
      "relay-first" -> "relay-first"
      _ -> "salix-first"
    end
  end

  def gateway_keys, do: list(:gateway_keys)
  def release_base_url, do: string(:release_base_url) || @default_release_base
  def release_manifest, do: get()[:release_manifest]

  def release_manifest_url,
    do: string(:release_manifest_url) || @default_release_manifest_url

  @doc "Whether the keys that sign member credentials are available (the KEK is set or derivable)."
  def enabled?, do: match?({:ok, _}, SalixStore.Stations.SigningKeys.kek())

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
