// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 9967fe35be) station/src/screens/linux-session.ts as it is there.
//
// A station can start before its user's desktop and inherit an old DISPLAY. Look up that same user's active
// graphical session when logind is available; never borrow another user's session or X11 credentials.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
type Session = { id: string; uid: number; type: "x11" | "wayland"; active: boolean; remote: boolean; display?: string };

function fields(text: string): Record<string, string> {
  return Object.fromEntries(text.split("\n").flatMap((line) => {
    const equal = line.indexOf("=");
    return equal > 0 ? [[line.slice(0, equal), line.slice(equal + 1)]] : [];
  }));
}

export function graphicalSession(id: string, uid: number, text: string): Session | null {
  const properties = fields(text);
  if (Number(properties.User) !== uid || properties.Class !== "user" || (properties.Type !== "x11" && properties.Type !== "wayland")) return null;
  return { id, uid, type: properties.Type, active: properties.Active === "yes", remote: properties.Remote === "yes", display: properties.Display || undefined };
}

/// The program environment selected by logind. The caller can still use an explicitly started Xvfb or a host without
/// logind: in either case a lack of an active graphical session leaves its inherited environment intact.
export async function desktopEnvironment(base: NodeJS.ProcessEnv = process.env): Promise<NodeJS.ProcessEnv> {
  const uid = process.getuid?.();
  if (uid === undefined) return { ...base };
  try {
    const list = await run("loginctl", ["list-sessions", "--no-legend", "--no-pager"], { env: base, timeout: 2_000, maxBuffer: 256_000 });
    const ids = list.stdout.split("\n").flatMap((line) => {
      const match = /^\s*(\S+)\s+(\d+)\s+/.exec(line);
      return match && Number(match[2]) === uid ? [match[1]!] : [];
    }).slice(0, 20);
    const sessions = (await Promise.all(ids.map(async (id) => {
      try {
        const result = await run("loginctl", ["show-session", id, "--no-pager", "--property=User,Type,Class,Active,Remote,Display"], { env: base, timeout: 2_000 });
        return graphicalSession(id, uid, result.stdout);
      } catch { return null; }
    }))).filter((session): session is Session => session !== null && session.active);
    sessions.sort((a, b) => Number(a.remote) - Number(b.remote));
    const session = sessions[0];
    if (!session) return { ...base };

    const env: NodeJS.ProcessEnv = { ...base, XDG_SESSION_TYPE: session.type };
    const runtime = `/run/user/${uid}`;
    if (existsSync(join(runtime, "bus"))) {
      env.XDG_RUNTIME_DIR = runtime;
      env.DBUS_SESSION_BUS_ADDRESS = `unix:path=${join(runtime, "bus")}`;
    }
    if (session.type === "wayland") {
      // The portal backend uses the desktop activation environment, not the station's inherited Wayland socket.
      delete env.DISPLAY;
      delete env.XAUTHORITY;
      try {
        const activation = await run("systemctl", ["--user", "show-environment"], { env, timeout: 2_000, maxBuffer: 256_000 });
        const values = fields(activation.stdout);
        if (values.WAYLAND_DISPLAY) env.WAYLAND_DISPLAY = values.WAYLAND_DISPLAY;
      } catch { /* The portal can still use the user's D-Bus session without a Wayland socket here. */ }
      env.WAYLAND_DISPLAY ||= "wayland-0";
      return env;
    }
    delete env.WAYLAND_DISPLAY;
    // GNOME normally exports these into the user's systemd activation environment after login.
    try {
      const activation = await run("systemctl", ["--user", "show-environment"], { env, timeout: 2_000, maxBuffer: 256_000 });
      const values = fields(activation.stdout);
      if (values.DISPLAY && (!session.display || values.DISPLAY === session.display)) {
        if (env.DISPLAY !== values.DISPLAY) delete env.XAUTHORITY;
        env.DISPLAY = values.DISPLAY;
        if (values.XAUTHORITY) env.XAUTHORITY = values.XAUTHORITY;
      } else if (session.display && env.DISPLAY !== session.display) {
        env.DISPLAY = session.display;
        delete env.XAUTHORITY;
      }
    } catch {
      if (session.display && env.DISPLAY !== session.display) {
        env.DISPLAY = session.display;
        delete env.XAUTHORITY;
      }
    }
    if (!env.XAUTHORITY) {
      for (const candidate of [join(runtime, "gdm/Xauthority"), base.HOME && join(base.HOME, ".Xauthority")]) {
        if (candidate && existsSync(candidate)) { env.XAUTHORITY = candidate; break; }
      }
    }
    return env;
  } catch { return { ...base }; }
}
