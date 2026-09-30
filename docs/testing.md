# Testing

Keep tests close to the business or runtime boundary they protect.

## Required Rules

- Business behavior and user-visible changes need corresponding tests. For
  client behavior that crosses runtime, UI, or native-bridge boundaries,
  prefer end-to-end coverage.
- Fixes need a regression test that reproduces the issue unless the change is
  maintenance work with no stable business behavior to assert.
- Every source change must include a relevant test change, or the PR must check
  the template's `[test-not-required]` waiver line with a specific reason.
- Playwright P0 under `clients/e2e/p0` is reserved for high-frequency user
  paths and runtime startup/isolation health. Put other client behavior in the
  closest package/app component, E2E, or visual-regression suite.
- Bug fixes should add the smallest regression test that fails without the fix:
  Vitest for local logic or components, Playwright when the failure is visible
  only through the app/runtime flow.

## Local Commands

From the repository root:

```sh
make test-clients
make test-clients-smoke
make test-systems
make test-policy
make test-devtools
make test-resources
make test-systems-static
make test-all-local
```

From `clients/`:

```sh
pnpm ci:static
pnpm ci:unit
pnpm ci:storybook
pnpm ci:build:web
pnpm ci:build:electron
pnpm test:unit
pnpm test:storybook
pnpm test:e2e
pnpm smoke:web
pnpm smoke:electron
```

The `electron-shell` E2E project includes the chat dynamic UI runtime suite.
To run only that suite, run this command from `clients/`:

```sh
pnpm exec playwright test --config apps/electron/e2e/dynamic-ui/playwright.config.ts
```

## Client Harness

- Vitest runs unit and component tests across Node and jsdom projects.
- `clients/packages/test-utils/src/render.tsx` wraps React Testing Library
  render helpers.
- `clients/packages/test-utils/src/native-bridge.ts` installs a deterministic
  native bridge mock for tests that cross that boundary.
- Storybook build and test-runner/a11y checks run in client CI.
- Playwright P0 smoke tests live in `clients/e2e/p0`.
- The web smoke starts the Vite web app automatically.
- The Electron smoke builds the Electron app first, skips the native NotchHost
  build for smoke speed, starts the Electron renderer Vite server, and launches
  the built main process with Playwright's Electron runner.
- Electron Playwright projects set `COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS=1`.
  Test windows still paint and remain fully interactive through Playwright, but
  use Electron's `showInactive()` API and the macOS `accessory` activation
  policy so local runs do not take keyboard focus from the foreground app. Set
  the variable to `0` only for a scenario that explicitly tests native app
  activation.

The `ci:*` scripts are the canonical local/CI entry points for deterministic
jobs. `ci:build:web` creates production Web and Admin bundles.
`ci:build:electron` creates an unsigned staging-flavor macOS package; signing,
notarization, Velopack feed publication, and the GitHub prerelease remain the
responsibility of the staging release workflow.

Client workflows run these checks and builds:

- `Client Checks` runs static checks, unit tests, Storybook/a11y, and E2E.
  Computer Use helper, PermissionFlow patch, packaging, and permission-probe
  changes run the separate native checks. Helper-only changes skip the browser
  and Electron suites, and do not trigger Systems CI. Other Systems CI inputs
  in the same PR still trigger its full checks, including workflow changes.
  Client changes retain both suites and the native checks.
- `Client Build` creates the production Web/Admin bundles and the unsigned
  staging Electron package.
- `Electron Release - Staging` runs after relevant merges to `main`, publishes
  the Velopack staging feed, and creates a GitHub prerelease containing the
  signed and notarized client artifacts.

Pull requests always receive stable `Required Client CI` and
`Required Client Build` aggregate checks. Configure both names as required in
the default-branch ruleset; individual job names can then change without
silently weakening merge protection. Heavy jobs skip cleanly for unrelated
changes, while the aggregate checks still report success.

## CI Artifacts

Playwright is configured with:

- `trace: "retain-on-failure"`
- `screenshot: "only-on-failure"`
- `video: "retain-on-failure"`
- HTML report output under `clients/playwright-report`

CI uploads Playwright bundles with artifact names that include target, status,
run id, and attempt:

- Success artifacts are retained for 1 day.
- Failure artifacts are retained for 3 days and include report, traces,
  screenshots, videos, and `test-results`.

`Client Build` also uploads downloadable GitHub Actions artifacts for three
days: `client-web-build-*` contains production Web/Admin bundles and
`client-electron-macos-staging-*` contains the unsigned staging Electron
package. These are build-validation artifacts, not releases. The signed and
notarized installer is attached to the GitHub prerelease after a relevant merge
to `main`.

CI also supports publishing smoke artifacts to the Comma E2E Reports dashboard
through Cloudflare R2. The R2 publish step is optional and runs only when the
write credentials are configured:

- `E2E_REPORTS_R2_ENDPOINT`
- `E2E_REPORTS_R2_REGION` (usually `auto`)
- `E2E_REPORTS_R2_BUCKET` (required)
- `E2E_REPORTS_R2_ACCESS_KEY_ID`
- `E2E_REPORTS_R2_SECRET_ACCESS_KEY`

The publish step writes `run.json`, per-target `manifest.json`, date indexes,
the Playwright HTML report, traces, screenshots, videos, and raw `test-results`
files under the `e2e-reports/` R2 prefix. Target manifests and run records also
include `failureTypes` so the dashboard can group failures such as timeouts,
assertions, browser exits, network failures, and application errors. Upload
failures are warnings only; the final smoke status still comes from the
Playwright jobs themselves. GitHub Actions artifacts remain the short-lived
fallback.

## Static Quality Gates

- `make test-devtools` runs check/build for `devtools/e2e-reports` and
  `devtools/salix-web-ui`; the e2e reports workflow also boots preview and runs
  its smoke script.
- `make test-resources` validates Salix system skill metadata and script syntax.
- `make test-systems-static` runs the systems formatting check.
- `make test-all-local` aggregates `test-policy`,
  `test-resources`, `test-devtools`, `test-systems-static`, `test-systems`,
  `test-bft-cli`, and `test-clients`. It does not run the separate
  `test-clients-smoke` web/Electron smoke suite.

## Removing redundant tests

Keep user behavior, authorization, ownership, cancellation, storage compatibility, and transport regressions.
Do not assert over implementation source, script text, workflow text, or their AST to infer runtime behavior.
This includes SQL migrations, call placement, import allowlists, and tests that enforce those source checks.
If the quality goal is valid, migrate the check to a behavior test before removing its only coverage.
Execute the relevant path and assert its result, state change, or observable failure.
Keep compiler, type, lint, generated-file consistency, and executable protocol checks.
Reading source to compile or execute it is valid. Matching its text is not behavioral evidence.
Remove assertions that only pin literal schema copies, CSS classes, fixture text, or deleted historical code.
Client tests assert interactions and accessibility.
A tiny helper does not need an oversized input matrix that adds no distinct boundary.
Lean redundancy requires the executable theorem, matching input domain, and matching property.
Codec, C/ETF, resolver, compaction, and provider behavior remain outside a pure policy proof.
See [Verification](verification.md).

Do not test-wrap simple repository checks. Run the check directly.
Documentation-only maintenance needs link, size, formatting, and affected-tool validation, not an invented product E2E.
Report what actually ran, its exact revision, and any runtime limits.
Do not call a mocked provider test a live delivery check.

## External device recovery rehearsal

In the configured systems test environment, run from `systems/`:

```sh
deno test --allow-all --filter 'external runtimes complete' e2e/tests/salix_connect_test.ts
```

This uses the Go Connector, PostgreSQL, MinIO, and controlled native-model substitutes.
The harness starts the shared recovery worker and notification listener, which unit-test configuration disables.
The Codex case retains offline input, exits the server, starts a new server process against the same stores,
and checks the original Session's visible reply and input receipt after reconnect.
Repeated recovery must not duplicate that reply. This is not live model or Telegram delivery acceptance.

## Manual evidence

For a behavior that needs a native app or external service:

1. State the changed user behavior and failure boundary.
2. Record the build/revision, environment, fixture account, and exact input.
3. Exercise the actual runtime path and observe the user-facing result.
4. Record failures separately from untested paths.
5. Remove test-owned accounts, files, and workloads.

Keep temporary reports, screenshots, and PDFs outside `docs/`.
Do not retain one hand-test diary per PR as a permanent product contract.

## Browser Run

Native CDP transport tests run in the Elixir suite.
Set `BROWSER_DRIVER_CHROMIUM` to a local Chromium executable to include real browser tests.
They exercise input, screenshots, Unicode, replacement, streams, disconnects, cross-task cookies/local storage, logout, clearing, and failed-close recovery.
Regressions cover 71 origins, LRU eviction, input during saves, partial saves, paused tasks, handoff, self-open, self/cross-task provider-expiry recovery, bounded lost-create recovery, passive stream/checkpoint expiry, reconnect refusal, and human-control lease retention.
The tests use isolated Postgres and Chromium. Only Cloudflare acquisition/deletion use a fixture.

Live tests use the `browser_live` tag with `CF_BROWSER_ACCOUNT_ID` and `CF_BROWSER_TOKEN_FILE`.
Run `mix test apps/salix_agent/test/browser_live_test.exs --include browser_live` from `systems` with the test databases available.
They create and delete their own Cloudflare browsers and consume provider usage. Keep the API token in the specified file.
Local tests establish first-request cookie and first-script local-storage behavior. Live tests verify transfer through Cloudflare CDP and guardrails.
Neither proves every website's login behavior, IndexedDB persistence, or preservation of changes after the last successful checkpoint.
