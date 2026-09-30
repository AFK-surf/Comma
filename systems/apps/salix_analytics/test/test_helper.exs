# :clickhouse tests need a live ClickHouse at 127.0.0.1:8123; opt in with
# `mix test --include clickhouse`.
#
# Local container shape used for this suite. Use `latest`, which is what
# systems-ci.yml runs: pinning locally hides forward-compatibility breaks that
# CI then finds. One has already happened — a `SELECT * REPLACE(...)` whose
# alias shadowed a same-level WHERE behaved differently on 24.8 and 26.8, and
# the 24.8 run passed a migration that resurrected deleted messages.
#   docker run -d --rm --name comma-clickhouse-test -p 8123:8123 \
#     -e CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server:latest
#
# Existing local debt: `typed_usage_test.exs` may fail when run by itself if Req
# has not been started; run it through the app/umbrella test command until that
# startup dependency is cleaned up.
ExUnit.start(exclude: [:clickhouse, :live_semantic_gpu])
