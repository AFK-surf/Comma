# Sleep Guard

The sleep guard keeps a Mac awake with the lid closed while Comma runs. It
backs the "Keep awake with lid closed" setting.

## Why a privileged daemon

Power assertions (`caffeinate`, `powerSaveBlocker`, `IOPMAssertion`) stop
idle sleep only. Closing the lid starts clamshell sleep, which ignores
assertions. Only the kernel's `SleepDisabled` flag, set by
`pmset -a disablesleep 1`, overrides clamshell sleep. Setting the flag requires
root.

The flag is system-wide and persists until something clears it. Comma must
not leave it set after Comma quits or crashes. A root daemon that holds the
flag per XPC connection gives that guarantee: when Comma's process ends, the
kernel closes the connection and the daemon clears the flag.

## Parts

- `Sources/CommaSleepGuard`: the daemon. launchd starts it as root on the
  first connection to its Mach service. It accepts only clients signed by the
  same team as itself, with Comma's bundle identifier. An ad-hoc signed
  development build checks the bundle identifier only. It sets the flag for
  the first holder and clears it after the last holder leaves. It does not
  clear a flag that was already set before Comma set it. It exits after 30
  seconds without clients.
- The flag is stored on disk and survives a reboot. While a daemon holds the
  flag for Comma, it keeps a marker file in `/var/db/comma-sleep-guard`, one
  per app flavor. When the daemon starts, it removes its own marker and clears
  the flag if no other marker remains. The daemon does the same on SIGTERM.
  launchd starts the daemon at boot (`RunAtLoad`), so a flag left after a
  power loss is cleared even if Comma does not start again.
- All flavors share the one system flag. A daemon clears the flag only after
  the last marker is gone, so quitting one flavor does not wake the Mac under
  another. Every marker check and flag write runs under an `flock` on
  `/var/db/comma-sleep-guard.lock`, so two flavors cannot interleave them. A
  daemon removes its marker only after the flag is clear, so an interruption
  in between leaves the next start something to recover.
- `src/sleep_guard.mm`: the Node-API addon for Electron Main. It reads and
  registers the daemon with `SMAppService`, opens Login Items when Settings
  asks, and keeps the XPC connection open while the setting is on.
- `scripts/sleep-guard-launchd.ts`: writes the LaunchDaemon plist into
  `Contents/Library/LaunchDaemons` during packaging. The label and Mach
  service are `<app bundle id>.sleep-guard`, so each app flavor has its own
  daemon.

## Approval

macOS requires the user to approve the daemon once in System Settings ›
General › Login Items. Comma reads the approval back as
`keepAwakeWhenLidClosedStatus`. Main reads it when it opens and on each
renderer state read, for example when a window gets focus. Comma does not
persist the status.

- macOS reports a daemon that was never registered as `notFound` or
  `notRegistered`. Comma shows both as `not-registered`.
- When the user turns the setting on, Comma registers the daemon if
  necessary. If macOS waits for approval, Comma keeps the choice and
  Settings shows a dialog. The dialog opens Login Items. If the user
  cancels the dialog, Comma withdraws the choice.
- When the user returns after approval, the next readback holds the flag
  and the setting shows on. The user does not turn it on again.
- If the user turns the daemon off in Login Items, launchd stops the
  daemon, and the daemon restores sleep. The next readback releases the
  hold and keeps the choice for a later approval.
- At launch, Comma resumes only an approved daemon. It does not register
  the daemon or open System Settings.
- If registration fails, the error includes the reason from macOS.

## Building

`pnpm build:native` builds the daemon and the addon into `dist/native/macos`.
Forge packages them through the existing `dist/native` extra resource, and
`scripts/sign-macos-app.ts` signs the daemon with the app.
