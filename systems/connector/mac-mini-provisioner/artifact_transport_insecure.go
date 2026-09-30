//go:build bft_insecure_artifact_test

package main

// This test-only build tag permits a loopback HTTP artifact server so the
// binary E2E can serve deterministic bytes without changing host trust stores.
// Release workflows never set this tag.
const allowInsecureLoopbackArtifact = true
