defmodule SalixWeb.CloudVM.RuntimeInstall do
  @moduledoc "Locked native runtime preparation on the Group VM."

  @lock_path Path.expand("../../../../../runtime-images/runtime-dependencies.lock.json", __DIR__)
  @external_resource @lock_path
  @lock Jason.decode!(File.read!(@lock_path))

  def install(%{"provider" => "cloudflare"} = rec, id, provider, opts) do
    timeout = Keyword.get(opts, :runtime_install_timeout_ms, 240_000)

    with {:ok, %{"status" => "connected", "connector_run_id" => run}} <-
           SalixEnv.Registry.get_device(rec["tenant_id"], rec["group_id"], rec["device_id"]),
         {:ok, %{"exit_code" => code}} <-
           SalixEnv.Connector.Live.request(
             run,
             "exec",
             %{"command" => script(id, provider), "timeout" => div(timeout + 999, 1_000)},
             timeout: timeout + 1_000
           ) do
      case code do
        0 -> :ok
        65 -> {:error, :runtime_node_required}
        _ -> {:error, :runtime_install_failed}
      end
    else
      _ -> {:error, :runtime_install_failed}
    end
  end

  def script(id, provider) when provider in ~w(codex claude) do
    if not valid_id?(id), do: raise(ArgumentError, "invalid runtime request id")
    package = @lock[provider]["package"]
    version = @lock[provider]["version"]
    command = if provider == "claude", do: "claude", else: "codex"

    """
    set -eu
    umask 077
    base="${SALIX_MANAGED_RUNTIME_ROOT%/runtimes}"
    if [ -z "$base" ]; then base="$HOME/.local/share/salix"; fi
    mkdir -p "$base/packages" "$base/runtimes"
    exec 9>"$base/runtime-install.lock"
    flock -w 180 9
    command -v npm >/dev/null 2>&1 || exit 65
    node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' || exit 65
    package_dir="$base/packages/#{provider}-#{version}"
    if [ ! -x "$package_dir/node_modules/.bin/#{command}" ]; then
      staging=$(mktemp -d "$base/packages/install.XXXXXXXX")
      trap 'rm -rf "$staging"' EXIT
      DISABLE_AUTOUPDATER=1 npm install --prefix "$staging" --no-audit --no-fund -- '#{package}@#{version}' >&2
      #{if provider == "claude", do: "node \"$staging/node_modules/@anthropic-ai/claude-code/install.cjs\" >&2", else: ""}
      "$staging/node_modules/.bin/#{command}" --version >&2
      mv "$staging" "$package_dir"
      trap - EXIT
    fi
    target="$base/runtimes/#{id}"
    mkdir -p "$target/bin"
    cat > "$target/bin/#{command}.new" <<EOF
    #!/bin/sh
    export DISABLE_AUTOUPDATER=1
    exec "$package_dir/node_modules/.bin/#{command}" "\\$@"
    EOF
    chmod 700 "$target/bin/#{command}.new"
    mv "$target/bin/#{command}.new" "$target/bin/#{command}"
    """
  end

  def valid_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, id)
end
