# Desktop screens

A Mac station shows an app's windows (`app`) and its main display (`display`) through its Computer Use helper. A
Windows station shows its main display as the screen source `display` (kind `desktop`). Both speak still.fail Helper's
messages, and one `HelperView` (`src/screens/screen-pipe.ts`) reads them. A Linux station shows the station user's X11
desktop as `display` too (see "Linux"). "The Mac's helper" below describes the Mac.
The other sections describe Windows, and the rules they share. `src/screens/win-desktop.ts` implements the `ScreenSource` interface of `src/screens/source.ts`.
The program `comma-desktop-screen.exe` (`native/desktop-screen`) captures, encodes and posts the input.

The code is a port of still.fail (github.com/AFK-surf/still.fail, `afk/main` 7470ca2abe):

| Cue | still.fail |
| --- | --- |
| `native/desktop-screen` (Rust, with its tests) | `station/native/screen` (`stillfail-screen`) |
| `src/screens/screen-pipe.ts` (`HelperView`, `helperMessage`, `TO_HELPER`) | `station/src/screens/desktop.ts` |
| `src/screens/win-desktop.ts` (`WindowsDesktop`, `LastingView`, `childPipe`) | `station/src/screens/win-desktop.ts` |
| `src/screens/win-input.ts` (`KEYS`, `WinInput`) | `station/src/screens/win-input.ts` |

The clipboard and the system output come from `afk/main` 3d517e022e. "Clipboard and sound" below lists their sources.

still.fail's `docs/remote-screens.md` ("Windows") and `docs/station-ts-native.md` (§5) describe the same program.

## The Mac's helper

`src/screens/helper.ts` makes the sources `app` and `display`. Each view is one connection to the Computer Use daemon's
socket. The station writes one JSON line `{control: "screen.view", view: {target, codec, control, maxWidth, maxHeight,
apps?, bitrate?, background?, cursor?, audio?, timing?}, auth_token}`. Then both directions carry still.fail Helper's messages
(`CUStream/ScreenView.swift` lists them).

The Swift code is a port of still.fail Helper (`afk/main` b928883a23):

| Cue | still.fail |
| --- | --- |
| `CUStream/ScreenView.swift` (`ScreenView`: messages, encoders, `pump`, `encoded`, `next`, `keyframe`, `rate`, `bounds`, `setFiner`, `wake`, colour tags) | `station/native/helper/Sources/StillfailHelper/ScreenView.swift` |
| `CUStream/ScreenChannel.swift` | `Channel.swift` |
| `CUStream/SimulatorStreamSession.swift` (a `ScreenView`; `settleTurn`) | `SimulatorView.swift` |
| `ScreenStreamConnection.swift` (the grant checked in a fresh process, the restart) | `Daemon.swift` `screen.view`, `Status.swift` `fresh` |
| `src/screens/helper.ts` `openView` (the restart, the refusal that says where to grant) | `station/src/screens/desktop.ts` `Desktop.open` |
| `src/mesh/screen-pace.ts` `Sizer` | `station/src/mesh/screen-pace.ts` |

How a view runs:

1. The helper keeps the newest picture that ScreenCaptureKit captured. It encodes one only when the station asks for the
   next frame (`next`), and only a new one, unless a key frame was asked. The station asks only while its pace lets a
   frame go (`screen-pace.ts`), so a slow link or a Salix relay gets fewer frames, not a queue of large ones.
2. It encodes H.265 when the client takes it and this Mac has a hardware H.265 encoder, else H.264 (the hardware encoder,
   else the software one). Its `info` says the codec and the encoder. When the helper makes the encoder again with
   another codec or encoder (a low-latency session that fails its first frame), it sends `info` again before that
   encoder's config, and the viewer's statistics follow it. The client's H.265 fallback (#4967) applies as for
   Windows.
3. A frame that the encoder drops is still owed, from a key frame if one was asked.
4. A key frame asked of a still screen encodes the last picture again, finer (a lower QP bound, twice the bit rate).
   The helper makes a key frame only when the station asks for one, or for a new encoder. It does not make one by time.
5. The station sends `rate` as the link changes. While the link carries a quarter or less of what the picture's size
   needs, the station asks for 1280×720 (`bounds`), and for the view's own size again once the link carries it
   (`Sizer`). The helper changes its capture size while the view runs.
6. A view wakes a display that sleeps (its capture is black) and keeps it on until the view ends.
7. The pictures are captured in sRGB (Display P3 when asked `gamut: "p3"`) and tagged so in the stream, not in the
   display's own colour space.
8. Each frame and sound packet has the time of its capture, in µs, on the clock that the station reads (`hostNow`:
   `process.hrtime`). On macOS that clock continues while the Mac sleeps (`mach_continuous_time`). ScreenCaptureKit,
   CoreAudio and CoreSimulator give times on `mach_absolute_time`, which stops during sleep. The helper adds the time
   that the Mac slept since its boot to each time (`CUStream/HostClock.swift`). Without this, a Mac that slept sends
   stamps that are hours behind, and `FrameLatency` does not count them, so the viewer shows no frame latency.
9. Screen Recording: macOS gives a running process a new grant only when it starts again. If the daemon does not have
   the grant, it asks a new process of itself (`--permissions-status`). If that process has it, the daemon leaves its
   socket, says `code: "restart"` and ends. The station starts the daemon again and asks once more. If the grant is
   missing, the view is refused with a message that names the setting: System Settings > Privacy & Security > Screen &
   System Audio Recording.

Cue's own beside still.fail's: an app's view captures only that app's windows and follows them (message 64 says the apps
and their windows as they change), a background colour, the display by index, and the pointer in the pictures unless the
station asks `cursor` (then message 6 says it). A simulator says how it stands in message 65. Input is Cue's
`{type: …}` form, which `RemoteInputInjector.swift` posts (still.fail makes ops of it in its station).

The helper does not have parts of the display (regions) or reveal yet. It ignores their messages. A simulator's view
also ignores the clipboard and audio messages. A low-latency encoder session that fails every frame (a virtual
machine's) is made again without low latency.

## Linux

`src/screens/linux-desktop.ts` makes the source `display` on Linux (`platform.hasLinuxDesktop`). `src/mesh/mesh.ts` adds
it beside the other sources of a computer's station. It is a port of still.fail's X11 path (`afk/main` 9967fe35be):

| Cue | still.fail |
| --- | --- |
| `src/screens/linux-session.ts` (`desktopEnvironment`, `graphicalSession`) | `station/src/screens/linux-session.ts` |
| `src/screens/linux-tools.ts` (`LinuxScreenTools`, `executable`) | `station/src/screens/linux-tools.ts` |
| `src/screens/x11-desktop.ts` (`X11Desktop`, `X11Input`, `EVDEV`, the JPEG and H.264 views) | `station/src/screens/x11-desktop.ts` |
| `src/screens/x11-h264.ts` (`X11H264`) | `station/src/screens/x11-h264.ts` |
| `src/screens/linux-desktop.ts` (`LinuxDesktop`, its X11 path) | `station/src/screens/linux-desktop.ts` |

still.fail's `docs/remote-screens.md` ("On Linux", "On X11") and `docs/linux-desktop-setup.md` describe the same code.

1. Each view looks for an active graphical login of the station's own user with `loginctl`, and prefers a local login.
   It takes that session's `DISPLAY` and `XAUTHORITY` from the user's systemd environment, or the session's display.
   Without such a login, it uses the environment that the station inherited (for example, an `Xvfb` that the user
   started). It never uses another user's login or X11 credentials.
2. `ffmpeg` (with `x11grab`) captures the root window, with the pointer, at 15 frames a second or less. `xdotool` posts
   the input. Both come from the station's `PATH`. The station does not carry them.
3. If one of them is missing on Debian or Ubuntu (x64 or arm64), the first view prepares a private pair: APT downloads
   `ffmpeg` and `xdotool` and their dependencies from the machine's configured sources, and `dpkg-deb` extracts them into
   `<data>/screen-tools/apt`. Nothing is installed in the system, no package script runs, and no administrator password
   is necessary. A view that waits more than 8 s is refused with "preparing", and the next view uses the pair. A failed
   preparation is tried again at the next view.
4. For a client that takes H.264, one `ffmpeg` captures raw pictures (at most 3840×2160) and keeps only the newest. A
   second `ffmpeg` encodes one picture with libx264 only when the station asks for the next frame, so an encoded delta
   frame is never dropped. A key frame request, or a large change of the bit rate, starts the encoder again with a new
   config. Otherwise (no libx264, or the client asks only for JPEG) one `ffmpeg` sends JPEGs.
5. Input: the wire's desktop input (`DesktopX11Input`) becomes still.fail's form for `X11Input`. Keys go by their place
   (Xorg's evdev key codes), so the remote keyboard layout does not move them. A modifier that the person did not press
   before the key is pressed around it. A key of no known place, and the wire's `text` (an IME's, a paste's), are typed
   with `xdotool type`. The keys and buttons a view holds are released when it ends.
6. A view says why it cannot open, in the station's language (`station.screen.linux*`): no desktop of this user, a
   Wayland session, the programs missing, being prepared or failed to prepare, or an X server it cannot reach.

The rules of "Who may view it" apply as they are. The view has no clipboard, system audio, or resize, and it shows all
X11 monitors as one picture. The encoders run in software.

## Who may view it

The mesh carries it, with the same rules as a Mac's display (`src/mesh/screens.ts`, `src/mesh/device-mesh.ts`): only
the computer's owner, only while the computer's access is Full, and only when the client has the Debug setting
"computers over the mesh" on. A view drives the screen only when it asks for control and its member may drive.

## How a view runs

1. `src/mesh/mesh.ts` makes one `WindowsDesktop` when `platform.hasWindowsScreen` is true and the release has the
   program: `COMMA_STATION_DESKTOP_SCREEN`, else `comma-desktop-screen.exe` beside `main.js` (`scripts/bundle.sh` puts
   it there), else the checkout's build.
2. `comma-desktop-screen status` gives the main display's size and whether Windows can capture it (Windows 10 1903 or
   later).
3. Each view starts its own `comma-desktop-screen view` process. The process inherits the station's environment, as
   the station's other native parts do. The station writes one JSON line
   `{codec, audio?, maxWidth, maxHeight, bitrate?}` on its standard input. Then both directions carry messages: a kind byte,
   the payload's length (4 bytes, big-endian), the payload. `native/desktop-screen/src/main.rs` lists every message.
4. The station asks for each frame (`next`). The process answers when the screen changed, so a still screen sends
   nothing. The station also sends `keyframe`, `input`, `rate` (the bit rate the link carries), and the clipboard,
   watch and audio messages ("Clipboard and sound").
5. The process answers with `info` (the size, the encoder and the codec it made), `config` (the size and the avcC or
   hvcC) before the first frame and at each change, `frame`, `event`, `cursor`, `clipboard`, `audio config` and
   `audio`.
6. If the process ends by itself (the display changed, the graphics driver restarted, a crash), the view starts a new
   process and continues from its key frame and config, the clipboard still watched. After more than three restarts in
   a minute, the view ends.
7. When the view ends, the station closes the process's input. The process ends, or the station stops it after 2 s.

A helper event with `stopped` carries the capture failure's reason. The mesh preserves that reason as `state.ended`,
with `endedCode: "screen_refused"`, when the view ends with a capture refusal. The client shows the reason and a retry
button. It does not repeatedly reconnect. Windows keeps its bounded process recovery before ending the view.

The process encodes H.265 when the client takes it and the GPU has a hardware H.265 encoder. Otherwise it encodes H.264
(the hardware encoder, else Microsoft's software encoder). Its `info` says which codec it made.

## Input

Cue's client sends a computer's screen the wire's desktop input: `{type: "move" | "down" | "up" | "scroll" | "keydown"
| "keyup"}` (`mesh/screens.ts` `helperInput` lets only these through). `DesktopWinInput` changes each event to
still.fail's form and gives it to `WinInput`, which makes the program's ops:

- Buttons: the wire's 0, 1, 2 (primary, secondary, middle) are Windows' left, right and middle buttons. A move while a
  button is held is a drag.
- Scroll: a page's pixels become Windows' wheel units (120 a notch, about 100 pixels).
- Keys: by their scan code (the key's place, whatever the keyboard layout). A modifier the person did not press
  before the key is pressed around it.

SendInput cannot reach the sign-in screen, UAC's secure desktop or the input of an app that runs as administrator.

## The pointer

The video leaves out the pointer. The process says where it is and its shape (`cursor`: `{x, y, shape}`, 0..1 of the
display, a CSS cursor name, `none` when hidden). The view sends it to the client as the state's `cursor`
(`ScreenView.watchCursor`, the wire's `state`). A client that does not draw it ignores it.

## Which computers offer a view

The station tells Salix in the connector's metadata, for a device connection:

- `capabilities.screen_view`: the station serves the computer's display on the mesh. True on a Mac with the Computer
  Use helper, on Windows with the program, and on Linux.

Salix keeps it among a device's public capabilities (`SalixEnv.Control`), and `Comma.Devices` gives it as the device's
`screen_view`. A station that does not say it (a station from before) gets false. Only a device connection says it: a
station that is not a computer's (a sandbox's, a workload's) does not. Every client views a screen on the mesh, and
there is no other way to it (as in still.fail):

- The desktop app views a computer's screen on the mesh. It offers "View screen" in Settings › Devices, and a
  computer's display in the screen menu, only where `screen_view` is true. It never offers the display of the computer
  it runs on: the view would show itself. That computer's simulators, emulators and phones stay in the screen menu and in "View simulators".
- The web page does the same through the browser's iroh (relays and Salix only, as a browser has no UDP). Where the
  browser has no `MediaStreamTrackGenerator` (Safari, Firefox), it draws the decoded frames on a canvas and shows that
  canvas's stream.
- The iOS and Android apps offer "View screen", and "Simulators and devices", where the device is online and
  `screen_view` is true. They decode the frames natively (VideoToolbox, MediaCodec) and acknowledge each one, as the
  page does.

When the mesh does not reach the computer (the core fails `unreachable`, `timeout` or `unavailable`), the client says
the computer is out of reach and tries again by itself.

### A server that does not send the field

An old or self-hosted server from before this field does not send it. This is a long-term case, not only a rollout
window. For this case, the client core uses an owner-approved compatibility policy that infers the field from the
platform (`screenSaid` in `clients/packages/core/src/comma/schemas.ts`). It is not the rule from before #4970: then,
the iOS app checked only that the device is online, and the desktop menu checked only `station_id`. Neither excluded
Windows or Linux.

The core applies this to `screen_view`:

1. An explicit boolean from the server stays as it is.
2. Otherwise, the core takes the device's `os` if it is not empty, else `system_info.os_type`.
3. If it finds no OS, or the OS is `darwin`, the field is true. Any other OS makes the field false.

A current server sends an explicit false for a station that does not say the capability (an old station). So this
policy covers only server responses without the field, not every old station.

A true from this policy means "the client may try". It does not confirm the capability, and the view can fail.

## Clipboard and sound

A Mac's `app` and `display` and a Windows `display` carry the clipboard (text and PNG) and the system output. The wire is
`@comma/mesh`'s `screen-wire.ts`: kinds 4 (`clipboard`, station to client), 5 (`audioConfig`), 6 (`audio`) and 21
(`clipboard`, client to station). The layouts and bounds are still.fail's (`docs/remote-screens.md`, "Wire"): text at
most 1 MB, a PNG at most 8 MB, audio at 48 kHz, stereo, in 20 ms packets: `pcm_s16le` of 3840 bytes, or one Opus
packet (about 64 kbit/s). Kind 23 (`sound`, client to station) turns the view's sound off and on.

The rules:

- The list says `clipboard: ["text", "png"]` for each of these screens. A client offers the clipboard only for the
  types that the list names. A station from before says nothing, so the client sends nothing and types a paste as text.
- The clipboard goes only to and from a view that drives the screen now. The station watches the machine's clipboard
  while the view is in Control, and stops when the view switches to Watch or ends. It drops a client clipboard frame
  while the view watches, of a type that the screen does not carry, or past its bound. A frame past 2 bytes + 8 MB ends
  the view, as any client frame past its bound does. The station posts a paste after the input before it.
- The machine sends a copy only when its clipboard changes after the watch starts. It does not send what the clipboard
  held before, what the view set itself, or the same content twice in a row.
- A view gets the system output only when it asks for `audio: "pcm_s16le"` or `audio: "opus"`. A client asks
  `opus` when its page decodes Opus (WebCodecs `AudioDecoder`). A Mac's helper then encodes Opus with AudioToolbox, and
  Windows' comma-desktop-screen with libopus (`unsafe-libopus`). A source that cannot make the encoder sends PCM, which
  an `opus` client also takes. The `audioConfig` says which. The view gets the sound in
  Watch and in Control. A preview never gets it. A client that mutes the sound sends `sound` 0: the station then asks
  the helper for no packets and sends none, until `sound` 1. The station keeps one packet in flight: it asks the helper for the next packet only after the
  last one went on the stream. A slow link thus drops sound at the machine (at most 300 ms is kept there), and no sound
  queues behind the pictures. The microphone is never captured.
- The client plays the sound with still.fail's reserve (`screenAudio.ts`). It starts after 100 ms is queued. A gap
  between packets longer than the reserve covers makes the reserve that long plus one packet, up to 300 ms. The client
  empties its queue after a stall (the reserve plus 200 ms queued) and when it runs dry, and fills the reserve again.
  Mute, a view that opens again, and closing stop the sound. Mute is this device's choice for the computer. The machine
  captures and sends while the view is open.
- A view of the app's own computer does not ask for the sound and plays none. The app knows its computer from its
  connector (Main's `connectorRuntime` state). Playing the sound there would put it on the same output, where the
  helper captures it again, and it would loop.
- The machine's sound does not include the sound of the Comma app, where the platform can exclude it: on macOS 14.2
  and later with the System Audio Recording grant, and on Windows build 20348 and later (below). The app plays the
  sound of the screens that it views. If two computers view each other, each would send that sound back to the other,
  and it would loop. Where the app's sound cannot be
  excluded, it is captured, and two such computers that view each other unmuted still loop. The sound of other apps is
  captured as before.
- A copy made on the screen goes onto this device's clipboard at once. The desktop app writes it through Main, as its
  other copies go (the renderer has no clipboard permission). If the write fails (the web: no focus), a toast offers
  to copy it with a press.

The Mac's helper: `CUStream/ScreenClipboard.swift` sets NSPasteboard (text, or PNG with a TIFF beside it) and pastes
with ⌘V, after the input before it, on the view's queue. While watched, it reads the changeCount every 0.5 s.
`CUStream/SystemAudio.swift` makes the sound into packets. The Comma apps are each process whose bundle identifier is
`surf.comma.desktop` or starts with `surf.comma.desktop.`: Comma, Comma Staging, Comma Dev, a source build, their
Electron helper processes (Chromium's audio service among them) and the Computer Use helper.

- A display's view: `CUStream/SystemAudioTap.swift`, a Core Audio process tap (`CATapDescription`
  `stereoGlobalTapButExcludeProcesses`, macOS 14.2 and later) in a private aggregate device with no sub-device. The tap
  excludes the Core Audio process object of each Comma process (`kAudioProcessPropertyBundleID`) and of the helper. The
  helper reads `kAudioHardwarePropertyProcessObjectList` again when it changes and sets the running tap's
  `kAudioTapPropertyDescription`. Thus a Comma process that starts to play during a view is excluded within
  milliseconds, with no gap in the sound. The tap gives 48 kHz stereo (other rates are converted). The helper sends no
  silence, as ScreenCaptureKit does not.
- The tap needs "System Audio Recording Only" (TCC `kTCCServiceAudioCapture`, `NSAudioCaptureUsageDescription` in the
  helper's Info.plist). Screen Recording does not give it. While the person has not answered, Core Audio holds
  `AudioDeviceCreateIOProcID` until they answer. Thus the helper starts the tap only when `TCCAccessPreflight` says
  that the grant is there, on a thread of its own, and waits at most 2 s. When the grant was not asked yet, the helper
  asks for it with `TCCAccessRequest` once while it runs and does not wait for the answer: macOS shows "Comma Computer
  Use would like access to record your system audio" with Allow. The next view with sound uses the tap. The helper's
  permission window (`PermissionFlowLayout`) cannot ask for it: System Settings has no list that an app can be dropped
  into for this grant. The tap captures no microphone and causes no microphone prompt.
- The fallback, and an app's view: a second ScreenCaptureKit stream that captures only sound (`capturesAudio`,
  `excludesCurrentProcessAudio`, no microphone; its picture is 2×2 once a second and not used). Its filter
  (`ScreenStreamSession.soundApps`) excludes the Comma apps. A Comma app that starts while a display's view is open is
  excluded when ScreenCaptureKit lists it, about 0.5 s after its start. ScreenCaptureKit excludes only the sound that an
  app plays in its own process. The desktop app plays its sound in Chromium's audio service, which is no app that a
  filter can name. Thus a display's fallback captures the Comma app's sound, and two such computers that view each other
  unmuted still loop. A display's view uses the fallback before macOS 14.2, without the grant, or when the tap does not
  start. An app's view captures only the sound of its apps, and never a Comma app among them, so it always uses this
  stream. The view's picture cannot use this filter: ScreenCaptureKit captures the sound of each app whose windows the
  picture shows.

A display's view sends one event `{audio}` that says whether the Comma app's sound is excluded, and why not, as Windows
does. The info says `audio: true` when the tap or the sound stream started. The desktop app keeps Chromium's audio
service out of process: while the microphone grant is not decided, macOS can hold a process's first sound until the
person answers, and in the main process the app's main thread would wait.

Windows: `native/desktop-screen` `clipboard.rs` and `audio.rs` as they were, but `audio.rs` excludes the sound of the
Comma app's process tree. The desktop app gives the station its process ID in `COMMA_APP_PID`, and the station and
`comma-desktop-screen` get it from their environment. With it, the capture is a process loopback with
`PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`. Microsoft gives build 20348 as the minimum for
`AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS`. The sound of the app is excluded only when the variable holds a process ID and
the process loopback activates and initializes. Without the variable, or if the process loopback fails, the capture is
the WASAPI loopback of the default output, as in still.fail, and the sound of the app is captured. In each case the
program sends one event `{audio}` that says whether the sound of the app is excluded, and why not.

| Cue | still.fail (`afk/main` 3d517e022e) |
| --- | --- |
| `screen-pipe.ts` (`helperClip`, messages 4, 5, 8, 9; `nextAudio`, `setClipboard`, `watchClipboard`) | `station/src/screens/desktop.ts` `HelperView` |
| `win-desktop.ts` (`clipboard`, the `audio` ask, `LastingView.nextAudio`, `setClipboard`, `watchClipboard`) | `station/src/screens/win-desktop.ts` |
| `mesh/screens.ts` (`ViewSession` `#audio`, `#clip`, `#setClipboard`; `screenInLimit`) | `station/src/mesh/screens.ts` (`#audio`, `run`, `#read`, `limitIn`, `parseClip`) |
| `CUStream/ScreenClipboard.swift` | `station/native/helper/.../Clipboard.swift` |
| `CUStream/SystemAudio.swift` (`SystemAudio`, `AudioPackets`) | `station/native/helper/.../SystemAudio.swift` |
| `clients/.../remote-screen/screenClipboard.ts` (`putClip`, `pasted`, `takesPaste`) | `web/src/screen/Transfer.tsx`, `ScreenViewer.tsx` (`paste`) |
| `clients/.../remote-screen/screenAudio.ts` (`ScreenAudioReserve`) | `apps/mbui/mbui/src/host/win_stream.cpp` (`sound_play`, `sound_stop`) |

## Frame timing

A view can log where the time of each of its frames goes. The log is off by default. It gives the times of each stage
(the encoder, the station's loop, the write to the stream, the client's core, its page and decoder), from which a
queue on the link and a decoder that holds frames can be told apart, with the limits below. It only records: the pace
makes the same decisions with it on. With it on, the client sends more on the way back (`received`, the `ack`'s
times), and the station writes the log. With it off, the views do no timing work on the wire or in the log, but the
core and the page still keep a small map of frames.

Turn it on for a station on a Mac:

1. Quit the Comma app.
2. Run `launchctl setenv COMMA_STATION_SCREEN_TIMING 1`.
3. Open the Comma app. The app starts its station, and the station gets the variable.
4. Open a view of the Mac's `display` or `app` from another computer. A preview does not log.
5. Read the lines: `grep 'frame timing' "$HOME/Library/Application Support/@comma/station/station.log"`. Comma Staging
   uses `@comma-staging`, and Comma Dev uses `@comma-dev`.
6. To turn it off, quit the app, run `launchctl unsetenv COMMA_STATION_SCREEN_TIMING`, and open the app again.

With the variable set (and not `0`), each view does the following (`src/mesh/screen-timing.ts`):

- Its first `state` says `timing: true`. The view asks the helper `timing: true`.
- The helper sends message 66 just before each frame: the frame's timestamp, when the encoder took the picture, when
  the encoder gave the frame out, and when the helper sent it. Each is 8 bytes, µs on `HostClock`.
- The client's core sends `received` (kind 22) as soon as it has a video frame whole, before the page and its decoder.
- The client's `ack` has 20 more bytes: `held` (core, from the whole frame to the `ack`), and from the page having the
  frame: `decodeIn`, `decodeOut`, `shown` (handed to the track) and `ack`. Each is µs on that process's own clock.
- The station logs one line each second at most while the view goes, and one more line when the view ends, with at
  most 120 frames each. A line comes only on an `ack` or at the end: a view that gets no `ack` logs nothing until it
  ends. It keeps at most 240 frames that are not acknowledged. It counts frames past these bounds as `dropped` and does
  not log them.

One line has these fields: `view` (a number), `screen`, `link` (what the native mesh says of the connection now:
`via`, the chosen path's `rttMs`, `cwnd` in bytes, `congestionEvents`, `sentDatagrams`, `lostPackets`, and the
connection's `txBytes`, `rxBytes` and `lost`), `pace` (`rate`, `rtt`, `through`, `unacked`, and `stalled`: how long
the station's loop stood still so far, in ms), `columns` and `frames`. Each frame is an array in the order of
`columns`:

- `ts` (µs), `key` (1 or 0), `bytes`.
- In ms after the capture, on the host's clock: `encodeStart`, `encodeDone`, `helperSent`, `got` (the station read
  the frame), `queued` (in line for the stream), `writeStart`, `writeDone` (the native stream took the bytes into the
  QUIC send buffer), `received`, `acked`.
- In ms on the client's clocks: `held`, `decodeIn`, `decodeOut`, `shown`, `clientAck`.

What the differences show, and what is mixed into each:

- `writeDone` minus `writeStart`: how long the write took. It includes a wait for the QUIC send buffer or flow control
  (the frame's first bytes are already on the link then) and the station's loop. It is not only the station's work.
- `received` minus `writeStart`: from the start of the write to the station reading the client's `received`. It
  includes the link both ways, the client's core and its queue of messages back, and the station's loop. It is not
  the link's round trip alone.
- `received` minus `writeDone`: what is left of that after the write took the bytes. A write held back 1 s by the send
  buffer, then `received` 10 ms after it, shows 10 ms here: read it with `writeDone` minus `writeStart`.
- `acked` minus `received`: the difference between two messages back on the same stream. It includes the page and its
  decoder, and how the two messages waited on the way back. Messages held back together on the way make it small. Use
  `held` (the core, from the whole frame to the page's `ack`) and `decodeOut` minus `decodeIn` (the page, from the
  frame given to the decoder to its output) for what the client held.

`held` is in whole ms on the core's clock (`ctx.now()`, the wall clock): a change of the system time can make it
wrong. A value is
`null` when no one said it: a helper or client from before, a frame that a later `ack` acknowledged (let go, or two in
the decoder), or a frame that was never acknowledged.

Old and new parts work together. The station and the client ship in the same app, but a client on one computer views a
station on another, which can have a different release. A station from before does not say `timing`, so the client
sends no `received` and no `ack` times. A station from before reads only the first 8 bytes of an `ack`, and lets kind
22 be. A helper from before lets `timing` be and sends no message 66.

Not recorded:

- When the picture is on the screen. `shown` is when the page gives the frame to the `MediaStreamTrackGenerator`.
- Bytes in flight and the bandwidth estimate. The addon's `noq-proto` 1.3 `PathStats` has neither.
- The Windows and Linux desktops' encoder times. Their programs do not send message 66.
- The clock offset between the station and the client. Client times are durations on the client's own clocks.

## Picture quality (画质)

The viewer's toolbar has a 画质 menu: 自动, 流畅, 高清 and 原画. The code is a port of still.fail (`afk/main`
0a70d5e9d0):

| Cue | still.fail |
| --- | --- |
| `src/mesh/screen-pace.ts` `Quality`, `rateCeiling`, `Sizer` (`whole`) | `station/src/mesh/screen-pace.ts` |
| `src/mesh/screens.ts` `askOf`, `ViewSession` (`#quality`, `#setCeiling`) | `station/src/mesh/screens.ts` `asked`, `ViewSession` |
| `clients/packages/core/src/screen-views.ts` (`quality` in the ask, `screenQuality`) | `client/core-ts/src/screens.ts` `qualityOf` |
| `clients/packages/app/src/components/remote-screen/screenQuality.ts`, `ScreenStreamChrome.tsx` `ScreenQualityMenu` | `apps/mbui/src/sfpages/screen.mbt` `screen_quality`, `ScreenSess::bounds`; `screen_panel.mbt` |

What each choice does:

| 画质 | The bounds that the client asks | The bit rate's ceiling | A slow link |
| --- | --- | --- | --- |
| 自动 (no `quality`) | A computer: none, so the station uses 1920×1080. A device: its `side`. | Pixels × 16 a second (1080p: 33 Mbit/s), at most 60 Mbit/s | The Sizer asks 1280×720. |
| 流畅 (`smooth`) | 1280×720. A device: its long side at most 1280. | Pixels × 6 (1080p: 12.4 Mbit/s) | The Sizer asks 1280×720. |
| 高清 (`hd`) | 1920×1080. A device: its long side at most 1920. | Pixels × 16 | The Sizer asks 1280×720. |
| 原画 (`original`) | 7680×4320: the largest size that the source supports (see "Platforms") | Pixels × 16 | The Sizer does not make the picture smaller. The link gets fewer frames. |

The ceiling is never less than the source's own rate (pixels × 3, at least 1 Mbit/s). The link lowers the rate below the
ceiling when it carries less (the pace).

Through Salix, every 画质 is held to `SALIX_RATE` (8 Mbit/s), Cue's bound on the bit rate that the station asks the
encoder for. No 画质 can go above it. 流畅's lower ceiling stays lower. This bound is a request policy. It is not a cap
on the bytes on the wire (the transport and its bursts add to it), and it does not guarantee bandwidth to a view. The
relay's node budget is shared by all the connections that the node relays, and it is configurable (`@node_budget`).
One closed-loop observation (2026-11-08, a local stand-in of the relay at its default budget): a view asked 16 Mbit/s
went past the node's budget as motion started, and the view stalled. 原画 through Salix keeps its bounds, so the pace
gives it fewer frames when the link carries less.

The station reads `quality` from the view's ask (`askOf`). It takes only `smooth`, `hd` and `original`. It ignores
another value, and the `quality` of a preview (`peek`). It sets the ceiling again from the picture's size and
`quality` at each `config` and each change of the connection's way (`#setCeiling`).

The core keeps the choice with the account on this device (`screenQuality`, `devices.chooseScreenQuality`). A sign-out
forgets it. Each account has its own. A change opens the view again: the client's stream is keyed by the 画质, so the
viewer holds a new stream. When no other stage holds the old stream, the client closes it at once: it no longer
keeps one of the member's three views for 1 s more. The station frees that view asynchronously, when the old view's
session ends (`session.run(...).finally`), so the view is not guaranteed to be free before the new request arrives. A
view's 画质 does not change while it runs.

Compatibility. Stations and clients update at different times, on different machines, so no part of this is
required:

- A station from before ignores `quality`. The view is 自动 there. The client still asks the bounds of its 画质.
- A client from before sends no `quality`. The view is 自动.
- The core sends `quality` only when it is a value that it knows.

Platforms. Every screen source goes through the same `ViewSession`, so the same ceiling and Sizer apply to each
(`src/mesh/mesh.ts` gives `makeScreenViews` all the sources). What each source does with them:

- The Mac's app and display (`src/screens/helper.ts`), and Windows' display (`src/screens/win-desktop.ts`): they take
  `rate` and `bounds`, so the ceiling and the Sizer both apply. 原画 gives the screen's own size within the rectangle
  that the client asks (7680×4320).
- iOS Simulators (`src/screens/simulator.ts`, a `HelperView`): they take `rate` and `bounds`. The long side of the
  bounds is the bound both ways.
- Linux X11 (`src/screens/x11-desktop.ts`): it takes `rate` while the view runs (`X11H264` makes the `ffmpeg`
  encoder again when the change and the interval allow), so the ceiling applies. It cannot change its bounds while the
  view runs, so the Sizer does not change its size. A new view's bounds apply, at most 3840×2160: that is 原画's size.
- Android devices (`src/screens/android.ts`): scrcpy takes no new rate while it runs, and no new bounds. The rate comes
  from the side asked (`bitrateOf`). So the 画质 sets the bounds that the client asks, and with them the rate. 流畅's
  1280 and 高清's 1920 are upper bounds within the device's `side`, so two choices can give the same size. 原画's long
  side is at most 2560 (`sideOf`), at 8 Mbit/s.

## Build and release

`scripts/native.ts` has the part `desktop-screen` (win32-x64): cargo-zigbuild cross-builds it for
`x86_64-pc-windows-gnu`, as for the station's other Windows parts. The composite action `station-native-windows` gets
it from R2 or builds it. `scripts/bundle.sh win32-x64` copies it beside `main.js`, and the desktop app carries that
release. The Station workflow runs the crate's tests that run on every OS (`cargo test`); its Windows-only tests run
with `cargo test` on Windows.

## Deviations from still.fail

| Deviation | Reason |
| --- | --- |
| The crate and program are `comma-desktop-screen`, and the clipboard window's name is too. | Cue's station names its own parts (`comma-station`, `comma-runner`). The code is the same. |
| The source id is `display`, not `desktop`. | Cue's clients open a computer's whole display as `display` (the Mac's helper source). |
| The TS view never asks for parts of the display (regions), reveal or the display's scale and resolution, and does not run agent-desktop. The Rust program still has them. | Cue's `ScreenSource` and `ScreenView` have none of these. A later change that adds one to Cue can use the program as it is. |
| The client's clipboard frame is kind 21, not 19. | Cue's `control` frame took 19 first. Kind 20 stays free for still.fail's `look`. |
| A clipboard watch follows the open view's Control: it starts when the view switches to Control and stops when it switches to Watch. | Cue switches Watch and Control on the open view (still.fail opens a new view). still.fail stops the watch only when another person takes the screen. |
| The Mac helper's clipboard takes its pasteboard as a parameter and runs its set and paste on the view's queue. The paste is the view's ⌘V, so an app's view sends it to its windows. Reveal (message 6) is not ported. | Cue's views post input on their own queue, and an app's view sends keys to its windows. The tests use a private named pasteboard, never the person's. |
| An app's view captures only the sound of its apps. | Cue's app view uses a ScreenCaptureKit filter that includes only those apps. still.fail has no app view. |
| The client plays sound on Web Audio with win_stream.cpp's adaptive reserve, not apple_stream.m's fixed 60 ms one. | Cue's client is a web page. The adaptive reserve is still.fail's later rule, made for a Mac's packets that come late now and then. |
| A view of the app's own computer carries no sound. | A computer that views itself would play the sound into its own capture, and it would loop. still.fail does not handle this. |
| The machine's sound excludes the Comma app's sound: on a Mac (14.2 and later, with System Audio Recording) a Core Audio process tap without the Comma processes, else a second, sound-only ScreenCaptureKit stream without the Comma apps, which still hears the app's audio service; on Windows (build 20348 and later, with `COMMA_APP_PID`) a process loopback without the app's process tree; elsewhere the endpoint loopback, which still loops. | Two computers that view each other would send each other's sound back, and it would loop. still.fail (`afk/main` 6719d82971) has the same loop: its helper excludes only its own sound, and its `audio.rs` is the endpoint loopback. |
| The client writes this device's clipboard through Main in the desktop app, not with `navigator.clipboard`. | Cue's desktop session denies every renderer permission, clipboard-write included. |
| The client does not send files to the machine, and has no paste button for a phone. | Cue's desktop client has no drive upload to a screen and no phone viewer for computers. |
| `HelperView` takes Cue's wire input through `DesktopWinInput`. | Cue's client sends `{type: …}` events to a computer, not still.fail's `{t: …}`. `WinInput` stays as it is. |
| The pace (`screen-pace.ts` `Pacer`) finds a queue only when every acknowledgement in the last 500 ms (and two round trips) is late, or one frame waits longer than that window. The baseline is the 10th percentile of the round trips, not the minimum. The oldest frame may also wait twice the link's jitter. A frame's own bytes at the asked rate do not count as a wait, so a key frame is not a queue. The bit rate counts only the last second of acknowledged frames. After 2 s with no queue, the rate goes up by 1.5 at each step, not by 1.3. Near the rate that went through at the last queue, it goes up by 1.15. | still.fail (`afk/main` 7470ca2abe, the same in b23c3baff7) counts one frame held past the minimum round trip and 30 ms, again within a second, as a queue. On a Wi‑Fi LAN (round trip 9 to 70 ms, 240 Mbit/s), this jitter kept a view at 300 kbit/s and 1280×720 for 10 minutes. At that rate, the encoder needed 1.2 to 1.9 s for each 64 KB key frame. |
| The pace does not count a frame that is alone on the link as a queue. Such a frame has no frame sent after it for longer than the pace lets the oldest frame wait, and the pace did not hold a frame back. Its wait starts when the next frame goes. With one frame on the way, the pace always lets the next frame go. For 1 s after the picture changes size, the pace does not count round trips. At most 60 frames are on the way, not 16. The Sizer counts the time to the smaller picture again when its steps are more than 500 ms apart. | A still screen sends a frame only now and then. The client's H.265 decoder keeps the newest frame until the next comes, so the station gets the acknowledgement seconds late. On a Wi‑Fi LAN of 240 Mbit/s (2026-11-07), this cut a still view to 0.33 Mbit/s and 1280×720, and the next motion stayed low for 1 to 2 minutes. The new decoder for a larger picture cut the rate two times. On Salix (round trip 245 ms), 16 frames on the way held a view at 17 to 28 frames a second. |
| The pace lowers the bit rate for a queue only while the source uses the rate. The median of the last three frames sent must be a quarter or more of one frame's share of the rate (the rate over 60 frames a second). | A still screen sends a 1 to 1.3 KB frame about 30 times a second. A lower rate does not make these frames smaller. On a Wi‑Fi LAN of 240 Mbit/s (2026-11-08), the link took 1 to 5 s for each 127 to 195 KB key frame of a still screen. The frames after the key frame waited behind it. The pace took this for a queue and cut the rate to what the screen sent, 0.35 to 0.6 Mbit/s. The Sizer then made the view 1280×720 for 19 to 88 s. |
| The Mac's helper makes a key frame only when it is asked for one, not each 10 s. Its key frames are at most an hour apart (`MaxKeyFrameIntervalDuration` 3600 s). An interval of 0 is the encoder's own, and the software H.264 encoder makes a key frame each 4 frames. | The view's stream is reliable and in order, so a periodic key frame repairs nothing. On a still screen, it was the only large frame, and it arrived 1 to 5 s late (see the row above). The client asks for a key frame when its decoder needs one. |
| 自动 asks no bounds for a computer, so the station uses 1920×1080; a device asks its `side`. | still.fail's 自动 asks the stage's size in device pixels. Cue's views asked these bounds before 画质, and 自动 keeps them. |
| Through Salix, every 画质 stays at `SALIX_RATE` or lower (see "Picture quality"). | still.fail's relays have no such budget. |
| A change of 画质 opens a new view. | Cue's station has no `screen.bounds` to ask an open view again. A device's new `side` opens a new view too. |
| The 画质 is kept with the account on this device, in the core. | still.fail keeps it in its `prefs` topic. Cue's core keeps per-account choices in the account's data. |
| The menu is a list in the toolbar, with what each choice asks beside it. | still.fail's 控制中心 has a segmented control. Cue's toolbar uses the design system's `Menu`. |
| The view has no preview (`peek`) and no JPEG. | No computer screen in Cue offers a preview, and Cue's mesh views ask for H.264 or H.265. |
| A station keeps at most six previews (`peek`) open, and one client (its mesh device) at most two. A refused view is logged. | still.fail (`afk/main` 6c009b70bf) has no limit on previews and logs no refusal. Each preview opens its own view of its source, and an Android preview starts scrcpy. One client's cards do not take another client's place. |
| Linux: the source id is `display`, and a view runs at 15 frames a second. | Cue's `ViewOptions` has no `fps`; 15 is still.fail's most. |
| Linux: `DesktopX11Input` takes the wire's `{type: …}` input, `text` too. `X11Input` stays as it is. | As for `DesktopWinInput`. |
| Linux: the X11 views do not use `HelperView`. | still.fail's X11 views have no helper process: `ffmpeg` and `xdotool` run from the station. The views are still.fail's own. |
| Linux: `X11H264` takes the clock its restart pacing reads. | A test moves it instead of waiting real time. |
| Frame timing (`received`, the `ack`'s times, the helper's message 66) is Cue's own. | still.fail logs no frame times. Its acknowledgement comes when the decoder gives the frame out, so a round trip includes what the decoder holds. |
| Linux: no Wayland portal and no GStreamer/XTest X11 fallback (still.fail's `linux-portal.ts`, `linux-portal.py`, `linux-x11.py`). A Wayland session is refused (`linuxWayland`). | Both send only JPEG, and Cue's desktop viewer decodes only H.264 and H.265. For the same reason, the X11 JPEG view is not reached by the current viewer. |

## Tests

- `native/desktop-screen`: the crate's own tests (`cargo test`; the capture, encoder and HDR tests on Windows only).
- `test/win-screen.test.ts`: `WinInput` and `DesktopWinInput`, a view through a fake process (frames, config, input,
  rate, pointer, H.265), the restart of a process that ends by itself, and the real program on a Windows machine with
  a display.
- `test/mesh-screens.test.ts`: the Mac's views end to end on the memory mesh through a fake helper socket (frames only
  when asked, H.265, the restart after a grant, the refusal, bounds, the system output only to a view that asked, the
  clipboard only while the view drives, its bounds and types), and Windows' display through a fake process, with the
  pointer in the state, the input posted, and its clipboard and sound.
- `test/x11-desktop.test.ts`: the reasons a desktop gives; on a real X server (`COMMA_TEST_X11=1`), the encoder's paced
  restarts and key frames, the JPEG fallback, repeated views that leave no `ffmpeg`, and an X server that exits.
- `test/mesh-linux-screen.test.ts`: the Linux display end to end on the memory mesh with fake `ffmpeg` and `xdotool`
  (listing, H.264 config and frames, input only while the view drives, refusals); on a real X server, a decoded
  picture, a pointer move, keys and typed Chinese text.
- `test/linux-screen-tools.test.ts`, `test/linux-session.test.ts`: the private APT pair (with a fake APT), the logind
  lookup and the desktop's choice of session.
- `test/connector/screen-view.test.ts`: `screen_view` on a Linux computer, and none on a station that is not a computer's.
- The Station workflow's job "Station Linux desktop" runs these files on Xvfb.
- `clients/packages/mesh/test/screen-wire.test.ts`, `clients/packages/core/test/screen-views.test.ts`: the clipboard and
  audio frames, their bounds, the `ack`'s times and `received`, and the core's events and calls.
  `meshScreenDecoder.test.ts`: the page's times in each `ack`.
- `clients/packages/app/src/components/remote-screen/test/`: `screenAudio.test.ts` (the reserve),
  `screenClipboard.test.ts` (which paste goes onto the screen's clipboard), `meshScreenClipAudio.test.ts` (what the
  stream hands on).
- `test/screen-timing.test.ts`: the variable, a frame's times in a line, and the line's bounds. `test/mesh-screens.test.ts`
  also has a view that logs its frames' times end to end, and one that does not. `test/comma-mesh-native.test.ts`: the
  addon's path and connection figures.
- `test/screen-pace.test.ts`: each 画质's ceiling (`rateCeiling`, `viewCeiling` through Salix), 原画's whole picture
  (`Sizer`), and each 画质 on a whole view (a LAN, a narrow link, Salix). `test/mesh-screens.test.ts`: the ask's
  `quality` (`askOf`). `clients/packages/core/test/screen-views.test.ts`: `quality` in the ask, and the choice kept
  with the account. `remote-screen/test/remoteScreenStream.test.ts`: the bounds and `quality` of each 画质, a new
  view for a new 画质. `remote-screen/test/ScreenQualityMenu.test.tsx`: the menu.
- `test/screen-pace.test.ts`: `Pacer` on simulated links (a Wi‑Fi LAN, a link narrower than the frames, a far relay, a
  short congestion), `Sizer`, `Sharpener` and `FrameLatency`. A whole view (the pump, a decoder that keeps the newest
  frame, the Sizer and the Sharpener) on a still screen between motion, on a still screen whose key frames the link
  takes seconds for, on a picture that grows from 1280×720 to 1920×1080, and on a relay of 200 ms round trip.
- `ComputerUseHost/Tests/CUTests/ScreenViewTests.swift`: a picture encoded only when asked, a dropped key frame
  still owed, no key frame that was not asked for, and message 66 only when asked. `ScreenClipAudioTests.swift`: the clipboard set, pasted and watched on a private pasteboard; sound made
  into 20 ms packets; samples made interleaved stereo; the sound filter without the Comma apps; the tap without the
  Comma processes. `HostClockTests.swift`: a stamp includes the time the Mac slept. `PasteBannerTests.swift`: input
  after a paste on a simulator waits for the banner (simulator-screen.md).
- `clients/apps/electron/src/main/test/station.test.ts`: the desktop app gives the station `COMMA_APP_PID`.
