// Views of the person's own computers' screens over the mesh, where the host reaches their stations
// (`StationMeshPorts.ownComputers`: every app that has the mesh) (the station's side: systems/station/src/mesh/screens.ts;
// the wire: @comma/mesh's screen-wire.ts). The
// page opens a view with a call that runs for as long as the view does, and has its frames as that call's progress,
// as they come: one message on the core's port each, their bytes beside the JSON (a port copies them; Electron's takes
// no transfer). What goes back (each frame shown, input) goes by a call of its
// own. Frames on their way are bounded by the station's pace, which goes by those acknowledgements. Watch and Control
// change on the open view (a `control` frame), so the picture goes on as it was: a switch never opens it anew. The
// screen's clipboard comes as a copy is made on it and goes as the page pastes (only while the view drives, the station
// decides), and its system output comes packet by packet where the page asked for it (still.fail's client/core-ts
// screen-frames.ts carries the same frames). A station that logs its frames' times (its first state's `timing`) is told
// as each video frame comes whole (`received`), and each `ack` carries the times it went by (`ViewTiming`).
import { lazySchema } from "@comma/chat-contract";
import { CoreError, type CallContext, type Value } from "@comma/core-kernel";
import {
  MAX_SCREEN_OUT,
  SCREEN_HEADER,
  SCREEN_LIST_WITH_DEVICES,
  ScreenFrameReader,
  ScreenKind,
  ScreenOutgoing,
  clipFits,
  encodeScreenAck,
  encodeScreenClip,
  encodeScreenSound,
  encodeScreenControl,
  encodeScreenFrame,
  encodeScreenJson,
  encodeScreenReceived,
  parseScreenAudio,
  parseScreenAudioConfig,
  parseScreenVideo,
  parseStationClip,
  screenQualityOf,
  type Clip,
  type ScreenAckTiming,
  type ScreenAsk,
} from "@comma/mesh";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { deviceSchema } from "./comma/schemas.ts";
import {
  SCREEN_DEBUG_ACTIONS,
  type ListedPhone,
  type ListedScreen,
  type ScreenDebugAction,
  type ScreenDeviceId,
  type ScreenQuality,
  type ScreenAudioCodec,
  type ScreenViewEvent,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { fromBase64 } from "./record.ts";
import type { Stations } from "./stations/index.ts";

/** Where the account keeps its 画质 (`screenQuality`). */
const SCREEN_QUALITY_META = "screens:quality";

const listSchema = lazySchema(() =>
  z.object({
    screens: z.array(
      z.object({
        id: z.string(),
        clipboard: z.array(z.string()).optional(),
      })
    ),
    codecs: z.array(z.string()).optional(),
  })
);

const rectSchema = lazySchema(() =>
  z.object({
    x: z.number(),
    y: z.number(),
    width: z.number(),
    height: z.number(),
  })
);

/** A panel's corners as superellipses (the station's sim-mask.ts `curves`). */
const cornerCurvesSchema = lazySchema(() => {
  const curve = z.object({
    reach: z.number().min(0).max(0.5),
    k: z.number().min(0).max(8),
  });
  return z.tuple([curve, curve, curve, curve]);
});

/** A simulator's case, a panel's (the station's sim-chrome.ts `toldOf`). */
const chromeSchema = lazySchema(() =>
  z.object({
    key: z.string().max(64),
    width: z.number(),
    height: z.number(),
    frame: z.object({ width: z.number().positive(), height: z.number().positive() }),
    screen: rectSchema,
    corners: z.array(z.number()).max(4),
    curves: cornerCurvesSchema.optional().catch(undefined),
    buttons: z
      .array(
        rectSchema.extend({
          name: z.string().max(64),
          dx: z.number(),
          dy: z.number(),
          front: z.boolean().optional(),
          page: z.number().int().optional(),
          usage: z.number().int().optional(),
        })
      )
      .max(16),
  })
);

/** Its pictures: PNGs in base64. */
const chromePicturesSchema = lazySchema(() =>
  z.object({
    body: z.string(),
    buttons: z.record(
      z.string(),
      z.object({ up: z.string(), down: z.string().optional() })
    ),
  })
);

const devicesSchema = lazySchema(() =>
  z.object({
    screens: z.array(
      z.object({
        id: z.string(),
        kind: z.string(),
        title: z.string().optional(),
        name: z.string().optional(),
        model: z.string().optional(),
        instance: z.string().optional(),
        width: z.number().optional(),
        height: z.number().optional(),
        peek: z.boolean().optional(),
        capabilities: z
          .object({
            input: z.literal("touch"),
            buttons: z.array(z.string()),
            panels: z.array(
              z.object({
                width: z.number(),
                height: z.number(),
                corners: z.tuple([z.number(), z.number(), z.number(), z.number()]),
                curves: cornerCurvesSchema.optional().catch(undefined),
              })
            ),
            // (a station's case it cannot read is left out, the device drawn as its panels say)
            chrome: z.array(chromeSchema).max(4).optional().catch(undefined),
            poses: z.array(z.enum(["closed", "book", "open"])).optional(),
            closable: z.boolean().optional(),
            logs: z.boolean().optional(),
            // (what debugs an app on it; any action a later station lists that this client does not know is left out)
            debug: z
              .object({
                actions: z
                  .array(z.string())
                  .transform((actions) =>
                    actions.filter((one): one is ScreenDebugAction =>
                      SCREEN_DEBUG_ACTIONS.includes(one as ScreenDebugAction)
                    )
                  ),
                install: z.array(z.string().max(16)).max(8),
              })
              .optional()
              .catch(undefined),
          })
          .optional(),
        phone: z.boolean().optional(),
        agent: z.boolean().optional(),
      })
    ),
    avds: z.array(z.string()).optional(),
    simulators: z
      .array(
        z.object({ udid: z.string(), title: z.string(), model: z.string().optional() })
      )
      .optional(),
    devicesUnavailable: z.string().optional(),
    phones: z
      .object({
        usb: z.boolean(),
        list: z
          .array(
            z.object({
              serial: z.string().max(256),
              state: z.string().max(64),
              model: z.string().max(256).nullable(),
              transport: z.enum(["usb", "wifi"]),
              shown: z.boolean(),
              agents: z.boolean(),
              screen: z.string().max(256).optional(),
            })
          )
          .max(64),
      })
      .optional(),
  })
);

/** What the station answers a change of its phones: the phones as its list gives them. */
const phonesSchema = lazySchema(() =>
  z.object({
    usb: z.boolean(),
    list: devicesSchema.shape.phones.unwrap().shape.list,
    said: z.string().max(1024).optional(),
  })
);

/** A phone as the core gives it, from what the station says. */
const phoneOf = (p: z.infer<typeof phonesSchema>["list"][number]): ListedPhone => ({
  serial: p.serial,
  state: p.state,
  model: p.model,
  transport: p.transport,
  shown: p.shown,
  agents: p.agents,
  ...(p.screen ? { screen: p.screen } : {}),
});

const startedSchema = lazySchema(() => z.object({ id: z.string() }));

/** Whether a view's target is one of a computer's devices, which only a listing that asks for them shows. */
const isDevice = (target: unknown): target is ScreenDeviceId =>
  typeof target === "string" && /^(android|simulator):[^/?#\s]{1,200}$/.test(target);

/** What a view asks for of what its page decodes; none said: H.264. */
const codecsOf = (raw: unknown): string[] => {
  const codecs = Array.isArray(raw)
    ? raw.filter((codec) => codec === "h265" || codec === "h264" || codec === "jpeg")
    : [];
  return codecs.length > 0 ? codecs : ["h264"];
};

const unsupported = (message: string) => new CoreError("unsupported", message);

/** How long a view waits for the mesh to reach the computer, before it says it did not. */
const REACH_MS = 8_000;

const string = (raw: unknown, name: string): string => {
  const value = (raw as Record<string, unknown> | null)?.[name];
  if (typeof value !== "string" || value === "" || value.length > 256)
    throw CoreError.invalid(`${name} is required`);
  return value;
};

/** The frames as the page has them: each a message of its own, on bytes of its own (a port clones a whole buffer). */
function eventOf(
  kind: number,
  payload: Uint8Array,
  codec: ScreenAudioCodec
): ScreenViewEvent | null {
  if (kind === ScreenKind.video) {
    const video = parseScreenVideo(payload);
    return video && { type: "video", ...video, data: video.data.slice() };
  }
  if (kind === ScreenKind.audio) {
    const audio = parseScreenAudio(payload, codec);
    return audio && { type: "audio", ts: audio.ts, data: audio.data.slice() };
  }
  if (kind === ScreenKind.audioConfig) {
    const said = parseScreenAudioConfig(payload);
    return said && { type: "audioConfig", codec: said };
  }
  if (kind === ScreenKind.clipboard) {
    const clip = parseStationClip(payload);
    return clip && { type: "clipboard", clip };
  }
  if (kind !== ScreenKind.config && kind !== ScreenKind.state) return null;
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
  if (value === null || typeof value !== "object") return null;
  if (kind === ScreenKind.state)
    return {
      type: "state",
      state: value as Extract<ScreenViewEvent, { type: "state" }>["state"],
    };
  const config = value as Record<string, unknown>;
  return typeof config.codec === "string" &&
    typeof config.width === "number" &&
    typeof config.height === "number" &&
    typeof config.description === "string"
    ? {
        type: "config",
        codec: config.codec,
        width: config.width,
        height: config.height,
        description: config.description,
      }
    : null;
}

const keyOf = (client: number, view: number) => `${client}/${view}`;

/** Frames a view keeps the time it had them whole of, at most, until their `ack`: a few seconds of them. */
const MAX_RECEIVED = 240;

/**
 * A view's frames' times, once its station asked them (`state.timing`): when the core had each whole (its clock), for
 * the `ack`'s `held`.
 */
class ViewTiming {
  on = false;
  readonly #received = new Map<number, number>();

  had(ts: number, at: number) {
    this.#received.set(ts, at);
    if (this.#received.size > MAX_RECEIVED)
      this.#received.delete(this.#received.keys().next().value!);
  }

  /** The `ack`'s times for frame `ts`, the page's beside them; the frames up to it are forgotten. */
  acked(ts: number, at: number, page: unknown): ScreenAckTiming {
    const had = this.#received.get(ts);
    for (const t of this.#received.keys()) if (t <= ts) this.#received.delete(t);
    const p = (page ?? {}) as Record<string, unknown>;
    const timing: ScreenAckTiming = had === undefined ? {} : { held: at - had };
    for (const name of ["decodeIn", "decodeOut", "shown", "ack"] as const) {
      const v = p[name];
      if (typeof v === "number" && Number.isFinite(v) && v >= 0) timing[name] = v;
    }
    return timing;
  }
}

/** A clip the page gives, within its bounds; null when it is none. */
function clipOf(raw: unknown): Clip | null {
  const v = raw as { type?: unknown; text?: unknown; data?: unknown } | null;
  const clip: Clip | null =
    v?.type === "text" && typeof v.text === "string"
      ? { type: "text", text: v.text }
      : v?.type === "png" && v.data instanceof Uint8Array
        ? { type: "png", data: v.data }
        : null;
  return clip && clipFits(clip) ? clip : null;
}

/** The two calls. A view's id is good only for the page that opened it. */
export function registerScreenViews(ctx: Ctx, stations: Stations): void {
  const open = new Map<string, { outgoing: ScreenOutgoing; timing: ViewTiming }>();
  let nextView = 1;

  // The 画质 chosen (still.fail's prefs `screenQuality`), kept with the account on this device: a sign-out forgets it,
  // and another account has its own. None: 自动.
  const chosenQuality = (): ScreenQuality | null =>
    screenQualityOf(ctx.session.current()?.meta<string>(SCREEN_QUALITY_META)) ?? null;
  const qualityChanged = () => {
    const { store } = ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "screenQuality") store.invalidate(topic);
  };
  ctx.kernel.source("screenQuality", {
    start: () => undefined,
    stop: () => undefined,
    compute: (): Value => ({ ok: { quality: chosenQuality() } }),
  });
  ctx.session.onChange(qualityChanged);

  /** The station of a person's computer, linked: the host reaches own computers, and the server says it is theirs. */
  const stationOf = (workspace: string, device: string) =>
    Effect.gen(function* () {
      if (!ctx.host.stationMesh?.ownComputers)
        return yield* Effect.fail(
          unsupported("This app does not reach computers' screens.")
        );
      const account = yield* ctx.session.account();
      const found = yield* ctx.api.request(
        account,
        "GET",
        route`/v1/comma/workspaces/${workspace}/devices/${device}`,
        deviceSchema
      );
      if (!found.station_id)
        return yield* Effect.fail(unsupported("That computer runs no station."));
      stations.linkOwnComputer(workspace, found.station_id);
      return found.station_id;
    });

  const listScreens = (raw: unknown) =>
    Effect.gen(function* () {
      const workspace = string(raw, "workspace");
      const station = yield* stationOf(workspace, string(raw, "device"));
      const listed = yield* stations.ask(
        workspace,
        station,
        "GET",
        SCREEN_LIST_WITH_DEVICES
      );
      const parsed = devicesSchema.safeParse(listed);
      if (!parsed.success)
        return yield* Effect.fail(
          new CoreError("bad_response", "The station's list is not one.")
        );
      return {
        screens: parsed.data.screens.flatMap((s): ListedScreen[] =>
          (s.kind === "android" || s.kind === "simulator") &&
          isDevice(s.id) &&
          s.capabilities &&
          s.instance &&
          s.name
            ? [
                {
                  id: s.id,
                  instance: s.instance,
                  name: s.name,
                  ...(s.model ? { model: s.model } : {}),
                  title: s.title ?? s.id,
                  width: s.width ?? 0,
                  height: s.height ?? 0,
                  peek: s.peek === true,
                  capabilities: s.capabilities,
                  ...(s.phone ? { phone: true } : {}),
                  ...(s.agent ? { agent: true } : {}),
                },
              ]
            : []
        ),
        avds: parsed.data.avds ?? [],
        simulators: parsed.data.simulators ?? [],
        ...(parsed.data.phones
          ? {
              phones: {
                usb: parsed.data.phones.usb,
                list: parsed.data.phones.list.map(phoneOf),
              },
            }
          : {}),
        ...(parsed.data.devicesUnavailable
          ? { unavailable: parsed.data.devicesUnavailable }
          : {}),
      };
    });

  const startDevice = (raw: unknown) =>
    Effect.gen(function* () {
      const workspace = string(raw, "workspace");
      const simulator = (raw as { simulator?: unknown } | null)?.simulator;
      const body =
        simulator === undefined
          ? { avd: string(raw, "avd") }
          : { simulator: string(raw, "simulator") };
      const station = yield* stationOf(workspace, string(raw, "device"));
      const answer = yield* stations.ask(
        workspace,
        station,
        "POST",
        "/screens/start",
        body
      );
      const parsed = startedSchema.safeParse(answer);
      return parsed.success
        ? parsed.data
        : yield* Effect.fail(new CoreError("bad_response", "The station gave no id."));
    });

  const closeDevice = (raw: unknown) =>
    Effect.gen(function* () {
      const workspace = string(raw, "workspace");
      const screen = string(raw, "screen");
      const instance = string(raw, "instance");
      if (!isDevice(screen)) throw CoreError.invalid("screen is required");
      const station = yield* stationOf(workspace, string(raw, "device"));
      yield* stations.ask(
        workspace,
        station,
        "POST",
        `/screens/${encodeURIComponent(screen)}/close`,
        { instance }
      );
      return null;
    });

  /** One panel's case pictures of a simulator, turned as asked. */
  const deviceChrome = (raw: unknown) =>
    Effect.gen(function* () {
      const workspace = string(raw, "workspace");
      const screen = string(raw, "screen");
      const p = raw as { panel?: unknown; turn?: unknown };
      if (!isDevice(screen)) throw CoreError.invalid("screen is required");
      if (
        !Number.isInteger(p.panel) ||
        (p.panel as number) < 0 ||
        (p.panel as number) > 3
      )
        throw CoreError.invalid("panel is required");
      if (!Number.isInteger(p.turn) || (p.turn as number) < 0 || (p.turn as number) > 3)
        throw CoreError.invalid("turn is required");
      const station = yield* stationOf(workspace, string(raw, "device"));
      const answer = yield* stations.ask(
        workspace,
        station,
        "GET",
        `/screens/${encodeURIComponent(screen)}/chrome/${p.panel as number}/${p.turn as number}`
      );
      const parsed = chromePicturesSchema.safeParse(answer);
      return parsed.success
        ? parsed.data
        : yield* Effect.fail(
            new CoreError("bad_response", "The station's case pictures are not ones.")
          );
    });

  /** The owner changes the computer's phones: USB, one phone shown and for agents, one over Wi-Fi. */
  const choosePhones = (raw: unknown) =>
    Effect.gen(function* () {
      const workspace = string(raw, "workspace");
      const change = (raw as { change?: unknown } | null)?.change as
        | Record<string, unknown>
        | undefined;
      const body =
        typeof change?.usb === "boolean"
          ? { usb: change.usb }
          : typeof change?.serial === "string" && typeof change.shown === "boolean"
            ? {
                serial: change.serial,
                shown: change.shown,
                agents: change.agents === true,
              }
            : typeof change?.connect === "string"
              ? { connect: change.connect }
              : typeof change?.disconnect === "string"
                ? { disconnect: change.disconnect }
                : null;
      if (body === null) throw CoreError.invalid("change is required");
      const station = yield* stationOf(workspace, string(raw, "device"));
      const answer = yield* stations.ask(
        workspace,
        station,
        "POST",
        "/screens/phones",
        body
      );
      const parsed = phonesSchema.safeParse(answer);
      if (!parsed.success)
        return yield* Effect.fail(
          new CoreError("bad_response", "The station's phones are not a list.")
        );
      return {
        usb: parsed.data.usb,
        list: parsed.data.list.map(phoneOf),
        ...(parsed.data.said ? { said: parsed.data.said } : {}),
      };
    });

  const run = (raw: unknown, call: CallContext) =>
    Effect.scoped(
      Effect.gen(function* () {
        const workspace = string(raw, "workspace");
        const device = string(raw, "device");
        const p = raw as {
          target?: unknown;
          codecs?: unknown;
          apps?: unknown;
          control?: unknown;
          background?: unknown;
          peek?: unknown;
          instance?: unknown;
          maxWidth?: unknown;
          maxHeight?: unknown;
          audio?: unknown;
          quality?: unknown;
          sink?: unknown;
        };
        const target = p.target;
        const asksDevice = isDevice(target);
        if (target !== "app" && target !== "display" && !asksDevice)
          throw CoreError.invalid("target is required");
        // Only where the host reaches own computers; nothing is asked of anyone otherwise.
        if (!ctx.host.stationMesh?.ownComputers)
          return yield* Effect.fail(
            unsupported("This app does not reach computers' screens.")
          );
        const account = yield* ctx.session.account();
        const found = yield* ctx.api.request(
          account,
          "GET",
          route`/v1/comma/workspaces/${workspace}/devices/${device}`,
          deviceSchema
        );
        const station = found.station_id;
        if (!station)
          return yield* Effect.fail(unsupported("That computer runs no station."));
        // A station from before takes a view for a request whose body never ends: it is asked only of one that lists
        // the screen. A plain request, too, renews a credential that has expired, which the view's own stream cannot.
        stations.linkOwnComputer(workspace, station);
        const listed = yield* stations
          .ask(
            workspace,
            station,
            "GET",
            asksDevice ? SCREEN_LIST_WITH_DEVICES : "/screens"
          )
          .pipe(
            Effect.timeoutOrElse({
              duration: REACH_MS,
              orElse: () =>
                Effect.fail(
                  new CoreError("unreachable", "The mesh did not reach that computer.")
                ),
            }),
            Effect.mapError((error) =>
              error.code === "http_404"
                ? unsupported("That computer's station shows no screens over the mesh.")
                : error
            ),
            // Forced through Salix, to test it: a failure is that path's, not a reason to go another way.
            Effect.mapError((error) =>
              ctx.host.stationMesh?.salixOnly &&
              error.code !== "forbidden" &&
              error.code !== "unauthorized"
                ? new CoreError("salix_only", error.message)
                : error
            )
          );
        const screens = listSchema.safeParse(listed);
        const shown = screens.success
          ? screens.data.screens.find((s) => s.id === target)
          : undefined;
        if (!shown)
          return yield* Effect.fail(
            unsupported("That computer's station shows no such screen over the mesh.")
          );

        const outgoing = new ScreenOutgoing();
        const timing = new ViewTiming();
        const view = nextView++;
        const key = keyOf(call.client, view);
        open.set(key, { outgoing, timing });
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            open.delete(key);
            outgoing.end();
          })
        );
        // 画质: one the station knows, or none (自动); a station from before lets it be.
        const quality = screenQualityOf(p.quality);
        const ask: ScreenAsk = {
          codecs: codecsOf(p.codecs),
          control: p.control === true,
          ...(Array.isArray(p.apps)
            ? {
                apps: p.apps
                  .filter((app): app is string => typeof app === "string")
                  .slice(0, 8),
              }
            : {}),
          ...(typeof p.background === "string" ? { background: p.background } : {}),
          ...(p.peek === true ? { peek: true } : {}),
          ...(typeof p.instance === "string" && p.instance.length <= 64
            ? { instance: p.instance }
            : {}),
          ...(typeof p.maxWidth === "number" ? { maxWidth: p.maxWidth } : {}),
          ...(typeof p.maxHeight === "number" ? { maxHeight: p.maxHeight } : {}),
          ...((p.audio === true || p.audio === "opus") && p.peek !== true
            ? { audio: p.audio === "opus" ? ("opus" as const) : ("pcm_s16le" as const) }
            : {}),
          ...(quality && p.peek !== true ? { quality } : {}),
        };
        const { body } = yield* stations.duplex(
          workspace,
          station,
          `/screens/${encodeURIComponent(target)}/view`,
          [[SCREEN_HEADER, JSON.stringify(ask)]],
          outgoing
        );
        // The clipboard's types the station listed for it (none from a station before: nothing is offered or sent).
        const clipboard = (shown.clipboard ?? []).filter(
          (type): type is "text" | "png" => type === "text" || type === "png"
        );
        call.progress({
          type: "open",
          view,
          ...(clipboard.length > 0 ? { clipboard } : {}),
        } satisfies ScreenViewEvent);
        // The phones' own decoder, where the app asked for it: pictures go to it as numbers and bytes, not as progress.
        const sink =
          typeof p.sink === "number" && Number.isSafeInteger(p.sink) && p.sink > 0
            ? p.sink
            : undefined;
        const native = sink === undefined ? undefined : ctx.host.screenFrames;
        const reader = new ScreenFrameReader(MAX_SCREEN_OUT);
        let ended: string | undefined;
        let endedCode: "screen_refused" | undefined;
        // What the view's `audio` packets are, as its `audioConfig` said.
        let audioCodec: ScreenAudioCodec = "pcm_s16le";
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
            if (native && kind === ScreenKind.video) {
              const video = parseScreenVideo(payload);
              if (!video) continue;
              if (timing.on) {
                timing.had(video.ts, ctx.now());
                outgoing.push(encodeScreenReceived(video.ts));
              }
              native.frame(sink!, video.key ? 4 : 3, video.ts, 0, 0, video.data);
              continue;
            }
            const event = eventOf(kind, payload, audioCodec);
            if (!event) continue;
            if (event.type === "audioConfig") audioCodec = event.codec;
            if (event.type === "state" && event.state.ended) {
              ended = event.state.ended;
              endedCode =
                event.state.endedCode === "screen_refused"
                  ? "screen_refused"
                  : undefined;
            }
            if (event.type === "state" && event.state.timing === true) timing.on = true;
            if (native && event.type === "config") {
              native.frame(
                sink!,
                event.codec === "h265" ? 2 : 1,
                0,
                event.width,
                event.height,
                fromBase64(event.description)
              );
              continue;
            }
            // Whole, before the page and its decoder.
            if (event.type === "video" && timing.on) {
              timing.had(event.ts, ctx.now());
              outgoing.push(encodeScreenReceived(event.ts));
            }
            call.progress(event);
          }
        }
        if (ended && ended !== "finished")
          return yield* Effect.fail(new CoreError(endedCode ?? "screen_ended", ended));
        return null;
      })
    );

  ctx.kernel.calls({
    "devices.listScreens": { run: listScreens },
    "devices.startScreenDevice": { run: startDevice },
    "devices.closeScreenDevice": { run: closeDevice },
    "devices.screenDeviceChrome": { run: deviceChrome },
    "devices.chooseScreenPhones": { run: choosePhones },
    "devices.openScreenView": { cancellable: true, run },
    "devices.chooseScreenQuality": {
      run: (raw) =>
        Effect.gen(function* () {
          const asked = (raw as { quality?: unknown } | null)?.quality;
          const chosen = screenQualityOf(asked);
          if (asked !== null && !chosen)
            return yield* Effect.fail(
              CoreError.invalid("quality is smooth, hd, original or null")
            );
          const account = yield* ctx.session.account();
          if (
            (account.meta<string>(SCREEN_QUALITY_META) ?? null) !== (chosen ?? null)
          ) {
            account.setMeta(SCREEN_QUALITY_META, chosen ?? null);
            qualityChanged();
          }
          return null;
        }),
    },
    "devices.sendToScreenView": {
      run: (raw, call) =>
        Effect.sync(() => {
          const p = raw as {
            view?: unknown;
            ack?: unknown;
            timing?: unknown;
            keyframe?: unknown;
            input?: unknown;
            control?: unknown;
            clipboard?: unknown;
            paste?: unknown;
            sound?: unknown;
          } | null;
          const opened = open.get(keyOf(call.client, Number(p?.view)));
          if (!opened) return null;
          const { outgoing, timing } = opened;
          if (Number.isSafeInteger(p?.ack)) {
            const ts = p!.ack as number;
            outgoing.push(
              encodeScreenAck(
                ts,
                timing.on ? timing.acked(ts, ctx.now(), p?.timing) : undefined
              )
            );
          }
          if (p?.keyframe === true)
            outgoing.push(encodeScreenFrame(ScreenKind.keyframe));
          if (p?.input !== null && typeof p?.input === "object")
            outgoing.push(encodeScreenJson(ScreenKind.input, p.input));
          if (typeof p?.control === "boolean")
            outgoing.push(encodeScreenControl(p.control));
          const clip = clipOf(p?.clipboard);
          if (clip) outgoing.push(encodeScreenClip(clip, p?.paste === true));
          if (typeof p?.sound === "boolean") outgoing.push(encodeScreenSound(p.sound));
          return null;
        }),
    },
  });
}
