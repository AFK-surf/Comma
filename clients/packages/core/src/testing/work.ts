// The work a test's core did, counted by topic (core-kernel's meter.ts), and the rule every test's core is held to: a
// change costs what changed. When a test ends, its core must not have
// - sent a list of objects with no spec saying how its items are known (`TOPIC_SPECS`: a key, or by place),
// - made again, in one new value of a topic, more than one item of a list equal to the one in its last value (its
//   source makes the list again rather than keeping it: core-kernel keep.ts; one item can come back equal through a
//   change of its own),
// - checked through the same schema again while a topic computed (what the core made itself was checked as it came
//   in; a first read from the disk may come in while a topic computes, once),
// - written a document or a meta value as the bytes it held already.
// With `CORE_WORK_REPORT` naming a JSONL file, each test also appends its counts there.
import { appendFileSync } from "node:fs";
import { schemaChecks } from "@comma/chat-contract";
import { noWork, shared, type Meter, type Topic, type Work } from "@comma/core-kernel";
import { expect, onTestFinished } from "vitest";

/** What a topic's emissions took, added up. */
export type TopicWork = Omit<Work, "unkeyed" | "within" | "remadeIn"> & {
  emissions: number;
  /** Bytes of what went out. */
  bytes: number;
  /** Lists sent with no spec for their items. */
  unkeyed: Set<string>;
  /** Items made again, by the place of their list. */
  remadeIn: Map<string, number>;
  /** Lists of which one emission made more than one item again, with the most it made. */
  remadeLists: Map<string, number>;
  /** Schema checks while it computed, and those through a schema that checked while it computed before. */
  checks: number;
  checkedAgain: number;
};

/** What the documents a table keeps took to write, added up; `same`: writes of the bytes it held. */
export type TableWrites = { writes: number; bytes: number; same: number };

/** The meters of the cores live now: a schema check is counted for the topic each of them computes. */
const live = new Set<WorkMeter>();
schemaChecks.watch = (schema) => {
  for (const meter of live) meter.checkedWhileComputing(schema);
};

export class WorkMeter {
  readonly topics = new Map<string, TopicWork>();
  readonly tables = new Map<string, TableWrites>();
  /** What `share` compared while this meter counted. */
  shared = 0;
  /** What `madeOnce` looked up while this meter counted. */
  looked = 0;
  #computing: string | null = null;
  #sharedAt = shared.compared;
  #lookedAt = shared.looked;
  readonly #during = new Set<WorkMeter>();

  /** A topic's work so far (none yet: all zero). */
  topic(name: string): TopicWork {
    let t = this.topics.get(name);
    if (!t) {
      const { unkeyed: _, within: __, remadeIn: ___, ...zero } = noWork();
      t = {
        ...zero,
        emissions: 0,
        bytes: 0,
        unkeyed: new Set(),
        remadeIn: new Map(),
        remadeLists: new Map(),
        checks: 0,
        checkedAgain: 0,
      };
      this.topics.set(name, t);
    }
    return t;
  }

  /** The meter a core counts through (`CoreOptions.meter`): this one, and those `during` opened. */
  get counting(): Meter {
    live.add(this);
    const all = () => [this, ...this.#during];
    return {
      emitted: (topic, work, bytes) => {
        for (const m of all()) m.#emitted(topic, work, bytes);
      },
      remade: (topic, work) => {
        for (const m of all()) m.#remade(topic, work);
      },
      wrote: (table, bytes, same) => {
        for (const m of all()) m.#wrote(table, bytes, same);
      },
      computing: (topic) => {
        for (const m of all()) m.#computing = topic?.topic ?? null;
      },
    };
  }

  /** What the core did while `run` ran. */
  async during(run: () => Promise<void> | void): Promise<WorkMeter> {
    const since = new WorkMeter();
    this.#during.add(since);
    try {
      await run();
    } finally {
      this.#during.delete(since);
      since.settle();
    }
    return since;
  }

  /** Counts what `share` compared and `madeOnce` looked up to now. */
  settle(): void {
    this.shared += shared.compared - this.#sharedAt;
    this.#sharedAt = shared.compared;
    this.looked += shared.looked - this.#lookedAt;
    this.#lookedAt = shared.looked;
  }

  checkedWhileComputing(schema: object): void {
    if (this.#computing === null) return;
    const t = this.topic(this.#computing);
    t.checks++;
    let seen = this.#checked.get(this.#computing);
    if (!seen) this.#checked.set(this.#computing, (seen = new WeakSet()));
    if (seen.has(schema)) t.checkedAgain++;
    seen.add(schema);
    for (const m of this.#during) m.checkedWhileComputing(schema);
  }

  /** The schemas that checked while each topic computed. */
  readonly #checked = new Map<string, WeakSet<object>>();

  #emitted(topic: Topic, work: Work, bytes: number): void {
    const t = this.topic(topic.topic);
    t.emissions++;
    t.bytes += bytes;
    t.compared += work.compared;
    t.rebuilt += work.rebuilt;
    t.keys += work.keys;
    t.matched += work.matched;
    t.weighed += work.weighed;
    for (const path of work.unkeyed) t.unkeyed.add(path);
  }

  /**
   * Another account signed in (or none is): a topic's next value is that account's, not its last one made again, even
   * where the two are equal.
   */
  accountChanged(): void {
    for (const name of this.topics.keys()) this.#newAccount.add(name);
    for (const m of this.#during) m.accountChanged();
  }

  readonly #newAccount = new Set<string>();

  #remade(topic: Topic, work: Work): void {
    if (this.#newAccount.delete(topic.topic)) return;
    const t = this.topic(topic.topic);
    t.rebuiltItems += work.rebuiltItems;
    for (const [path, n] of Object.entries(work.remadeIn)) {
      t.remadeIn.set(path, (t.remadeIn.get(path) ?? 0) + n);
      if (n > 1) t.remadeLists.set(path, Math.max(n, t.remadeLists.get(path) ?? 0));
    }
  }

  #wrote(table: string, bytes: number, same: boolean): void {
    const t = this.tables.get(table) ?? { writes: 0, bytes: 0, same: 0 };
    t.writes++;
    t.bytes += bytes;
    if (same) t.same++;
    this.tables.set(table, t);
  }

  /** What breaks the rule above, one line each; empty when nothing does. */
  waste(): string[] {
    const out: string[] = [];
    for (const [name, t] of this.topics) {
      for (const path of t.unkeyed)
        out.push(
          `${name}: the list at ${path} has no spec (TOPIC_SPECS: key or byIndex)`
        );
      for (const [path, n] of t.remadeLists)
        out.push(
          `${name}: ${n} items of ${path} made again equal to those of its last value`
        );
      if (t.checkedAgain > 0)
        out.push(`${name}: ${t.checkedAgain} schema check(s) again while it computed`);
    }
    for (const [table, t] of this.tables)
      if (t.same > 0) out.push(`${table}: ${t.same} write(s) of the bytes it held`);
    return out;
  }

  report(): unknown {
    this.settle();
    return {
      topics: Object.fromEntries(
        [...this.topics].map(([name, t]) => [
          name,
          {
            ...t,
            unkeyed: [...t.unkeyed],
            remadeIn: Object.fromEntries(t.remadeIn),
            remadeLists: Object.fromEntries(t.remadeLists),
          },
        ])
      ),
      tables: Object.fromEntries(this.tables),
      shared: this.shared,
      looked: this.looked,
    };
  }

  /** The core is gone: its checks are no longer counted. */
  close(): void {
    live.delete(this);
  }
}

/**
 * Holds a test's core to the rule above when the test ends, unless it failed already; with `CORE_WORK_REPORT` set,
 * appends its counts to that file first.
 */
export function holdToWork(meter: WorkMeter): void {
  const file = process.env.CORE_WORK_REPORT;
  const state = expect.getState();
  // Written past the test file's IO guard (test-utils io-guard.ts), when there is one: a report, not the test's IO.
  const append =
    (
      globalThis as {
        [key: symbol]:
          | { appendReport?: (file: string, text: string) => void }
          | undefined;
      }
    )[Symbol.for("comma.test.ioGuard")]?.appendReport ?? appendFileSync;
  onTestFinished((context) => {
    meter.close();
    if (file)
      append(
        file,
        `${JSON.stringify({ file: state.testPath, test: state.currentTestName, ...(meter.report() as object) })}\n`
      );
    if (context.task.result?.state === "fail") return;
    const waste = meter.waste();
    if (waste.length > 0)
      throw new Error(
        `The core did work that does not follow from what changed (testing/work.ts):\n${waste.join("\n")}`
      );
  });
}
