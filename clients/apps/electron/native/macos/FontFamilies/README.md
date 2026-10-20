# Font families

This macOS-only Node-API addon gives Electron Main the names of the font
families installed on this Mac. Settings > Appearance > Font lists them.

The addon calls `CTFontManagerCopyAvailableFontFamilyNames` on a libuv worker.
The renderer does not use Local Font Access (`queryLocalFonts`), because it is
slow and needs a permission. The addon does not start a process or read font
files.

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
