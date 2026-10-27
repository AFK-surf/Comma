// Ported from systems/connector/salix-connect/computer_use_test.go (same test names).
// Computer Use talks to the app's helper daemon over a private Unix socket with an auth token: the capability follows
// the helper's presence, actions map to daemon requests and responses to results, the helper launches as its prepared
// application, socket paths are per runtime and fit macOS's limit, and screenshots are stored bounded and expiring.
// The daemon is a real Unix socket that answers one request (local IPC); image expiry runs on the connector's clock.
import assert from "node:assert/strict";
import { mkdirSync, rmSync, existsSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { applyConfigFile, defaultConfig, normalizeConfig } from "../../src/connector/config.ts";
import { type Connector, makeConnector } from "../../src/connector/connector.ts";
import {
  COMPUTER_USE_HELLO_MESSAGE,
  COMPUTER_USE_IMAGE_MAX_BYTES,
  COMPUTER_USE_IMAGE_MAX_COUNT,
  COMPUTER_USE_IMAGE_TTL_MS,
  COMPUTER_USE_SOCKET_DIRECTORY_NAME,
  COMPUTER_USE_SOCKET_PATH_MAX_BYTES,
  computerUseHelperOpenArgs,
  computerUseSocketIdentity,
  computerUseSocketPathForRuntime,
  defaultComputerUseSocketPath,
} from "../../src/connector/computer-use.ts";
import { tempDir } from "./support/temp.ts";

const darwin = process.platform === "darwin";
const macOnly = { skip: darwin ? false : "macOS only" };
const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

/** A daemon socket that answers the hello and then one request with `response`; the request it got is returned. */
function fakeDaemon(response: string) {
  const path = join("/tmp", `cu-${process.pid}-${Math.random().toString(36).slice(2)}.sock`);
  let resolveRequest: (request: Record<string, any>) => void = () => {};
  const request = new Promise<Record<string, any>>((resolve) => (resolveRequest = resolve));
  const server: Server = createServer((conn) => {
    let buffer = "";
    conn.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const parsed = JSON.parse(buffer.slice(0, newline));
      if (parsed.control === "hello") {
        conn.end(`${JSON.stringify({ kind: "final", response: { ok: true, message: COMPUTER_USE_HELLO_MESSAGE } })}\n`);
        return;
      }
      resolveRequest(parsed);
      conn.end(response.endsWith("\n") ? response : `${response}\n`);
      server.close();
    });
  });
  return new Promise<{ path: string; request: Promise<Record<string, any>> }>((resolve) => server.listen(path, () => resolve({ path, request })));
}

function computerUseConnector(socketPath: string): Connector {
  const helperApp = join(tempDir(), "Comma Computer Use.app");
  mkdirSync(helperApp, { recursive: true });
  return makeConnector({ name: "laptop", root: tempDir(), computerUseHelperApp: helperApp, computerUseSocketPath: socketPath, computerUseRuntimePath: tempDir(), env: { HOME: tempDir() } });
}

const assertToken = (request: Record<string, any>) => assert.ok(typeof request.auth_token === "string" && request.auth_token.trim(), "the request has no auth_token");

test("TestDefaultComputerUseHelperPathFollowsConnectorBinary", macOnly, () => {
  const dir = tempDir();
  const cfg = { ...defaultConfig(), executablePath: join(dir, "salix-connect") };
  normalizeConfig(cfg);
  assert.equal(cfg.computerUseHelperApp, join(dir, "native", "macos", "Comma Computer Use.app"));
});

test("TestComputerUseMetadataReflectsHelperAvailability", () => {
  const missing = makeConnector({ name: "laptop", root: tempDir(), computerUseHelperApp: join(tempDir(), "missing.app") });
  assert.equal(missing.metadata().capabilities!.computer_use_tool, false);
  const helperApp = join(tempDir(), "Comma Computer Use.app");
  mkdirSync(helperApp, { recursive: true });
  const present = makeConnector({ name: "laptop", root: tempDir(), computerUseHelperApp: helperApp });
  assert.equal(present.metadata().capabilities!.computer_use_tool, darwin);
});

test("TestComputerUseStartSendsDaemonRequestAndReturnsHelp", macOnly, async () => {
  const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true,"display":{"display":1}}}');
  const c = computerUseConnector(daemon.path);
  const result = await run(c.computerUse({ action: "start", args: { apps: ["Safari"], display: 2 } }));
  assert.deepEqual([result.ok, result.mode], [true, "background"]);
  assert.match(String(result.help), /get_app_state/);
  const request = await daemon.request;
  assertToken(request);
  assert.equal(request.display, 2);
  assert.deepEqual(request.action.start, { apps: ["Safari"], mode: "background" });
});

test("TestComputerUseStartForegroundOnRequest", macOnly, async () => {
  const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true}}');
  const c = computerUseConnector(daemon.path);
  const result = await run(c.computerUse({ action: "start", args: { mode: "foreground" } }));
  assert.equal(result.mode, "foreground");
  assert.match(String(result.help), /get_screenshot/);
  assert.equal((await daemon.request).action.start.mode, "foreground");
  const bad = await run(c.computerUse({ action: "start", args: { mode: "sideways" } }));
  assert.equal(bad.ok, false);
});

for (const [action, args, payload] of [
  ["get_app_state", { app: "Comma", window_title: "Settings" }, { app: "Comma", window_title: "Settings" }],
  ["click", { snapshot_id: "s1", element_index: 7 }, { snapshot_id: "s1", element_index: 7 }],
  ["click", { snapshot_id: "s1", x: 10, y: 20 }, { snapshot_id: "s1", x: 10, y: 20 }],
  ["set_value", { snapshot_id: "s1", element_index: 3, value: "on" }, { snapshot_id: "s1", element_index: 3, value: "on" }],
  ["set_value", { snapshot_id: "s1", element_index: 3, value: "" }, { snapshot_id: "s1", element_index: 3, value: "" }],
  ["type_text", { snapshot_id: "s1", text: "  two\nlines " }, { snapshot_id: "s1", text: "  two\nlines " }],
  ["scroll", { snapshot_id: "s1", element_index: 2, direction: "down" }, { snapshot_id: "s1", element_index: 2, direction: "down" }],
] as const) {
  test(`TestComputerUseBackgroundActionsAddressSnapshotElements/${action}`, macOnly, async () => {
    const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true,"text":"state"}}');
    const c = computerUseConnector(daemon.path);
    assert.equal((await run(c.computerUse({ action, args }))).ok, true);
    assert.deepEqual((await daemon.request).action[action], payload);
  });
}

test("TestComputerUseBackgroundElementActionsNeedSnapshot", async () => {
  const result = await run(makeConnector({}).computerUse({ action: "set_value", args: { element_index: 3, value: "on" } }));
  assert.equal(result.ok, false);
  assert.match(String(result.error), /snapshot_id/);
});

test("TestComputerUseBackgroundStateReturnsTreeWithScreenshot", macOnly, async () => {
  const daemon = await fakeDaemon(
    '{"kind":"final","response":{"ok":true,"text":"Computer Use state (ComputerUseNext Snapshot: s2)\\n<app_state>tree</app_state>","imageData":"AQID","imageContentType":"image/png","imageWidth":10,"imageHeight":20}}',
  );
  const c = computerUseConnector(daemon.path);
  const result = await run(c.computerUse({ action: "click", args: { snapshot_id: "s1", element_index: 7 } }));
  assert.equal(result.ok, true);
  assert.equal(typeof result.image_path, "string");
  assert.match(String(result.text), /<app_state>tree<\/app_state>/);
  await daemon.request;
});

test("TestComputerUseScreenshotConvertsImageEnvelope", macOnly, async () => {
  const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true,"imageData":"AQID","imageContentType":"image/jpeg","imageWidth":10,"imageHeight":20}}');
  const c = computerUseConnector(daemon.path);
  const result = await run(c.computerUse({ action: "get_screenshot" }));
  assert.equal(result.ok, true);
  const name = String(result.image_path);
  const read = await run(c.computerUse({ action: "read_image", args: { path: name } }));
  assert.equal(read.image_base64, "AQID");
  assert.deepEqual([result.image_width, result.image_height, result.image_size_bytes], [10, 20, 3]);
  const request = await daemon.request;
  assertToken(request);
  assert.ok("get_screenshot" in request.action);
});

test("TestComputerUseOpenPermissionFlowSendsControlRequest", macOnly, async () => {
  const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true,"message":"Authorization window opened.","permissions":{"accessibility":false,"screenRecording":true}}}');
  const c = computerUseConnector(daemon.path);
  const result = await run(c.computerUse({ action: "open-permission-flow" }));
  assert.equal(result.ok, true);
  assert.match(String(result.text), /Authorization window opened\./);
  assert.deepEqual(result.permissions, { accessibility: false, screenRecording: true });
  const request = await daemon.request;
  assertToken(request);
  assert.equal(request.control, "open-permission-flow");
  assert.ok(!("action" in request), "the permission flow request included an action");
});

for (const [action, response, daemonAction] of [
  ["permissions-status", '{"kind":"final","response":{"ok":true,"permissions":{"accessibility":true,"screenRecording":true}}}', "permissions_status"],
  ["list-applications", '{"kind":"final","response":{"ok":true,"text":"[]"}}', "list_applications"],
]) {
  test(`TestComputerUseQueriesSendDaemonAction/${action}`, macOnly, async () => {
    const daemon = await fakeDaemon(response);
    const c = computerUseConnector(daemon.path);
    assert.equal((await run(c.computerUse({ action }))).ok, true);
    const request = await daemon.request;
    assertToken(request);
    assert.ok(daemonAction in request.action, `the daemon action is not ${daemonAction}`);
  });
}

test("TestComputerUseShutdownSendsControlRequest", macOnly, async () => {
  const daemon = await fakeDaemon('{"kind":"final","response":{"ok":true}}');
  const c = computerUseConnector(daemon.path);
  await run(c.shutdownComputerUseDaemon);
  const request = await daemon.request;
  assertToken(request);
  assert.equal(request.control, "shutdown");
});

test("TestComputerUsePermissionsOpenUIIsUnsupported", async () => {
  const result = await run(makeConnector({}).computerUse({ action: "permissions-open-ui" }));
  assert.equal(result.ok, false);
  assert.match(String(result.error), /unsupported computer_use action/);
});

test("TestComputerUseErrorsAndInterruptedResponses", macOnly, async () => {
  let daemon = await fakeDaemon('{"kind":"final","response":{"ok":false,"error":"daemon exploded"}}');
  let result = await run(computerUseConnector(daemon.path).computerUse({ action: "status" }));
  assert.deepEqual([result.ok, result.error], [false, "daemon exploded"]);
  await daemon.request;
  daemon = await fakeDaemon('{"kind":"final","response":{"ok":false,"interrupted":true,"message":"user took over"}}');
  result = await run(computerUseConnector(daemon.path).computerUse({ action: "status" }));
  assert.deepEqual([result.ok, result.error, result.interrupted], [false, "user took over", true]);
  await daemon.request;
});

test("TestComputerUseHelperOpenArgsCarryRuntimePathsAndToken", () => {
  const args = computerUseHelperOpenArgs("/Applications/Comma Computer Use.app", "/tmp/custom-computer-use.sock", "/tmp/@comma-staging/computer-use", "secret-token");
  for (const want of ["-n", "--env", "COMMA_COMPUTER_USE_SOCKET_PATH=/tmp/custom-computer-use.sock", "COMMA_COMPUTER_USE_RUNTIME_PATH=/tmp/@comma-staging/computer-use", "COMMA_COMPUTER_USE_AUTH_TOKEN=secret-token"]) {
    assert.ok(args.includes(want), `missing ${want}`);
  }
  assert.equal(args.at(-1), "/Applications/Comma Computer Use.app", "the app path is not last");
});

test("TestComputerUseLaunchesPreparedApplication", macOnly, async () => {
  const c = computerUseConnector(join(tempDir(), "daemon.sock"));
  const executable = join(c.config().computerUseHelperApp, "Contents", "MacOS", "CommaComputerUseDaemon");
  mkdirSync(join(executable, ".."), { recursive: true });
  writeFileSync(executable, `#!/bin/sh\n[ "$1" = --prepare-app ] || exit 1\nprintf '%s\\n' "$0.standalone.app"\n`, { mode: 0o755 });
  const command = await run(c.computerUseHelperCommand("test-token"));
  assert.equal(command.args.at(-1), `${executable}.standalone.app`, "launched something other than the installed app");
  writeFileSync(executable, "#!/bin/sh\necho 'installation busy' >&2\nexit 1\n", { mode: 0o755 });
  const failed = await Effect.runPromiseExit(c.computerUseHelperCommand("test-token"));
  assert.ok(Exit.isFailure(failed) && String(failed.cause).includes("installation busy"), "an installation failure did not stop the launch with an actionable error");
});

test("TestComputerUseSocketPathFollowsRuntimeRoot", macOnly, async () => {
  const first = computerUseSocketPathForRuntime("@comma-staging", join(tempDir(), "one", "profile"));
  const second = computerUseSocketPathForRuntime("@comma-staging", join(tempDir(), "two", "profile"));
  assert.notEqual(first, second, "same-basename runtime roots share a socket path");
  mkdirSync(join(first, ".."), { recursive: true, mode: 0o700 });
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(first, () => resolve()));
  server.close();
  assert.ok(!computerUseSocketPathForRuntime("../unsafe namespace", join(tempDir(), "profile")).split("/").at(-1)!.includes(".."), "an unsafe namespace was not contained");
});

test("TestComputerUseSocketPathStaysWithinMacOSLimit", macOnly, () => {
  const env = { TMPDIR: join(tempDir(), "long-temp-root-".repeat(8)) };
  const path = computerUseSocketPathForRuntime("long-release-namespace-".repeat(8), join(tempDir(), "long-runtime-root-".repeat(16), "profile"), env.TMPDIR);
  assert.ok(Buffer.byteLength(path) + 1 <= COMPUTER_USE_SOCKET_PATH_MAX_BYTES, `the socket path is too long: ${path}`);
  assert.ok(path.startsWith("/tmp/comma-cu-"), "a long TMPDIR did not use the compact per-user fallback");
});

test("TestComputerUseSocketPathFallsBackAtExactMacOSBufferSize", macOnly, async () => {
  const namespace = "@comma-staging";
  const runtimeRoot = join(tempDir(), "profile");
  const relative = join(COMPUTER_USE_SOCKET_DIRECTORY_NAME, `${computerUseSocketIdentity(namespace, runtimeRoot)}.sock`);
  const rootLength = COMPUTER_USE_SOCKET_PATH_MAX_BYTES - Buffer.byteLength(relative) - 1;
  const prefix = `/tmp/comma-boundary-${process.pid}-`;
  const tempRoot = prefix + "x".repeat(rootLength - prefix.length);
  mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
  try {
    const candidate = join(tempRoot, relative);
    assert.equal(Buffer.byteLength(candidate), COMPUTER_USE_SOCKET_PATH_MAX_BYTES);
    const path = computerUseSocketPathForRuntime(namespace, runtimeRoot, tempRoot);
    assert.ok(path !== candidate && path.startsWith("/tmp/comma-cu-"), "an exact-buffer-size path did not use the compact fallback");
    assert.ok(Buffer.byteLength(path) + 1 <= COMPUTER_USE_SOCKET_PATH_MAX_BYTES);
    mkdirSync(join(path, ".."), { recursive: true, mode: 0o700 });
    const server = createServer();
    await new Promise<void>((resolve) => server.listen(path, () => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(path, { force: true });
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("TestComputerUseRuntimeFollowsElectronConfig", macOnly, async () => {
  const root = join(tempDir(), "@comma-staging");
  const configPath = join(tempDir(), "connector.json");
  writeFileSync(configPath, JSON.stringify({ connector: { root: "." }, electron: { runtime_namespace: "@comma-staging", runtime_root: root } }), { mode: 0o600 });
  const cfg = { ...defaultConfig(), configPath };
  await run(applyConfigFile(cfg, new Set()));
  normalizeConfig(cfg);
  assert.equal(cfg.computerUseSocketPath, computerUseSocketPathForRuntime("@comma-staging", root));
  assert.equal(cfg.computerUseRuntimePath, join(root, "computer-use"));
});

test("TestDefaultComputerUseSocketPathAvoidsGlobalTmpSocket", macOnly, () => {
  const path = defaultComputerUseSocketPath();
  assert.notEqual(path, "/tmp/computeruse.sock", "the default socket path is the global one");
  assert.ok(path.includes(COMPUTER_USE_SOCKET_DIRECTORY_NAME));
});

test("TestComputerUseImageExpiryAndIsolation", async () => {
  const runtimePath = tempDir();
  const c = makeConnector({ computerUseRuntimePath: runtimePath, testClock: true });
  const result = await run(c.storeComputerUseImage({ imageData: Buffer.from("image"), imageContentType: "image/png" }));
  const name = String(result.image_path);
  const path = join(runtimePath, "screenshots", name);
  assert.equal(readFileSync(path, "utf8"), "image");
  // An independently made connector reads a retained image after a restart.
  assert.equal((await run(makeConnector({ computerUseRuntimePath: runtimePath }).readComputerUseImage(name))).ok, true);
  assert.equal((await run(c.readComputerUseImage(`../${name}`))).ok, false, "a path outside the image directory was read");
  const old = new Date(c.nowForTest() - COMPUTER_USE_IMAGE_TTL_MS - 1000);
  utimesSync(path, old, old);
  assert.equal((await run(c.readComputerUseImage(name))).ok, false, "an expired image was read");
  assert.ok(!existsSync(path), "the expired image remains");
});

test("TestComputerUseImageStorageBound", async () => {
  const c = makeConnector({ computerUseRuntimePath: tempDir() });
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(c.storeComputerUseImage({ imageData: Buffer.alloc(COMPUTER_USE_IMAGE_MAX_BYTES + 1), imageContentType: "image/png" }))), "an oversized image was accepted");
  const dir = await run(c.computerUseImageDirectory);
  for (let i = 0; i < COMPUTER_USE_IMAGE_MAX_COUNT; i++) writeFileSync(join(dir, `capture-${i}.png`), "x", { mode: 0o600 });
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(c.storeComputerUseImage({ imageData: Buffer.from("new"), imageContentType: "image/png" }))), "an image above the count limit was accepted");
  assert.equal((await run(c.readComputerUseImage("capture-0.png"))).ok, true);
});
