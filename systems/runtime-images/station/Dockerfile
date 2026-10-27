# The Comma station on an Agent VMM Host: a Group's Cloud VM when the Group's
# Cloud VM provider is agent_vmm. It carries the same station release as the
# Cloudflare Container (systems/station/scripts/bundle.sh, linux-arm64, its
# native parts built for glibc 2.28) and the locked Claude and Codex CLIs the
# station runs Tasks with. The `station` build context is that release.
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

FROM ${STATION_IMAGE}

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
ARG PACKAGE_SNAPSHOT
ARG DEBIAN_SUITE
ENV DISABLE_AUTOUPDATER=1

# The tools Tasks use to read what people send them (video, audio, PDF, archives,
# Office files, CJK text), so they need not install them in a disposable VM.
COPY systems/runtime-images/station/file-tools-packages systems/runtime-images/station/file-tools-requirements.txt /tmp/

# Debian packages as of the locked snapshot (packageSnapshot in
# runtime-dependencies.lock.json), so a rebuild installs the same versions.
# npm has not yet released all fixed versions in its bundled dependency tree,
# so the locked tarballs below replace them.
RUN set -eu; \
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
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client libpcre2-8-0 procps \
    && apt-get install -y --no-install-recommends $(cat /tmp/file-tools-packages) python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && fetch "${NPM_TARBALL}" /tmp/npm.tgz && verify /tmp/npm.tgz "${NPM_INTEGRITY}" \
    && fetch "${NPM_BRACE_EXPANSION_TARBALL}" /tmp/npm-brace-expansion.tgz \
    && verify /tmp/npm-brace-expansion.tgz "${NPM_BRACE_EXPANSION_INTEGRITY}" \
    && fetch "${NPM_UNDICI_TARBALL}" /tmp/npm-undici.tgz && verify /tmp/npm-undici.tgz "${NPM_UNDICI_INTEGRITY}" \
    && fetch "${NPM_IP_ADDRESS_TARBALL}" /tmp/npm-ip-address.tgz \
    && verify /tmp/npm-ip-address.tgz "${NPM_IP_ADDRESS_INTEGRITY}" \
    && fetch "${NPM_TAR_TARBALL}" /tmp/npm-tar.tgz && verify /tmp/npm-tar.tgz "${NPM_TAR_INTEGRITY}" \
    && fetch "${CODEX_TARBALL}" /tmp/codex.tgz && verify /tmp/codex.tgz "${CODEX_INTEGRITY}" \
    && fetch "${CLAUDE_TARBALL}" /tmp/claude.tgz && verify /tmp/claude.tgz "${CLAUDE_INTEGRITY}" \
    && fetch "${CLAUDE_PLATFORM_TARBALL}" /tmp/claude-platform.tgz \
    && verify /tmp/claude-platform.tgz "${CLAUDE_PLATFORM_INTEGRITY}" \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/npm.tgz \
    && test "$(npm --version)" = "${NPM_VERSION}" \
    && npm_config_cache=/tmp/npm-cache npm install --global /tmp/codex.tgz \
    && npm_config_cache=/tmp/npm-cache npm install --global --ignore-scripts --omit=optional /tmp/claude.tgz /tmp/claude-platform.tgz \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
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
    && codex --version \
    && rm -rf /root/.npm /root/.claude /root/.claude.json \
              /tmp/npm-cache /tmp/node-compile-cache \
              /tmp/*.tgz /tmp/*.expected /tmp/*.actual

RUN python3 -m pip install --break-system-packages --no-cache-dir --only-binary :all: --require-hashes \
      -r /tmp/file-tools-requirements.txt \
    && rm /tmp/file-tools-packages /tmp/file-tools-requirements.txt

COPY --from=station . /opt/comma-station
COPY systems/runtime-images/station/entrypoint.sh /usr/local/bin/comma-station-entrypoint
COPY --from=silk-build /out/silk-v3-decoder /usr/local/bin/silk-v3-decoder
COPY systems/runtime-images/station/silk2wav /usr/local/bin/silk2wav
RUN chmod 0755 /usr/local/bin/comma-station-entrypoint /usr/local/bin/silk2wav \
    && test -x /usr/local/bin/silk-v3-decoder \
    && /opt/comma-station/node/bin/node --version \
    && test -x /opt/comma-station/mesh/target/release/stillfail-station \
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
