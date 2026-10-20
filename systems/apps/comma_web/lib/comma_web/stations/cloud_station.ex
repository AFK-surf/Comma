defmodule CommaWeb.Stations.CloudStation do
  @moduledoc """
  The control plane for `SalixWeb.StationPlace`: a Group's Cloud VM station is
  placed in that Group's roster (`Comma.Stations.admit_cloud_station/6`),
  whichever product owns the Group.
  """

  @behaviour SalixWeb.StationPlace

  @impl true
  def admit(tenant_id, group_id, station_id, previous_station_id, version) do
    Comma.Stations.admit_cloud_station(
      tenant_id,
      group_id,
      station_id,
      previous_station_id,
      version,
      public_origin()
    )
  end

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
