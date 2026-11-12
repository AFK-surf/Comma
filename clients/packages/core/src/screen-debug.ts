// What debugs an app on a device beside its picture, over the mesh (the station's side: systems/station/src/mesh/screens.ts
// `/screens/<id>/debug/<action>`, from screens/sim-debug.ts and android-debug.ts). The station does each only for a client
// with a view of the device in Control now, so these fail `forbidden` from any other. A picture or a movie is written into
// Downloads as it comes, as a file of a station's Task is (`files.save`), at any size.
import { CoreError } from "@comma/core-kernel";
import { Effect, Scope, Stream } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { deviceSchema } from "./comma/schemas.ts";
import type { Ctx } from "./ctx.ts";
import type { Pull } from "./host.ts";
import type { ScreenDebugAnswer } from "./contract.ts";
import type { Stations } from "./stations/index.ts";

/** A screenshot at most, as the station's own bound. */
const MAX_PICTURE = 32 << 20;
/** The most that goes up to be installed: what crosses to the core at once. */
export const MAX_SCREEN_APP_BYTES = 1024 ** 3;
const PART = 1 << 20;
const isDevice = (screen: unknown): screen is string =>
  typeof screen === "string" && /^(android|simulator):[^/?#\s]{1,200}$/.test(screen);

const answerSchema = z.object({
  recording: z.boolean().optional(),
  appearance: z.enum(["light", "dark"]).optional(),
  app: z.string().max(256).optional(),
  name: z.string().max(256).optional(),
});

type Target = { workspace: string; device: string; screen: string; instance: string };

function targetOf(raw: unknown): Target {
  const p = (raw ?? {}) as Record<string, unknown>;
  for (const key of ["workspace", "device", "instance"] as const)
    if (typeof p[key] !== "string" || p[key] === "")
      throw CoreError.invalid(`${key} is required`);
  if (!isDevice(p.screen)) throw CoreError.invalid("screen is required");
  return p as Target;
}

/** The file's bytes as the request's body, a part at a time (no copy of them). */
function parts(bytes: Uint8Array): AsyncIterable<Uint8Array> {
  const pieces: Uint8Array[] = [];
  for (let at = 0; at < bytes.length; at += PART)
    pieces.push(bytes.subarray(at, at + PART));
  return Stream.toAsyncIterable(Stream.fromIterable(pieces));
}

const host = (error: Parameters<typeof CoreError.host>[0]) => CoreError.host(error);

function collect(body: Pull<Uint8Array>, max: number) {
  return Effect.gen(function* () {
    const chunks: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const piece = yield* body.take.pipe(
        Effect.mapError((e) => new CoreError("unreachable", e.message))
      );
      if (piece === null) break;
      size += piece.length;
      if (size > max)
        return yield* Effect.fail(
          new CoreError("too_large", "The station's answer is too large.")
        );
      chunks.push(piece);
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, at);
      at += chunk.length;
    }
    return bytes;
  });
}

export function registerScreenDebug(ctx: Ctx, stations: Stations): void {
  /** One action on the device's station, its answer's body to be read within the scope. */
  const act = (
    target: Target,
    action: string,
    query: Record<string, string> = {},
    outgoing: AsyncIterable<Uint8Array> = parts(new Uint8Array())
  ): Effect.Effect<{ body: Pull<Uint8Array> }, CoreError, Scope.Scope> =>
    Effect.gen(function* () {
      if (!ctx.host.stationMesh?.ownComputers)
        return yield* Effect.fail(
          new CoreError("unsupported", "This app debugs no device.")
        );
      const account = yield* ctx.session.account();
      const found = yield* ctx.api.request(
        account,
        "GET",
        route`/v1/comma/workspaces/${target.workspace}/devices/${target.device}`,
        deviceSchema
      );
      if (!found.station_id)
        return yield* Effect.fail(
          new CoreError("unsupported", "That computer runs no station.")
        );
      stations.linkOwnComputer(target.workspace, found.station_id);
      const search = new URLSearchParams({ instance: target.instance, ...query });
      return yield* stations.duplex(
        target.workspace,
        found.station_id,
        `/screens/${encodeURIComponent(target.screen)}/debug/${action}?${search.toString()}`,
        [],
        outgoing
      );
    });

  const said = (bytes: Uint8Array): Effect.Effect<ScreenDebugAnswer, CoreError> =>
    Effect.try({
      try: () => answerSchema.parse(JSON.parse(new TextDecoder().decode(bytes))),
      catch: () => new CoreError("bad_response", "The station answered unexpectedly."),
    }) as Effect.Effect<ScreenDebugAnswer, CoreError>;

  /** A body written into Downloads as it comes: nothing of it stays when it fails. */
  const saved = (body: Pull<Uint8Array>, fileName: string) =>
    Effect.gen(function* () {
      const desktop = ctx.host.desktop;
      if (!desktop)
        return yield* Effect.fail(new CoreError("unsupported", "No Downloads folder."));
      const { id } = yield* desktop.saveOpen(fileName).pipe(Effect.mapError(host));
      const written = Effect.gen(function* () {
        for (;;) {
          const piece = yield* body.take.pipe(
            Effect.mapError((e) => new CoreError("unreachable", e.message))
          );
          if (piece === null) return;
          yield* desktop.saveWrite(id, piece).pipe(Effect.mapError(host));
        }
      });
      yield* written.pipe(
        Effect.tapError(() => Effect.ignore(desktop.saveClose(id, false)))
      );
      return yield* desktop.saveClose(id, true).pipe(Effect.mapError(host));
    });

  ctx.kernel.calls({
    "devices.screenDebug": {
      run: (raw) =>
        Effect.scoped(
          Effect.gen(function* () {
            const target = targetOf(raw);
            const p = raw as { action?: unknown; value?: unknown; panel?: unknown };
            if (
              p.action !== "state" &&
              p.action !== "restart" &&
              p.action !== "appearance" &&
              p.action !== "record"
            )
              throw CoreError.invalid("action is required");
            const query: Record<string, string> = {};
            if (p.action === "appearance")
              query.value = p.value === "dark" ? "dark" : "light";
            if (p.action === "record" && (p.panel === "inner" || p.panel === "cover"))
              query.panel = p.panel;
            const { body } = yield* act(target, p.action, query);
            return yield* said(yield* collect(body, 1 << 16));
          })
        ),
    },
    "devices.saveScreenPicture": {
      run: (raw) =>
        Effect.scoped(
          Effect.gen(function* () {
            const target = targetOf(raw);
            const name = (raw as { name?: unknown }).name;
            if (typeof name !== "string" || name === "")
              throw CoreError.invalid("name is required");
            const { body } = yield* act(target, "screenshot");
            const png = yield* collect(body, MAX_PICTURE);
            const desktop = ctx.host.desktop;
            if (!desktop) return { png, saved: null };
            return {
              png,
              saved: yield* desktop
                .saveDownload(name, png)
                .pipe(Effect.mapError((e) => CoreError.host(e))),
            };
          })
        ),
    },
    "devices.saveScreenRecording": {
      run: (raw) =>
        Effect.scoped(
          Effect.gen(function* () {
            const target = targetOf(raw);
            const name = (raw as { name?: unknown }).name;
            if (typeof name !== "string" || name === "")
              throw CoreError.invalid("name is required");
            const { body } = yield* act(target, "record-stop");
            return yield* saved(body, name);
          })
        ),
    },
    "devices.installScreenApp": {
      run: (raw) =>
        Effect.scoped(
          Effect.gen(function* () {
            const target = targetOf(raw);
            const p = raw as { name?: unknown; bytes?: unknown };
            if (
              typeof p.name !== "string" ||
              p.name === "" ||
              !(p.bytes instanceof Uint8Array)
            )
              throw CoreError.invalid("a file is required");
            if (p.bytes.length > MAX_SCREEN_APP_BYTES)
              return yield* Effect.fail(
                new CoreError("too_large", "That file is too large.")
              );
            const { body } = yield* act(
              target,
              "install",
              { name: p.name },
              parts(p.bytes)
            );
            return yield* said(yield* collect(body, 1 << 16));
          })
        ),
    },
  });
}
