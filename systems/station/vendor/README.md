# vendor

`scrcpy/LICENSE` is the Apache-2.0 license of scrcpy's server, which the release carries (`docs/android-screen.md`). The
file itself is a native part (`scripts/native.ts`), not here.

`serve-sim` is the iOS Simulator's capture and input, from EvanBacon/serve-sim at 0193e65 (`packages/serve-sim/Sources`,
Apache-2.0) through still.fail's `vendor/serve-sim`. It holds only `SimDuoHID/main.m`,
`SimNative/{FrameCapture,HIDInjector,DeviceHubKeyboardBridge,DuoHIDBridge,PixelBufferUtils,SimFrameworks,Xcode}.swift` and
the `SimNativeSupport` they use. `Package.swift` is ours. `DTUHIDKeys.swift` and `Shared.swift` come from still.fail. The
Computer Use helper uses it (`docs/simulator-screen.md`). HIDInjector's `sendHardwareButton` (a button by its HID usage,
held as long as a person holds it) is still.fail's. `src/screens/sim-chrome.ts` lays out the device's case as serve-sim's
TypeScript does (`packages/serve-sim/src/devicekit-chrome.ts`, `device-displays.ts`), through still.fail's port.

Crates taken from crates.io and changed for Comma; `[patch.crates-io]` in native/mesh/, tools/load/ and the clients'
mesh crates (clients/packages/mesh/native, clients/packages/mesh/wasm) points at them. Each
change is marked `ember:` in the source. Drop a crate here once upstream has the same.

iroh and iroh-relay are not here: they come from still.fail's fork, github.com/zzj3720/iroh (branch `stillfail`), at
one rev that every `[patch.crates-io]` here names, with the noq-proto fork it builds with (github.com/zzj3720/noq).
A change to iroh goes into that fork, and the rev here moves to it.

- **swarm-discovery 0.6.3**
  - src/receiver.rs: a peer's addresses are read from the answers as well as the additionals, and records with
    mDNS's cache-flush bit count as class IN. A router reflecting mDNS between subnets sends the addresses on as
    answers, which 0.6.3 dropped, so a station on the other subnet was never found.
  - src/sender.rs: the first query goes out 20–120 ms after starting (RFC 6762 §5.2) instead of a whole cadence
    (0.7 s, pushed back further by others' queries) later.
  - src/socket.rs: a failed send on one interface (a VM bridge that takes no multicast) is logged at debug, not
    error, and failing on every interface is said once when it starts (and once when it ends), not with every
    announcement: both recur with each one (twice a second on a Mac that denies the process the local network).
- **iroh-mdns-address-lookup 0.4.0** (src/lib.rs)
  - Multicast goes out on, and is received from, every local IPv4 interface (swarm-discovery's `add_interface_v4`),
    not only the default route's. A machine on two networks (studio: wired 192.168.0.x, Wi-Fi 192.168.20.x) was
    only announced on the first.
  - Without advertising (ember's devices: they only look stations up), the interfaces are still joined.
  - A republish (same addresses and TXT) is not a new discovery: `Peer`'s equality includes when it was seen, so
    every mDNS packet reached the endpoint as new addresses (also reported upstream-side in rayfish/rayfish#161).
- **n0-mainline 0.6.0** (src/actor/socket.rs; the phones' mesh only, clients/packages/mesh/native: the DHT lookup of
  iroh-mainline-address-lookup), from still.fail's vendor/n0-mainline (AFK-surf/still.fail b91a2d754)
  - A read that fails backs off (50 ms, doubling, at most 2 s), the next read's time kept on the socket so the actor's
    select dropping a read for another branch does not cut the wait short; from the third failure in a row (~150 ms
    after the first) the socket is bound anew, the old one closed first so its port can be taken again, else on
    another. It went straight back to the actor's loop, the socket still readable: an iPhone back from the
    background kept a core busy (hot, and reaching no station) until the app was killed. Upstream's 0.7.1 still
    returns at once.
- **noq-udp 1.3.0** (src/linux.rs): no UDP segmentation offload (GSO) on Android, each datagram sent on its own. An
  Android emulator's network accepts a segmented burst and drops all of it; QUIC on a direct path then got nothing
  through once it sent more than a packet or two at once, until iroh dropped the path 15 s later. The phones' iroh
  (clients/packages/mesh/native) uses this crate too.
- **noq-udp 1.3.0** (src/unix.rs): on Apple platforms a datagram's source address is set with `IP_PKTINFO`. It was
  set with `IP_RECVDSTADDR`, which macOS ignores on send, so a reply left from the address the routing table picked.
  On a machine with two addresses on one network (studio: 192.168.20.10 on the wired VLAN, 192.168.20.107 on Wi-Fi) a
  device that had dialed one got the answer from the other, and the handshake never finished: the station dropped
  what came back as sent to the wrong interface.
- **noq-udp 1.3.0** (src/unix.rs, src/apple_fast.rs): `recv_single` re-prepares `msghdr` before each `recvmsg` and
  checks receive errors before `MSG_TRUNC` (backport of n0-computer/noq#884 / GHSA-6pp4-4cxf-xf88), because
  `netwatch` never calls `set_apple_fast_path` so Apple targets receive through `recv_single` and a single datagram
  larger than the 1472-byte buffer followed by `EAGAIN` left `MSG_TRUNC` set and spun a core at 100%. Both
  `recv_single` (`n == 0` with `msg_namelen == 0`) and `recv_via_recvmsg_x` (`msg_count == 0`) return `WouldBlock` on
  `SS_CANTRCVMORE` EOF so tokio clears readiness instead of reading an uninitialized peer address or spinning on
  `Ok(0)`.
