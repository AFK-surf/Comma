defmodule SalixEnv.DeviceInstall do
  @moduledoc """
  Installation commands for new devices in an already-authorized group: a
  station enrollment from the configured station installer
  (`config :salix_env, :station_install, Module`, see `c:station_command/4`).
  The result has `"kind" => "station"` and the enrollment `"command"`.

  A Group without a station installer, or a request the installer cannot
  serve (no known member, no public origin), gets
  `{:error, :station_install_unavailable}`: a computer joins through the Comma
  desktop app instead.
  """

  @doc """
  The station install for a Group's new device. `requester` names the member
  who asked: `%{user_id: id}` from a signed-in surface, the tool ctx subset
  (`tenant_id`, `group_id`, `trusted_origin`) from the Router's tool, or nil.
  """
  @callback station_command(
              tenant_id :: String.t(),
              group_id :: String.t(),
              name :: String.t() | nil,
              requester :: map() | nil
            ) :: {:ok, map()} | {:error, term()}

  def create_command(tenant_id, group_id, name, opts \\ []),
    do: station_command(tenant_id, group_id, name, opts[:requester])

  def create_token_command(tenant_id, group_id, attrs, opts \\ []) do
    requester =
      case get_in(attrs, ["meta", "owner_user_id"]) do
        user_id when is_binary(user_id) -> %{user_id: user_id, origin: opts[:origin]}
        _ -> nil
      end

    # A station gets the default station name, which members can rename.
    with {:ok, install} <- station_command(tenant_id, group_id, nil, requester) do
      {:ok,
       install
       |> Map.take(["kind", "name", "expires_at", "supported_platforms"])
       |> Map.put("install_command", install["command"])}
    end
  end

  defp station_command(tenant_id, group_id, name, requester) do
    case SystemsRuntime.get_env(:salix_env, :station_install) do
      nil -> {:error, :station_install_unavailable}
      module -> module.station_command(tenant_id, group_id, name, requester)
    end
  end
end
