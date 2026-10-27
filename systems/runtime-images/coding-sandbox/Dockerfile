# The system image of a coding Task's L4ES sandbox (SalixWeb.CodingSandboxes,
# docs/compute-devices.md#coding-sandboxes): the station runtime image
# (runtime-images/station: the station release, Claude Code, Codex, git), and
# what L4ES needs of a custom system image (l4h-sandbox DESIGN.md §27.3):
# systemd as init, an enabled OpenSSH server, sudo, useradd and D-Bus. gh opens
# the pull requests; Docker (with buildx and compose) runs what the repository
# builds, started by its socket on first use, as L4ES's own image does. The
# station starts as the login user `comma` once sbx-firstboot has made it
# (in the docker group, which sbx-firstboot adds where it exists), with the
# secrets the sandbox was created with. The base is Debian trixie (build.sh).
# build.sh exports it as the EROFS image Salix adds to each L4ES workspace
# (SalixWeb.L4ES.ensure_image/1).
ARG STATION_RUNTIME_IMAGE=comma-station-runtime:amd64
# Match the primary BEAM jobs in .github/workflows/systems-ci.yml.
FROM hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim AS beam

FROM ${STATION_RUNTIME_IMAGE}

# The station runtime image runs its station as `node`; this image boots systemd.
USER root
WORKDIR /
ENV HOME=/root

# Toolchain versions follow the station base's locked Debian package snapshot.
# GCC provides C/C++ and headers without a second compiler suite.
RUN set -eu; \
    apt-get update \
    && apt-get install -y --no-install-recommends systemd-sysv dbus openssh-server sudo passwd gh \
       docker.io docker-cli docker-buildx docker-compose \
       libtinfo6 libstdc++6 libssl3t64 libsctp1 \
       build-essential pkg-config rustc cargo golang-go \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable ssh.service \
    && systemctl disable docker.service containerd.service \
    && systemctl enable docker.socket \
    && systemctl mask getty@tty1.service

# Copy only the language toolchains, without the source image's operating system.
COPY --from=beam /usr/local/lib/erlang /usr/local/lib/erlang
COPY --from=beam /usr/local/lib/elixir /usr/local/lib/elixir
RUN set -eu; for tool in /usr/local/lib/erlang/bin/* /usr/local/lib/elixir/bin/*; do \
      ln -s "$tool" "/usr/local/bin/$(basename "$tool")"; \
    done

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

COPY systems/runtime-images/coding-sandbox/comma-station.service /etc/systemd/system/comma-station.service
COPY systems/runtime-images/coding-sandbox/comma-station-start /usr/local/bin/comma-station-start
RUN chmod 0755 /usr/local/bin/comma-station-start \
    && systemctl enable comma-station.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT []
CMD ["/sbin/init"]
