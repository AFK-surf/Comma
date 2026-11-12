---
name: shared-screen
description: Look at and act on a screen the user shared from Comma's screen panel (a picture with a comma:screen/<device>/<screen> link), or one you opened for them, such as an iOS Simulator, an Android emulator or phone, or a Mac or Windows display. Use when a message has such a link or asks you to reproduce what it shows.
metadata:
  displayName: Shared screen
---

# A shared screen

When the user shares a screen from Comma's screen panel, their message has:

- a picture of the stream frame the panel showed, as an image attachment, possibly resized for the attachment;
- a link alone on its line, `[<name> · <time>](comma:screen/<device>/<screen>)`, which names the screen and about when it was shared;
- on an iOS Simulator or an Android device, when Comma kept lines of its app's logs: `app-logs.txt`, up to the newest 100 lines, oldest first, each `<time> <level> <app>[<pid>]: <words>`.

The user may have dragged one or more red boxes on the picture to show where the problem is. The picture's file is then named `screen-<time>-marked.<ext>`. Those boxes are not part of the screen: read them as the user pointing, and look there first.

Read `app-logs.txt` when the picture does not explain the problem, and for crashes or errors. It is what Comma kept when the user pressed Send, not what the logs pane showed and not the moment of the picture: compare its times with the link's time. Lines can be later than the picture, or old when the pane was closed before. They can be one app's or the whole device's, as the pane's filter last was, and the user may have cleared earlier lines. To read more, use `env.exec` on that computer (`xcrun simctl spawn <udid> log show` on a simulator, `adb -s <serial> logcat -d` on Android). A share without the file means none were kept (an older Comma on that computer, a screen without logs, logs never read, or cleared): read them yourself, or ask the user.

Look at the picture first. Answer about what it shows, in the user's words. Do not ask the user to describe what the picture already shows.

The link says which screen it is: `<device>` is the computer's `device_id`, and `<screen>` (URL-encoded) is `display`, `android:<serial>` or `simulator:<udid>`.
Use the same screen to look again or act on it. Do not open another device.

## Act on the screen

Act only for what the user asked. Only the computer's owner can view its screens. If the person who asked is not that owner, say so.

- `android:<serial>`: use `env.android` with that `device_id`, the `environment` id that `device.get` gives for it (the one with `android_device_tool`), and `target="android:<serial>"`. Start a lease, `observe` for a fresh screenshot, then tap, swipe, type or press keys in the screenshot's pixels, and `end` the lease. A person who drives the device in Control comes first: your input waits for them, or fails with `android_held_by_person`. Then wait and try again.
- `display` on a Mac or Windows computer: use `env.computer_use` with that device's environment that has `computer_use_tool`. Use background mode on the app the picture shows. Use foreground mode only when the app has no usable accessibility tree, and tell the user first.
- `simulator:<udid>`: use `env.screen` with that `device_id`, the `environment` id that `device.get` gives for it (the one with `screen_device_tool`), and `target="simulator:<udid>"` (the link's `<screen>`, URL-decoded). Start a lease, `observe` for a fresh screenshot, then tap, swipe, type or press keys (`home`, `lock`, `enter`, ...) in the screenshot's pixels, and `end` the lease. The first start in a chat shows the computer's owner a card to allow it; wait for the answer. A person who drives the simulator in Control comes first: your input fails with `screen_held_by_person`. Then wait and try again. You can still `observe` then. `env.screen` does not start apps: use `env.exec` on that computer for what `xcrun simctl` does (`launch`, `openurl`). On `screen_capability_missing`, Comma on that computer is older: ask its owner to update it. Until then, use `env.exec` for a fresh picture (`xcrun simctl io <udid> screenshot <path>`) and ask the user to do the taps you need, step by step, in the screen panel.
- A computer with none of these tools, or an older Comma there: say in one sentence what is missing (for example, update Comma on that computer), and work from the picture.

After you act, say what you did and what the screen shows now. Do not post the screen's link again.
