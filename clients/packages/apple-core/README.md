# CommaCore

Swift 6 transport, authentication, and conversation state for the native Apple apps.
Foundation URLSession and Security Keychain provide HTTP and credential custody.
The package has no third-party runtime dependencies.

`Transport.swift` holds the incremental SSE codec. It bounds frames and queues before
event publication and keeps exact-connection cancellation.

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
