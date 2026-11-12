// The X11 desktop source (screens/x11-desktop.ts, x11-h264.ts). Ported from still.fail's station/test/x11-desktop.test.ts
// (the reasons), x11-h264.test.ts (rate changes, key frames, the JPEG fallback) and x11-desktop-lifecycle.test.ts. The
// tests marked so run only with COMMA_TEST_X11=1, on a real, disposable X server (never a person's desktop): `DISPLAY`
// names it, and ffmpeg (with libx264), xdotool, xev, xauth and Xvfb are on the PATH. Where still.fail's waited real
// time (a sleep past the encoder's restart pacing, a deadline on a read), these move the encoder's clock or wait on the
// thing itself; the test runner's timeout is the only bound.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { ScreenRefused } from "../src/screens/hub.ts";
import { X11Desktop } from "../src/screens/x11-desktop.ts";

const run = promisify(execFile);
const realX11 = process.env.COMMA_TEST_X11 === "1";

/// Asks until `check` passes; each ask waits on a process or the X server, nothing else.
async function until(check: () => Promise<boolean>) {
  while (!(await check())) await run(process.execPath, ["-e", ""]);
}

/// An X client kept connected: Xvfb resets its root window when its last client goes.
async function observer(env: NodeJS.ProcessEnv) {
  const xev = spawn("xev", ["-event", "keyboard"], { env, stdio: "ignore" });
  await run("xdotool", ["search", "--sync", "--name", "Event Tester"], { env });
  return xev;
}

test("a Linux desktop says why when it cannot reach an X11 session", async () => {
  const env: NodeJS.ProcessEnv = {};
  const desktop = new X11Desktop({ env, changed: () => {} });
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxNoDisplay");
  env.DISPLAY = ":99";
  env.WAYLAND_DISPLAY = "wayland-0";
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxWayland");
  delete env.WAYLAND_DISPLAY;
  env.PATH = "";
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxTools");
  await assert.rejects(desktop.open({ maxWidth: 640, maxHeight: 480, codecs: ["h264"] }), (e: unknown) => e instanceof ScreenRefused && e.status === 503 && /ffmpeg with X11 support and xdotool/.test(e.message));
});

test("H.264 rate changes restart the encoder as paced, a key frame at once; an encoder that cannot start leaves JPEG", { skip: !realX11 }, async (t) => {
  const env = { ...process.env };
  const xev = await observer(env);
  t.after(() => xev.kill());
  let now = 0;
  const desktop = new X11Desktop({ env, changed: () => {}, now: () => now });
  const view = await desktop.open({ maxWidth: 640, maxHeight: 400, codecs: ["h264", "jpeg"], bitrate: 1_500_000 });
  try {
    const first = await view.next();
    assert.equal(first?.config?.codec, "h264");
    assert.equal(first?.key, true);
    const second = await view.next();
    assert.equal(second?.key, false);
    now += 1_600;
    view.rate!(400_000);
    const changed = await view.next();
    assert.equal(changed?.config?.codec, "h264");
    assert.equal(changed?.key, true);
    // A brief rise does not restart it; one that lasts does; a key frame asked passes the pacing.
    view.rate!(1_500_000);
    now += 1_600;
    const steady = await view.next();
    assert.equal(steady?.config, undefined);
    assert.equal(steady?.key, false);
    now += 3_100;
    const faster = await view.next();
    assert.equal(faster?.config?.codec, "h264");
    assert.equal(faster?.key, true);
    view.keyframe();
    const key = await view.next();
    assert.equal(key?.config?.codec, "h264");
    assert.equal(key?.key, true);
  } finally {
    view.close();
    await desktop.close();
  }

  // An ffmpeg that says libx264 but cannot start it leaves a client that takes JPEG able to watch.
  const dir = mkdtempSync(join(tmpdir(), "comma-x11-encoder-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const fake = join(dir, "ffmpeg");
  const real = (await run("which", ["ffmpeg"], { env })).stdout.trim();
  writeFileSync(fake, `#!/bin/sh\ncase " $* " in\n  *" -encoders "*) echo ' V..... libx264'; exit 0;;\n  *" -c:v libx264 "*) exit 1;;\nesac\nexec "${real}" "$@"\n`);
  chmodSync(fake, 0o755);
  const fallback = new X11Desktop({ env, ffmpeg: fake, changed: () => {} });
  try {
    const jpeg = await fallback.open({ maxWidth: 640, maxHeight: 400, codecs: ["h264", "jpeg"] });
    try {
      assert.equal((await jpeg.next())?.config?.codec, "jpeg");
    } finally {
      jpeg.close();
    }
  } finally {
    await fallback.close();
  }
});

test("repeated X11 views close their capture processes and release pending reads", { skip: !realX11 }, async (t) => {
  const env = { ...process.env };
  const xev = await observer(env);
  t.after(() => xev.kill());
  const desktop = new X11Desktop({ env, changed: () => {} });
  const initial = process.memoryUsage().rss;
  let peak = initial;
  try {
    for (const codec of ["jpeg", "h264"] as const) {
      for (let i = 0; i < 20; i++) {
        const view = await desktop.open({ maxWidth: 640, maxHeight: 400, codecs: [codec] });
        const first = await view.next();
        assert.ok(first && first.config?.codec === codec && first.data.length > 100);
        const pending = view.next();
        view.close();
        await pending; // It had a new frame already, or close resolves it.
        assert.equal(await view.next(), null);
        view.close(); // Closing twice does nothing.
        peak = Math.max(peak, process.memoryUsage().rss);
      }
    }
    await desktop.close();
    await until(async () => !(await run("ps", ["-o", "comm=", "--ppid", String(process.pid)], { env })).stdout.split("\n").some((line) => line.trim() === "ffmpeg"));
    const growth = (peak - initial) / (1024 * 1024);
    assert.ok(growth < 256, `unexpected RSS growth: ${growth.toFixed(1)} MiB`);
  } finally {
    await desktop.close();
  }
});

test("an X server that exits ends JPEG and H.264 views and is said unreachable", { skip: !realX11 }, async () => {
  for (const [i, codec] of (["jpeg", "h264"] as const).entries()) {
    const dir = mkdtempSync(join(tmpdir(), "comma-x11-failure-"));
    const auth = join(dir, "Xauthority");
    const display = `:${196 + i}`;
    const env: NodeJS.ProcessEnv = { ...process.env, DISPLAY: display, XAUTHORITY: auth, XDG_SESSION_TYPE: "x11" };
    delete env.WAYLAND_DISPLAY;
    await run("xauth", ["-f", auth, "add", display, ".", "0123456789abcdef0123456789abcdef"], { env });
    const server = spawn("Xvfb", [display, "-auth", auth, "-nolisten", "tcp", "-noreset", "-screen", "0", "640x480x24"], { env, stdio: "ignore" });
    const desktop = new X11Desktop({ env, changed: () => {} });
    try {
      await until(async () => {
        if (server.exitCode !== null) throw new Error("the disposable X server did not start");
        return run("xdotool", ["getdisplaygeometry"], { env }).then(() => true, () => false);
      });
      const view = await desktop.open({ maxWidth: 640, maxHeight: 480, codecs: [codec] });
      assert.equal((await view.next())?.config?.codec, codec);
      server.kill("SIGTERM");
      // A lost X server ends the view: no read is left waiting.
      while ((await view.next()) !== null);
      await desktop.refresh(true);
      assert.equal(desktop.access().reason, "linuxUnavailable");
      view.close();
    } finally {
      server.kill("SIGTERM");
      await desktop.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }
});
