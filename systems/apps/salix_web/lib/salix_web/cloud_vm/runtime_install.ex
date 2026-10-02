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
    cache="$base/packages/#{provider}-#{version}.current"
    usable_package() {
      [ -x "$1/node_modules/.bin/#{command}" ] && "$1/node_modules/.bin/#{command}" --version >&2
    }
    if ! usable_package "$package_dir"; then
      cached=$(node -e 'try { process.stdout.write(require("fs").realpathSync(process.argv[1])) } catch (_) {}' "$cache")
      if [ -n "$cached" ] && usable_package "$cached"; then
        package_dir="$cached"
      else
        staging=$(mktemp -d "$base/packages/#{provider}-#{version}.XXXXXXXX")
        cache_link=""
        trap 'rm -rf "$staging"; if [ -n "$cache_link" ]; then rm -f "$cache_link"; fi' EXIT
        DISABLE_AUTOUPDATER=1 npm install --prefix "$staging" --no-audit --no-fund -- '#{package}@#{version}' >&2
        #{if provider == "claude", do: "node \"$staging/node_modules/@anthropic-ai/claude-code/install.cjs\" >&2", else: ""}
        "$staging/node_modules/.bin/#{command}" --version >&2
        # Keep old paths available to independently running native processes.
        # The cache points to a package. Each wrapper retains its exact path.
        cache_link=$(mktemp "$base/packages/.current.XXXXXXXX")
        rm -f "$cache_link"
        ln -s "$staging" "$cache_link"
        # A published package must survive any later wrapper failure.
        trap 'rm -f "$cache_link"' EXIT
        node -e 'require("fs").renameSync(process.argv[1], process.argv[2])' "$cache_link" "$cache"
        package_dir="$staging"
        trap - EXIT
      fi
    fi
    target="$base/runtimes/#{id}"
    mkdir -p "$target/bin"
    cat > "$target/bin/#{command}.new" <<EOF
    #!/bin/sh
    export DISABLE_AUTOUPDATER=1
    exec "$package_dir/node_modules/.bin/#{command}" "\\$@"
    EOF
    chmod 700 "$target/bin/#{command}.new"
    node -e 'require("fs").renameSync(process.argv[1], process.argv[2])' "$target/bin/#{command}.new" "$target/bin/#{command}"
    """
  end

  def valid_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, id)
end
