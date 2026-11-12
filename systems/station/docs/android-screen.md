# Android screens

`src/screens/android.ts` shows an Android emulator, or a phone that the computer's owner chose, as a screen source. It implements the `ScreenSource` interface of
`src/screens/source.ts`. The code comes from still.fail's `station/src/screens/android.ts` and the "Android" section of
its `docs/remote-screens.md`.

The mesh carries it: `GET /screens?devices=1` lists it and `POST /screens/<id>/view` views it, with the same admission as
a computer's screens (`src/mesh/device-mesh.ts`: its owner alone, the computer's access Full). `src/screens/devices.ts`
creates `AndroidScreens` once for the station: the owner's views and the agents' leases (below) use the same devices.
It starts adb only at the first listing or agent call that asks for devices. A desktop app asks only with Settings ›
Debug's setting on.

## Safety rules

A person's real phone can be on adb at any time. A restart of the default adb server once connected a phone over
wireless debugging, and a test then sent input to it because it was the first device in the list.

Obey these rules in all code and tests that use this source:

1. Do not use the first device in a list. Use one exact serial.
2. Do not call `adb` for a device without `-s <serial>`. `adbOf` is the only path to a device. `track-devices` and
   `kill-server` talk to the server only. `connect <host>:<port>` and `disconnect <host>:<port>` name the address that
   the owner typed (`wirelessAddress`: never this machine). These are the only calls without a serial.
3. Do not use the adb server of a person. `serverPort` is a required argument, and `AndroidScreens` refuses 5037.
   `stationAdbPort` gives each data directory its own port, and `stopServer` stops that server when the station stops.
4. Do not let adb connect to a phone by itself, or look for one. `adbEnv` always sets `ADB_MDNS=0` and
   `ADB_MDNS_AUTO_CONNECT=0`. A malformed mDNS packet on the network also aborts an adb server that has mDNS on.
5. Do not inherit a setting that selects another server or device. `adbEnv` removes `ADB_SERVER_SOCKET`,
   `ANDROID_ADB_SERVER_ADDRESS`, `ADB_SERVER_PORT`, `ADBHOST`, `ADB_LOCAL_TRANSPORT_MAX_PORT` and `ANDROID_SERIAL`.
6. Do not trust the name `emulator-<port>`. adb gives that name to any adbd on a local port or at `ADBHOST`.
7. In tests, use a fake adb at an absolute path. Do not boot an emulator. Do not call the adb on `PATH`.
8. Do not ask a phone anything before its owner chose it. Before that, the list shows only what the server says of it
   (`track-devices -l`: serial, state, model, transport).

## Which devices are sources

`shownDevice` decides from the serial. A device that it refuses gets no adb call at all, not even `getprop`.

A device with an emulator's name then gets one more check, after it has booted. `ro.kernel.qemu` or `ro.boot.qemu` must
be 1. Otherwise it gets no further adb call and is not a source.

| Serial | Source |
| --- | --- |
| `emulator-<port>` that says it runs on qemu | Yes, as `android:emulator-<port>` |
| A phone whose exact adb serial the owner chose (`phones`) | Yes, as `android:<ro.serialno>` |
| Any other phone (USB or `<host>:<port>`) | No. It is only listed under `phones` |
| `adb-<serial>._adb-tls-connect._tcp` (adb found it on the network) | Never, also when it is in `phones` |
| `127.0.0.1:<port>` (a phone lent through `mesh/adb.ts`) | Never, also when it is in `phones` |

This is narrower than still.fail, which shows every USB phone.

## Phones

The owner chooses phones in the screen panel's 手机… dialog (`ScreenPhones.tsx`). The choices are in config.json,
`screens.phones`: `{usb, chosen: {<adb serial>: {agents}}}`. Nothing is chosen at first, and USB is off.

- **USB.** `adbEnv` sets `ADB_USB=0` while `usb` is off, so the station's server does not take a USB phone. When the
  owner turns USB on, the station stops its server (`kill-server` on its own port) and starts it again without
  `ADB_USB`. Its emulators come back to it. The station's server then takes the machine's USB phones, as Android
  Studio's adb on 5037 does, and the two servers contend for them. The dialog says so.
- **Wi-Fi.** The owner types the address that Wireless debugging shows. The station runs `adb connect <host>:<port>` on
  its own server and chooses that address. It first waits for its server to answer, as a listing does, for at most 3
  seconds: `adb connect` alone starts a second server beside one that is still starting, which fails on the port. The phone must already trust this machine's adb key (paired once with the
  person's own adb). The station does not pair.
- **Listed before chosen.** `GET /screens?devices=1` also answers `phones: {usb, list}`. Each phone has `serial`,
  `state`, `model`, `transport` (`usb` or `wifi`), `shown`, `agents`, and `screen` once it is a screen. A chosen phone
  that is not on adb now is listed with state `absent`.
- **Changes.** `POST /screens/phones` takes one of `{usb}`, `{serial, shown, agents}`, `{connect}` or `{disconnect}`,
  and answers the phones. Only one who may drive the computer (access Full) may change them.
- **A phone screen.** Its id is `android:<ro.serialno>`, and its `instance` is a hash of its name and its boot. It is
  never `closable`, and nothing here starts it. The list marks it `phone: true`. A preview does not turn its screen
  on. A view that is not a preview turns the screen on, on Watch too. scrcpy shows the lock screen as the phone shows it.

A device on adb has no answers until it has booted, so the source looks again every 3 seconds until
`sys.boot_completed` is 1. The source follows `adb track-devices` from the first `refresh`. After 10 minutes without a
`refresh`, and with no device listed, it stops following.

`unavailable()` says why no device can be listed when adb is absent or does not run. The listing is then empty.

`panels` gives the device body its corners. Like still.fail, the source reads them from `dumpsys display`. A display that
says no radius, or a radius of 0, has no panel, and a client then draws square corners. The screen list must also carry
`panels` to the client, as still.fail's `hub.ts` does.

## The list

`GET /screens?devices=1` gives each device as `{id, kind: "android", title, width, height, peek: true, capabilities}`:

- `input`: `touch`.
- `buttons`: what the client may offer beside the device.
- `panels`: the screen's panels and corners.
- `poses`: the ways a foldable can stand. A device that does not fold has none.
- `closable`: `POST /screens/<id>/close` closes the emulator for good. The station sends SIGTERM to the emulator's process
  (on Windows, it ends the process). It does not send `adb -s <serial> emu kill`. The station never does this by itself.

The answer also has `avds`, the Android Virtual Devices that could start now, and `devicesUnavailable` when no device can
be listed. `POST /screens/start` with `{avd}` starts one (`src/screens/emulator.ts`) with no window on the station's adb
server, and answers the id it will have. The client lists until it is there. It outlives the station. Only one who may
drive starts or closes a device.

## Which device

A device's id (`android:emulator-5554`) names a place: an emulator's console port, which another emulator may take once
it closes. The list therefore also gives `name`, the AVD's name, and `instance`, which identifies this run of the device. It is a
hash of the name, the kernel's `boot_id` and, for an emulator, its process id (from `adb emu avd discoverypath`). The
process id is needed because an emulator started from its quick-boot snapshot keeps the snapshot's `boot_id`. A view and a close must name the instance. The station refuses one for another
instance with 409, so a stale card or tab cannot drive or close a device that took its place.

A device can be replaced at its port with no offline step that adb reports. So the station reads these again before
each view, each close and each put-back (below), and at each change adb reports. When the boot differs, the station
refuses the request with 409, drops the source and looks at the port anew. A device whose run cannot be read has no
instance. It is listed without one, its views only look, and it is not closed from here. This client does not show such
a device.

A close does not use the serial. Between the check and an `adb -s <serial>` call, the emulator can end and another
emulator can start at its port, and the call would reach that one. So when the station lists an emulator, it also reads
the start time of its process (the pid in `instance`). Just before a close, the station checks the instance again, then
reads the start time of that pid again. If the process is gone or its start time differs by 5 seconds or more, the
station refuses the close with 409 and ends nothing. An emulator whose start time could not be read is not `closable`.

Views, input and the put-back (below) still use the serial after the check. This race is accepted: it occurs only when
an emulator on the owner's own machine ends and another starts at the same port within that gap. The worst result is a
wrong rotation, pose or key on that other emulator.

`POST /screens/start` starts one emulator at a time. It holds the console port it chose until the emulator binds it or
ends. An emulator that has not bound its port within 30 seconds is stopped, and the start fails. So two starts never get
the same port. The client waits for the device listed at the answered id with the AVD's `name`. The station checks
access after it reads the body, again just before it spawns the emulator, and again before it answers.

## A view

A view is one run of scrcpy's server on the device:

- The station pushes the file to `/data/local/tmp/stillfail-scrcpy-<id>.jar` and removes it after the start, also after a
  failed start.
- It uses its own `adb forward`, removed when the view ends.
- Its protocol is pinned to the version of the file, because scrcpy keeps no compatibility between releases.

A packet that says it is longer than 32 MiB ends the view. `fps` and `bitrate` go on the program's command line, so the
source takes them only as finite positive numbers, with `fps` at 120 or less.

The source sends H.264 only, and refuses a viewer without H.264 before it runs anything on the device. The encoder takes
no new size or rate while it runs, so a view has no `rate`. Its rate goes by its size: 2 Mbit/s at 480 on its long side,
3 at 720, 5 at 1080, 7 at 1440, and 8 above, while the picture moves (still.fail's rates). A still screen sends nothing. It opens at the
larger of its bounds
on its long side, at most 2560. The client asks for the size the picture shows at, in its screen's pixels, so its page
does not scale a larger picture down, which leaves small text soft. It asks once more, larger, as its stage grows.

`keyframe()` sends scrcpy's reset message, which starts a new capture. A slow viewer does not queue more than 30 frames.
The view then drops frames up to a new key frame and asks for that key frame.

A preview (`peek`, a link's card in a message) only looks, and does not turn the screen on. It runs at the size the card
asks, 2 frames a second and 300 kbit/s, beside the views. One client runs at most two at once, and the station at most six. A view that is not a preview turns the
screen on, on Watch too. With the screen off, no frame comes.

`open` fails with a `ScreenRefused` and a clear message, and does not hang, in these cases:

- `scrcpy-server` is absent.
- adb does not run or does not answer within 15 seconds.
- The program ends before it listens.
- The program takes the connection and sends nothing for 15 seconds. still.fail waits forever here.
- The view is closed while it opens. No forward stays, and no program runs after that.

## Text

The input `{ t: "text", text }` is what an IME composed or what a paste carried. As in still.fail's `android.ts`, printable
ASCII of at most 300 bytes goes as scrcpy's `INJECT_TEXT`, which types it as keys. Other text goes as `SET_CLIPBOARD`
with paste set, so it replaces what the device's clipboard held. `deviceInput` takes text of 1 to 4096 UTF-16 units.

## Rotation

The input `{ t: "device", name: "rotate" }` turns the display one quarter: lock 1, 2, 3, 0, and then 1 again. The source
runs a fixed command with `wm user-rotation` over adb. scrcpy's own `ROTATE_DEVICE` does nothing on an Android 16
emulator. On a device with poses the command first runs `wm fixed-to-user-rotation enabled`, because the system of an Android 16
foldable AVD keeps its lock per pose and answers `wm user-rotation lock` with `free`. Before the first turn or fold from here, the
station reads `wm fixed-to-user-rotation` and `wm user-rotation`. It puts the device back with `cmd device_state state
reset` and those two values (`restoreOf`; the system's defaults where they were not readable). The pose goes back to the
device's own base state, not to an override another tool set. This happens a minute after the last view that drives the
device ends, when the device is closed from here, and when the station stops while the device is still there. It
happens only on the boot that was turned. A device that left adb is not touched again, and its pending put-back is
called off. The picture's new shape comes from scrcpy. After the first rotate, the display no longer follows its sensor.

The source runs that command only for the name `rotate`. The mesh route also checks names before input reaches a view
(`deviceInput` in `src/mesh/screens.ts`).

## Fold

`cmd device_state print-states` says whether a device folds. `posesOf` takes a `closed` and an `open` state, and a
`book` state if there is one, by their names. A device whose one state is `DEFAULT` does not fold and has no poses.
The input `{ t: "pose", name }` runs `cmd device_state state <id>` with the device's own number for that name. Display 0
follows the fold, so scrcpy starts a new capture with the new size.

`watchDevice` reports the rotation and the pose. A view looks as each capture starts, and after a rotate or a pose.

## scrcpy-server

The file is not in Git. `scripts/native.ts` has it as the part `scrcpy-server`, with the same content-addressed cache
and R2 store as the other native parts. The workflows that publish parts from main also publish it, for each platform.
Until then, or for a key that R2 lacks, a bundle gets the file from GitHub and fails if GitHub cannot give it. Its `build` downloads the unmodified `scrcpy-server-v5.0.1` from scrcpy's GitHub
release and checks its SHA-256. The file runs on a device, so another file must not reach one. The expected hash is the
digest GitHub gave for the release asset when this was pinned. It matches still.fail's copy. On a mismatch the build
fails, and nothing is published or bundled.

`scripts/bundle.sh` puts the file in `station/scrcpy-server`, beside `main.js`, with its license in
`station/scrcpy-server.LICENSE`. scrcpy is Apache-2.0 (Genymobile and contributors). The license text is in
`vendor/scrcpy/LICENSE`. A checkout gets the file with `node scripts/native.ts run scrcpy-server -- <command>`, which
sets `STILLFAIL_SCRCPY_SERVER`.

To change the version, change `SCRCPY` in `scripts/native.ts` and `SERVER_VERSION` in `src/screens/android.ts` together,
and read scrcpy's protocol changes.

## App logs

An Android device's logs go on the same route as a simulator's (`docs/simulator-screen.md`, "App logs"). The station
runs `logcat -v threadtime -T 1` through the device's own adb, which is pinned to its serial (`adb -s <serial>`). The
`app` filter keeps the lines of the foreground app's processes, or of the package asked for. It also keeps the runtime's
and ActivityManager's lines about that app. The station reads the foreground app and its pids again every 2 seconds
while the stream runs. A crash is `FATAL EXCEPTION`, a fatal signal, a `F` or `A` line, or ActivityManager's
`Process … has died`. This works where the station has adb: macOS, Windows and Linux.

## Debugging an app

An emulator lists `capabilities.debug`, as a simulator does (`docs/simulator-screen.md`, "Debugging an app", has the
routes and who may). `src/screens/android-debug.ts` does each with adb, pinned to the device's serial. A phone lists none:
what is on it is a person's own. still.fail has no such code for Android, so this is not a port.

- `restart`: the package in front, only if `pm list packages -3` has it, by `am force-stop` and `monkey`. The launcher or a
  system app in front gives 404.
- `screenshot`: `exec-out screencap -p`.
- `record`: `screenrecord --time-limit 180`. The station saves its PID and checks its unique output path before sending SIGINT.
  During stop or close, it waits at most five seconds for the recorder PID and command to become available.
  Start returns immediately. Other recorders are left alone.
  `adb pull` fetches the movie. The station then removes the remote movie and PID file.
  Device removal also requests SIGINT before it removes these files.
  The next stop retires the previous local movie before it fetches the new movie. Device removal also retires it.
  An active download keeps a retired movie until its response stream closes.
- `install`: an `.apk`, by `adb install -r -t`. It is not started: adb does not say the package.
- `appearance`: `cmd uimode night`. Listed only from API 29, read when the emulator is listed.

These work the same on a Windows or Linux station, because each is adb's. Those stations have no simulators.

## A link in a message

`comma:screen/<device id>/<screen id>` on its own line is the screen's card in the client
(`clients/packages/app/src/components/remote-screen/ScreenLink.tsx`), with Settings › Debug's setting on. The screen id is
`display`, `android:<serial>` or `simulator:<udid>` (`docs/simulator-screen.md`), percent-encoded. A card shows a preview while it is on the screen. A display has no
preview, because its view wakes it. A successful listing that no longer includes the device boot replaces its card with an inert “Screen ended” placeholder.
An unreachable station keeps the last known card.

Before the first successful listing, a device card says that device information is unavailable.
Its title uses a human link label or a localized device type. The target's id, UUID, or serial is not a display name.
The card stays disabled until the station lists the device. A later successful read restores its name and preview.

## Agents on a device

Salix Workers lease a device through `env.android` in its `device` mode (`src/screens/android-agent.ts`, the device
connection's `android` method). The connector says `android_device_tool: true` and `android: {protocol_version: 3,
mode: "device"}` on a desktop's device connection. Salix keeps its gates: the tenant's `android_control` record must
name the `device` mode, the `android-control` plugin must be on, and only a Worker calls it
(`Salix.Control.AndroidControl`).

- `status` lists the devices an agent may lease: each emulator, and each phone that its owner chose with `agents` on.
  Other phones are not said. `status` and `start` follow adb first, as a listing does (`refresh`), so a station that
  nobody listed yet still finds its devices. A phone that is not chosen still gets no adb call.
- `start {target, instance?, lease_seconds?}` leases one device for 60 to 3600 seconds (default 600). One lease is
  allowed for each device. The list marks a leased device `agent: true`.
- `observe` answers a PNG screenshot at the device's size, kept as a computer-use screenshot is (`image_path`; Salix
  reads it with `read_image`), with `screen_on`, `locked` and `held_by_person`.
- `tap {x, y}`, `swipe {from, to, duration_ms?}`, `type {text}` (printable ASCII; a newline is Enter), `key {key}`
  (named keys, no power key) and `launch {package}` act in the screenshot's pixels. Each is one fixed command with
  checked arguments.
- `end` ends the lease. A lease also ends when its time is up, when the device leaves adb, and when the station stops.
- Each person's view of the device, except a preview, hears the lease start and end (`agent`), and where each tap and
  swipe presses and lifts (`agentPointer`), as `systems/station/docs/simulator-screen.md` says for a simulator.
- On each device, a start, each action, an end and the put-back run one after the other. Two starts at once give one
  lease and refuse the other (`android_leased`). A start after an end begins only when the phone is put back.
- One check covers a lease: it is still this lease, its deadline has not passed, the station is not stopping, the
  device is the one leased, and its owner still lets agents use it. The check runs as an action starts and again
  after every adb answer, before anything more reaches the device (a start runs it after it reads and sets what the
  phone shows). A lease that fails it ends in that same turn, its phone put back, and the action is refused
  (`android_lease_expired`, `android_phone_not_offered`, `android_target_replaced`). The lease's own timer only ends
  a lease that no action uses.

A phone has more rules:

1. Agents reach a phone only when its owner turned `agents` on for it.
2. The first lease of a phone in each Conversation needs its owner's consent. The station refuses a phone's `start`
   with `android_consent_required` unless Salix says `consent`. Salix raises a `computer_use_start` Capability Request
   (capability `android_phone`) with its card in the Conversation, and the call waits for the answer. Only the owner
   of the computer allows or denies it (`POST …/requests/<id>/decision`). Salix gives `consent` only from an approved
   request of that Conversation, device and phone among the Conversation's newest 100 requests. It drops an Agent's
   own `consent` argument. Outside a Comma Conversation a phone is refused.
3. While a lease lasts, the phone shows touches (`show_touches`) and has a notification that an agent uses it. At the
   end the station puts `show_touches` back and replaces the notification with one that says the agent stopped.
   `end` answers only after this. When the station stops, it refuses new starts, ends every lease and waits for each
   put-back before it stops its adb server.
4. When the owner turns `agents` off for a phone, or stops showing it, its lease ends at once and the phone is put back
   before the change is answered. An action that finds the owner's word changed (config.json edited by hand) ends the
   lease the same way and is refused.
5. A locked phone takes no input except `key wakeup`. A phone that does not say whether it is locked is taken as
   locked. The owner unlocks it. An agent never types a PIN.
6. While a person drives the device in a view of theirs, every agent's input is refused (`android_held_by_person`).
   A view that only looks does not hold it. A view that switches to Control holds the device from that switch, and a
   switch to Watch releases it at once, while the view continues.

A Worker's card in the chat (`WorkerComputerUseScreen.tsx`) shows the leased device as the computer lists it. The card
only looks.

## Not ported

- `adb/servers.ts`, `adb/grants.ts`, `adb/link.ts`, `adb/tool.ts`: still.fail lends a phone to one chat with its own adb
  server. Comma lends a phone with `mesh/adb.ts` to all the agents of a station. Such a phone stays out of the screen
  panel (`127.0.0.1:<port>`).
- still.fail's virtual display for a chat's agent, and its `computer` and `screen` tools: Comma's agents use
  `env.android`, and the station's own Claude and Codex sessions get no screen tool.
- The rest of `screens/hub.ts`: `hub.ts` has only `ScreenRefused`.
- JPEG previews: scrcpy sends H.264 alone, so a card decodes H.264 at 2 frames a second. still.fail's web client asks a
  JPEG preview, which its Android source refuses.
