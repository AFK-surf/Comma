// A record of what a page and its core worker exchanged in a run of the
// whole world, and the page's end of playing it again: the view alone, with
// no worker and no server. The record's player is a realm of the page's
// world (`recordedPeer`), so the page meets each message under the same
// rules as in the run that made the record: in the same round, at the same
// world time.

import type { Realm, SentMessage } from "@comma/test-utils/world/world";

/**
 * One message between a page and its worker, as the page saw it; a step of
 * the test on another realm (a call of the server), which what the page
 * received next may answer; or what the world did that the page's next round
 * depends on: where the page rested, and where the world's time moved for a
 * realm the view alone runs without.
 */
export type Exchanged = {
  /**
   * Page time, in ms, when the page sent it, ran it or rested, or the test
   * took the step. Of a `due`, world time.
   */
  at: number;
  /**
   * `out`: the page sent it; `in`: the page ran it; `step`: the test's step,
   * `data` its name, arguments and result. `rest`: the page rested, having
   * run and sent what the record has since its rest before: the end of a
   * round. `due`: the world's time moved here because the worker or the
   * server had something due.
   */
  dir: "out" | "in" | "step" | "rest" | "due";
  data?: unknown;
  /** A step the test took before the page opened. */
  before?: true;
};

/**
 * What a page notes of itself and its worker, the same in the run that makes
 * a record and in the run that plays it: the second must note what the first
 * did, entry by entry. `elapsed` is the page's time.
 */
export function exchangeLog(elapsed: () => number) {
  const entries: Exchanged[] = [];
  // Whether the page ran or sent something since it last rested.
  let active = false;
  return {
    entries,
    /** The page runs a message of its worker. */
    ran(data: unknown) {
      active = true;
      entries.push({ at: elapsed(), dir: "in", data });
    },
    /** From now on, what the page posts on `endpoint` is noted as it posts it. */
    sends(endpoint: { postMessage: unknown }) {
      const post = (endpoint.postMessage as (...args: unknown[]) => void).bind(
        endpoint
      );
      endpoint.postMessage = (...args: unknown[]) => {
        active = true;
        entries.push({ at: elapsed(), dir: "out", data: args[0] });
        post(...args);
      };
    },
    /** The test took a step on another realm. */
    step(name: string, args?: readonly unknown[], result?: unknown) {
      entries.push({ at: elapsed(), dir: "step", data: { name, args, result } });
    },
    /** The world's time moved to `at` for a realm the view alone runs without. */
    due(at: number) {
      const last = entries.at(-1);
      if (last?.dir === "due" && last.at === at) return;
      entries.push({ at, dir: "due" });
    },
    /** The page rested: a round in which it ran or sent something ends here. */
    rested() {
      if (!active) return;
      active = false;
      entries.push({ at: elapsed(), dir: "rest" });
    },
  };
}

/**
 * The page's line to a worker that is not there: what the record's player
 * injects arrives as a worker's message, and what the page posts goes
 * nowhere (the page notes it, `exchangeLog`).
 */
export function recordedLine() {
  const endpoint = new EventTarget() as unknown as Worker;
  Object.assign(endpoint, {
    postMessage() {},
    terminate() {},
    onmessage: null,
    onerror: null,
    onmessageerror: null,
  });
  return {
    endpoint,
    /** A message of the record reaches the page's end of the line. */
    inject(data: unknown) {
      endpoint.dispatchEvent(new MessageEvent("message", { data }));
    },
  };
}

/**
 * A realm the view alone runs without (the worker, the server), in the run
 * that makes the record: `due` hears each time the world's time moved to
 * something due in it. The world's time moves the same way when the record
 * is played, so the page's rounds fall at the same times.
 */
export function absentRealm(realm: Realm, due: (at: number) => void): Realm {
  let next: number | null = null;
  return {
    name: realm.name,
    deliver: (from, id, detail) => realm.deliver(from, id, detail),
    async settle(now) {
      if (next !== null && next <= now) due(now);
      const report = await realm.settle(now);
      next = report.nextDue;
      return report;
    },
  };
}

const unmarked = () =>
  new Error(
    "The record does not say where the page rested: make it again (COMMA_WORLD_RECORDS=record)."
  );
const shown = (data: unknown) => (JSON.stringify(data) ?? String(data)).slice(0, 160);
const described = (entry: Exchanged) =>
  `${entry.dir}${entry.data === undefined ? "" : ` ${shown(entry.data)}`} at ${entry.at} ms`;
// Two messages that part after what `shown` prints of them: where, and what each has there.
const apart = (a: Exchanged, b: Exchanged | undefined) => {
  if (!b || a.dir !== b.dir || shown(a.data) !== shown(b.data)) return undefined;
  const [did, has] = [JSON.stringify(a.data) ?? "", JSON.stringify(b.data) ?? ""];
  let at = 0;
  while (at < did.length && did[at] === has[at]) at += 1;
  if (at === did.length && at === has.length) return undefined;
  return `They part at character ${at}: the view's has ${JSON.stringify(did.slice(at, at + 80))}, the record's ${JSON.stringify(has.slice(at, at + 80))}.`;
};
const same = (a: Exchanged, b: Exchanged | undefined) =>
  b !== undefined &&
  a.dir === b.dir &&
  a.at === b.at &&
  JSON.stringify(a.data) === JSON.stringify(b.data);

/**
 * The core of a view that runs alone, as a realm of the page's world: it
 * plays `record` to the page, which notes what it does as the recording page
 * did (`page.exchanged`, an `exchangeLog`).
 *
 * The world hands the page what the record has it run in one round as one
 * batch, whatever the page sent between two of them, and one round's batch
 * only after the page rested from the round before. The player sends itself
 * a message behind each batch: the world then runs the player again once the
 * page rested, at the same world time, also when the page sent nothing. It
 * waits for world time only at a `due` entry.
 *
 * What the page notes must be the record's next entries, each as the record
 * has it (what, when, in which order): `caughtUp` fails at the first that
 * differs.
 */
export function recordedPeer(
  record: readonly Exchanged[],
  page: { exchanged(): readonly Exchanged[]; inject(data: unknown): void },
  name = "worker 1"
) {
  // A record made before a page noted its rests: its rounds are not known.
  if (
    record.some((entry) => entry.dir === "in") &&
    !record.some((entry) => entry.dir === "rest")
  )
    throw unmarked();
  // The steps before the page opened are no part of the view's run.
  let next = record.findIndex((entry) => !entry.before);
  if (next < 0) next = record.length;
  // How many of the page's notes were compared with the record.
  let seen = 0;
  // The rest that ends the last round handed to the page.
  let handed = -1;
  let said = 0;
  let marks = 0;
  let failed = false;
  const parted = (did: string) => {
    const entry = record[next];
    failed = true;
    return new Error(
      `${did}, where the record has ${entry ? described(entry) : "nothing more"} (entry ${next + 1} of ${record.length}).`
    );
  };
  const did = (entry: Exchanged) =>
    entry.dir === "out"
      ? `The view sent ${shown(entry.data)} at ${entry.at} ms`
      : entry.dir === "in"
        ? `The view ran ${shown(entry.data)} at ${entry.at} ms`
        : `The view rested at ${entry.at} ms`;
  /** Fails at the first thing the page did that is not the record's next entry. */
  const caughtUp = () => {
    // The first difference failed the test: what follows it says nothing more.
    if (failed) return;
    const log = page.exchanged();
    for (; seen < log.length; seen += 1) {
      const entry = log[seen]!;
      if (!same(entry, record[next])) {
        const error = parted(did(entry));
        const where = apart(entry, record[next]);
        if (where) error.message += ` ${where}`;
        throw error;
      }
      next += 1;
    }
  };
  return {
    name,
    caughtUp,
    // What the page sent is in its notes, compared there.
    async deliver() {},
    async settle(now: number) {
      caughtUp();
      const sent: SentMessage[] = [];
      for (;;) {
        const entry = record[next];
        if (failed || !entry) return { nextDue: null, sent };
        if (entry.dir === "due") {
          if (entry.at > now) return { nextDue: entry.at, sent };
          next += 1;
          continue;
        }
        // The page's next round. What the page runs in it was handed over
        // before the round began, also when the page sends first in it.
        let first = next;
        while (record[first]?.dir === "out") first += 1;
        if (record[first]?.dir !== "in" || first < handed)
          return { nextDue: null, sent };
        let end = first;
        for (; record[end]?.dir === "in" || record[end]?.dir === "out"; end += 1) {
          const message = record[end]!;
          if (message.dir !== "in") continue;
          page.inject(message.data);
          said += 1;
          sent.push({ to: "page", id: said, label: shown(message.data).slice(0, 60) });
        }
        if (record[end]?.dir !== "rest") {
          failed = true;
          throw unmarked();
        }
        handed = end;
        marks += 1;
        sent.push({ to: name, id: marks, label: "the page's rest" });
        return { nextDue: null, sent };
      }
    },
    /** The test takes the record's step `step` again; returns the result the step had. */
    step(step: string) {
      caughtUp();
      const entry = record[next] as
        | (Exchanged & { data: { name: string; result: unknown } })
        | undefined;
      if (entry?.dir !== "step" || entry.data.name !== step)
        throw parted(`The test took the step ${step}`);
      next += 1;
      return entry.data.result;
    },
    /** How far the record was played: the next entry, counted from 0. */
    played() {
      caughtUp();
      return next;
    },
  };
}
