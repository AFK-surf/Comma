// A client's connections whose process is gone. A client killed with a connection open (Android's force stop, a crash,
// a desktop app killed) sends nothing as it goes, and the connection would last until its idle timeout, ten minutes
// (CONNECTION_IDLE_MS in native/mesh: a phone app frozen in the background keeps its connections for its return). What
// is open on it lasts as long: a screen's view goes on capturing and encoding for no one.
//
// So each connection is asked whether its other end is still there (`Connection.answers`: a datagram it acknowledges at
// once), and closed if nothing is heard back:
// - when the same device connects again (`Superseded`, still.fail station/src/mesh/superseded.ts): its older ones are
//   asked. A connection that answers is left alone: one key may be several live clients at once.
// - when one with a view open has received nothing for QUIET_MS (`watchQuiet`): a client in the foreground sends a ping
//   each 2 s and its path keep-alives each second. One with nothing open is not asked: a phone frozen in the background
//   answers nothing either, and its connection is kept for its return.
import { log } from "../ops/log.ts";
import type { Connection } from "./native.ts";

/// How long a connection has to answer: a relay's round trip from a phone on a poor network is under a second; asked
/// three times within it.
export const ANSWER_MS = 3_000;
/// The close code of a connection found gone.
export const GONE_CODE = 4;
/// How long a connection with a view open may receive nothing before it is asked.
export const QUIET_MS = 30_000;
/// How often that is looked at.
export const QUIET_LOOK_MS = 5_000;

type Asked = Pick<Connection, "remoteId" | "answers" | "isClosed" | "close">;

async function ask(conn: Asked, within: number, why: string): Promise<void> {
  if (conn.answers === undefined) return;
  const there = await conn.answers(within).catch(() => true);
  if (there || conn.isClosed()) return;
  log.info("mesh", `a client's connection is gone (${why}): closed`, { device: conn.remoteId().slice(0, 12) });
  conn.close(GONE_CODE, "gone");
}

export class Superseded {
  readonly #open = new Map<string, Set<Connection>>();
  readonly #within: number;

  constructor(within = ANSWER_MS) {
    this.#within = within;
  }

  /// A connection came: those of its device here before it are asked whether they are still there. Resolves once each
  /// has answered or been closed.
  arrived(conn: Connection): Promise<void> {
    const id = conn.remoteId();
    const mine = this.#open.get(id) ?? new Set<Connection>();
    this.#open.set(id, mine);
    const before = [...mine].filter((c) => !c.isClosed());
    mine.add(conn);
    const forget = () => {
      mine.delete(conn);
      if (mine.size === 0 && this.#open.get(id) === mine) this.#open.delete(id);
    };
    conn.closed().then(forget, forget);
    return Promise.all(before.map((old) => ask(old, this.#within, "its device connected again"))).then(() => {});
  }
}

/// Asks `conn` whether its other end is there once it has received nothing for `quiet` while `busy` (a view open on it),
/// and closes it if not. Returns what stops looking.
export function watchQuiet(conn: Pick<Connection, "remoteId" | "answers" | "isClosed" | "close" | "stats">, busy: () => boolean, every: (ms: number, f: () => void) => () => void, o: { quiet?: number; look?: number; within?: number } = {}): () => void {
  const quiet = o.quiet ?? QUIET_MS;
  const look = o.look ?? QUIET_LOOK_MS;
  const received = () => conn.stats?.().rxPackets;
  if (conn.answers === undefined || received() === undefined) return () => {};
  let last = received();
  let still = 0;
  let asking = false;
  return every(look, () => {
    if (asking || conn.isClosed()) return;
    const now = received();
    if (now !== last || !busy()) {
      last = now;
      still = 0;
      return;
    }
    still += look;
    if (still < quiet) return;
    asking = true;
    void ask(conn, o.within ?? ANSWER_MS, `nothing received for ${Math.round(quiet / 1000)} s`).finally(() => {
      asking = false;
      still = 0;
      last = received();
    });
  });
}
