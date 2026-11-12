# The system image of a coding Task's L4ES sandbox (SalixWeb.CodingSandboxes,
# docs/compute-devices.md#coding-sandboxes): the station runtime image
# (runtime-images/station: the station release, Claude Code, Codex, git), and
# what L4ES needs of a custom system image (l4h-sandbox DESIGN.md §27.3):
# systemd as init, an enabled OpenSSH server, sudo, useradd and D-Bus. gh opens
# the pull requests; Docker (with buildx and compose) runs what the repository
# builds, started by its socket on first use, as L4ES's own image does. The
# station starts as the login user `comma` once sbx-firstboot has made it
# (in the docker group, which sbx-firstboot adds where it exists), with the
# secrets the sandbox was created with. Chromium, with fonts for Latin, CJK
# (from the station base) and emoji text, lets the agent open the page it
# builds; an Xvfb display (:99, comma-display.service) is there for a browser
# or program that needs a window.
# The base is Debian trixie (build.sh).
# build.sh exports it as the EROFS image Salix adds to each L4ES workspace
# (SalixWeb.L4ES.ensure_image/1).
ARG STATION_RUNTIME_IMAGE=comma-station-runtime:amd64
# Match the primary BEAM jobs in .github/workflows/systems-ci.yml.
FROM hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim AS beam

FROM ${STATION_RUNTIME_IMAGE}
ARG PACKAGE_SNAPSHOT

# The station runtime image runs its station as `node`; this image boots systemd.
USER root
WORKDIR /
ENV HOME=/root

# Toolchain versions follow the station base's locked Debian package snapshot.
# GCC provides C/C++ and headers without a second compiler suite. The systems
# umbrella's native parts need the packages that CI installs for them
# (native-build-packages). Rust comes through rustup: the repository pins its
# toolchains (systems/station/scripts/native.ts), and rustup installs a pinned
# or the default stable one in the user's ~/.rustup on first use.
COPY systems/runtime-images/coding-sandbox/native-build-packages /tmp/native-build-packages
RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    set -eu; \
    apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends systemd-sysv dbus openssh-server sudo passwd gh \
       docker.io docker-cli docker-buildx docker-compose \
       libtinfo6 libstdc++6 libssl3t64 libsctp1 \
       build-essential pkg-config rustup golang-go \
       chromium chromium-sandbox xvfb xdotool \
       fonts-liberation fonts-noto-color-emoji \
       $(grep -v '^#' /tmp/native-build-packages) \
    # The same floor as the VMM Station's Chromium (runtime-images/station/Dockerfile).
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' chromium)" ge 156.0.8078.73 \
    && rm -rf /var/lib/apt/lists/* /tmp/native-build-packages \
    && install -d /etc/skel/.rustup \
    && printf 'version = "12"\ndefault_toolchain = "stable"\n' > /etc/skel/.rustup/settings.toml \
    && systemctl enable ssh.service \
    && systemctl disable docker.service containerd.service \
    && systemctl enable docker.socket \
    && systemctl mask getty@tty1.service

# A login shell (what Codex runs commands in) sets its own PATH: keep the station's `comma` command on it.
# A terminal's login shell does not start from the station: give it the browser and the display that the
# station's programs have (comma-station.service).
RUN printf '%s\n' 'PATH="$HOME/.comma/station/bin:$PATH"' \
      'export CHROMIUM_BIN=/usr/bin/chromium DISPLAY="${DISPLAY:-:99}"' > /etc/profile.d/comma.sh

# Copy only the language toolchains, without the source image's operating system.
COPY --from=beam /usr/local/lib/erlang /usr/local/lib/erlang
COPY --from=beam /usr/local/lib/elixir /usr/local/lib/elixir
RUN set -eu; for tool in /usr/local/lib/erlang/bin/* /usr/local/lib/elixir/bin/*; do \
      ln -s "$tool" "/usr/local/bin/$(basename "$tool")"; \
    done

# The locked elan, for the verified kernel (systems/native/verified_kernel). Its
# lake and lean commands install the Lean toolchain that the project's
# lean-toolchain file names in the user's ~/.elan on first use (about 570 MB
# download, 2.9 GB on disk), so the image does not carry it.
# The builder's cache keeps the verified tarball, so a rebuild does not depend
# on GitHub release downloads.
ARG ELAN_TARBALL
ARG ELAN_INTEGRITY
RUN --mount=type=cache,target=/var/cache/comma-downloads,sharing=locked set -eu; \
    cached="/var/cache/comma-downloads/$(basename "${ELAN_TARBALL}")"; \
    printf '%s' "${ELAN_INTEGRITY#sha512-}" | base64 --decode >/tmp/elan.expected; \
    if [ -f "$cached" ] && openssl dgst -sha512 -binary "$cached" | cmp -s /tmp/elan.expected -; then \
      cp "$cached" /tmp/elan.tgz; \
    else \
      curl --fail --location --silent --show-error --retry 5 --retry-delay 10 "${ELAN_TARBALL}" --output /tmp/elan.tgz; \
    fi \
    && openssl dgst -sha512 -binary /tmp/elan.tgz >/tmp/elan.actual && cmp /tmp/elan.expected /tmp/elan.actual \
    && cp /tmp/elan.tgz "$cached" \
    && tar -xzf /tmp/elan.tgz -C /tmp \
    && ELAN_HOME=/opt/elan /tmp/elan-init -y --no-modify-path --default-toolchain none \
    && rm -rf /tmp/elan.tgz /tmp/elan.expected /tmp/elan.actual /tmp/elan-init /opt/elan/toolchains \
    && for tool in /opt/elan/bin/*; do ln -s "$tool" "/usr/local/bin/$(basename "$tool")"; done \
    && elan --version

# Match package.json's packageManager. Install globally for every sandbox user.
RUN npm install --global pnpm@10.25.0 \
    && npm cache clean --force \
    && test "$(pnpm --version)" = 10.25.0 \
    && elixir --version \
    && mix --version \
    && elixir -e 'true = System.version() == "1.20.4"; true = (:code.root_dir() |> Path.join("releases/29/OTP_VERSION") |> File.read!() |> String.trim()) == "29.1.1"'

# Override Debian's RAM-backed /tmp. The root overlay uses the sandbox data disk.
COPY systems/runtime-images/coding-sandbox/tmp.mount /etc/systemd/system/tmp.mount
# Match the sandbox's own fd limit. A billion-entry limit makes BEAM exhaust RAM.
COPY systems/runtime-images/coding-sandbox/docker-daemon.json /etc/docker/daemon.json
RUN install -d -m 1777 -o root -g root /tmp \
    && systemctl enable tmp.mount

COPY systems/runtime-images/coding-sandbox/comma-display.service /etc/systemd/system/comma-display.service
COPY systems/runtime-images/coding-sandbox/comma-station.service /etc/systemd/system/comma-station.service
COPY systems/runtime-images/coding-sandbox/comma-station-start /usr/local/bin/comma-station-start
RUN chmod 0755 /usr/local/bin/comma-station-start \
    && systemctl enable comma-display.service comma-station.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT []
CMD ["/sbin/init"]
