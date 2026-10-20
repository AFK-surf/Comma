import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  classify,
  dayOf,
  fileTitle,
  firstErrorLine,
  logLines,
  matchSignature,
  parseExUnit,
  parseJobLog,
  parsePlaywright,
  parseVitest,
  renderWorkflow,
  runnerSignatures,
  shardless,
  summarize,
} from "./ci-main-failures.mjs";

const script = join(import.meta.dirname, "ci-main-failures.mjs");

// Short excerpts of real job logs from main (Cue, 2026-10-08 to 2026-10-11),
// with the runner's time stamps and color codes as GitHub gave them.

// Electron Shell E2E: the annotation, the ✘ line, the summary and the numbered block with a project.
const playwrightList = `2026-10-08T00:35:39.2446098Z ##[error]  1) [electron-shell] › apps/electron/e2e/chat-runtime-ownership.spec.ts:737:5 › email login resumes after editing the address and survives a rejected resend 
    Error: expect(locator).toBeVisible() failed

    Locator: getByText(/Resend in 3[0-5]s/)
    Expected: visible
2026-10-08T00:35:39.2450779Z   ✘   13 [electron-shell] › apps/electron/e2e/chat-runtime-ownership.spec.ts:737:5 › email login resumes after editing the address and survives a rejected resend (12.2s)
2026-10-08T00:36:41.0351825Z ##[notice]  1 failed
    [electron-shell] › apps/electron/e2e/chat-runtime-ownership.spec.ts:737:5 › email login resumes after editing the address and survives a rejected resend 
  1 skipped
2026-10-08T00:36:41.0358096Z   1) [electron-shell] › apps/electron/e2e/chat-runtime-ownership.spec.ts:737:5 › email login resumes after editing the address and survives a rejected resend 
2026-10-08T00:36:41.0358376Z 
2026-10-08T00:36:41.0358483Z     Error: expect(locator).toBeVisible() failed
2026-10-08T00:36:41.0358606Z `;

// Browser Side E2E Test: only the ✘ line names the test.
const playwrightMarkOnly = `2026-10-10T01:58:04.9392460Z   ✘  1 packages/app/e2e/analytics/posthog.spec.ts:12:1 › website first touch joins web registration across origins without private URL fields (6.6s)
2026-10-10T01:58:10.2063770Z   ✓  2 packages/app/e2e/analytics/posthog.spec.ts:168:3 › the real SDK sends sanitized routes and identity, without automatic DOM capture (4.4s)
2026-10-10T01:58:17.6495790Z   ✓  3 packages/app/e2e/analytics/posthog.spec.ts:168:3 › the real SDK sends sanitized routes and identity, without automatic DOM capture when initial ingestion arrives last (7.4s)
2026-10-10T01:58:25.9011530Z   ✓  4 packages/app/e2e/analytics/posthog.spec.ts:252:1 › real SDK exceptions are redacted, readiness is emitted once, and a fatal React error is critical (8.2s)
2026-10-10T01:58:27.0502710Z   ✓  5 packages/app/e2e/analytics/posthog.spec.ts:295:1 › the app remains usable when PostHog is unreachable (1.1s)
2026-10-10T01:58:31.2444540Z   ✓  6 packages/app/e2e/analytics/posthog.spec.ts:305:1 › visible replies reach PostHog with the committed message ID and no conversation content (4.2s)
2026-10-10T01:58:31.4599270Z 
2026-10-10T01:58:31.4678760Z   1 failed
2026-10-10T01:58:31.4679500Z     packages/app/e2e/analytics/posthog.spec.ts:12:1 › website first touch joins web registration across origins without private URL fields 
2026-10-10T01:58:31.4680280Z   5 passed (58.8s)`;

// Storybook E2E: the dot reporter prints a GitHub annotation.
const playwrightDot = `2026-10-08T04:19:59.6446510Z ···························································F::error file=clients/packages/ui/e2e/task-card-reorder.spec.ts,title=e2e/task-card-reorder.spec.ts:110:1 › the card sticks to the hand and falls into the well from where it is,line=150,col=45::  1) e2e/task-card-reorder.spec.ts:110:1 › the card sticks to the hand and falls into the well from where it is %0A    Error: expect(received).toBeLessThan(expected)%0A%0A    Expected: < 60%0A    Received:   90.31597900390625%0A%0A      1`;

// Storybook E2E: a numbered header without a project.
const playwrightNoProject = `2026-10-08T23:38:22.8460420Z ##[error]  1) e2e/status-indicator.spec.ts:4:1 › status indicator snaps Shadow DOM motion with reduced motion 
    Error: locator.evaluate: Test timeout of 600000ms exceeded.

      19 |   await expect(indicator).toBeVisible();
      20 |
    > 21 |   const resultPromise = indicator.evaluate((element) => {`;

// Synchronicity Binary Smoke: a failed test.
const vitestTest = `2026-10-10T09:31:16.5727252Z \u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m\u001b[1m\u001b[41m Failed Tests 1 \u001b[49m\u001b[22m\u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m
2026-10-10T09:31:16.5727498Z 
2026-10-10T09:31:16.5728246Z \u001b[41m\u001b[1m FAIL \u001b[22m\u001b[49m \u001b[30m\u001b[43m node \u001b[49m\u001b[39m apps/electron/src/main/test/synchronicity-control.test.ts\u001b[2m > \u001b[22mSynchControlClient with the pinned daemon\u001b[2m > \u001b[22mstreams a file larger than the renderer limit and survives token rotation
2026-10-10T09:31:16.5729102Z \u001b[31m\u001b[1mAssertionError\u001b[22m: expected undefined to be 'origin: key:3gxueecokmp7d91kahxrjpacb…' // Object.is equality\u001b[39m
2026-10-10T09:31:16.5729394Z 
2026-10-10T09:31:16.5729538Z \u001b[32m- Expected:\u001b[39m`;

// Browser Component Test: a failed test in the browser project.
const vitestBrowser = `2026-10-08T21:19:22.2626150Z \u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m\u001b[1m\u001b[41m Failed Tests 1 \u001b[49m\u001b[22m\u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m
2026-10-08T21:19:22.2626400Z 
2026-10-08T21:19:22.2628810Z \u001b[41m\u001b[1m FAIL \u001b[22m\u001b[49m \u001b[30m\u001b[42m browser (chromium) \u001b[49m\u001b[39m e2e/app-shell/markdown-stream.chromium.test.ts\u001b[2m > \u001b[22mroute bubble that just makes the transcript overflow lands once
2026-10-08T21:19:22.2631650Z \u001b[31m\u001b[1mAssertionError\u001b[22m: expected -128 to be greater than 1\u001b[39m
2026-10-08T21:19:22.2636030Z \u001b[36m \u001b[2m❯\u001b[22m e2e/app-shell/markdown-stream.chromium.test.ts:\u001b[2m225:19\u001b[22m\u001b[39m`;

// Unit Test: a file that failed to load.
const vitestFileLoad = `2026-10-09T18:25:16.1648570Z \u001b[31m⎯⎯⎯⎯⎯⎯\u001b[39m\u001b[1m\u001b[41m Failed Suites 1 \u001b[49m\u001b[22m\u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m
2026-10-09T18:25:16.1649000Z 
2026-10-09T18:25:16.1650320Z \u001b[41m\u001b[1m FAIL \u001b[22m\u001b[49m \u001b[30m\u001b[43m node \u001b[49m\u001b[39m apps/electron/src/main/test/native-side-chat.test.ts\u001b[2m [ apps/electron/src/main/test/native-side-chat.test.ts ]\u001b[22m
2026-10-09T18:25:16.1651580Z \u001b[31m\u001b[1mError\u001b[22m: Electron failed to install correctly. Please delete \`node_modules/electron\` and run "npx install-electron --no" manually.\u001b[39m
2026-10-09T18:25:16.1653790Z \u001b[90m \u001b[2m❯\u001b[22m getElectronPath ../node_modules/electron/index.js:\u001b[2m43:13\u001b[22m\u001b[39m
2026-10-09T18:25:16.1654800Z \u001b[90m \u001b[2m❯\u001b[22m Object.<anonymous> ../node_modules/electron/index.js:\u001b[2m52:18\u001b[22m\u001b[39m
2026-10-09T18:25:16.1655100Z 
2026-10-09T18:25:16.1655450Z \u001b[31m\u001b[2m⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[1/1]⎯\u001b[22m\u001b[39m`;

// Browser Component Test: files that failed to run.
const vitestRunError = `2026-10-08T16:28:57.0379480Z 
2026-10-08T16:28:57.0380080Z \u001b[31m⎯⎯⎯⎯⎯⎯\u001b[39m\u001b[1m\u001b[41m Unhandled Error \u001b[49m\u001b[22m\u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m
2026-10-08T16:28:57.0383260Z \u001b[31m\u001b[1mError\u001b[22m: Failed to run the test /Users/admin/actions-runner/_work/Cue/Cue/clients/e2e/app-shell/chat-panel-media.chromium.test.ts.\u001b[39m
2026-10-08T16:28:57.0391580Z \u001b[90m \u001b[2m❯\u001b[22m ../node_modules/vitest/dist/chunks/cli-api.CnMVyzaz.js:\u001b[2m2639:17\u001b[22m\u001b[39m
2026-10-08T16:28:57.0392480Z \u001b[90m \u001b[2m❯\u001b[22m processTicksAndRejections node:internal/process/task_queues:\u001b[2m104:5\u001b[22m\u001b[39m
2026-10-08T16:28:57.0392910Z 
2026-10-08T16:28:57.0394310Z \u001b[31m\u001b[1mCaused by: Error\u001b[22m: [vitest] Browser connection was closed while running tests. Was the page closed unexpectedly?\u001b[39m
2026-10-08T16:28:57.0396150Z \u001b[90m \u001b[2m❯\u001b[22m WebSocket.<anonymous> ../node_modules/@vitest/browser/dist/index.js:\u001b[2m3054:16\u001b[22m\u001b[39m
2026-10-08T16:28:57.0420420Z 
2026-10-08T16:28:57.0420710Z \u001b[31m⎯⎯⎯⎯⎯⎯\u001b[39m\u001b[1m\u001b[41m Unhandled Error \u001b[49m\u001b[22m\u001b[31m⎯⎯⎯⎯⎯⎯⎯\u001b[39m
2026-10-08T16:28:57.0466000Z \u001b[31m\u001b[1mError\u001b[22m: Failed to run the test /Users/admin/actions-runner/_work/Cue/Cue/clients/e2e/app-shell/markdown-stream.chromium.test.ts.\u001b[39m
2026-10-08T16:28:57.0466900Z \u001b[90m \u001b[2m❯\u001b[22m ../node_modules/vitest/dist/chunks/cli-api.CnMVyzaz.js:\u001b[2m2639:17\u001b[22m\u001b[39m
2026-10-08T16:28:57.0467600Z \u001b[90m \u001b[2m❯\u001b[22m processTicksAndRejections node:internal/process/task_queues:\u001b[2m104:5\u001b[22m\u001b[39m
2026-10-08T16:28:57.0467960Z 
2026-10-08T16:28:57.0468820Z \u001b[31m\u001b[1mCaused by: Error\u001b[22m: [vitest] Browser connection was closed while running tests. Was the page closed unexpectedly?\u001b[39m
2026-10-08T16:28:57.0469630Z \u001b[90m \u001b[2m❯\u001b[22m WebSocket.<anonymous> ../node_modules/@vitest/browser/dist/index.js:\u001b[2m3054:16\u001b[22m\u001b[39m`;

// test-beam: an ExUnit failure.
const exunit = `2026-10-10T00:45:52.7781106Z ....
2026-10-10T00:45:52.7781147Z 
2026-10-10T00:45:52.7781347Z   1) test remote source streams into a fresh blob committed to the peer manifest (SalixAgent.ToolsPeersCopyTest)
2026-10-10T00:45:52.7781672Z      apps/salix_agent/test/tools_peers_copy_test.exs:323
2026-10-10T00:45:52.7781945Z      ** (ArithmeticError) bad argument in arithmetic expression: nil - -576460684490082503
2026-10-10T00:45:52.7782200Z      stacktrace:
2026-10-10T00:45:52.7782427Z        :erlang.-(nil, -576460684490082503)
2026-10-10T00:45:52.7782732Z        (systems_clock 0.1.0) lib/systems_clock.ex:2454: SystemsClock.capture_report/1
2026-10-10T00:45:52.7783244Z        (systems_clock 0.1.0) lib/systems_clock.ex:2434: SystemsClock.save_report/1
2026-10-10T00:45:52.7783570Z        (systems_clock 0.1.0) lib/systems_clock.ex:2408: SystemsClock.save_report/0
2026-10-10T00:45:52.7783929Z        (ex_unit 1.20.4) lib/ex_unit/on_exit_handler.ex:140: ExUnit.OnExitHandler.exec_callback/1
2026-10-10T00:45:52.7784388Z        (ex_unit 1.20.4) lib/ex_unit/on_exit_handler.ex:126: ExUnit.OnExitHandler.on_exit_runner_loop/0
2026-10-10T00:45:52.7784575Z 
2026-10-10T00:45:52.7784618Z ...`;

// A job without a test: curl timed out.
const errorCurl = `2026-10-08T16:14:18.7801130Z   GIT_TERMINAL_PROMPT: 0
2026-10-08T16:14:18.7801300Z   GCM_INTERACTIVE: never
2026-10-08T16:14:18.7801470Z   TZ: UTC
2026-10-08T16:14:18.7801600Z   LANG: en_US.UTF-8
2026-10-08T16:14:18.7801830Z   VITEST_CHROMIUM_GC_DISK_THRESHOLD_GB: 1024
2026-10-08T16:14:18.7803670Z   GH_TOKEN: ***
2026-10-08T16:14:18.7803830Z ##[endgroup]
2026-10-08T16:15:18.8714170Z curl: (28) Operation timed out after 60015 milliseconds with 0 bytes received
2026-10-08T16:16:19.8841030Z curl: (28) Operation timed out after 60007 milliseconds with 0 bytes received
2026-10-08T16:17:21.8991010Z curl: (28) Operation timed out after 60004 milliseconds with 0 bytes received
2026-10-08T16:18:25.9177780Z curl: (28) Operation timed out after 60005 milliseconds with 0 bytes received
2026-10-08T16:18:25.9243340Z ##[error]Process completed with exit code 28.
2026-10-08T16:18:25.9492090Z Cleaning up orphan processes`;

// release-kubernetes-e2e: a failing Go test.
const errorGo = `2026-10-11T20:11:32.9422996Z --- FAIL: TestDisposableNamespaceRecoveryMatrix (438.34s)
2026-10-11T20:11:32.9510851Z     --- PASS: TestDisposableNamespaceRecoveryMatrix/persistent_namespace_resumes_after_local_Kubernetes_restart (43.03s)
2026-10-11T20:11:32.9511842Z     --- PASS: TestDisposableNamespaceRecoveryMatrix/exclusive_candidate_startup_follows_ordered-ready_zero_then_one (12.78s)
2026-10-11T20:11:32.9512781Z     --- PASS: TestDisposableNamespaceRecoveryMatrix/recovery_does_not_persist_recovered_before_restored_workloads_are_ready (80.25s)
2026-10-11T20:11:32.9513608Z FAIL
2026-10-11T20:11:32.9516760Z FAIL	github.com/AFK-surf/comma/systems/ops/comma-release/release	438.347s
2026-10-11T20:11:32.9517360Z FAIL
2026-10-11T20:11:33.6775413Z make: *** [Makefile:122: test-comma-release-kubernetes-e2e] Error 1
2026-10-11T20:11:33.6777342Z make: Leaving directory '/home/runner/_work/Cue/Cue'
2026-10-11T20:11:33.6823024Z ##[error]Process completed with exit code 2.
2026-10-11T20:11:33.7057342Z Cleaning up orphan processes`;

// dashboard-e2e: an exception in a seed script.
const errorElixir = `2026-10-10T13:54:36.9010579Z {"ansi_color":"cyan","application":"ecto_sql","component":"other","domain":["elixir"],"error_class":"none","file":"lib/ecto/adapters/sql.ex","gl":"#PID<0.70.0>","level":"debug","line":1344,"mfa":["Elixir.Ecto.Adapters.SQL","log",5],"msg":"QUERY OK source=\\"projects\\" db=1.2ms queue=0.1ms idle=31.5ms\\nSELECT p0.\\"id\\", p0.\\"name\\", p0.\\"slug\\", p0.\\"status\\", p0.\\"salix
2026-10-10T13:54:36.9020260Z {"ansi_color":"magenta","application":"ecto_sql","component":"other","domain":["elixir"],"error_class":"none","file":"lib/ecto/adapters/sql.ex","gl":"#PID<0.70.0>","level":"debug","line":1344,"mfa":["Elixir.Ecto.Adapters.SQL","log",5],"msg":"QUERY OK db=0.6ms idle=30.6ms\\nbegin []","pid":"#PID<0.95.0>","revision":"unknown","surface":"system","ts":"2026-10-10T13:54:36.9
2026-10-10T13:54:36.9050441Z {"ansi_color":null,"application":"ecto_sql","component":"other","domain":["elixir"],"error_class":"none","file":"lib/ecto/adapters/sql.ex","gl":"#PID<0.70.0>","level":"debug","line":1344,"mfa":["Elixir.Ecto.Adapters.SQL","log",5],"msg":"QUERY OK db=0.3ms\\nrollback []","pid":"#PID<0.95.0>","revision":"unknown","surface":"system","ts":"2026-10-10T13:54:36.902Z","workload
2026-10-10T13:54:36.9059583Z ** (RuntimeError) could not seed external agent: :external_runtime_retired
2026-10-10T13:54:36.9060722Z     apps/bridge_for_teams_web/e2e/seed.exs:315: (file)
2026-10-10T13:54:36.9061002Z     (elixir 1.20.4) lib/code.ex:1639: Code.require_file/2
2026-10-10T13:54:36.9336282Z ##[error]Process completed with exit code 1.
2026-10-10T13:54:36.9388101Z ##[group]Run cat /tmp/dashboard.log || true`;

// bun-e2e: the error line is a heading.
const errorHeading = `2026-10-11T17:21:20.0682479Z       at run (/home/runner/_work/Cue/Cue/systems/e2e/tests/mcp_runtime_test.ts:74:15)
2026-10-11T17:21:20.0685716Z       at async <anonymous> (/home/runner/_work/Cue/Cue/systems/e2e/tests/mcp_runtime_test.ts:22:26)
2026-10-11T17:21:20.0729108Z 
2026-10-11T17:21:20.1496971Z ##[error]--- failure summary ---
MCP_RUNTIME_E2E: async MCP discovering
** (RuntimeError) MCP_RUNTIME_E2E step device async MCP failed: MCP tool not found for ["slow_progress"] in []
    scripts/mcp_runtime_e2e.exs:261: MCPRuntimeE2E.run_e2e_step!/2`;

// Browser Component Test. The URL's port is cut: the port lint reads any
// host:port in a test file as a port the test uses.
const dynamicImport = `2026-10-10T02:27:37.3385620Z \u001b[31m\u001b[1mTypeError\u001b[22m: Failed to fetch dynamically imported module: http://localhost/__pages/assets/main-B_wdagSL.js\u001b[39m`;

// Unit Test.
const fileExists = `2026-10-09T18:24:28.9198580Z Error: failed to create directory '/Users/admin/actions-runner/_work/Cue/Cue/node_modules/electron/dist/Electron.app': File exists (os error 17)`;

// Unit Test.
const econnreset = `2026-10-10T07:14:01.6780610Z ##[error]Failed to FinalizeArtifact: Unable to make request: ECONNRESET`;

const items = (parse, text) =>
  parse(logLines(text)).map(({ file, title }) => ({ file, title }));

test("a shard suffix is not part of the job name", () => {
  assert.equal(shardless("Browser E2E Test (2/2)"), "Browser E2E Test");
  assert.equal(shardless("test-beam (3/16)"), "test-beam");
  assert.equal(shardless("dashboard-e2e (salix_web)"), "dashboard-e2e");
  assert.equal(shardless("Unit Test"), "Unit Test");
});

test("Playwright failures are read from the list, the mark line, the annotation and the numbered block", () => {
  const project = "apps/electron/e2e/chat-runtime-ownership.spec.ts";
  const title =
    "email login resumes after editing the address and survives a rejected resend";
  assert.deepEqual(items(parsePlaywright, playwrightList), [{ file: project, title }]);
  assert.match(parsePlaywright(logLines(playwrightList))[0].detail, /Resend in 3/);

  // Only the mark line names the test, and its duration is not part of the title.
  assert.deepEqual(items(parsePlaywright, playwrightMarkOnly), [
    {
      file: "packages/app/e2e/analytics/posthog.spec.ts",
      title:
        "website first touch joins web registration across origins without private URL fields",
    },
  ]);

  assert.deepEqual(items(parsePlaywright, playwrightDot), [
    {
      file: "e2e/task-card-reorder.spec.ts",
      title: "the card sticks to the hand and falls into the well from where it is",
    },
  ]);
  assert.deepEqual(items(parsePlaywright, playwrightNoProject), [
    {
      file: "e2e/status-indicator.spec.ts",
      title: "status indicator snaps Shadow DOM motion with reduced motion",
    },
  ]);
});

test("a Playwright test keeps its identity when its line moves", () => {
  const moved = playwrightMarkOnly.replaceAll(":12:1", ":40:3");
  assert.deepEqual(
    items(parsePlaywright, moved),
    items(parsePlaywright, playwrightMarkOnly)
  );
});

test("Vitest failures are read with their suites, and files that fail to load or run are named", () => {
  assert.deepEqual(items(parseVitest, vitestTest), [
    {
      file: "apps/electron/src/main/test/synchronicity-control.test.ts",
      title:
        "SynchControlClient with the pinned daemon > streams a file larger than the renderer limit and survives token rotation",
    },
  ]);
  assert.equal(
    items(parseVitest, vitestBrowser)[0].file,
    "e2e/app-shell/markdown-stream.chromium.test.ts"
  );
  assert.match(
    items(parseVitest, vitestBrowser)[0].title,
    /^route bubble that just makes the transcript/
  );

  assert.deepEqual(items(parseVitest, vitestFileLoad), [
    { file: "apps/electron/src/main/test/native-side-chat.test.ts", title: fileTitle },
  ]);
  // The runner's checkout path is dropped.
  assert.deepEqual(items(parseVitest, vitestRunError), [
    { file: "e2e/app-shell/chat-panel-media.chromium.test.ts", title: fileTitle },
    { file: "e2e/app-shell/markdown-stream.chromium.test.ts", title: fileTitle },
  ]);
});

test("ExUnit failures give the test title and its file", () => {
  const [failure] = parseExUnit(logLines(exunit));
  assert.equal(failure.file, "apps/salix_agent/test/tools_peers_copy_test.exs");
  assert.equal(
    failure.title,
    "remote source streams into a fresh blob committed to the peer manifest"
  );
  assert.match(failure.detail, /ArithmeticError/);
});

const first = (text) => firstErrorLine(logLines(text));

test("a job that names no test is its first error line, without numbers that change between runs", () => {
  assert.equal(
    first(errorCurl),
    "curl: (28) Operation timed out after N milliseconds with 0 bytes received"
  );
  assert.equal(first(errorGo), "--- FAIL: TestDisposableNamespaceRecoveryMatrix (T)");
  assert.equal(
    first(errorElixir),
    "** (RuntimeError) could not seed external agent: :external_runtime_retired"
  );
  assert.equal(first(errorHeading), "MCP_RUNTIME_E2E: async MCP discovering");

  const parsed = parseJobLog(errorGo);
  assert.equal(parsed.tests, false);
  assert.deepEqual(
    parsed.items.map(({ file }) => file),
    [""]
  );
  assert.equal(parseJobLog(vitestTest).tests, true);
});

test("runner and network signatures are found in the log and not in a plain assertion", () => {
  assert.equal(matchSignature(fileExists), "file-exists");
  assert.equal(matchSignature(dynamicImport), "dynamic-import");
  assert.equal(matchSignature(errorCurl), "curl-timeout");
  assert.equal(matchSignature(econnreset), "econnreset");
  assert.equal(matchSignature("Error: write EMFILE: too many open files"), "emfile");
  assert.equal(matchSignature("erl_child_setup closed"), "erl-child-setup");
  assert.equal(
    matchSignature(
      "The runner has received a shutdown signal. This can happen when the runner service is stopped"
    ),
    "runner-lost"
  );
  assert.equal(matchSignature(playwrightList), null);
  assert.equal(matchSignature(exunit), null);
  assert.equal(
    new Set(runnerSignatures.map(({ id }) => id)).size,
    runnerSignatures.length
  );
  for (const signature of runnerSignatures) assert.ok(signature.label.length > 0);
});

const run = (index, ...failures) => ({
  id: String(index),
  sha: `sha${String(index).padStart(6, "0")}`,
  createdAt: `2026-10-10T0${index}:00:00Z`,
  conclusion: failures.length > 0 ? "failure" : "success",
  items: failures.map(([title, signature = null]) => ({
    job: "Unit Test",
    file: "a.test.ts",
    title,
    signature,
  })),
});

test("an item red in three consecutive runs is a regression, in two it is not", () => {
  const runs = [
    run(1, ["A"]),
    run(2, ["A"]),
    run(3, ["A"]),
    run(4),
    run(5, ["A"]),
    run(6, ["A"]),
    run(7),
  ];
  const { streaks, runs: classified } = classify(runs);
  assert.deepEqual(
    classified.map(({ class: name }) => name),
    ["regression", "regression", "regression", null, "random", "random", null]
  );
  assert.equal(streaks.length, 1);
  assert.deepEqual(
    [streaks[0].first, streaks[0].last, streaks[0].length, streaks[0].ongoing],
    [0, 2, 3, false]
  );
});

test("a run takes the worst class of its items: regression, then runner, then random", () => {
  const runs = [
    run(1, ["A"], ["B", "econnreset"], ["C"]),
    run(2, ["A"], ["D", "emfile"]),
    run(3, ["A"]),
    run(4, ["E"], ["F", "emfile"]),
    run(5, ["G"]),
    run(6, ["H"]),
  ];
  const classified = classify(runs).runs;
  assert.deepEqual(
    classified.map(({ class: name }) => name),
    ["regression", "regression", "regression", "runner", "random", "random"]
  );
  assert.deepEqual(
    classified[0].items.map(({ class: name }) => name),
    ["regression", "runner", "random"]
  );
});

test("a streak counts the runs of the item, not of the job: another test failing in between does not break it", () => {
  const runs = [run(1, ["A"], ["X"]), run(2, ["A"]), run(3, ["A"], ["Y"])];
  const { streaks } = classify(runs);
  assert.deepEqual(
    streaks.map(({ title }) => title),
    ["A"]
  );
});

test("days are counted in UTC+8 and the report ends with the random share", () => {
  assert.equal(dayOf("2026-10-10T15:59:59Z"), "2026-10-10");
  assert.equal(dayOf("2026-10-10T16:00:00Z"), "2026-10-11");

  const runs = [
    { ...run(1, ["A"]), createdAt: "2026-10-10T15:00:00Z" },
    { ...run(2, ["A"]), createdAt: "2026-10-10T16:00:00Z" },
    { ...run(3, ["A"]), createdAt: "2026-10-10T17:00:00Z" },
    { ...run(4, ["B"]), createdAt: "2026-10-10T18:00:00Z" },
    { ...run(5), createdAt: "2026-10-10T19:00:00Z" },
  ];
  const summary = summarize(runs);
  assert.deepEqual(summary.days, [
    { day: "2026-10-10", completed: 1, red: 1, regression: 1, runner: 0, random: 0 },
    { day: "2026-10-11", completed: 4, red: 3, regression: 2, runner: 0, random: 1 },
  ]);
  assert.deepEqual(
    summary.random.map(({ title, count, testsInFile }) => [title, count, testsInFile]),
    [["B", 1, 1]]
  );
  assert.deepEqual(
    [
      summary.regressions[0].began.sha,
      summary.regressions[0].lastRed.sha,
      summary.regressions[0].greenAt.sha,
    ],
    ["sha000001", "sha000003", "sha000004"]
  );
  const text = renderWorkflow("Unit", summary);
  assert.match(
    text,
    /== Unit: 5 completed, 4 red \(3 regression, 0 runner, 1 random\)/
  );
  assert.match(text, / 3 runs {2}Unit Test: a\.test\.ts > A/);
});

// A `gh` that serves a small history and records every call.
function fakeGh(dir) {
  const calls = join(dir, "calls.log");
  const logs = {
    A: ` FAIL   node  a.test.ts > Suite > A\nAssertionError: boom\n`,
    B: ` FAIL   node  b.test.ts > B\nError: read ECONNRESET\n`,
    C: ` FAIL   node  c.test.ts > C\nAssertionError: boom\n`,
  };
  const history = [
    [11, "failure", "A"],
    [12, "failure", "A"],
    [13, "failure", "A"],
    [14, "success"],
    [15, "failure", "B"],
    [16, "failure", "C"],
  ];
  const source = `#!${process.execPath}
const { appendFileSync } = require("node:fs");
const args = process.argv.slice(2).join(" ");
appendFileSync(${JSON.stringify(calls)}, args + "\\n");
const history = ${JSON.stringify(history)};
const logs = ${JSON.stringify(logs)};
if (args.includes("/workflows/client-checks.yml/runs")) {
  for (const [id, conclusion] of history) {
    const created = "2026-10-10T0" + (id - 10) + ":00:00Z";
    console.log(JSON.stringify({ id, conclusion, createdAt: created, sha: "sha" + id, attempt: 1, message: "commit " + id }));
  }
} else if (args.includes("/logs")) {
  const id = Number(/jobs\\/(\\d+)\\/logs/.exec(args)[1]) / 10;
  process.stdout.write(logs[history.find(([run]) => run === id)[2]]);
} else if (args.includes("/jobs")) {
  const id = Number(/runs\\/(\\d+)\\/jobs/.exec(args)[1]);
  console.log(JSON.stringify({ id: id * 10, name: "Unit Test (1/2)", conclusion: "failure" }));
  console.log(JSON.stringify({ id: id * 10 + 1, name: "Required Client CI", conclusion: "failure" }));
} else {
  console.error("unexpected " + args);
  process.exit(1);
}
`;
  writeFileSync(join(dir, "gh"), source);
  chmodSync(join(dir, "gh"), 0o755);
  return { bin: dir, calls };
}

test("the command line sorts a fake history, downloads each log once and ends with one number", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-main-failures-test-"));
  const { bin, calls } = fakeGh(dir);
  const cache = join(dir, "cache");
  const exec = () =>
    spawnSync(
      process.execPath,
      [
        script,
        "--workflow",
        "Client Checks",
        "--since",
        "2026-10-10",
        "--cache",
        cache,
      ],
      { env: { PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8" }
    );

  const firstRun = exec();
  assert.equal(firstRun.status, 0, firstRun.stderr);
  const lines = firstRun.stdout.trimEnd().split("\n");
  assert.match(
    lines[0],
    /== Client Checks: 6 completed, 5 red \(3 regression, 1 runner, 1 random\)/
  );
  assert.match(firstRun.stdout, /Runner or network signatures\n.*econnreset/);
  assert.equal(lines.at(-1), "0.167"); // one random red run of six

  const callsAfterFirst = readFileSync(calls, "utf8").trimEnd().split("\n");
  assert.equal(callsAfterFirst.filter((call) => call.includes("/logs")).length, 5);
  assert.equal(
    callsAfterFirst.filter((call) => /\/runs\/\d+\/jobs/.test(call)).length,
    5
  );

  // The second run asks only for the run list: jobs and logs come from the cache.
  const second = exec();
  assert.equal(second.stdout, firstRun.stdout);
  const callsAfterSecond = readFileSync(calls, "utf8").trimEnd().split("\n");
  assert.equal(callsAfterSecond.length - callsAfterFirst.length, 1);
  assert.ok(callsAfterSecond.at(-1).includes("/workflows/client-checks.yml/runs"));
});

test("the JSON output carries the same numbers", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-main-failures-test-"));
  const { bin } = fakeGh(dir);
  const result = spawnSync(
    process.execPath,
    [
      script,
      "--workflow",
      "client checks",
      "--since",
      "2026-10-10",
      "--cache",
      join(dir, "cache"),
      "--json",
    ],
    { env: { PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8" }
  );
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(
    [report.completed, report.random, report.randomRatio.toFixed(3)],
    [6, 1, "0.167"]
  );
  assert.deepEqual(report.workflows[0].total, {
    completed: 6,
    red: 5,
    regression: 3,
    runner: 1,
    random: 1,
  });
});

test("an unknown option or workflow stops with a message", () => {
  for (const args of [["--nope"], ["--workflow", "Nightly"]]) {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /unknown/);
  }
});
