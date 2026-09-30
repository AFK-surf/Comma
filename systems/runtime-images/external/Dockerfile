ARG GO_IMAGE=golang:1.26.6-bookworm
ARG EXTERNAL_IMAGE=node:24.19.0-bookworm-slim
FROM ${GO_IMAGE} AS connector-builder

WORKDIR /src
COPY systems/connector/salix-connect/go.mod systems/connector/salix-connect/go.sum ./
RUN go mod download
COPY systems/connector/salix-connect/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/salix-runtime-agent .

FROM ${EXTERNAL_IMAGE}

ARG NPM_VERSION
ARG NPM_TARBALL
ARG NPM_INTEGRITY
ARG NPM_BRACE_EXPANSION_VERSION
ARG NPM_BRACE_EXPANSION_TARBALL
ARG NPM_BRACE_EXPANSION_INTEGRITY
ARG NPM_UNDICI_VERSION
ARG NPM_UNDICI_TARBALL
ARG NPM_UNDICI_INTEGRITY
ARG NPM_IP_ADDRESS_VERSION
ARG NPM_IP_ADDRESS_TARBALL
ARG NPM_IP_ADDRESS_INTEGRITY
ARG NPM_TAR_VERSION
ARG NPM_TAR_TARBALL
ARG NPM_TAR_INTEGRITY
ARG CODEX_TARBALL
ARG CODEX_INTEGRITY
ARG CLAUDE_VERSION
ARG CLAUDE_TARBALL
ARG CLAUDE_INTEGRITY
ARG CLAUDE_PLATFORM_TARBALL
ARG CLAUDE_PLATFORM_INTEGRITY
ARG PI_TARBALL
ARG PI_INTEGRITY
ENV DISABLE_AUTOUPDATER=1

# npm has not yet released all fixed versions in its bundled dependency tree,
# so the locked tarballs below replace them.
RUN set -eu; \
    apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --location --silent --show-error "${NPM_TARBALL}" --output /tmp/npm.tgz \
    && curl --fail --location --silent --show-error "${NPM_BRACE_EXPANSION_TARBALL}" --output /tmp/npm-brace-expansion.tgz \
    && curl --fail --location --silent --show-error "${NPM_UNDICI_TARBALL}" --output /tmp/npm-undici.tgz \
    && curl --fail --location --silent --show-error "${NPM_IP_ADDRESS_TARBALL}" --output /tmp/npm-ip-address.tgz \
    && curl --fail --location --silent --show-error "${NPM_TAR_TARBALL}" --output /tmp/npm-tar.tgz \
    && curl --fail --location --silent --show-error "${CODEX_TARBALL}" --output /tmp/codex.tgz \
    && curl --fail --location --silent --show-error "${CLAUDE_TARBALL}" --output /tmp/claude.tgz \
    && curl --fail --location --silent --show-error "${CLAUDE_PLATFORM_TARBALL}" --output /tmp/claude-platform.tgz \
    && curl --fail --location --silent --show-error "${PI_TARBALL}" --output /tmp/pi.tgz \
    && printf '%s' "${NPM_INTEGRITY#sha512-}" | base64 --decode >/tmp/npm.expected \
    && openssl dgst -sha512 -binary /tmp/npm.tgz >/tmp/npm.actual \
    && cmp /tmp/npm.expected /tmp/npm.actual \
    && printf '%s' "${NPM_BRACE_EXPANSION_INTEGRITY#sha512-}" | base64 --decode >/tmp/npm-brace-expansion.expected \
    && openssl dgst -sha512 -binary /tmp/npm-brace-expansion.tgz >/tmp/npm-brace-expansion.actual \
    && cmp /tmp/npm-brace-expansion.expected /tmp/npm-brace-expansion.actual \
    && printf '%s' "${NPM_UNDICI_INTEGRITY#sha512-}" | base64 --decode >/tmp/npm-undici.expected \
    && openssl dgst -sha512 -binary /tmp/npm-undici.tgz >/tmp/npm-undici.actual \
    && cmp /tmp/npm-undici.expected /tmp/npm-undici.actual \
    && printf '%s' "${NPM_IP_ADDRESS_INTEGRITY#sha512-}" | base64 --decode >/tmp/npm-ip-address.expected \
    && openssl dgst -sha512 -binary /tmp/npm-ip-address.tgz >/tmp/npm-ip-address.actual \
    && cmp /tmp/npm-ip-address.expected /tmp/npm-ip-address.actual \
    && printf '%s' "${NPM_TAR_INTEGRITY#sha512-}" | base64 --decode >/tmp/npm-tar.expected \
    && openssl dgst -sha512 -binary /tmp/npm-tar.tgz >/tmp/npm-tar.actual \
    && cmp /tmp/npm-tar.expected /tmp/npm-tar.actual \
    && printf '%s' "${CODEX_INTEGRITY#sha512-}" | base64 --decode >/tmp/codex.expected \
    && openssl dgst -sha512 -binary /tmp/codex.tgz >/tmp/codex.actual \
    && cmp /tmp/codex.expected /tmp/codex.actual \
    && printf '%s' "${CLAUDE_INTEGRITY#sha512-}" | base64 --decode >/tmp/claude.expected \
    && openssl dgst -sha512 -binary /tmp/claude.tgz >/tmp/claude.actual \
    && cmp /tmp/claude.expected /tmp/claude.actual \
    && printf '%s' "${CLAUDE_PLATFORM_INTEGRITY#sha512-}" | base64 --decode >/tmp/claude-platform.expected \
    && openssl dgst -sha512 -binary /tmp/claude-platform.tgz >/tmp/claude-platform.actual \
    && cmp /tmp/claude-platform.expected /tmp/claude-platform.actual \
    && printf '%s' "${PI_INTEGRITY#sha512-}" | base64 --decode >/tmp/pi.expected \
    && openssl dgst -sha512 -binary /tmp/pi.tgz >/tmp/pi.actual \
    && cmp /tmp/pi.expected /tmp/pi.actual \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/npm.tgz \
    && test "$(npm --version)" = "${NPM_VERSION}" \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/codex.tgz /tmp/pi.tgz \
    && npm_config_cache=/tmp/npm-cache npm install --global --ignore-scripts --omit=optional /tmp/claude.tgz /tmp/claude-platform.tgz \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
    && mkdir -p /tmp/npm-undici /tmp/npm-brace-expansion /tmp/npm-ip-address /tmp/npm-tar \
    && tar -xzf /tmp/npm-undici.tgz -C /tmp/npm-undici --strip-components=1 \
    && tar -xzf /tmp/npm-brace-expansion.tgz -C /tmp/npm-brace-expansion --strip-components=1 \
    && tar -xzf /tmp/npm-ip-address.tgz -C /tmp/npm-ip-address --strip-components=1 \
    && tar -xzf /tmp/npm-tar.tgz -C /tmp/npm-tar --strip-components=1 \
    && rm -rf /usr/local/lib/node_modules/npm/node_modules/undici \
              /usr/local/lib/node_modules/npm/node_modules/brace-expansion \
              /usr/local/lib/node_modules/npm/node_modules/ip-address \
              /usr/local/lib/node_modules/npm/node_modules/tar \
    && mv /tmp/npm-undici /usr/local/lib/node_modules/npm/node_modules/undici \
    && mv /tmp/npm-brace-expansion /usr/local/lib/node_modules/npm/node_modules/brace-expansion \
    && mv /tmp/npm-ip-address /usr/local/lib/node_modules/npm/node_modules/ip-address \
    && mv /tmp/npm-tar /usr/local/lib/node_modules/npm/node_modules/tar \
    && test "$(node -p "require('/usr/local/lib/node_modules/npm/node_modules/brace-expansion/package.json').version")" = "${NPM_BRACE_EXPANSION_VERSION}" \
    && test "$(node -p "require('/usr/local/lib/node_modules/npm/node_modules/ip-address/package.json').version")" = "${NPM_IP_ADDRESS_VERSION}" \
    && test "$(node -p "require('/usr/local/lib/node_modules/npm/node_modules/tar/package.json').version")" = "${NPM_TAR_VERSION}" \
    && test "$(node -p "require('/usr/local/lib/node_modules/npm/node_modules/undici/package.json').version")" = "${NPM_UNDICI_VERSION}" \
    && codex --version \
    && pi --version \
    && rm -rf /root/.npm /root/.claude /root/.claude.json \
              /tmp/npm-cache /tmp/node-compile-cache \
              /tmp/*.tgz /tmp/*.expected /tmp/*.actual

COPY --from=connector-builder /out/salix-runtime-agent /usr/local/bin/salix-runtime-agent
RUN install -d -o node -g node -m 0700 /workspace

ENV HOME=/workspace
WORKDIR /workspace
USER node
RUN test "$(id -u)" = "1000" \
    && test "$(id -g)" = "1000" \
    && test "${HOME}" = "/workspace" \
    && test "$(pwd)" = "/workspace" \
    && test "$(stat -c '%u:%g:%a' /workspace)" = "1000:1000:700" \
    && test "$(claude --version | awk '{print $1}')" = "${CLAUDE_VERSION}" \
    && test ! -e /workspace/.claude \
    && test ! -e /workspace/.claude.json
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/salix-runtime-agent", "--runtime-agent"]
