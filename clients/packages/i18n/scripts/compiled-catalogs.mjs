import { createHash } from "node:crypto";
// The default export, read at each call: a unit test's temporary directory is
// in memory (packages/test-utils/src/memory-tmp.ts).
import fs from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Compiling the message catalogs into src/paraglide takes about ten seconds,
// most of it writing the type declarations. One CI job did it up to five
// times: on install, before the unit tests or the type check, and in every
// Vite build. `ensureCompiled` compiles only when src/paraglide does not hold
// the output of the current inputs, and a CI host keeps each output for its
// other jobs (`hostCache`).

const packageDirectory = fileURLToPath(new URL("..", import.meta.url));
const outputDirectory = "src/paraglide";
const stampName = ".compiled.json";
/** How many outputs a cache directory keeps (7 MB each). */
const cachedOutputs = 40;

/**
 * Where a CI host keeps the outputs: beside its node_modules snapshots
 * (.github/actions/setup-macos-cache/select-cache.sh), which every runner of
 * the host shares. None outside CI.
 */
export const hostCache = () =>
  process.env.COMMA_NODE_MODULES_CACHE
    ? join(dirname(process.env.COMMA_NODE_MODULES_CACHE), "comma-i18n")
    : undefined;

/**
 * The `isServer` expression the runtime is compiled with: by a Vite build and
 * by the command line (`pnpm compile`, `pnpm check`) alike, so each finds the
 * others' output current and none rewrites src/paraglide under another.
 */
export const viteIsServer = "import.meta.env?.SSR ?? typeof window === 'undefined'";

const sha256 = (parts) => {
  const hash = createHash("sha256");
  for (const part of parts) {
    hash.update(`${part.length}:`);
    hash.update(part);
  }
  return hash.digest("hex");
};

/** Every file under `directory` but the stamp, as sorted relative paths. */
function files(directory, prefix = "") {
  return fs
    .readdirSync(join(directory, prefix), { withFileTypes: true })
    .toSorted((a, b) => (a.name < b.name ? -1 : 1))
    .flatMap((entry) =>
      entry.isDirectory()
        ? files(directory, `${prefix}${entry.name}/`)
        : prefix === "" && entry.name === stampName
          ? []
          : [`${prefix}${entry.name}`]
    );
}

const digest = (directory) =>
  sha256(
    files(directory).flatMap((file) => [file, fs.readFileSync(join(directory, file))])
  );

/** The lockfile of the workspace `directory` is in: it pins the compiler and its plugins. */
function workspaceLockfile(directory) {
  for (let at = directory; ; at = dirname(at)) {
    const lockfile = join(at, "pnpm-lock.yaml");
    if (fs.existsSync(lockfile)) return lockfile;
    if (dirname(at) === at) {
      throw new Error(`No pnpm-lock.yaml above ${directory}.`);
    }
  }
}

/** Names what the output is a function of: the catalogs, the project, the options and the compiler. */
function inputsKey({ directory, lockfile, options }) {
  const inputs = [
    ...files(join(directory, "messages")).map((file) => `messages/${file}`),
    "project.inlang/settings.json",
  ];
  return sha256([
    JSON.stringify(options),
    fs.readFileSync(lockfile),
    ...inputs.flatMap((file) => [file, fs.readFileSync(join(directory, file))]),
  ]);
}

/** Whether `output` is a whole output of the inputs `key` names. */
function holds(output, key) {
  try {
    const stamp = JSON.parse(fs.readFileSync(join(output, stampName), "utf8"));
    return stamp.inputs === key && stamp.output === digest(output);
  } catch {
    // No stamp, or files that went while they were read: not an output.
    return false;
  }
}

/**
 * Makes `to` hold the files of `from`, each put in place whole and the stamp
 * last. The directory stays: a build that reads it meanwhile (Forge runs its
 * Vite builds at once, and each asks for the catalogs) finds every file. What
 * else `to` held goes once the output is there.
 */
function copy(from, to) {
  fs.mkdirSync(to, { recursive: true });
  const wanted = [...files(from), stampName];
  const partial = fs.mkdtempSync(join(to, ".partial-"));
  try {
    for (const file of wanted) {
      const target = join(to, file);
      fs.mkdirSync(dirname(target), { recursive: true });
      const staged = join(partial, file.replaceAll("/", "__"));
      fs.copyFileSync(join(from, file), staged);
      fs.renameSync(staged, target);
    }
  } finally {
    fs.rmSync(partial, { recursive: true, force: true });
  }
  const output = new Set(wanted);
  for (const file of files(to)) {
    if (!output.has(file)) fs.rmSync(join(to, file), { force: true });
  }
}

/**
 * Keeps `output` in `cache` under `key`, whole or not at all, and drops the
 * outputs used longest ago. The cache only saves time: a host directory that
 * cannot be written is reported, and the compiled output stands.
 */
function keep(output, cache, key) {
  try {
    const kept = join(cache, key);
    if (holds(kept, key)) return;
    // What is there under this name is not the output: a copy cut short.
    fs.rmSync(kept, { recursive: true, force: true });
    fs.mkdirSync(cache, { recursive: true });
    const partial = fs.mkdtempSync(join(cache, ".partial-"));
    try {
      copy(output, partial);
      fs.renameSync(partial, kept);
    } catch (error) {
      fs.rmSync(partial, { recursive: true, force: true });
      // Another job of the host kept the same output meanwhile.
      if (!holds(kept, key)) throw error;
    }
    const used = (name) => fs.statSync(join(cache, name)).mtimeMs;
    const stale = fs
      .readdirSync(cache)
      .filter((name) => !name.startsWith("."))
      .toSorted((a, b) => used(b) - used(a) || (a < b ? -1 : 1))
      .slice(cachedOutputs);
    for (const name of stale) {
      fs.rmSync(join(cache, name), { recursive: true, force: true });
    }
  } catch (error) {
    console.warn(`Could not keep the compiled message catalogs in ${cache}: ${error}`);
  }
}

/**
 * A directory beside the output to build a new one in: renaming its files
 * into the output needs the same file system.
 */
const staging = (directory) => fs.mkdtempSync(join(directory, ".paraglide-"));

/**
 * Moves the whole output in `from` into `output` one file at a time. A job
 * runs its builds in parallel processes, and one reads `output` while another
 * may be replacing it (a Browser Component Test shard failed on a missing
 * `messages/_index.js`): each file is renamed over the one before it, so a
 * reader finds every file whole, never an emptied directory. The stamp goes
 * first and comes back last: `output` is named whole only once it is.
 */
function install(from, output) {
  fs.mkdirSync(output, { recursive: true });
  fs.rmSync(join(output, stampName), { force: true });
  const fresh = files(from);
  for (const file of fresh) {
    fs.mkdirSync(dirname(join(output, file)), { recursive: true });
    fs.renameSync(join(from, file), join(output, file));
  }
  const current = new Set(fresh);
  for (const file of files(output)) {
    if (!current.has(file)) fs.rmSync(join(output, file), { force: true });
  }
  fs.renameSync(join(from, stampName), join(output, stampName));
  fs.rmSync(from, { recursive: true, force: true });
}

/**
 * Installs the cache's output of `key` into `output`; false when the cache
 * has no whole one. The copy is what gets checked: the cache is read once,
 * across the host's file share.
 */
function restore(directory, output, cache, key) {
  const kept = join(cache, key);
  if (!fs.existsSync(join(kept, stampName))) return false;
  const copied = staging(directory);
  try {
    copy(kept, copied);
  } catch {
    // Dropped by another job while it was copied.
    fs.rmSync(copied, { recursive: true, force: true });
    return false;
  }
  if (!holds(copied, key)) {
    fs.rmSync(copied, { recursive: true, force: true });
    return false;
  }
  install(copied, output);
  try {
    // Used now: the outputs used longest ago are the ones dropped.
    const now = new Date();
    fs.utimesSync(kept, now, now);
  } catch {
    // Dropped meanwhile; the copy is whole.
  }
  return true;
}

// Imported when a compilation is due. A Vite config passes its own import:
// one that Vite's module runner loaded cannot import after the config has.
const paraglideCompile = async (job) =>
  (await import("@inlang/paraglide-js")).compile(job);

/**
 * Leaves src/paraglide holding the compiled catalogs. Returns how: `current`
 * (it already did), `restored` (from the host's cache) or `compiled`.
 *
 * @param {object} [given]
 * @param {string} [given.isServer] The runtime's `isServer` expression; Paraglide's default without one.
 * @param {string} [given.directory] The i18n package.
 * @param {string} [given.cache] A directory that outlives the checkout, shared by the host's jobs; none without one.
 * @param {(job: { project: string, outdir: string }) => Promise<unknown>} [given.compile] Paraglide's `compile`.
 */
export async function ensureCompiled({
  isServer,
  directory = packageDirectory,
  cache,
  compile = paraglideCompile,
} = {}) {
  const options = {
    strategy: ["globalVariable", "baseLocale"],
    outputStructure: "locale-modules",
    emitTsDeclarations: true,
    ...(isServer === undefined ? {} : { isServer }),
  };
  const key = inputsKey({ directory, lockfile: workspaceLockfile(directory), options });
  const output = join(directory, outputDirectory);
  if (holds(output, key)) return "current";
  if (cache && restore(directory, output, cache, key)) return "restored";
  // Compiled beside the output, which stays whole for its readers meanwhile.
  const compiled = staging(directory);
  try {
    await compile({
      project: join(directory, "project.inlang"),
      outdir: compiled,
      ...options,
    });
    fs.writeFileSync(
      join(compiled, stampName),
      JSON.stringify({ inputs: key, output: digest(compiled) })
    );
  } catch (error) {
    fs.rmSync(compiled, { recursive: true, force: true });
    throw error;
  }
  // Kept from what this job compiled: the output may meanwhile be another job's.
  if (cache) keep(compiled, cache, key);
  install(compiled, output);
  return "compiled";
}
