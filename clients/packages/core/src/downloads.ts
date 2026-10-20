// Files of any size downloaded to the device (`download`, `downloads.*`): a message's attachment, an agent's blob or an
// image uploaded to the group, read for the account's session into the host's storage (DownloadPorts) and kept there
// for the next showing. A file is visible only once it is whole and, when its source names one, matches the size and
// SHA-256 it was asked for; one that does not is removed and said unavailable. Each account has a directory of its
// own: signed out, or signed in as another account, the others' are removed. An account keeps at most 256 MB, the
// least recently shown removed first.
//
// Bounds: two downloads at a time, one per file however many surfaces show it; no automatic retry (the person's next
// action starts it again); progress is said at most as often as the topic emits.
import { CoreError, type Topic, type Value, utf8 } from "@comma/core-kernel";
import { Effect, type Fiber, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import type { DownloadValue, FileSource } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { fileRequest, fileSourceSchema } from "./files.ts";
import type { DownloadPorts } from "./host.ts";

const DOC = "downloads";
const KEPT_BYTES = 256 * 1024 * 1024;

/** What an account keeps, by file: where it is, its size, and when it was last shown. */
type Kept = Record<string, { path: string; size: number; usedAt: number }>;

const expectSchema = z.object({
  size: z.number().int().nonnegative(),
  sha256: z.string().regex(/^[0-9a-f]{64}$/),
});

type Running = {
  received: number;
  total: number | null;
  fiber: Fiber.Fiber<unknown, unknown>;
};

export class Downloads {
  readonly #ctx: Ctx;
  readonly #ports: DownloadPorts | undefined;
  readonly #running = new Map<string, Running>();
  readonly #failed = new Map<string, "network" | "unavailable">();
  /** How many times each file was asked to start or stop (`asked`): a surface tells the state its call brought. */
  readonly #asked = new Map<string, number>();
  readonly #permits = Semaphore.makeUnsafe(2);
  #accountKey: string | null | undefined = undefined;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#ports = ctx.host.downloads;
    const { kernel } = ctx;
    kernel.source("download", {
      start: (topic) => this.#touch(topic),
      stop: () => undefined,
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const running of this.#running.values()) ctx.runner.interrupt(running.fiber);
      this.#running.clear();
      this.#failed.clear();
      this.#asked.clear();
      this.#changed();
      // Nothing one account downloaded stays for another, or once signed out.
      const ports = this.#ports;
      if (ports)
        ctx.runner.fork(
          Effect.ignore(ports.retain(ctx.session.current()?.dbName ?? null))
        );
    });
    kernel.calls({
      "downloads.start": {
        run: (p) => {
          const input = parse(p);
          return Effect.sync(() => {
            const asked = this.#ask(fileKey(input.source));
            this.#start(input.source, input.name, input.expect);
            return asked;
          });
        },
      },
      "downloads.cancel": {
        run: (p) => {
          const { source } = parse(p);
          return Effect.sync(() => {
            const key = fileKey(source);
            const asked = this.#ask(key);
            const running = this.#running.get(key);
            if (running) {
              this.#running.delete(key);
              this.#ctx.runner.interrupt(running.fiber);
              this.#changed();
            }
            return asked;
          });
        },
      },
    });
  }

  /** Counts a call on the file's state; the count the caller hears. */
  #ask(key: string): { asked: number } {
    const asked = (this.#asked.get(key) ?? 0) + 1;
    this.#asked.set(key, asked);
    this.#changed();
    return { asked };
  }

  #kept(account: Account | null): Kept {
    return account?.doc<Kept>(DOC)?.value ?? {};
  }

  #value(topic: Topic): DownloadValue {
    const source = topicSource(topic);
    const key = source ? fileKey(source) : "";
    const base = {
      received: 0,
      total: null,
      path: null,
      failure: null,
      asked: this.#asked.get(key) ?? 0,
    };
    if (!source) return { ...base, status: "failed", failure: "unavailable" };
    const kept = this.#kept(this.#ctx.session.current())[key];
    if (kept)
      return {
        ...base,
        status: "ready",
        received: kept.size,
        total: kept.size,
        path: kept.path,
      };
    const running = this.#running.get(key);
    if (running)
      return {
        ...base,
        status: "downloading",
        received: running.received,
        total: running.total,
      };
    const failure = this.#failed.get(key);
    if (failure) return { ...base, status: "failed", failure };
    return { ...base, status: "idle" };
  }

  /** A kept file shown again is the most recently used. */
  #touch(topic: Topic): void {
    const source = topicSource(topic);
    const account = this.#ctx.session.current();
    if (!source || !account) return;
    const key = fileKey(source);
    const kept = this.#kept(account);
    const entry = kept[key];
    if (entry)
      account.putDoc(
        DOC,
        { ...kept, [key]: { ...entry, usedAt: this.#ctx.now() } },
        this.#ctx.now()
      );
  }

  #start(
    source: FileSource,
    name: string,
    expect: z.output<typeof expectSchema> | undefined
  ): void {
    const ctx = this.#ctx;
    const ports = this.#ports;
    const account = ctx.session.current();
    const key = fileKey(source);
    if (!account || this.#running.has(key) || this.#kept(account)[key]) return;
    this.#failed.delete(key);
    if (!ports) {
      this.#failed.set(key, "unavailable");
      this.#changed();
      return;
    }
    const path = `${account.dbName}/${key}/${safeName(name)}`;
    const request = fileRequest(source);
    const running: Omit<Running, "fiber"> & { fiber?: Running["fiber"] } = {
      received: 0,
      total: expect?.size ?? null,
    };
    const download = Effect.gen({ self: this }, function* () {
      const opened = yield* ports.open(
        {
          method: request.method,
          path: request.path,
          headers: "body" in request ? [["content-type", "application/json"]] : [],
          body: "body" in request ? utf8(JSON.stringify(request.body)) : null,
          lease: account.lease,
        },
        path
      );
      if (opened.status === 401) ctx.session.rejected(account.lease, 401);
      if (opened.status !== 200)
        return [403, 404, 410].includes(opened.status) ? "unavailable" : "network";
      running.total = expect?.size ?? opened.total;
      // Given up (cancelled, signed out), nothing of it stays.
      const written = yield* Effect.onInterrupt(
        Effect.gen({ self: this }, function* () {
          for (;;) {
            const step = yield* ports.step(opened.id);
            if ("sha256" in step) return step;
            running.received = step.received;
            this.#changed();
          }
        }),
        () => Effect.ignore(ports.close(opened.id))
      );
      if (
        expect &&
        (written.size !== expect.size || written.sha256 !== expect.sha256)
      ) {
        yield* Effect.ignore(ports.remove(path));
        return "unavailable";
      }
      this.#keep(account, key, path, written.size);
      return null;
    });
    const run = this.#permits.withPermits(1)(
      download.pipe(
        Effect.orElseSucceed(() => "network" as const),
        Effect.tap((failure) =>
          Effect.sync(() => {
            if (this.#running.get(key) !== running) return;
            this.#running.delete(key);
            if (failure) this.#failed.set(key, failure);
            this.#changed();
          })
        )
      )
    );
    this.#running.set(key, running as Running);
    running.fiber = ctx.runner.fork(run);
    this.#changed();
  }

  /** The file is whole: kept, and the least recently shown removed while the account keeps more than it may. */
  #keep(account: Account, key: string, path: string, size: number): void {
    if (this.#ctx.session.current() !== account) return;
    const now = this.#ctx.now();
    const kept: Kept = { ...this.#kept(account), [key]: { path, size, usedAt: now } };
    let total = Object.values(kept).reduce((sum, entry) => sum + entry.size, 0);
    const oldest = Object.entries(kept)
      .filter(([other]) => other !== key)
      .toSorted(([, a], [, b]) => a.usedAt - b.usedAt);
    for (const [other, entry] of oldest) {
      if (total <= KEPT_BYTES) break;
      delete kept[other];
      total -= entry.size;
      this.#ctx.runner.fork(
        Effect.ignore(this.#ports!.remove(entry.path.replace(/\/[^/]*$/, "")))
      );
    }
    account.putDoc(DOC, kept, now);
  }

  #changed(): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "download") store.invalidate(topic);
  }
}

function parse(p: unknown): {
  source: FileSource;
  name: string;
  expect: z.output<typeof expectSchema> | undefined;
} {
  const parsed = z
    .object({
      source: fileSourceSchema,
      name: z.string().max(512).optional(),
      expect: expectSchema.optional(),
    })
    .safeParse(p);
  if (!parsed.success || parsed.data.source.source === "avatar")
    throw CoreError.invalid("not a file to download");
  return {
    source: parsed.data.source,
    name: parsed.data.name ?? "",
    expect: parsed.data.expect,
  };
}

/** The topic's `source`: the file source as JSON. */
function topicSource(topic: Topic): FileSource | null {
  try {
    const parsed = fileSourceSchema.safeParse(JSON.parse(String(topic.source)));
    return parsed.success && parsed.data.source !== "avatar" ? parsed.data : null;
  } catch {
    return null;
  }
}

/** Which file a source names, the same for every surface: a blob by its content, anything else by where it is. */
export function fileKey(source: FileSource): string {
  switch (source.source) {
    case "agent-blob":
      return `b${source.blobRef.hash}`;
    case "attachment":
      return `a${hash(`${source.group}\n${source.conversation}\n${source.message}\n${source.index}`)}`;
    case "group-file":
      return `f${hash(`${source.group}\n${source.path}`)}`;
    case "avatar":
      return `v${hash(source.revision)}`;
  }
}

/** Two 32-bit FNV-1a hashes of `text`, as 16 hex digits: a file name, not a secret. */
function hash(text: string): string {
  let a = 0x811c9dc5;
  let b = 0x01000193 ^ 0x5bd1e995;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    a = Math.imul(a ^ c, 0x01000193) >>> 0;
    b = Math.imul(b ^ c, 0x01000193 + 0x9e3779b1) >>> 0;
  }
  return a.toString(16).padStart(8, "0") + b.toString(16).padStart(8, "0");
}

/** The file's name as it may stand in a path: no separators, no dot-only names. */
function safeName(name: string): string {
  const cleaned = [...name]
    .map((c) => ('/\\:*?"<>|'.includes(c) || c.charCodeAt(0) < 0x20 ? "_" : c))
    .join("")
    .trim()
    .slice(0, 120);
  return cleaned === "" || /^\.+$/.test(cleaned) ? "file" : cleaned;
}
