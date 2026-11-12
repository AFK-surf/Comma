# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS base

# An HTTPS apt mirror for the image's architecture, for example
# https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports. The base image has no CA
# bundle yet, so it comes from Alpine. apt still checks every index against
# Ubuntu's signing keys.
ARG UBUNTU_MIRROR=
COPY --from=alpine:3.22 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN if [ -n "$UBUNTU_MIRROR" ]; then \
      sed -i -E "s#http://(ports|archive|security)\.ubuntu\.com/ubuntu(-ports)?#${UBUNTU_MIRROR}#" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi

FROM base AS dmg-tools

ARG LIBDMG_HFSPLUS_COMMIT=e18579b391950589b9ed16ee630c54ce4319bb29
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake git libbz2-dev libssl-dev zlib1g-dev \
    && git clone https://github.com/mozilla/libdmg-hfsplus /src \
    && git -C /src checkout "${LIBDMG_HFSPLUS_COMMIT}" \
    && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /build -j"$(nproc)" \
    && install -m 0755 /build/dmg/dmg /build/hfs/hfsplus /usr/local/bin/

FROM base AS velopack

ARG TARGETARCH
ARG DOTNET_SDK_VERSION=10.0.403
ARG VPK_VERSION=1.2.0
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl libssl3 libstdc++6 unzip \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in arm64) rid=linux-arm64 ;; amd64) rid=linux-x64 ;; esac \
    && echo "$rid" > /tmp/rid && mkdir -p /opt/dotnet /opt/vpk \
    && curl -fsSL --retry 5 --retry-all-errors "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-${rid}.tar.gz" -o /tmp/dotnet.tar.gz \
    && tar -xzf /tmp/dotnet.tar.gz -C /opt/dotnet && rm /tmp/dotnet.tar.gz \
    && curl -fsSL --retry 5 --retry-all-errors "https://api.nuget.org/v3-flatcontainer/vpk/${VPK_VERSION}/vpk.${VPK_VERSION}.nupkg" -o /tmp/vpk.nupkg \
    && unzip -q /tmp/vpk.nupkg -d /opt/vpk && rm /tmp/vpk.nupkg
COPY velopack/Program.cs velopack/VelopackPack.csproj /build/
RUN /opt/dotnet/dotnet publish /build -c Release -r "$(cat /tmp/rid)" --self-contained \
      -p:VpkDir=/opt/vpk/tools/net10.0/any -o /opt/velopack \
    && mkdir /opt/velopack/vendor \
    && install -m 0755 /opt/vpk/vendor/UpdateMac /opt/velopack/vendor/ \
    && install -m 0644 /opt/vpk/vendor/Velopack.entitlements /opt/velopack/vendor/

FROM base

ARG TARGETARCH
ARG SWIFT_VERSION=6.4.2
ARG NODE_VERSION=24.22.1
# A mirror of https://nodejs.org/dist with the same layout.
ARG NODE_DIST=https://nodejs.org/dist
ARG PNPM_VERSION=10.25.0
ARG LLVM_VERSION=20
ARG RCODESIGN_VERSION=0.29.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      binutils build-essential ca-certificates curl git gnupg2 hfsprogs imagemagick \
      libarchive-tools libbz2-1.0 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev \
      libpython3-dev libsqlite3-0 libssl3 libstdc++-13-dev libxml2-dev libz3-dev \
      lld-${LLVM_VERSION} llvm-${LLVM_VERSION} perl pkg-config python3 tzdata unzip \
      xz-utils zip zlib1g-dev zstd \
    && rm -rf /var/lib/apt/lists/*

# Downloads go to a file first, so that a retried transfer starts the file again.
RUN case "$TARGETARCH" in \
      arm64) dir=ubuntu2404-aarch64; suffix=ubuntu24.04-aarch64 ;; \
      amd64) dir=ubuntu2404; suffix=ubuntu24.04 ;; \
      *) echo "unsupported architecture $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 --retry-all-errors "https://download.swift.org/swift-${SWIFT_VERSION}-release/${dir}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${suffix}.tar.gz" -o /tmp/swift.tar.gz \
    && tar -xzf /tmp/swift.tar.gz -C /opt && rm /tmp/swift.tar.gz \
    && mv "/opt/swift-${SWIFT_VERSION}-RELEASE-${suffix}" /opt/swift \
    && cd /opt/swift/usr \
    && rm -rf lib/swift/embedded lib/swift_static lib/liblldb* lib/libsourcekitdInProc.so \
      bin/lldb* bin/sourcekit-lsp bin/docc share/docc bin/clangd bin/swift-format

RUN case "$TARGETARCH" in arm64) arch=arm64 ;; amd64) arch=x64 ;; esac \
    && curl -fsSL --retry 5 --retry-all-errors "${NODE_DIST}/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /opt && rm /tmp/node.tar.xz \
    && mv "/opt/node-v${NODE_VERSION}-linux-${arch}" /opt/node \
    && PATH=/opt/node/bin:$PATH npm install -g "pnpm@${PNPM_VERSION}" \
    && rm -rf /root/.npm

RUN case "$TARGETARCH" in arm64) arch=aarch64 ;; amd64) arch=x86_64 ;; esac \
    && name="apple-codesign-${RCODESIGN_VERSION}-${arch}-unknown-linux-musl" \
    && curl -fsSL --retry 5 --retry-all-errors "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${RCODESIGN_VERSION}/${name}.tar.gz" -o /tmp/rcodesign.tar.gz \
    && tar -xzf /tmp/rcodesign.tar.gz -C /tmp \
    && install -m 0755 "/tmp/${name}/rcodesign" /usr/local/bin/rcodesign \
    && rm -rf "/tmp/${name}" /tmp/rcodesign.tar.gz

COPY --from=dmg-tools /usr/local/bin/dmg /usr/local/bin/hfsplus /usr/local/bin/
COPY --from=velopack /opt/velopack /opt/macos-cross/velopack

ARG COMPILER_RT_TAG=llvmorg-21.1.0
ARG OS_VERSION_CHECK_SHA256=37accdfb259f9228c1e5049e8bc3dcc2c996fa17c7fda542eed977237af71a9e
RUN mkdir -p /opt/macos-cross/compiler-rt \
    && curl -fsSL --retry 5 --retry-all-errors -o /opt/macos-cross/compiler-rt/os_version_check.c \
      "https://raw.githubusercontent.com/llvm/llvm-project/${COMPILER_RT_TAG}/compiler-rt/lib/builtins/os_version_check.c" \
    && echo "${OS_VERSION_CHECK_SHA256}  /opt/macos-cross/compiler-rt/os_version_check.c" | sha256sum -c -

COPY bin/ /opt/macos-cross/bin/
RUN mkdir -p /opt/macos-cross/swift-darwin-rd \
    && cd /opt/macos-cross/swift-darwin-rd \
    && for entry in shims clang host apinotes; do ln -s "/opt/swift/usr/lib/swift/${entry}" "${entry}"; done \
    && grep -o -E '^module [A-Za-z_]+' /opt/swift/usr/lib/swift/shims/module.modulemap \
      | awk '{ print "extern module " $2 " \"shims/module.modulemap\"" }' > module.modulemap \
    && cd /opt/macos-cross/bin \
    && ln -s "/usr/bin/llvm-libtool-darwin-${LLVM_VERSION}" libtool \
    && ln -s "/usr/bin/llvm-lipo-${LLVM_VERSION}" lipo \
    && ln -s "/usr/bin/llvm-install-name-tool-${LLVM_VERSION}" install_name_tool \
    && ln -s "/usr/bin/llvm-otool-${LLVM_VERSION}" otool \
    && ln -s "/usr/bin/llvm-strip-${LLVM_VERSION}" strip \
    && ln -s "/usr/bin/dsymutil-${LLVM_VERSION}" dsymutil \
    && ln -s /opt/macos-cross/velopack/vpk vpk \
    && chmod 0755 /opt/macos-cross/bin/* \
    && ln -s /opt/macos-cross/bin/PlistBuddy /usr/libexec/PlistBuddy

ENV PATH=/opt/macos-cross/bin:/opt/node/bin:/opt/swift/usr/bin:$PATH \
    MACOS_LD=/usr/bin/ld64.lld-${LLVM_VERSION} \
    SWIFT_DARWIN_RESOURCE_DIR=/opt/macos-cross/swift-darwin-rd \
    VELOPACK_VENDOR_DIR=/opt/macos-cross/velopack/vendor

COPY build-dmg.sh make-dmg.sh prepare-sdk.sh sign.sh /opt/macos-cross/
WORKDIR /src
ENTRYPOINT ["/opt/macos-cross/build-dmg.sh"]
