// The test runner's side of a Node realm (./node-realm.ts): builds the
// realm's entry behind the realm's runtime, starts it as a process of its
// own, and passes the world's calls to it. A test reaches these as browser
// commands (../app-shell/support/world.ts).

import { fork, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { build, type AliasOptions } from "vite";
import type { BrowserCommand } from "vitest/node";
import { routeWorldServer, worldServerOrigin } from "../../vite/app-shell-origin";
import type { NodeRealmCall, NodeRealmReply } from "./node-realm";

type Started = { id: number; info: unknown; delayMs: number };
type Running = {
  process: ChildProcess;
  origin: string;
  calls: Map<number, { resolve(value: unknown): void; reject(error: Error): void }>;
  output: string;
};

/** A distributive `Omit`: each member of the union loses `call`. */
type Uncalled<T> = T extends unknown ? Omit<T, "call"> : never;
export type NodeRealmRequest = Uncalled<NodeRealmCall>;

export function nodeRealmCommands({
  root,
  alias,
}: {
  root: string;
  alias: AliasOptions;
}) {
  const recordPath = (file: string) => {
    const records = path.resolve(root, "e2e/app-shell/records");
    const resolved = path.resolve(records, file);
    if (path.relative(records, resolved).startsWith(".."))
      throw new Error(`A record is a file of e2e/app-shell/records: ${file}`);
    return resolved;
  };
  const built = new Map<string, Promise<string>>();
  const realms = new Map<number, Running>();
  let ids = 0;
  let calls = 0;
  const outDirs: string[] = [];
  process.on("exit", () => {
    for (const realm of realms.values()) realm.process.kill("SIGKILL");
    // The run's builds of its realms' entries go with the run.
    for (const dir of outDirs) rmSync(dir, { recursive: true, force: true });
  });

  // One build of an entry for the run: every test starts a process from it.
  const bundle = (entry: string) => {
    let file = built.get(entry);
    if (!file) {
      const source = path.resolve(root, entry);
      if (path.relative(root, source).startsWith(".."))
        throw new Error(`A realm's entry is a file of the project: ${entry}`);
      const outDir = mkdtempSync(path.join(tmpdir(), "comma-node-realm-"));
      outDirs.push(outDir);
      const virtual = "\0comma-node-realm";
      file = build({
        configFile: false,
        root,
        logLevel: "error",
        resolve: { alias },
        plugins: [
          {
            name: "comma-node-realm-entry",
            resolveId: (id) => (id === "comma-node-realm" ? virtual : undefined),
            // The realm's runtime first: the entry's modules find the routed
            // host functions.
            load: (id) =>
              id === virtual
                ? [
                    `import { serveNodeRealm } from ${JSON.stringify(path.resolve(root, "e2e/ui-runtime/node-realm.ts"))};`,
                    `import start from ${JSON.stringify(source)};`,
                    "void serveNodeRealm(start);",
                  ].join("\n")
                : undefined,
          },
        ],
        ssr: { noExternal: true },
        build: {
          ssr: true,
          outDir,
          emptyOutDir: true,
          minify: false,
          rollupOptions: {
            input: { realm: "comma-node-realm" },
            output: { format: "esm", entryFileNames: "[name].mjs" },
          },
        },
      }).then(() => path.join(outDir, "realm.mjs"));
      built.set(entry, file);
    }
    return file;
  };

  return {
    /** Starts the realm whose entry is `entry` (a path in the project); resolves once its servers listen. */
    nodeRealmStart: async (
      _ctx,
      entry: string,
      options: { name: string; seed?: number; start?: unknown }
    ): Promise<Started> => {
      const file = await bundle(entry);
      const id = (ids += 1);
      const origin = worldServerOrigin(options.name);
      const child = fork(file, [JSON.stringify({ ...options, origin })], {
        stdio: ["ignore", "pipe", "pipe", "ipc"],
      });
      const realm: Running = { process: child, origin, calls: new Map(), output: "" };
      realms.set(id, realm);
      const keep = (chunk: Buffer) => {
        realm.output = (realm.output + chunk.toString()).slice(-4000);
        if (process.env.DEBUG_NODE_REALM) process.stderr.write(chunk);
      };
      child.stdout!.on("data", keep);
      child.stderr!.on("data", keep);
      return new Promise<Started>((resolve, reject) => {
        child.on("exit", (code) => {
          realms.delete(id);
          const error = new Error(
            `The realm ${entry} exited (${code}).\n${realm.output}`
          );
          reject(error);
          for (const call of realm.calls.values()) call.reject(error);
        });
        child.on("message", (message: NodeRealmReply) => {
          if ("ready" in message) {
            if (message.ports.length > 1)
              reject(new Error(`The realm ${entry} listens on more than one port.`));
            routeWorldServer(origin, message.ports[0]);
            resolve({ id, info: message.info, delayMs: message.delayMs });
            return;
          }
          const call = realm.calls.get(message.reply);
          realm.calls.delete(message.reply);
          if (message.error === undefined) call?.resolve(message.value);
          else call?.reject(new Error(message.error));
        });
      });
    },
    /** One call of the world to the realm. */
    nodeRealmCall: (_ctx, id: number, request: NodeRealmRequest) => {
      const realm = realms.get(id);
      if (!realm) throw new Error(`No realm ${id} runs.`);
      return new Promise<unknown>((resolve, reject) => {
        const call = (calls += 1);
        realm.calls.set(call, { resolve, reject });
        realm.process.send({ call, ...request } as NodeRealmCall);
      });
    },
    /** How this run treats the records of the web app's specs: "record" writes them, "check" compares a whole run with them, "" plays them. */
    worldRecordMode: () => process.env.COMMA_WORLD_RECORDS ?? "",
    /** The record `file` (a path in e2e/app-shell/records), or null when there is none. */
    worldRecordRead: async (_ctx, file: string) => {
      const { readFile } = await import("node:fs/promises");
      return readFile(recordPath(file), "utf8").then(
        (text) => JSON.parse(text) as unknown,
        () => null
      );
    },
    /** Every record, as a path in e2e/app-shell/records. */
    worldRecordList: async () => {
      const { readdir } = await import("node:fs/promises");
      const names = await readdir(recordPath("."), { recursive: true }).catch(
        () => [] as string[]
      );
      return names.filter((name) => name.endsWith(".json")).toSorted();
    },
    worldRecordWrite: async (_ctx, file: string, record: unknown) => {
      const { mkdir, writeFile } = await import("node:fs/promises");
      await mkdir(path.dirname(recordPath(file)), { recursive: true });
      await writeFile(recordPath(file), `${JSON.stringify(record, null, 1)}\n`);
    },
    nodeRealmStop: (_ctx, id: number) => {
      const realm = realms.get(id);
      realms.delete(id);
      if (realm) routeWorldServer(realm.origin, undefined);
      realm?.process.removeAllListeners("exit");
      realm?.process.kill("SIGKILL");
    },
  } satisfies Record<string, BrowserCommand<never[]>>;
}

declare module "vitest/browser" {
  interface BrowserCommands {
    nodeRealmStart: (
      entry: string,
      options: { name: string; seed?: number; start?: unknown }
    ) => Promise<Started>;
    nodeRealmCall: (id: number, request: NodeRealmRequest) => Promise<unknown>;
    nodeRealmStop: (id: number) => Promise<void>;
    worldRecordMode: () => Promise<string>;
    worldRecordRead: (file: string) => Promise<unknown>;
    worldRecordList: () => Promise<string[]>;
    worldRecordWrite: (file: string, record: unknown) => Promise<void>;
  }
}
