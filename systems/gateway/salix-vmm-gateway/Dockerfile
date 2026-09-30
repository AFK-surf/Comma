FROM rust:1.96-bookworm AS iroh-build
WORKDIR /src/iroh
COPY Comma/systems/gateway/salix-vmm-gateway/iroh/Cargo.toml Comma/systems/gateway/salix-vmm-gateway/iroh/Cargo.lock ./
COPY Comma/systems/gateway/salix-vmm-gateway/iroh/src/ ./src/
RUN cargo build --release --locked

FROM golang:1.26.3-alpine AS build
WORKDIR /src/Comma/systems/gateway/salix-vmm-gateway
COPY Comma/systems/gateway/salix-vmm-gateway/*.go Comma/systems/gateway/salix-vmm-gateway/go.mod Comma/systems/gateway/salix-vmm-gateway/go.sum ./
COPY agent-vmm /src/agent-vmm
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/salix-vmm-gateway .

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=iroh-build /src/iroh/target/release/salix-gateway-iroh /salix-gateway-iroh
COPY --from=build /out/salix-vmm-gateway /salix-vmm-gateway
ENTRYPOINT ["/salix-vmm-gateway"]
