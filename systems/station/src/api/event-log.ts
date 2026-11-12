// What a station tells everyone as it changes (a message said, a session's summary, a sidebar row, the overview, a job),
// as a log: each event its number in it, kept a while. A client's stream is this log from some number on, in order; the
// last id a client heard (`<run>.<n>`) is where its next stream goes on from (`since`): what came after it is told again,
// or, when that is not all kept any more (or the id is another run's), the client is told it missed something and reads
// the station again. A run is this process's: a stream that comes back to the next process reads the station again.
//
// Only what is appended here has a number. What a stream is given because it asked for it (a session's steps as it
// runs, a job's log, host samples) is not of the log, is never told again (the next stream asks for it anew), and has
// no id: nothing a client goes on from can be ahead of what it was told of the log.
//
// It knows no client, stream or timer: events.ts says who follows and tells them; this says what was told, and what of
// it one who comes back is yet to hear. Ported from Comma's station (station/src/api/event-log.ts).
import { randomBytes } from "node:crypto";

/// What was told is kept this long, at most this many and this much: an hour, as a phone comes back to a chat after a
/// while in a pocket (ten minutes, half of its streams could not be told what they missed, and read the station again).
export const KEPT_MS = 3_600_000;
export const KEPT_MOST = 20_000;
export const KEPT_BYTES = 8 * 1024 * 1024;

/// An event of the log: its number, whom it was for (`to`, as the teller says it), as it goes out ("": it said a thing
/// whole, and the thing was said again since), and the thing it says whole (`of`).
export type Logged<To> = { n: number; to: To; text: string; at: number; of?: string };

export class EventLog<To> {
  /// This run of the log, in each event's id: a number of another run says nothing here.
  readonly run: string;
  #seq = 0;
  /// What is kept, oldest first, how much it is, and the number of the last let go (nothing before it can be gone on
  /// from).
  #kept: Logged<To>[] = [];
  #bytes = 0;
  #forgotten = 0;
  /// What is kept that says a thing whole, by the thing.
  #latest = new Map<string, Logged<To>>();

  constructor(run = randomBytes(4).toString("hex")) {
    this.run = run;
  }

  /// Appends an event, at `now`: the event as it goes out, with its id. `of`: the thing it says whole (a session, a
  /// viewer's overview or sidebar row, a job): it takes the place of what is kept of that thing, as told again the
  /// latest alone says how the thing is. Kept every time, a viewer's overview (some 20 KB at each change of a process)
  /// was most of what is kept: a busy station kept a few minutes of events, and told a phone coming back megabytes.
  append(event: string, data: unknown, to: To, now: number, of?: string): Logged<To> {
    const n = ++this.#seq;
    const logged: Logged<To> = { n, to, text: `id: ${this.run}.${n}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`, at: now, of };
    if (of !== undefined) {
      const before = this.#latest.get(of);
      if (before !== undefined) {
        this.#bytes -= before.text.length;
        before.text = "";
      }
      this.#latest.set(of, logged);
    }
    this.#kept.push(logged);
    this.#bytes += logged.text.length;
    this.#letGo(now);
    return logged;
  }

  /// Lets go of the oldest kept, while it keeps more than it may or they are older than KEPT_MS at `now`.
  #letGo(now: number) {
    let gone = 0;
    while (gone < this.#kept.length && (this.#kept.length - gone > KEPT_MOST || this.#bytes > KEPT_BYTES || now - this.#kept[gone]!.at > KEPT_MS)) {
      this.#bytes -= this.#kept[gone]!.text.length;
      gone++;
    }
    if (gone > 0) {
      this.#forgotten = this.#kept[gone - 1]!.n;
      this.#kept = this.#kept.slice(gone);
      const from = this.#kept[0]?.n ?? Infinity;
      for (const [thing, e] of this.#latest) if (e.n < from) this.#latest.delete(thing);
    }
  }

  /// The number `since` (`<run>.<n>`) says, where all that was appended after it is kept: this run's, and not before
  /// what was let go. Null: it cannot be gone on from.
  #from(since: string): number | null {
    const m = /^([0-9a-f]+)\.(\d+)$/.exec(since);
    return m !== null && m[1] === this.run && Number(m[2]) >= this.#forgotten ? Number(m[2]) : null;
  }

  /// Whether a stream can go on from `since`: all that was appended after it is kept.
  has(since: string): boolean {
    return this.#from(since) !== null;
  }

  /// What was appended after `since`, in order, as it went out (of a thing said whole, what was said last); none
  /// when `since` cannot be gone on from.
  after(since: string): Logged<To>[] {
    const n = this.#from(since);
    return n === null ? [] : this.#kept.filter((e) => e.n > n && e.text !== "");
  }

  /// Where the log is now (`<run>.<n>`): a stream told all that is appended from now on can go on from it.
  at(): string {
    return `${this.run}.${this.#seq}`;
  }

  /// Lets go of all that is kept (nobody followed for long): nothing before now can be gone on from.
  clear(): void {
    this.#kept = [];
    this.#bytes = 0;
    this.#latest.clear();
    this.#forgotten = ++this.#seq;
  }

  /// How it stands, for the log line of a stream that could not go on.
  state(): { run: string; forgotten: number; told: number; kept: number; bytes: number } {
    return { run: this.run, forgotten: this.#forgotten, told: this.#seq, kept: this.#kept.length, bytes: this.#bytes };
  }
}
