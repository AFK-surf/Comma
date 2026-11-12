---
name: show-screen
description: Show the user a live screen in the chat, as a card they open and drive in Comma. Use when they ask to see an app, an iOS Simulator, an Android emulator or phone, or their computer's screen (我要看 simulator, 启动起来我看看, show me the app). Do not send screenshots instead.
metadata:
  displayName: Show a screen
---

# Show a screen

A message line that is only a screen's link becomes a live card of that screen in Comma.
The owner of the computer opens it, watches it and drives it from the chat.
Use the card when the user wants to see an app, a simulator or a screen. Do not send screenshots or a screen recording instead.

Post the card yourself, in the conversation where the user asked, as soon as the device runs. Do not wait for a build, and do not leave the card to a Task: the card shows the app when it lands.

1. Find the computer. Use the initiating Message's `client_device` when the user means "my Mac" or "this computer". Otherwise use `device.list`, then `device.get` for its `environment`.
2. Get the device running. For an iOS Simulator or Android emulator, boot it with `env.exec` if none is running (`xcrun simctl boot <udid>`, `emulator -avd <name>`). `device.screens` lists those that could start (`bootable_simulators`, `startable_avds`). For the computer's own screen, there is nothing to start.
3. Call `device.screens` with the computer's `device_id` and `environment`. Pick the screen from `screens`: `kind` `simulator`, `android` or `display`, and its `title`. Call it again after a boot if the device is not listed yet.
4. Send the screen's `link` exactly as `device.screens` returns it, alone on its own line, with a blank line before and after it and no Markdown, quotes or code block around it. Put a short sentence before it. One line per screen. For example:

   ```
   iPhone 17 Pro 模拟器已启动，still.fail 正在构建，装好后会在这里打开：

   comma:screen/dev_123/simulator%3A0702F8CC-2E2A-4D0A-8401-C37FA01E1646
   ```

   The blank line matters: Comma versions from before this rule draw a card only for a paragraph that is the link alone.

   Never build a link yourself or reuse one from an earlier conversation. A simulator's link (`simulator:<udid>`) stays the same across boots, but a card follows the boot it first showed: after the device boots again, call `device.screens` again and post its link as a new card. An Android emulator's id is its adb serial, which a later emulator may take.
5. To show an app, build, install and launch it on that device (for example `xcodebuild`, `xcrun simctl install` and `xcrun simctl launch` with `env.exec`), yourself or in a Task. Then say in one line that it runs, without the link again.

## After a change

Post a screen's card once per device in a conversation. When you change the app after the user has seen it, rebuild it, reinstall it and relaunch it in the same simulator or emulator. Do not boot another device, and do not shut down or reboot that one.
Do not post the link again. Say what you did and point to the card above, for example "Rebuilt and relaunched still.fail in iPhone 17 Pro at 14:32; the card above shows it."
The open card and screen panel show the relaunched app by themselves: the device's screen keeps streaming, so the user has nothing to refresh.
Post a new card only for another device, or when the device had to boot again: the link may be the same, but an open card stops showing a device that booted again.

## Look before you say it changed

Before you say a visible change is done, look at the rebuilt screen and compare it with what the user asked for. A passing build, passing tests or edited source do not show that the screen changed.

1. Take a picture of the device.
   - An iOS Simulator, where you have `env.screen` and the computer's environment has `screen_device_tool`: call `env.screen` with `device_id`, that `environment`, `action="start"` and `target="simulator:<udid>"`, then `action="observe"` with the `lease_id` and `lease_epoch` it returned. Call `action="end"` when you finished looking. The first start in a chat shows the computer's owner a card to allow it. Wait for the answer. If the owner denies it, do not take the picture another way: say that you could not look. `observe` works while a person drives the simulator in Control. It does not touch the device. The screenshot comes back in the tool result when your model can see images.
   - An iOS Simulator otherwise: run `xcrun simctl io <udid> screenshot <path>` with `env.exec`.
   - Android: use `env.android` `observe` on a lease, or run `adb -s <serial> exec-out screencap -p > <path>` with `env.exec`.

   View an image that you saved to a file: read it where your tools read images on that computer, or `env.copy` it to your files and read it with `fs.read_file` (`vision_query` when your model cannot see images).
2. Compare the part of the screen the user named with what they asked for, and with a picture from before the change if you have one.
3. Say it changed only if you saw it change. When the old look is still there, or you could not look, say that plainly (for example "Rebuilt and relaunched, but the + button still shows orange"). Then keep working on it or say what is left.

The picture is for you. Do not send it instead of the card.

## When no screen can be shown

- `unavailable` in the result, or no screen of the needed kind: tell the user why in one sentence, from that text. Comma on the computer must be signed in by its owner, with Settings › Devices access Full, and the owner's Comma app must reach the computer over the mesh (on the desktop app: Settings › Debug › Computers over the mesh, on by default).
- `screens_unsupported` (an older Comma on that computer, or a station of the Workspace): tell the user to update Comma on that computer. Offer a screenshot only if they ask for one.
- No device with `screen_view` in its capabilities: that computer cannot show its screen.

Only the computer's owner can open its screens. If the person who asked is not the owner of that computer, say that the card opens only for its owner.
The Comma phone apps and older Comma versions show the link as text: the screen opens in the Comma desktop app.
