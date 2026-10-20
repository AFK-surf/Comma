# Keychain password

This macOS-only Node-API addon gives Electron Main the password of one generic
keychain item. Settings > Browser uses it to import sign-ins from another
Chromium browser. That browser encrypts cookie values with a key that it keeps
as the "<browser> Safe Storage" item, for example `Chrome Safe Storage`.

## Why Main asks the Security framework

When Comma reads the item, macOS asks the user to allow it, and the prompt names
Comma. Do not use the `security` command-line tool for this read. Its prompt
names `security`. If the user selects "Always Allow", every process that runs
`security` can then read the key without a prompt.

The addon calls `SecItemCopyMatching` on a GCD queue, so Main does not wait for
the user's answer. The addon does not write keychain items and does not start a
process.

## Main-process API

```ts
const addon = loadKeychainPasswordAddon({ isPackaged: app.isPackaged, logger });
await addon.readGenericPassword("Chrome Safe Storage", "Chrome");
// { status: "found", password } | { status: "missing" | "denied" | "failed" }
```

The result is `failed` when the addon cannot answer: on other platforms, or
when the addon is not built. The import then reports a failure.

## Build

The full native build and the from-source start hook build this addon. A
focused build is available with:

```sh
pnpm --dir clients --filter @comma/electron exec node --import tsx scripts/build-native.ts --keychain-password-only
```
