ARG GO_IMAGE=golang:1.26.6-bookworm
ARG SHELL_IMAGE=alpine:3.23.5
FROM ${GO_IMAGE} AS builder

WORKDIR /src
COPY systems/runtime-images/go.mod ./go.mod
COPY systems/runtime-images/cmd/comma-shell-runtime ./cmd/comma-shell-runtime
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /out/comma-shell-runtime ./cmd/comma-shell-runtime

FROM ${SHELL_IMAGE}

RUN apk add --no-cache \
      'libcrypto3>=3.5.8-r0' \
      'libssl3>=3.5.8-r0' \
    && addgroup -g 10001 runtime \
    && adduser -D -u 10001 -G runtime -h /workspace runtime
COPY --from=builder /out/comma-shell-runtime /usr/local/bin/comma-shell-runtime

WORKDIR /workspace
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/comma-shell-runtime"]
