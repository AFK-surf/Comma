FROM golang:1.27.3-trixie AS go

FROM node:24.22.1-bookworm-slim AS node

# Keep the devcontainer aligned with the toolchain used to build the systems
# Rust NIFs. Station's native builder selects its own pinned toolchain through
# rustup when it needs it.
FROM rust:1.96.0-slim-trixie AS rust

FROM hexpm/elixir:1.20.1-erlang-29.0.2-debian-trixie-20260610-slim

ENV LANG=C.UTF-8 \
    MIX_ENV=dev \
    MIX_HOME=/usr/local/share/mix \
    PATH=/usr/local/bin:${PATH}

COPY --from=node /usr/local/ /usr/local/
COPY --from=rust /usr/local/rustup /opt/rustup
COPY --from=rust /usr/local/cargo/bin /usr/local/cargo/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      cmake \
      ca-certificates \
      curl \
      ffmpeg \
      file \
      git \
      gosu \
      inotify-tools \
      jq \
      less \
      libopus-dev \
      libsodium-dev \
      libsrtp2-dev \
      libssl-dev \
      libuv1-dev \
      openssh-client \
      postgresql-client \
      pkg-config \
      procps \
      redis-tools \
      sudo \
      vim-tiny \
      zsh \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p "${MIX_HOME}" \
    && mix local.hex --force \
    && mix local.rebar --force \
    && npm install --global pnpm@10.25.0 \
    && groupadd --gid 1000 vscode \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash vscode \
    && echo 'vscode ALL=(root) NOPASSWD:ALL' >/etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:${PATH}

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/var/lib/comma-dev/cargo-home \
    PATH=/usr/local/cargo/bin:${PATH}

ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:${PATH}
COPY systems/native/verified_kernel/lean-toolchain /tmp/lean-toolchain
COPY systems/native/verified_kernel/scripts/install-toolchain.sh /tmp/install-lean-toolchain.sh
# The backend builds the verified kernel as vscode, and elan writes its settings on first use.
RUN bash /tmp/install-lean-toolchain.sh /tmp/lean-toolchain \
    && chown -R vscode:vscode /opt/elan /opt/rustup /usr/local/cargo/bin

COPY systems/devcontainer/entrypoint.sh /usr/local/bin/comma-devcontainer-entrypoint
RUN chmod 0755 /usr/local/bin/comma-devcontainer-entrypoint

WORKDIR /workspace/Comma
ENTRYPOINT ["/usr/local/bin/comma-devcontainer-entrypoint"]
CMD ["bash", "/workspace/Comma/systems/devcontainer/backend.sh"]
