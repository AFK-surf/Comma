// The client core alone: the page is no app, only the view's end of a record
// (e2e/app-shell/records). It starts the core's worker of the shipped build,
// sends it what the record has the view send, each message at its time and
// after the core said what the record has it say before, and checks every
// message of the core against the record.
export type Entry = {
  at: number;
  dir: "out" | "in" | "step" | "rest" | "due";
  data?: unknown;
  before?: true;
};

declare global {
  interface Window {
    /** Set before the page loads: the record as its file holds it, the worker's script and name, the recording page's seed. */
    coreAloneInput?: { entries: Entry[]; worker: string; name: string; seed: number };
    coreAlone?: {
      /** The test took the record's step `name` on the server. */
      step(name: string): void;
      /** The next entry, counted from 0, and where the core parted from the record. */
      state(): { next: number; faults: string[] };
    };
    commaRandomSeed?: number;
  }
}

const shown = (value: unknown) => JSON.stringify(value);

const input = window.coreAloneInput!;
const record = input.entries;
const faults: string[] = [];
let next = 0;
// Where the view rested and where the world's time moved for the core are
// the view's side of the record: the core's rounds here are this page's.
function skip() {
  while (record[next]?.dir === "rest" || record[next]?.dir === "due") next += 1;
}
function passed() {
  next += 1;
  skip();
}
skip();
// The worker draws its randomness from the seed of the page that starts it.
window.commaRandomSeed = input.seed;
const worker = new Worker(input.worker, { name: input.name, type: "module" });

function send() {
  for (;;) {
    const entry = record[next];
    if (entry?.dir !== "out") return;
    // The page's time is its runtime's: the record's times are page times.
    // ast-grep-ignore: ts-test-clock
    const wait = entry.at - performance.now();
    if (wait > 0) {
      // ast-grep-ignore: ts-test-timer
      setTimeout(send, wait);
      return;
    }
    passed();
    // Worker.postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    worker.postMessage(entry.data);
  }
}
worker.addEventListener("message", (event) => {
  const entry = record[next];
  // The record ends where its test ended: what the core says after is beyond it.
  if (!entry) return;
  const said = shown(event.data);
  if (entry?.dir !== "in" || shown(entry.data) !== said) {
    faults.push(
      `The core said ${said.slice(0, 300)}, where the record has ${entry ? `${entry.dir} ${shown(entry.data).slice(0, 300)} at ${entry.at} ms` : "nothing more"} (entry ${next + 1} of ${record.length}).`
    );
    return;
  }
  passed();
  send();
});
window.coreAlone = {
  step(name: string) {
    const entry = record[next] as (Entry & { data: { name: string } }) | undefined;
    if (entry?.dir !== "step" || entry.data.name !== name) {
      faults.push(`The test took the step ${name} at entry ${next + 1}.`);
      return;
    }
    passed();
    send();
  },
  state: () => ({ next, faults: [...faults] }),
};
send();
