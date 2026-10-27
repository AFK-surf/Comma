// A desktop's Main serves the Mac apps MCP server. Salix reaches it through the connector's client_mcp method,
// which forwards one JSON-RPC message with Main's credential, also while the device is read-only, and not
// once its owner turned the computer's access off.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Exit, Fiber, Layer } from "effect";
import { CLIENT_MCP_TIMEOUT, ClientControl, SCOPE_LOCAL_FILE_READ, makeConnector } from "../../src/connector/connector.ts";
import { eventually } from "./support/eventually.ts";

const desktop = {
  deviceMode: true,
  configPath: "main-owned.json",
  deviceWorkspaceId: "wsp_owned",
  scope: SCOPE_LOCAL_FILE_READ,
  env: { COMMA_CLIENT_CONTROL_URL: "http://main.test", COMMA_CLIENT_CONTROL_TOKEN: "main-test-token" },
};

const listTools = { jsonrpc: "2.0", id: 7, method: "tools/list", params: {} };

test("TestReadOnlyDesktopForwardsClientMcpToMain", async () => {
  const asked: Array<{ server: string; message: unknown }> = [];
  const control = Layer.succeed(ClientControl)({
    call: () => Effect.fail(new Error("not an invoke")),
    mcp: (token, server, message) =>
      Effect.sync(() => {
        assert.equal(token, "main-test-token", "missing Main credential");
        asked.push({ server, message });
        return { jsonrpc: "2.0", id: 7, result: { tools: [] } };
      }),
  });
  const c = makeConnector(desktop, control);
  assert.deepEqual(c.metadata().capabilities!.client_mcp, ["mac-apps"]);
  const exit = await Effect.runPromiseExit(c.dispatchForTest("mcp", "client_mcp", { server: "mac-apps", message: listTools }));
  assert.ok(Exit.isSuccess(exit), "a read-only desktop refused client_mcp");
  assert.deepEqual(exit.value, { message: { jsonrpc: "2.0", id: 7, result: { tools: [] } } });
  assert.deepEqual(asked, [{ server: "mac-apps", message: listTools }]);
  assert.equal(c.currentScope(), SCOPE_LOCAL_FILE_READ, "client_mcp widened the device's access");
});

test("TestClientMcpRefusesUnknownServersAndDevicesWithoutMain", async () => {
  const control = Layer.succeed(ClientControl)({
    call: () => Effect.fail(new Error("not an invoke")),
    mcp: () => Effect.fail(new Error("Main must not be asked")),
  });
  const unknown = await Effect.runPromiseExit(
    makeConnector(desktop, control).clientMcp({ server: "shell", message: listTools }),
  );
  assert.ok(Exit.isFailure(unknown), "an unknown server was forwarded");

  const standalone = makeConnector({ deviceMode: true, scope: SCOPE_LOCAL_FILE_READ, env: {} }, control);
  assert.deepEqual(standalone.metadata().capabilities!.client_mcp, []);
  const exit = await Effect.runPromiseExit(standalone.clientMcp({ server: "mac-apps", message: listTools }));
  assert.ok(Exit.isFailure(exit), "a device without Main forwarded client_mcp");

  const malformed = await Effect.runPromiseExit(makeConnector(desktop, control).clientMcp({ server: "mac-apps", message: [1] }));
  assert.ok(Exit.isFailure(malformed), "a non-object message was forwarded");
});

test("TestClientMcpStopsWhenTheComputersAccessIsOff", async () => {
  const control = Layer.succeed(ClientControl)({
    call: () => Effect.fail(new Error("not an invoke")),
    mcp: () => Effect.fail(new Error("Main must not be asked")),
  });
  const c = makeConnector(desktop, control);
  await Effect.runPromise(c.deviceAccess({ access: "off" }));
  const exit = await Effect.runPromiseExit(c.dispatchForTest("mcp", "client_mcp", { server: "mac-apps", message: listTools }));
  assert.ok(Exit.isFailure(exit), "a computer with access off forwarded client_mcp");
});

test("TestClientMcpGivesUpOnASilentMainAndSaysTheOutcomeIsUnknown", async () => {
  let aborted = false;
  const control = Layer.succeed(ClientControl)({
    call: () => Effect.fail(new Error("not an invoke")),
    mcp: () => Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => void (aborted = true)))),
  });
  const c = makeConnector({ ...desktop, testClock: true }, control);
  const call = { jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "messages_send", arguments: {} } };
  const fiber = Effect.runFork(c.clientMcp({ server: "mac-apps", message: call }));
  // Main has not answered; its deadline goes by on the connector's test clock.
  await eventually(() => c.sleepsForTest() > 0, "the wait for Main");
  await Effect.runPromise(c.advanceClockForTest(CLIENT_MCP_TIMEOUT));
  const exit = await Effect.runPromise(Fiber.await(fiber));
  assert.ok(Exit.isFailure(exit), "a silent Main was waited on past the deadline");
  assert.match(String(Exit.isFailure(exit) && exit.cause), /may or may not have been made/);
  assert.ok(aborted, "the request to Main was not aborted");
});
