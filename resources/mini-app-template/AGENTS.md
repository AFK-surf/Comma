# Rules for coding agents

This repository is a Comma app. Comma runs it inside the Comma Mac and web apps,
in a sandboxed frame with no network and no URL of its own.

## Tech stack

Use this stack unless the user asks for another:

- Node and npm. Keep `package-lock.json` in the repository.
- Vite, TypeScript (strict) and React.
- shadcn/ui for every control, card, dialog and form. Add a component with
  `npx shadcn@latest add <name>`. It goes to `src/components/ui/`. Compose
  screens from these components before you write your own.
- Tailwind CSS for layout and spacing. Do not write a second stylesheet.
- lucide-react for icons.

Do not add a UI library, CSS framework, state library or router beside these.
Add another npm package only when the app needs it, and only if it works
without network at run time.

## Look

`DESIGN.md` is the design guide. Read it before you build a screen, and
check its last section before each deploy. In short:

- The app uses Comma's design system and only its tokens. `src/index.css`
  maps Comma's tokens (`--comma-*` variables that Comma sets on `<html>`) to
  the shadcn/ui and Tailwind theme, for light and dark. Do not write a value
  outside the theme: no hex, `rgb()` or named colors, no arbitrary values
  (`text-[15px]`, `p-[13px]`), no fonts, no `dark:` color classes.
- Build the app as a mature app is built: a phone app that the same code lays
  out as an iPad app and a web app. Use `src/components/`: `AppShell`,
  `useNavigation` and `useSizeClass` (navigation.tsx) for sections and screen
  stacks, `Screen` (screen.tsx) for every screen, `SplitView` (split-view.tsx)
  for a list and its detail, `Sheet` (sheet.tsx) for a task over a screen,
  `List`, `ListItem` and `ListSection` (list.tsx), `EmptyState`, `ErrorState`
  and `LoadingList` (state.tsx), `useToast` (toast.tsx), then shadcn/ui.
- Set text by role (`text-body`, `text-headline`, `text-large-title`...),
  never by size. A role is iOS's size on a touch screen and Comma's desktop
  size with a mouse.
- The app runs from 320px wide and inside a 360px tall chat card. The phone
  layout is the default; the components switch to the iPad and web layouts.
- Use another look only when the user asks for one: in the request, with a
  screenshot or with a style file (design tokens, a stylesheet, a brand guide).
  Then put that look's values in place of the Comma tokens it changes, in
  `src/index.css` and nowhere else. The components keep using the theme classes.
  Keep light and dark, and keep the Comma tokens for everything the look does not
  set.

## Build, test, deploy

1. Install: `npm install`.
2. Build: `npm run build`. It type-checks, builds the frontend to one file,
   `dist/index.html`, and builds the backend (if `comma-app.json` has one) to
   `dist-worker/index.js`.
3. Test: `npm test` runs the unit tests with the mock (`src/comma/mock.ts`).
   Also check the app in a headless browser: run `npm run dev` and open
   the printed URL. Outside Comma, `src/main.tsx` installs the mock, so every
   `comma.*` call works with in-memory data. If `CHROMIUM_BIN` is set, the
   machine has a browser at that path: use it and do not download one. With
   Playwright: install `playwright-core` and launch with
   `{ executablePath: process.env.CHROMIUM_BIN }`.
4. Cover: the Apps gallery shows a screenshot of the app's first screen.
   Make it in the headless browser, with the app on `npm run dev`:
   - Set the viewport to 390 × 844 with device scale 2, in the light theme.
   - Show the first screen as a user sees it after some use. If it is empty,
     add sample data through the app first.
   - Capture the top 390 × 293 CSS pixels as JPEG at quality 80. The result
     is 780 × 586 pixels. With Playwright: a page from
     `{ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }`, then
     `page.screenshot({ type: "jpeg", quality: 80, clip: { x: 0, y: 0, width: 390, height: 293 } })`.
     WebP is smaller; use it only when the browser or an encoder at hand
     writes it (Playwright does not).
   - Save it as `public/cover.jpg` (or `.webp`) and set `"cover": "cover.jpg"`
     in `comma-app.json`. Then run `npm run build` again, which copies it to
     `dist/`.
   The cover must be at most 160 KiB and 1200 × 1200 pixels. Every gallery
   viewer downloads it, so do not use PNG. Make a new cover when the first
   screen changes.
5. Deploy: call the station tool `app_deploy` with short `notes` on what
   changed. It commits and pushes your work, then sends the build to Comma.
   Fix every error it returns and call it again. The user sees the new
   version in the chat. Report its app ID and Version to the Router.
   The Router can publish with `internal.apps.publish` after this Task is ready for review.
6. Backend errors: call the station tool `app_logs`.

Run `npm run build` before each `app_deploy`. Never edit `dist/` or
`dist-worker/` by hand.

## Frontend rules

- Use only `comma` from `src/comma/sdk.ts` for effects. The app has no network:
  `fetch`, `XMLHttpRequest`, `WebSocket`, remote images, fonts and scripts fail.
  Put every asset into the bundle (imports of images and fonts become data URLs).
- Keep data only in `comma.storage`. List each store you use in
  `comma-app.json` `storage`. Keys use letters, digits and `. _ / -` (at most
  256). Use `put(key, value, { ifVersion })` to avoid lost updates.
  - `comma.storage.device`: this device only. 32 KiB per value, 1 MiB in all.
  - `comma.storage.user`: the current viewer, on all devices. 10 MiB per viewer.
  - `comma.storage.app`: shared by all viewers. 1 MiB per value, 100 MiB in all.
- Do not use `localStorage`, `sessionStorage`, IndexedDB, cookies, Service
  Workers, `window.open`, a form that submits to a URL (handle `onSubmit` and
  call `preventDefault()`), `alert` or `confirm`. They do not work in the
  sandbox.
- Do not use the URL or `history` for navigation. Use `useNavigation()` from
  `src/components/navigation.tsx` (stacks in memory).
- Keep the build to one module script. Do not add code splitting or dynamic
  `import()` of app code. To load a large file on demand, keep it in `public/`
  and use `comma.asset("file.js")`.
- Capabilities (`comma-app.json` `capabilities`) the app may ask for:
  `identity.basic` (`comma.viewer()`), `ai.chat` (all `comma.ai.*` calls),
  `web.search` (`comma.web.search(query)`), `chat.draft`
  (`comma.chat.draft`), `tasks.create` (`comma.tasks.propose`), `files.pick`,
  `drive.app_folder` (`comma.drive.*`), `calendar.read` (Mac only),
  `notifications` (`comma.notify`), `clipboard.write`, `links.open` (`comma.open`),
  and the device capabilities `microphone`, `camera`, `location`, `screen.wake`,
  `fullscreen`, `clipboard.read`, `share`, `haptics`, `midi`, `usb`, `bluetooth` (README.md,
  "Device capabilities"). The frame cannot use `getUserMedia`, geolocation,
  Web MIDI itself: use the SDK. For declared `usb` and `bluetooth` capabilities,
  use `navigator.usb` and `navigator.bluetooth` directly. Start device selection
  from a user click. Browser device grants belong to Comma, not to an individual
  app. Other apps with the same capability can access those authorized devices.
  Test API availability before you show a device control.
  `comma.microphone.devices()` lists inputs and optional channel-count/sample-rate ranges.
  Use `comma.microphone.startChannels` for separate PCM channels and indexed selection.
  Channel indices are zero-based audio-stream positions, not physical port names.
  See README.md for the options and sample callback. The existing `start` stays mono.
  Ask only for what the app needs. The viewer grants them; a call can fail.
- `comma.ai.decide({ state, questions })` uses the shared `ai.chat` grant and the viewer Workspace's credits.
  Send only the state the model needs, with 1 to 8 typed questions and at most 12 KiB of JSON.
  Use `choice`, `noul` or `score` questions as described in README.md. No app backend is needed.
- Web search returns at most five `{title, url, text}` results for a query of 1 to 2,000 characters.
  Comma sends the query to Exa after the viewer grants access. Guests must sign up. No app backend is needed.
- Every SDK call can reject with `CommaError` (`code`: `unsupported`,
  `not_granted`, `denied`, `signup_required`, `app_paused`, `rate_limited`,
  `invalid`, `not_found`, `conflict`, `quota_exceeded`, `failed`,
  `unavailable`). Show the user a short message; do not crash. Check
  `comma.supports(op)` before you show a feature that needs a capability.
- Follow the Comma theme: `<html>` has `data-theme` (`light` or `dark`) and
  `color-scheme`. The theme colors change with it, so the app needs no `dark:`
  classes for them. Use `comma.onTheme` only for code that must react to a
  change.

## Backend (optional)

- `worker/index.ts` is a Cloudflare Worker module. To use it, add to `comma-app.json`:
  `"backend": {"entry": "worker/index.ts", "egress": ["api.example.com"], "secrets": ["API_KEY"]}`.
- The frontend calls it with `comma.backend.fetch("/path", init)`. Requests
  arrive at `https://app.invalid/<path>` with the header `x-comma-viewer`.
- `fetch` from the backend reaches only https hosts in `egress` (at most 20).
- Store data in `env.STORAGE` (see the comments in `worker/index.ts`).
- Secrets are `env.<NAME>`. The Router or app owner sets their values through Comma. Never
  put secret values in the repository.
- Limits: 50 ms CPU and 50 subrequests per request; 1 MiB request body.

## Do not change

- `src/comma/` (Comma updates these files).
- The single-file build in `vite.config.ts`.
- The `--comma-*` mapping in `src/index.css`, unless the user asked for their
  own look (see Look).
