// A simulator's debugging (screens/sim-debug.ts) with simctl played, after still.fail's station/test/sim-debug.test.ts:
// only an app a person installed started again, a setting only to what simctl takes, an app installed and started, a
// movie told which panel it is of and turned. side/screen-simulator-debug.test.ts has the real one.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type Recorder, SimDebug, appsOf, newestRunning, turnMovie, turnOf } from "../src/screens/sim-debug.ts";

const INSTALLED = JSON.stringify({ "com.apple.Preferences": { ApplicationType: "System", CFBundleDisplayName: "Settings" }, "fail.still.a": { ApplicationType: "User", CFBundleName: "Alpha" }, "fail.still.b": { ApplicationType: "User", CFBundleName: "Beta" } });

/// A device with two apps of a person's, its `launchctl` saying `running` and its recorder played.
function played(running = "", udid = "U", record?: Recorder) {
  const runs: string[][] = [];
  const debug = new SimDebug(
    "simctl",
    udid,
    async (file, args) => {
      runs.push([file, ...args]);
      if (file === "/bin/sh") return INSTALLED;
      if (args.includes("launchctl")) return running;
      if (args.join(" ") === `ui ${udid} appearance`) return "dark\n";
      return "";
    },
    async () => new Uint8Array(),
    record,
  );
  return { debug, runs };
}

test("the apps a person installed, those running first", () => {
  assert.deepEqual(appsOf(JSON.parse(INSTALLED), "1\t0\tUIKitApplication:fail.still.b[ff42][rb-legacy]\n"), [
    { id: "fail.still.b", name: "Beta", running: true },
    { id: "fail.still.a", name: "Alpha", running: false },
  ]);
});

test("the app started last is the one that shows, of those a person installed", () => {
  const apps = appsOf(JSON.parse(INSTALLED), "");
  const said = "812\t0\tUIKitApplication:fail.still.a[1][rb-legacy]\n903\t0\tUIKitApplication:fail.still.b[2][rb-legacy]\n999\t0\tUIKitApplication:com.apple.Preferences[3][rb-legacy]\n";
  assert.equal(newestRunning(apps, said)?.id, "fail.still.b");
  assert.equal(newestRunning(apps, ""), null);
});

test("restart ends and starts the running app; none running, nothing is started", async () => {
  const idle = played();
  assert.equal(await idle.debug.restart(), null);
  assert.ok(!idle.runs.some((r) => r.includes("launch")));
  const { debug, runs } = played("812\t0\tUIKitApplication:fail.still.a[1][rb-legacy]\n");
  assert.deepEqual(await debug.restart(), { app: "fail.still.a", name: "Alpha" });
  assert.deepEqual(runs.at(-1), ["simctl", "launch", "--terminate-running-process", "U", "fail.still.a"]);
});

test("light or dark is read from simctl and set by it", async () => {
  const { debug, runs } = played();
  assert.deepEqual(await debug.state(), { recording: false, appearance: "dark" });
  await debug.setAppearance("light");
  assert.deepEqual(runs.at(-1), ["simctl", "ui", "U", "appearance", "light"]);
});

test("an app installed and started, the file let go of; a file from elsewhere or of another type is not touched", async () => {
  const runs: string[][] = [];
  const debug = new SimDebug(
    "simctl",
    "U",
    async (file, args) => {
      runs.push([file, ...args]);
      if (file === "ditto") {
        const { mkdirSync } = await import("node:fs");
        mkdirSync(join(args.at(-1)!, "Payload", "Demo.app"), { recursive: true });
      }
      return file === "plutil" ? JSON.stringify({ CFBundleIdentifier: "fail.still.demo" }) : "";
    },
    async () => new Uint8Array(),
  );
  const folder = debug.installFolder();
  const elsewhere = mkdtempSync(join(tmpdir(), "elsewhere-"));
  assert.equal(await debug.install(join(elsewhere, "Demo.ipa")), null);
  const notes = join(folder, "notes.txt");
  writeFileSync(notes, "x");
  assert.equal(await debug.install(notes), null);
  rmSync(notes);
  assert.equal(runs.length, 0);
  const ipa = join(folder, `sim-debug-test-${process.pid}.ipa`);
  writeFileSync(ipa, "x");
  assert.deepEqual(await debug.install(ipa), { app: "fail.still.demo" });
  assert.deepEqual(runs[0]!.slice(0, 3), ["ditto", "-x", "-k"]);
  assert.deepEqual(runs[1]!.slice(0, 3), ["simctl", "install", "U"]);
  assert.match(runs[1]![3]!, /Payload\/Demo\.app$/);
  assert.deepEqual(runs.at(-1), ["simctl", "launch", "--terminate-running-process", "U", "fail.still.demo"]);
  assert.equal(existsSync(ipa), false);
  rmSync(elsewhere, { recursive: true });
});

/// A recorder that writes its movie and counts its stops.
function movies() {
  const asked: string[][] = [];
  let stopped = 0;
  const record: Recorder = (args) => {
    asked.push(args);
    writeFileSync(args.at(-1)!, "movie");
    return { started: Promise.resolve(), ended: Promise.resolve(), stop: () => void stopped++ };
  };
  return { asked, record, stops: () => stopped };
}

test("a recording: told which display a panel is, ended, its movie kept until the next", async () => {
  const m = movies();
  const { debug } = played("", "REC-A", m.record);
  assert.equal(await debug.recordStop(), null);
  await debug.recordStart("inner");
  assert.ok(m.asked[0]!.includes("--display=3"));
  assert.equal((await debug.state()).recording, true);
  await debug.recordStart("inner");
  assert.equal(m.asked.length, 1, "what goes on goes on");
  const first = (await debug.recordStop())!;
  assert.equal(m.stops(), 1);
  assert.equal(readFileSync(first.path, "utf8"), "movie");
  first.release?.();
  await debug.recordStart("cover");
  assert.ok(m.asked[1]!.includes("--display=1"));
  assert.equal(existsSync(first.path), false, "the last one's let go of");
  (await debug.recordStop())?.release?.();
  await debug.recordStart(null);
  assert.ok(!m.asked[2]!.some((a) => a.startsWith("--display")));
  (await debug.recordStop())?.release?.();
  await debug.close();
});

test("one device starting to record leaves another device's movie alone", async () => {
  const a = played("", "REC-B", movies().record);
  const b = played("", "REC-C", movies().record);
  await a.debug.recordStart(null);
  const movie = (await a.debug.recordStop())!;
  await b.debug.recordStart(null);
  assert.equal(existsSync(movie.path), true);
  await b.debug.recordStop();
});

test("a recording nothing came of says so", async () => {
  const record: Recorder = (args) => {
    writeFileSync(args.at(-1)!, "");
    return { started: Promise.resolve(), ended: Promise.resolve(), stop: () => {} };
  };
  const { debug } = played("", "REC-D", record);
  await debug.recordStart(null);
  await assert.rejects(debug.recordStop(), /nothing was recorded/);
});

test("a panel's turn as simctl says it, and a movie told it", async () => {
  const said = "Device Name: primary\n  UI Orientation: Portrait\nDevice Name: primary-1\n  UI Orientation: Landscape Left\n";
  assert.equal(turnOf(said, "primary"), 0);
  assert.equal(turnOf(said, "primary-1"), 1);
  const box = (kind: string, ...body: Buffer[]) => {
    const b = Buffer.concat(body);
    const h = Buffer.alloc(8);
    h.writeUInt32BE(b.length + 8, 0);
    h.write(kind, 4, "latin1");
    return Buffer.concat([h, b]);
  };
  const tkhd = Buffer.alloc(84);
  tkhd.writeUInt32BE(2006 * 0x10000, 76);
  tkhd.writeUInt32BE(2852 * 0x10000, 80);
  const hdlr = Buffer.alloc(24);
  hdlr.write("vide", 8, "latin1");
  const movie = Buffer.concat([box("ftyp", Buffer.alloc(8)), box("mdat", Buffer.alloc(16)), box("moov", box("mvhd", Buffer.alloc(100)), box("trak", box("tkhd", tkhd), box("mdia", box("hdlr", hdlr))))]);
  const dir = mkdtempSync(join(tmpdir(), "movie-"));
  const file = join(dir, "m.mp4");
  writeFileSync(file, movie);
  assert.equal(await turnMovie(file, 1), true);
  const out = readFileSync(file);
  const at = out.indexOf("tkhd") + 4 + 40;
  assert.deepEqual([out.readInt32BE(at), out.readInt32BE(at + 4), out.readInt32BE(at + 12), out.readInt32BE(at + 16), out.readInt32BE(at + 24), out.readInt32BE(at + 28), out.readInt32BE(at + 32)], [0, 0x10000, -0x10000, 0, 2852 * 0x10000, 0, 0x40000000]);
  writeFileSync(file, "");
  assert.equal(await turnMovie(file, 0), false, "nothing recorded");
  rmSync(dir, { recursive: true });
});


test("concurrent starts spawn one recorder and close removes the completed movie", async () => {
  const m = movies();
  const { debug } = played("", "REC-SERIAL", m.record);
  await Promise.all([debug.recordStart(null), debug.recordStart(null)]);
  assert.equal(m.asked.length, 1);
  const movie = (await debug.recordStop())!;
  movie.release?.();
  await debug.close();
  assert.equal(existsSync(movie.path), false);
});

test("close fences a start awaiting the panel and no recorder survives it", async () => {
  let proceed!: () => void;
  let arrived!: () => void;
  const held = new Promise<void>((done) => { proceed = done; });
  const enumerating = new Promise<void>((done) => { arrived = done; });
  const m = movies();
  const debug = new SimDebug("simctl", "REC-CLOSE", async () => { arrived(); await held; return ""; }, async () => new Uint8Array(), m.record);
  const start = debug.recordStart("inner");
  await enumerating;
  const closed = debug.close();
  proceed();
  await Promise.all([start, closed]);
  assert.equal(m.asked.length, 0);
});

test("a movie stays readable through the next recording and close until its download releases it", async () => {
  const { debug } = played("", "REC-DOWNLOAD", movies().record);
  await debug.recordStart(null);
  const movie = (await debug.recordStop())!;
  await debug.recordStart(null);
  (await debug.recordStop())?.release?.();
  await debug.close();
  assert.equal(readFileSync(movie.path, "utf8"), "movie");
  await movie.release?.();
  assert.equal(existsSync(movie.path), false);
});


test("device removal removes a stopped movie after its download has finished", async () => {
  const { debug } = played("", "REC-REMOVE", movies().record);
  await debug.recordStart(null);
  const movie = (await debug.recordStop())!;
  await movie.release?.();
  assert.equal(existsSync(movie.path), true);
  await debug.close();
  assert.equal(existsSync(movie.path), false);
});
