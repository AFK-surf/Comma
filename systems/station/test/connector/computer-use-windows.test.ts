// Computer Use on Windows maps the background-mode actions onto Cua Driver's tools: get_app_state finds the app's
// window and reads it, actions address that snapshot's elements by index and return the window's new state. The
// driver here is a scripted connection that records the calls it gets.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { type DriverConnection, makeWindowsComputerUse, windowsKeys } from "../../src/connector/computer-use-windows.ts";

const run = <A>(effect: Effect.Effect<A>) => Effect.runPromise(effect);

const notepadState = (value = "") => ({
  structured: {
    app_name: "notepad.exe",
    window_title: "Untitled - Notepad",
    capture_id: "capture_1",
    screenshot_width: 754,
    screenshot_height: 512,
    tree_markdown: `- Window "Untitled - Notepad"\n  - [0] Edit "Text Editor" [value="${value}" actions=[set_value,scroll]]\n  - [3] Button "Minimize" [actions=[invoke]]`,
    elements: [
      { element_index: 0, element_token: "s00000001:0", screenshot_frame: { x: 0, y: 50, w: 752, h: 437 } },
      { element_index: 3, element_token: "s00000001:3", actions: ["invoke"], screenshot_frame: { x: 613, y: 0, w: 47, h: 30 } },
      { element_index: 8, element_token: "s00000001:8", actions: ["expand"], screenshot_frame: { x: 66, y: 30, w: 52, h: 19 } },
    ],
  },
  image: { data: Buffer.from("png").toString("base64"), mimeType: "image/png" },
  text: "",
  isError: false,
});

function fakeDriver() {
  const calls: Array<[string, Record<string, unknown>]> = [];
  let typed = "";
  const connection: DriverConnection = {
    async callTool(name, args) {
      calls.push([name, args]);
      switch (name) {
        case "list_apps":
          return {
            structured: {
              apps: [
                { name: "explorer.exe", pid: 10, running: true },
                { name: "Notepad", bundle_id: "C:\\Windows\\system32\\notepad.exe", pid: 1140, running: true },
              ],
            },
            text: "",
            isError: false,
          };
        case "list_windows":
          return {
            structured: {
              windows: [
                { pid: 1140, title: "Hidden", window_id: 7, minimized: true, z_index: 0 },
                { pid: 1140, title: "Untitled - Notepad", window_id: 131594, is_on_screen: true, z_index: 1 },
              ],
            },
            text: "",
            isError: false,
          };
        case "get_window_state":
          return notepadState(typed);
        case "type_text":
          // Like Notepad: background typing is dropped, and the driver says the foreground would take it.
          if (args.delivery_mode === "background")
            return { structured: { delivery: { mode: "background" }, escalation: { reason: "delivery_failed", target: "foreground" } }, text: "", isError: false };
          typed += String(args.text);
          return { structured: {}, text: "", isError: false };
        case "click":
          // Like Notepad's menus: ExpandCollapse is listed and refused.
          if (args.action === "expand") return { structured: { error: { message: "ExpandCollapse.Expand failed: 0x80040200" } }, text: "", isError: true };
          return { structured: {}, text: "", isError: false };
        case "set_value":
          return { structured: { error: { message: "element is read-only" } }, text: "", isError: true };
        default:
          return { structured: {}, text: "", isError: false };
      }
    },
    close: async () => {},
  };
  return { calls, connection };
}

function windowsComputerUse() {
  const driver = fakeDriver();
  const stored: unknown[] = [];
  const cu = makeWindowsComputerUse(
    {
      executable: "cua-driver.exe",
      home: "home",
      cursorThemes: "themes",
      env: {},
      storeImage: (response) => Effect.sync(() => (stored.push(response), { ok: true, image_path: "capture-1.png", image_width: response.imageWidth })),
    },
    async () => driver.connection,
  );
  return { cu, calls: driver.calls, stored };
}

test("TestWindowsSessionShowsTheBrandCursor", async () => {
  const { cu, calls } = windowsComputerUse();
  assert.equal((await run(cu.call("start", {}))).ok, true);
  assert.deepEqual(calls.find(([name]) => name === "start_session")![1], { cursor_theme: { theme_id: "comma.brand" } });
});

test("TestWindowsGetAppStateReadsTheAppsWindowWithItsScreenshot", async () => {
  const { cu, calls, stored } = windowsComputerUse();
  const state = await run(cu.call("get_app_state", { app: "notepad" }));
  assert.equal(state.ok, true);
  assert.equal(state.image_path, "capture-1.png");
  assert.match(String(state.text), /Computer Use state \(Snapshot: w1\)/);
  assert.match(String(state.text), /\[0\] Edit "Text Editor"/);
  assert.match(String(state.text), /ScreenshotSize: 754x512/);
  assert.equal(stored.length, 1);
  // The open window, not the minimized one.
  assert.deepEqual(calls.find(([name]) => name === "get_window_state")![1], {
    pid: 1140,
    window_id: 131594,
    tree_format: "both",
    include_screenshot: true,
    max_image_dimension: 1568,
  });
});

test("TestWindowsActionsAddressSnapshotElementsAndReturnTheNewState", async () => {
  const { cu, calls } = windowsComputerUse();
  const first = await run(cu.call("get_app_state", { app: "Notepad", window_title: "untitled" }));
  assert.equal(first.ok, true);
  const typed = await run(cu.call("type_text", { snapshot_id: "w1", element_index: 0, text: "hello" }));
  assert.match(String(typed.text), /value="hello"/);
  assert.match(String(typed.text), /Snapshot: w2/);
  // Background first; the foreground only once the driver says the background failed, and the result says so.
  assert.deepEqual(
    calls.filter(([name]) => name === "type_text").map(([, args]) => args),
    [
      { pid: 1140, window_id: 131594, text: "hello", element_token: "s00000001:0", delivery_mode: "background" },
      { pid: 1140, window_id: 131594, text: "hello", element_token: "s00000001:0", delivery_mode: "foreground" },
    ],
  );
  assert.match(String(typed.text), /sent in the foreground/);

  const clicked = await run(cu.call("click", { snapshot_id: "w2", element_index: 3 }));
  assert.doesNotMatch(String(clicked.text), /foreground/);
  assert.deepEqual(calls.find(([name]) => name === "click")![1], { pid: 1140, window_id: 131594, element_token: "s00000001:3", delivery_mode: "background" });

  // A menu without Invoke opens through ExpandCollapse, and with a real click in the foreground where it refuses that.
  const opened = await run(cu.call("click", { snapshot_id: "w2", element_index: 8 }));
  assert.equal(opened.ok, true);
  assert.match(String(opened.text), /sent in the foreground/);
  assert.deepEqual(
    calls.filter(([name]) => name === "click").slice(1, 3).map(([, args]) => args),
    [
      { pid: 1140, window_id: 131594, element_token: "s00000001:8", action: "expand", delivery_mode: "background" },
      { pid: 1140, window_id: 131594, element_token: "s00000001:8", delivery_mode: "foreground" },
    ],
  );

  await run(cu.call("click", { snapshot_id: "w2", x: 20, y: 30 }));
  assert.deepEqual(calls.filter(([name]) => name === "click")[3]![1], { pid: 1140, window_id: 131594, x: 20, y: 30, capture_id: "capture_1", delivery_mode: "background" });

  await run(cu.call("press_key", { snapshot_id: "w2", key: "cmd+s" }));
  assert.deepEqual(calls.find(([name]) => name === "hotkey")![1], { pid: 1140, window_id: 131594, keys: ["ctrl", "s"], delivery_mode: "background" });

  await run(cu.call("scroll", { snapshot_id: "w2", element_index: 0, direction: "down" }));
  assert.deepEqual(calls.find(([name]) => name === "scroll")![1], { pid: 1140, window_id: 131594, x: 376, y: 268.5, direction: "down", by: "page", amount: 1, delivery_mode: "background" });
});

test("TestWindowsFailuresComeBackAsResults", async () => {
  const { cu } = windowsComputerUse();
  assert.deepEqual(await run(cu.call("click", { element_index: 0 })), { ok: false, error: "'snapshot_id' is required; call get_app_state first" });
  assert.match(String((await run(cu.call("get_app_state", { app: "Paint" }))).error), /not running/);
  await run(cu.call("get_app_state", { app: "notepad" }));
  assert.deepEqual(await run(cu.call("set_value", { snapshot_id: "w1", element_index: 0, value: "x" })), { ok: false, error: "element is read-only" });
  assert.match(String((await run(cu.call("click", { snapshot_id: "w1", element_index: 9 }))).error), /element 9 is not in that snapshot/);
  assert.match(String((await run(cu.call("start", { mode: "foreground" }))).error), /background mode only/);
});

test("TestWindowsKeysNameMacModifiersAsWindowsOnes", () => {
  assert.deepEqual(windowsKeys("cmd+shift+S"), ["ctrl", "shift", "s"]);
  assert.deepEqual(windowsKeys("return"), ["enter"]);
  assert.deepEqual(windowsKeys("option+f4"), ["alt", "f4"]);
});
