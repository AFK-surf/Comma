import { execFile } from "node:child_process";
import {
  chmod,
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import bridgeScript from "./comma_bridge.py?raw";

/**
 * Where Blender is on this computer and how Comma's bridge script gets into it.
 * The script goes into each Blender version's user `scripts/startup` folder,
 * which Blender loads at start (and on Reload Scripts) without any add-on
 * preference, so Comma never writes Blender's preferences file.
 */

export const SCRIPT_NAME = "comma_bridge.py";
/** The first line of every script Comma writes; uninstall removes only files that start with it. */
const SCRIPT_MARK = "# Comma's bridge in Blender.";
const VERSION_DIR = /^\d+\.\d+$/;

export interface BlenderInstall {
  /** The executable. */
  path: string;
  /** "4.2", the user folder version; undefined when it could not be read. */
  version?: string | undefined;
}

export interface BlenderPlatform {
  platform: NodeJS.Platform;
  home: string;
  env: NodeJS.ProcessEnv;
}

export const hostPlatform = (): BlenderPlatform => ({
  platform: process.platform,
  home: homedir(),
  env: process.env,
});

/** Blender's per-user resource folder, holding one folder per version. */
export function userRoot(p: BlenderPlatform): string {
  if (p.platform === "darwin")
    return join(p.home, "Library", "Application Support", "Blender");
  if (p.platform === "win32")
    return join(
      p.env.APPDATA ?? join(p.home, "AppData", "Roaming"),
      "Blender Foundation",
      "Blender"
    );
  return join(p.env.XDG_CONFIG_HOME ?? join(p.home, ".config"), "blender");
}

/** The Blenders installed in the usual places. */
export async function findInstalls(p: BlenderPlatform): Promise<BlenderInstall[]> {
  if (p.platform === "darwin") {
    const found: BlenderInstall[] = [];
    for (const dir of ["/Applications", join(p.home, "Applications")]) {
      for (const name of await list(dir)) {
        if (!/^blender.*\.app$/i.test(name)) continue;
        const app = join(dir, name);
        const plist = await readFile(join(app, "Contents", "Info.plist"), "utf8").catch(
          () => ""
        );
        const short =
          /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(
            plist
          )?.[1];
        found.push({
          path: join(app, "Contents", "MacOS", "Blender"),
          version: majorMinor(short),
        });
      }
    }
    return found;
  }
  if (p.platform === "win32") {
    const found: BlenderInstall[] = [];
    const roots = [
      p.env.ProgramFiles,
      p.env.ProgramW6432,
      p.env["ProgramFiles(x86)"],
    ].filter((root): root is string => !!root);
    for (const root of new Set(roots)) {
      const foundation = join(root, "Blender Foundation");
      for (const name of await list(foundation)) {
        const exe = join(foundation, name, "blender.exe");
        if (await exists(exe))
          found.push({ path: exe, version: majorMinor(/(\d+\.\d+)/.exec(name)?.[1]) });
      }
      const steam = join(
        root,
        "Steam",
        "steamapps",
        "common",
        "Blender",
        "blender.exe"
      );
      if (await exists(steam)) found.push({ path: steam });
    }
    return found;
  }
  return [];
}

/** The version of a Blender executable, from its own `--version`. */
export function readVersion(executable: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      executable,
      ["--version"],
      { timeout: 20_000, windowsHide: true },
      (error, stdout) => {
        resolve(error ? undefined : majorMinor(/Blender (\d+\.\d+)/.exec(stdout)?.[1]));
      }
    );
  });
}

/** The versions to install into: every installed Blender's and every user folder already there. */
export async function targetVersions(
  p: BlenderPlatform,
  installs: readonly BlenderInstall[],
  versionOf: (executable: string) => Promise<string | undefined> = readVersion
): Promise<string[]> {
  const versions = new Set(
    (await list(userRoot(p))).filter((name) => VERSION_DIR.test(name))
  );
  for (const install of installs) {
    const version = install.version ?? (await versionOf(install.path));
    if (version) versions.add(version);
  }
  return [...versions].toSorted();
}

export function scriptPath(p: BlenderPlatform, version: string) {
  return join(userRoot(p), version, "scripts", "startup", SCRIPT_NAME);
}

/** The bridge script, pointing at this app's bridge file. */
export function renderScript(bridgeFile: string) {
  return bridgeScript.replace('"__COMMA_BRIDGE_FILE__"', JSON.stringify(bridgeFile));
}

/** Writes the script for each version; returns the versions written. */
export async function installScripts(
  p: BlenderPlatform,
  versions: readonly string[],
  bridgeFile: string
): Promise<string[]> {
  const script = renderScript(bridgeFile);
  const written: string[] = [];
  for (const version of versions) {
    const path = scriptPath(p, version);
    await mkdir(dirname(path), { recursive: true });
    await writeAtomic(path, script);
    written.push(version);
  }
  return written;
}

/** The versions whose user folder holds Comma's script. */
export async function installedVersions(p: BlenderPlatform): Promise<string[]> {
  const versions: string[] = [];
  for (const version of (await list(userRoot(p)))
    .filter((name) => VERSION_DIR.test(name))
    .toSorted()) {
    if (await ours(scriptPath(p, version))) versions.push(version);
  }
  return versions;
}

/** Removes Comma's script from every version; leaves any other file alone. */
export async function removeScripts(p: BlenderPlatform) {
  for (const version of await installedVersions(p)) {
    const script = scriptPath(p, version);
    await rm(script, { force: true });
    // Blender's compiled copy of it.
    const cache = join(dirname(script), "__pycache__");
    for (const name of await list(cache))
      if (name.startsWith("comma_bridge."))
        await rm(join(cache, name), { force: true });
  }
}

export interface BridgeFile {
  protocol: number;
  port: number;
  token: string;
}

/** Writes the bridge file only this OS user can read. */
export async function writeBridgeFile(path: string, contents: BridgeFile) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await writeAtomic(path, `${JSON.stringify(contents)}\n`, 0o600);
}

async function ours(path: string) {
  const head = await readFile(path, "utf8").catch(() => "");
  return head.startsWith(SCRIPT_MARK);
}

async function writeAtomic(path: string, contents: string, mode = 0o644) {
  const staged = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(staged, contents, { mode });
  await chmod(staged, mode).catch(() => undefined);
  await rename(staged, path);
}

function majorMinor(version: string | undefined) {
  return /^(\d+\.\d+)/.exec(version ?? "")?.[1];
}

async function list(dir: string): Promise<string[]> {
  return readdir(dir).catch(() => []);
}

async function exists(path: string) {
  return stat(path).then(
    () => true,
    () => false
  );
}
