# Testing

Keep tests near their business or runtime boundary.

## Required Rules

- Business behavior and user-visible changes need tests. An E2E test runs the whole chain through core, native-bridge, or server APIs, not rendered UI ([AGENTS.md](../AGENTS.md#end-to-end-tests)).
- A fix adds the smallest regression test that fails without it: Vitest for the core chain or components, Playwright for a window or OS failure. Maintenance with no stable behavior to assert is exempt.
- Existing tests can cover a change. Review behavior and coverage instead of requiring a test-file edit.
- Playwright P0 (`clients/e2e/p0`) is only for high-frequency user paths and runtime startup and isolation health. Put other client behavior in the closest package, app, E2E, or visual-regression suite.

## Deterministic runtime

Production reads BEAM time and application configuration. Tests control both through runtime functions.

- Time: timers, sleeps, timeouts, and deadlines read `SystemsClock`.
  Suites drive the manual clock with `SystemsClock.Case` or `SystemsClock.Test` and stay `async: false`.
- Configuration: code reads a replaceable dependency with `SystemsRuntime.get_env/3`. A test binds it with `SystemsRuntime.Test.put_env/3` or `delete_env/2`.
  The test, its tasks, descendants, and allowed processes see the binding until the test exits.
  A suite whose code runs in application processes calls `SystemsRuntime.Test.shared/0` in an `async: false` setup.
  Do not use global `Application.put_env/3` for these dependencies. It stays correct for keys that code reads with `Application.get_env/3`.

`mix systems.clock_calls` (from `systems/`, `MIX_ENV=test`) fails on a direct clock call in compiled modules.
`systems/apps/systems_runtime/priv/clock_calls_baseline.exs` lists older calls. Use `--update-baseline` only after removals.
The `direct-clock-call`, `direct-application-env`, and `direct-randomness` rules in `lint/rules` find the same calls in source.
`scripts/ast-grep.sh scan` runs them in CI and in the pre-commit hook, with `mix format`, Prettier, and oxlint.
`make`, `mix deps.get`, and `pnpm install` install the hook from `scripts/git-hooks`.

## Deterministic tests

All gated server and client tests obey these rules.

1. The result of a test depends only on the code and the seed.
2. The harness, scheduler, and test clock use no real-time threshold or grace period.
3. Unobservable states fail closed and name the stopped process and function.
4. Do not loosen assertions to pass. When you change an assertion, explain what it verified and how the replacement still verifies it.

Fix flaky tests at their cause. Do not add retries, longer timeouts, or skips.

## No real network

Tests connect only to this machine: loopback, `*.localhost`, unix sockets, and the local Postgres, Redis, MinIO and ClickHouse test services.
Replace an external service with a fixture or fake in the repository. A subprocess that a test starts must not download anything (npm, Go modules, git).

The test harness enforces this. A connection to another host fails the test that made it, and the message names the host and the test.

- BEAM: `SystemsRuntime.NetworkGuard` (`config :systems_runtime, network_guard: true`) for `mix test` and `MIX_ENV=test` scripts.
- Node and Bun: `scripts/test-network-guard.mjs`, through Vitest `setupFiles`, `node --import` or the Bun `preload`.
- Playwright: Chromium resolves only this machine's names (`scripts/test-network-browser.mjs` in each config's `launchOptions`). A page reaches a host a test routes itself (`page.route`).
- Subprocesses inherit an offline environment: proxies on a closed local port, and npm, pip, uv, cargo, Go and git offline.

`COMMA_TEST_NETWORK_ALLOW` (comma-separated) adds local test service hosts, such as `postgres,redis` in a container network.
`COMMA_TEST_NETWORK=report` lets connections through and lists them (`COMMA_TEST_NETWORK_REPORT` names a JSONL file).

A test of an external service on purpose has a live tag (`live_llm`, `live_meet`, `live_semantic_gpu`, `browser_live`). The tag excludes it by default and lets it through the guard. PR CI does not run live tests.

The rules in `lint/determinism/rules` find real time, timers, deadlines, randomness, fixed ports, and raw Electron changes in tests, and real time in the harness (`ex-harness-real-clock`).
Only the clock's own production reads of real time are exempt, each with an `ast-grep-ignore` comment and reason.
Go live tests (`*_live_test.go`) reach real services and are outside the rules. CI never runs them.
`scripts/determinism.sh report` counts findings. `check` runs in the `Determinism` workflow on pull requests and fails when a change adds a finding to a file.

## CI

Every pull request gets the `Required Client CI` and `Required Client Build` aggregate checks.
Configure both as required in the default-branch ruleset. Heavy jobs skip for unrelated changes, and the aggregates still report success.

## Manual evidence

For behavior that needs a native app or external service:

1. State the changed user behavior and failure boundary.
2. Record the build revision, environment, fixture account, and exact input.
3. Run the real runtime path and observe the user-facing result.
4. Record failures apart from untested paths.
5. Remove test-owned accounts, files, and workloads.

Keep reports, screenshots, and PDFs outside `docs/`.

## Browser Run

Native browser tests and their `browser_live` tag live in `systems/apps/salix_agent/test/browser_live_test.exs`.

## Computer Use permission identity

Computer Use owns its macOS Accessibility and Screen Recording permissions.
Packaged Comma installs the signed helper under `~/Library/Application Support/Comma Computer Use/<helper bundle ID>/`.
Permission checks, authorization, and Connector actions open that app through LaunchServices.
System Settings shows the flavor-specific Computer Use name. Its permission restart does not restart Comma.
Comma replaces the copied helper only when shipped code changes.
Comma permissions do not grant access to this app. Users must authorize Computer Use. The next action restarts it if macOS closed it.

Automated tests cover signature, LaunchServices identity, relaunch, replacement, and failed-copy recovery. They do not grant TCC permissions or show the consent dialog.

To check manually on a fresh macOS test account:

1. Open authorization from packaged Comma.
2. Grant Accessibility and Screen Recording to the Computer Use app.
3. Confirm that System Settings names Computer Use for both grants.
4. Select the system restart action. Confirm that Comma's PID does not change.
5. Request a screenshot through the Connector. Confirm that it succeeds.

Do not reset a developer's existing permissions for this check.
