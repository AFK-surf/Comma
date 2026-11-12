// Where each of a view's frames spent its time, for an acceptance run (docs/desktop-screen.md, "Frame timing"): only with
// COMMA_STATION_SCREEN_TIMING set, and then as one station log line a view at most each TIMING_LINE_MS. Records only:
// the pace (screen-pace.ts) decides as it would without it.
//
// A frame's times on the host's clock (`hostNow`, which the helper stamps its frames by), in ms after its capture: the
// helper's encoder took it and gave it out, the helper sent it (its message 66, screen-pipe.ts), the station had it, put
// it in line for the stream, the stream took it and wrote it (the native stream took its bytes: QUIC's send buffer, not
// the wire), the client's `received` and `ack` came. And the client's own, each on its clock (@comma/mesh
// screen-wire.ts `ScreenAckTiming`): from its core having the frame whole to its `ack`, and from the page having it to its
// decoder taking it, giving it out, it handed to the track, its `ack`. A frame acknowledged by a later one's `ack` (let
// go, or one the station never heard of alone) has no times of the client's.
import type { ScreenAckTiming } from "@comma/mesh";
import { log } from "../ops/log.ts";
import type { HelperTiming } from "../screens/source.ts";
import { hostNow } from "./screen-pace.ts";

/// Whether views log their frames' times: COMMA_STATION_SCREEN_TIMING set, and not "0".
export const screenTimingOn = (env: NodeJS.ProcessEnv = process.env) => (env.COMMA_STATION_SCREEN_TIMING ?? "0") !== "0" && env.COMMA_STATION_SCREEN_TIMING !== "";

/// What the native mesh says of the view's connection now (native.ts `Connection` `paths`, `stats`), only what it has:
/// the chosen path's round trip, congestion window (bytes), congestion events, UDP datagrams sent, packets lost; the connection's
/// UDP bytes both ways and packets lost.
export type LinkStats = { via?: string | null; rttMs?: number; cwnd?: number; congestionEvents?: number; sentDatagrams?: number; lostPackets?: number; txBytes?: number; rxBytes?: number; lost?: number };

/// What the pace says now, read only, and how long the station's loop stood still so far (ms, screen-pace.ts LoopStall).
export type PaceNow = { rate: number | null; rtt: number | null; through: number; unacked: number; stalled: number };

/// A line each this often at most, of this many frames at most (60 a second: all of them); frames past it are counted
/// (`dropped`), not said.
export const TIMING_LINE_MS = 1000;
export const TIMING_LINE_FRAMES = 120;
/// Frames sent and not acknowledged kept, at most: past it the oldest is dropped.
export const TIMING_OPEN = 240;

/// A line's frames, each an array of these: `ts` (µs), `key` (1 or 0), `bytes`, then ms after capture on the host's
/// clock, then ms on the client's.
export const TIMING_COLUMNS = ["ts", "key", "bytes", "encodeStart", "encodeDone", "helperSent", "got", "queued", "writeStart", "writeDone", "received", "acked", "held", "decodeIn", "decodeOut", "shown", "clientAck"] as const;

type Timed = { ts: number; key: boolean; bytes: number; helper?: HelperTiming; queued: number; writeStart?: number; writeDone?: number; received?: number; acked?: number; client?: ScreenAckTiming };

export class FrameTiming {
  readonly #fields: Record<string, unknown>;
  readonly #now: () => number;
  readonly #link: () => LinkStats | null;
  readonly #pace: () => PaceNow | null;
  readonly #line: (fields: Record<string, unknown>) => void;
  /// Frames sent and not acknowledged, by `ts`, oldest first; and those done, not said yet.
  readonly #open = new Map<number, Timed>();
  #done: Timed[] = [];
  #dropped = 0;
  #said = -Infinity;

  /// `fields`: what each line says the view is (its number, its screen).
  constructor(o: { fields: Record<string, unknown>; now?: () => number; link?: () => LinkStats | null; pace?: () => PaceNow | null; line?: (fields: Record<string, unknown>) => void }) {
    this.#fields = o.fields;
    this.#now = o.now ?? hostNow;
    this.#link = o.link ?? (() => null);
    this.#pace = o.pace ?? (() => null);
    this.#line = o.line ?? ((fields) => log.info("screens", "frame timing", fields));
  }

  /// A frame put in line for the stream now.
  sent(frame: { ts: number; key: boolean; bytes: number; helper?: HelperTiming }) {
    this.#open.set(frame.ts, { ts: frame.ts, key: frame.key, bytes: frame.bytes, ...(frame.helper ? { helper: frame.helper } : {}), queued: this.#now() });
    if (this.#open.size > TIMING_OPEN) {
      this.#open.delete(this.#open.keys().next().value!);
      this.#dropped++;
    }
  }

  writing(ts: number) {
    const f = this.#open.get(ts);
    if (f) f.writeStart = this.#now();
  }

  written(ts: number) {
    const f = this.#open.get(ts);
    if (f) f.writeDone = this.#now();
  }

  /// The client has frame `ts` whole (its `received`).
  received(ts: number) {
    const f = this.#open.get(ts);
    if (f) f.received ??= this.#now();
  }

  /// The client's `ack` of `ts`, with its times (null: none said): every frame up to it is done.
  acked(ts: number, client: ScreenAckTiming | null) {
    const now = this.#now();
    for (const [t, f] of this.#open) {
      if (t > ts) break;
      this.#open.delete(t);
      f.acked = now;
      if (t === ts && client) f.client = client;
      this.#finish(f);
    }
    if (now - this.#said >= TIMING_LINE_MS) this.#say(now);
  }

  /// The view ended: what is left said, those never acknowledged too.
  end() {
    for (const f of this.#open.values()) this.#finish(f);
    this.#open.clear();
    this.#say(this.#now());
  }

  #finish(f: Timed) {
    if (this.#done.length < TIMING_LINE_FRAMES) this.#done.push(f);
    else this.#dropped++;
  }

  #say(now: number) {
    if (this.#done.length === 0 && this.#dropped === 0) return;
    this.#said = now;
    const frames = this.#done.map(row);
    const dropped = this.#dropped;
    this.#done = [];
    this.#dropped = 0;
    const link = this.#link();
    const pace = this.#pace();
    this.#line({ ...this.#fields, ...(link ? { link } : {}), ...(pace ? { pace: { ...pace, rate: pace.rate === null ? null : Math.round(pace.rate), through: Math.round(pace.through), stalled: Math.round(pace.stalled) } } : {}), columns: TIMING_COLUMNS.join(","), frames, ...(dropped > 0 ? { dropped } : {}) });
  }
}

const tenth = (ms: number | undefined) => (ms === undefined ? null : Math.round(ms * 10) / 10);

/// One frame as a line says it (TIMING_COLUMNS).
function row(f: Timed): (number | null)[] {
  const capture = f.ts / 1000;
  const after = (at: number | undefined) => (at === undefined ? null : tenth(at - capture));
  const c = f.client ?? {};
  return [f.ts, f.key ? 1 : 0, f.bytes, after(f.helper?.encodeStart), after(f.helper?.encodeDone), after(f.helper?.sent), after(f.helper?.got), after(f.queued), after(f.writeStart), after(f.writeDone), after(f.received), after(f.acked), tenth(c.held), tenth(c.decodeIn), tenth(c.decodeOut), tenth(c.shown), tenth(c.ack)];
}
