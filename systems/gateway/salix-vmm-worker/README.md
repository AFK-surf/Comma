# salix-vmm-worker

The Agent VMM worker of one Salix node. `SalixStore.AgentVMM.Worker` starts it as a port and owns its lifetime.
The worker holds the node's Agent VMM Host connections. It keeps transport state only.
Salix owns registration, allocation, command, session, mesh, and trust facts.

The crate is self-contained. `proto/` holds the Agent VMM protobuf schema that the worker speaks.
The build script compiles it without `protoc`. The image builds the worker in a stage of `systems/Dockerfile`.

## Host connections

Hosts connect to the public listener with TLS 1.3 and the ALPN `agent-vmm/rpc/1`, then `yamux`.
One `yamux` stream carries one call. Each frame is a tag byte, a big-endian `u32` length, and the payload:

| Tag | Frame | Payload |
| --- | --- | --- |
| `0x00` | request header, first frame of a call | JSON: `v`, `method`, `metadata`, optional `timeout_ms` |
| `0x01` | message | one protobuf message |
| `0x02` | end of the request stream | empty |
| `0x03` | status, last frame from the server | JSON: `code`, `message`, `details_b64` |

A Host calls `RemoteControllerService/Connect` and the six `PersonalMeshRegistryService` methods.
Each call carries the registration ID and the credential as `authorization: Bearer <base64>`.
The worker accepts `HostHello.protocol_version` `5` only. It answers another version with `REMOTE_PROTOCOL_UNSUPPORTED` and the supported range.

The worker asks Salix to authenticate the credential and to settle the hello before it acknowledges readiness.
It then claims commands for that connection, sends each one to the Host, and commits the Host transcript to Salix.
A transient claim failure does not close a healthy connection. Claims retry with backoff from 200 ms to 5 s.
A command that changes the Host inventory ends the connection after its result commits. The next hello supplies a fresh inventory.

## Runtime sessions

A succeeded `OpenSession` binds one allocation generation to the connection that carried it.
The worker commits the result first, and then tells Salix that the session is ready.
For each runtime call the worker opens a stream to the Host on that same connection.
The call carries `x-agentvmm-allocation-id`, `x-agentvmm-allocation-generation`, and `authorization: Bearer <tunnel_nonce>`.
When the connection ends, the worker closes its sessions and tells Salix which connection ended.

Salix names one typed operation for each call. The worker does not expose an arbitrary Host RPC.
`process.start` is idempotent by request ID. A session holds at most 256 processes and 1024 start records.
A typed operation has 90 seconds. `compute.image.import` has 750 seconds, and the Host fetches the archive itself.
Errors use a finite vocabulary. Host error text and resource names never reach Salix.

## Salix side

Salix and the worker use two local channels. Both carry JSON frames with a four-byte length (`{:packet, 4}`).

- Standard input and output. Salix sends the configuration as the first frame. The worker answers `ready` with its listener address.
  The worker then sends each control request (`call`) and each fact (`event`). Salix answers a request with `reply`.
  A reply has the status and body of the gateway control API in `SalixStore.AgentVMMGatewayControl`.
- A Unix socket in a directory that only Salix can enter. One connection carries one request with the worker token.
  `session_call` runs a typed operation and answers `{"status", "body"}`.
  `iroh_tunnel` answers `{"type": "ready"}`. The connection then carries the bytes of one `agent-vmm/service-tunnel/1` stream.

The worker exits when Salix closes standard input. It holds at most 64 iroh tunnels. A tunnel has 15 seconds to connect and one hour to live.

## Tests

```sh
cargo test
make testhost PROFILE=dev
```

`cargo test` runs the worker against a scripted Salix and a test Host over the real transports.
`salix_vmm_test_host` is the same test Host as a process. `apps/salix_web/test/agent_vmm_worker_e2e_test.exs` runs it against the real Salix store.
The test Host needs the `test-host` feature. The release image does not contain it.
