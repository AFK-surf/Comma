defmodule SalixEnv.DeviceInstall do
  @moduledoc """
  Installation commands for new devices in an already-authorized group.

  An optional station installer can replace the Connector command
  (`config :salix_env, :station_install, Module`, see `c:station_command/4`).
  When it answers `{:ok, install}`, no Connector credential is created and the
  result has `"kind" => "station"` with the station enrollment `"command"`.

  A Connector command belongs to the member who asked for it: the device it
  installs is theirs (`meta.owner_user_id`), so they find it in Settings >
  Devices and set its access there.
  """

  alias SalixEnv.ConnectorTokens
  alias SalixEnv.Ports.PublicURL
  alias SalixStore.{ConnectorInstall, ServerReleaseDescriptor}

  @platforms ConnectorInstall.platforms()

  @doc """
  The station install for a Group's new device, or `:connector` when the Group
  keeps the Connector installer. `requester` names the member who asked:
  `%{user_id: id}` from a signed-in surface, the tool ctx subset
  (`tenant_id`, `group_id`, `trusted_origin`) from the Router's tool, or nil.
  `{:connector, user_id}` keeps the Connector installer and names the member
  who asked, who owns the device it installs.
  """
  @callback station_command(
              tenant_id :: String.t(),
              group_id :: String.t(),
              name :: String.t() | nil,
              requester :: map() | nil
            ) :: {:ok, map()} | :connector | {:connector, String.t()} | {:error, term()}

  def create_command(tenant_id, group_id, name, opts \\ []) do
    case station_command(tenant_id, group_id, name, opts[:requester]) do
      {:connector, owner_user_id} ->
        opts = Keyword.put(opts, :token_attrs, owner_attrs(owner_user_id))

        with {:ok, install, _credential} <- create_install(tenant_id, group_id, name, opts),
             do: {:ok, install}

      result ->
        result
    end
  end

  def create_token_command(tenant_id, group_id, attrs, opts \\ []) do
    requester =
      case get_in(attrs, ["meta", "owner_user_id"]) do
        user_id when is_binary(user_id) -> %{user_id: user_id, origin: opts[:origin]}
        _ -> nil
      end

    # The name here is the Connector's credential name; a station gets the
    # default station name, which members can rename.
    case station_command(tenant_id, group_id, nil, requester) do
      {:connector, _owner_user_id} ->
        with {:ok, install, credential} <-
               create_install(tenant_id, group_id, attrs["name"], token_attrs: attrs),
             do: {:ok, Map.put(credential, "install_command", install["command"])}

      {:ok, install} ->
        {:ok,
         install
         |> Map.take(["kind", "name", "expires_at", "supported_platforms"])
         |> Map.put("install_command", install["command"])}

      error ->
        error
    end
  end

  # The installer's answer, with `:connector` as `{:connector, owner}` (nil when no member is known).
  defp station_command(tenant_id, group_id, name, requester) do
    module = SystemsRuntime.get_env(:salix_env, :station_install)

    case module && module.station_command(tenant_id, group_id, name, requester) do
      answer when answer in [nil, :connector] -> {:connector, requester_user(requester)}
      answer -> answer
    end
  end

  defp requester_user(%{user_id: user_id}) when is_binary(user_id) and user_id != "", do: user_id
  defp requester_user(_requester), do: nil

  defp owner_attrs(owner_user_id) when is_binary(owner_user_id),
    do: %{"meta" => %{"owner_user_id" => owner_user_id}}

  defp owner_attrs(nil), do: %{}

  defp create_install(tenant_id, group_id, name, opts) do
    with true <- is_binary(name) and String.trim(name) != "",
         {:ok, _artifacts} <- artifacts(opts),
         {:ok, credential} <-
           ConnectorTokens.create_group_connector_token(
             group_id,
             tenant_id,
             Map.merge(
               Keyword.get(opts, :token_attrs, %{}) |> Map.take(["meta"]),
               %{
                 "name" => name,
                 "alias" => name,
                 "registration_expires_in_seconds" =>
                   Keyword.get(opts, :registration_ttl_seconds, 900)
               }
             )
           ) do
      {:ok,
       %{
         "device_id" => credential["device_id"],
         "name" => name,
         "command" => command(credential),
         "supported_platforms" => @platforms,
         "access" => "read_only",
         "run_mode" => "background_until_reboot",
         "registration_expires_at" => credential["registration_expires_at"],
         "verification_path" => "connection-check.txt",
         "verification_content" => "COMMA_CONNECTOR_READ_OK",
         "instructions" =>
           "Give command unchanged to the user to run on the target computer. The script asks for local consent before installing and registering. Retain device_id. Use device.get and its exact environment_id, then copy verification_path through Connector to vfs and compare verification_content with fs.read_file. Online status alone does not pass verification. Reuse this command after an uncertain result. First registration must occur before registration_expires_at. After registration, that deadline does not disconnect the device. Explain in the user's language that Connector starts read-only, survives closing this terminal, and runs until reboot. The computer belongs to the Workspace member who asked for this command: they allow operations on it in Comma Settings > Devices, from any of their clients. No SSH or Drive setup is required."
       }, credential}
    end
  end

  defp artifacts(opts) do
    case SystemsRuntime.get_env(:salix_env, :device_install_local_artifact_root) do
      nil -> published_artifacts(opts)
      _ -> local_artifacts()
    end
  end

  @doc false
  def local_artifact_path(platform) when platform in @platforms do
    with root when is_binary(root) <-
           SystemsRuntime.get_env(:salix_env, :device_install_local_artifact_root),
         path = Path.join([root, platform, "salix-connect"]),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  def local_artifact_path(_), do: {:error, :not_found}

  defp local_artifacts do
    base = http_base()

    Enum.reduce_while(@platforms, {:ok, %{}}, fn platform, {:ok, entries} ->
      case local_artifact_path(platform) do
        {:ok, _} ->
          {:cont,
           {:ok,
            Map.put(
              entries,
              platform,
              base <> "/v1/device-connection/" <> platform <> "/salix-connect"
            )}}

        _ ->
          {:halt, {:error, :connector_release_unavailable}}
      end
    end)
  end

  defp published_artifacts(opts) do
    Enum.reduce_while(@platforms, {:ok, %{}}, fn platform, {:ok, entries} ->
      target =
        case Keyword.get(
               opts,
               :artifact_root,
               SystemsRuntime.get_env(:salix_env, :device_install_artifact_root)
             ) do
          nil -> ServerReleaseDescriptor.target("salix-connect", platform)
          root -> ServerReleaseDescriptor.target("salix-connect", platform, root)
        end

      case target do
        {:ok, %{source: source}} -> {:cont, {:ok, Map.put(entries, platform, source)}}
        {:error, _} -> {:halt, {:error, :connector_release_unavailable}}
      end
    end)
  end

  @doc false
  # The command handed to the user is one line; the server renders the script
  # (`install_script/1`) for whoever presents the install's Connector token.
  def command(credential) do
    "curl -sSL -H #{shell_quote("Authorization: Bearer " <> credential["token"])} " <>
      "#{shell_quote(http_base() <> "/v1/device-connection/install.sh")} | sh"
  end

  @doc """
  The installer script for a Connector token, served at
  `GET /v1/device-connection/install.sh`. The command pipes it to `sh`, so
  every outcome is a script; errors print a reason and exit 1.
  """
  def install_script(raw_token) do
    with {:ok, _tenant_id, record} <- ConnectorTokens.validate_connector_token(raw_token),
         {:ok, artifacts} <- artifacts([]) do
      credential =
        record
        |> Map.take(["group_id", "device_id", "name"])
        |> Map.merge(%{"token" => raw_token, "server" => PublicURL.connector_server_url()})

      {:ok, script(credential, artifacts)}
    else
      {:error, :unauthorized} ->
        {:error, :unauthorized,
         failure("This install command is invalid or has expired. Ask Comma for a new one.")}

      {:error, _} ->
        {:error, :unavailable,
         failure(
           "The Connector release is unavailable right now. Try the same command again later."
         )}
    end
  end

  defp failure(message), do: "printf '%s\\n' #{shell_quote(message)} >&2\nexit 1\n"

  # The braces make `sh` read the whole script before running any of it, so a
  # truncated download runs nothing.
  defp script(credential, artifacts) do
    """
    {
    set -eu
    umask 077
    printf '%s\\n' #{shell_quote("Connect this computer to Comma Group #{credential["group_id"]} at #{credential["server"]}.")}
    printf '%s\\n' 'Access starts read-only. Connector runs in the background until reboot. No startup service will be installed.'
    printf '%s' 'Type yes to install and connect: ' >/dev/tty
    IFS= read -r comma_consent </dev/tty
    [ "$comma_consent" = yes ] || { echo 'Installation canceled.'; exit 1; }
    #{ConnectorInstall.artifact_exports(Map.new(artifacts, fn {platform, source} -> {platform, %{"COMMA_CONNECTOR_SOURCE" => source}} end))}
    state="${HOME:?HOME is required}/.comma/devices/"#{shell_quote(credential["device_id"])}
    mkdir -p "$state"
    download=$(mktemp "$state/.download.XXXXXX")
    trap 'rm -f "$download"' 0
    curl -fsSL --connect-timeout 10 --max-time 90 "$COMMA_CONNECTOR_SOURCE" -o "$download"
    chmod 700 "$download"
    mv -f "$download" "$state/salix-connect"
    printf '%s\\n' 'COMMA_CONNECTOR_READ_OK' >"$state/connection-check.txt"
    export SALIX_CONNECTOR_TOKEN=#{shell_quote(credential["token"])}
    trap '' HUP
    nohup "$state/salix-connect" --device --scope local_file_read \\
      --server #{shell_quote(credential["server"])} --name #{shell_quote(credential["name"])} \\
      --root "$state" --reconnect </dev/null >>"$state/connector.log" 2>&1 &
    echo "Connector startup requested. Verify the connection-check.txt file through Comma. You can close this terminal."
    }
    """
  end

  defp http_base do
    PublicURL.connector_server_url()
    |> String.replace_prefix("wss://", "https://")
    |> String.replace_prefix("ws://", "http://")
    |> String.trim_trailing("/")
  end

  defp shell_quote(value), do: ConnectorInstall.shell_quote(value)
end
