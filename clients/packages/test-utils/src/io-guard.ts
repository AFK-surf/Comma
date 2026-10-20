import { createRequire, syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { afterAll, beforeAll, expect } from "vitest";

// Real IO a unit test file does: sockets (servers, clients, fetch), child
// processes, file reads and writes, timers on the machine's clock. With
// DETERMINISM_IO_REPORT naming a JSONL file, each test file appends what it
// did, to find the files still to move onto scripted cores and fake timers.
// A file that forbids real IO (`forbidRealIo`, as fake timers that step when
// idle need) fails at the first.

const require = createRequire(import.meta.url);
const repository = resolve(import.meta.dirname, "../../../..");
const stateKey = Symbol.for("comma.test.ioGuard");
// The guard's state lives on the global object, and its functions are
// watched once per process: test files that share a process (`isolate:
// false`) load the setup files, and this module with them, again for each
// file, and a second watch would wrap the fake clock's timers
// (test-clock.ts), installed after the first, as real ones.
type GuardState = {
  watched: boolean;
  /** From `forbidRealIo` on, real IO fails the test that does it. */
  forbidden: boolean;
  /** True while the guard writes its own report. */
  reporting: boolean;
  counts: Map<string, number>;
  /** The tests that did each kind of IO; "" for the file's own hooks. */
  tests: Map<string, Set<string>>;
};
const state = ((globalThis as { [stateKey]?: GuardState })[stateKey] ??= {
  watched: false,
  forbidden: false,
  reporting: false,
  counts: new Map(),
  tests: new Map(),
});

/** From now on in this file, real IO fails the test that does it. */
export function forbidRealIo() {
  state.forbidden = true;
}

// The report's own write, kept before the file system is watched.
const appendFileSync = (
  require("node:fs") as typeof import("node:fs")
).appendFileSync.bind(null);

const note = (kind: string) => {
  if (state.reporting) return;
  if (state.forbidden)
    throw new Error(
      `Real IO (${kind}) in a test file that forbids it: its fake timers step whenever the test waits, and an IO callback still on its way would let them run ahead.`
    );
  state.counts.set(kind, (state.counts.get(kind) ?? 0) + 1);
  const test = expect.getState().currentTestName ?? "";
  state.tests.set(kind, (state.tests.get(kind) ?? new Set()).add(test));
};

/**
 * `replacement`, carrying `original`'s own properties: `util.promisify.custom`
 * (`execFile`, `setTimeout`, `exists` resolve with what their own promise
 * form gives, `{ stdout, stderr }` for one) and any other a caller reads.
 */
export function standIn<F extends (...args: never[]) => unknown>(
  original: unknown,
  replacement: F
): F {
  for (const key of Reflect.ownKeys(original as object)) {
    if (key === "length" || key === "name" || key === "prototype") continue;
    Object.defineProperty(
      replacement,
      key,
      Object.getOwnPropertyDescriptor(original as object, key)!
    );
  }
  return replacement;
}

function wrap<T extends object>(target: T, name: keyof T & string, kind: string) {
  const original = target[name] as unknown;
  if (typeof original !== "function") return;
  Object.defineProperty(target, name, {
    configurable: true,
    writable: true,
    value: standIn(original, function (this: unknown, ...args: unknown[]) {
      note(kind);
      return (original as (...a: unknown[]) => unknown).apply(this, args);
    }),
  });
}

/**
 * Watches the file's real IO: records it into DETERMINISM_IO_REPORT when set,
 * and fails it once the file forbids it.
 */
export function watchRealIo() {
  const report = process.env.DETERMINISM_IO_REPORT;
  // Each test file counts its own IO, whether or not it shares the process.
  let file = "";
  beforeAll(() => {
    file = expect.getState().testPath ?? "";
    state.counts.clear();
    state.tests.clear();
  });
  afterAll(() => {
    if (!report) return;
    state.reporting = true;
    appendFileSync(
      report,
      `${JSON.stringify({
        file,
        io: Object.fromEntries(state.counts),
        tests: Object.fromEntries(
          [...state.tests].map(([kind, names]) => [kind, [...names]])
        ),
      })}\n`
    );
    state.reporting = false;
  });
  if (state.watched) return;
  state.watched = true;
  const net = require("node:net") as typeof import("node:net");
  const tls = require("node:tls") as typeof import("node:tls");
  const dgram = require("node:dgram") as typeof import("node:dgram");
  const childProcess =
    require("node:child_process") as typeof import("node:child_process");
  const fs = require("node:fs") as typeof import("node:fs");
  wrap(net.Socket.prototype, "connect", "socket-connect");
  wrap(net.Server.prototype, "listen", "server-listen");
  wrap(tls, "connect", "tls-connect");
  wrap(dgram, "createSocket", "udp");
  for (const name of [
    "spawn",
    "spawnSync",
    "exec",
    "execSync",
    "execFile",
    "execFileSync",
    "fork",
  ] as const)
    wrap(childProcess, name, "child-process");
  const temporary = tmpdir();
  // File writes, in the callback, sync and promise forms.
  const writers = [
    "writeFile",
    "appendFile",
    "mkdir",
    "mkdtemp",
    "rm",
    "rmdir",
    "unlink",
    "rename",
    "copyFile",
    "cp",
    "truncate",
  ];
  const writeTargets: [object, string][] = [
    ...writers.flatMap((name): [object, string][] => [
      [fs, name],
      [fs, `${name}Sync`],
      [fs.promises, name],
    ]),
    [fs, "createWriteStream"],
  ];
  for (const [target, name] of writeTargets) {
    const original = (target as Record<string, unknown>)[name];
    if (typeof original !== "function") continue;
    Object.defineProperty(target, name, {
      configurable: true,
      writable: true,
      value: standIn(original, (...args: unknown[]) => {
        note(String(args[0]).startsWith(temporary) ? "fs-write-tmp" : "fs-write");
        return (original as (...a: unknown[]) => unknown)(...args);
      }),
    });
  }
  // File reads a test makes (not the modules it imports, nor dependencies).
  const readers = [
    [fs, "readFile"],
    [fs, "readFileSync"],
    [fs, "createReadStream"],
    [fs, "readdir"],
    [fs, "readdirSync"],
    [fs.promises, "readFile"],
    [fs.promises, "readdir"],
  ] as const;
  for (const [target, name] of readers) {
    const original = (target as Record<string, unknown>)[name] as (
      ...a: unknown[]
    ) => unknown;
    Object.defineProperty(target, name, {
      configurable: true,
      writable: true,
      value: standIn(original, (...args: unknown[]) => {
        const path = String(args[0]);
        // The repository's files are the test's fixed inputs, as its code is.
        if (
          expect.getState().currentTestName &&
          !path.includes("/node_modules/") &&
          !path.startsWith(`${repository}/`)
        )
          note(path.startsWith(temporary) ? "fs-read-tmp" : "fs-read");
        return original(...args);
      }),
    });
  }
  for (const name of ["setTimeout", "setInterval"] as const) {
    const original = globalThis[name] as unknown as (...a: unknown[]) => unknown;
    Object.defineProperty(globalThis, name, {
      configurable: true,
      writable: true,
      value: standIn(original, (callback: unknown, ms?: number, ...rest: unknown[]) => {
        if ((ms ?? 0) > 0) note("real-timer");
        return original(callback, ms, ...rest);
      }),
    });
  }
  // `import { readFile } from "node:fs"` sees the watched functions too.
  syncBuiltinESMExports();
}
