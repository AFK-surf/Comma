# Comma Side Chat Gesture Host

This bundled macOS helper is the thin native input partner for Comma's Electron
side-chat window. It does not render chat UI, own messages, or hold
credentials. Its only visible AppKit UI is the menu-bar item (see
[Menu-bar item](#menu-bar-item)). Electron owns the side-chat window and all
other product UI.

The separate `../SideChatBackdrop` Node-API addon is the only native visual
piece of Side Chat. It installs the original feathered `CABackdropLayer` inside
the same Electron `NSWindow`; this helper never coordinates a second blur or
overlay window.

The helper remains native for two narrow reasons. Comma's left-edge two-finger
interaction reads physical contacts from `MultitouchSupport.framework` before
an Electron window is visible. Electron's public swipe event is a discrete
three-finger window event and cannot preserve that interaction. The menu-bar
menu needs a main thread that Electron Main does not share.

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
- `side-chat.enabled` (off drops the edge gesture and the global shortcut and
  closes the surface; Main sends it before the shortcut replay)
- `status-menu.show`
- `status-menu.hide`

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
grow renderer behavior, chat commands, settings UI, or any authentication/data
access.

## Menu-bar item

On macOS the helper also shows the Comma item in the menu bar and its menu.
AppKit tracks a menu on the main thread of the process that owns it. In
Electron Main that thread also runs the product runtime, and its tasks delayed
the hover highlight by up to about 190 ms. The main thread of this helper is
otherwise idle. This changes the earlier rule that the helper has no status
item; the change was decided on 2026-10-01 to keep the menu hover off Main's
thread.

Electron Main owns the menu. `status-menu.show` carries the rows, the path of
the template icon, the tooltip, and the menu width in points. Main sends it
again after every helper restart, and `status-menu.hide` removes the item. The
helper reports a chosen row as `status-menu.select` with the row id and runs
nothing itself. Quit is also a row that Main runs. When the running helper is lost
(it exits, its stream fails, or Main kills it, for example because another app
took the saved shortcut), Main draws the menu with Electron's Tray until the
menu-bar item is next turned off and on, so the item and its Settings and Quit
rows stay usable.

No row has an AppKit key equivalent, so AppKit reserves no key-equivalent
column. A shortcut is secondary text at a right-aligned tab stop, and a long
Task title ends with "…" at the right edge. The helper measures AppKit's
padding on each update, because it differs between macOS versions. Rows that
arrive while the menu is open wait until it closes.

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
