# The Comma station on an Agent VMM Host: a Group's Cloud VM when the Group's
# Cloud VM provider is agent_vmm. It carries the same station release as the
# Cloudflare Container (systems/station/scripts/bundle.sh, linux-arm64, its
# native parts built for glibc 2.28) and the locked Claude and Codex CLIs the
# station runs Tasks with. The `station` build context is that release.
#
# Shared tools serve the Shell and Station images. `comma-station` also serves
# the amd64 coding sandbox; `vmm-station` adds the meeting bot and browser.
# The `meetnative` context contains its locked source revision.
ARG GO_IMAGE=golang:1.26.10-bookworm
ARG STATION_IMAGE=node:24.22.1-bookworm-slim
# The Debian release of STATION_IMAGE (the coding sandbox builds this image on
# trixie: runtime-images/coding-sandbox/build.sh).
ARG DEBIAN_SUITE=bookworm

# The locked SILK v3 decoder, for the WeChat and QQ voice messages Tasks receive
# (ffmpeg has no SILK decoder); silk2wav wraps it.
FROM ${STATION_IMAGE} AS silk-build
ARG SILK_V3_DECODER_TARBALL
ARG SILK_V3_DECODER_INTEGRITY
RUN set -eu; \
    apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl g++ gcc make openssl \
    && curl --fail --location --silent --show-error "${SILK_V3_DECODER_TARBALL}" --output /tmp/silk.tgz \
    && printf '%s' "${SILK_V3_DECODER_INTEGRITY#sha512-}" | base64 --decode >/tmp/silk.expected \
    && openssl dgst -sha512 -binary /tmp/silk.tgz >/tmp/silk.actual && cmp /tmp/silk.expected /tmp/silk.actual \
    && mkdir /tmp/silk && tar -xzf /tmp/silk.tgz -C /tmp/silk --strip-components=1 \
    && make -C /tmp/silk/silk lib decoder \
    && install -D -m 0755 /tmp/silk/silk/decoder /out/silk-v3-decoder

FROM ${STATION_IMAGE} AS shared-tools

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
ARG PACKAGE_SNAPSHOT
ARG DEBIAN_SUITE
# Debian packages as of the locked snapshot (packageSnapshot in
# runtime-dependencies.lock.json), so a rebuild installs the same versions.
# npm has not yet released all fixed versions in its bundled dependency tree,
# so the locked tarballs below replace them.
RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    set -eu; \
    fetch() { curl --fail --location --silent --show-error "$1" --output "$2"; }; \
    verify() { printf '%s' "${2#sha512-}" | base64 --decode >"$1.expected" \
      && openssl dgst -sha512 -binary "$1" >"$1.actual" && cmp "$1.expected" "$1.actual"; }; \
    printf '%s\n' \
      'Types: deb' "URIs: http://snapshot.debian.org/archive/debian/${PACKAGE_SNAPSHOT}" \
      "Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates" 'Components: main' 'Check-Valid-Until: no' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' '' \
      'Types: deb' "URIs: http://snapshot.debian.org/archive/debian-security/${PACKAGE_SNAPSHOT}" \
      "Suites: ${DEBIAN_SUITE}-security" 'Components: main' 'Check-Valid-Until: no' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" upgrade -y \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends \
         bash ca-certificates curl wget git openssh-client openssl libpcre2-8-0 procps \
         python3 python3-pip python3-venv jq coreutils findutils ripgrep tar gzip zip unzip file ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && fetch "${NPM_TARBALL}" /tmp/npm.tgz && verify /tmp/npm.tgz "${NPM_INTEGRITY}" \
    && fetch "${NPM_BRACE_EXPANSION_TARBALL}" /tmp/npm-brace-expansion.tgz \
    && verify /tmp/npm-brace-expansion.tgz "${NPM_BRACE_EXPANSION_INTEGRITY}" \
    && fetch "${NPM_UNDICI_TARBALL}" /tmp/npm-undici.tgz && verify /tmp/npm-undici.tgz "${NPM_UNDICI_INTEGRITY}" \
    && fetch "${NPM_IP_ADDRESS_TARBALL}" /tmp/npm-ip-address.tgz \
    && verify /tmp/npm-ip-address.tgz "${NPM_IP_ADDRESS_INTEGRITY}" \
    && fetch "${NPM_TAR_TARBALL}" /tmp/npm-tar.tgz && verify /tmp/npm-tar.tgz "${NPM_TAR_INTEGRITY}" \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/npm.tgz \
    && test "$(npm --version)" = "${NPM_VERSION}" \
    && npm_modules=/usr/local/lib/node_modules/npm/node_modules \
    && for patch in undici brace-expansion ip-address tar; do \
         mkdir -p "/tmp/npm-$patch" \
         && tar -xzf "/tmp/npm-$patch.tgz" -C "/tmp/npm-$patch" --strip-components=1 \
         && rm -rf "$npm_modules/$patch" \
         && mv "/tmp/npm-$patch" "$npm_modules/$patch"; \
       done \
    && test "$(node -p "require('$npm_modules/brace-expansion/package.json').version")" = "${NPM_BRACE_EXPANSION_VERSION}" \
    && test "$(node -p "require('$npm_modules/ip-address/package.json').version")" = "${NPM_IP_ADDRESS_VERSION}" \
    && test "$(node -p "require('$npm_modules/tar/package.json').version")" = "${NPM_TAR_VERSION}" \
    && test "$(node -p "require('$npm_modules/undici/package.json').version")" = "${NPM_UNDICI_VERSION}" \
    && rm -rf /root/.npm /root/.claude /root/.claude.json \
              /tmp/npm-cache /tmp/node-compile-cache \
              /tmp/*.tgz /tmp/*.expected /tmp/*.actual

# Remove the bundle's duplicate Node before its files reach a final image layer.
# Desktop bundles retain their own Node; only these image targets use base Node.
FROM shared-tools AS station-bundle
COPY --from=station . /opt/comma-station
RUN rm -rf /opt/comma-station/node \
    && mkdir -p /opt/comma-station/node/bin \
    && ln -s /usr/local/bin/node /opt/comma-station/node/bin/node

FROM shared-tools AS comma-station
ARG CODEX_TARBALL
ARG CODEX_INTEGRITY
ARG CLAUDE_VERSION
ARG CLAUDE_TARBALL
ARG CLAUDE_INTEGRITY
ARG CLAUDE_PLATFORM_TARBALL
ARG CLAUDE_PLATFORM_INTEGRITY
ENV DISABLE_AUTOUPDATER=1
COPY systems/runtime-images/station/file-tools-packages systems/runtime-images/station/file-tools-requirements.txt /tmp/
RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    set -eu; \
    fetch() { curl --fail --location --silent --show-error "$1" --output "$2"; }; \
    verify() { printf '%s' "${2#sha512-}" | base64 --decode >"$1.expected" \
      && openssl dgst -sha512 -binary "$1" >"$1.actual" && cmp "$1.expected" "$1.actual"; }; \
    apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends $(cat /tmp/file-tools-packages) \
    && rm -rf /var/lib/apt/lists/* \
    && fetch "${CODEX_TARBALL}" /tmp/codex.tgz && verify /tmp/codex.tgz "${CODEX_INTEGRITY}" \
    && fetch "${CLAUDE_TARBALL}" /tmp/claude.tgz && verify /tmp/claude.tgz "${CLAUDE_INTEGRITY}" \
    && fetch "${CLAUDE_PLATFORM_TARBALL}" /tmp/claude-platform.tgz \
    && verify /tmp/claude-platform.tgz "${CLAUDE_PLATFORM_INTEGRITY}" \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/codex.tgz \
    && npm_config_cache=/tmp/npm-cache npm install --global --ignore-scripts --omit=optional /tmp/claude.tgz /tmp/claude-platform.tgz \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
    && codex --version \
    && rm -rf /root/.npm /root/.claude /root/.claude.json \
              /tmp/npm-cache /tmp/node-compile-cache \
              /tmp/*.tgz /tmp/*.expected /tmp/*.actual

RUN python3 -m pip install --break-system-packages --no-cache-dir --only-binary :all: --require-hashes \
      -r /tmp/file-tools-requirements.txt \
    && rm /tmp/file-tools-packages /tmp/file-tools-requirements.txt

COPY --from=station-bundle /opt/comma-station /opt/comma-station
COPY systems/runtime-images/station/entrypoint.sh /usr/local/bin/comma-station-entrypoint
COPY systems/runtime-images/station/initialize-access.mjs /usr/local/lib/comma-station-initialize-access.mjs
COPY --from=silk-build /out/silk-v3-decoder /usr/local/bin/silk-v3-decoder
COPY systems/runtime-images/station/silk2wav /usr/local/bin/silk2wav
RUN chmod 0755 /usr/local/bin/comma-station-entrypoint /usr/local/bin/silk2wav \
    && test -x /usr/local/bin/silk-v3-decoder \
    && /opt/comma-station/node/bin/node --version \
    && test -x /opt/comma-station/mesh/target/release/comma-station \
    && test -f /opt/comma-station/station/main.js \
    && install -d -o node -g node -m 0700 /workspace

ENV HOME=/workspace
WORKDIR /workspace
USER node
RUN test "$(id -u)" = "1000" \
    && test "$(id -g)" = "1000" \
    && test "$(stat -c '%u:%g:%a' /workspace)" = "1000:1000:700" \
    && test "$(claude --version | awk '{print $1}')" = "${CLAUDE_VERSION}" \
    && test ! -e /workspace/.claude \
    && test ! -e /workspace/.claude.json
ENTRYPOINT ["/usr/local/bin/comma-station-entrypoint"]

# meet-native, built as meetnative's own image builds it.
FROM ${GO_IMAGE} AS meetnative-build
COPY --from=meetnative / /src/meetnative
WORKDIR /src/meetnative
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -tags chrome_tokenfactory -ldflags='-s -w' -o /out/meet-native ./cmd/meet-native

FROM ${GO_IMAGE} AS shell-build
WORKDIR /src
COPY systems/runtime-images/go.mod ./go.mod
COPY systems/runtime-images/cmd/comma-shell-runtime ./cmd/comma-shell-runtime
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/comma-shell-runtime ./cmd/comma-shell-runtime

FROM shared-tools AS shell
RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends build-essential pkg-config pandoc python3-virtualenv python-is-python3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 runtime \
    && useradd --uid 10001 --gid runtime --home-dir /workspace --create-home runtime
COPY --from=shell-build /out/comma-shell-runtime /usr/local/bin/comma-shell-runtime
ENV HOME=/workspace \
    PYTHONUSERBASE=/workspace/.local \
    NPM_CONFIG_PREFIX=/workspace/.local \
    PATH=/workspace/.local/bin:$PATH
WORKDIR /workspace
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/comma-shell-runtime"]

# The VMM Station: meet-native and the browser and display it drives, as of the
# locked package snapshot; the entrypoint starts them beside the station.
FROM comma-station AS vmm-station
ARG PACKAGE_SNAPSHOT
ARG DEBIAN_SUITE
USER root
RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    set -eu; \
    apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends chromium ffmpeg xvfb \
    # CVE-2026-118333 and CVE-2026-118337: Chromium before 156.0.8078.73 has critical CVEs;
    # a package snapshot still serving an older build fails the build.
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' chromium)" ge 156.0.8078.73 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
COPY --from=meetnative-build /out/meet-native /usr/local/bin/meet-native
ENV CHROMIUM_BIN=/usr/bin/chromium \
    GIN_MODE=release \
    MEETNATIVE_LISTEN_ADDR=127.0.0.1:8081
USER node
