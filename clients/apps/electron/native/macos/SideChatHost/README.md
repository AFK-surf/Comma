# Comma Side Chat Gesture Host

This bundled macOS helper is the thin native input partner for Comma's Electron
side-chat window. It does not render chat UI, own messages, hold credentials,
or create a visible AppKit/SwiftUI window. Electron owns the side-chat window
and all product UI.

The separate `../SideChatBackdrop` Node-API addon is the only native visual
piece. It installs the original feathered `CABackdropLayer` inside the same
Electron `NSWindow`; this helper never coordinates a second blur or overlay
window.

The helper remains native for one narrow reason: Comma's left-edge two-finger
interaction reads physical contacts from `MultitouchSupport.framework` before
an Electron window is visible. Electron's public swipe event is a discrete
three-finger window event and cannot preserve that interaction.

Build it through the Electron package:

```sh
pnpm --dir clients --filter @comma/electron build:native
# Side Chat helper + backdrop only:
pnpm --dir clients --filter @comma/electron build:native:side-chat
```

## Runtime contract

Electron starts the host without an API URL, bearer token, workspace, or chat
snapshot. The host reads generated, newline-delimited control frames on stdin
and writes only generated protocol frames on stdout. Diagnostics go to stderr.

Supported controls are:

- `side-chat.open`
- `side-chat.close`
- `side-chat.toggle`
- `side-chat.layout`
- `side-chat.interactive-progress`
- `side-chat.interactive-complete`
- `side-chat.shortcut`
- `side-chat.stop`

The helper emits `side-chat.presentation` snapshots containing a monotonic
helper-local revision, reveal phase and progress, the exact horizontal content
offset, and the AppKit screen/content/window frames. Electron Main converts the
AppKit coordinates to Electron display coordinates and republishes a separate
Main-lifetime monotonic revision. The same-window addon atomically applies the
emitted horizontal offset to both its backdrop/mask and every Chromium content
sibling. The renderer consumes phase, progress, available height, and the
content/window layout, but must not apply a second horizontal transform. A
helper restart may begin again at revision `1` without moving renderer state
backward.

`side-chat.layout` also carries the Main-owned, process-local geometry subset
of the former native Debug settings. Width, feather/outset padding, content
origin, open X, bottom offset, and closed extra distance are therefore applied
by the helper before it publishes the next presentation; they are not fixed
constants and are never persisted by this process.

The gesture constants and settling thresholds intentionally match the original
native side-chat implementation. A third contact cancels an active gesture and
settles to the last stable endpoint so the Electron window cannot remain
partially revealed.

The helper's reveal state machine is the single owner for the native trackpad
edge gesture. The renderer does not install a panel-wide pointer recognizer, so
mouse drags remain available for normal browser interactions such as selecting
message text.

Wire types are generated from `nativePartnerProtocolRegistry`; do not add
handwritten Codable mirrors. Regenerate after changing the native-partner leaf:

```sh
pnpm --dir clients --filter @comma/native-bridge generate:partners
```

The helper registers Control-Z as the default global hotkey and accepts
`side-chat.shortcut` controls from Electron Main to replace it. Main sends the
stored shortcut again after every bounded helper restart. The helper must not
grow renderer behavior, chat commands, settings UI, a status item, or any
authentication/data access.

Electron Main treats renderer crash/load failure/unresponsiveness and every
backdrop attach/geometry/reveal/health failure as fail-closed: it hides the
window and locally converges presentation to `closed` before any bounded window
recreation. Packaged helper discovery is fixed below
`Resources/native/macos`; repo/cwd candidates are development-only.

## Validation

The real-process regression builds the artifact and verifies ready/layout,
interactive progress and completion to both endpoints, explicit open/close
presentation convergence, protocol mismatch, stdin shutdown, minimum macOS
version, and packaged discovery:

```sh
pnpm --dir clients --filter @comma/electron build:native:side-chat
pnpm --dir clients exec vitest run apps/electron/test/native-side-chat-host.test.ts
```

Gesture parity still requires a real physical trackpad smoke test: exactly two
contacts from the left edge, continuous reveal in both directions, three-finger
cancellation back to the last stable endpoint, and no half-open residue. A
synthetic Electron swipe event is not equivalent evidence.
