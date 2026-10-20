# Runs the NIF that scripts/check-runtime.sh built on the host in an image
# without Lean: build it there first. Only Erlang comes from the builder image.
FROM docker.io/hexpm/elixir:1.20.1-erlang-29.0.2-debian-trixie-20260610-slim AS erlang

FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 libssl3t64 libncurses6 libncursesw6 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=erlang /usr/local/lib/erlang /usr/local/lib/erlang
ENV PATH=/usr/local/lib/erlang/bin:${PATH}
COPY priv/verified_kernel.so /app/lib/salix_verified_kernel/priv/verified_kernel.so
COPY priv/licenses /app/lib/salix_verified_kernel/priv/licenses
COPY _build/test/lib/salix_verified_kernel/ebin /app/lib/salix_verified_kernel/ebin
COPY test/runtime_smoke.escript /app/runtime_smoke.escript
ENTRYPOINT ["escript", "/app/runtime_smoke.escript"]
