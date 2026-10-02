# Font families

This macOS-only Node-API addon gives Electron Main the names of the font
families installed on this Mac. Settings > Appearance > Font lists them.

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

## Main-process API

```ts
const addon = loadFontFamiliesAddon({ isPackaged: app.isPackaged, logger });
await addon.familyNames();
// ["Academy Engraved LET", "American Typewriter", …], or null
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
