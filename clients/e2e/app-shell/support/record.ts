import "@comma/test-utils/browser-commands";
import { commands } from "vitest/browser";

// The execution record of a test, for the determinism proof
// (determinism/manifest.txt): after each test-clock step, one event that
// digests what the page shows then (./digest) — page time, the DOM, every
// animation's state and time, and every element's box. A test appends
// {file, test, status, events, digest} to DETERMINISM_RECORD, digest being the
// sha256 of its events in order. Runs of the same test on the same code, under
// any perturbation, must give the same record. With DETERMINISM_EVENTS, each
// test also writes what its events digest, to find where two runs part.

export type FrameState = { html: string; animations: string[]; boxes: string[] };

let settings: { recording: boolean; events: boolean; timing: boolean } | undefined;
let events: string[] | undefined;
let raw:
  | { name: string; html?: string; boxes?: string; pending: Promise<void> }
  | undefined;

/** Applies the run's perturbation once; true while records are written. */
export async function setUpDeterminism() {
  settings ??= await commands.determinismSettings();
  return settings.recording;
}

/** True while each test reports where its real time went (./timing). */
export async function timingEnabled() {
  settings ??= await commands.determinismSettings();
  return settings.timing;
}

// Whether the running test has a record of its own (a page's, ./page).
let begun = false;

/** Forgets the last test's record: called before each test. */
export function newTest() {
  begun = false;
}

/** Whether the running test began its own record. */
export const testRecorded = () => begun;

export async function beginRecord(file: string, test: string) {
  begun = true;
  events = (await setUpDeterminism()) ? [] : undefined;
  raw = settings?.events
    ? {
        name: `${`${file}__${test}`.replaceAll(/[^\w.-]+/g, "_").slice(-200)}.txt`,
        pending: Promise.resolve(),
      }
    : undefined;
}

/** True while this test's events are recorded: the caller reads the page. */
export const recording = () => events !== undefined;

export function recordFrame(label: string, state: FrameState) {
  events?.push(`${label} ${digestOf(label, state)}`);
}

export async function endRecord(
  file: string,
  test: string,
  status: string,
  state: FrameState | undefined
) {
  if (!events) return;
  if (state) events.push(`${status} ${digestOf(status, state)}`);
  const bytes = new TextEncoder().encode(events.join("\n"));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const digest = Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join(
    ""
  );
  await commands.appendDeterminismRecord(
    JSON.stringify({ file, test, status, events: events.length, digest })
  );
  await raw?.pending;
  events = undefined;
  raw = undefined;
}

// FNV-1a of one frame's state: the record keeps a short line per step.
function digestOf(label: string, state: FrameState) {
  let hash = 0x81_1c_9d_c5;
  const add = (text: string) => {
    for (let index = 0; index < text.length; index += 1) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 0x01_00_01_93) >>> 0;
    }
  };
  add(state.html);
  for (const line of state.animations) add(line);
  for (const line of state.boxes) add(line.slice(line.indexOf(" ") + 1));
  if (raw) {
    const current = raw;
    const boxes = state.boxes.join("\n");
    const text = [
      `--- frame ${label}`,
      ...state.animations.map((line) => `animation ${line}`),
      state.html === current.html ? "html same" : `html\n${state.html}`,
      boxes === current.boxes ? "boxes same" : `boxes\n${boxes}`,
      "",
    ].join("\n");
    current.html = state.html;
    current.boxes = boxes;
    current.pending = current.pending.then(() =>
      commands.appendDeterminismEvents(current.name, text)
    );
  }
  return hash.toString(16).padStart(8, "0");
}
