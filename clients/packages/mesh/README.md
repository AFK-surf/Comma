# @comma/mesh

Direct connections between a Comma client core and a station, and the protocol on them. The client core uses the client half (`MeshClient`). A station uses the serving half (`serveMesh`).

## What is in this package

- `link.ts`: the QUIC surface the mesh needs (`MeshEndpoint`, `MeshConnection`, `BiStream`). A peer is named by its endpoint id, an Ed25519 public key. A connection can say how it runs (`nextVia`: direct, an iroh relay, or Salix) and tells each change.
- `station-native.ts` (`@comma/mesh/station-native`): that surface on the station's native addon (`systems/station/native/mesh`, `mesh.node`, Node), which is iroh. The connection is direct when the network allows it, through a relay otherwise. The desktop app carries the addon in its bundled station. A client's endpoint is never announced. With relays, it looks stations up on the LAN and in the DHT.
- `salix-relay.ts`: Salix as the relay of last resort, for an endpoint bound with `salixRelay`. It opens Comma's client relay socket with a single-use ticket, proves the endpoint's id over the socket's challenge, and carries the endpoint's packets in binary frames. Each peer's packets go on the socket that the peer was last heard on.
- `wire.ts`: the `comma/mesh/1` protocol, both directions.
- `client.ts`: requests to peers. Keeps one connection per peer and opens a new one after the old one goes. Asks the caller for a credential at each hello and at each renewal. Says how each open connection runs (`nextVia`).
- `server.ts`: admits a connection by its credential (`verify`) and answers each request (`handle`).
- `memory.ts` (`@comma/mesh/testing`): endpoints in memory, for tests. Nothing in it is timed.

## What is not in this package

- What a credential is, who issues it, and what a principal may do. `verify` and `handle` belong to the caller.
- Device identity, enrollment and presence.
- The requests a station serves (paths and bodies).
- Which relays to use and where the addon is. The caller gives them to `bindNativeEndpoint`.

## Protocol `comma/mesh/1`

Each frame is a 4-byte big-endian length, followed by that many bytes of UTF-8 JSON. The limit is 64 KiB per frame.

1. The first bidirectional stream the client opens is the control stream. The client sends `{"type":"hello","version":1,"credential":…}`. The server answers `{"type":"welcome"}`, or `{"type":"refused","code","message"}`. After a refusal the connection serves nothing more.
2. The client may send `{"type":"credential","credential":…}` on the control stream. The server answers `renewed` or `refused`.
3. Each further stream the client opens carries one request. The client sends `{"type":"request","method","path","headers"}`, then the body bytes, then finishes its side. The server sends `{"type":"response","status","headers"}`, then the body bytes, then finishes. Instead of a response, the server can send one `{"type":"error","code","message"}` frame.
4. When a credential has expired, the server answers a request with error `credential_expired`. The client renews the credential once and sends the request again. It does this only if the body can be sent again (bytes or none).
5. Either side gives a request up by resetting or stopping its stream, with code 1 (`cancelled`). Code 2 (`protocol`) means the peer broke the protocol.

Error codes the mesh itself gives: `unauthorized`, `credential_expired`, `internal` (the handler failed; details stay on the server), `protocol`, `frame_too_large`, `unreachable`, `disconnected`, `cancelled`, `closed`. A `verify` that throws a `MeshError` gives the client that error's code and message.
