defmodule CommaWeb.StationReleases do
  @moduledoc """
  The station release manifest Comma pins (contract §7), served at
  `/stations/releases/station.json` in still.fail's `releases/station.json`
  shape (`{version, build, commit}`). Configuration supplies it inline
  (COMMA_STATION_RELEASE_MANIFEST) or by URL (COMMA_STATION_RELEASE_MANIFEST_URL,
  by default still.fail's stable `station.json`).
  A URL is fetched by this one process, at most once per five minutes, so a
  burst of stations asking costs one upstream request; the last good copy is
  kept when a refresh fails.
  """
  use SystemsRuntime.Server

  alias Comma.Stations.Config

  @ttl_ms 5 * 60 * 1000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def manifest do
    case Config.release_manifest() do
      %{} = inline ->
        validate(inline)

      _ ->
        SystemsRuntime.Server.call(__MODULE__, :manifest, 15_000)
    end
  catch
    :exit, _ -> {:error, :release_unavailable}
  end

  @impl true
  def init(_opts), do: {:ok, %{manifest: nil, url: nil, fetched_at: nil}}

  @impl true
  def handle_call(:manifest, _from, state) do
    url = Config.release_manifest_url()
    now = SystemsClock.monotonic_time(:millisecond)

    if (state.url == url and state.fetched_at) && now - state.fetched_at < @ttl_ms do
      {:reply, {:ok, state.manifest}, state}
    else
      case fetch(url) do
        {:ok, manifest} ->
          {:reply, {:ok, manifest}, %{manifest: manifest, url: url, fetched_at: now}}

        {:error, _} = error ->
          if state.url == url and state.manifest,
            do: {:reply, {:ok, state.manifest}, state},
            else: {:reply, error, state}
      end
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 10_000, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        with {:ok, decoded} <- Jason.decode(body), do: validate(decoded)

      _ ->
        {:error, :release_unavailable}
    end
  rescue
    _ -> {:error, :release_unavailable}
  end

  defp validate(%{"version" => version} = manifest) when is_binary(version), do: {:ok, manifest}
  defp validate(_manifest), do: {:error, :release_unavailable}
end
