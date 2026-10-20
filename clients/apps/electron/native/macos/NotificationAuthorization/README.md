# Notification Authorization

This macOS-only Node-API addon gives Electron Main the parts of
`UNUserNotificationCenter` that Electron does not expose. It reads the current
authorization status, asks the user for permission and waits for the answer, and
sets the app icon badge.

It must run inside Comma's own process. macOS tracks notification authorization
per bundle, so a spawned helper can only report its own status.

Electron shows a banner without waiting for the authorization answer. While the
status is `notDetermined`, the first banner races the system prompt and macOS
refuses it. Comma therefore requests authorization before its first banner and
shows it only after the OS says yes (`message-notifications-platform.ts`).

## Main-process API

```ts
const addon = loadNotificationAuthorizationAddon({
  isPackaged: app.isPackaged,
  logger,
});
await addon.authorizationStatus();
// "notDetermined" | "denied" | "authorized" | "provisional" | "unavailable"
await addon.requestAuthorization();
// the status the user's answer leaves behind, same names
await addon.setBadgeCount(3);
// "shown" | "cleared" | "unavailable"
```

`requestAuthorization()` shows the system prompt only while the status is
`notDetermined`. A decided status answers from the OS record. `unavailable`
means the process has no bundle (a bare `node`), the addon is not built, or the
query failed.

A request that returns `notDetermined` means the OS declined to ask. This
happens for a from-source `Electron.app`, which shares `com.github.Electron`
with other checkouts, and for an unsigned package, which shares its bundle id
with the installed signed app. Such a build cannot post notifications. Main
logs it and skips the banner.

`setBadgeCount()` uses the UserNotifications badge, not Electron's
`app.setBadgeCount()`, so it respects the "Badge application icon" switch in
System Settings. When the switch is off, the addon clears the badge.

Main reads `notDetermined` back as `undetermined`. Settings treats only `denied`
as "turned off in System Settings". The first-launch onboarding can show the
prompt earlier through `appPreferences.requestNotificationAuthorization`.

## Building

`pnpm build:native` builds it with the rest of the native tree.
`pnpm build:native:notification-authorization` rebuilds only this addon. The
binary goes to `dist/native/macos/comma-notification-authorization.node`.
Forge packages it outside ASAR through the existing `dist/native` extra
resource.
