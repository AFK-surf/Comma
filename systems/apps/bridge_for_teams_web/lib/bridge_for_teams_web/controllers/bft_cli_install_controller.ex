defmodule BridgeForTeamsWeb.BFTCLIInstallController do
  @moduledoc """
  Public installer entrypoint for the admin `bft` CLI.

  The dashboard can show a stable install command before the user starts CLI
  device login from their terminal. Deployments must configure
  `:bft_cli_artifact_base_url` (preferred, platform-aware Go release layout) or
  `:bft_cli_artifact_url`; otherwise the script fails loudly instead of
  pretending a local `bft` binary exists.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  @doc "GET /v1/cli/install.sh"
  def show(conn, _params) do
    script =
      cond do
        base_url = configured_string(:bft_cli_artifact_base_url) ->
          platform_install_script(
            base_url,
            configured_string(:bft_cli_release_id) || "latest",
            dashboard_base_url(conn)
          )

        artifact_url = configured_string(:bft_cli_artifact_url) ->
          install_script(
            artifact_url,
            configured_string(:bft_cli_sha256),
            dashboard_base_url(conn)
          )

        true ->
          unavailable_script()
      end

    conn
    |> put_resp_content_type("text/x-shellscript", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, script)
  end

  @doc "GET /v1/cli/release"
  def release(conn, _params) do
    case release_metadata(conn) do
      {:ok, metadata} ->
        send_json(conn, 200, %{"ok" => true, "data" => metadata})

      {:error, metadata} ->
        send_json(conn, 503, %{
          "ok" => false,
          "error" => %{
            "code" => "bft_cli_installer_not_configured",
            "message" => "BFT CLI installer is not configured on this deployment.",
            "details" => metadata
          }
        })
    end
  end

  defp platform_install_script(base_url, release_id, api_base_url) do
    base_url = String.trim_trailing(base_url, "/")
    release_path = if release_id == "latest", do: "latest", else: "releases/#{release_id}"

    """
    #!/usr/bin/env sh
    set -eu

    log() { printf '%s\\n' "$*" >&2; }
    fail() { printf 'bft install failed: %s\\n' "$*" >&2; exit 1; }
    #{String.trim(sha256_verify_function())}

    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$os" in
      darwin|linux) ;;
      *) fail "unsupported OS: $os" ;;
    esac
    case "$arch" in
      arm64|aarch64) arch="arm64" ;;
      x86_64|amd64) arch="amd64" ;;
      *) fail "unsupported architecture: $arch" ;;
    esac
    platform="$os-$arch"

    artifact_url="#{base_url}/#{release_path}/$platform/bft"
    checksum_url="$artifact_url.sha256"
    install_dir="${BFT_CLI_INSTALL_DIR:-$HOME/.local/bin}"
    target="$install_dir/bft"
    config_path="${BFT_CLI_CONFIG:-$HOME/.bridge-for-teams/cli.json}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/bft-cli.XXXXXX")"
    checksum_tmp="$tmp.sha256"
    cleanup() { rm -f "$tmp" "$checksum_tmp"; }
    trap cleanup EXIT HUP INT TERM

    log "Installing BridgeForTeams bft CLI for $platform"
    mkdir -p "$install_dir"
    curl -fsSL "$artifact_url" -o "$tmp"
    curl -fsSL "$checksum_url" -o "$checksum_tmp" || fail "BFT CLI checksum not found at $checksum_url"
    expected="$(awk '{print $1}' "$checksum_tmp")"
    verify_sha256 "$expected" "$tmp"
    chmod 0755 "$tmp"
    mv "$tmp" "$target"
    trap - EXIT HUP INT TERM

    #{String.trim(config_bootstrap_script(api_base_url))}

    log "[ok] bft installed at $target"
    log "Next: run bft auth login --url #{api_base_url} --output text and approve the device login in the dashboard."
    """
    |> trim_script()
  end

  defp install_script(artifact_url, sha256, api_base_url) do
    checksum_step =
      if sha256 do
        """
        verify_sha256 #{shell_quote(sha256)} "$tmp"
        """
      else
        "fail 'BFT CLI checksum is not configured on this deployment.'"
      end

    """
    #!/usr/bin/env sh
    set -eu

    log() { printf '%s\\n' "$*" >&2; }
    fail() { printf 'bft install failed: %s\\n' "$*" >&2; exit 1; }
    #{String.trim(sha256_verify_function())}

    install_dir="${BFT_CLI_INSTALL_DIR:-$HOME/.local/bin}"
    target="$install_dir/bft"
    config_path="${BFT_CLI_CONFIG:-$HOME/.bridge-for-teams/cli.json}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/bft-cli.XXXXXX")"
    cleanup() { rm -f "$tmp"; }
    trap cleanup EXIT HUP INT TERM

    log 'Installing BridgeForTeams bft CLI'
    mkdir -p "$install_dir"
    curl -fsSL #{shell_quote(artifact_url)} -o "$tmp"
    #{String.trim(checksum_step)}
    chmod 0755 "$tmp"
    mv "$tmp" "$target"
    trap - EXIT HUP INT TERM

    #{String.trim(config_bootstrap_script(api_base_url))}

    log "[ok] bft installed at $target"
    log "Next: run bft auth login --url #{api_base_url} --output text and approve the device login in the dashboard."
    """
    |> trim_script()
  end

  defp sha256_verify_function do
    """
    verify_sha256() {
      expected="$1"
      file="$2"
      if command -v shasum >/dev/null 2>&1; then
        printf '%s  %s\\n' "$expected" "$file" | shasum -a 256 -c -
      elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\\n' "$expected" "$file" | sha256sum -c -
      else
        fail "sha256 verification tool not found; install shasum or sha256sum"
      fi
    }
    """
  end

  defp unavailable_script do
    """
    #!/usr/bin/env sh
    set -eu

    printf '%s\\n' 'BridgeForTeams bft CLI installer is not configured on this deployment.' >&2
    printf '%s\\n' 'Ask an operator to set :bft_cli_artifact_base_url or :bft_cli_artifact_url and redeploy, or use go run ./systems/cli/bft/cmd/bft only for local development.' >&2
    exit 1
    """
    |> trim_script()
  end

  defp release_metadata(conn) do
    install_url =
      conn
      |> dashboard_base_url()
      |> String.trim_trailing("/")
      |> then(&(&1 <> "/v1/cli/install.sh"))

    cond do
      base_url = configured_string(:bft_cli_artifact_base_url) ->
        base_url = String.trim_trailing(base_url, "/")
        release_id = configured_string(:bft_cli_release_id) || "latest"
        release_path = if release_id == "latest", do: "latest", else: "releases/#{release_id}"

        {:ok,
         %{
           "mode" => "bft_cli_release",
           "layout" => "platform",
           "release_id" => release_id,
           "artifact_base_url" => base_url,
           "metadata_url" => "#{base_url}/#{release_path}/metadata.json",
           "install_url" => install_url,
           "checksum_required" => true
         }}

      artifact_url = configured_string(:bft_cli_artifact_url) ->
        {:ok,
         %{
           "mode" => "bft_cli_release",
           "layout" => "legacy",
           "release_id" => configured_string(:bft_cli_release_id) || "legacy",
           "artifact_url" => artifact_url,
           "install_url" => install_url,
           "checksum_required" => true,
           "checksum_configured" => configured_string(:bft_cli_sha256) != nil
         }}

      true ->
        {:error, %{"mode" => "bft_cli_release", "install_url" => install_url}}
    end
  end

  defp config_bootstrap_script(api_base_url) do
    """
    if [ ! -f "$config_path" ]; then
      mkdir -p "$(dirname "$config_path")"
      umask 077
      {
        printf '%s\\n' '{'
        printf '  "api_base_url": %s\\n' #{json_shell_string(api_base_url)}
        printf '%s\\n' '}'
      } > "$config_path"
      chmod 0600 "$config_path" 2>/dev/null || true
      log "[ok] default BFT URL saved to $config_path"
    else
      log "[info] existing BFT CLI config left unchanged at $config_path"
    fi
    """
  end

  defp configured_string(key) do
    case Application.get_env(:bridge_for_teams_web, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp dashboard_base_url(conn) do
    case configured_string(:public_base_url) do
      nil ->
        port_suffix =
          case {conn.scheme, conn.port} do
            {:http, 80} -> ""
            {:https, 443} -> ""
            {_scheme, port} -> ":#{port}"
          end

        "#{conn.scheme}://#{conn.host}#{port_suffix}"

      base ->
        String.trim_trailing(base, "/")
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp json_shell_string(value) do
    value
    |> Jason.encode!()
    |> shell_quote()
  end

  defp trim_script(script) do
    script
    |> String.trim()
    |> String.replace(~r/\n[ \t]+/, "\n")
    |> Kernel.<>("\n")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, Jason.encode!(body))
  end
end
