// What Slack calls people and channels, kept on disk (<data>/slack-names.json, as chat/names.rs keeps it) so the
// admin API never waits on Slack for a name: a name not known yet answers null at once, is fetched in the background,
// and `onLearn` tells the pages to read again (once per burst). Failed lookups are not tried again for a while.
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { Clock, Effect, Exit, FiberSet, Scope } from "effect";
import { liveClock } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { Person } from "../sessions/chat.ts";

const RETRY_FAILED_MS = 10 * 60_000;

/// A key's entry: a person, a channel's name (null: a direct message, known to have none), when it was learned.
type Entry = { person?: Person; channel?: string | null; at: number };

export type NameBookOptions = { saveAfterMs?: number; learnAfterMs?: number; clock?: Clock.Clock };

export class NameBook {
  readonly path: string;
  private entries = new Map<string, Entry>();
  private pending = new Set<string>();
  private failed = new Map<string, number>();
  private saving = false;
  private learning = false;
  private listener: () => void = () => {};
  private saveAfterMs: number;
  private learnAfterMs: number;
  private scope: Scope.Closeable;
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  private closed = false;
  private clock: Clock.Clock;

  constructor(path: string, options: NameBookOptions = {}) {
    this.path = path;
    this.saveAfterMs = options.saveAfterMs ?? 2000;
    this.learnAfterMs = options.learnAfterMs ?? 200;
    let text: string | null = null;
    try {
      text = readFileSync(path, "utf8");
    } catch {}
    if (text !== null) {
      try {
        const kept = JSON.parse(text);
        if (kept === null || typeof kept !== "object" || Array.isArray(kept)) throw new Error("not an object");
        for (const [key, entry] of Object.entries(kept)) this.entries.set(key, entry as Entry);
      } catch (error) {
        log.warn("slack", "slack names file unreadable; starting empty", { error: (error as Error).message });
      }
    }
    this.clock = options.clock ?? liveClock;
    this.scope = Effect.runSync(Scope.make());
    const run = Effect.runSync(Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope));
    this.run = (effect) => run(effect.pipe(Effect.provideService(Clock.Clock, this.clock)));
  }

  /// Called (once per burst) after names were learned, so pages read what shows them again.
  onLearn(listener: () => void) {
    this.listener = listener;
  }

  person(key: string, fetch: () => Promise<Person | null>): Person | null {
    const known = this.entries.get(key)?.person ?? null;
    if (known === null) this.learn(key, async () => {
      const person = await fetch();
      return person === null ? null : { person, at: this.clock.currentTimeMillisUnsafe() };
    });
    return known;
  }

  /// A channel's name; null for a direct message (known) or not known yet.
  channel(key: string, fetch: () => Promise<string | null>): string | null {
    const known = this.entries.get(key)?.channel;
    if (known === undefined) this.learn(key, async () => ({ channel: await fetch(), at: this.clock.currentTimeMillisUnsafe() }));
    return known ?? null;
  }

  /// Ends its timers; what was learned and not yet saved is saved now.
  async close() {
    if (this.closed) return;
    this.closed = true;
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
    if (this.saving) this.save();
  }

  private learn(key: string, fetch: () => Promise<Entry | null>) {
    if (this.closed || this.pending.has(key) || (this.failed.get(key) ?? 0) > this.clock.currentTimeMillisUnsafe()) return;
    this.pending.add(key);
    void fetch()
      .catch(() => null)
      .then((entry) => {
        this.pending.delete(key);
        if (entry === null) {
          this.failed.set(key, this.clock.currentTimeMillisUnsafe() + RETRY_FAILED_MS);
          return;
        }
        const merged = this.entries.get(key) ?? { at: 0 };
        if (entry.person !== undefined) merged.person = entry.person;
        if (entry.channel !== undefined) merged.channel = entry.channel;
        merged.at = entry.at;
        this.entries.set(key, merged);
        this.later();
      });
  }

  private later() {
    if (this.closed) return;
    if (!this.learning) {
      this.learning = true;
      this.after(this.learnAfterMs, () => {
        this.learning = false;
        this.listener();
      });
    }
    if (!this.saving) {
      this.saving = true;
      this.after(this.saveAfterMs, () => this.save());
    }
  }

  private after(ms: number, f: () => void) {
    void this.run(Effect.sleep(ms).pipe(Effect.andThen(Effect.sync(f)))).catch(() => {});
  }

  private save() {
    this.saving = false;
    const tmp = this.path.replace(/\.json$/, "") + ".json.tmp";
    try {
      writeFileSync(tmp, JSON.stringify(Object.fromEntries(this.entries)));
      renameSync(tmp, this.path);
    } catch (error) {
      log.warn("slack", "cannot save slack names", { error: (error as Error).message });
    }
  }
}
