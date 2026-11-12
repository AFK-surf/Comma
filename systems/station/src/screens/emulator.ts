// The Android Virtual Devices a machine can start, for a person who picks one in a screen's list. Asked only when a person
// looks. An emulator started here has no window of its own (it is shown through a view) and outlives the station, as one a
// person starts by hand does.
import { type ChildProcess, execFile } from "node:child_process";
import { existsSync } from "node:fs";
import net from "node:net";
import { delimiter, dirname, join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { startLasting } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";

const ASK_TIMEOUT = 15_000;
/// The console ports an emulator may take, each with the adb port above it: so its serial is known before it boots.
const FIRST_PORT = 5554;
const LAST_PORT = 5584;
export const AVD_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

/// The Android emulator program: on the PATH, in the SDK, beside the `platform-tools` adb is in, or where Android Studio puts it.
export function emulatorPath(adb: string | null, env: NodeJS.ProcessEnv = process.env): string | null {
  const exe = platform.exe("emulator");
  const candidates = [
    ...(env.PATH ?? "").split(delimiter).filter(Boolean).map((d) => join(d, exe)),
    ...[env.ANDROID_HOME, env.ANDROID_SDK_ROOT].filter((d): d is string => !!d).map((d) => join(d, "emulator", exe)),
    ...(adb ? [join(dirname(dirname(adb)), "emulator", exe)] : []),
    // Where Android Studio puts the SDK, wherever adb itself came from (Homebrew's has no emulator beside it).
    ...(env.HOME ? [join(env.HOME, "Library/Android/sdk/emulator", exe), join(env.HOME, "Android/Sdk/emulator", exe)] : []),
    ...(env.LOCALAPPDATA ? [join(env.LOCALAPPDATA, "Android", "Sdk", "emulator", exe)] : []),
  ];
  return candidates.find((p) => existsSync(p)) ?? null;
}

/// The AVDs `emulator -list-avds` names: nothing but names (it says other things on a line of its own, "INFO | ...").
export function avdsOf(said: string): string[] {
  return said.split("\n").map((l) => l.trim()).filter((l) => AVD_NAME.test(l));
}

/// The AVDs a machine could start; none where it has no emulator.
export function avdsOn(emulator: string | null): Promise<string[]> {
  if (emulator === null) return Promise.resolve([]);
  return new Promise((resolve) => {
    const child = execFile(emulator, ["-list-avds"], { windowsHide: true, maxBuffer: 1024 * 1024 }, (error, out) => (stop(), resolve(error ? [] : avdsOf(out))));
    const stop = wall.after(ASK_TIMEOUT, () => void child.kill("SIGKILL"));
  });
}

const portFree = (port: number) =>
  new Promise<boolean>((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)));
  });

/// How long a started emulator has to take its console port: until then the port is held here, so no other start takes it.
const BIND_MS = 30_000;
/// The console ports of emulators started here and still running (or not yet bound).
const held = new Set<number>();
/// One start at a time: a port is chosen, the emulator started and its port seen taken before the next start chooses.
let starting: Promise<unknown> = Promise.resolve();

/// Starts `avd` on the station's adb server, at the first console port nothing on this machine holds: the source id it
/// will be listed as, once that emulator has bound its port; null when there is no such name, no port, or it ended first.
export function startEmulator(o: {
  emulator: string;
  avd: string;
  env: NodeJS.ProcessEnv;
  ended?: () => void;
  free?: (port: number) => Promise<boolean>;
  start?: (program: string, args: string[], options: { stdio: "ignore"; env: NodeJS.ProcessEnv }) => ChildProcess;
  bindMs?: number;
  /// Asked just before it is started: what allowed the start still does.
  allowed?: () => boolean;
}): Promise<string | null> {
  const next = starting.then(() => startOne(o));
  starting = next.catch(() => null);
  return next;
}

async function startOne(o: Parameters<typeof startEmulator>[0]): Promise<string | null> {
  if (!AVD_NAME.test(o.avd)) return null;
  const free = o.free ?? portFree;
  for (let port = FIRST_PORT; port <= LAST_PORT; port += 2) {
    if (held.has(port) || !(await free(port)) || !(await free(port + 1))) continue;
    if (o.allowed && !o.allowed()) return null;
    held.add(port);
    let exited = false;
    const child = (o.start ?? startLasting)(o.emulator, ["-avd", o.avd, "-port", String(port), "-no-window", "-no-boot-anim", "-no-audio"], { stdio: "ignore", env: o.env });
    const end = () => {
      if (exited) return;
      exited = true;
      held.delete(port);
      o.ended?.();
    };
    child.on("error", end);
    child.on("exit", end);
    // Its port taken is the sign it is this one's: until then another start would choose the same.
    const until = wall.now() + (o.bindMs ?? BIND_MS);
    while (!exited && (await free(port)) && wall.now() < until) await wall.sleep(250);
    if (exited) return null;
    // Not bound by then: nothing says what took its port later, so it is not this start's.
    if (await free(port)) {
      child.kill();
      return null;
    }
    return `android:emulator-${port}`;
  }
  return null;
}
