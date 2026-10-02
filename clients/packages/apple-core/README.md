# CommaCore

Swift 6 transport, authentication, and conversation state for the native Apple apps.
Foundation URLSession and Security Keychain provide HTTP and credential custody.
The package has no third-party runtime dependencies.

`Transport.swift` isolates the incremental SSE codec.
URLSession provides bytes but no SSE decoder.
We evaluated [LDSwiftEventSource](https://github.com/launchdarkly/swift-eventsource).
Its [event parser](https://github.com/launchdarkly/swift-eventsource/blob/main/Source/EventParser.swift) accumulates data without a frame-size limit.
Comma requires bounded frames and queues before event publication.
The isolated codec enforces those bounds and preserves exact-connection cancellation.
Transport/state tests exercise chunked UTF-8, CRLF, malformed frames, cancellation, reconnect, and canonical draft recovery.
Backend HTTP tests exercise the corresponding authorized SSE snapshot contract.

Run tests from the repository root:

```sh
swift test --package-path clients/packages/apple-core
```

Use explicit cache paths when the shell sandbox cannot write default Swift caches:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/comma-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/comma-swift-cache \
swift test --package-path clients/packages/apple-core \
  --scratch-path /tmp/comma-apple-core-build \
  --cache-path /tmp/comma-swiftpm-cache --disable-sandbox
```

[Native client contracts](../../../docs/clients.md#native-apple-clients) own the product behavior and request budgets.
