# Build context: this directory.
FROM rust:1.96-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/
RUN cargo build --release --locked

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/comma-station-gateway /comma-station-gateway
ENTRYPOINT ["/comma-station-gateway"]
CMD ["serve"]
