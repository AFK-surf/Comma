# Font families

This macOS-only Node-API addon gives Electron Main two CoreText answers. It
lists the font families installed on this Mac, which Settings > Appearance >
Font shows. It also measures text in the menu-item font, which the menu-bar
menu uses to cut long Task titles.

## Why Main asks CoreText

The renderer can ask Chromium through Local Font Access (`queryLocalFonts`).
That API builds one record per font face with its display names. On a Mac with
about 1,600 faces, the first read in each renderer takes about 3 seconds, and
the API needs a permission. The Font menu needs only family names.

`CTFontManagerCopyAvailableFontFamilyNames` returns the same families in about
40 ms. The names are not localized under any system language, so CSS family
matching accepts them. CoreText is thread-safe. The query runs on a libuv
worker, so the JS thread of Main does not wait for it. The addon does not start
a process or read font files.

## Menu text width

`menuTextWidth(text)` returns the width in points of `text` in the font AppKit
draws menu item titles with. The menu-bar menu uses it to cut long Task titles
so that they end at one edge.

CoreText's menu-item UI font (`kCTFontUIFontMenuItem`) is the same face and
size as `NSFont.menuFont`. Its widths equal AppKit's, including the per-glyph
fallback for CJK text and emoji. The call is synchronous: one short line layout
takes about 20 µs. It reads the font on each call, so it follows a change to the
system text settings. The result is `null` on other platforms and for a binary
built before this function existed.

## Main-process API

```ts
const addon = loadFontFamiliesAddon({ isPackaged: app.isPackaged, logger });
await addon.familyNames();
// ["Academy Engraved LET", "American Typewriter", …], or null
addon.menuTextWidth("Open Comma");
// 82.7, or null
```

The result is `null` when the addon cannot answer: on other platforms, or when
the addon is not built. The `appearance.fontFamilies` capability then reports
no list, and Appearance shows only the default typeface.

## Build

The full native build and the from-source start hook build this addon. A
focused build is available with:

```sh
pnpm --dir clients --filter @comma/electron exec node --import tsx scripts/build-native.ts --font-families-only
```
