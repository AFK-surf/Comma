// An Android emulator's debugging (screens/android-debug.ts) with adb played: only an app a person installed and that
// shows is started again, and what its Android cannot do is not listed.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { existsSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { AndroidDebug, androidDebugActions } from "../src/screens/android-debug.ts";

function played(say: (args: string[]) => string = () => "") {
  const runs: string[][] = [];
  const shells: { command: string; child: EventEmitter & { kill(signal?: string): boolean } }[] = [];
  const adb = {
    run: async (args: string[]) => (runs.push(args), say(args)),
    long: async (args: string[]) => {
      runs.push(args);
      if (args[0] === "pull") writeFileSync(args[2]!, "movie");
      return "";
    },
    bytes: async (args: string[]) => (runs.push(args), Buffer.from("png")),
    shell: (command: string) => {
      const child = Object.assign(new EventEmitter(), { kill: () => true });
      shells.push({ command, child });
      return child as never;
    },
  };
  return { debug: new AndroidDebug(adb, 34, "t"), runs, shells };
}

test("an emulator lists light and dark only where its Android has them", () => {
  assert.ok(androidDebugActions(29).includes("appearance"));
  assert.ok(!androidDebugActions(28).includes("appearance"));
  assert.ok(!androidDebugActions(0).includes("appearance"));
  assert.deepEqual(androidDebugActions(28), ["restart", "screenshot", "record", "install"]);
});

const SHOWS = (app: string, installed: string) => (args: string[]) => (args[1]?.includes("dumpsys") ? `${app}\n1234\n` : args[1]?.startsWith("pm list") ? installed : "");

test("restart: the app that shows, if a person installed it; the launcher is left alone", async () => {
  const launcher = played(SHOWS("com.google.android.apps.nexuslauncher", "package:fail.still.a\n"));
  assert.equal(await launcher.debug.restart(), null);
  assert.ok(!launcher.runs.some((r) => r[1]?.includes("force-stop")));
  const { debug, runs } = played(SHOWS("fail.still.a", "package:fail.still.a\r\npackage:fail.still.b\r\n"));
  assert.deepEqual(await debug.restart(), { app: "fail.still.a", name: "fail.still.a" });
  assert.deepEqual(runs.at(-1), ["shell", "am force-stop fail.still.a; monkey -p fail.still.a -c android.intent.category.LAUNCHER 1"]);
});

test("light or dark, as `cmd uimode` says and takes it", async () => {
  const { debug, runs } = played((args) => (args[1] === "cmd uimode night" ? "Night mode: yes\n" : ""));
  assert.deepEqual(await debug.state(), { recording: false, appearance: "dark" });
  await debug.setAppearance("light");
  assert.deepEqual(runs.at(-1), ["shell", "cmd uimode night no"]);
});

test("an .apk installed over what is there, the file let go of; another file is not", async () => {
  const { debug, runs } = played();
  const apk = join(debug.installFolder(), `android-debug-test-${process.pid}.apk`);
  writeFileSync(apk, "x");
  assert.deepEqual(await debug.install(apk), {});
  assert.deepEqual(runs.at(-1), ["install", "-r", "-t", apk]);
  assert.equal(existsSync(apk), false);
  assert.equal(await debug.install(join(dirname(apk), "x.ipa")), null);
  assert.equal(await debug.install("/elsewhere/x.apk"), null);
  assert.equal(runs.length, 1);
});

test("a recording: ended whole on the device, fetched, and taken off it", async () => {
  // (the device's `screenrecord` ends once it is told to)
  const { debug, runs, shells } = played((args) => {
    if (args[1]?.includes('kill -INT "$p"')) queueMicrotask(() => shells[0]!.child.emit("close"));
    return "";
  });
  assert.equal(await debug.recordStop(), null);
  await debug.recordStart();
  await debug.recordStart();
  assert.equal(shells.length, 1, "what goes on goes on");
  assert.match(shells[0]!.command, /^screenrecord --time-limit 180 \/data\/local\/tmp\/comma-t-[0-9a-f]+\.mp4 & p=/);
  assert.equal((await debug.state()).recording, true);
  const remote = shells[0]!.command.split(" ")[3]!;
  const movie = (await debug.recordStop())!;
  assert.ok(existsSync(movie.path));
  assert.ok(runs.some((r) => r[1]?.includes(`cat ${remote}.pid`)));
  assert.ok(!runs.some((r) => r[1]?.includes("pkill")));
  assert.deepEqual(runs.slice(-2), [["pull", remote, movie.path], ["shell", `rm -f ${remote} ${remote}.pid`]]);
  await movie.release?.();
  await debug.close();
  assert.equal(existsSync(movie.path), false);
});

test("a screenshot is screencap's PNG", async () => {
  const { debug, runs } = played();
  assert.equal((await debug.screenshot()).toString(), "png");
  assert.deepEqual(runs.at(-1), ["exec-out", "screencap", "-p"]);
});


test("close signals the remote recorder, not just the local adb process", async () => {
  const { debug, runs, shells } = played((args) => {
    if (args[1]?.includes('kill -INT "$p"')) queueMicrotask(() => shells[0]!.child.emit("close"));
    return "";
  });
  await debug.recordStart();
  const remote = shells[0]!.command.split(" ")[3]!;
  await debug.close();
  assert.ok(runs.some((r) => r[1]?.includes(`cat ${remote}.pid`)));
  assert.deepEqual(runs.at(-1), ["shell", `rm -f ${remote} ${remote}.pid`]);
  await assert.rejects(debug.recordStart(), /closed/);
});
