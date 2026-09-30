#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=/workspace/Comma
ready_marker=/var/lib/comma-dev/seed-ready

cd "${repository_root}/systems"
rm -f "${ready_marker}"

# Retain this key with the local database. Subscription credentials use it at rest.
if [[ -z "${SALIX_SUBSCRIPTION_STORAGE_KEY:-}" ]]; then
  subscription_key_file=/var/lib/comma-dev/subscription-storage-key
  if [[ ! -f "${subscription_key_file}" ]]; then
    node -e 'require("node:fs").writeFileSync(process.argv[1], require("node:crypto").randomBytes(32).toString("base64"), {mode: 0o600, flag: "wx"})' "${subscription_key_file}"
  fi
  export SALIX_SUBSCRIPTION_STORAGE_KEY="$(cat "${subscription_key_file}")"
fi

mix deps.get
mix compile

COMMA_RELEASE_JOB=1 mix run --no-start "${repository_root}/systems/devcontainer/bootstrap.exs"

mix run --no-start --eval '
  case Application.ensure_all_started(:comma) do
    {:ok, _started} -> Process.sleep(:infinity)
    {:error, reason} -> raise "Comma dev container failed to start: #{inspect(reason)}"
  end
' &
backend_pid=$!

terminate_backend() {
  kill -TERM "${backend_pid}" 2>/dev/null || true
  wait "${backend_pid}" 2>/dev/null || true
}
trap terminate_backend EXIT INT TERM

for _attempt in $(seq 1 120); do
  if ! kill -0 "${backend_pid}" 2>/dev/null; then
    wait "${backend_pid}"
  fi

  if curl -fsS http://127.0.0.1:4000/health >/dev/null \
    && curl -fsS http://127.0.0.1:4200/health >/dev/null; then
    break
  fi

  sleep 1
done

curl -fsS http://127.0.0.1:4000/health >/dev/null
curl -fsS http://127.0.0.1:4200/health >/dev/null

if [[ "${COMMA_DEV_AUTO_SEED:-true}" == true ]]; then
  node "${repository_root}/systems/scripts/comma-local-dev-seed.mjs"
fi

touch "${ready_marker}"
echo "Comma dev container is ready: API http://127.0.0.1:4200"

trap - EXIT
wait "${backend_pid}"
