FROM docker.io/hexpm/elixir:1.20.1-erlang-29.0.2-debian-trixie-20260610-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates cmake pkg-config libuv1-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:${PATH}
WORKDIR /kernel
COPY lean-toolchain scripts/install-toolchain.sh ./
RUN bash install-toolchain.sh lean-toolchain
COPY . .
RUN mix test

FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 libssl3t64 libncurses6 libncursesw6 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/lib/erlang /usr/local/lib/erlang
ENV PATH=/usr/local/lib/erlang/bin:${PATH}
COPY --from=builder /kernel/priv/verified_kernel.so /app/lib/salix_verified_kernel/priv/verified_kernel.so
COPY --from=builder /kernel/priv/licenses /app/lib/salix_verified_kernel/priv/licenses
COPY --from=builder /kernel/_build/test/lib/salix_verified_kernel/ebin/Elixir.SalixVerifiedKernel.Native.beam /app/lib/salix_verified_kernel/ebin/
COPY --from=builder /kernel/_build/test/lib/salix_verified_kernel/ebin/Elixir.SalixVerifiedKernel.beam /app/lib/salix_verified_kernel/ebin/
COPY test/runtime_smoke.escript /app/runtime_smoke.escript
ENTRYPOINT ["escript", "/app/runtime_smoke.escript"]
