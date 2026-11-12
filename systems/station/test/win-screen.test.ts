// Windows' main display as a screen (screens/win-desktop.ts, docs/desktop-screen.md): its input as Windows posts it, a
// comma-desktop-screen process for each view (a fake one, node running FAKE_SCREEN, anywhere; the real one where it is
// built on Windows), and the view on the mesh saying the pointer the process says. Ported from still.fail's
// station/test/screens.test.ts ("input as Windows posts it", "Windows' desktop: …"), with Cue's wire input added.
import assert from "node:assert/strict";
import { test } from "node:test";
import { platform } from "../src/platform/index.ts";
import type { ScreenRefused } from "../src/screens/hub.ts";
import { WindowsDesktop, screenBinary } from "../src/screens/win-desktop.ts";
import { DesktopWinInput, KEYS, WinInput } from "../src/screens/win-input.ts";
import { fakeScreen } from "./desktop-screen-fakes.ts";

test("input as Windows posts it: buttons, a wheel in its units, keys by their scan code, modifiers pressed round a key", () => {
  const win = new WinInput();
  const at = (x: number, y: number, kind: "down" | "up" | "move", buttons: number) => ({ t: "pointer" as const, kind, x, y, buttons });
  assert.deepEqual(win.ops(at(0.5, 0.5, "down", 1)), [{ op: "mouse", type: "down", x: 0.5, y: 0.5, button: 0 }]);
  assert.deepEqual(win.ops(at(0.6, 0.5, "move", 1)), [{ op: "mouse", type: "move", x: 0.6, y: 0.5, button: 0 }]);
  assert.deepEqual(win.ops(at(0.6, 0.5, "up", 0)), [{ op: "mouse", type: "up", x: 0.6, y: 0.5, button: 0 }]);
  // The right button, then the middle one while it is held, and the right one let go.
  assert.equal((win.ops(at(0.2, 0.2, "down", 2))[0] as any).button, 2);
  assert.equal((win.ops(at(0.2, 0.2, "down", 6))[0] as any).button, 1);
  assert.equal((win.ops(at(0.2, 0.2, "up", 4))[0] as any).button, 2);
  // A page's notch (100 pixels down) is Windows' (120 up); a trackpad's small ones add up to whole units.
  assert.deepEqual(win.ops({ t: "wheel", x: 0.1, y: 0.9, dx: 0, dy: 100 }), [{ op: "wheel", x: 0.1, y: 0.9, dx: 0, dy: -120 }]);
  assert.deepEqual(win.ops({ t: "wheel", x: 0.1, y: 0.9, dx: 0.5, dy: 0 }), []);
  assert.deepEqual(win.ops({ t: "wheel", x: 0.1, y: 0.9, dx: 0.5, dy: 0 }), [{ op: "wheel", x: 0.1, y: 0.9, dx: 1, dy: 0 }]);
  // Ctrl+C as a keyboard gives it: Ctrl down first, so nothing pressed round C.
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "Control", code: "ControlLeft", mods: 2 }), [{ op: "key", scan: 0x1d, ext: false, vk: 0, down: true }]);
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "c", code: "KeyC", mods: 2 }), [{ op: "key", scan: KEYS.KeyC!.scan, ext: false, vk: 0, down: true }]);
  win.ops({ t: "key", kind: "up", key: "c", code: "KeyC", mods: 2 });
  win.ops({ t: "key", kind: "up", key: "Control", code: "ControlLeft", mods: 0 });
  // A phone's keys row (⌃ held for the next key, no Ctrl of its own): Ctrl and Shift pressed round it.
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "V", code: "KeyV", mods: 2 | 8 }), [
    { op: "key", scan: 0x1d, ext: false, vk: 0, down: true },
    { op: "key", scan: 0x2a, ext: false, vk: 0, down: true },
    { op: "key", scan: 0x2f, ext: false, vk: 0, down: true },
    { op: "key", scan: 0x2a, ext: false, vk: 0, down: false },
    { op: "key", scan: 0x1d, ext: false, vk: 0, down: false },
  ]);
  // E0 keys, and one Windows says by its virtual key.
  assert.deepEqual(win.ops({ t: "key", kind: "up", key: "ArrowUp", code: "ArrowUp", mods: 0 }), [{ op: "key", scan: 0x48, ext: true, vk: 0, down: false }]);
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "Meta", code: "MetaLeft", mods: 4 }), [{ op: "key", scan: 0x5b, ext: true, vk: 0, down: true }]);
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "Pause", code: "Pause", mods: 0 }), [{ op: "key", scan: 0, ext: false, vk: 0x13, down: true }]);
  // A key of no known place types what it says; not with ctrl or the Windows key, and not on its up.
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "é", code: "", mods: 8 }), [{ op: "text", text: "é" }]);
  assert.deepEqual(win.ops({ t: "key", kind: "up", key: "é", code: "", mods: 0 }), []);
  assert.deepEqual(win.ops({ t: "key", kind: "down", key: "é", code: "", mods: 2 }), []);
  assert.deepEqual(win.ops({ t: "text", text: "你好" }), [{ op: "text", text: "你好" }]);
});

test("Cue's wire input to a computer (mesh/screens.ts helperInput) as Windows posts it: a drag with the button held, the secondary button, a scroll, keys with modifiers", () => {
  const win = new DesktopWinInput();
  // A press, a move while it is held (a drag), the release; a point off the picture is its edge.
  assert.deepEqual(win.ops({ type: "down", x: 0.25, y: 0.5, button: 0, clicks: 1, mods: [] }), [{ op: "mouse", type: "down", x: 0.25, y: 0.5, button: 0 }]);
  assert.deepEqual(win.ops({ type: "move", x: 1.5, y: 0.5, mods: [] }), [{ op: "mouse", type: "move", x: 1, y: 0.5, button: 0 }]);
  assert.deepEqual(win.ops({ type: "up", x: 1, y: 0.5, button: 0, clicks: 1, mods: [] }), [{ op: "mouse", type: "up", x: 1, y: 0.5, button: 0 }]);
  // The wire's secondary button (1) is Windows' right one, its middle (2) the middle one.
  assert.equal((win.ops({ type: "down", x: 0.1, y: 0.1, button: 1, clicks: 1, mods: [] })[0] as any).button, 2);
  assert.equal((win.ops({ type: "up", x: 0.1, y: 0.1, button: 1, clicks: 1, mods: [] })[0] as any).button, 2);
  assert.equal((win.ops({ type: "down", x: 0.1, y: 0.1, button: 2, clicks: 1, mods: [] })[0] as any).button, 1);
  win.ops({ type: "up", x: 0.1, y: 0.1, button: 2, clicks: 1, mods: [] });
  // A page's scroll, in its pixels.
  assert.deepEqual(win.ops({ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 100, mods: [] }), [{ op: "wheel", x: 0.5, y: 0.5, dx: 0, dy: -120 }]);
  // ⇧ with a key the person did not press ⇧ for first: pressed round it.
  assert.deepEqual(win.ops({ type: "keydown", code: "KeyA", mods: ["shift"] }), [
    { op: "key", scan: 0x2a, ext: false, vk: 0, down: true },
    { op: "key", scan: 0x1e, ext: false, vk: 0, down: true },
    { op: "key", scan: 0x2a, ext: false, vk: 0, down: false },
  ]);
  assert.deepEqual(win.ops({ type: "keyup", code: "KeyA", mods: [] }), [{ op: "key", scan: 0x1e, ext: false, vk: 0, down: false }]);
  // What it does not know is nothing.
  assert.deepEqual(win.ops({ type: "keydown", code: "NotAKey", mods: [] }), []);
  assert.deepEqual(win.ops({ type: "stop" }), []);
  assert.deepEqual(win.ops({ type: "move", x: "far", y: 0 }), []);
});

test("Windows' desktop: a comma-desktop-screen process a view, asked for each frame, input as Windows posts it, the pointer it says; its size as it says", async () => {
  const fake = fakeScreen();
  const none = new WindowsDesktop({ binary: null });
  await assert.rejects(none.open({ maxWidth: 1920, maxHeight: 1080, codecs: ["h264"] }), (e: ScreenRefused) => e.status === 501 && e.key === "station.screen.noHelper");
  let changed = 0;
  const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", changed: () => changed++, start: fake.start, title: () => "PC" });
  assert.equal(desktop.id, "display");
  await desktop.refresh(true);
  assert.deepEqual(fake.started, [["status"]]);
  assert.deepEqual(desktop.size(), { width: 2560, height: 1600 });
  assert.equal(changed, 1);
  // Looked at a moment ago: not asked again.
  await desktop.refresh();
  assert.equal(fake.started.length, 1);
  await assert.rejects(desktop.open({ maxWidth: 1920, maxHeight: 1080, codecs: [] }), (e: ScreenRefused) => e.status === 415);
  const view = await desktop.open({ maxWidth: 1280, maxHeight: 800, codecs: ["h264"], bitrate: 2_000_000 });
  assert.deepEqual(fake.started.at(-1), ["view"]);
  assert.deepEqual(await view.next(), { key: true, ts: 1000, data: new Uint8Array([0, 0, 0, 1, 1]), config: { codec: "h264", width: 1280, height: 800, description: new Uint8Array([1, 66, 0, 31]) } });
  // The pointer it said (before that frame), told at once to who starts to hear it.
  const pointer: unknown[] = [];
  view.watchCursor!((cursor) => pointer.push(cursor));
  assert.deepEqual(pointer, [{ x: 0.5, y: 0.25, shape: "text" }]);
  await view.input({ type: "keydown", code: "KeyC", mods: [] });
  await view.input({ type: "down", x: 0.25, y: 0.5, button: 0, clicks: 1, mods: [] });
  view.rate!(3_000_000);
  // Its input is had before the next frame is answered (it reads in order).
  assert.deepEqual(await view.next(), { key: false, ts: 2000, data: new Uint8Array([0, 0, 0, 1, 2]) });
  assert.deepEqual(fake.lines(), [
    { codec: "h264", maxWidth: 1280, maxHeight: 800, bitrate: 2_000_000 },
    { op: "key", scan: 0x2e, ext: false, vk: 0, down: true },
    { op: "mouse", type: "down", x: 0.25, y: 0.5, button: 0 },
    { rate: 3_000_000 },
  ]);
  // Closed: a pending frame is none.
  const pending = view.next();
  view.close();
  assert.equal(await pending, null);
  // H.265 asked of it, where the client takes it: its config says what it made.
  const hevc = await desktop.open({ maxWidth: 1280, maxHeight: 800, codecs: ["h265", "h264"] });
  assert.equal(fake.lines().at(-1).codec, "h265");
  assert.equal((await hevc.next())?.config?.codec, "h265");
  hevc.close();
  // One that cannot capture says why.
  await assert.rejects(desktop.open({ maxWidth: 1, maxHeight: 1, codecs: ["h264"] }), (e: ScreenRefused) => e.status === 503 && /no display to capture/.test(e.message));
  await desktop.close();
  fake.done();
});

for (const stopped of ["", "the display went"]) {
  test(`Windows' desktop: a view whose process ends goes on in a new one, from its config, its pointer still heard; one that keeps ending ends (${stopped || "process loss"})`, async (t) => {
    const fake = fakeScreen(stopped);
    const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", start: fake.start });
    t.after(async () => { await desktop.close(); fake.done(); });
    const view = await desktop.open({ maxWidth: 2, maxHeight: 2, codecs: ["h264"] });
    let pointed = 0;
    view.watchCursor!(() => pointed++);
    const frames = [];
    for (let f = await view.next(); f !== null; f = await view.next()) frames.push(f);
    const views = fake.started.filter((args) => args[0] === "view").length;
    // Two frames a process: the first and three started again, each from its config and a key frame; then it ends.
    assert.equal(views, 4);
    assert.equal(frames.length, 8);
    assert.deepEqual(frames.map((f) => f.key), [true, false, true, false, true, false, true, false]);
    assert.ok(frames.filter((_, i) => i % 2 === 0).every((f) => f.config?.codec === "h264"));
    assert.equal(pointed, 4, "each process's pointer heard");
    // Ended: closed as a view the station closes is (nothing more started).
    view.close();
    assert.equal(await view.next(), null);
    assert.equal(fake.started.filter((args) => args[0] === "view").length, 4);
  });
}

// The real one, where it is built (a Windows machine with a display): an H.264 view of the main display, at its own size.
const realScreen = platform.hasWindowsScreen ? screenBinary() : null;
test("Windows' desktop, for real: comma-desktop-screen gives a picture of the display", { skip: realScreen === null }, async () => {
  const desktop = new WindowsDesktop({ binary: realScreen });
  await desktop.refresh(true);
  const { width, height } = desktop.size();
  assert.ok(width > 0 && height > 0);
  const view = await desktop.open({ maxWidth: width, maxHeight: height, codecs: ["h264"] });
  const first = (await view.next())!;
  assert.equal(first.key, true);
  assert.equal(first.config?.codec, "h264");
  assert.deepEqual([first.config!.width, first.config!.height], [width, height]);
  // A key frame asked for: the same picture again when the screen did not change.
  view.keyframe();
  assert.ok((await view.next())!.key);
  view.close();
  await desktop.close();
});
