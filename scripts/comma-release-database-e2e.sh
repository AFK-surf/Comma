#!/usr/bin/env bash
set -euo pipefail

postgres_container="comma-release-postgres-e2e-${PPID}"
clickhouse_container="comma-release-clickhouse-e2e-${PPID}"

cleanup() {
  docker rm -f "${postgres_container}" "${clickhouse_container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --name "${postgres_container}" \
  --env POSTGRES_PASSWORD=postgres \
  --publish 127.0.0.1::5432 \
  postgres:16-alpine >/dev/null
docker run --detach --name "${clickhouse_container}" \
  --env CLICKHOUSE_SKIP_USER_SETUP=1 \
  --publish 127.0.0.1::8123 \
  clickhouse/clickhouse-server:24.8-alpine >/dev/null

postgres_endpoint=$(docker port "${postgres_container}" 5432/tcp)
clickhouse_endpoint=$(docker port "${clickhouse_container}" 8123/tcp)
postgres_port=${postgres_endpoint##*:}
clickhouse_url="http://${clickhouse_endpoint}"

for _ in $(seq 1 60); do
  if docker exec "${postgres_container}" pg_isready -U postgres >/dev/null 2>&1 && \
      curl --fail --silent --show-error "${clickhouse_url}/?query=SELECT%201" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec "${postgres_container}" pg_isready -U postgres >/dev/null
curl --fail --silent --show-error "${clickhouse_url}/?query=SELECT%201" >/dev/null
docker exec "${postgres_container}" createdb -U postgres billing_core_test
docker exec "${postgres_container}" createdb -U postgres comma_core_test
docker exec "${postgres_container}" createdb -U postgres bridge_for_teams_test

BILLING_TEST_DB_PORT="${postgres_port}" \
  COMMA_TEST_DB_PORT="${postgres_port}" \
  BRIDGE_TEST_DB_PORT="${postgres_port}" \
  RELEASE_E2E_CLICKHOUSE_URL="${clickhouse_url}" \
  sh -c 'cd systems && mix test apps/comma/test/release_adapter_e2e_test.exs --include release_controller_e2e'
