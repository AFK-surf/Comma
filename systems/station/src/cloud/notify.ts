// What the chats' people hear about while no client of theirs runs (admin/notify.rs and the station process's
// notify.rs, docs/notifications.md): noticed from the store's changes as they come, worked out by the readers
// (src/read/notices.ts), gathered over a second and posted to the control plane (still.fail cloud's
// `/v1/stations/notify`, Comma's `/v1/comma/stations/notify`: ControlPlane.notify), signed with the station's key, which
// pushes them to people's devices. Only what happens from now on is noticed. A batch that cannot be
// sent is dropped; an older cloud (404) has no pushes.
import { Clock, Effect, Exit, FiberSet, Scope } from "effect";
import { stationLang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import type { Readers } from "../read/pool.ts";
import type { Notice } from "../read/notices.ts";
import type { Store } from "../store/store.ts";
import type { Cloud } from "./state.ts";
import { liveClock } from "../ops/fibers.ts";

/// Notices wait this long to go out together; at most this many in one post (the cloud takes no more).
const GATHER_MS = 1_000;
const MAX_BATCH = 50;

export class Notifier {
  private since: number;
  /// Each session's last turn noticed (when it ended), so one turn is noticed once.
  private ended = new Map<string, number>();
  private waiting: Notice[] = [];
  /// A batch is being gathered (its wait is running).
  private gathering = false;
  /// Runs an effect as a fiber of the notifier's (the wait while a batch gathers): they end at `close`.
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  private scope: Scope.Closeable;
  private stop: () => void;
  private readers: Readers;
  private store: Store;
  private cloud: Cloud;
  /// Where a batch goes (tests give their own); the control plane's by default (`send`).
  post: (notices: Notice[]) => Promise<void>;

  /// `send`: a batch to the control plane; `clock`: the clock a batch gathers on (a TestClock in tests).
  constructor(store: Store, readers: Readers, cloud: Cloud, send: (notices: Notice[]) => Promise<void>, options: { clock?: Clock.Clock } = {}) {
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
    this.since = (options.clock ?? liveClock).currentTimeMillisUnsafe();
    this.store = store;
    this.readers = readers;
    this.cloud = cloud;
    this.post = send;
    this.stop = store.subscribe((change) => {
      if (change.type === "session") this.sessionChanged(change.key);
      else if (change.type === "thread") this.said(change.id, change.entries);
    });
  }

  close() {
    this.stop();
    Effect.runFork(Scope.close(this.scope, Exit.void));
  }

  /// A turn that ended since the last look: its chats hear how. Looked at here first, so most changes ask nothing.
  private sessionChanged(key: string) {
    const ended = this.store.lastTurn(key)?.endedAt;
    if (typeof ended !== "number" || ended < this.since || this.ended.get(key) === ended) return;
    this.ended.set(key, ended);
    this.ask("turnNotices", { key, since: this.since, ended: null, lang: stationLang() });
  }

  /// People's messages and the station's ⚠️ in its own chats.
  private said(thread: number, entries: { kind: string; authorKind: string; text: string | null; at: number }[]) {
    const worth = entries.some((e) => e.kind === "message" && e.at >= this.since && (e.authorKind === "person" || (e.authorKind === "ember" && (e.text ?? "").startsWith("⚠️"))));
    if (worth) this.ask("saidNotices", { thread, entries, since: this.since, lang: stationLang() });
  }

  private ask(op: string, args: unknown) {
    void this.readers.read(op, args, stationLang()).then(
      (text) => {
        const answer = JSON.parse(text);
        this.queue(Array.isArray(answer) ? answer : answer.notices);
      },
      (error) => log.warn("notify", "a notice could not be made", { error: (error as Error).message }),
    );
  }

  private queue(notices: Notice[]) {
    if (notices.length === 0) return;
    this.waiting.push(...notices);
    if (this.gathering) return;
    this.gathering = true;
    void this.run(Effect.sleep(GATHER_MS).pipe(Effect.andThen(Effect.sync(() => this.gathered())))).catch(() => {});
  }

  private gathered() {
    this.gathering = false;
    const batch = this.waiting.splice(0, MAX_BATCH);
    if (this.waiting.length > 0) this.queue(this.waiting.splice(0));
    if (this.cloud.removed() || this.cloud.state === null) return;
    this.post(batch).then(
      () => log.info("notify", "notices sent", { n: batch.length }),
      (error) => log.warn("notify", "notices dropped", { n: batch.length, error: (error as Error).message }),
    );
  }
}
