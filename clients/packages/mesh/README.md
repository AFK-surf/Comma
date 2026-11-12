# @comma/mesh

Direct connections between a Comma client core and a station, and the protocol on them. The client core uses the client half (`MeshClient`). A station uses the serving half (`serveMesh`).

## What is in this package

- `link.ts`: the QUIC surface the mesh needs (`MeshEndpoint`, `MeshConnection`, `BiStream`). A peer is named by its endpoint id, an Ed25519 public key. A connection can say how it runs (`nextVia`: direct, an iroh relay, or Salix) and tells each change.
- `native-link.ts`: that surface on an iroh binding that answers as the station's addon does. The desktop's and the browser's bindings both answer so.
- `station-native.ts` (`@comma/mesh/station-native`): that surface on the station's native addon (`systems/station/native/mesh`, `mesh.node`, Node), which is iroh. The connection is direct when the network allows it, through a relay otherwise. The desktop app carries the addon in its bundled station. A client's endpoint is never announced. With relays, it looks stations up on the LAN and in the DHT. With `salixOnly`, it has no IP path and no relay, and reaches stations through Salix alone, to test that path.
- `native/` (Rust, `comma-mesh-native`): the same endpoint for the phones, linked into the client core's engine (`clients/packages/core/native/engine.cpp`) as a static library. The engine answers the core's `mesh.*` operations with it (`clients/packages/core/src/hosts/mobile-mesh.ts`). It is the station's iroh with the same settings and the station's Salix transport, and it carries Salix's sockets itself. It does not look stations up by mDNS: a phone dials the addresses the control plane gives. `systems/station/scripts/native.ts` builds it (part `client-mesh`, for `android-arm64`, `ios-arm64` and `ios-sim-arm64`), and the Android and iOS builds fetch it prebuilt. A build that cannot get it reaches no station.
- `wasm/` (Rust, `comma-mesh-wasm`) and `web.ts` (`@comma/mesh/web`): the same endpoint in the browser, through iroh relays and Salix only, because a browser has no UDP. The web app's core worker loads it the first time it reaches a station (`clients/apps/web/vite.config.ts`, `virtual:comma-mesh`). `systems/station/scripts/native.ts` builds it (part `web-mesh`, target `wasm32`, with the Android NDK's clang). A build that cannot get it reaches no station.
- `salix-relay.ts`: Salix as a relay, for an endpoint bound with `salixRelay`. By default (`salix-first`) it ranks with direct paths and races them by round trip, with an iroh relay as the backup; with `relay-first` it goes last. What the control plane says (`route_policy`) picks, read only at bind: a change needs a rebuilt endpoint and moves nothing already open. Under `relay-first`, a local test found Salix took over about 30 seconds after the relay went down, and an open connection did not move back within 60 seconds of its return. A socket holding more than 128 KiB unwritten takes no more packets (it can pass that by one), and QUIC sends them again. That bounds the backlog and does not put control first: packets and control messages share the socket. It opens Comma's client relay socket with a single-use ticket, proves the endpoint's id over the socket's challenge, and carries the endpoint's packets in binary frames. Each peer's packets go on the socket that the peer was last heard on. The caller gives it how to sign with the endpoint's key: Node's crypto on the desktop, the browser build on the web.
- `wire.ts`: the `comma/mesh/1` protocol, both directions.
- `client.ts`: requests to peers. Keeps one connection per peer and opens a new one after the old one goes. Asks the caller for a credential at each hello and at each renewal. Says how each open connection runs (`nextVia`).
- `server.ts`: admits a connection by its credential (`verify`) and answers each request (`handle`).
- `screen-wire.ts`: the frames of a view of a station's screen, both directions (below).
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

## Views of a screen

A view runs on one `comma/mesh/1` request stream, and frames go in both directions for as long as it lasts. `screen-wire.ts` says the frames, which are still.fail's (`config`, `video`, `state`, `input`, `ack`, `keyframe`), and `control`.

- `GET /screens` lists what can be viewed. A station from before answers 404. Do not send a view to a station that did not list the screen: it reads a request's whole body first, and a view's body does not end.
- `GET /screens?devices=1` also lists the computer's Android devices (`android:<serial>`, with what each can do) and the virtual devices that could start, which wakes its adb. `POST /screens/start` starts one, `POST /screens/<id>/close` closes one.
- `POST /screens/<id>/view` carries what it asks in the `x-comma-screen` header. The station answers 200 `application/x-comma-screen`, or a status with `{error}` (403 when the computer's access is not Full).
- The station sends a frame only while its pace lets one go, by the client's `ack`s of what it has shown (`systems/station/src/mesh/screen-pace.ts`). A client that sends none gets two frames.
- A capture refusal ends the view with `state.ended` and `endedCode: "screen_refused"`. The client shows the reason and waits for a manual retry. A lost connection has no `endedCode` and keeps the normal reconnect policy.
- Watch and Control are a state of the open view. The ask's `control` sets it at the start. A `control` frame (`{control: boolean}`) changes it while the view runs, and the station answers with a `state` of `control`. The picture continues: the station opens no new capture and asks for no key frame or new rate.
  - Watch takes effect at once: the station drops each input event that comes after it.
  - For Control, the station checks the credential (unexpired, not revoked, the computer's owner), access Full, that the member may drive, that the view is not a preview, and, for a device, that the list still gives the same source for its id, with the instance the view opened. It does not read the device's boot again, as a view's opening does. A device replaced after that check is the accepted race of `systems/station/docs/android-screen.md` ("Which device"). When the station refuses Control, the `state` has `refused` with the reason, and the view stays on Watch.
  - The station checks each input event against the view's state when the event arrives.
  - The first `state` has `switches: true`. A station from before does not send it and ignores a `control` frame. To go from Watch to Control on such a station, the client opens a new view. From Control to Watch it keeps the open view, and the page stops sending input.
- A view of a device that an agent can lease gets two more `state` fields. `agent` says whether a lease lasts: the station sends it after the first `state` and each time a lease starts or ends. `agentPointer` (`{x, y, down}`, 0..1 of the picture) says where the agent's finger is as it presses, moves and lifts. A preview gets neither, and a station from before sends neither.
- The bit rate goes up to the picture's pixels × 16 a second (`rateCeiling`, at most 60 Mbit/s; 1080p is 33), and to 8 Mbit/s at most while the connection goes through Salix, whose relay passes 4 MiB/s a connection and 2 MiB/s a node for all its connections. A preview goes no higher than the source's own rate (pixels × 3).
- The ask's `quality` is the 画质 the person chose: `smooth` (流畅), `hd` (高清) or `original` (原画). No `quality` is 自动. 流畅 lowers the bit rate's ceiling to pixels × 6. The station does not make 原画's picture smaller for a slow link; the source's own largest size still applies. The 8 Mbit/s request bound through Salix applies to every 画质. The station ignores a value that it does not know, and a preview's. `systems/station/docs/desktop-screen.md` ("Picture quality") has the full rules.
- Every field of the ask is optional except `codecs` and `control`. A station from before ignores `quality`, so the view is 自动. A client from before sends no `quality`, so the view is 自动. Stations and clients update at different times, so a new field must not be required.
- The desktop's pictures leave the pointer out. The station sends it in `state.cursor`, and the page draws it in its shape. While the person's own mouse is over the picture and drives it, that mouse shows the shape instead. `state.video` and `state.latency` feed the toolbar's statistics.

The station's side is `systems/station/src/mesh/screens.ts`. The client's side is `clients/packages/core/src/screen-views.ts` and, in the page, `clients/packages/app/src/components/remote-screen/meshScreenStream.ts`. Every client takes this way: the desktop app and the browser decode in the page, and the iOS and Android apps decode natively (`clients/apps/apple/iOS/Remote/PhoneMeshScreen.swift`, the Android app's screen view).
