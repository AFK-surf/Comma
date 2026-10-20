defmodule CommaWeb.Stations.GroupDirectory do
  @moduledoc """
  `CommaWeb.Stations.Directory` backed by the station control plane: the
  Group's non-removed stations in the roster Salix keeps
  (`SalixStore.Stations`), with `online` read from `CommaWeb.StationPresence`.
  It is read-only. While the control plane is unavailable it reports
  `:station_directory_unavailable`, so station tools fail closed.
  """

  @behaviour CommaWeb.Stations.Directory

  @impl true
  def list_group_stations(tenant_id, group_id)
      when is_binary(tenant_id) and is_binary(group_id) do
    if Comma.Stations.Config.enabled?() do
      :ok = Comma.Stations.Window.group(tenant_id, group_id)
      online = CommaWeb.StationPresence.online(group_id)

      {:ok,
       Enum.map(SalixStore.Stations.roster(tenant_id, group_id), fn station ->
         %{
           "id" => station.id,
           "name" => station.name,
           "version" => station.version,
           "enrolled_by" => station.enrolled_by,
           "online" => MapSet.member?(online, station.id)
         }
       end)}
    else
      {:error, :station_directory_unavailable}
    end
  end

  def list_group_stations(_tenant_id, _group_id), do: {:error, :station_directory_unavailable}
end
