// A device's running app's logs beside its picture, over the mesh (the station's side: systems/station/src/mesh/screens.ts
// `/screens/<id>/logs`, its lines from screens/app-logs.ts). The page reads them with a call that runs for as long as its
// pane is open, their batches as the call's progress; its end (the pane closed) ends the station's stream, and the
// station's process with its last reader. The newest lines of each device read lately stay here, bounded (TAIL lines of
// at most TAIL_SCREENS devices), for what sends an agent the screen with what its app said (`devices.screenLogTail`).
import { lazySchema } from "@comma/chat-contract";
import { CoreError, type CallContext } from "@comma/core-kernel";
import {
  MAX_SCREEN_OUT,
  ScreenFrameReader,
  ScreenKind,
  ScreenOutgoing,
} from "@comma/mesh";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { deviceSchema } from "./comma/schemas.ts";
import type { ScreenLogEvent, ScreenLogLine } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { Stations } from "./stations/index.ts";

/** The newest lines kept of one device. */
export const TAIL = 500;
/** The devices whose lines are kept: the one read longest ago goes past it. */
const TAIL_SCREENS = 8;
/** What the station may say of one line, past which it is not taken as one. */
const MAX_TEXT = 4096;

const lineSchema = lazySchema(() =>
  z.object({
    seq: z.number().int().nonnegative(),
    at: z.string().max(64),
    level: z.string().max(32),
    app: z.string().max(256),
    pid: z.number().int().optional(),
    text: z.string().max(MAX_TEXT),
    crash: z.literal(true).optional(),
  })
);

const stateSchema = lazySchema(() =>
  z.object({
    logs: z
      .object({ mode: z.enum(["app", "all"]), app: z.string().max(256).optional() })
      .optional(),
    lines: z.array(z.unknown()).max(1000).optional(),
    dropped: z.number().int().nonnegative().optional(),
    ended: z.string().max(1024).optional(),
  })
);

const isDevice = (screen: unknown): screen is string =>
  typeof screen === "string" && /^(android|simulator):[^/?#\s]{1,200}$/.test(screen);
const APP = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;

function string(raw: unknown, key: string): string {
  const v = (raw as Record<string, unknown> | null)?.[key];
  if (typeof v !== "string" || v === "") throw CoreError.invalid(`${key} is required`);
  return v;
}

/**
 * The newest lines of the devices read lately, each device's oldest first, kept apart for each filter (App, All, one
 * app): each is a stream of its own at the station, its `seq` its own. Which filter of a device was read last is what
 * its tail gives unless another is named.
 */
export class ScreenLogTails {
  readonly #tails = new Map<string, { lines: ScreenLogLine[]; last: number }>();
  readonly #latest = new Map<string, string>();

  add(screen: string, filter: string, lines: readonly ScreenLogLine[]): void {
    const key = `${screen}\n${filter}`;
    this.#latest.delete(screen);
    this.#latest.set(screen, filter);
    while (this.#latest.size > TAIL_SCREENS)
      this.#latest.delete(this.#latest.keys().next().value!);
    const tail = this.#tails.get(key) ?? { lines: [], last: -1 };
    // (read last, kept last: the one read longest ago goes first)
    this.#tails.delete(key);
    this.#tails.set(key, tail);
    // A reader that joins is given what the station held: lines this one already had are not kept twice, nor kept again
    // once cleared.
    const fresh =
      lines[0] !== undefined && lines[0].seq <= tail.last
        ? lines.filter((l) => l.seq > tail.last)
        : lines;
    tail.lines.push(...fresh);
    tail.last = fresh.at(-1)?.seq ?? tail.last;
    if (tail.lines.length > TAIL) tail.lines.splice(0, tail.lines.length - TAIL);
    while (this.#tails.size > TAIL_SCREENS)
      this.#tails.delete(this.#tails.keys().next().value!);
  }

  /** A filter read again: the station gives what it holds first, which is what is kept from then on. */
  reset(screen: string, filter: string): void {
    this.#tails.delete(`${screen}\n${filter}`);
  }

  tail(screen: string, n: number, filter = this.#latest.get(screen)): ScreenLogLine[] {
    if (n <= 0 || filter === undefined) return [];
    return this.#tails.get(`${screen}\n${filter}`)?.lines.slice(-n) ?? [];
  }

  /** The person cleared the device's logs: none of what was read is sent, whichever filter it came by. */
  clear(screen: string): void {
    for (const [key, tail] of this.#tails)
      if (key.startsWith(`${screen}\n`)) tail.lines = [];
  }
}

/** A filter as its tail is kept: `app`, `all`, or `app:<bundle id or package>`. */
const filterOf = (mode: "app" | "all", app: string | undefined) =>
  app ? `app:${app}` : mode;

const keyOf = (workspace: string, device: string, screen: string) =>
  `${workspace}\n${device}\n${screen}`;

export function registerScreenLogs(ctx: Ctx, stations: Stations): void {
  const tails = new ScreenLogTails();

  const run = (raw: unknown, call: CallContext) =>
    Effect.scoped(
      Effect.gen(function* () {
        const workspace = string(raw, "workspace");
        const device = string(raw, "device");
        const screen = string(raw, "screen");
        const instance = string(raw, "instance");
        const p = raw as { mode?: unknown; app?: unknown };
        if (!isDevice(screen)) throw CoreError.invalid("screen is required");
        const mode = p.mode === "all" ? "all" : "app";
        const app = typeof p.app === "string" && APP.test(p.app) ? p.app : undefined;
        if (!ctx.host.stationMesh?.ownComputers)
          return yield* Effect.fail(
            new CoreError("unsupported", "This app reads no app logs.")
          );
        const account = yield* ctx.session.account();
        const found = yield* ctx.api.request(
          account,
          "GET",
          route`/v1/comma/workspaces/${workspace}/devices/${device}`,
          deviceSchema
        );
        if (!found.station_id)
          return yield* Effect.fail(
            new CoreError("unsupported", "That computer runs no station.")
          );
        stations.linkOwnComputer(workspace, found.station_id);
        const query = new URLSearchParams({ mode, instance, ...(app ? { app } : {}) });
        // Nothing goes on it: it is kept open while the pane is, and its end says the pane closed.
        const outgoing = new ScreenOutgoing();
        yield* Effect.addFinalizer(() => Effect.sync(() => outgoing.end()));
        const { body } = yield* stations
          .duplex(
            workspace,
            found.station_id,
            `/screens/${encodeURIComponent(screen)}/logs?${query.toString()}`,
            [],
            outgoing
          )
          .pipe(
            // A station from before serves no such path; a screen with no app logs says so.
            Effect.mapError((error) =>
              error.code === "http_404" ||
              error.code === "http_405" ||
              (error.code === "forbidden" && /not served/.test(error.message))
                ? new CoreError("unsupported", "That computer reads no app logs.")
                : error
            )
          );
        const key = keyOf(workspace, device, screen);
        const filter = filterOf(mode, app);
        tails.reset(key, filter);
        const reader = new ScreenFrameReader(MAX_SCREEN_OUT);
        let ended: string | undefined;
        for (;;) {
          const chunk = yield* body.take.pipe(
            Effect.mapError((e) => new CoreError("unreachable", e.message))
          );
          if (chunk === null) break;
          const frames = yield* Effect.try({
            try: () => reader.push(chunk),
            catch: () =>
              new CoreError("bad_response", "The station's frame is too large."),
          });
          for (const { kind, payload } of frames) {
            if (kind !== ScreenKind.state) continue;
            const parsed = stateSchema.safeParse(
              yield* Effect.try({
                try: (): unknown => JSON.parse(new TextDecoder().decode(payload)),
                catch: () =>
                  new CoreError("bad_response", "The station's state is not JSON."),
              })
            );
            if (!parsed.success) continue;
            const state = parsed.data;
            if (state.ended) ended = state.ended;
            if (state.logs)
              call.progress({
                type: "filter",
                mode: state.logs.mode,
                ...(state.logs.app ? { app: state.logs.app } : {}),
              } satisfies ScreenLogEvent);
            if (state.lines) {
              const lines = state.lines.flatMap((one) => {
                const line = lineSchema.safeParse(one);
                return line.success ? [line.data as ScreenLogLine] : [];
              });
              tails.add(key, filter, lines);
              call.progress({
                type: "lines",
                lines,
                ...(state.dropped ? { dropped: state.dropped } : {}),
              } satisfies ScreenLogEvent);
            }
          }
        }
        if (ended && ended !== "finished")
          return yield* Effect.fail(new CoreError("screen_ended", ended));
        return null;
      })
    );

  ctx.kernel.calls({
    "devices.openScreenLogs": { cancellable: true, run },
    "devices.clearScreenLogTail": {
      run: (raw) =>
        Effect.sync(() => {
          tails.clear(
            keyOf(
              string(raw, "workspace"),
              string(raw, "device"),
              string(raw, "screen")
            )
          );
          return null;
        }),
    },
    "devices.screenLogTail": {
      run: (raw) =>
        Effect.sync(() => {
          const p = raw as { lines?: unknown; mode?: unknown; app?: unknown } | null;
          const n = p?.lines;
          const lines = Number.isInteger(n) ? Math.min(TAIL, n as number) : 100;
          const app = typeof p?.app === "string" && APP.test(p.app) ? p.app : undefined;
          const filter =
            p?.mode === "app" || p?.mode === "all" ? filterOf(p.mode, app) : undefined;
          return {
            lines: tails.tail(
              keyOf(
                string(raw, "workspace"),
                string(raw, "device"),
                string(raw, "screen")
              ),
              lines,
              filter
            ),
          };
        }),
    },
  });
}
