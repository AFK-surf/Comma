import { afterEach, expect, it } from "vitest";
import { uiClock } from "../../clock";
import { declareUiModule, uiRuntime } from "../index";
import { createTestUiRuntime, type TestUiRuntime } from "./testing";

// The test UI runtime owns time, order, randomness, storage and loading: what
// UI code observes through them depends only on the code and the seed.

let uninstall: (() => void) | undefined;
afterEach(() => {
  uninstall?.();
  uninstall = undefined;
});

const start = (seed = 1): TestUiRuntime => {
  const runtime = createTestUiRuntime({ seed, frameMs: 16 });
  uninstall = runtime.install();
  return runtime;
};

it("runs timers only as time advances, at their due time, in the order they were set", async () => {
  const runtime = start();
  const log: string[] = [];
  // ast-grep-ignore: ts-test-timer, ts-test-clock -- routed to the test runtime (installTestUiHost): page time, not real time.
  setTimeout(() => log.push(`a ${performance.now()}`), 30);
  // ast-grep-ignore: ts-test-timer, ts-test-clock -- routed to the test runtime (installTestUiHost): page time, not real time.
  setTimeout(() => log.push(`b ${performance.now()}`), 10);
  uiClock.after(30, () => log.push(`c ${uiClock.monotonic()}`));
  // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
  const interval = setInterval(
    // ast-grep-ignore: ts-test-clock -- the test runtime's clock (installTestUiHost).
    () => log.push(`i ${Date.now() - Date.UTC(2026, 0, 15, 12)}`),
    20
  );
  expect(log).toEqual([]);
  await runtime.advance(9);
  expect(log).toEqual([]);
  await runtime.advance(41);
  clearInterval(interval);
  await runtime.advance(100);
  expect(log).toEqual(["b 10", "i 20", "a 30", "c 30", "i 40"]);
  expect(runtime.elapsed()).toBe(150);
});

it("tells when its next timer or frame is due", async () => {
  const runtime = start();
  expect(runtime.nextDue()).toBeNull();
  uiClock.after(40, () => {});
  expect(runtime.nextDue()).toBe(40);
  await runtime.advance(5);
  uiClock.frame(() => {});
  expect(runtime.nextDue()).toBe(16);
  await runtime.advance(40);
  expect(runtime.nextDue()).toBeNull();
});

it("runs frame callbacks on multiples of the frame, with the frame's time", async () => {
  const runtime = start();
  const frames: number[] = [];
  await runtime.advance(5);
  // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
  requestAnimationFrame((time) => {
    frames.push(time);
    // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
    requestAnimationFrame((next) => frames.push(next));
  });
  await runtime.advance(40);
  expect(frames).toEqual([16, 32]);
});

it("draws random values and ids from its seed", () => {
  const draw = (seed: number) => {
    const runtime = start(seed);
    const values = [
      // ast-grep-ignore: ts-test-random -- the test runtime's seeded values (installTestUiHost).
      Math.random(),
      uiRuntime.random.next(),
      // ast-grep-ignore: ts-test-random -- the test runtime's seeded values (installTestUiHost).
      crypto.randomUUID(),
      // ast-grep-ignore: ts-test-random -- the test runtime's seeded values (installTestUiHost).
      [...crypto.getRandomValues(new Uint8Array(8))].join(","),
    ];
    uninstall?.();
    uninstall = undefined;
    expect(runtime.seed).toBe(seed);
    return values;
  };
  expect(draw(7)).toEqual(draw(7));
  expect(draw(7)).not.toEqual(draw(8));
  expect(draw(7)[2]).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  );
});

it("keeps storage in memory, empty for each runtime", () => {
  start();
  localStorage.setItem("key", "value");
  expect(uiRuntime.storage.local().getItem("key")).toBe("value");
  uninstall?.();
  start();
  expect(localStorage.getItem("key")).toBeNull();
});

it("delivers work in the order it started, before time moves on", async () => {
  const runtime = start();
  const order: string[] = [];
  let finishFirst!: (value: string) => void;
  const first = new Promise<string>((resolve) => (finishFirst = resolve));
  void uiRuntime.load.work("first", () => first).then((value) => order.push(value));
  void uiRuntime.load
    .work("second", () => Promise.resolve("second"))
    .then((value) => order.push(value));
  // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
  setTimeout(() => order.push("timer"), 1);
  expect(runtime.pendingWork()).toEqual(["first", "second"]);
  finishFirst("first");
  await runtime.advance(1);
  expect(order).toEqual(["first", "second", "timer"]);
});

it("runs a message between two ports of the page as a task, in the order posted", async () => {
  const runtime = start();
  const order: string[] = [];
  const channel = new MessageChannel();
  channel.port1.addEventListener("message", (event) =>
    order.push(`message ${String(event.data)}`)
  );
  channel.port1.start();
  // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
  setTimeout(() => order.push("timer"), 0);
  channel.port2.postMessage("a");
  channel.port2.postMessage("b");
  expect(order).toEqual([]);
  await runtime.flush();
  expect(order).toEqual(["message a", "message b", "timer"]);
  channel.port1.close();
});

it("delivers a WebAssembly module's compile as work", async () => {
  const runtime = start();
  let compiled = false;
  // The empty module: its header alone.
  void WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])).then(() => {
    compiled = true;
  });
  expect(runtime.pendingWork()).toEqual(["wasm compile"]);
  await runtime.advance(1);
  expect(compiled).toBe(true);
  expect(runtime.pendingWork()).toEqual([]);
});

it("loads declared modules before a fixture renders; a load while the test runs is a violation", async () => {
  const runtime = start();
  const declared = declareUiModule("declared", async () => ({ name: "declared" }));
  await runtime.prepare();
  expect(declared.ready()).toEqual({ name: "declared" });
  expect(runtime.violations()).toEqual([]);
  await uiRuntime.load.module("late", async () => "late");
  expect(runtime.violations()).toEqual(["0ms: load late while the test runs"]);
});

it("refuses requests while it runs", async () => {
  const runtime = start();
  await expect(fetch("https://example.test/data")).rejects.toThrow(
    "A UI test runtime allows no requests"
  );
  expect(runtime.violations()).toEqual(["0ms: fetch https://example.test/data"]);
});

it("clamps a timeout nested more than five deep to 4 ms, as a browser does", async () => {
  const runtime = start();
  const at: number[] = [];
  const loop = () => {
    at.push(runtime.elapsed());
    // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
    if (at.length < 8) setTimeout(loop, 0);
  };
  // ast-grep-ignore: ts-test-timer -- routed to the test runtime (installTestUiHost): page time, not real time.
  setTimeout(loop, 0);
  await runtime.advance(20);
  expect(at).toEqual([0, 0, 0, 0, 0, 4, 8, 12]);
});
