defmodule CommaWeb.Stations.DeviceInstall do
  @moduledoc """
  Station installer for `SalixEnv.DeviceInstall` under
  `COMMA_STATIONS_DEVICE_CUTOVER` (on by default,
  `Comma.Stations.Config.device_cutover?/0`).

  A member who uses stations (has enrolled one in the Workspace) gets the
  one-line station enrollment command (`Comma.Stations`) for a new device
  instead of the Connector install script, so no device Connector credential
  is created. Everyone else keeps the Connector: a member without a station,
  a turn whose requester is unknown, a Group that is not a Comma Workspace, or
  a request with no known public origin.

  The enrollment is issued as that member: the signed-in user of Settings >
  Devices, or the requester of the Router's install tool turn. A Connector
  command for a known member is theirs too (`{:connector, user_id}`): the
  device it installs shows in their Settings > Devices.
  """

  @behaviour SalixEnv.DeviceInstall

  @platforms ~w(darwin-arm64 linux-x64 linux-arm64)

  @impl true
  def station_command(tenant_id, group_id, name, requester) do
    case issuer(requester) do
      {:ok, issuer} -> station_command(tenant_id, group_id, name, requester, issuer)
      :none -> :connector
    end
  end

  defp station_command(tenant_id, group_id, name, requester, issuer) do
    with true <- Comma.Stations.Config.device_cutover?(),
         {:ok, %{"salix_tenant_id" => ^tenant_id} = workspace} <-
           Comma.Workspaces.get_by_group(group_id),
         true <- uses_stations?(tenant_id, group_id, issuer),
         origin when is_binary(origin) <- Comma.Stations.Config.origin(origin(requester)) do
      # From here the member uses stations: a refusal is theirs, not a fallback.
      with {:ok, enrollment} <- enroll(workspace["id"], issuer, name, origin, requester) do
        {:ok,
         %{
           "kind" => "station",
           "name" => name || "Station",
           "command" => enrollment["command"],
           "expires_at" => enrollment["expires_at"],
           "supported_platforms" => @platforms,
           "instructions" =>
             "Give command unchanged to the user to run on the target computer. It installs the still.fail station as a user service and enrolls it in this Workspace. The command works once and expires after one hour. After enrollment, use station.list to find the station and its device_id."
         }}
      end
    else
      _ -> {:connector, issuer}
    end
  end

  defp uses_stations?(tenant_id, group_id, user_id) do
    case CommaWeb.Stations.Directory.list_group_stations(tenant_id, group_id) do
      {:ok, stations} -> Enum.any?(stations, &(&1["enrolled_by"] == user_id))
      _ -> false
    end
  end

  defp origin(%{origin: origin}) when is_binary(origin), do: origin
  defp origin(_requester), do: nil

  # A tool turn whose member may not enroll (a read-only one) reads as "needs a member who may".
  defp enroll(workspace_id, issuer, name, origin, requester) do
    case Comma.Stations.create_member_enrollment(workspace_id, issuer, name, origin) do
      {:error, :forbidden} when is_map_key(requester, :trusted_origin) ->
        {:error, :requester_required}

      result ->
        result
    end
  end

  defp issuer(%{user_id: user_id}) when is_binary(user_id) and user_id != "", do: {:ok, user_id}

  defp issuer(%{trusted_origin: _} = ctx) do
    case CommaWeb.Stations.requester(ctx) do
      {:ok, user_id} -> {:ok, user_id}
      _ -> :none
    end
  end

  defp issuer(_requester), do: :none
end
