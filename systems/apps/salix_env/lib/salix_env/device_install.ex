defmodule SalixEnv.DeviceInstall do
  @moduledoc "Installation commands for new devices in an already-authorized group."

  alias SalixEnv.ConnectorTokens
  alias SalixStore.{ConnectorInstall, ServerReleaseDescriptor}

  @platforms ConnectorInstall.platforms()

  def create_command(tenant_id, group_id, name, opts \\ []) do
    with {:ok, install, _credential} <- create_install(tenant_id, group_id, name, opts),
         do: {:ok, install}
  end

  def create_token_command(tenant_id, group_id, attrs) do
    with {:ok, install, credential} <-
           create_install(tenant_id, group_id, attrs["name"], token_attrs: attrs),
         do: {:ok, Map.put(credential, "install_command", install["command"])}
  end

  defp create_install(tenant_id, group_id, name, opts) do
    with true <- is_binary(name) and String.trim(name) != "",
         {:ok, artifacts} <- artifacts(opts),
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
         "command" => command(credential, artifacts),
         "supported_platforms" => @platforms,
         "access" => "read_only",
         "run_mode" => "background_until_reboot",
         "registration_expires_at" => credential["registration_expires_at"],
         "verification_path" => "connection-check.txt",
         "verification_content" => "COMMA_CONNECTOR_READ_OK",
         "instructions" =>
           "Give command unchanged to the user to run on the target computer. The script asks for local consent before installing and registering. Retain device_id. Use device.get and its exact environment_id, then copy verification_path through Connector to vfs and compare verification_content with fs.read_file. Online status alone does not pass verification. Reuse this command after an uncertain result. First registration must occur before registration_expires_at. After registration, that deadline does not disconnect the device. Explain in the user's language that Connector starts read-only, survives closing this terminal, and runs until reboot. No SSH or Drive setup is required."
       }, credential}
    end
  end

  defp artifacts(opts) do
    case Application.get_env(:salix_env, :device_install_local_artifact_root) do
      nil -> published_artifacts(opts)
      _ -> local_artifacts()
    end
  end

  @doc false
  def local_artifact_path(platform) when platform in @platforms do
    with root when is_binary(root) <-
           Application.get_env(:salix_env, :device_install_local_artifact_root),
         path = Path.join([root, platform, "salix-connect"]),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  def local_artifact_path(_), do: {:error, :not_found}

  defp local_artifacts do
    base =
      SalixEnv.Ports.PublicURL.connector_server_url()
      |> String.replace_prefix("wss://", "https://")
      |> String.replace_prefix("ws://", "http://")
      |> String.trim_trailing("/")

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
               Application.get_env(:salix_env, :device_install_artifact_root)
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
  def command(credential, artifacts) do
    script = """
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
    """

    lines = MapSet.new(String.split(script, "\n"))

    delimiter =
      Enum.find_value(0..MapSet.size(lines), fn suffix ->
        candidate = "COMMA_DEVICE_INSTALL_#{suffix}"
        if not MapSet.member?(lines, candidate), do: candidate
      end)

    "sh <<'#{delimiter}'\n" <> script <> delimiter
  end

  defp shell_quote(value), do: ConnectorInstall.shell_quote(value)
end
