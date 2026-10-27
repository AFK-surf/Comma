# Comma Menu-Bar Host

This bundled macOS helper (`CommaMenuBarHost.app`) shows the Comma item in the
menu bar and its menu. It holds no credential, session, workspace or chat data.
AppKit tracks a menu on the main thread of its owner process. The main thread of
this helper is idle, so hovering the menu does not wait for Electron Main.

The helper keeps the bundle id it had when it also ran Side Chat
(`<app bundle id>.side-chat`, `menuBarHostBundleId` in `scripts/native-paths.ts`).
macOS keeps the item's place in the menu bar and its Menu Bar setting by that id.

Build it through the Electron package:

```sh
pnpm --dir clients --filter @comma/electron build:native
# The menu-bar helper only:
pnpm --dir clients --filter @comma/electron build:native:menu-bar
```

## Runtime contract

Electron Main (`NativeStatusMenuService`) starts the helper with only `LANG`,
`LC_ALL`, `LC_CTYPE` and `PATH`. The helper reads generated, newline-delimited
frames on stdin (`CommaStatusMenuHostFrame`) and writes generated frames on
stdout (`CommaStatusMenuClientFrame`). Diagnostics go to stderr.

- Main to the helper: `status-menu.show` and `status-menu.hide`.
- The helper to Main: `status-menu.ready` once it reads, `status-menu.select`
  with a chosen row's id, `status-menu.result` for each frame, and
  `status-menu.protocol-error` for a frame it cannot read (another protocol
  version, for example), which gets no result.

The helper exits when its stdin closes. Main starts it with the first menu and
closes its stdin when the menu-bar item is turned off, and kills it if it has
not ended 2 seconds later. A menu shown before that end waits for it, so two
items never show together.

## Menu-bar item

Electron Main owns the menu. `status-menu.show` carries the rows, the path of
the template icon, the tooltip, and the menu width in points; each new menu
replaces the shown one. The helper reports a chosen row as `status-menu.select`
with the row id and runs nothing itself. Any click on the item opens the menu;
while Quick Chat runs, the menu has its row. An `openId` is reported the same
way as the menu opens, so Main can say times from then and read usage again,
and a `closeId` once it has closed, after the chosen row's id. Quit is also a
row that Main runs. When the helper is lost
(it exits or cannot start), Main draws the menu with Electron's Tray until the
menu-bar item is next turned off and on, so the item and its Settings and Quit
rows stay usable.

No row has an AppKit key equivalent, so AppKit reserves no key-equivalent
column. A shortcut is secondary text, and an item's detail a grey capsule, at
a right-aligned tab stop; a long Task title ends with "…" at the right edge. A
`meter` row is a view with its detail at the same edge and, with a `fraction`,
an 8 pt bar below in a 52 pt row (red for `tone: critical`; a dot when nothing
is used). It draws its text 16 pt in, where macOS 26 draws a
row's title in a menu without images; other macOS versions are not measured.
Section headers show in capitals. The helper measures AppKit's padding on each
update, because it differs between macOS versions. Rows that arrive while the
menu is open update its rows in place where they can: a row with the same id
and kind, or the header or separator at its place, whose text fits the menu's
edge. A meter made without a bar shows a new one only after the menu closes.
The rest waits until it closes, since adding or removing items would move the
row under the pointer.

Packaged helper discovery is fixed below `Resources/native/macos`; repo and
cwd candidates are development-only.

## Validation

Run the real-process regression:

```sh
pnpm --dir clients --filter @comma/electron build:native:menu-bar
pnpm --dir clients exec vitest run apps/electron/test/native-build.test.ts -t "menu-bar helper"
```
