import { createRequire, syncBuiltinESMExports } from "node:module";
import { dirname, isAbsolute, resolve } from "node:path";
import { standIn } from "./io-guard";
import { namingTemporaryFiles } from "./seeded-random";

// The machine's temporary directory, in memory: a unit test's files under
// os.tmpdir() (mkdtemp, writes, reads, renames, streams) never reach the disk,
// so they cost no real IO and leave nothing behind. The real `node:fs` and
// `node:fs/promises` functions send a path under the temporary directory, and
// a descriptor they opened, to a memory volume; everything else goes on as
// before (and the IO guard, ./io-guard, sees it).

const require = createRequire(import.meta.url);

// Functions whose first argument is a path.
const pathFunctions = [
  "access",
  "appendFile",
  "chmod",
  "chown",
  "createReadStream",
  "createWriteStream",
  "exists",
  "lchown",
  "lstat",
  "lutimes",
  "mkdir",
  "mkdtemp",
  "open",
  "opendir",
  "readFile",
  "readdir",
  "readlink",
  "realpath",
  "rm",
  "rmdir",
  "stat",
  "statfs",
  "truncate",
  "unlink",
  "unwatchFile",
  "utimes",
  "watch",
  "watchFile",
  "writeFile",
];
// Functions whose first two arguments are paths.
const twoPathFunctions = ["copyFile", "cp", "link", "rename", "symlink"];
// Functions whose first argument is a descriptor.
const descriptorFunctions = [
  "close",
  "fchmod",
  "fchown",
  "fdatasync",
  "fstat",
  "fsync",
  "ftruncate",
  "futimes",
  "read",
  "readv",
  "write",
  "writev",
];
// memfs hands out descriptors from the top of the 31-bit range down.
const isMemoryDescriptor = (fd: unknown) => typeof fd === "number" && fd >= 2 ** 30;

/** Sends `real[name]` to `fake()[name]` for the calls `useMemory` picks. */
const route = (
  real: Record<string, unknown>,
  fake: () => Record<string, unknown>,
  name: string,
  useMemory: (args: unknown[]) => boolean
) => {
  const original = real[name];
  if (typeof original !== "function") return;
  Object.defineProperty(real, name, {
    configurable: true,
    writable: true,
    value: standIn(original, function (this: unknown, ...args: unknown[]) {
      if (!useMemory(args))
        return (original as (...a: unknown[]) => unknown).apply(this, args);
      const memory = fake();
      return (memory[name] as (...a: unknown[]) => unknown).apply(memory, args);
    }),
  });
};

/** Puts the temporary directory in memory for the rest of this test file. */
export function keepTemporaryFilesInMemory() {
  const fs = require("node:fs") as typeof import("node:fs") & Record<string, unknown>;
  const fsPromises = fs.promises as unknown as Record<string, unknown>;
  const os = require("node:os") as typeof import("node:os");
  const roots = [os.tmpdir(), fs.realpathSync(os.tmpdir())];
  // Made at the first use: most files never touch the temporary directory,
  // and loading memfs costs each file that does about 60 ms.
  type Memory = Record<string, unknown> & { promises: Record<string, unknown> };
  let made: Memory | undefined;
  const memory = () => {
    if (made) return made;
    const { Volume, createFsFromVolume } = require("memfs") as typeof import("memfs");
    const volume = new Volume();
    for (const root of roots) volume.mkdirSync(root, { recursive: true });
    made = createFsFromVolume(volume) as unknown as Memory;
    // A directory's random name comes from the seeded stream of temporary
    // names (./seeded-random), drawn when it is asked for.
    const volumeFs = made;
    const mkdtempSync = volumeFs.mkdtempSync as (...args: unknown[]) => string;
    volumeFs.mkdtempSync = (...args: unknown[]) =>
      namingTemporaryFiles(() => mkdtempSync.apply(volumeFs, args));
    volumeFs.mkdtemp = (prefix: unknown, options: unknown, callback?: unknown) => {
      const done = (typeof options === "function" ? options : callback) as (
        error: unknown,
        path?: string
      ) => void;
      try {
        const path = (volumeFs.mkdtempSync as (...args: unknown[]) => string)(
          prefix,
          typeof options === "function" ? undefined : options
        );
        queueMicrotask(() => done(null, path));
      } catch (error) {
        queueMicrotask(() => done(error));
      }
    };
    volumeFs.promises.mkdtemp = async (prefix: unknown, options: unknown) =>
      (volumeFs.mkdtempSync as (...args: unknown[]) => string)(prefix, options);
    return made;
  };
  const memoryPromises = () => memory().promises;

  const inTemporary = (path: unknown) => {
    const text =
      typeof path === "string"
        ? path
        : path instanceof URL
          ? path.pathname
          : Buffer.isBuffer(path)
            ? path.toString()
            : undefined;
    return (
      text !== undefined &&
      roots.some((root) => text === root || text.startsWith(`${root}/`))
    );
  };

  for (const name of pathFunctions) {
    const byPath = (args: unknown[]) => inTemporary(args[0]);
    route(fs, memory, name, byPath);
    route(fs, memory, `${name}Sync`, byPath);
    route(fsPromises, memoryPromises, name, byPath);
  }
  for (const name of twoPathFunctions) {
    const byPaths = (args: unknown[]) => {
      // A relative symlink target is read from the link's own directory.
      const source =
        name === "symlink" &&
        typeof args[0] === "string" &&
        typeof args[1] === "string" &&
        !isAbsolute(args[0])
          ? resolve(dirname(args[1]), args[0])
          : args[0];
      const [from, to] = [inTemporary(source), inTemporary(args[1])];
      if (from !== to)
        throw new Error(
          `${name} between the temporary directory (in memory) and the disk: ${String(args[0])} -> ${String(args[1])}`
        );
      return from;
    };
    route(fs, memory, name, byPaths);
    route(fs, memory, `${name}Sync`, byPaths);
    route(fsPromises, memoryPromises, name, byPaths);
  }
  for (const name of descriptorFunctions) {
    const byDescriptor = (args: unknown[]) => isMemoryDescriptor(args[0]);
    route(fs, memory, name, byDescriptor);
    route(fs, memory, `${name}Sync`, byDescriptor);
  }
  syncBuiltinESMExports();
}
