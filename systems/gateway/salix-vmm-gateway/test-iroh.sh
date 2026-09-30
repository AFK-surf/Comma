#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cargo build --manifest-path iroh/Cargo.toml --locked --bins --examples
IROH_TEST_BINARY="$PWD/iroh/target/debug/salix-gateway-iroh" go test -race -count=1 ./... "$@"
