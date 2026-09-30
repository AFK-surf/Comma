# Salix Tailcat gateway

This module connects Agent SSH sessions to [Tailcat](https://github.com/tailscale/tailcat) servers.
Each Salix Pod runs one gateway process for all of its SSH sessions.
The gateway never runs one process per session.

`SalixAgent.SSH.TailcatGateway` starts the gateway as an Erlang port on the first `ssh.open` with `tailcat`.
When the port closes, the gateway stops.

## Protocol

1. The node sends one configuration frame on stdin. The frame holds the Unix socket path, a random token and the trusted DERP map URL.
2. The gateway listens on the socket (mode `0600`, in a `0700` directory) and writes one `{"type":"ready"}` frame.
3. For each SSH connection, the node connects to the socket and sends one dial request: the token, the address or DNS name, and the port.
4. The gateway sends one reply frame. The reply is `{"ok":true,"server_node_key":...}` or `{"code":...,"message":...}`.
5. After a successful reply, the socket carries the raw SSH stream. OTP `:ssh` runs on it.

All frames use a 4-byte big-endian length followed by JSON, at most 16 KiB.

## Rules

- **Trusted relays only.** The gateway uses DERP relays only from the trusted DERP map.
  - An address that names a region by ID must name a region in the map.
  - An address with embedded relays must use host names from one region of the map. The gateway ignores the embedded IPs, ports and TLS settings.
  - An Agent-supplied address therefore cannot make the gateway open connections to other hosts.
- **Server port only.** The gateway dials only a port on the Tailcat server. It never uses exit-node or UDP dials.
- **Ephemeral keys.** Each connection gets its own `tailcat.Client` with a new node key. The gateway never stores, reuses or shares a key. The Agents of one Group run on many nodes at once, and two peers that present one node key to a server would replace each other there.
- **No `--allow`.** A server that admits only listed client keys never answers an ephemeral key, so the dial fails with `tailcat_unreachable` after 10 seconds. The Group SSH key authenticates instead.
- **No node-wide limit.** The gateway does not limit connections per Pod. The SSH session limit per Agent session applies. One client with one connection uses about 2 MiB and 61 goroutines.
- **Clean close.** When a connection ends, the gateway waits up to 5 seconds for the last TCP segments, then closes the client.

## Build and test

```sh
make                 # ../apps/salix_agent/priv/tailcat_gateway
make testpeer        # test-only Tailcat server behind a local relay
go test -race ./...
```

The module requires Go 1.27.1 or later, because Tailcat v0.7.0 requires it. The Makefile sets `GOTOOLCHAIN=auto`, so an older installed Go fetches 1.27.1. Set it for `go test` as well.
Tailcat makes no API or wire-format stability promises. Update the pinned version on purpose, and run the Go tests and `apps/salix_agent/test/ssh_tools_test.exs`.
