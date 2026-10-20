# caBLE Scanner

This macOS-only Node-API addon lets Electron Main sign in with a passkey from a
phone. After the phone scans the QR code of a browser tab, it broadcasts a
Bluetooth LE advert. The advert proves that the phone is near this Mac and
carries the tunnel routing ID. The addon reports these adverts to Main.

The addon only listens. It does not connect to the phone and holds no keys. Main
decrypts each advert with the key of its own QR code and ignores all others
(`src/main/modules/browser-sidebar/hybrid`).

## What it reports

- It scans like Chromium: no service filter, duplicates allowed.
- It reports an advert when service data under UUID `FFF9` (FIDO) or `FDE2`
  (Google, sent by iOS 16) is exactly 20 bytes long.
- It reports each Bluetooth state change as `on`, `off`, `denied`,
  `unsupported` or `pending`.

The first scan creates the `CBCentralManager`. Creating it shows the macOS
Bluetooth prompt for Comma. Use `NSBluetoothAlwaysUsageDescription` in
`forge.config.ts` for the prompt text. `authorization()` reads the decision
without asking for it.

## Main-process API

```ts
const addon = loadCableScannerAddon({ isPackaged: app.isPackaged, logger });
addon.scan(
  {
    advert: (data) => {}, // 20 bytes
    state: (state) => {}, // "on" | "off" | "denied" | "unsupported" | "pending"
  },
  signal
);
```

Concurrent scans share one CoreBluetooth scan. The scan stops when the last
signal aborts.

## Building

`pnpm build:native` builds the addon with the rest of the native tree.
`pnpm build:native:cable-scanner` builds only this addon. The binary goes to
`dist/native/macos/comma-cable-scanner.node`. Forge packages it outside ASAR
through the existing `dist/native` extra resource.
