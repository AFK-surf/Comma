/**
 * The world of one end-to-end test: the realms that make it up (a page, a
 * core worker, a process, the stub server) on one schedule. Left alone, each
 * realm runs on its own time, and what one sends another arrives when the
 * machine delivers it: which runs first differs from run to run. In a world,
 * one realm runs at a time, in an order the world decides:
 *
 * - A realm runs only when the world settles it, to rest: until nothing of it
 *   can run without time moving or a message reaching it.
 * - What a realm sends another is held by the receiver. The world hands the
 *   held messages over in the order they were sent (realms in their fixed
 *   order, each realm's messages in the order it sent them). The receiver
 *   runs a message, and those that follow it to the same realm, then rests.
 * - Time is the world's. It moves only when every realm rests and no message
 *   is on its way, and then to the next time something is due.
 *
 * So what a test observes depends on the code and the order of the realms,
 * not on how long anything took. The world's log is the test's execution
 * record.
 */

/** What a realm tells the world after it ran to rest. */
export type RealmReport = {
  /** The next time something of the realm is due, in world time; null when nothing is. */
  nextDue: number | null;
  /** What it sent other realms since its last report, in the order it sent them. */
  sent: readonly SentMessage[];
};

/** One message a realm sent: the `id`-th it sent `to`, counted from 1. */
export type SentMessage = {
  to: string;
  id: number;
  label: string;
  /** What the receiver needs to find the message on a line that does not count messages (a request, part of a response). */
  detail?: unknown;
};

/** One participant of a world. */
export interface Realm {
  readonly name: string;
  /**
   * Runs what the realm can run at world time `now`, to rest: its timers due
   * by `now`, the messages handed to it, and the work they start. A message
   * that arrives meanwhile is held, not run.
   */
  settle(now: number): Promise<RealmReport>;
  /**
   * Hands the realm message `id` from `from`. Resolves once the realm holds
   * the message (it has arrived, however long that took) and will run it in
   * its next `settle`. `detail` is the sender's, as it reported the message.
   */
  deliver(from: string, id: number, detail?: unknown): Promise<void>;
  /** What the realm is doing, for a failure's report. */
  describe?(): Promise<string> | string;
}

type Envelope = SentMessage & { from: string };

export class World {
  readonly #realms: Realm[];
  readonly #byName: Map<string, Realm>;
  readonly #due = new Map<string, number | null>();
  readonly #unsettled = new Set<string>();
  readonly #inFlight: Envelope[] = [];
  readonly #log: string[] = [];
  // How many messages each realm received.
  readonly #received = new Map<string, number>();
  #now = 0;

  /**
   * `realms` in the order the world runs them when several can run; `now` is
   * the time the world begins at (the time of a realm that ran before it).
   */
  constructor(realms: readonly Realm[], { now = 0 }: { now?: number } = {}) {
    this.#now = now;
    this.#realms = [...realms];
    this.#byName = new Map(realms.map((realm) => [realm.name, realm]));
    if (this.#byName.size !== realms.length)
      throw new Error("Two realms of a world have the same name.");
    for (const realm of realms) this.#unsettled.add(realm.name);
  }

  /** World time, in ms since the world began. */
  now() {
    return this.#now;
  }

  /** Every step the world took, in order: the test's execution record. */
  log(): readonly string[] {
    return this.#log;
  }

  /** A realm that began after the world did (a worker its page started) runs after the others, from now on. */
  join(realm: Realm) {
    if (this.#byName.has(realm.name))
      throw new Error("Two realms of a world have the same name.");
    this.#realms.push(realm);
    this.#byName.set(realm.name, realm);
    this.#unsettled.add(realm.name);
  }

  /** The test did something to `realm` (sent it input, evaluated code in it): it may have work to run. */
  touched(realm: string) {
    this.#realm(realm);
    this.#unsettled.add(realm);
  }

  /** Runs the world at the current time until every realm rests and no message is on its way. */
  async settle(): Promise<void> {
    for (;;) {
      for (const realm of this.#realms) {
        if (!this.#unsettled.delete(realm.name)) continue;
        const report = await realm.settle(this.#now);
        if (report.nextDue !== null && report.nextDue <= this.#now)
          throw new Error(
            `${realm.name} rests at ${this.#now} ms with something due at ${report.nextDue} ms.`
          );
        this.#due.set(realm.name, report.nextDue);
        for (const message of report.sent) {
          this.#realm(message.to);
          this.#inFlight.push({ from: realm.name, ...message });
        }
        this.#log.push(
          `${this.#now} ${realm.name} rests${report.sent.length > 0 ? `, sent ${report.sent.map((message) => `${message.label} to ${message.to}`).join(", ")}` : ""}`
        );
      }
      const next = this.#inFlight.shift();
      if (!next) return;
      // The messages that follow it to the same realm go with it: the realm
      // runs them in this order, then rests once.
      const batch = [next];
      while (this.#inFlight[0]?.to === next.to) batch.push(this.#inFlight.shift()!);
      for (const message of batch) {
        await this.#realm(message.to).deliver(message.from, message.id, message.detail);
        this.#received.set(message.to, (this.#received.get(message.to) ?? 0) + 1);
        this.#log.push(
          `${this.#now} ${message.to} receives ${message.label} from ${message.from}`
        );
      }
      this.#unsettled.add(next.to);
    }
  }

  /**
   * Runs `ms` of world time: everything due in it, in order. The realms in
   * `bring` run at the end of it with nothing due too (a page shows a frame).
   */
  async advance(ms: number, bring: readonly string[] = []): Promise<void> {
    const end = this.#now + ms;
    for (;;) {
      await this.settle();
      const next = this.#nextDue();
      if (next === null || next > end) break;
      this.#moveTo(next);
    }
    this.#moveTo(end);
    for (const name of bring) this.touched(name);
    await this.settle();
  }

  /**
   * Moves time to the next time anything in the world is due, when that is
   * within `limit` ms, and runs what is due then; the realms in `bring` run
   * there too. False, with time where it was, when nothing is due in `limit`
   * ms: a wait for something else could not end before.
   *
   * With `watch`, time moves on past the times at which only other realms
   * run, to the next time something is due in a realm of `watch` or a
   * message reaches one: what they show can change no sooner. False when that is not
   * within `limit` ms; the other realms ran what was due in them meanwhile.
   */
  async next(
    limit: number,
    bring: readonly string[] = [],
    watch?: readonly string[]
  ): Promise<boolean> {
    const end = this.#now + limit;
    for (;;) {
      await this.settle();
      const next = this.#nextDue();
      if (next === null || next > end) return false;
      const due =
        watch === undefined || watch.some((name) => this.#due.get(name) === next);
      const received = this.#receivedBy(watch ?? []);
      this.#moveTo(next);
      if (!due) {
        await this.settle();
        if (this.#receivedBy(watch!) === received) continue;
      }
      for (const name of bring) this.touched(name);
      await this.settle();
      return true;
    }
  }

  /**
   * Runs the world until `condition` holds, looking each time the world
   * rests. Fails when `limit` ms of world time pass first, and at once when
   * nothing in the world is left to run: the condition could never hold.
   */
  async until(
    condition: () => unknown,
    { limit = 10_000, what = "the condition" }: { limit?: number; what?: string } = {}
  ): Promise<void> {
    const start = this.#now;
    for (;;) {
      await this.settle();
      if (await condition()) return;
      const next = this.#nextDue();
      if (next === null)
        throw new Error(
          `${what} does not hold, and nothing in the world is left to run.\n${await this.#describe()}`
        );
      if (next - start > limit)
        throw new Error(
          `${what} did not hold within ${limit} ms of world time.\n${await this.#describe()}`
        );
      this.#moveTo(next);
    }
  }

  #realm(name: string) {
    const realm = this.#byName.get(name);
    if (!realm) throw new Error(`The world has no realm "${name}".`);
    return realm;
  }

  #receivedBy(names: readonly string[]) {
    let count = 0;
    for (const name of names) count += this.#received.get(name) ?? 0;
    return count;
  }

  #nextDue() {
    let next: number | null = null;
    for (const due of this.#due.values())
      if (due !== null && (next === null || due < next)) next = due;
    return next === null ? null : Math.max(next, this.#now);
  }

  // Every realm learns the new time when it next settles; those with something
  // due by it have work to run.
  #moveTo(time: number) {
    if (time < this.#now) return;
    this.#now = time;
    for (const [name, due] of this.#due)
      if (due !== null && due <= time) this.#unsettled.add(name);
  }

  async #describe() {
    const lines = [`world time ${this.#now} ms`];
    for (const realm of this.#realms) {
      const due = this.#due.get(realm.name);
      lines.push(
        `${realm.name}: next due ${due === null || due === undefined ? "nothing" : `${due} ms`}${realm.describe ? `; ${await realm.describe()}` : ""}`
      );
    }
    lines.push("last steps:", ...this.#log.slice(-20).map((line) => `  ${line}`));
    return lines.join("\n");
  }
}
