// Starting an AVD: the program and the ports it is given, on a stand-in. Never a real emulator.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { avdsOf, emulatorPath, startEmulator } from "../src/screens/emulator.ts";

const started = () => {
  const calls: { program: string; args: string[]; port: string | undefined }[] = [];
  const child = new EventEmitter();
  return {
    calls,
    child,
    start: ((program: string, args: string[], options: { env: NodeJS.ProcessEnv }) => {
      calls.push({ program, args, port: options.env.ANDROID_ADB_SERVER_PORT });
      return child;
    }) as never,
  };
};

test("an AVD starts with no window, on the station's adb server, at the first console port nothing holds", async () => {
  const s = started();
  const taken = new Set([5554, 5557]);
  // (it takes its port as it starts)
  const id = await startEmulator({ emulator: "/sdk/emulator", avd: "Fold", env: { ANDROID_ADB_SERVER_PORT: "15233" }, free: async (port) => !taken.has(port), start: ((program: string, args: string[], options: never) => (taken.add(Number(args[3])), (s.start as (...a: unknown[]) => EventEmitter)(program, args, options))) as never });
  // 5556's adb port is held, so 5556 is passed over too.
  assert.equal(id, "android:emulator-5558");
  assert.deepEqual(s.calls[0], { program: "/sdk/emulator", args: ["-avd", "Fold", "-port", "5558", "-no-window", "-no-boot-anim", "-no-audio"], port: "15233" });
  // (its end gives the port back)
  s.child.emit("exit");
});

test("what is no AVD's name, or a machine with no port left, starts nothing, and its end is heard", async () => {
  const s = started();
  assert.equal(await startEmulator({ emulator: "/e", avd: "-writable-system", env: {}, free: async () => true, start: s.start }), null);
  assert.equal(await startEmulator({ emulator: "/e", avd: "a b", env: {}, free: async () => true, start: s.start }), null);
  assert.equal(await startEmulator({ emulator: "/e", avd: "Fold", env: {}, free: async () => false, start: s.start }), null);
  assert.deepEqual(s.calls, []);
  let ended = 0;
  // One that ends before it takes its port started nothing.
  const gone = startEmulator({ emulator: "/e", avd: "Fold", env: {}, ended: () => ended++, free: async () => true, start: ((...a: never[]) => {
    const child = (s.start as (...b: never[]) => EventEmitter)(...a);
    queueMicrotask(() => child.emit("exit"));
    return child;
  }) as never });
  assert.equal(await gone, null);
  assert.equal(ended, 1);
});

test("the AVDs are the names `-list-avds` says, and the emulator is found where Android Studio puts it", () => {
  assert.deepEqual(avdsOf("INFO    | Storing crashdata\nPixel_9\nFold-2\n"), ["Pixel_9", "Fold-2"]);
  assert.equal(emulatorPath(null, { PATH: "", HOME: "/nonexistent" }), null);
});

test("two AVDs started at once get a port each: the second chooses once the first has taken its own", async () => {
  const bound = new Set<number>();
  const children: EventEmitter[] = [];
  const start = ((_program: string, args: string[]) => {
    const child = new EventEmitter();
    children.push(child);
    // (an emulator binds its console as it starts)
    bound.add(Number(args[3]));
    return child;
  }) as never;
  const free = async (port: number) => !bound.has(port);
  const [pixel, fold] = await Promise.all([
    startEmulator({ emulator: "/e", avd: "Pixel", env: {}, free, start }),
    startEmulator({ emulator: "/e", avd: "Fold", env: {}, free, start }),
  ]);
  assert.deepEqual([pixel, fold], ["android:emulator-5554", "android:emulator-5556"]);
  // A port is the station's while its emulator runs, whatever the check of the machine says.
  bound.clear();
  assert.equal(await startEmulator({ emulator: "/e", avd: "Third", env: {}, free: async (port) => (port === 5558 && !bound.has(5558) ? (bound.add(5558), true) : !bound.has(port)), start }), "android:emulator-5558");
  for (const child of children) child.emit("exit");
});

test("an emulator that has not taken its port by the deadline is not the start's: it is stopped, and nothing is said started", async () => {
  let killed = 0;
  const start = (() => Object.assign(new EventEmitter(), { kill: () => (killed++, true) })) as never;
  assert.equal(await startEmulator({ emulator: "/e", avd: "Slow", env: {}, free: async () => true, start, bindMs: 0 }), null);
  assert.equal(killed, 1);
});

test("a start no longer allowed as it is about to begin starts nothing", async () => {
  const s = started();
  assert.equal(await startEmulator({ emulator: "/e", avd: "Fold", env: {}, free: async () => true, start: s.start, allowed: () => false }), null);
  assert.deepEqual(s.calls, []);
});
