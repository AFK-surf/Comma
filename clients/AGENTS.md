# Client agent instructions

These rules apply to every change in `clients/`: Web, Electron, desktop and mobile apps, the native bridge, and client tests.
The repository root `AGENTS.md` also applies. Each app may add its own `AGENTS.md`.

## Comma App local development

Treat staging interactions as real shared-environment operations.
See [Development](../docs/development.md).

## Client UI

UI components are in `clients/packages/ui`.

For a UI fix or new UI, use the design system first:

1. Find the existing component in `clients/packages/ui` and its Figma DS component and variant. Extend a component before you write a new one.
2. Use `src/styles/theme.css` tokens for color, spacing, type, radius, and motion. Do not write raw values.
3. Read Figma node values with Figma MCP. Do not estimate them from screenshots.
4. Follow a base component's `GUIDE.md` if present.
5. Something that enters or leaves by its size keeps its whole scale range and is not visible at half its size or less, on every client, so it does not jump: its opacity follows its scale, 0 at 0.5 or below and 1 at full size.

For icons and scrollbars, follow [`clients/packages/ui/GUIDE.md`](packages/ui/GUIDE.md) and [`scroll-area/GUIDE.md`](packages/ui/src/components/scroll-area/GUIDE.md).

## Native capability kernel

All main<->renderer capabilities use generated leaves in
`clients/packages/native-bridge/src/capability-leaves.ts`. Regenerate after changes.

- `defineNativeCapability`: command, request -> typed result.
- `defineNativeEvent`: fire-and-forget event.
- `defineNativeState`: owned replay-last `{ snapshot, get, subscribe }`. Only the owner's mutation/snapshot path publishes, through composition-root wiring.

Leaves define zod I/O, permission, handler metadata, and mock/web fallback.
The generator owns contracts, bridge/types, bindings, and manifest. Renderers spread it and call `getNativeBridge()`.
Only aliases may be handwritten.

Forbidden:

- Raw IPC or new `ipcMain.handle` outside the gateway. The legacy allowlist only shrinks.
- Electron-main imports or raw secrets in renderer/shared. Main is the bearer authority: SecureStore holds tokens, and `/v1` strips renderer auth and injects it.
- State publication from renderer, gateway, dev surfaces, or bypasses.
- Hand-edited generated artifacts. Edit the leaf and regenerate.
- Fake dev data. Mark paths `needs-capability` or `planned`.

Verify with:

```sh
pnpm --dir clients check:foundation
pnpm --dir clients --silent check:foundation -- --list
pnpm --dir clients typecheck && pnpm --dir clients lint
```

`check:foundation --list` lists configuration and generated-file consistency checks.
It does not prove runtime isolation or security. Verify those through execution.

## Client tests

- Put Playwright tests near the runtime or package (`clients/{packages/app,apps/electron}/e2e`).
- Reserve `clients/e2e/p0` for critical frequent paths and startup/isolation.
- Put unit and component tests nearby. Put shared helpers in `clients/packages/test-utils`.

## End-to-end tests

An E2E test runs the whole chain, not one unit: the product's entry point, the
client core, the host and its process boundaries, and the server or its scripted
stand-in. It does not depend on the parts that cannot be made deterministic,
mainly the rendered UI.

- Drive the chain through deterministic entry points: core calls and topics
  (`startTestCore`, `FakeHost`, `FakeCommaApi`, `TestTime`), native-bridge
  capabilities, Main's services and server APIs. Do not drive business behavior
  by clicking, typing or waiting for rendered UI.
- Keep business logic out of the UI. When a behavior can be reached only through
  the UI, move its logic into the client core first, then test it there end to end.
- Test the UI separately: a component renders the core's values and its actions
  call the core (component tests).
- Use a UI-driven Playwright or Electron test only for what only a window or the
  operating system shows: native windows, focus, IPC and process boundaries,
  clipboard and dialogs, credential isolation, and rendering identity. Keep each
  such test to that boundary and do not repeat business checks in it.
