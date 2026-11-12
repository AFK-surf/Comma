# iOS Simulator screens

`src/screens/simulator.ts` shows each iOS Simulator booted on a Mac as a screen source, `simulator:<udid>`. It implements
the `ScreenSource` interface of `src/screens/source.ts`. The code comes from still.fail's
`station/src/screens/simulator.ts`, `sim-input.ts`, `sim-mask.ts` and `SimulatorView.swift`, and the "Simulators" section
of its `docs/remote-screens.md`. Android devices work the same way on the same routes (`docs/android-screen.md`).

The mesh carries it: `GET /screens?devices=1` lists it and `POST /screens/<id>/view` views it, with the same admission as
a computer's screens (`src/mesh/device-mesh.ts`: its owner alone, the computer's access Full). `src/mesh/mesh.ts` creates
`Simulators`. The desktop app and the web page ask for devices unless the desktop's Settings › Debug turns its mesh off.
The iOS and Android apps ask for them on the computer's "Simulators and devices" page. Agents drive a simulator through
Salix (see "Agents on a simulator").

## Safety rules

1. Use CoreSimulator's own simctl at its absolute path
   (`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`). Do not use
   `xcrun simctl`: it is a script that can first run `xcodebuild -runFirstLaunch`, and that asks for an administrator's
   password in a window.
2. Do not boot or shut down a simulator by itself. Only a person's `POST /screens/start` boots one, and only their
   `POST /screens/<id>/close` shuts one down. The station shuts down nothing when it stops.
3. Do not open Simulator.app or any other window. `simctl boot` boots a device with no window, and the helper captures
   its framebuffer.
4. In tests, use a fake simctl and ps and a fake helper. For a check on a real simulator, create one of your own, and
   delete it after the check. Do not touch another person's simulators.

## Which devices are listed

Only a station on a Mac, with simctl at its path and a running Computer Use helper, lists simulators. Linux and Windows
stations list none. Only iOS devices that `simctl list -j devices` says are available are listed. A watch, a TV or a
headset is not.

The source looks at the devices at each listing that asks, and from the first listing on when CoreSimulator rewrites a
device's `device.plist` (as it boots and shuts down) or the list of devices changes. It watches each device's folder,
not what is below it, which a running device writes all the time.

## The list

`GET /screens?devices=1` gives each booted device as `{id, kind: "simulator", title, name, model, instance, width, height, peek:
true, capabilities}`, with the same `capabilities` as an Android device:

- `input`: `touch`.
- `buttons`: `home`, `lock`, `volume`, `rotate`.
- `panels`: each panel's size and corners, from the framebuffer masks in the device type's bundle (`sim-mask.ts`).
- `chrome`: the device's case and buttons, one for each panel, where Xcode has them on this Mac ("The device's case").
- `poses`: `closed`, `open`, on an iPhone Duo only.
- `closable`: `POST /screens/<id>/close` shuts the device down (`simctl shutdown`).

The answer also has `simulators`, `[{udid, title, model}]`: the devices that are shut down and could boot. `POST /screens/start`
with `{simulator: <udid>}` boots one of those (`simctl boot`) and answers the id it will have. The station reads the list
again before it boots and refuses a device that is not in it or not shut down (422). It checks access after it reads the
body and again just before it boots.

The desktop app's simulator menu lists only iOS device models on the current Mac. The station supplies `model` from
CoreSimulator's device type name, independent of a renamed test instance. Each model has one row. A choice uses the
current boot for that model, else another running instance, else an existing device on the newest installed runtime.
Older stations without `model` retain name-based grouping. The menu does not create new simulator devices.
Models chosen recently appear first. Additional models are behind More. Other computers, displays, and Android devices
do not appear in this simulator menu.

Settings › Devices › This device's ⋯ menu has "View simulators" where this computer's station lists any simulator or
AVD. It opens a screen tab on the running one chosen last, else on the first that runs. When none runs, the tab lists
the models to start, as the menu does.

## Which boot

A UDID names the device across all its boots. Each boot runs its own `launchd_sim` process. The source reads that process
from `ps` and its start time, and `instance` is a hash of the UDID, that pid and that start. A view and a close must name
the instance. The station reads the boot again before each view and each close, and refuses another boot with 409, so a
stale card or tab cannot drive or shut down a later boot of the device. A device whose boot cannot be read has no
instance: it is listed without one, its views only look, and it is not shut down from here. The client does not show such
a device.

A close is by UDID after the check. If the device shuts down and boots again in that gap, the close shuts down the new
boot of the same device. This race is accepted.

## A view

A view is one connection to the Computer Use helper. The station opens it with `{control: "screen.view", view: {target:
"simulator", udid, codec, control, maxWidth, maxHeight, fps?, bitrate?}}`. Then the connection carries still.fail
Helper's messages, as the Mac's desktop does (`desktop-screen.md`, "The Mac's helper"), and `src/screens/screen-pipe.ts`
(`HelperView`) reads them. `control` is true for each view that can drive (not a preview, and a known instance), also a
view that starts on Watch. The helper then takes input from the station, and the station sends only the input of a view
that is on Control now. A switch between Watch and Control does not change the helper's view
(`clients/packages/mesh/README.md`, "Views of a screen"). `SimulatorStreamSession.swift`, a `ScreenView`
(`CUStream/ScreenView.swift`) as still.fail's `SimulatorView` is one, serves it:

- Views, previews and agent input use serve-sim (`vendor/serve-sim`). They need no macOS capture permission or simulator window.
  An iPhone Duo exposes its outer and inner screens. Both use the simulator's original framebuffer.
  Comma does not offer a half-fold view or capture a Device Hub window.
  Screen changes use the source's transition. The client adds no rotation animation.
- The helper keeps the newest picture, scaled into the view's bounds. It encodes one only when the station asks for the
  next frame (`next`), and only a new one, unless a key frame was asked. A slow link so gets fewer frames, not a queue
  of them. A key frame asked of a still screen encodes the last picture again. A frame that the encoder drops is still
  owed, from a key frame if one was asked.
- The bounds are the longer side of what the view asked, both ways, because a device can stand either way. The station
  can ask for other bounds while the view runs (`bounds`): the view then fits its next picture into them.
- `info` names the codec and the encoder for the viewer's statistics. A `config` message (the size, then the `avcC` or
  `hvcC`) comes before the first frame and whenever it changes. The next frame is a key frame. A video frame is
  length-prefixed NAL units.
- Message 65 (`{orientation, pose?}`) says how the device stands and which screen is active.
  The client uses that orientation to place the case. still.fail's message 10 says the turn alone.

## Codecs

A client asks for what its page decodes, H.265 first (`ScreenAsk.codecs`). The helper gives H.265 only where the Mac
encodes it on its hardware, and otherwise H.264. A preview (`peek`, a link's card) asks for JPEG and H.264. A simulator
gives it a JPEG at most 2 times a second, each frame a whole picture and a key frame, and the config's `description`
empty. An Android device has no JPEG and gives the card H.264. A view that asks for no H.264 or H.265 is refused with 415.

## Input

`sim-input.ts` translates the device input that `deviceInput` in `src/mesh/screens.ts` checked:

| Input | On the device |
| --- | --- |
| The left button held | A finger. One that goes down in the bottom 3% or the top 2% is a system gesture |
| A wheel | A finger dragging |
| A key | Its USB HID usage |
| `{t: "text", text}` | Typed with a US keyboard's keys when each character has one. For other text, such as an IME's Chinese, the helper puts it on the device's pasteboard and sends ⌘V. The simulator's keyboards are not authenticated, so iOS takes that ⌘V as the app reading what another app copied. It asks the person with a prompt that a simulator never shows, and refuses. The helper reads the refusal in `pasted`'s log, allows that app to paste from other apps (`simctl privacy grant pasteboard`), and sends ⌘V again. When the view ends, it resets each app it allowed. After each paste, iOS shows a banner that says the app pasted. The banner has the keyboard focus for about 2.5 s, and keys sent then are lost. On the first paste after a boot, the banner comes up 0.25–0.35 s late. The helper follows SpringBoard's log while the view drives the device (`PasteBanner.swift`), and holds the next input until the banner gives the focus back, plus 50 ms. When no banner comes up in 1 s, the input goes then. The helper holds input for at most 5 s. When it cannot follow the log, it holds the next input for 2.6 s from the ⌘V |
| ⌘⇧H, ⌃⌘⇧H, ⌘L, ⌘K | Home, the app switcher, lock, the software keyboard |
| `{t: "device", name: "rotate"}` | The device turned a quarter |
| `{t: "device", name: "volume_up"}`, `volume_down` | Its volume buttons |
| `{t: "pose", name}` | An iPhone Duo's hinge |
| `{t: "button", page, usage, down}` | A button of the device's case by its HID usage, held from `down: true` until `down: false` (at least 80 ms) |

Previews and agent input keep framebuffer coordinates.

The client's home and lock buttons send ⌘⇧H and ⌘L. A preview's input and a read-only member's input do not reach the
helper.

The helper says how the device stands (message 65: `orientation` in degrees clockwise, a foldable's `pose`). A view passes
that on with `watchDevice`.

## Rotation

The helper tracks the physical turns requested for each booted device. The case and picture follow that turn, and each
finger is turned back into framebuffer coordinates. A portrait-locked app appears sideways inside the turned case;
its UI direction does not undo the person's turn. Duo's inner panel mounts one quarter turn clockwise from its cover,
so switching panels keeps the same physical direction. Control views and previews share it.

While the device turns, the helper holds the picture and asks `simctl io enumerate` how the UI stands. It waits up to
1.5 s for a UI change, then up to 1.5 s for drawing to settle. It also releases a picture whose app stays upright.
Before the first turn, the UI direction initializes the view. CoreSimulator does not report physical direction, so a
later turn in Device Hub cannot reliably replace the direction requested here. A turned picture has no edge gestures.
Use the device's buttons.

## The device's case

`src/screens/sim-chrome.ts` is still.fail's (`station/src/screens/sim-chrome.ts`), with the layout of serve-sim
(`devicekit-chrome.ts`, `device-displays.ts`, Apache-2.0). It reads the case that Xcode has for the device type:
`/Library/Developer/DeviceKit/Chrome/<id>.devicechrome` (`chrome.json` and its PDFs), with the panels from the type's
`capabilities.plist` (`displays`) and its `profile.plist`. These files are Apple's. The station reads them on the Mac,
keeps the pictures it makes of them only in the Mac's temporary files (`comma-device-chrome`), and sends them only to
those who may see the screen. They are not in this repository or in an app.

- The list's `chrome` is one item for each panel: `{key, width, height, frame, screen, corners, buttons: [{name, x, y,
  width, height, dx, dy, front?, page?, usage?}]}`, in the case's own points, upright as the framebuffer is. `width` and
  `height` are the framebuffer's pixels, so the picture's shape tells which panel it is. `dx`, `dy` is the way a button
  goes in when pressed. A button without `usage` is only drawn.
- `GET /screens/<id>/chrome/<panel>/<turn>` gives `{body, buttons: {<name>: {up, down?}}}`: PNGs in base64, turned
  `turn` (0 to 3) quarters clockwise. `body` is as large as `frame`: the case with the panel's shape (its framebuffer
  mask) cut out, and a notch's sensor bar over it. A Dynamic Island is not in it: the device draws it in its own picture.
  `/usr/bin/sips` draws the PDFs. The admission is the list's. 404: no such screen or panel.
- A Mac without Xcode's DeviceKit chrome, a device type the station cannot read, and an Android device have no `chrome`.
  The client then draws the plain body from `panels`, and its home, lock and volume buttons beside the device.

The client (`clients/packages/app/src/components/remote-screen/screenCase.ts`, after still.fail's mbui
`screen_case.mbt`) takes the panel whose shape the picture has. It turns the case as the picture is turned (message 65's
`orientation`), so an iPhone Duo's inner panel lines up too. It asks for that way's pictures first, then the other ways
and panels one after another. It draws the picture, its corners cut as far in as the case covers them (0.8 of the panel's
corners), the buttons behind the case, the case over them, and a home button on it. Only in Control, it puts a press area on each button with a `usage`, beside the panel and never over it. It
places side-button icons outside the case. Hover reveals the controls on that edge. The hovered, pressed or
keyboard-focused icon is blue. Side buttons slide from Xcode's normal position to its rollover position when revealed.
Icons move outward with them and fade in. They return inward on leave. Reduced motion disables these transitions.
Each button keeps its accessible name. The icon and physical button share one press area. A press
sends `{t: "button", page, usage, down: true}`, and its release `down: false`. A switch to Watch, a stream that changes,
the keys' or the button's focus lost, or the window losing the focus or being hidden releases a held button.
The toolbar leaves out the controls that the case has: lock (`power`), volume and home.
Screen choices use icons with tooltip names in both layouts.

## Foldables

An iPhone Duo has an outer and an inner screen. SpringBoard's log reports the active screen, including changes made from Device Hub.
The view reports `closed` for the outer screen and `open` for the inner screen, regardless of an intermediate hinge angle.
The controls select the outer screen at 0° or the inner screen at 180°. They do not expose an intermediate pose or read hinge angles.
The helper keeps the last requested angle per boot (`KnownHinges`) to start the next screen switch's sweep and to restore it if a command fails.
A screen switch runs
`comma-duo-hid` inside the simulator. `package-computer-use-helper.sh` builds that file from
`vendor/serve-sim/Sources/SimDuoHID` into the helper's Resources and signs it with `duo-hid.entitlements`, in the release
too (`sign-macos-app.ts`). `simctl spawn` starts it with `DYLD_ROOT_PATH`, which a hardened runtime removes unless the
file has `com.apple.security.cs.allow-dyld-environment-variables`. Without it the file stops at launch, and no pose or turn
reaches an iPhone Duo. A Mac without the iOS Simulator SDK builds none, and a pose then does nothing.

Before a panel switch, the helper holds the last picture. It releases that picture after the new panel draws a nonblack,
steady picture for 150 ms, or after 1.5 s. A newer switch or turn owns the hold.

## App logs

`src/screens/app-logs.ts` reads the logs of the apps on a simulator, for the logs pane under its picture. It comes from
still.fail's `station/src/screens/sim-debug.ts`: `simctl spawn <udid> log stream --style ndjson` with its predicate. The
`app` filter shows what apps a person installed say themselves, Foundation's NSLog and their errors. It also shows the
Swift runtime's `Fatal error`, CoreFoundation's uncaught exception and SpringBoard's `Process exited` line. One app asked
by its bundle id narrows that to its process. The `all` filter shows the whole device at its default level.

The mesh carries it: `POST /screens/<id>/logs?mode=app|all[&app=<bundle id>]&instance=<instance>`, only to one who may
drive the computer (the owner, not read-only), while its access is Full. The list says `capabilities.logs`. A station
from before lists none, and the client shows no pane. The reply is `state` frames: `{logs: {mode}}` first, then
`{lines, dropped?}`, `{alive}`, and `{ended}` last. The stream lasts while the request body is open. The client ends it
when the pane closes. It also ends when the access or credential goes or the device shuts down.

Ask Comma in the client sends `app-logs.txt` with the picture. The file has at most the newest 100 lines that the client
keeps of this device, from the filter read last (App or All). The client reads them when the person presses Send, not
when the frame was taken. With the pane closed, the lines are those kept from when it was open, and they can be old.
Clear in the pane also removes them from what is sent, for every filter.

A line is a crash when it is the Swift runtime's `Fatal error`, an uncaught exception, or an app's process that ended on
a signal other than SIGKILL or SIGTERM. A crash report (`.ips`) in `~/Library/Logs/DiagnosticReports` whose `procPath`
names the device also gives a crash line. With one app's filter, only a report whose `bundleID` is that app's does.
A fault alone is not a crash.

Bounds: one `log stream` process for each device and filter, which runs only while somebody reads it. A device keeps at
most 4 filters. The station runs at most 4 log streams at once. A line is cut at 2000 characters. Lines come in at
200 a second (bursts of 400), and the station counts the rest as `dropped`. Crash lines have a bucket of their own
(10 a second). The newest 1000 lines stay for a reader that joins later. Each reader holds at most 2000 lines that wait
to go. At most one `alive` frame waits for a reader that reads nothing. Android's look at the
foreground app runs one at a time. The station reads each crash report once, at most 16 at a time. When the log
process ends by itself, all that its start runs with it stops too.

## Debugging an app

`src/screens/sim-debug.ts` restarts the running app, takes a screenshot, records the screen, installs an app and sets
light or dark. It comes from still.fail's `station/src/screens/sim-debug.ts`. `app-logs.ts` above has its logs.

The list says `capabilities.debug: {actions, install}`: the actions this device can do and the file types it installs. A
station from before lists none, and the client shows no buttons. A client from before ignores the field. A phone and a
computer's own screen have no `debug`. Actions:
`POST /screens/<id>/debug/<action>?instance=<instance>`.

| Action | What it does | Query |
| --- | --- | --- |
| `state` | `{recording, appearance}` | |
| `restart` | Ends and starts the newest running app a person installed. 404: none runs. | |
| `screenshot` | A PNG of the device, in its own pixels. | |
| `appearance` | Sets light or dark. | `value=light\|dark` |
| `record` | Starts `simctl io recordVideo`. | `panel=inner\|cover` on a foldable |
| `record-stop` | Ends it. The reply is the H.264 MP4. 404: nothing records. | |
| `install` | The request body is the file: `.ipa`, or `.zip` with a `.app` in it. The app is installed and started. | `name=<file name>` |

Authority: only the computer's owner can use these actions, with Full access and a view of this device in Control.
The station checks the live boot before dispatch. It checks access, Control, cancellation, and the live boot again after an upload.
A switch to Watch, an ended view, or revoked access prevents pending uploads from installing.
An action already dispatched to the device can finish. These commands use the same check-then-device-command boundary as device shutdown.
Screenshots and `state` use these checks too. A recording started in Control must be stopped in Control.
Otherwise the recorder stops at its 10-minute limit.

Bounds: the uploaded file is at most 2 GiB, with one upload per device. The client sends at most 1 GiB.
This bounds compressed input, not extracted bytes or disk use.
The station assigns the temporary filename and removes the upload after success, rejection, or failure.
Each recording has a separate temporary folder. Starts and stops run in order for each device.
The next recording or device removal removes the previous movie. An active download keeps its movie until its response stream closes.

Deviations from still.fail:

- `restart` takes no app. still.fail's viewer chooses one in its App tab, and Comma has no such tab.
- A recording's folder is the device's. still.fail empties one shared folder when any device starts recording, which takes a movie from another device.
- A movie and a file to install go on the mesh request itself. still.fail goes through its drive, which Comma has not.
- A folder `.app` cannot be chosen in a browser file picker, so it goes up zipped (`.zip`), as still.fail's upload does.
- Not ported: text size, opening a URL, location, the status bar, biometrics, uninstall, push.

## A link in a message

`comma:screen/<device id>/simulator%3A<udid>` on its own line is the simulator's card in the client, as for an Android
device (`docs/android-screen.md`).

## Agents on a simulator

Salix Workers lease a booted simulator through `env.screen` (`src/screens/simulator-agent.ts`, the device
connection's `screen` method). The connector says `screen_device_tool: true` on a Mac's device connection where
simctl and the Computer Use helper are. Salix refuses `env.screen` on a device that does not say it (a station from
before: `screen_capability_missing`), and only a Worker calls it.

The tenant's `android_control` policy and the `android-control` plugin do not govern `env.screen`: they gate
`env.android` alone. A simulator is gated by the computer's access (Full), the Worker role and the computer owner's
consent card in the Conversation. Turning `android-control` off does not turn off all device automation.

- `status` lists the booted simulators, each by its screen id (`simulator:<udid>`, the `<screen>` of a link), and
  whether a person drives it now.
- `start {target, instance?, lease_seconds?}` leases one for 60 to 3600 seconds (default 600). One lease is allowed
  for each simulator. The first start in a Conversation asks the computer's owner on a `computer_use_start` card
  (capability `ios_simulator`): only that owner answers it, and the station is told `consent` only from its record.
- `observe` gives CoreSimulator's own screenshot (`simctl io <udid> screenshot`), a PNG in the device's pixels, at
  most 24 MB, kept as a computer-use screenshot is.
- `tap {x, y}`, `swipe {from, to, duration_ms?}`, `type {text}` and `key {key}` are in the latest screenshot's
  pixels. They go through a view of the helper's that drives the device as a person's Control does (`Input`):
  `home`, `app_switcher`, `lock` and `keyboard` press the device's buttons by Simulator.app's shortcuts.
- `end` ends the lease and closes its view. A lease also ends when its time is up, when the simulator shuts down or
  boots again, or when the station stops.

The station tells each person's view of a simulator or an emulator about the lease, in the view's `state` frames
(`ScreenSource.watchAgent`, `clients/packages/mesh/src/screen-wire.ts`). A preview is told nothing.

- `agent` says whether a lease lasts. The station sends it after the view's first state and each time a lease starts or ends.
- `agentPointer` `{x, y, down}` says where the agent's finger is, as a share of the picture. The station sends it for
  each press, move and lift of a tap or a swipe. An emulator's swipe is one `input swipe`: the station sends its
  press where it starts and its lift where it ends.

Comma's panel opens a simulator or an emulator on Watch (`ScreenStreamPanel.tsx`). When `agent` is false, the panel
switches to Control and shows no Watch or Control choice. When `agent` becomes true, the panel switches to Watch, so
the agent's input reaches the device, and shows the Watch and Control choice beside the device: under a device that is
taller than wide, and at the end of the buttons' row of one that is wider than tall (`ScreenControlChoice`). It draws a
glowing edge around the device, outside its body, and the agent's cursor at each `agentPointer`
(`ScreenAgentPresence.tsx`). When the lease ends, the panel returns to Control and hides the choice.
A station from before sends no `agent`. Then the panel stays on Watch and shows the choice once the picture comes, so
it never holds off an agent's input that the person did not ask to hold off.

A person who takes Control of the simulator in a view comes first: while they drive it, an agent's input is refused
(`screen_held_by_person`). A swipe looks at its lease again after each move: when its time is up, the station stops,
the simulator goes or a person takes it, the finger is lifted where it is and nothing more goes. An agent still
observes.

`scripts/simulator-agent-live.sh` runs the live acceptance check `scripts/simulator-agent-live.ts` on a Mac: a simulator and a helper
instance of its own, a screenshot, a person's Control, and a tap that changes the screen. It deletes them after.
