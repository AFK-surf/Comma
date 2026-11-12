# Comma app template

This is the template for Comma apps. An app runs inside Comma (Mac and web),
in a sandboxed frame. It has no network and no URL of its own. It uses Comma
through `window.comma`: storage, the viewer, AI chat, Drive and more.

Comma makes a new private repository from this template when you ask it to
build an app. A coding agent then writes the app and deploys it with the
station tool `app_deploy`. The rules for the agent are in [AGENTS.md](AGENTS.md).

The stack is Node, Vite, TypeScript, React, shadcn/ui, Tailwind CSS and
lucide-react icons. The shadcn/ui theme follows Comma's colors in light and dark.

## Develop locally

```sh
npm install
npm run dev     # opens the app with an in-memory mock of window.comma
npm test        # unit tests with the mock
npm run build   # dist/index.html (and dist-worker/index.js with a backend)
```

## Files

| Path                 | Use                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------- |
| `comma-app.json`     | Name, capabilities, storage stores and the optional backend.                        |
| `src/`               | The React frontend. `src/main.tsx` starts it.                                       |
| `DESIGN.md`          | The design guide: app architecture, size classes, type roles, color, controls.      |
| `src/components/`    | The app's frame and blocks: sections, screens, split view, sheet, lists, states.    |
| `src/components/ui/` | shadcn/ui components. Add more with `npx shadcn@latest add <name>`.                 |
| `src/index.css`      | Tailwind CSS and the shadcn/ui theme, mapped to Comma's `--comma-*` design tokens.  |
| `src/comma/`         | The Comma SDK (`sdk.ts`) and its local mock (`mock.ts`). Comma updates these files. |
| `worker/`            | The optional backend (a Cloudflare Worker).                                         |

## `comma-app.json`

```json
{
  "name": "Habit tracker",
  "description": "Track daily habits.",
  "icon": "icon.png",
  "cover": "cover.jpg",
  "capabilities": ["identity.basic", "ai.chat"],
  "storage": ["user", "device"],
  "backend": {
    "entry": "worker/index.ts",
    "egress": ["api.open-meteo.com"],
    "secrets": ["OPEN_METEO_KEY"]
  }
}
```

- `name`: 1 to 60 characters.
- `icon`: a PNG, SVG or WebP file in `dist/` (at most 256 KiB). Optional.
- `cover`: a JPEG, WebP or PNG screenshot of the first screen in `dist/`, for the
  Apps gallery (at most 160 KiB and 1200 × 1200 pixels; 780 × 585 is enough).
  Optional. See AGENTS.md for how to make it.
- `capabilities`: `identity.basic`, `ai.chat`, `web.search`, `chat.draft`, `tasks.create`,
  `files.pick`, `drive.app_folder`, `calendar.read`, `notifications`,
  `clipboard.write`, `links.open`, and the device capabilities below.
- `storage`: `app`, `user`, `device`.
- `backend`: optional. At most 20 `egress` hosts (no IP addresses, no
  wildcards) and 20 `secrets` names (`A-Z`, `0-9`, `_`).

## Device capabilities

Comma runs SDK device operations in the host after the viewer allows them.
Declared `usb` and `bluetooth` capabilities use browser APIs directly in the
opaque frame. No separate app domain is required.

| Capability       | SDK                                         | Viewer                      |
| ---------------- | ------------------------------------------- | --------------------------- |
| `microphone`     | `comma.microphone.start(onSamples, onEnd?)` | Grants once                 |
| `camera`         | `comma.camera.capture({ facing? })`         | Takes each photo            |
| `location`       | `comma.location.current()`                  | Grants once                 |
| `screen.wake`    | `comma.screen.keepAwake(on)`                | No grant                    |
| `fullscreen`     | `comma.screen.fullscreen(on)`               | No grant                    |
| `clipboard.read` | `comma.clipboard.read()`                    | Confirms each read          |
| `share`          | `comma.share({ title?, text?, url? })`      | Uses the system share sheet |
| `haptics`        | `comma.haptics(ms or [on, off, on, ...])`   | No grant                    |
| `midi`           | `comma.midi.start(onMessage, onEnd?)`       | Grants once                 |
| `usb`            | `navigator.usb`                             | Device chooser              |
| `bluetooth`      | `navigator.bluetooth`                       | Device chooser              |

- USB and Bluetooth device selection needs a user click and a supported browser.
  Web Bluetooth uses BLE/GATT. WebUSB does not replace Web Serial or WebHID.
  Check `navigator.usb` or `navigator.bluetooth` before use, rather than `comma.supports(op)`.
  Device grants belong to the top-level Comma origin. Other apps with that declared
  capability can access previously authorized devices. A separate iframe origin
  does not give these browser grants a per-app scope.
  Electron shows a device chooser and keeps selected device permissions in memory.
- `microphone.start` calls `onSamples` with mono PCM chunks (`Float32Array`,
  -1 to 1) at the returned `sampleRate`, without echo cancellation, noise
  suppression or gain. Call `stop()` on the returned handle when done.
- `comma.microphone.devices()` lists audio inputs with `id`, `name`, and optional
  `channelCount` and `sampleRate` ranges (`{ min, max }`). Missing ranges mean
  the browser did not expose them. They do not identify physical ports. Give
  an `id` to `microphone.start(onSamples, onEnd, { deviceId })` to record that
  input; without it, the system default records. The handle's `device` is the
  input that records. When that input is removed, `onEnd` gets `ended`.
- `comma.microphone.startChannels(options, onSamples, onEnd?)` records separate
  input channels. Set `options.channelCount` to the exact input count (1 to 32,
  within the browser and device limits). Set `deviceId` to select an input.
  Optional `channels` selects zero-based indices in delivery order, without duplicates.
  Without `channels`, all input channels are delivered. The callback receives
  a `Float32Array[]`, one PCM array per selected channel, at the handle's `sampleRate`.
  The handle also returns `channelCount`, `channels`, `device`, and `stop()`.
  Unsupported counts fail. The host does not silently mix down to fewer channels.
  Capability ranges do not guarantee every combination. The browser can resample
  the input; `sampleRate` describes the delivered PCM, not the device's native rate.
  This call uses the same microphone grant and lifetime as `start`.

  ```ts
  const recording = await comma.microphone.startChannels(
    { deviceId, channelCount: 4, channels: [2, 0] },
    ([thirdInput, firstInput]) => processAudio(thirdInput, firstInput),
    (reason) => showStopped(reason),
  );
  // Later: await recording.stop();
  ```

- `comma.microphone.watch(onChange, onEnd?)` returns the current `devices` and
  calls `onChange` with the new list when an input is connected or removed.
- `midi.start` returns the input devices and calls `onMessage` with
  `{ input, data, time }` for each message. System exclusive messages are not
  sent.
- `camera.capture` resolves with a JPEG `{ mime, width, height, data }`, or
  null when the viewer closes the sheet.
- `screen.fullscreen` and `share` need a click or a key press just before the
  call. `haptics` resolves `{ played: false }` where the device cannot vibrate.
- Platforms: Comma web runs all of them where the browser supports them. The
  Mac app runs all except `location`, `share` and `haptics`. The iOS and
  Android apps run none of them yet. Check `comma.supports(op)` first.

## Decision model

Add `ai.chat` to `capabilities` for all AI calls, then call the SDK:

```ts
const result = await comma.ai.decide({
  state: { message: "Schedule a team meeting" },
  questions: {
    route: {
      type: "choice",
      instructions: "Select the task",
      criteria: { meeting: "Arrange a meeting", none: "No task" },
    },
  },
});
// result.model identifies the model.
// Narrow result.answers.route by its type before reading choice.
const route = result.answers.route;
if (route?.type === "choice") console.log(route.choice);
```

One `ai.chat` grant covers all `comma.ai.*` calls, including chat and decisions. Comma bills the viewer's Workspace.
The model receives only the supplied state. No app backend, API key or conversation history is needed.
Requests contain 1 to 8 questions and at most 12 KiB of JSON, including the questions.
`state` can be a string, object or array. Question and choice keys use letters, digits, underscores or hyphens, with at most 64 characters.

- `choice`: supply `instructions` and a `criteria` map of 2 to 32 option descriptions.
  The answer has `choice`, `probabilities_bp` and `confidence_bp`.
- `noul`: supply `instructions` and optional `criteria: { true: "...", false: "..." }`.
  The answer has `probability_bp`, the probability that the answer is yes.
- `score`: supply `instructions` and a `criteria` array of 2 to 10 descriptions, from lowest to highest.
  The answer has `score_milli`, `probabilities_bp` and `confidence_bp`.

Probabilities and confidence use basis points: 9,000 means 90%.
Confidence describes the answer distribution, not correctness or the selected option's probability.
Scores use 1,000 units per level, starting at zero. With two levels, a score of 800 means 0.8.
The score distribution uses string keys such as `"0"` and `"1"`.
Guests receive `signup_required`. Rate limits return `rate_limited`. Missing configuration and provider failures return `unavailable`.
For local tests, pass `aiDecide: (request) => result` to `createMockComma()` or `installMockComma()`.
The local mock returns `unavailable` until you supply this handler.

## Web search

Add `web.search` to `capabilities`, then call the SDK:

```ts
const results = await comma.web.search("accessible chart design");
// Each result has title, url and text fields.
```

The viewer grants access once. Queries go to Exa through Comma's server. No app backend or API key is needed.
Queries contain 1 to 2,000 characters. Results contain at most five entries, with excerpts of at most 1,200 characters.
Guests receive `signup_required`. Provider failures return `unavailable`.
For local tests, pass `webSearch: (query) => results` to `createMockComma()` or `installMockComma()`.

## Limits

- `dist/index.html` at most 8 MiB; the whole `dist/` at most 25 MiB and 2,000 files.
- The backend at most 3 MiB compressed.
