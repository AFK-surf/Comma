# salix-vmm-gateway

This independent Go workload terminates Agent VMM `remote.v1` and the provider-neutral `trust.v1.PersonalMeshRegistryService`.
It owns only live connection and session routing and typed protobuf transport.
Salix owns registration, allocation, command, mesh, and trust facts through the workload-authenticated control API.
Canonical signed protobuf inputs come from the shared Agent VMM signing package. There is no copied wire schema.

The remote listener uses TLS 1.3. The internal session proxy requires mTLS. The separate Salix control API uses the install secret.
The session CONNECT path contains the exact registration, allocation, allocation generation, and connection generation.
A gateway restart drops live connections. Hosts reconnect, and Salix inventory reconciliation resolves the new gateway instance and connection epoch.

The gateway commits each terminal command result before it changes the live connection.
A stale revision rejection ends that connection. The next Host handshake supplies a bounded inventory snapshot.
Salix checks each command against its exact allocation target before it retries it.

A transient Server claim failure does not close a healthy Host connection. Claims retry with backoff while the Host receive loop stays active.
Retries cover control availability 503s, proxy 502 and 504s, EOF, connection reset or refusal, and network timeouts.
Authorization, stale identity, unknown 503 reasons, and invalid responses end the claim loop.
Host disconnect or request cancellation stops retry. No failed claim authorizes a command.
Command commit failures still end the connection.

Each accepted runtime session owns one persistent `host.v1.AgentRuntimeService` client until the Host closes the session.

Runtime execution uses three typed actions: acquire, release, and list.
The gateway forwards the exact container instance, allocation authority, execution owner, activity ID, kind, and deadline. It does not infer an owner from an input batch.
The main execution has no deadline. Short operations need one.
The gateway does not expose an arbitrary Host RPC or Host credential to Salix.

The control client sends an exact gateway-instance workload identity on every request.
Salix stores only credential digests and fences command results and session observations against the current instance and epoch.
Registry signing keys stay behind the Salix signer seam. Neither the gateway nor Postgres receives a device or mesh private key.

Local builds use the sibling `agent-vmm` checkout through `go.mod replace`.
Release builds use a two-root context with the selected Comma and Agent VMM revisions.
The published OCI image digest is the deployment identity. Source revisions are diagnostics only.

## Wire changes and release order

The Gateway parses Salix command JSON with the Agent VMM protobuf version in its image. The Host parses the forwarded protobuf command with its installed version.

1. Promote a mainline Gateway image and a formal Host bundle that know the new command fields before Salix sends those fields.
2. Test a command on staging.
3. Promote the same Gateway image and chart to production before the Comma release.
4. Update each Host through its state-preserving lifecycle path.

If Salix already sends a field that the production Gateway cannot parse:

1. Promote a staging-proven mainline Gateway release.
2. Update the affected Hosts with a formal bundle.
3. Check the Host connection and automatic Runtime recovery.
4. Verify a Host command result, Runtime readiness, and a Worker response before you report recovery.

Do not edit accepted commands or install a branch image to hide the mismatch.
An older Connector with an exited loop needs controlled client recovery.

## Outbound iroh service tunnels

With `IROH_DIALER_BINARY=/salix-gateway-iroh`, the internal mTLS HTTP/1.1 listener accepts `CONNECT /v1/iroh/service-tunnel`.
`Iroh-Endpoint-Addr` is unpadded base64url of the official iroh `EndpointAddr` JSON.
After HTTP 200, the connection carries canonical `service.v1.ServiceRouteService` gRPC bytes.
The caller gets an endpoint observation and RouteCapability through its trust and route workflow, then sends `OpenServiceForward` with that capability.
HTTP 200 means only that the transport connected. It does not authorize or open a workload port.
The Host validates the capability, export, route generation, expiry, and budgets before it forwards into the guest container.

The dialer uses the official Rust iroh SDK with the N0 preset (discovery, direct QUIC, and HTTPS relay fallback).
The private Unix socket protocol is one bounded JSON address line, `ready\n`, then bytes.
Only `agent-vmm/service-tunnel/1` is supported, with no inbound ALPNs, pairing, mesh authority, signing keys, or durable endpoint state.

Tunnel count per pod, address size, dial time, and connection lifetime are bounded in `iroh.go`.
Either transport direction closing closes the whole gRPC connection.
Restart or shutdown drops these tunnels. Callers must reconnect explicitly.
Worker loss returns 503 for new tunnels and closes existing ones. It does not change remote-controller ownership or write persistent state.

The client CA authenticates the internal caller. The SDK's peer handshake authenticates the requested EndpointId.
The Host's enrolled trust signer is the authority for RouteCapability, and the Host owns the fail-closed decision to open the container port.
The gateway does not treat a supplied endpoint as service authorization. If the handler is mounted on a different listener, its mTLS check keeps this admission boundary.

Run `bash test-iroh.sh` with a sibling Agent VMM checkout.
Its destination is a test gRPC server, not a macOS VMM. It does not prove Host authorization or guest networking.

This is the internal gateway-to-iroh transport only. There is no public HTTP listener, wildcard hostname-to-service map, public route issuer, or browser authorization.
DNS alone does not publish a container service.

## Isolated pressure integration test

Use Python 3.11 or newer, Docker, Go, Rust, and the macOS signing tools.
Build a current Linux arm64 Guest bundle from the sibling VMM checkout. From this gateway directory, run:

```sh
python3 testdata/pressure-relay/build.py --vmm /path/to/agent-vmm \
  --guest-bundle /path/to/guest-bundle --output /tmp/comma-pressure-fixture
. /tmp/comma-pressure-fixture/env.sh
cd ../..
# Set the repository's test database ports and Redis URL to isolated Docker services.
mix test apps/salix_web/test/compute_pressure_e2e_test.exs
```

The output directory must be new. The builder creates a test image and a scratch Guest bundle.
It does not change an installed Host or deploy an artifact.
A fixture relay carries callbacks through authenticated ForwardTCP. It adds no production egress exception.
The fixture directory that ExUnit prints keeps bounded Guest and Host logs.
