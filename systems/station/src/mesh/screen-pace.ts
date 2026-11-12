// How fast a view's frames go (still.fail's docs/remote-screens.md, "Pace"): which may be sent now, and the bit rate its source is
// asked to encode at. Both from what the client's acknowledgements say of the link: how long a frame takes from sent to
// decoded (the round trip), and how much went through in the last second.
//
// Frames go while those on the way go through as fast as the link has gone lately: the oldest not acknowledged waiting
// no longer than the quickest round trip of the last RTT_WINDOW_MS, `queueMs` of it, and the link's jitter. A far link
// so carries as many frames a second as a near one.
//
// A queue stands in front of the link (a link slower than the frames) when every frame acknowledged over the last
// QUEUE_WINDOW_MS (and two round trips) was later than the link's own round trip (BASE_SHARE of the trips are quicker)
// by more than `late`, half of `queueMs`, or when one frame waited longer than that window. Each frame's own bytes at
// the rate asked are left out of its wait (a key frame takes longer to go through, and is no queue). One late
// acknowledgement, or a moment of them (Wi‑Fi's jitter: 9–70 ms on a LAN of 240 Mbit/s, 2026-11-07), is no queue: some
// frames in the window still came in time. Nor is a frame alone on the link: one the source sent nothing after for
// longer than `may` lets the oldest wait (a still screen; an H.265 decoder keeps the newest until the next comes) waits
// as part of a queue only from when the next went; and the frames of a new picture size wait FRESH_MS for the client's
// decoder made anew. One frame on the way never holds the next. A queue lowers the bit rate only while the source's
// frames use it (`USED_FRAME`): a still screen's 1 KB frames get no smaller at a lower rate. While it does, it goes down to what
// went through (no lower than half of what it was at a time), so the frames that come next are as many and smaller
// rather than fewer and late. It goes up again a step at a time once no queue stood for UP_AFTER_MS, to the most the
// view is asked at (`rateCeiling`). A view starts at START_RATE (its first frame, a whole picture, is its largest: on a
// narrow link one at the source's own rate held the view up for a second) and goes up by START_UP each step until it
// is first lowered.
//
// Ported from still.fail (station/src/mesh/screen-pace.ts), its bit rate's ceiling and quicker climb as of
// still.fail#4384 (7470ca2abe). How a queue is found, the jitter, the key frame's own bytes, a frame alone, a new size,
// MAX_UNACKED, UP_FAST and USED_FRAME are Cue's own (docs/desktop-screen.md, "Deviations from still.fail"): still.fail takes a frame
// held past the quickest round trip and QUEUE_MS, again within a second, for a queue, and Wi‑Fi's jitter held a LAN view
// at MIN_RATE and 1280×720. A source whose rate cannot change takes no notice of `rate`.
import { wall } from "../ops/fibers.ts";

/// Frames sent and not acknowledged, at most: before the link's round trip is known, and however short it is.
export const START_UNACKED = 2;
/// A second of frames at 60 a second: a relay's round trip (Salix's, 200–250 ms) and its bursts hold 20–30 on the way,
/// and the queue is bounded by time (`may`), not by this. Cue's own: still.fail's is 16.
export const MAX_UNACKED = 60;
/// How much longer than its quickest round trip the oldest frame not acknowledged may be waiting while the next goes:
/// the queue a view lets build in front of a link, no more: QUEUE_MS, or QUEUE_SHARE of the round trip where that is
/// more (a far link's round trip varies by more than a near one's).
export const QUEUE_MS = 30;
export const QUEUE_SHARE = 0.5;
export const queueMs = (rtt: number) => Math.max(QUEUE_MS, rtt * QUEUE_SHARE);
/// How much longer than the link's own round trip (QUIC's, on its chosen path) a frame's may be at the most: the client
/// receiving, decoding and acknowledging it. A frame's round trip past that waited in front of the link, in the
/// station's own send buffer: such trips are not the link's, however long all of them were (a view whose first key frame
/// took 6 s through a relay of 500 ms round trip took 6–29 s for its quickest from then on, kept 60 frames on the way,
/// and showed each 14 s late, 2026-11-11).
export const LINK_SLACK_MS = 100;
/// What is on the way may take this long to go through at the rate the link went at lately however quick its round
/// trip: on a fast link that rate is the frames' own (a key frame takes longer, a moment of Wi‑Fi's jitter), no queue.
export const DRAIN_FLOOR_MS = 250;
/// What is on the way is reckoned to go through DRAIN_GAIN times as fast as the most that went through lately: a screen
/// that changed little (its frames, not the link, set what went through) starts moving without its frames held back.
export const DRAIN_GAIN = 1.5;
/// How long a round trip counts towards the quickest (the link changes: another way, a relay).
export const RTT_WINDOW_MS = 10_000;
/// A queue stands once every acknowledgement over this long (and two round trips), QUEUE_SAMPLES of them at least, was
/// late by more than `late`: Wi‑Fi's moments of delay (100–250 ms) are shorter.
export const QUEUE_WINDOW_MS = 500;
export const QUEUE_SAMPLES = 3;
export const late = (rtt: number) => queueMs(rtt) / 2;
/// The share of the last RTT_WINDOW_MS's round trips quicker than the one a queue is told by.
export const BASE_SHARE = 0.1;
/// The link's jitter: how much later than its own round trip an acknowledgement is, on average (JITTER_GAIN of each new
/// one). The oldest frame may wait twice that more before the next is held back, JITTER_MAX_MS at most.
export const JITTER_GAIN = 1 / 8;
export const JITTER_MAX_MS = 100;
/// What went through is counted over this long.
export const DELIVERY_WINDOW_MS = 1000;
/// The lowest bit rate asked; down to `DOWN` of what went through (and no lower than `CUT` of what it was) once a queue
/// stands, and again each round trip and `HOLD_MS` it stays; up by `UP` each `UP_EVERY_MS` once no queue stood for
/// `UP_AFTER_MS`, by `UP_FAST` once none stood for `UP_FAST_AFTER_MS` (a link with room climbs back sooner:
/// still.fail#4384; Cue's UP_FAST is START_UP, not 1.3), but by `UP` near what went through when a queue last stood
/// (to `KNEE_PAST` times it).
export const MIN_RATE = 300_000;
export const DOWN = 0.85;
export const CUT = 0.5;
export const HOLD_MS = 200;
export const UP = 1.15;
export const UP_FAST = 1.5;
export const UP_FAST_AFTER_MS = 2000;
export const KNEE_PAST = 1.3;
export const UP_EVERY_MS = 500;
export const UP_AFTER_MS = 1000;
export const START_RATE = 1_500_000;
/// How long after a new picture size its frames' round trips are not counted (the client's decoder made anew).
export const FRESH_MS = 1000;
/// What went through is counted only once acknowledgements have come for this long.
export const MEASURED_MS = 500;
export const START_UP = 1.5;
/// A queue lowers the rate only while the source uses it: the median of the last USED_FRAMES frames sent at least
/// USED_FRAME of a frame's share of the rate (the rate over the 帧率 asked, FRAME_RATE where none is). A still screen's
/// frames (1–1.3 KB at 1920×1080, 2026-11-08) are a hundredth or less of their share at 16–33 Mbit/s: a lower rate makes
/// them no smaller. Cue's own.
export const USED_FRAME = 0.25;
export const USED_FRAMES = 3;
export const FRAME_RATE = 60;

/// The most a view is asked at (still.fail's MAX_RATE).
export const MAX_RATE = 60_000_000;
/// The most a view is asked at while its connection goes through Salix (`via` "salix"): Salix passes 4 MiB/s on a
/// connection (33.5 Mbit/s), and 2 MiB/s (16.8 Mbit/s) a node for all its relayed connections (`@node_budget`), and
/// drops what is beyond it in each 250 ms (SalixWeb.StationRelay). A view at 16 Mbit/s with QUIC's own bytes went past
/// the node's budget as motion began, and each burst stalled 250–860 ms (2026-11-08, a local stand-in of the relay);
/// at 8 Mbit/s one view asks about half of the default budget (QUIC's own bytes and bursts aside; the budget can be
/// set otherwise). Not in still.fail, whose relays have no such bound.
export const SALIX_RATE = 8_000_000;

/// The bit rate a source encodes a picture of this size at when not asked (still.fail Helper's, stillfail-screen's).
export const ownRate = (width: number, height: number) => Math.max(1_000_000, width * height * 3);

/// The 画质 a view asks (the client's `quality`; still.fail's `Quality`): none for 自动 or a client from before it.
export type Quality = "smooth" | "hd" | "original";

/// The most a picture of this size is asked at: its pixels × 16 a second (at most MAX_RATE, at least its own: 1080p 33
/// Mbit/s), 流畅 × 6 (12.4). 自动 is the best the link carries, as 原画 and 高清 are (they choose the size alone): the
/// link lowers it where it carries less. Ported from still.fail#4384 (`rateCeiling`). On a LAN a desktop's text at its
/// own rate (× 3) stayed soft as it moved, and at × 8 too (still.fail, 2026-11-06); Moonlight asks 20 Mbit/s for 1080p
/// at 60.
export function rateCeiling(width: number, height: number, quality?: Quality): number {
  const per = quality === "smooth" ? 6 : 16;
  return Math.max(ownRate(width, height), Math.min(MAX_RATE, width * height * per));
}

/// What a source is to be asked now (null: nothing): the pace's `rate` once it differs by RATE_STEP or more from what
/// was `asked` last (a source is not asked again for every small step), and at once whenever `asked` is above the
/// view's `ceiling` (its picture's size, or a connection now through Salix, lowered it: SALIX_RATE is a bound, not a
/// step away).
export const RATE_STEP = 0.05;
export function rateToAsk(asked: number | null, rate: number | null, ceiling: number | null): number | null {
  if (rate === null) return null;
  if (asked === null || Math.abs(rate - asked) >= asked * RATE_STEP) return rate;
  return ceiling !== null && asked > ceiling ? Math.min(rate, ceiling) : null;
}

/// The most one view is asked at: its picture's `rateCeiling` at its 画质, a preview's (a card, two pictures a second)
/// the source's own (still.fail#4384), and no more than SALIX_RATE while its connection goes through Salix (`via`
/// "salix"), whatever its 画质: SALIX_RATE is Cue's bound on what the encoder is asked through Salix, not a choice of
/// picture, a cap on the bytes on the wire, or bandwidth a view is sure of (docs/desktop-screen.md, "Picture quality").
export function viewCeiling(width: number, height: number, o: { peek?: boolean; via?: string | null; quality?: Quality } = {}): number {
  const top = o.peek ? ownRate(width, height) : rateCeiling(width, height, o.quality);
  return o.via === "salix" ? Math.min(top, SALIX_RATE) : top;
}

/// How long the station's own loop stood still (ms, in all, since it was first asked): a frame's round trip and the wait
/// of the oldest on the way are counted without it. A Mac host's loop stood still 40–140 ms every few seconds
/// (2026-10-29: busy with searches asked again and again) on a LAN of 4 ms and nothing lost: its frames' acknowledgements
/// were read that late, taken for frames held back by the link, and the rate went down to what the source made (a
/// screen changing little makes little), on to MIN_RATE and the picture to LOW_BOUNDS. A frame held at the client
/// (decoded slowly) or on the link (a queue, a packet lost) is held as before.
export const STALL_TICK_MS = 10;
export class LoopStall {
  #total = 0;
  #last = 0;
  #stop: (() => void) | null = null;
  #users = 0;
  readonly #now: () => number;
  constructor(now: () => number = () => hostNow()) {
    this.#now = now;
  }

  /// Counted while someone uses it (a view): the function says how long the loop stood still so far.
  use(): { stalled: () => number; done: () => void } {
    if (this.#users++ === 0) {
      this.#last = this.#now();
      this.#stop = wall.every(STALL_TICK_MS, () => this.#tick());
    }
    let done = false;
    return {
      stalled: () => this.stalled(),
      done: () => {
        if (done) return;
        done = true;
        if (--this.#users === 0 && this.#stop !== null) {
          this.#stop();
          this.#stop = null;
        }
      },
    };
  }

  /// How long it stood still so far, the stand it is in now (its tick not come yet) with it.
  stalled(): number {
    return this.#total + Math.max(0, this.#now() - this.#last - STALL_TICK_MS);
  }

  #tick() {
    const now = this.#now();
    this.#total += Math.max(0, now - this.#last - STALL_TICK_MS);
    this.#last = now;
  }
}
export const loopStall = new LoopStall();

/// A frame sent and not acknowledged (Pacer's `#out`).
type Sent = { ts: number; bytes: number; at: number; stall: number; own: number; from: number; fromStall: number };

export class Pacer {
  /// The frames sent and not acknowledged, oldest first: their timestamps, sizes, when they went, how long the loop had
  /// stood still by then, and how long their own bytes take at the rate asked then (ms).
  /// `from`: when it began to wait behind the view's own bytes: when it went, or, for a frame left alone on the link (the
  /// source sent nothing after it for longer than the gate of `may`, the pacer holding nothing back), when the next went.
  readonly #out: Sent[] = [];
  /// Whether `may` held a frame back since the last went: the newest frame then is not alone, but at the end of a queue.
  #holding = false;
  /// When the picture's size last changed: frames sent within FRESH_MS of it show the client's decoder made anew.
  #resized = -Infinity;
  /// Round trips measured, oldest first: as measured (`ms`), and less the frame's own bytes at the rate asked (`wait`:
  /// what is compared with the link's own round trip; a key frame's own bytes are no queue).
  #trips: { at: number; ms: number; wait: number }[] = [];
  /// The frames acknowledged lately: when, and their sizes.
  #through: { at: number; bytes: number }[] = [];
  /// The sizes of the last USED_FRAMES frames sent.
  #went: number[] = [];
  /// The bit rate asked of the source, and the most it is asked (its own); null before its size is known.
  #rate: number | null = null;
  #ceiling: number | null = null;
  #down = -Infinity;
  #up = -Infinity;
  /// When a queue last stood, and what went through then (the most the link carried lately).
  #queued = -Infinity;
  #knee = 0;
  /// The link's own round trip (BASE_SHARE of the trips are quicker), and how much later than it the acknowledgements
  /// are, on average (ms).
  #base: number | null = null;
  #jitter = 0;
  #first = Infinity;
  /// What went through in a second, as `#widest` read it, falling (a monotonic queue: the widest first).
  #widths: { at: number; bps: number }[] = [];
  /// The link's own round trip (QUIC's, on its chosen path), as last told; null: not known.
  #link: number | null = null;
  /// The 帧率 asked: ms between frames (none: as many as come), and when the next may go. Each frame takes the next
  /// slot of 1000/fps ms; one late by up to half a slot lets the next come that much sooner, so a source that makes
  /// frames at the same rate (still.fail Helper's capture, asked it) is not cut to fewer by the jitter of its frames,
  /// and no second carries more than fps + 1.
  readonly #gap: number | null;
  #due = -Infinity;
  readonly #now: () => number;
  readonly #stalled: () => number;
  /// `start`: the bit rate the source was opened at (none: its own); `fps`: the 帧率 asked (none: 自动); `stalled`: how
  /// long the station's loop stood still so far (LoopStall), left out of round trips and waits.
  constructor(now: () => number, start: number | null = null, fps?: number, stalled: () => number = () => 0) {
    this.#now = now;
    this.#stalled = stalled;
    this.#rate = start;
    this.#gap = fps !== undefined && fps > 0 ? 1000 / fps : null;
  }

  /// How long until the next frame may go by the 帧率 asked, in whole ms (0: now; none asked, always 0): a clock read in
  /// nanoseconds a hair short of the slot waits a ms, not 0 ms again and again.
  wait(): number {
    const left = this.#gap === null ? 0 : this.#due - this.#now();
    return left > 0 ? Math.ceil(left) : 0;
  }

  get unacked(): number {
    return this.#out.length;
  }

  /// The link's own round trip as QUIC measures it on its chosen path (ms; null: not known): no frame's round trip is
  /// taken to be longer than it and LINK_SLACK_MS.
  link(rttMs: number | null) {
    this.#link = rttMs !== null && Number.isFinite(rttMs) && rttMs > 0 ? rttMs : null;
  }

  /// The longest a frame's round trip is taken to be: the link's own and LINK_SLACK_MS, or none while it is not known.
  #cap(ms: number): number {
    return this.#link === null ? ms : Math.min(ms, this.#link + LINK_SLACK_MS);
  }

  /// The picture's size changed: the client makes its decoder anew, and the frames of the next FRESH_MS wait for it.
  /// Their round trips are no queue (a 720p view grown to 1080p was cut twice by it, 2026-11-07).
  resized() {
    this.#resized = this.#now();
  }

  /// The most the view is asked at (its picture's size changed: `rateCeiling`): what it is asked goes no higher.
  ceiling(rate: number) {
    this.#ceiling = rate;
    this.#rate = Math.min(this.#rate ?? rate, rate);
  }

  sent(ts: number, bytes: number) {
    const now = this.#now();
    const stall = this.#stalled();
    const own = this.#rate === null ? 0 : (bytes * 8 * 1000) / this.#rate;
    const last = this.#out.at(-1);
    if (last !== undefined && !this.#holding && this.#alone(last, now)) {
      last.from = now;
      last.fromStall = stall;
    }
    this.#holding = false;
    this.#out.push({ ts, bytes, at: now, stall, own, from: now, fromStall: stall });
    this.#went.push(bytes);
    if (this.#went.length > USED_FRAMES) this.#went.shift();
    if (this.#gap !== null) this.#due = Math.max(this.#due + this.#gap, now + this.#gap / 2);
  }

  /// The client decoded every frame up to `ts`; the newest of them gives a round trip.
  acked(ts: number) {
    const now = this.#now();
    let newest: Sent | null = null;
    while (this.#out.length > 0 && this.#out[0]!.ts <= ts) {
      const f = this.#out.shift()!;
      this.#through.push({ at: now, bytes: f.bytes });
      newest = f;
    }
    if (newest === null) return;
    this.#first = Math.min(this.#first, now);
    while (this.#through.length > 0 && this.#through[0]!.at < now - DELIVERY_WINDOW_MS) this.#through.shift();
    // No round trip of the link: a frame alone on it with none after (a still screen; an H.265 decoder keeps the newest
    // until the next comes), or one that waited for a decoder made anew.
    if ((this.#out.length === 0 && !this.#holding && this.#alone(newest, now)) || newest.at < this.#resized + FRESH_MS) return;
    const trip = Math.max(0, now - newest.from - (this.#stalled() - newest.fromStall));
    this.#trips.push({ at: now, ms: trip, wait: Math.max(0, trip - newest.own) });
    // The latest is kept however old: a still screen sends nothing for long.
    while (this.#trips.length > 1 && this.#trips[0]!.at < now - RTT_WINDOW_MS) this.#trips.shift();
    // The link's own round trip, to tell a queue by: a low share of the trips, not the quickest alone (one read early, a
    // stand of the loop counted a little long, would make every other one look late).
    const trips = this.#trips.map((t) => t.ms).sort((a, b) => a - b);
    this.#base = this.#cap(trips[Math.floor(trips.length * BASE_SHARE)]!);
    const base = this.#base;
    this.#jitter += (Math.max(0, this.#trips.at(-1)!.wait - base) - this.#jitter) * JITTER_GAIN;
    if (this.#standing(now)) this.#queuing(now);
    // Up only on a frame that came about as quick as the link goes (one late may be a queue starting).
    else if (this.#trips.at(-1)!.wait <= base + late(base)) this.#steady(now);
  }

  /// The quickest round trip lately, or null before one.
  rtt(): number | null {
    return this.#trips.length === 0 ? null : this.#cap(Math.min(...this.#trips.map((t) => t.ms)));
  }

  /// How long acknowledgements are looked at for a queue: QUEUE_WINDOW_MS, or two round trips where that is more.
  #window(): number {
    return Math.max(QUEUE_WINDOW_MS, 2 * (this.rtt() ?? 0));
  }

  /// Whether a queue stands: every acknowledgement over the window (QUEUE_SAMPLES of them at least) later than the
  /// link's own round trip by more than `late` (half of `queueMs`: a queue held to `queueMs` by `may` shows), or the newest later by
  /// more than the window itself (a link so slow that few come in it).
  #standing(now: number): boolean {
    const base = this.#base;
    if (base === null) return false;
    const window = this.#window();
    if (this.#trips.at(-1)!.wait > base + window) return true;
    const since = now - window;
    let n = 0;
    for (let i = this.#trips.length - 1; i >= 0 && this.#trips[i]!.at >= since; i--, n++) if (this.#trips[i]!.wait <= base + late(base)) return false;
    return n >= QUEUE_SAMPLES;
  }

  /// The link's jitter, as the oldest frame may wait for it (ms).
  jitter(): number {
    return Math.min(JITTER_MAX_MS, 2 * this.#jitter);
  }

  /// How long frame `f` has waited behind the view's own bytes (ms): since `from`, less the loop's stands and its own bytes.
  #waited(f: Sent, now: number): number {
    return Math.max(0, now - f.from - (this.#stalled() - f.fromStall) - f.own);
  }

  /// Whether frame `f`, the newest, has been on the link alone for longer than `may` lets the oldest wait.
  #alone(f: Sent, now: number): boolean {
    const rtt = this.rtt();
    return rtt !== null && this.#waited(f, now) > rtt + queueMs(rtt) + this.jitter();
  }

  /// Whether the next frame may go now; when not, the frames on the way go through slower than the link went lately.
  /// One frame on the way never holds the next: a decoder that keeps the newest until the next comes acknowledges it
  /// only then.
  may(): boolean {
    if (this.#out.length <= 1) return true;
    const rtt = this.rtt();
    if (rtt === null) return this.#out.length < START_UNACKED;
    const now = this.#now();
    const oldest = this.#out[0]!;
    const waited = this.#waited(oldest, now);
    const allowed = rtt + queueMs(rtt) + this.jitter();
    const may = this.#out.length < MAX_UNACKED && waited <= allowed && this.#drains(now, allowed);
    // Held a window and a round trip: a queue stands (a frame held a round trip, a packet lost and sent again, is none).
    if (!may && waited > this.#window() + rtt && oldest.at >= this.#resized + FRESH_MS) this.#queuing(now);
    if (!may) this.#holding = true;
    return may;
  }

  /// Whether what is on the way goes through within `allowed` ms at the rate the link went at lately: the newest frame
  /// waits no longer than the oldest may. The oldest alone tells a queue only once it has waited, and by then a slow link
  /// held a second of frames behind it. The source's frames far smaller than the rate makes them (a desktop changing a
  /// little: 2–7 KB at 60 a second) lower no rate (`#used`), nor do those at MIN_RATE, so on a link narrower than they are (a relay through a
  /// proxy, 200–600 kbit/s, 2026-11-11) only this keeps them from queuing: 60 frames, 14 s late, without it. Not before
  /// what went through is known (MEASURED_MS).
  #drains(now: number, allowed: number): boolean {
    // Frames that use the rate asked are made smaller by it once a queue stands (`#queuing`): the rate is their bound,
    // until it is MIN_RATE. (Held back here too, a screen starting to move after a still one, its frames' what went
    // through and not the link's, and a key frame at a low rate, would wait for no queue.)
    const widest = this.#widest(now);
    if (now - this.#first < MEASURED_MS || (this.#used() && (this.#rate ?? 0) > MIN_RATE)) return true;
    const through = widest;
    if (through <= 0) return true;
    const bytes = this.#out.reduce((sum, f) => sum + f.bytes, 0);
    return (bytes * 8 * 1000) / (through * DRAIN_GAIN) <= Math.max(allowed, DRAIN_FLOOR_MS);
  }

  /// Whether the frames on the way wait in front of the link: the oldest waited longer than its round trip and the queue
  /// a view lets build. Asks nothing of the pace (as `may` does): what else goes on the view's stream (its sound) is
  /// left out while it holds, so the pictures go first.
  backlogged(): boolean {
    if (this.#out.length <= 1) return false;
    const rtt = this.rtt();
    if (rtt === null) return false;
    return this.#waited(this.#out[0]!, this.#now()) > rtt + queueMs(rtt);
  }

  /// The bit rate to ask of the source, or null while its own is not known.
  rate(): number | null {
    return this.#rate;
  }

  /// The most that went through in a second over the last RTT_WINDOW_MS (bits a second): what the link carries at the
  /// least, which frames held back by `#drains` do not lower (what went through in the last second alone would, and
  /// hold back more).
  #widest(now: number): number {
    const through = this.#delivered(now);
    while (this.#widths.length > 0 && this.#widths.at(-1)!.bps <= through) this.#widths.pop();
    this.#widths.push({ at: now, bps: through });
    while (this.#widths[0]!.at < now - RTT_WINDOW_MS) this.#widths.shift();
    return this.#widths[0]!.bps;
  }

  /// What went through in the last second, in bits a second.
  through(): number {
    return this.#delivered(this.#now());
  }

  /// What went through in the last second, in bits a second.
  #delivered(now: number): number {
    // Over the window, or since the first acknowledgement when it came within it: none acknowledged in it, nothing
    // (a link that stopped is not said to carry what it did a while ago).
    const span = Math.max(100, Math.min(DELIVERY_WINDOW_MS, now - this.#first));
    const bytes = this.#through.reduce((sum, f) => (f.at >= now - DELIVERY_WINDOW_MS ? sum + f.bytes : sum), 0);
    return (bytes * 8 * 1000) / span;
  }

  /// A queue stands: the rate down to what went through, once each round trip and HOLD_MS.
  #queuing(now: number) {
    this.#queued = now;
    const rtt = this.rtt() ?? 0;
    if (this.#rate === null || now - this.#down < rtt + HOLD_MS) return;
    // What went through is not known yet (the first frame, a whole picture, is most of it): nothing to go by.
    if (now - this.#first < MEASURED_MS) return;
    // The source's frames far smaller than the rate makes them (a still screen): a lower rate makes them no smaller,
    // and what went through is what the source made, not what the link carries. The frames waited behind a large one
    // (a key frame the link took 1–5 s for on a still screen, 2026-11-08), not behind the rate.
    if (!this.#used()) return;
    this.#down = now;
    const through = this.#delivered(now);
    this.#knee = through;
    // Nothing through in the last second (frames held that long): by CUT.
    this.#rate = Math.max(MIN_RATE, Math.min(this.#rate, Math.max(this.#rate * CUT, through * DOWN)));
  }

  /// Whether the source's frames use the rate asked: the median of the last USED_FRAMES sent (the lower of two) is
  /// USED_FRAME or more of a frame's share of the rate.
  #used(): boolean {
    const sizes = [...this.#went].sort((a, b) => a - b);
    if (sizes.length === 0 || this.#rate === null) return true;
    const share = (this.#rate * (this.#gap ?? 1000 / FRAME_RATE)) / 1000 / 8;
    return sizes[Math.floor((sizes.length - 1) / 2)]! >= share * USED_FRAME;
  }

  #steady(now: number) {
    if (this.#rate === null || this.#ceiling === null || this.#rate >= this.#ceiling) return;
    // Starting: never lowered yet. Up once no queue stood for UP_AFTER_MS.
    const starting = this.#down === -Infinity;
    if ((!starting && now - Math.max(this.#down, this.#queued) < UP_AFTER_MS) || now - this.#up < UP_EVERY_MS) return;
    this.#up = now;
    // Near what the link carried when a queue last stood (from 1/UP_FAST of it to KNEE_PAST times it), by UP alone: a
    // far link's queue shows late, and a step of UP_FAST over it held the view's frames back. Past it with no queue, the
    // link carries more now: by UP_FAST again.
    const near = this.#rate * UP_FAST > this.#knee && this.#rate < this.#knee * KNEE_PAST;
    const fast = now - Math.max(this.#queued, this.#down) >= UP_FAST_AFTER_MS && !near;
    const step = starting ? START_UP : fast ? UP_FAST : UP;
    this.#rate = Math.min(this.#ceiling, this.#rate * step);
  }
}

/// A still screen sends nothing (the helper makes a picture only when the screen changed), so what is shown is the last
/// frame's picture, encoded at the rate asked then: a view's first at START_RATE stays a blur while nothing on it moves.
/// Once no frame has gone for STILL_MS and the rate the pace asks has gone up past SHARPER times the one the last frame
/// was encoded at, the same picture goes again as a key frame at it; its acknowledgement lets the rate go up again, and
/// so on to the most it is asked at. A screen that keeps changing never waits STILL_MS; a link that cannot carry it lowers the
/// rate, and nothing more is sent. After still.fail's.
export const STILL_MS = 500;
export const SHARPER = 1.1;

export class Sharpener {
  #at = -Infinity;
  #rate: number | null = null;

  /// A frame went at `now`, encoded at `rate` (null: a source with no rate of its own).
  sent(now: number, rate: number | null) {
    this.#at = now;
    this.#rate = rate;
  }

  /// How long until the screen has been still for STILL_MS (0: it has).
  left(now: number): number {
    return Math.max(0, this.#at + STILL_MS - now);
  }

  /// Whether the last frame's picture is to go again now, the pace asking `rate`.
  due(now: number, rate: number | null): boolean {
    return rate !== null && this.#rate !== null && this.left(now) === 0 && rate > this.#rate * SHARPER;
  }
}

/// How late a view's frames are, said every LATENCY_EVERY_MS while frames go: from a picture's capture to its drawing on
/// the device (`frame`; the acknowledgement's arrival less half the link's quickest round trip, the way back), and from
/// its capture to its going out (`before`: waiting to be asked for, encoded; an encoder that holds a picture back until
/// the next comes shows here). Medians of the last LATENCY_WINDOW_MS. A frame's timestamp is its capture time on the
/// host's own clock (the Mac helper's, still.fail Helper's and stillfail-screen's: what `now` reads here); one off it by
/// more than 10 s (a source with a clock of its own) is not counted. A capture time up to AHEAD_MS after `now` counts
/// as now: ScreenCaptureKit's frame times come a few ms ahead of `hostNow` (median 3 ms, at most 13 ms, on a Mac mini,
/// 2026-11-08), and half of a Mac's frames were not counted.
export const LATENCY_EVERY_MS = 1000;
export const AHEAD_MS = 50;
export const LATENCY_WINDOW_MS = 2000;

/// The host's clock in ms, as the helpers stamp frames and sound: process.hrtime. On a Mac it counts the time asleep
/// (mach_absolute_time and the time slept since boot), as the Mac helper's stamps do; on Windows it is
/// QueryPerformanceCounter.
export const hostNow = () => Number(process.hrtime.bigint()) / 1e6;

export class FrameLatency {
  readonly #now: () => number;
  readonly #out = new Map<number, { capture: number; sent: number }>();
  #samples: { at: number; frame: number; before: number }[] = [];
  #said = -Infinity;
  constructor(now: () => number = hostNow) {
    this.#now = now;
  }

  /// A frame of capture time `ts` (µs) went out now.
  sent(ts: number) {
    const now = this.#now();
    // A capture a little ahead of `now` (AHEAD_MS) is counted as made now.
    const capture = Math.min(now, ts / 1000);
    if (ts / 1000 - now > AHEAD_MS || now - capture > 10_000) return;
    this.#out.set(ts, { capture, sent: now });
  }

  /// The client drew every frame up to `ts`; `rtt`: the link's quickest round trip (ms), the way back its half.
  acked(ts: number, rtt: number) {
    const now = this.#now();
    let newest: { capture: number; sent: number } | null = null;
    for (const [t, f] of this.#out) {
      if (t > ts) continue;
      if (t === ts) newest = f;
      this.#out.delete(t);
    }
    if (newest === null) return;
    this.#samples.push({ at: now, frame: Math.max(0, now - rtt / 2 - newest.capture), before: newest.sent - newest.capture });
    while (this.#samples.length > 0 && this.#samples[0]!.at < now - LATENCY_WINDOW_MS) this.#samples.shift();
  }

  /// What to say now (once each LATENCY_EVERY_MS, when there are frames to say it of): the medians, in whole ms.
  take(): { frame: number; before: number } | null {
    const now = this.#now();
    // A still screen sends nothing: what is older than the window is not said again.
    while (this.#samples.length > 0 && this.#samples[0]!.at < now - LATENCY_WINDOW_MS) this.#samples.shift();
    if (this.#samples.length === 0 || now - this.#said < LATENCY_EVERY_MS) return null;
    this.#said = now;
    const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;
    return { frame: Math.round(median(this.#samples.map((s) => s.frame))), before: Math.round(median(this.#samples.map((s) => s.before))) };
  }
}

/// A picture fitted into 1280×720 while the link carries little.
export const LOW_BOUNDS = { maxWidth: 1280, maxHeight: 720 };
/// The rate at most this share of what a picture of its size is encoded at, for DOWNSIZE_MS, and the source using it
/// (what went through at least USED of it: a screen that changes little needs little, and is not made smaller for
/// it): the smaller picture.
export const DOWNSIZE_SHARE = 0.25;
export const USED = 0.6;
export const DOWNSIZE_MS = 3000;
/// The smaller picture's rate at its own (the link carries all of it) for UPSIZE_MS: the view's own size again.
export const UPSIZE_MS = 3000;
/// Steps further apart than this start the count to the smaller picture again: a still screen's few frames (each
/// acknowledgement a step) say nothing of the link between them. Cue's own.
export const STEP_GAP_MS = 500;

/// How large a picture a view asks of its source by the rate the pace asks: as the view asked it, or LOW_BOUNDS while
/// the link carries a quarter or less of what a picture that size is encoded at (fewer pixels, each sharper: text that
/// a 1080p picture at a few hundred kbit/s blurs stays readable at 720p). Back once the smaller picture's rate stays at
/// its own. Ported from still.fail (station/src/mesh/screen-pace.ts `Sizer`, afk/main 0a70d5e9d0) with its 画质 (原画
/// keeps the picture whole), without a look at a part of the screen (`ask`): Cue has none.
export class Sizer {
  readonly #now: () => number;
  readonly #asked: { maxWidth: number; maxHeight: number };
  #low = false;
  #since: number | null = null;
  #last = -Infinity;
  /// 原画 asked: the picture is never made smaller (a link that carries less gets fewer frames of it).
  readonly #whole: boolean;
  constructor(now: () => number, asked: { maxWidth: number; maxHeight: number }, quality?: Quality) {
    this.#now = now;
    this.#asked = { ...asked };
    this.#whole = quality === "original";
  }

  get low(): boolean {
    return this.#low;
  }

  /// With the rate asked now, what went through, and the picture's size now: the bounds to ask for, when they change;
  /// else null.
  step(rate: number, through: number, size: { width: number; height: number }): { maxWidth: number; maxHeight: number } | null {
    // Asked no larger than the small one, or 原画: nothing to make smaller.
    if (this.#whole || (this.#asked.maxWidth <= LOW_BOUNDS.maxWidth && this.#asked.maxHeight <= LOW_BOUNDS.maxHeight)) return null;
    const own = ownRate(size.width, size.height);
    const now = this.#now();
    if (!this.#low && now - this.#last > STEP_GAP_MS) this.#since = null;
    this.#last = now;
    const holds = this.#low ? rate >= own * 0.98 : rate <= own * DOWNSIZE_SHARE && through >= rate * USED;
    if (!holds) {
      this.#since = null;
      return null;
    }
    this.#since ??= now;
    if (now - this.#since < (this.#low ? UPSIZE_MS : DOWNSIZE_MS)) return null;
    this.#since = null;
    this.#low = !this.#low;
    return this.bounds();
  }

  /// The bounds to ask of the source as things are: the view's, or the smaller one's within them.
  bounds(): { maxWidth: number; maxHeight: number } {
    const a = this.#asked;
    return this.#low ? { maxWidth: Math.min(a.maxWidth, LOW_BOUNDS.maxWidth), maxHeight: Math.min(a.maxHeight, LOW_BOUNDS.maxHeight) } : { ...a };
  }
}
