defmodule CommaWeb.Stations.DeviceInstall do
  @moduledoc """
  Station installer for `SalixEnv.DeviceInstall`: a new device of a Group whose
  product serves stations (a Comma Workspace, a BridgeForTeams Project) gets the
  one-line station enrollment command (`Comma.Stations`).

  The enrollment is issued as the member who asked: the signed-in user of the
  product's Devices page, or the requester of the Router's install tool turn. A
  turn whose requester is no known member is refused, unless the product allows
  open enrollment: then the device has no owner. A Group no product owns or one
  not in use, a request with no known public origin, or a control plane without
  its signing keys answers `{:error, :station_install_unavailable}`.
  """

  @behaviour SalixEnv.DeviceInstall

  @platforms ~w(darwin-arm64 linux-x64 linux-arm64)

  @impl true
  def station_command(tenant_id, group_id, name, requester) do
    with {:ok, issuer} <- issuer(tenant_id, group_id, requester),
         {:ok, origin} <- enrollable(tenant_id, group_id, requester),
         {:ok, enrollment} <- enroll(tenant_id, group_id, issuer, name, origin, requester) do
      {:ok,
       %{
         "kind" => "station",
         "name" => name || "Station",
         "command" => enrollment["command"],
         "expires_at" => enrollment["expires_at"],
         "supported_platforms" => @platforms,
         "instructions" =>
           "Give command unchanged to the user to run on the target computer. It installs the Comma station as a user service and enrolls it in this Workspace. The command works once and expires after one hour. After enrollment, use station.list to find the station and its device_id."
       }}
    end
  end

  # A Group a product owns and serves, with the signing keys and a public origin to enroll at.
  defp enrollable(tenant_id, group_id, requester) do
    with true <- Comma.Stations.Config.enabled?(),
         true <- SalixStore.StationMembers.workspace_name(tenant_id, group_id) != "",
         true <- SalixStore.StationMembers.workspace_active?(tenant_id, group_id),
         origin when is_binary(origin) <-
           Comma.Stations.Config.origin(origin(requester) || public_origin()) do
      {:ok, origin}
    else
      _ -> {:error, :station_install_unavailable}
    end
  end

  defp origin(%{origin: origin}) when is_binary(origin), do: origin
  defp origin(_requester), do: nil

  # A request from another product's page or a Router's tool names no origin of Comma's: the server's own public one.
  defp public_origin do
    with base when is_binary(base) <- SystemsRuntime.get_env(:salix_web, :public_base_url),
         {:ok, %URI{scheme: scheme, host: host} = uri}
         when scheme in ["https", "http"] and is_binary(host) and host != "" <- URI.new(base) do
      URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
    else
      _ -> nil
    end
  end

  # A tool turn whose member may not enroll (a read-only one) reads as "needs a member who may".
  defp enroll(tenant_id, group_id, issuer, name, origin, requester) do
    case Comma.Stations.create_group_enrollment(tenant_id, group_id, issuer, name, origin) do
      {:error, :forbidden} when is_map_key(requester, :trusted_origin) ->
        {:error, :requester_required}

      result ->
        result
    end
  end

  defp issuer(_tenant_id, _group_id, %{user_id: user_id})
       when is_binary(user_id) and user_id != "",
       do: {:ok, user_id}

  defp issuer(tenant_id, group_id, %{trusted_origin: _} = ctx) do
    group_enroller = SalixStore.StationMembers.group_enroller()

    case CommaWeb.Stations.requester(ctx) do
      {:ok, user_id} ->
        {:ok, user_id}

      _ ->
        if SalixStore.StationMembers.enroller?(tenant_id, group_id, group_enroller),
          do: {:ok, group_enroller},
          else: {:error, :requester_required}
    end
  end

  defp issuer(_tenant_id, _group_id, _requester), do: {:error, :station_install_unavailable}
end
