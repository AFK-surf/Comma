# salix-vmm-gateway

This independent Go workload terminates Agent VMM `remote.v1` and the
provider-neutral `trust.v1.PersonalMeshRegistryService`. It owns only live
connection/session routing and typed protobuf transport. Salix owns
registration, allocation, command, mesh, and trust facts through the
workload-authenticated control API. Canonical signed protobuf inputs are
derived with the shared Agent VMM signing package; there is no copied wire
schema.

The remote listener uses TLS 1.3. The internal session proxy requires mTLS;
the separate Salix control API uses the install secret. The session CONNECT path contains the exact registration,
allocation, allocation generation, and connection generation. A gateway restart intentionally drops live
connections. Hosts reconnect and Salix inventory reconciliation resolves the
new current gateway instance and connection epoch.

The gateway commits each terminal command result before it changes the live
connection. A stale revision rejection ends that connection. The next Host
handshake supplies a bounded inventory snapshot. Salix checks each command
against its exact allocation target before retrying it.

A transient Server claim failure does not close a healthy Host connection.
Claim retries use a 200ms to 5s backoff. The Host receive loop remains active.
Retries cover control availability 503s, proxy 502/504s, EOF, connection reset/refusal, and network timeouts.
Authorization, stale identity, unknown 503 reasons, and invalid responses still end the claim loop.
Host disconnect or request cancellation stops retry. No failed claim authorizes a command.
Command commit failures still end the connection because result settlement has a separate contract.

Each accepted runtime session owns one persistent `host.v1.AgentRuntimeService`
client. Structured image, container, volume, exec, log, TCP forwarding,
workspace, build, and service-route operations reuse that client until the
host closes the runtime session. One operation does not consume the transport.

Runtime execution uses three typed actions: acquire, release, and list. The
gateway forwards the exact container instance, allocation authority, execution
owner, activity ID, kind, and deadline. It does not infer an owner from an
input batch. The main execution has no deadline. Short operations require one.
The gateway does not expose an arbitrary Host RPC or Host credential to Salix.

The control client sends an exact gateway-instance workload identity on every
bounded, deadline-limited request. Salix stores only credential digests and
fences command result/session observations against that current instance and
epoch. Registry signing keys remain behind the Salix signer seam; neither the
gateway nor Postgres receives a device or mesh private key.

Local builds use the sibling `agent-vmm` checkout through `go.mod replace` so
Comma never copies or forks `remote.v1`/`host.v1`. Release builds use a two-root
context containing the selected Comma and Agent VMM revisions. The published OCI
image digest is the deployment identity; source revisions are diagnostics and
do not participate in runtime admission.

## Wire changes and release order

The Gateway parses Salix command JSON with the Agent VMM protobuf version in
its image. The Host parses the forwarded protobuf command with its installed
version. Promote a mainline Gateway image and a formal Host bundle that know
new command fields before Salix starts to send those fields. Test a command
on staging, then promote the same Gateway image and chart to production before
the Comma release. Update each Host through its state-preserving lifecycle path.

If Salix already sends a field that the production Gateway cannot parse,
promote a staging-proven mainline Gateway release and update affected Hosts
with a formal bundle. Do not edit accepted commands or install a branch image
to hide the mismatch. After both updates, check the Host connection and automatic Runtime recovery.
An older Connector with an exited loop needs controlled client recovery. Verify a Host
command result, Runtime readiness, and a Worker response before reporting
recovery.

## Outbound iroh service tunnels

With `IROH_DIALER_BINARY=/salix-gateway-iroh`, the internal mTLS HTTP/1.1
listener accepts `CONNECT /v1/iroh/service-tunnel`. `Iroh-Endpoint-Addr` is
unpadded base64url of the official iroh `EndpointAddr` JSON. After HTTP 200,
the connection carries canonical `service.v1.ServiceRouteService` gRPC bytes.
The caller obtains an endpoint observation and RouteCapability through its
existing trust/route workflow, then sends `OpenServiceForward` with that
capability. HTTP 200 only means transport connected; it does not authorize or
open a workload port. The Host still validates the capability, export, route
generation, expiry and budgets before forwarding into the guest container.

The dialer uses the official Rust iroh 1.1 SDK with the N0 preset (discovery,
direct QUIC and HTTPS relay fallback). Go bindings are community maintained;
the official Rust SDK avoids a custom QUIC protocol or a Go FFI ABI dependency.
The private Unix socket protocol is one bounded JSON address line, `ready\n`,
then bytes. Only `agent-vmm/service-tunnel/1` is supported, with no inbound
ALPNs, pairing, mesh authority, signing keys or durable endpoint state.

Each pod admits at most 64 tunnels across all callers, with no per-user timer,
poll or fan-out scan. The address is at most 8190 decoded bytes, dialing takes
at most 15 seconds at the gateway, and each connection lasts at most one hour.
Either transport direction closing closes the whole gRPC connection. Restart
or shutdown drops these ephemeral tunnels; callers must reconnect explicitly.
Worker loss returns 503 for new tunnels and closes existing ones; it does not
change remote-controller ownership or write persistent state. No retry or
compatibility state is introduced.

Architecture review: the independent boundary is an internal caller reaching
a remote Host service. The existing client CA authenticates the internal
caller; the requested EndpointId is authenticated by the SDK's peer handshake;
the Host's existing enrolled trust signer remains the independent authority
for RouteCapability. The Host owns the fail-closed decision for opening the
container port. The gateway neither treats a supplied endpoint as service
authorization nor manufactures an identity proof. The handler's mTLS check
preserves this admission boundary if it is mounted on a different listener.
The expanded existing gateway test crosses HTTP mTLS, Unix IPC, real QUIC and
canonical gRPC; it changes the same merge/release decision as the old gateway
test and introduces no separate publication or runtime attestation gate.

Run `bash test-iroh.sh` with a sibling Agent VMM checkout. The fixture checks
bidirectional service data and destination rejection propagation through real
iroh endpoints, plus worker shutdown. Its destination is a test gRPC server,
not a macOS VMM; it does not prove Host authorization or guest networking.
Those remain Agent VMM's Host/guest tests. The retained TLA models and their
code mappings are unchanged: this connection transport adds no durable state,
ownership, accepted-work or signing-authority transition.

This is the internal gateway-to-iroh transport only. There is no public HTTP
listener, wildcard hostname-to-service map, public route issuer or browser
authorization. DNS alone does not publish a container service.

## Isolated pressure integration test

Use Python 3.11 or newer, Docker, Go, Rust, and the macOS signing tools. Build a
current Linux arm64 Guest bundle from the sibling VMM checkout. From this
gateway directory, run:

```sh
python3 testdata/pressure-relay/build.py --vmm /path/to/agent-vmm \
  --guest-bundle /path/to/guest-bundle --output /tmp/comma-pressure-fixture
. /tmp/comma-pressure-fixture/env.sh
cd ../..
# Set the repository's test database ports and Redis URL to isolated Docker services.
mix test apps/salix_web/test/compute_pressure_e2e_test.exs
```

The output directory must be new. The builder creates a test image and a scratch
Guest bundle. It does not change an installed Host or deploy an artifact.
The test uses six separate registrations and volumes, the real Salix router,
mTLS gateway, VMM, and Connector WebSockets. A fixture relay carries callbacks
through authenticated ForwardTCP; it adds no production egress exception.

The test checks warm idle instances, one scoped pressure candidate, Connector
quiet, exact-instance stop, and an execution-held busy instance. A scratch
Guest probe measures the shared parent limit and memory headroom. It triggers a
bounded child OOM and adds a small anonymous allocation at 99% parent usage to
exercise parent OOM with all surviving instances execution-held. No queued
Session input, approval, asynchronous obligation, or model call is created.
Those guarantees retain their separate Session and Connector regressions.
The fixture directory printed by ExUnit retains bounded Guest and Host logs.
