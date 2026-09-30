#!/usr/bin/env bash
set -euo pipefail
prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../../.." && pwd)"
container_name="comma-proactive-prototype-pg"
redis_name="comma-proactive-prototype-redis"

# This named container and database belong only to this throwaway prototype.
if ! docker inspect "$container_name" >/dev/null 2>&1; then
  docker run -d --name "$container_name" --label comma.prototype=proactive-chat \
    -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
fi
docker start "$container_name" >/dev/null
prototype_port="$(docker port "$container_name" 5432/tcp | awk -F: '{print $NF}')"
for attempt in {1..30}; do
  if docker exec "$container_name" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
if [[ "$(docker exec "$container_name" psql -U postgres -Atc "SELECT 1 FROM pg_database WHERE datname = 'proactive_chat_prototype'")" != 1 ]]; then
  docker exec "$container_name" createdb -U postgres proactive_chat_prototype
fi
export MIX_ENV=test SALIX_TEST_DB=proactive_chat_prototype SALIX_TEST_DB_PORT="$prototype_port"
if ! docker inspect "$redis_name" >/dev/null 2>&1; then
  docker run -d --name "$redis_name" --label comma.prototype=proactive-chat \
    -p 127.0.0.1::6379 redis:7-alpine >/dev/null
fi
docker start "$redis_name" >/dev/null
redis_port="$(docker port "$redis_name" 6379/tcp | awk -F: '{print $NF}')"
export REDIS_TEST_URL="redis://127.0.0.1:$redis_port/0"
if [[ "$(uname -s)" == Darwin ]]; then
  export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
  export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
fi
if ! command -v lake >/dev/null 2>&1 && [[ -d "$HOME/.cache/comma-toolchains/lean-4.33.1-darwin_aarch64/bin" ]]; then
  export PATH="$HOME/.cache/comma-toolchains/lean-4.33.1-darwin_aarch64/bin:$PATH"
fi
cd "$repo_root/systems"
exec mix run --no-start scripts/proactive-chat-prototype/run.exs "$@"
