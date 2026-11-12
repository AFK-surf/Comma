// Which desktop a Linux station shows (screens/linux-session.ts, linux-desktop.ts): only its own user's active graphical
// session, never another user's or their X11 credentials. Ported from still.fail's station/test/linux-portal.test.ts
// (its logind tests); the desktop's switching test keeps its X11 path, as linux-desktop.ts does.
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { LinuxDesktop } from "../src/screens/linux-desktop.ts";
import { desktopEnvironment, graphicalSession } from "../src/screens/linux-session.ts";
import { fakeX11Tools } from "./linux-screen-fakes.ts";

test("logind discovery accepts only the station user's graphical sessions", () => {
  const info = "User=1000\nType=wayland\nClass=user\nActive=yes\nRemote=no\nDisplay=\n";
  assert.deepEqual(graphicalSession("7", 1000, info), { id: "7", uid: 1000, type: "wayland", active: true, remote: false, display: undefined });
  assert.equal(graphicalSession("7", 1001, info), null);
  assert.equal(graphicalSession("7", 1000, info.replace("Class=user", "Class=greeter")), null);
  assert.equal(graphicalSession("7", 1000, info.replace("Type=wayland", "Type=tty")), null);
});

test("a station started outside the desktop uses the active session's environment", { skip: !process.getuid }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "comma-session-env-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const uid = process.getuid!();
  const loginctl = join(dir, "loginctl"), systemctl = join(dir, "systemctl");
  const session = (type: string, display: string) => writeFile(loginctl, `#!/bin/sh\nif [ "$1" = list-sessions ]; then\n  printf '7 ${uid} test seat0 tty2\\n'\nelse\n  printf 'User=${uid}\\nType=${type}\\nClass=user\\nActive=yes\\nRemote=no\\nDisplay=${display}\\n'\nfi\n`, { mode: 0o755 });
  const base = { ...process.env, PATH: dir, HOME: dir, DISPLAY: ":old", XAUTHORITY: "/stale-auth", WAYLAND_DISPLAY: "wayland-old" };
  await Promise.all([session("wayland", ""), writeFile(systemctl, "#!/bin/sh\nprintf 'WAYLAND_DISPLAY=wayland-9\\n'\n", { mode: 0o755 })]);
  const wayland = await desktopEnvironment(base);
  assert.equal(wayland.WAYLAND_DISPLAY, "wayland-9");
  assert.equal(wayland.DISPLAY, undefined);
  assert.equal(wayland.XAUTHORITY, undefined);
  await Promise.all([session("x11", ":9"), writeFile(systemctl, "#!/bin/sh\nprintf 'DISPLAY=:9\\n'\n", { mode: 0o755 })]);
  const x11 = await desktopEnvironment(base);
  assert.equal(x11.DISPLAY, ":9");
  assert.notEqual(x11.XAUTHORITY, "/stale-auth");
  assert.equal(x11.WAYLAND_DISPLAY, undefined);
  // Another user's active session is not this station's: its inherited environment stays as it was.
  await writeFile(loginctl, `#!/bin/sh\nif [ "$1" = list-sessions ]; then\n  printf '8 ${uid + 1} other seat0 tty3\\n'\nelse\n  printf 'User=${uid + 1}\\nType=x11\\nClass=user\\nActive=yes\\nRemote=no\\nDisplay=:7\\n'\nfi\n`, { mode: 0o755 });
  const other = await desktopEnvironment(base);
  assert.deepEqual([other.DISPLAY, other.XAUTHORITY], [":old", "/stale-auth"]);
});

test("the Linux desktop follows the discovered session: a Wayland one is said so, an X11 one is shown", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "comma-desktop-session-"));
  const fake = fakeX11Tools();
  let env: NodeJS.ProcessEnv = { XDG_SESSION_TYPE: "wayland", WAYLAND_DISPLAY: "wayland-0" };
  const desktop = new LinuxDesktop({ data: dir, env: {}, title: () => "test-station", discover: async () => env });
  t.after(async () => {
    await desktop.close();
    fake.done();
    await rm(dir, { recursive: true, force: true });
  });
  assert.equal(desktop.title(), "test-station");
  assert.equal(desktop.id, "display");
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxWayland");
  env = { XDG_SESSION_TYPE: "x11" };
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxNoDisplay");
  env = fake.env;
  await desktop.refresh(true);
  assert.deepEqual([desktop.access().capture, desktop.size()], [true, { width: 1280, height: 800 }]);
});
