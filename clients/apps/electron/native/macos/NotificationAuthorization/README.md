# Notification Authorization

This macOS-only Node-API addon gives Electron Main the parts of
`UNUserNotificationCenter` that Electron itself leaves open: it reads the current
authorization status, asks the user for permission and waits for the answer, and
sets the app icon badge.

It has to run inside Comma's own process. Notification authorization is tracked
per bundle, so a helper executable (Swift, `osascript`, anything spawned) could
only ever report _its_ status. The `com.apple.ncprefs` mirror System Settings
keeps is undocumented and was rejected.

## Why Comma asks itself

Electron's macOS notification presenter fires `requestAuthorizationWithOptions:`
when it is first created, but never awaits the answer: `Notification.show()`
calls `addNotificationRequest:` straight away. On a process whose status is
still `notDetermined` that first banner races the system prompt and is refused
with `UNErrorDomain error 1`; Electron reports it only through a `failed` event
whose text is localized. Comma therefore requests authorization before its first
banner and shows only once the OS has said yes (`message-notifications-platform.ts`).

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
`notDetermined`; a decided status answers from the OS record in a millisecond,
so asking before every first banner is free. `unavailable` is the answer when
the process has no bundle to ask for (a bare `node`), when the addon is not
built, or when the query itself fails.

A request that comes back `notDetermined` means the OS declined to ask at all.
It does that for a bundle it cannot pin down: a from-source `Electron.app`
shares `com.github.Electron` with every other checkout on the machine, and an
unsigned package shares its bundle id with the installed, signed app. Such a
build cannot post notifications; Main logs it and skips the banner rather than
letting Electron refuse it silently.

`setBadgeCount()` uses the UserNotifications badge, not Electron's
`app.setBadgeCount()`. Electron writes the Dock tile directly, which ignores the
"Badge application icon" switch in System Settings. The addon reads that switch
first and clears the badge when the switch is off.

Settings treats only `denied` as "turned off in System Settings"; an undecided
status is still enableable, and the prompt comes with the first banner.

## Building

`pnpm build:native` builds it with the rest of the native tree;
`pnpm build:native:notification-authorization` rebuilds just this addon. The
compiled binary is copied to `dist/native/macos/comma-notification-authorization.node`,
which Forge packages outside ASAR through the existing `dist/native` extra
resource.
