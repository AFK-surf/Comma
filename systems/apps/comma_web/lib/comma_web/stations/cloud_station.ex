defmodule CommaWeb.Stations.CloudStation do
  @moduledoc """
  The control plane for `SalixWeb.StationPlace`. Local roster admission joins
  the Workload owner's transaction; notifications follow its commit.
  """

  @behaviour SalixWeb.StationPlace

  @impl true
  def prepare(tenant_id, group_id, station_id, previous_station_id, version) do
    Comma.Stations.prepare_cloud_station(
      tenant_id,
      group_id,
      station_id,
      previous_station_id,
      version,
      public_origin()
    )
  end

  @impl true
  def publish(admission), do: Comma.Stations.publish_cloud_station(admission)

  # The Cloud VM's station reaches this server at its public URL, as an
  # enrolled station reaches the host its install command named.
  defp public_origin do
    case URI.parse(SalixWeb.Application.public_base_url() || "") do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if port == URI.default_port(scheme),
          do: "#{scheme}://#{host}",
          else: "#{scheme}://#{host}:#{port}"

      _ ->
        nil
    end
  end
end
