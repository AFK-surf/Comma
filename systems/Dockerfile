# Comma systems — one image and one `comma` umbrella release containing every
# subsystem. Each pod starts only the subset selected by `COMMA_SUBSYSTEMS`.
# The built-in Docker healthcheck below targets Salix; deployments that omit
# Salix must override it with the selected subsystem's health endpoint.
#
# Stage 1 builds the OTP release; stage 2 is the slim runtime. Build from the
# systems/ repository root:
#
#   docker build -f systems/Dockerfile -t comma .
#
# See DEPLOYMENT.md for required environment and topology.

# ---- Cloud SQL Proxy builder -----------------------------------------------
# Build the official proxy v2.25.4 from its pinned release commit with a patched
# Go toolchain. This release contains the reviewed upstream dependency updates
# for gRPC 1.83.2 and golang.org/x/crypto 0.55.0.
FROM golang:1.26.6-trixie AS cloud-sql-proxy-builder

ARG CLOUD_SQL_PROXY_VERSION=7905bdd628cd80cfb15714a7197f5bbd4a49d844
RUN GOBIN=/out CGO_ENABLED=0 go install \
      github.com/GoogleCloudPlatform/cloud-sql-proxy/v2@${CLOUD_SQL_PROXY_VERSION}

# ---- Subscription worker builder ------------------------------------------
FROM golang:1.26.6-trixie AS subscription-worker-builder
WORKDIR /src
COPY systems/account-proxy/go.mod systems/account-proxy/go.sum systems/account-proxy/bootstrap.sh ./
COPY systems/account-proxy/patches ./patches
RUN ./bootstrap.sh && go mod download
COPY systems/account-proxy/*.go ./
COPY systems/account-proxy/cmd ./cmd
RUN CGO_ENABLED=0 go build -trimpath -o /subscription_worker ./cmd/salix-account-proxy

# ---- Tailcat gateway builder ----------------------------------------------
# One process per Salix node for outbound SSH over Tailcat
# (SalixAgent.Tailcat.Gateway). Only the gateway command ships; the test peer
# stays out of the image.
FROM golang:1.27.1-trixie AS tailcat-gateway-builder
WORKDIR /src
COPY systems/tailcat-gateway/go.mod systems/tailcat-gateway/go.sum ./
RUN go mod download
COPY systems/tailcat-gateway/*.go ./
COPY systems/tailcat-gateway/cmd/salix-tailcat-gateway ./cmd/salix-tailcat-gateway
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /tailcat_gateway ./cmd/salix-tailcat-gateway

# ---- spinfoam fetcher -------------------------------------------------------
# The userspace eBPF runtime behind Agent background Loops
# (docs/salix/task-dynamic-workflow.md). The prebuilt release pinned in
# systems/native/spinfoam/SPINFOAM_VERSION is downloaded and verified against
# the pinned SHA256SUMS; the Elixir stage bundles the binary into
# salix_agent's priv/ exactly like the subscription worker. The binary embeds
# its C compiler, so no toolchain is involved at any stage.
FROM debian:trixie-slim AS spinfoam-fetcher
RUN apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY systems/native/spinfoam/SPINFOAM_VERSION systems/native/spinfoam/SHA256SUMS systems/native/spinfoam/fetch.sh ./native/spinfoam/
RUN ./native/spinfoam/fetch.sh OUT=/out/spinfoam

# ---- Stage 1: Elixir release builder -------------------------------------
FROM hexpm/elixir:1.20.1-erlang-29.0.2-debian-trixie-20260610-slim AS elixir-builder

ARG COMMA_LOCAL_RECOMMENDATION_MOCK=false

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates nodejs npm curl cmake pkg-config libuv1-dev libssl-dev \
      libsodium-dev libopus-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Lean is a build dependency. The runtime image receives only the static NIF.
ENV ELAN_HOME=/opt/elan
ENV PATH="/opt/elan/bin:${PATH}"
COPY systems/native/verified_kernel/lean-toolchain /tmp/lean-toolchain
COPY systems/native/verified_kernel/scripts/install-toolchain.sh /tmp/install-lean-toolchain.sh
RUN bash /tmp/install-lean-toolchain.sh /tmp/lean-toolchain

RUN mix local.hex --force && mix local.rebar --force

# Delay the capability input until after the OS/toolchain layer so toggling a
# local-only compile feature does not invalidate package installation.
ENV COMMA_LOCAL_RECOMMENDATION_MOCK=${COMMA_LOCAL_RECOMMENDATION_MOCK}

# Dependency layer (cached on mix.lock + per-app mix.exs).
COPY systems/mix.exs systems/mix.lock ./
COPY systems/apps/alert_router/mix.exs apps/alert_router/
COPY systems/apps/comma/mix.exs apps/comma/
COPY systems/apps/comma_log/mix.exs apps/comma_log/
COPY systems/apps/comma_ssh/mix.exs apps/comma_ssh/
COPY systems/apps/comma_tui/mix.exs apps/comma_tui/
COPY systems/apps/systems_observability/mix.exs apps/systems_observability/
COPY systems/apps/billing_core/mix.exs apps/billing_core/
COPY systems/apps/billing_commerce/mix.exs apps/billing_commerce/
COPY systems/apps/billing_stripe/mix.exs apps/billing_stripe/
COPY systems/apps/comma_core/mix.exs apps/comma_core/
COPY systems/apps/comma_web/mix.exs apps/comma_web/
COPY systems/apps/salix_store/mix.exs apps/salix_store/
COPY systems/apps/salix_calendar/mix.exs apps/salix_calendar/
COPY systems/apps/salix_agent/mix.exs apps/salix_agent/
COPY systems/apps/salix_ifc/mix.exs apps/salix_ifc/
COPY systems/apps/salix_cluster/mix.exs apps/salix_cluster/
COPY systems/apps/salix_web/mix.exs apps/salix_web/
COPY systems/apps/salix_llm/mix.exs apps/salix_llm/
COPY systems/apps/salix_im/mix.exs apps/salix_im/
COPY systems/apps/salix_env/mix.exs apps/salix_env/
COPY systems/apps/salix_analytics/mix.exs apps/salix_analytics/
COPY systems/apps/salix_migrate/mix.exs apps/salix_migrate/
COPY systems/apps/salix_media/mix.exs apps/salix_media/
COPY systems/apps/salix_meet/mix.exs apps/salix_meet/
COPY systems/apps/salix_voice/mix.exs apps/salix_voice/
COPY systems/apps/salix_signal/mix.exs apps/salix_signal/
COPY systems/apps/salix_signal_proto/mix.exs apps/salix_signal_proto/
COPY systems/apps/salix_mcp/mix.exs apps/salix_mcp/
COPY systems/apps/bridge_for_teams_core/mix.exs apps/bridge_for_teams_core/
COPY systems/apps/bridge_for_teams_web/mix.exs apps/bridge_for_teams_web/
COPY systems/config/config.exs config/
# Compile-time inputs that umbrella apps read while compiling — must be present
# BEFORE deps.compile (umbrella apps compile as path deps there), not just
# before the later `mix compile`:
#   * native/ — the verified kernel path dependency and the spinfoam fetch
#     script (`apps/salix_agent`'s `:spinfoam` compiler is a no-op here
#     because the fetch stage supplies the binary).
#   * salix_signal_proto's Makefile and C sources — its libsodium NIF builds
#     whenever the app compiles, including as an in-umbrella dependency.
#     salix_signal's libopus NIF (call media) likewise.
COPY systems/native native
COPY systems/apps/salix_signal_proto/Makefile apps/salix_signal_proto/Makefile
COPY systems/apps/salix_signal_proto/c_src apps/salix_signal_proto/c_src
COPY systems/apps/salix_signal/Makefile apps/salix_signal/Makefile
COPY systems/apps/salix_signal/c_src apps/salix_signal/c_src
COPY systems/connector/mac-mini-provisioner-install.sh connector/mac-mini-provisioner-install.sh
COPY systems/runtime-images/runtime-dependencies.lock.json runtime-images/runtime-dependencies.lock.json
RUN mix deps.get --only prod && mix deps.compile

# Source + release.
COPY systems/config config
COPY systems/apps apps
COPY --from=subscription-worker-builder /subscription_worker apps/salix_agent/priv/subscription_worker
COPY --from=tailcat-gateway-builder /tailcat_gateway apps/salix_agent/priv/tailcat_gateway
COPY --from=spinfoam-fetcher /out/spinfoam apps/salix_agent/priv/spinfoam
# CommaWeb.RecommendationRuntime embeds the versioned recommendation template
# catalog at compile time. Keep the repository-level catalog as the SSOT and
# make that external resource available at the same absolute path produced by
# its source-tree-relative lookup inside this builder (`/resources/...`).
COPY resources/salix-system-files/recommendation-template-catalog.v1.json /resources/salix-system-files/recommendation-template-catalog.v1.json
# ProactiveWatch embeds the Skill's Loop program from the same resource root.
COPY resources/salix-system-files/skills/proactive/scripts/watch.c /resources/salix-system-files/skills/proactive/scripts/watch.c
# Build the bridge_for_teams dashboard assets (standalone tailwind+esbuild Hex
# installers download their binaries here) into priv/static before the release,
# which bundles each app's priv/. Harmless when the subsystem isn't run.
RUN mix assets.setup && mix assets.deploy
RUN mix compile && mix release comma

# ---- Stage 2: runtime ------------------------------------------------------
# MUST track the builder's Debian release. mdex_native ships a precompiled NIF
# that requires a newer glibc than bullseye provides, and OTP's crypto NIF must
# see the same OpenSSL ABI it linked against during release compilation.
FROM debian:trixie-slim AS runtime

# libssl3t64 provides libcrypto.so.3 (required by the crypto NIF — see above).
# Trixie ships OpenSSL 3.5, which gives `:crypto` ML-KEM.
# libsodium23 is the shared library behind the salix_signal_proto NIF.
# libopus0 is the shared library behind the salix_signal Opus NIF (call media).
# spinfoam (Agent background Loops) embeds its own C compiler, so the
# runtime image carries no toolchain for it (DEPLOYMENT.md, "Background Loops").
ARG RUNTIME_APT_REFRESH=local
RUN echo "${RUNTIME_APT_REFRESH}" >/dev/null \
    && apt-get update -y && apt-get install -y --no-install-recommends \
      libstdc++6 libssl3t64 libsodium23 libopus0 openssl libpcre2-8-0 ca-certificates curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cloud-sql-proxy-builder /out/cloud-sql-proxy /usr/local/bin/cloud-sql-proxy

# Non-root runtime identity. Keep the UID/GID explicit because the same image is
# also used by Kubernetes sidecars whose runAsNonRoot policy cannot validate a
# named USER before the container starts.
RUN groupadd --gid 10001 comma \
    && useradd --uid 10001 --gid 10001 --create-home --home-dir /opt/comma comma
WORKDIR /opt/comma
USER 10001:10001

COPY --from=elixir-builder --chown=comma /app/_build/prod/rel/comma ./
COPY --chown=comma resources/salix-system-files /etc/salix-system

ARG SALIX_APP_REVISION=unknown

ENV SALIX_APP_REVISION=${SALIX_APP_REVISION} \
    ALERT_ROUTER_PORT=4300 \
    SALIX_HTTP_PORT=4000 \
    SALIX_TRANSFER_PORT=4400 \
    BRIDGE_DASHBOARD_HTTP_PORT=4101 \
    LANG=C.UTF-8

# Alert Router ingress, Salix HTTP/SSE, Salix transfer, BridgeForTeams
# dashboard, EPMD, BEAM distribution (pin a range in your orchestrator; see
# DEPLOYMENT.md).
EXPOSE 4300 4000 4400 4101 4369 9100-9110

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s \
  CMD curl -sf http://127.0.0.1:${SALIX_HTTP_PORT}/health || exit 1

# `start` runs in the foreground. This image-level healthcheck targets Salix on
# `SALIX_HTTP_PORT`; non-Salix deployments must replace it. On Salix pods, the
# deployment pre-stop hook calls bin/comma rpc
# "SalixCluster.Drain.drain([])" before SIGTERM.
ENTRYPOINT ["bin/comma"]
CMD ["start"]

# Production releases carry the complete Agent VMM runtime bundle. Local
# compose targets the runtime stage above so ordinary backend development does
# not build browser and agent images that it cannot consume.
FROM runtime AS release
COPY --chown=comma systems/runtime-images/dist/manifest.json /opt/comma/runtime-images/manifest.json
COPY --chown=comma systems/install-artifacts/release-descriptor.json /opt/comma/install-artifacts/release-descriptor.json
