ARG GO_IMAGE=golang:1.26.6-bookworm
ARG MEETING_IMAGE=debian:trixie-slim
FROM ${GO_IMAGE} AS connector-builder

WORKDIR /src/connector
COPY systems/connector/salix-connect/go.mod systems/connector/salix-connect/go.sum ./
RUN go mod download
COPY systems/connector/salix-connect/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/salix-runtime-agent .

WORKDIR /src/supervisor
COPY systems/runtime-images/go.mod ./go.mod
COPY systems/runtime-images/cmd/comma-meeting-runtime ./cmd/comma-meeting-runtime
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/comma-meeting-runtime ./cmd/comma-meeting-runtime

FROM meetnative AS meetnative-source

FROM ${GO_IMAGE} AS meetnative-builder
COPY --from=meetnative-source / /src/meetnative
WORKDIR /src/meetnative
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -tags chrome_tokenfactory -ldflags='-s -w' -o /out/meet-native ./cmd/meet-native

FROM ${MEETING_IMAGE}

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates chromium ffmpeg xvfb libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 runtime \
    && useradd --uid 10001 --gid 10001 --create-home --home-dir /workspace runtime
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
COPY --from=connector-builder /out/salix-runtime-agent /usr/local/bin/salix-runtime-agent
COPY --from=connector-builder /out/comma-meeting-runtime /usr/local/bin/comma-meeting-runtime
COPY --from=meetnative-builder /out/meet-native /usr/local/bin/meet-native

ENV CHROMIUM_BIN=/usr/bin/chromium \
    DISPLAY=:99 \
    GIN_MODE=release \
    MEETNATIVE_LISTEN_ADDR=127.0.0.1:8081
WORKDIR /workspace
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/comma-meeting-runtime"]
