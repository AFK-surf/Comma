FROM golang:1.24.6-bookworm AS build
ENV CGO_ENABLED=0
WORKDIR /src

FROM build AS minio-build
# Upstream RELEASE.2025-09-07T16-13-09Z, the existing storage release.
RUN git init && git remote add origin https://github.com/minio/minio.git \
    && git fetch --depth 1 origin 01ce918d8279a20e4706b96a64396146894adee4 \
    && git checkout --detach FETCH_HEAD
RUN MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go 2025-09-07T16:13:09Z > /tmp/ldflags \
    && go build -p 2 -trimpath -ldflags "$(cat /tmp/ldflags)" -o /out/minio .

FROM build AS mc-build
# Upstream RELEASE.2025-08-13T08-35-41Z, the existing bucket client release.
RUN git init && git remote add origin https://github.com/minio/mc.git \
    && git fetch --depth 1 origin d6541ea280b73a834b64d4097e21f2be77676104 \
    && git checkout --detach FETCH_HEAD
RUN MC_RELEASE=RELEASE go run buildscripts/gen-ldflags.go 2025-08-13T08:35:41Z > /tmp/ldflags \
    && go build -p 2 -trimpath -ldflags "$(cat /tmp/ldflags)" -o /out/mc .

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

FROM runtime AS minio
COPY --from=minio-build /out/minio /usr/bin/minio
COPY --from=minio-build /src/LICENSE /licenses/LICENSE
ENTRYPOINT ["minio"]
CMD ["server", "/data"]

FROM runtime AS mc
COPY --from=mc-build /out/mc /usr/bin/mc
COPY --from=mc-build /src/LICENSE /src/CREDITS /licenses/
ENTRYPOINT ["mc"]
