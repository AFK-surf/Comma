# Salix tailnet gateway

This module connects Agent Groups to their own Tailscale networks (tailnets).
Each Salix Pod runs one gateway process. The process runs one `tsnet` node for each Group whose tailnet lease the Pod holds.

`SalixAgent.Tailnet.Gateway` starts the gateway as an Erlang port on the first node start.
When the port closes, the gateway stops its nodes and exits. It does not log them out.

## Identity

- A Group has at most one node, in one tailnet. A tailnet admin approves it once with a login link.
- The node is not ephemeral. Its machine and node keys stay in the owner's lease record (`ctl/tailnet/groups/<group_id>/node.json`), sealed.
- Every state change goes to the owner as a `persist` frame. `WriteState` returns only after the owner saves it under its lease. If the owner cannot save it, the node stops.
- The next owner gives the saved state in `start`. The node reconnects with the same identity and needs no new approval.

## Protocol

Port frames use a 4-byte big-endian length followed by JSON, at most 256 KiB.

1. The owner sends one configuration frame: the Unix socket path, a random token and a scratch directory.
2. The gateway listens on the socket (mode `0600`) and writes `{"type":"ready"}`.
3. The owner sends `start` (Group, lease epoch, host name, tags, `accept_routes`, saved state), `stop` (with optional logout) and `persisted` (the answer to `persist`).
4. The gateway sends `status`, `persist`, `activity` (open connections) and `stopped`.

Socket requests use the same framing, at most 16 KiB. A request holds the token, the Group and the lease epoch:

- `dial` with a host and port: one reply frame, then the raw TCP stream.
- `peers` with a cursor: at most 200 peers.

The gateway refuses a request whose epoch is not the running node's epoch.

## Rules

- **Tailnet destinations only.** A host resolves only from the node's network map: a MagicDNS name or an address. The address must be a peer's Tailscale address, or be inside a peer's approved subnet route when `accept_routes` is on. Exit-node routes (`/0`) never count.
- **Netstack only.** The gateway dials through the node's netstack. It does not use `tsnet`'s `Dial`, which can send an address to the host network.
- **Client only.** Shields up, no listeners, no Tailscale SSH, no Serve or Funnel.
- **No log upload.** The process sets `TS_NO_LOGS_NO_SUPPORT`.
- **Bounded starts.** At most 4 nodes start at the same time. The owner stops an idle node.

## Build and test

```sh
make                 # ../apps/salix_agent/priv/tailnet_gateway
go test -race ./...  # uses tailscale.com/tstest/integration/testcontrol
```

The module pins the same `tailscale.com` version as `systems/tailcat-gateway`. It requires Go 1.27.1. The Makefile sets `GOTOOLCHAIN=auto`. Set it for `go test` as well.
