// The native parts the TypeScript station and clients use, prebuilt (docs/development.md, "Native parts"): each one
// is named by a key, the hash of all that goes into it (its sources, as git has them, not its tests, and every vendored
// crate it uses; its Cargo.lock; the Rust toolchain; the target; how it is built), and found, in this order, in
//   1. the cache on this machine, which every worktree shares: ~/Library/Caches/stillfail-native (macOS),
//      $XDG_CACHE_HOME/stillfail-native or ~/.cache/stillfail-native (Linux), %LOCALAPPDATA%\stillfail-native
//      (Windows), or $STILLFAIL_NATIVE_CACHE;
//   2. $STILLFAIL_NATIVE_INBOX, a directory of artifacts (CI: those a branch's natives job built, as a run artifact);
//   3. R2: the bucket cue-release under station-native/, read over public HTTPS (no login) at $STILLFAIL_NATIVE_URL
//      (default https://cue-release.afk.surf/station-native), which CI publishes to from main;
//   4. built here, from the checkout (and said so).
// So an everyday build or test compiles no Rust; only a change to a part's own sources builds it, once per machine.
//
//   node scripts/native.ts path <part> [target]        where it is (a directory), getting or building it first
//   node scripts/native.ts file <part> [target]        its main file (mesh.node, stillfail-runner, …)
//   node scripts/native.ts key <part> [target]         its key
//   node scripts/native.ts fetch <part> [target]       into the cache, never building (fails when not prebuilt)
//   node scripts/native.ts build <part> [target]       built here, into the cache, whatever is there
//   node scripts/native.ts run <part>… -- <command…>   the command, with each part's variable set (STILLFAIL_MESH_NATIVE, …)
//   node scripts/native.ts status                      every part and target: key, and whether cached / published
//   node scripts/native.ts missing [part[:target]…]    those (default: all of ours) R2 lacks, one a line
//   node scripts/native.ts ensure [--publish] [--outbox DIR] [part[:target]…]
//        CI: each (default: all) in the cache, built when not prebuilt; --publish uploads what R2 lacks (aws, with
//        CLOUDFLARE_R2_*; main only); --outbox copies the artifacts R2 lacks there (a branch's run artifact)
//   node scripts/native.ts prune [N]                   R2 keeps the newest N (20) of each part and target
//
// STILLFAIL_NATIVE=build never downloads (builds what the cache lacks); STILLFAIL_NATIVE=offline neither downloads nor
// builds. Builds go to $CARGO_TARGET_DIR/native/<part> when it is set, else the crate's own target/ (a worktree's own:
// a vendored crate built from two checkouts in one target confuses rustc, docs/operations.md).
import { execFileSync, spawnSync, type SpawnSyncOptions } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { homedir, hostname, platform as osPlatform, arch as osArch, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// A URL's pathname keeps a checkout path's non-ASCII characters percent-encoded: no such directory.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/// The Rust every part is built with (rustup installs it on first use): part of each key, so a newer one is a rebuild.
const TOOLCHAIN = "1.95.0";
/// zig, for the Linux builds from a Mac (cargo-zigbuild): only its own version builds what gets published.
const ZIG = "0.16.0";
/// The prebuilt parts, read: R2's public address of the bucket cue-release, under station-native/.
const STORE = (process.env.STILLFAIL_NATIVE_URL ?? "https://cue-release.afk.surf/station-native").replace(/\/$/, "");
/// …and written (CI, with CLOUDFLARE_R2_*): that prefix of the bucket.
const PREFIX = "station-native/";
const VENDORED = ["vendor/iroh", "vendor/iroh-mdns-address-lookup", "vendor/noq-udp", "vendor/swarm-discovery"];

type Target = "darwin-arm64" | "linux-x64" | "linux-arm64" | "win32-x64";
type Part = {
  /// What the artifact holds.
  files: (target: Target) => string[];
  targets: Target[];
  /// The targets CI publishes (default: all).
  publish?: Target[];
  /// The variable its users read its main file from (`run`).
  env?: string;
  /// What goes into it, as git paths; and how it is built, as data (both are in the key).
  inputs?: string[];
  recipe: (target: Target) => unknown;
  /// Built into `out` (a fresh directory).
  build: (target: Target, out: string) => void;
};

const host = (): Target => {
  const os = osPlatform(), cpu = osArch();
  if (os === "darwin" && cpu === "arm64") return "darwin-arm64";
  if (os === "linux" && cpu === "x64") return "linux-x64";
  if (os === "linux" && cpu === "arm64") return "linux-arm64";
  if (os === "win32" && cpu === "x64") return "win32-x64";
  throw new Error(`no native parts for ${os}-${cpu}`);
};
const TRIPLES: Record<string, string> = {
  "darwin-arm64": "aarch64-apple-darwin",
  "linux-x64": "x86_64-unknown-linux-gnu",
  "linux-arm64": "aarch64-unknown-linux-gnu",
  "win32-x64": "x86_64-pc-windows-gnu",
};
const TRIPLE = (t: Target): string => TRIPLES[t] ?? fail(`no Rust target for ${t}`);
function fail(message: string): never {
  throw new Error(message);
}
const STATION: Target[] = ["darwin-arm64", "linux-x64", "linux-arm64"];
/// The station's own parts: Windows' too (systems/station/docs/station-ts-native.md, "Windows"), named as it names them.
const STATION_BINS: Target[] = [...STATION, "win32-x64"];
const exe = (name: string) => (t: Target) => (t === "win32-x64" ? `${name}.exe` : name);

/// A Rust crate of its own (station/native/*), for a station platform: Linux from a Mac with cargo-zigbuild, for
/// glibc 2.28 and later (Debian 10, Ubuntu 20.04, RHEL 8 on); Windows with it too, as MinGW's (napi-rs finds Node's
/// symbols in the process at run time, so no MSVC import library is needed). `name`: the file kept, by target.
function stationCrate(dir: string, artifact: (t: Target) => string, name: string | ((t: Target) => string), extra: string[] = []): Part {
  const named = (t: Target) => (typeof name === "string" ? name : name(t));
  return {
    files: (t) => [named(t)],
    targets: STATION,
    inputs: [dir, ...extra],
    recipe: (t) => ({ cargo: cargoCommand(t), artifact: artifact(t), name: named(t) }),
    build(t, out) {
      const target = targetDir(join(ROOT, dir, "target"), basename(dir));
      cargo(cargoCommand(t), join(ROOT, dir), { CARGO_TARGET_DIR: target, ...(t === "win32-x64" ? noLibnode(target) : {}) });
      copyFileSync(join(target, TRIPLE(t), "release", artifact(t)), join(out, named(t)));
    },
  };
}
/// napi-build links a MinGW addon to libnode.dll, which neither Node nor Electron has on Windows: their Node-API is in
/// the executable, and napi-sys (dyn-symbols, its default) looks every function up there when the addon loads. So it
/// is given an empty import library to link (nothing is taken from it) and a libnode.dll to find beside it.
function noLibnode(target: string): Record<string, string> {
  const dir = join(target, "no-libnode");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "libnode.dll"), "");
  writeFileSync(join(dir, "libnode.a"), "!<arch>\n");
  return { LIBNODE_PATH: dir };
}
const cargoCommand = (t: Target, more: string[] = []) =>
  t === "darwin-arm64"
    ? ["build", "--release", "--locked", ...more, "--target", TRIPLE(t)]
    : ["zigbuild", "--release", "--locked", ...more, "--target", t === "win32-x64" ? TRIPLE(t) : `${TRIPLE(t)}.2.28`];

/// The launcher's part: Windows' has its windowless start beside it (native/launcher/src/hidden.rs).
function withHidden(part: Part): Part {
  const hidden = "stillfail-station-w.exe";
  return {
    ...part,
    targets: STATION_BINS,
    env: "STILLFAIL_LAUNCHER",
    files: (t) => (t === "win32-x64" ? [...part.files(t), hidden] : part.files(t)),
    build(t, out) {
      part.build(t, out);
      if (t === "win32-x64") copyFileSync(join(targetDir(join(ROOT, "native/launcher/target"), "launcher"), TRIPLE(t), "release", hidden), join(out, hidden));
    },
  };
}

const PARTS: Record<string, Part> = {
  // The station's iroh and image codecs, a Node addon (docs/station-ts-native.md §3); the desktop's core uses it too.
  mesh: {
    ...stationCrate("native/mesh", (t) => (t === "darwin-arm64" ? "libstillfail_mesh.dylib" : t === "win32-x64" ? "stillfail_mesh.dll" : "libstillfail_mesh.so"), "mesh.node", [...VENDORED, "../profiles"]),
    targets: STATION_BINS,
    env: "STILLFAIL_MESH_NATIVE",
  },
  // Salix's copy of the Profiles' logic (systems/profiles/nif): the NIF SalixAgent.Profiles.Native loads (`.so` on every
  // platform, as the BEAM looks for it). Published for every platform, so Salix's CI and a dev container take it
  // prebuilt unless the crate changed.
  "profiles-nif": {
    ...stationCrate("../profiles/nif", (t) => (t === "darwin-arm64" ? "libcomma_profiles_nif.dylib" : "libcomma_profiles_nif.so"), "comma_profiles_nif.so", ["../profiles"]),
    env: "PROFILES_NIF",
  },
  // The TypeScript station's launcher (§2) and an agent's runner (§1).
  // On Windows with stillfail-station-w.exe beside it: the launcher as a logon task runs it, with no window.
  launcher: withHidden(stationCrate("native/launcher", exe("stillfail-station"), exe("stillfail-station"))),
  runner: { ...stationCrate("native/runner", exe("stillfail-runner"), exe("stillfail-runner")), targets: STATION_BINS, env: "STILLFAIL_RUNNER" },
  // For the station's tests: the Rust station's cold storage as a command (test/cold-compat.test.ts), and a member's
  // client asking a station over iroh (tools/load: test/e2e.sh, compare.sh). This machine's only.
  "archive-rs": {
    ...stationCrate("test/archive-rs", () => "archive-rs", "archive-rs"),
    env: "ARCHIVE_RS",
    publish: ["darwin-arm64"],
  },
  "station-load": { ...stationCrate("tools/load", () => "station-load", "station-load", VENDORED), env: "E2E_LOAD", publish: ["darwin-arm64"] },
};
const P = (name: string): Part => PARTS[name] ?? fail(`no such part: ${name} (${Object.keys(PARTS).join(", ")})`);
const defaultTarget = (part: string): Target => P(part).targets.length === 1 ? P(part).targets[0]! : host();

// ── keys ──

function git(args: string[], input?: string): string {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8", input, maxBuffer: 64 << 20 });
}
/// Each input file and its content's git hash: as committed or staged, and as it is in the worktree when it differs
/// there (an edit not yet committed is another key), new files not ignored included.
function inputs(paths: string[]): [string, string][] {
  if (paths.length === 0) return [];
  const files = new Map<string, string>();
  for (const line of git(["ls-files", "-s", "-z", "--", ...paths]).split("\0")) {
    if (!line) continue;
    const [meta, path] = line.split("\t");
    files.set(path!, meta!.split(" ")[1]!);
  }
  const dirty = git(["ls-files", "-m", "-o", "--exclude-standard", "-z", "--", ...paths]).split("\0").filter(Boolean);
  const present = [...new Set(dirty)].filter((p) => existsSync(join(ROOT, p)) && statSync(join(ROOT, p)).isFile());
  for (const p of dirty) if (!present.includes(p)) files.delete(p);
  if (present.length > 0) {
    const hashes = git(["hash-object", "--stdin-paths"], present.map((p) => join(ROOT, p)).join("\n") + "\n").trim().split("\n");
    present.forEach((p, i) => files.set(p, hashes[i]!));
  }
  // A crate's tests, benches and examples are not in what it builds: changed, it is the same part (a test-only change
  // built the launcher and runner again for three platforms on 2026-10-04).
  for (const p of [...files.keys()]) if (/(^|\/)(tests|benches|examples)\//.test(p)) files.delete(p);
  return [...files].sort(([a], [b]) => (a < b ? -1 : 1));
}
function key(part: string, target: Target): string {
  const p = P(part);
  const what = { part, target, toolchain: TOOLCHAIN, zig: target.startsWith("linux") || target === "win32-x64" ? ZIG : undefined, recipe: p.recipe(target), files: p.files(target), inputs: inputs(p.inputs ?? []) };
  return createHash("sha256").update(JSON.stringify(what)).digest("hex").slice(0, 24);
}
const asset = (part: string, target: Target, k: string) => `${part}-${target}-${k}.tar.gz`;

// ── the cache ──

const CACHE = process.env.STILLFAIL_NATIVE_CACHE ??
  (osPlatform() === "darwin" ? join(homedir(), "Library/Caches/stillfail-native")
    : osPlatform() === "win32" ? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData/Local"), "stillfail-native")
    : join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "stillfail-native"));
const cached = (part: string, target: Target, k: string) => join(CACHE, part, `${target}-${k}`);
const log = (msg: string) => process.stderr.write(`native: ${msg}\n`);

/// One process at a time gets or builds a key on this machine (the others wait for it): a directory made atomically,
/// holding the pid, taken over when that process is gone.
function acquire(dir: string): () => void {
  const lock = `${dir}.lock`;
  mkdirSync(dirname(lock), { recursive: true });
  let said = false;
  for (;;) {
    try {
      mkdirSync(lock);
      writeFileSync(join(lock, "pid"), String(process.pid));
      return () => rmSync(lock, { recursive: true, force: true });
    } catch {
      let pid = 0;
      try { pid = Number(readFileSync(join(lock, "pid"), "utf8")); } catch {}
      let alive = pid > 0;
      if (alive) try { process.kill(pid, 0); } catch { alive = false; }
      // A lock just made has no pid yet (one that stays without for a minute was left by a crash); one whose holder
      // is gone is taken.
      let old = false;
      try { old = !pid && Date.now() - statSync(lock).mtimeMs > 60_000; } catch {}
      if ((!alive && pid > 0) || old) { rmSync(lock, { recursive: true, force: true }); continue; }
      if (!said) { log(`waiting for another process (${pid || "?"}) getting ${basename(dir)}`); said = true; }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
    }
  }
}

/// Puts a finished directory in place of `final` (a rename: whoever looks sees all of it or nothing).
function install(tmp: string, final: string, manifest: object) {
  writeFileSync(join(tmp, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  rmSync(final, { recursive: true, force: true });
  renameSync(tmp, final);
}
function fresh(part: string): string {
  const parent = join(CACHE, part);
  mkdirSync(parent, { recursive: true });
  // What a process killed while getting one left.
  for (const name of readdirSync(parent)) {
    const pid = Number(name.match(/^\.tmp-(\d+)-/)?.[1] ?? 0);
    if (!pid || pid === process.pid) continue;
    try { process.kill(pid, 0); } catch { rmSync(join(parent, name), { recursive: true, force: true }); }
  }
  const dir = join(parent, `.tmp-${process.pid}-${randomBytes(4).toString("hex")}`);
  mkdirSync(dir);
  return dir;
}
const complete = (dir: string, part: string, target: Target) =>
  existsSync(join(dir, "manifest.json")) && P(part).files(target).every((f) => existsSync(join(dir, f)));

/// On Windows, System32's tar (bsdtar): the tar a Git Bash puts first on PATH is GNU's, which reads `C:` in an
/// archive's path as a host to connect to.
const TAR = process.platform === "win32" ? join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe") : "tar";

function unpack(tgz: string, part: string, target: Target, k: string, from: string): string {
  const tmp = fresh(part);
  run(TAR, ["-xzf", tgz, "-C", tmp]);
  if (!P(part).files(target).every((f) => existsSync(join(tmp, f)))) throw new Error(`${basename(tgz)} lacks ${P(part).files(target).join(", ")}`);
  const manifest = existsSync(join(tmp, "manifest.json")) ? JSON.parse(readFileSync(join(tmp, "manifest.json"), "utf8")) : {};
  const final = cached(part, target, k);
  install(tmp, final, { ...manifest, part, target, key: k, from });
  return final;
}

async function download(part: string, target: Target, k: string): Promise<string | null> {
  const name = asset(part, target, k);
  const inbox = process.env.STILLFAIL_NATIVE_INBOX;
  if (inbox && existsSync(join(inbox, name))) {
    log(`${part} ${target} ${k}: from ${inbox}`);
    return unpack(join(inbox, name), part, target, k, "inbox");
  }
  const url = `${STORE}/${name}`;
  const started = Date.now();
  let response: Response;
  try {
    response = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(300_000) });
  } catch (e) {
    log(`${part} ${target}: could not reach GitHub (${(e as Error).message})`);
    return null;
  }
  if (response.status === 404) return null;
  if (!response.ok) { log(`${part} ${target}: ${url} answered ${response.status}`); return null; }
  const bytes = Buffer.from(await response.arrayBuffer());
  const tgz = join(tmpdir(), `${name}.${process.pid}`);
  writeFileSync(tgz, bytes);
  try {
    const dir = unpack(tgz, part, target, k, url);
    log(`${part} ${target} ${k}: downloaded (${(bytes.length / 1e6).toFixed(1)} MB, ${((Date.now() - started) / 1000).toFixed(1)} s)`);
    return dir;
  } finally { rmSync(tgz, { force: true }); }
}

function buildHere(part: string, target: Target, k: string): string {
  const started = Date.now();
  log(`${part} ${target} ${k}: not prebuilt; building it here${P(part).inputs ? " (cargo)" : ""}…`);
  const tmp = fresh(part);
  try {
    P(part).build(target, tmp);
  } catch (e) {
    rmSync(tmp, { recursive: true, force: true });
    throw e;
  }
  const final = cached(part, target, k);
  install(tmp, final, { part, target, key: k, from: "built", host: hostname(), builtAt: new Date().toISOString(), toolchain: TOOLCHAIN, commit: git(["rev-parse", "HEAD"]).trim() });
  log(`${part} ${target} ${k}: built in ${((Date.now() - started) / 1000).toFixed(0)} s`);
  return final;
}

/// The part's directory in the cache: there already, downloaded, or built.
async function get(part: string, target: Target, mode: "any" | "fetch" | "build" = "any"): Promise<string> {
  const k = key(part, target);
  const dir = cached(part, target, k);
  if (mode !== "build" && complete(dir, part, target)) return dir;
  const policy = process.env.STILLFAIL_NATIVE ?? "";
  return await lockedAsync(dir, async () => {
    if (mode !== "build" && complete(dir, part, target)) return dir;
    if (mode !== "build" && policy !== "build" && policy !== "offline") {
      const got = await download(part, target, k);
      if (got) return got;
    }
    if (mode === "fetch" || policy === "offline") throw new Error(`${part} ${target} ${k} is not prebuilt (STILLFAIL_NATIVE=${policy || "-"}, ${mode})`);
    // n0's relay is downloaded from n0 whatever the policy: "building" it is that.
    return buildHere(part, target, k);
  });
}
async function lockedAsync<T>(dir: string, f: () => Promise<T>): Promise<T> {
  const release = acquire(dir);
  try { return await f(); } finally { release(); }
}
// ── building ──

function run(cmd: string, args: string[], options: SpawnSyncOptions = {}) {
  const done = spawnSync(cmd, args, { stdio: ["ignore", process.stderr, process.stderr], ...options });
  if (done.error) throw done.error;
  if (done.status !== 0) throw new Error(`${cmd} ${args.join(" ")}: exit ${done.status ?? done.signal}`);
}
function rustEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const home = homedir();
  return {
    ...process.env,
    PATH: [join(home, ".cargo/bin"), "/opt/homebrew/bin", process.env.PATH].join(":"),
    RUSTUP_TOOLCHAIN: TOOLCHAIN,
    CARGO_INCREMENTAL: "0",
    ...extra,
  };
}
/// The toolchain and the target, installed when missing (rustup does it once per machine).
function rustTarget(triple: string) {
  const env = rustEnv();
  const installed = spawnSync("rustup", ["target", "list", "--installed", "--toolchain", TOOLCHAIN], { env, encoding: "utf8" });
  if (installed.status !== 0) run("rustup", ["toolchain", "install", TOOLCHAIN, "--profile", "minimal"], { env });
  if (!(installed.stdout ?? "").split("\n").includes(triple)) run("rustup", ["target", "add", "--toolchain", TOOLCHAIN, triple], { env });
}
function cargo(args: string[], cwd: string, extra: Record<string, string>) {
  const env = rustEnv(extra);
  const triple = args[args.indexOf("--target") + 1]!.replace(/\.2\.28$/, "");
  rustTarget(triple);
  if (args[0] === "zigbuild") {
    const zig = spawnSync("zig", ["version"], { env, encoding: "utf8" }).stdout?.trim();
    // A Linux machine without zig builds its own platform's for itself (Salix's CI): kept in its cache, never
    // published (only the Macs publish, with zig).
    if (!zig && triple === TRIPLE(host())) {
      log(`no zig here: built for this machine only`);
      args = ["build", ...args.slice(1).map((a) => a.replace(/\.2\.28$/, ""))];
    } else if (zig !== ZIG) log(`zig ${zig ?? "(none)"} here, the key assumes ${ZIG}`);
  }
  run("cargo", args, { cwd, env });
}
/// Where a part's cargo build goes: the job's own target (CI sets CARGO_TARGET_DIR), a directory of its own in it.
const targetDir = (own: string, part: string) => (process.env.CARGO_TARGET_DIR ? join(process.env.CARGO_TARGET_DIR, "native", part) : own);
// ── publishing (CI on main) ──

/// The aws CLI against R2, with the repository's CLOUDFLARE_R2_* (CI).
function aws(args: string[]): string {
  const account = process.env.CLOUDFLARE_R2_ACCOUNT_ID ?? fail("CLOUDFLARE_R2_ACCOUNT_ID is not set");
  const env = {
    ...process.env,
    AWS_ACCESS_KEY_ID: process.env.CLOUDFLARE_R2_ACCESS_KEY_ID ?? fail("CLOUDFLARE_R2_ACCESS_KEY_ID is not set"),
    AWS_SECRET_ACCESS_KEY: process.env.CLOUDFLARE_R2_SECRET_ACCESS_KEY ?? fail("CLOUDFLARE_R2_SECRET_ACCESS_KEY is not set"),
    AWS_DEFAULT_REGION: "auto", AWS_RETRY_MODE: "standard", AWS_MAX_ATTEMPTS: "3",
  };
  const done = spawnSync("aws", ["--endpoint-url", `https://${account}.r2.cloudflarestorage.com`, ...args], { env, encoding: "utf8", maxBuffer: 64 << 20 });
  if (done.status !== 0) throw new Error(`aws ${args.join(" ")}: ${done.stderr ?? done.error?.message}`);
  return done.stdout;
}
const bucket = () => process.env.CLOUDFLARE_R2_BUCKET ?? fail("CLOUDFLARE_R2_BUCKET is not set");
/// What R2 has: name → when it was written.
function listed(): Map<string, string> {
  const out = aws(["s3api", "list-objects-v2", "--bucket", bucket(), "--prefix", PREFIX, "--query", "Contents[].[Key,LastModified]", "--output", "text"]);
  const all = new Map<string, string>();
  for (const line of out.split("\n")) {
    const [k, when] = line.split("\t");
    if (k && k !== "None" && when) all.set(k.slice(PREFIX.length), when);
  }
  return all;
}
/// Whether R2 has NAME, over the public address (no credentials).
async function exists(name: string): Promise<boolean> {
  const r = await fetch(`${STORE}/${name}`, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(30_000) });
  return r.ok;
}
function pack(dir: string, name: string, into: string): string {
  const file = join(into, name);
  run(TAR, ["-czf", file, "-C", dir, "."]);
  return file;
}

// ── commands ──

const pair = (args: string[]): [string, Target] => {
  const part = args[0] ?? fail("which part?");
  P(part);
  const target = (args[1] as Target) ?? defaultTarget(part);
  if (!P(part).targets.includes(target)) throw new Error(`${part} has no target ${target} (${P(part).targets.join(", ")})`);
  return [part, target];
};
const mainFile = (part: string, target: Target, dir: string) => join(dir, P(part).files(target)[0]!);

async function main(argv: string[]) {
  const [cmd, ...args] = argv;
  switch (cmd) {
    case "key": { const [p, t] = pair(args); console.log(key(p, t)); return; }
    case "path": { const [p, t] = pair(args); console.log(await get(p, t)); return; }
    case "file": { const [p, t] = pair(args); console.log(mainFile(p, t, await get(p, t))); return; }
    case "fetch": { const [p, t] = pair(args); console.log(await get(p, t, "fetch")); return; }
    case "build": { const [p, t] = pair(args); console.log(await get(p, t, "build")); return; }
    case "run": {
      const at = args.indexOf("--");
      if (at < 1) throw new Error("usage: native.ts run <part>… -- <command…>");
      const env = { ...process.env };
      for (const part of args.slice(0, at)) {
        const [p, t] = pair([part]);
        const name = P(p).env;
        if (!name) throw new Error(`${p} has no variable`);
        if (!env[name]) env[name] = mainFile(p, t, await get(p, t));
      }
      const [command, ...rest] = args.slice(at + 1);
      const done = spawnSync(command ?? fail("no command"), rest, { stdio: "inherit", env });
      process.exit(done.status ?? 1);
    }
    case "status": {
      for (const [p, part] of Object.entries(PARTS)) for (const t of part.targets) {
        const k = key(p, t);
        const local = complete(cached(p, t, k), p, t) ? "cached" : "-";
        const up = (await exists(asset(p, t, k))) ? "published" : "-";
        console.log(`${p.padEnd(12)} ${t.padEnd(14)} ${k}  ${local.padEnd(7)} ${up}`);
      }
      return;
    }
    case "missing": {
      // Each part (default: all of ours) R2 lacks, one a line.
      const wanted: [string, Target][] = [];
      for (const a of args) { const [p, t] = a.split(":"); wanted.push(pair(t ? [p!, t] : [p!])); }
      if (wanted.length === 0) for (const [p, part] of Object.entries(PARTS)) if (p !== "iroh-relay") for (const t of part.publish ?? part.targets) wanted.push([p, t]);
      for (const [p, t] of wanted) if (!(await exists(asset(p, t, key(p, t))))) console.log(`${p}:${t}`);
      return;
    }
    case "ensure": {
      let publish = false, outbox = "";
      const wanted: [string, Target][] = [];
      for (let i = 0; i < args.length; i++) {
        if (args[i] === "--publish") publish = true;
        else if (args[i] === "--outbox") outbox = args[++i] ?? fail("--outbox DIR");
        else { const [p, t] = args[i]!.split(":"); wanted.push(pair(t ? [p!, t] : [p!])); }
      }
      // Default: all of ours (n0's relay is not ours to publish).
      if (wanted.length === 0) for (const [p, part] of Object.entries(PARTS)) if (p !== "iroh-relay") for (const t of part.publish ?? part.targets) wanted.push([p, t]);
      const work = join(tmpdir(), `stillfail-native-${process.pid}`);
      mkdirSync(work, { recursive: true });
      if (outbox) mkdirSync(outbox, { recursive: true });
      const summary: string[] = [];
      for (const [p, t] of wanted) {
        const k = key(p, t);
        const name = asset(p, t, k);
        const there = await exists(name);
        const before = complete(cached(p, t, k), p, t);
        const started = Date.now();
        const dir = await get(p, t);
        const took = ((Date.now() - started) / 1000).toFixed(0);
        const how = before ? "cached" : JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")).from === "built" ? "built" : "downloaded";
        let note = "";
        if (!there && publish) {
          const file = pack(dir, name, work);
          aws(["s3", "cp", file, `s3://${bucket()}/${PREFIX}${name}`, "--only-show-errors"]);
          note = " → published";
        } else if (!there && outbox) {
          pack(dir, name, outbox);
          note = " → outbox";
        }
        summary.push(`${p} ${t} ${k}: ${how} (${took} s)${there ? ", published already" : note}`);
      }
      rmSync(work, { recursive: true, force: true });
      for (const line of summary) console.log(line);
      return;
    }
    case "prune": {
      const keep = Number(args[0] ?? 20);
      const groups = new Map<string, [string, string][]>();
      for (const [name, when] of listed()) {
        const g = name.replace(/-[0-9a-f]{24}\.tar\.gz$/, "");
        groups.set(g, [...(groups.get(g) ?? []), [name, when]]);
      }
      for (const [, list] of groups) {
        list.sort((a, b) => (a[1] < b[1] ? 1 : -1));
        for (const [name] of list.slice(keep)) { aws(["s3", "rm", `s3://${bucket()}/${PREFIX}${name}`, "--only-show-errors"]); console.log(`deleted ${name}`); }
      }
      return;
    }
    default:
      process.stderr.write(readFileSync(new URL(import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("//")).map((l) => l.slice(3)).join("\n") + "\n");
      process.exit(cmd ? 2 : 0);
  }
}

main(process.argv.slice(2)).catch((e) => {
  log((e as Error).message);
  process.exit(1);
});
