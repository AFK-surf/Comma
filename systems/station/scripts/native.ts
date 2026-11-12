// The native parts the TypeScript station and clients use, prebuilt (docs/development.md, "Native parts"): each one
// is named by a key, the hash of all that goes into it (its sources, as git has them, not its tests, and every vendored
// crate it uses; its Cargo.lock; the Rust toolchain; the target; how it is built), and found, in this order, in
//   1. the cache on this machine, which every worktree shares: ~/Library/Caches/comma-station-native (macOS),
//      $XDG_CACHE_HOME/comma-station-native or ~/.cache/comma-station-native (Linux), %LOCALAPPDATA%\comma-station-native
//      (Windows), or $COMMA_STATION_NATIVE_CACHE;
//   2. $COMMA_STATION_NATIVE_INBOX, a directory of artifacts (CI: those a branch's natives job built, as a run artifact);
//   3. R2: the bucket cue-release under station-native/, read over public HTTPS (no login) at $COMMA_STATION_NATIVE_URL
//      (default https://cue-release.afk.surf/station-native), which CI publishes to from main;
//   4. built here, from the checkout (and said so).
// So an everyday build or test compiles no Rust; only a change to a part's own sources builds it, once per machine.
//
//   node scripts/native.ts path <part> [target]        where it is (a directory), getting or building it first
//   node scripts/native.ts file <part> [target]        its main file (mesh.node, comma-runner, …)
//   node scripts/native.ts key <part> [target]         its key
//   node scripts/native.ts fetch <part> [target]       into the cache, never building (fails when not prebuilt)
//   node scripts/native.ts build <part> [target]       built here, into the cache, whatever is there
//   node scripts/native.ts run <part>… -- <command…>   the command, with each part's variable set (COMMA_STATION_MESH_NATIVE, …)
//   node scripts/native.ts status                      every part and target: key, and whether cached / published
//   node scripts/native.ts missing [part[:target]…]    those (default: all of ours) R2 lacks, one a line
//   node scripts/native.ts ensure [--publish] [--outbox DIR] [part[:target]…]
//        CI: each (default: all) in the cache, built when not prebuilt; --publish uploads what R2 lacks (aws, with
//        CLOUDFLARE_R2_*; main only); --outbox copies the artifacts R2 lacks there (a branch's run artifact)
//   node scripts/native.ts prune [N]                   R2 keeps the newest N (20) of each part and target
//
// COMMA_STATION_NATIVE=build never downloads (builds what the cache lacks); COMMA_STATION_NATIVE=offline neither downloads nor
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
const STORE = (process.env.COMMA_STATION_NATIVE_URL ?? "https://cue-release.afk.surf/station-native").replace(/\/$/, "");
/// …and written (CI, with CLOUDFLARE_R2_*): that prefix of the bucket.
const PREFIX = "station-native/";
const VENDORED = ["vendor/iroh", "vendor/iroh-mdns-address-lookup", "vendor/noq-udp", "vendor/swarm-discovery"];

type Target = "darwin-arm64" | "linux-x64" | "linux-arm64" | "win32-x64" | "android-arm64" | "ios-arm64" | "ios-sim-arm64" | "wasm32";
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
  /// Its Mac files are Mach-O binaries of ours, which `verify` checks (a crate's; not scrcpy's server).
  machO?: boolean;
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
  "android-arm64": "aarch64-linux-android",
  "ios-arm64": "aarch64-apple-ios",
  "ios-sim-arm64": "aarch64-apple-ios-sim",
  wasm32: "wasm32-unknown-unknown",
};
const TRIPLE = (t: Target): string => TRIPLES[t] ?? fail(`no Rust target for ${t}`);
function fail(message: string): never {
  throw new Error(message);
}
const STATION: Target[] = ["darwin-arm64", "linux-x64", "linux-arm64"];
const APPLE_STRIP = ["/usr/bin/strip", "-S", "-x"];
/// The station's own parts: Windows' too (systems/station/docs/station-ts-native.md, "Windows"), named as it names them.
const STATION_BINS: Target[] = [...STATION, "win32-x64"];
const exe = (name: string) => (t: Target) => (t === "win32-x64" ? `${name}.exe` : name);

/// A Rust crate of its own (station/native/*), for a station platform: Linux from a Mac with cargo-zigbuild, for
/// glibc 2.28 and later (Debian 10, Ubuntu 20.04, RHEL 8 on); Windows with it too, as MinGW's (napi-rs finds Node's
/// symbols in the process at run time, so no MSVC import library is needed). `name`: the file kept, by target.
///
/// On a Mac, Apple's strip takes the symbols off, not the one Rust's release profile runs. Rust 1.95.0's rust-objcopy drops
/// the padding ld puts after the indirect symbols, so an odd number of them leaves the string table 4 off an 8-byte
/// boundary. dyld does not load such an addon when it is linked with the macOS 27 SDK or later: "mis-aligned LINKEDIT
/// string pool". `verify` checks each file.
function stationCrate(dir: string, artifact: (t: Target) => string, name: string | ((t: Target) => string), extra: string[] = []): Part {
  const named = (t: Target) => (typeof name === "string" ? name : name(t));
  const mac = (t: Target) => t === "darwin-arm64";
  return {
    files: (t) => [named(t)],
    targets: STATION,
    machO: true,
    inputs: [dir, ...extra],
    recipe: (t) => ({ cargo: cargoCommand(t), artifact: artifact(t), name: named(t), ...(mac(t) ? { strip: APPLE_STRIP } : {}) }),
    build(t, out) {
      const target = targetDir(join(ROOT, dir, "target"), basename(dir));
      cargo(cargoCommand(t), join(ROOT, dir), {
        CARGO_TARGET_DIR: target,
        ...(t === "win32-x64" ? noLibnode(target) : {}),
        ...(mac(t) ? { CARGO_PROFILE_RELEASE_STRIP: "false" } : {}),
      });
      copyFileSync(join(target, TRIPLE(t), "release", artifact(t)), join(out, named(t)));
      if (mac(t)) run(APPLE_STRIP[0]!, [...APPLE_STRIP.slice(1), join(out, named(t))]);
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
/// The phones' parts are built with what the apps are: the NDK and the lowest Android of the Android app
/// (clients/apps/android, `ndkVersion`, `minSdk`), the lowest iOS of the iOS app (clients/apps/apple/project.yml).
const NDK = "27.2.12479018";
const ANDROID_API = 35;
const IOS = "18.0";
const PHONES: Target[] = ["android-arm64", "ios-arm64", "ios-sim-arm64"];
/// The NDK's LLVM: ANDROID_NDK_HOME's, else the SDK's NDK of `NDK`.
function ndkBin(): string {
  const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT ?? join(homedir(), osPlatform() === "darwin" ? "Library/Android/sdk" : "Android/Sdk");
  const ndk = process.env.ANDROID_NDK_HOME ?? join(sdk, "ndk", NDK);
  const bin = join(ndk, "toolchains/llvm/prebuilt", osPlatform() === "darwin" ? "darwin-x86_64" : "linux-x86_64", "bin");
  if (!existsSync(bin)) throw new Error(`no Android NDK ${NDK} at ${ndk} (set ANDROID_NDK_HOME)`);
  return bin;
}
/// The NDK's compilers for a crate's C parts (ring) and its linker.
function androidEnv(): Record<string, string> {
  const bin = ndkBin();
  const clang = join(bin, `aarch64-linux-android${ANDROID_API}-clang`);
  return { CC_aarch64_linux_android: clang, AR_aarch64_linux_android: join(bin, "llvm-ar"), CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER: clang };
}
/// The browser's: the NDK's clang targets WebAssembly too (ring's C parts), where Apple's does not; getrandom asks the
/// browser.
function wasmEnv(): Record<string, string> {
  const bin = ndkBin();
  return { CC_wasm32_unknown_unknown: join(bin, "clang"), AR_wasm32_unknown_unknown: join(bin, "llvm-ar"), RUSTFLAGS: '--cfg getrandom_backend="wasm_js"' };
}
/// The wasm-bindgen CLI the browser's crate is made a module with: the version its crate pins (`wasm-bindgen = "=…"`),
/// installed once into this machine's cache when the PATH has no such one.
const WASM_BINDGEN = "0.2.129";
function wasmBindgen(): string {
  const env = rustEnv();
  const onPath = spawnSync("wasm-bindgen", ["--version"], { env, encoding: "utf8" }).stdout?.trim();
  if (onPath === `wasm-bindgen ${WASM_BINDGEN}`) return "wasm-bindgen";
  const root = join(CACHE, "wasm-bindgen", WASM_BINDGEN);
  const bin = join(root, "bin", "wasm-bindgen");
  if (!existsSync(bin)) run("cargo", ["install", "wasm-bindgen-cli", "--version", WASM_BINDGEN, "--locked", "--root", root], { env });
  return bin;
}
/// A crate of the clients' for the browser, made a module with wasm-bindgen (`--target web`): `name`.js, its .wasm and
/// its types.
function webCrate(part: string, dir: string, name: string, extra: string[] = []): Part {
  return {
    files: () => [`${name}.js`, `${name}_bg.wasm`, `${name}.d.ts`],
    targets: ["wasm32"],
    inputs: [dir, ...extra],
    recipe: (t) => ({ cargo: cargoCommand(t), wasmBindgen: WASM_BINDGEN, clang: `ndk ${NDK}` }),
    build(t, out) {
      const target = targetDir(join(ROOT, dir, "target"), part);
      cargo(cargoCommand(t), join(ROOT, dir), { CARGO_TARGET_DIR: target, ...wasmEnv() });
      run(wasmBindgen(), ["--target", "web", "--out-dir", out, join(target, TRIPLE(t), "release", `${name}.wasm`)], { env: rustEnv() });
    },
  };
}
/// A crate of the clients' (clients/…), a static library each phone's app links into its core's engine.
function phoneCrate(part: string, dir: string, name: string, extra: string[] = []): Part {
  return {
    files: () => [name],
    targets: PHONES,
    inputs: [dir, ...extra],
    recipe: (t) => ({ cargo: cargoCommand(t), artifact: name, ...(t === "android-arm64" ? { ndk: NDK, api: ANDROID_API } : { ios: IOS }) }),
    build(t, out) {
      const target = targetDir(join(ROOT, dir, "target"), part);
      cargo(cargoCommand(t), join(ROOT, dir), { CARGO_TARGET_DIR: target, ...(t === "android-arm64" ? androidEnv() : { IPHONEOS_DEPLOYMENT_TARGET: IOS }) });
      copyFileSync(join(target, TRIPLE(t), "release", name), join(out, name));
    },
  };
}
const cargoCommand = (t: Target, more: string[] = []) =>
  t === "darwin-arm64" || t === "wasm32" || PHONES.includes(t)
    ? ["build", "--release", "--locked", ...more, "--target", TRIPLE(t)]
    : ["zigbuild", "--release", "--locked", ...more, "--target", t === "win32-x64" ? TRIPLE(t) : `${TRIPLE(t)}.2.28`];

/// The launcher's part: Windows' has its windowless start beside it (native/launcher/src/hidden.rs).
function withHidden(part: Part): Part {
  const hidden = "comma-station-w.exe";
  return {
    ...part,
    targets: STATION_BINS,
    env: "COMMA_STATION_LAUNCHER",
    files: (t) => (t === "win32-x64" ? [...part.files(t), hidden] : part.files(t)),
    build(t, out) {
      part.build(t, out);
      if (t === "win32-x64") copyFileSync(join(targetDir(join(ROOT, "native/launcher/target"), "launcher"), TRIPLE(t), "release", hidden), join(out, hidden));
    },
  };
}

/// scrcpy's server, the unmodified file of its release: it is not ours to build, so `build` gets it from there. It runs
/// on a device a person views (docs/android-screen.md), so a changed release file must not reach one: the hash is the
/// digest GitHub gave for the release asset when this was pinned, and a file with another makes this build fail, so
/// nothing is published or bundled. The version goes up with SERVER_VERSION in src/screens/android.ts.
const SCRCPY = {
  url: "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1",
  sha256: "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536",
};

const PARTS: Record<string, Part> = {
  // Not a crate: the same file for every station platform (SCRCPY above).
  "scrcpy-server": {
    files: () => ["scrcpy-server"],
    targets: STATION_BINS,
    env: "STILLFAIL_SCRCPY_SERVER",
    recipe: () => SCRCPY,
    build(_t, out) {
      const file = join(out, "scrcpy-server");
      run("curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--max-time", "120", "--output", file, SCRCPY.url]);
      const got = createHash("sha256").update(readFileSync(file)).digest("hex");
      if (got !== SCRCPY.sha256) throw new Error(`${SCRCPY.url}: sha256 ${got}, expected ${SCRCPY.sha256}`);
    },
  },
  // The station's iroh and image codecs, a Node addon (docs/station-ts-native.md §3); the desktop's core uses it too.
  mesh: {
    ...stationCrate("native/mesh", (t) => (t === "darwin-arm64" ? "libcomma_station_mesh.dylib" : t === "win32-x64" ? "comma_station_mesh.dll" : "libcomma_station_mesh.so"), "mesh.node", [...VENDORED, "../profiles"]),
    targets: STATION_BINS,
    env: "COMMA_STATION_MESH_NATIVE",
  },
  // Windows' main display as a screen (native/desktop-screen, still.fail's stillfail-screen ported): an executable the
  // station starts for each view (src/screens/win-desktop.ts, docs/desktop-screen.md). Windows only.
  "desktop-screen": {
    ...stationCrate("native/desktop-screen", () => "comma-desktop-screen.exe", "comma-desktop-screen.exe"),
    targets: ["win32-x64"],
    env: "COMMA_STATION_DESKTOP_SCREEN",
  },
  // Salix's copy of the Profiles' logic (systems/profiles/nif): the NIF SalixAgent.Profiles.Native loads (`.so` on every
  // platform, as the BEAM looks for it). Published for every platform, so Salix's CI and a dev container take it
  // prebuilt unless the crate changed.
  "profiles-nif": {
    ...stationCrate("../profiles/nif", (t) => (t === "darwin-arm64" ? "libcomma_profiles_nif.dylib" : "libcomma_profiles_nif.so"), "comma_profiles_nif.so", ["../profiles"]),
    env: "PROFILES_NIF",
  },
  // The TypeScript station's launcher (§2) and an agent's runner (§1).
  // On Windows with comma-station-w.exe beside it: the launcher as a logon task runs it, with no window.
  launcher: withHidden(stationCrate("native/launcher", exe("comma-station"), exe("comma-station"))),
  runner: { ...stationCrate("native/runner", exe("comma-runner"), exe("comma-runner")), targets: STATION_BINS, env: "COMMA_STATION_RUNNER" },
  // For the station's tests: the Rust station's cold storage as a command (test/cold-compat.test.ts), and a member's
  // client asking a station over iroh (tools/load: test/e2e.sh, compare.sh). This machine's only.
  "archive-rs": {
    ...stationCrate("test/archive-rs", () => "archive-rs", "archive-rs"),
    env: "ARCHIVE_RS",
    publish: ["darwin-arm64"],
  },
  "station-load": { ...stationCrate("tools/load", () => "station-load", "station-load", VENDORED), env: "E2E_LOAD", publish: ["darwin-arm64"] },
  // The phones' iroh (clients/packages/mesh/native), which the Android and iOS apps link into their core's engine. It
  // takes the station's Salix transport as its own source.
  "client-mesh": phoneCrate("client-mesh", "../../clients/packages/mesh/native", "libcomma_mesh.a", [...VENDORED, "native/mesh/src/salix.rs"]),
  // The browser's iroh (clients/packages/mesh/wasm), which the web app's core worker loads.
  "web-mesh": webCrate("web-mesh", "../../clients/packages/mesh/wasm", "comma_mesh_wasm", [...VENDORED, "native/mesh/src/salix.rs"]),
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

const CACHE = process.env.COMMA_STATION_NATIVE_CACHE ??
  (osPlatform() === "darwin" ? join(homedir(), "Library/Caches/comma-station-native")
    : osPlatform() === "win32" ? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData/Local"), "comma-station-native")
    : join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "comma-station-native"));
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

/// The string table's offset in a 64-bit Mach-O, from its LC_SYMTAB.
function stringTableOffset(file: string): number | undefined {
  const bytes = readFileSync(file);
  if (bytes.length < 32 || bytes.readUInt32LE(0) !== 0xfeedfacf) throw new Error(`${file} is not a 64-bit Mach-O`);
  for (let i = 0, at = 32; i < bytes.readUInt32LE(16); i++, at += bytes.readUInt32LE(at + 4)) {
    if (bytes.readUInt32LE(at) === 2) return bytes.readUInt32LE(at + 16);
  }
  return undefined;
}
/// Fails unless each of a Mac part's Mach-O files is one dyld takes. The offset is checked first and on every Mac: an older
/// macOS or SDK loads a bad file, and a newer one refuses it. On a Mac, a signature must hold and an addon must load.
function verify(part: string, target: Target, dir: string) {
  if (target !== "darwin-arm64" || !P(part).machO) return;
  for (const name of P(part).files(target)) {
    const file = join(dir, name);
    const offset = stringTableOffset(file);
    if (offset === undefined || offset % 8 !== 0) throw new Error(`${part} ${target}: ${name} has its string table at ${offset} (not 8-byte aligned)`);
    if (osPlatform() !== "darwin") continue;
    run("/usr/bin/codesign", ["--verify", file]);
    if (name.endsWith(".node")) run(process.execPath, ["-e", "process.dlopen({ exports: {} }, process.argv[1])", file]);
  }
}

function unpack(tgz: string, part: string, target: Target, k: string, from: string): string {
  const tmp = fresh(part);
  run(TAR, ["-xzf", tgz, "-C", tmp]);
  if (!P(part).files(target).every((f) => existsSync(join(tmp, f)))) throw new Error(`${basename(tgz)} lacks ${P(part).files(target).join(", ")}`);
  const manifest = existsSync(join(tmp, "manifest.json")) ? JSON.parse(readFileSync(join(tmp, "manifest.json"), "utf8")) : {};
  verify(part, target, tmp);
  const final = cached(part, target, k);
  install(tmp, final, { ...manifest, part, target, key: k, from });
  return final;
}

async function download(part: string, target: Target, k: string): Promise<string | null> {
  const name = asset(part, target, k);
  const inbox = process.env.COMMA_STATION_NATIVE_INBOX;
  if (inbox && existsSync(join(inbox, name))) {
    log(`${part} ${target} ${k}: from ${inbox}`);
    return unpack(join(inbox, name), part, target, k, "inbox");
  }
  const kept = keptDownload(name);
  if (kept && existsSync(kept)) {
    log(`${part} ${target} ${k}: from ${dirname(kept)}`);
    return unpack(kept, part, target, k, `${STORE}/${name}`);
  }
  const url = `${STORE}/${name}`;
  const started = Date.now();
  let response: Response;
  try {
    response = await fetchRetrying(url, 300_000);
  } catch (e) {
    log(`${part} ${target}: could not reach ${STORE} (${(e as Error).message})`);
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
    if (kept) {
      mkdirSync(dirname(kept), { recursive: true });
      copyFileSync(tgz, `${kept}.${process.pid}`);
      renameSync(`${kept}.${process.pid}`, kept);
    }
    return dir;
  } finally { rmSync(tgz, { force: true }); }
}

/// Where a CI host keeps a downloaded artifact between jobs (COMMA_TOOL_CACHE). The name holds the part's key, so a
/// kept file is the one R2 serves under that name.
function keptDownload(name: string): string | undefined {
  const cache = process.env.COMMA_TOOL_CACHE;
  return cache ? join(cache, "station-native", name) : undefined;
}

/// fetch, again after a dropped connection or a 5xx (up to 3 tries, 2 s apart).
async function fetchRetrying(url: string, timeoutMs: number, method = "GET"): Promise<Response> {
  for (let attempt = 1; ; attempt++) {
    try {
      const response = await fetch(url, { method, redirect: "follow", signal: AbortSignal.timeout(timeoutMs) });
      if (response.status < 500 || attempt === 3) return response;
      log(`${url} answered ${response.status}; trying again`);
    } catch (e) {
      if (attempt === 3) throw e;
      log(`${url}: ${(e as Error).message}; trying again`);
    }
    await new Promise((r) => setTimeout(r, 2_000));
  }
}

function buildHere(part: string, target: Target, k: string): string {
  const started = Date.now();
  log(`${part} ${target} ${k}: not prebuilt; building it here${P(part).inputs ? " (cargo)" : ""}…`);
  const tmp = fresh(part);
  try {
    P(part).build(target, tmp);
    verify(part, target, tmp);
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
  const policy = process.env.COMMA_STATION_NATIVE ?? "";
  return await lockedAsync(dir, async () => {
    if (mode !== "build" && complete(dir, part, target)) return dir;
    if (mode !== "build" && policy !== "build" && policy !== "offline") {
      const got = await download(part, target, k);
      if (got) return got;
    }
    if (mode === "fetch" || policy === "offline") throw new Error(`${part} ${target} ${k} is not prebuilt (COMMA_STATION_NATIVE=${policy || "-"}, ${mode})`);
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
  const kept = keptDownload(name);
  if (kept && existsSync(kept)) return true;
  const r = await fetchRetrying(`${STORE}/${name}`, 30_000, "HEAD");
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
      const work = join(tmpdir(), `comma-station-native-${process.pid}`);
      mkdirSync(work, { recursive: true });
      if (outbox) mkdirSync(outbox, { recursive: true });
      const summary: string[] = [];
      for (const [p, t] of wanted) {
        const k = key(p, t);
        const name = asset(p, t, k);
        // Whether R2 has it matters only to what is published or kept in the outbox: without either, a part at hand is
        // taken without asking R2, which a runner cannot always reach.
        const there = publish || outbox ? await exists(name) : undefined;
        const before = complete(cached(p, t, k), p, t);
        const started = Date.now();
        const dir = await get(p, t);
        verify(p, t, dir);
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
