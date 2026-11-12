// A view of one of the station's screens on `comma/mesh/1` (@comma/mesh's screen-wire.ts says the wire), after still.fail's
// station/src/mesh/screens.ts. It answers on the request's own stream, frames both ways for as long as both sides keep
// it; comma.ts routes it here before a request's body is read. The source is asked for a frame only while the `Pacer`
// lets one go (screen-pace.ts), by the client's acknowledgements of what it has shown.
//
// Who may: this computer's owner alone (device-mesh.ts admitted them), and the computer's access: full. A view ends when the credential is revoked, the
// connection to Salix that admitted it goes, or the access is lowered.
//
// Watch and Control are a state of the open view: a `control` frame changes it in place, and the picture goes on as it
// was (no new capture, key frame or rate). Control is checked again (`refusedControl`), but a device's boot is not read
// again as a view's opening reads it: the accepted check-then-serial race (docs/android-screen.md, "Which device").
//
// The clipboard and the system output, as still.fail's mesh/screens.ts carries them (afk/main 3d517e022e, `ViewSession`
// `run`, `#audio`, `#read`'s `setClipboard`): the screen's clipboard goes to a view only while it drives (watched from its
// Control, let go at its Watch), and a view's clipboard frame is taken only while it drives, of a type the source
// carries, within bounds, in order with its input. The system output goes to any view that asked for it but a
// preview, Watch or Control (still.fail: one that only looks hears it too), one packet in flight at a time, so a slow
// link never queues sound behind the pictures.
//
// A device's running app's logs (screens/app-logs.ts) go on a sibling request, `POST /screens/<id>/logs?mode=app|all
// [&app=<bundle id or package>]&instance=<instance>`, to one who may drive it (what an app logs may be private: a
// read-only member only sees the screen), for as long as its request's body is open: `state` frames, the first saying
// the filter, then `lines` (each batch at most LOG_BATCH, with how many were `dropped` before them), `alive` and `ended`.
// It ends as a view does: the client finishes or resets its stream, its credential or access goes, or the device goes.
//
// What debugs an app on a device (screens/sim-debug.ts, android-debug.ts) goes on `POST /screens/<id>/debug/<action>
// ?instance=<instance>`: as what drives it, to one who may (the owner, not read-only), while the access is Full and this
// same client has a view of this device in Control now, so a client that only watches can do none of it.
//
// With COMMA_STATION_SCREEN_TIMING set, a view but a preview logs where each frame's time went (screen-timing.ts): its
// first state says `timing`, and the client tells it as each frame came whole (`received`) and its `ack`'s times.
import { randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { open, rm } from "node:fs/promises";
import { join } from "node:path";
import type { Headers, MeshReply, ServedRequest } from "@comma/mesh";
import {
  SCREEN_AUDIO,
  SCREEN_HEADER,
  SCREEN_TYPE,
  type ScreenAsk,
  type ScreenAudioCodec,
  type ScreenListed,
  ScreenFrameReader,
  ScreenKind,
  clipPayload,
  clipFits,
  encodeScreenAudio,
  encodeScreenFrame,
  encodeScreenJson,
  encodeScreenVideo,
  parseClip,
  parseScreenAck,
  parseScreenAckTiming,
  parseScreenControl,
  parseScreenReceived,
  parseScreenSound,
  screenInLimit,
  screenQualityOf,
} from "@comma/mesh";
import type { Access } from "../device/access.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { HelperViewOptions } from "../screens/helper.ts";
import { type AppLogFeed, type AppLogLine, BUNDLE_ID, READER_QUEUE } from "../screens/app-logs.ts";
import { ScreenRefused } from "../screens/hub.ts";
import { picturesOf, toldOf } from "../screens/sim-chrome.ts";
import { type ClipType, type Codec, type DeviceDebugAction, type DeviceInput, type Frame, type ScreenInput, type ScreenSource, type ScreenVideo, type ScreenView, isDevice } from "../screens/source.ts";
import type { PhoneChoice, PhoneChoices, PhoneListed } from "../screens/devices.ts";
import type { Admitted } from "./credential.ts";
import { FrameLatency, Pacer, type Quality, STILL_MS, START_RATE, Sharpener, Sizer, hostNow, loopStall, rateToAsk, viewCeiling } from "./screen-pace.ts";
import { FrameTiming, type LinkStats, screenTimingOn } from "./screen-timing.ts";

/// Capture sessions a station runs for views at once.
const MAX_VIEWS = 4;
/// Of those, one member's: a member cannot take them all from the others.
const MAX_VIEWS_A_MEMBER = 3;
/// Previews (a link's card) one client keeps open at once, beside those: as many as its page decodes as video
/// (`videoPeeks` in the client's ScreenLink.tsx), so a third Android card is refused here and starts no capture it would
/// let go of. One client's cards leave room for another's.
const MAX_PEEKS_A_CLIENT = 2;
/// Previews a station keeps open at once, of all its clients: a chat full of cards leaves room for the real view. Each
/// is small and about twice a second (a JPEG, or 300 kbit/s of H.264): room for three clients' two.
const MAX_PEEKS = 6;
/// A refused preview asks again every 5 s while its card is shown: one client's same refusal is logged once in this time.
const REFUSAL_LOG_MS = 60_000;
/// The refusals remembered for that, at most: clients and reasons are few, and forgetting one only logs it again.
const MAX_REFUSALS_KEPT = 64;
/// How long a view that ended waits for what it still has to say to go, when the client stopped reading.
const ENDED_MS = 5000;
/// A view says it is alive this often, so a still screen, which sends nothing, is told from a dead one.
const ALIVE_MS = 2000;
/// How often a view reads its connection's round trip for its pace (a native call; QUIC's own estimate moves slowly).
const LINK_READ_MS = 250;
/// What the helper takes of one input event (screens/screen-pipe.ts message 3).
const MAX_INPUT_BYTES = 4096;
const INPUT_TYPES = new Set(["move", "down", "up", "scroll", "keydown", "keyup", "text"]);
/// The most text one input event carries, in UTF-16 units (still.fail mesh/screens.ts `parseInput`). A client sends a
/// longer paste as more events.
const MAX_TEXT = 4096;
/// The least a picture's bounds may ask: what the helper can make (CUStream/ScreenView.swift).
const MIN_SIDE = 64;
const LIST = "/screens";
const VIEW = /^\/screens\/([^/?]+)\/view$/;
const START = "/screens/start";
const CLOSE = /^\/screens\/([^/?]+)\/close$/;
const LOGS = /^\/screens\/([^/?]+)\/logs$/;
/// What debugs an app on a device: one action each (the header's).
const DEBUG = /^\/screens\/([^/?]+)\/debug\/([a-z-]+)$/;
/// The largest file that goes up to be installed.
const MAX_INSTALL_BYTES = 2 * 1024 ** 3;
/// Log streams a station runs for viewers at once (each a reader of a device's feed, which runs one process).
const MAX_LOG_STREAMS = 4;
/// The most lines one `state` frame carries.
const LOG_BATCH = 200;
const PHONES = "/screens/phones";
/// A simulator's case: one panel's pictures, turned `turn` quarters clockwise (screens/sim-chrome.ts).
const CHROME = /^\/screens\/([^/?]+)\/chrome\/(\d)\/([0-3])$/;
/// What a start's body may be: an AVD's name or a simulator's UDID, in JSON.
const MAX_START_BODY = 1024;
const REPLACED = "that device is no longer running: another has its place";

/// What the computer's owner could open now, as its own listing with devices says it: for its agents' links (screens/links.ts).
export type ScreenCatalog = {
  screens: ScreenListed[];
  avds: string[];
  simulators: { udid: string; title: string; model?: string }[];
  /// Why its Android devices cannot be listed now; or why none of its screens can be viewed (`refused`).
  devicesUnavailable?: string;
  refused?: string;
};

export type ScreenViews = {
  /// What the owner could open now, without a member's credential: the station's own word for its agents.
  catalog(): Promise<ScreenCatalog>;
  /// What answers a request for the screens, or null when it asks something else. `via`: how the request's connection
  /// runs now (`direct`, `relay`, `salix`; null not known), which bounds a view's bit rate (screen-pace.ts SALIX_RATE);
  /// `link`: what the native mesh says of it, for the frames' times (screen-timing.ts).
  handle(admitted: Admitted, request: Pick<ServedRequest<Admitted>, "method" | "path" | "headers" | "body" | "signal">, via?: () => string | null, link?: () => LinkStats | null): Promise<MeshReply> | null;
};

export type ScreenViewsOptions = {
  sources(): readonly ScreenSource[];
  /// The computer's one access value now.
  access(): Access;
  /// Whether the station answers now.
  up(): boolean;
  /// Who may see and who may drive: device-mesh.ts says, each decided on its own.
  mayView(admitted: Admitted): boolean;
  mayControl(admitted: Admitted): boolean;
  /// Hears the access or what admits members change; gives the function that stops it.
  listen(changed: () => void): () => void;
  /// The machine's Android devices, only looked at by a listing that asks: nothing else starts adb.
  devices?: {
    /// Follows adb, and says once it has looked.
    refresh(): Promise<void>;
    /// Why none can be listed now, in the station's language.
    unavailable(): string | null;
    /// The Android Virtual Devices that could start here.
    startable(): Promise<string[]>;
    /// Starts one; the id it will be listed as, or null when it is no such device, none can start, or `allowed` says no
    /// as it is about to.
    start(avd: string, allowed: () => boolean): Promise<string | null>;
    /// The phones on the machine's adb and what its owner chose of them (screens/devices.ts).
    phones?: {
      choices(): PhoneChoices;
      phones(): PhoneListed[];
      setUsb(on: boolean): Promise<void>;
      choose(serial: string, choice: PhoneChoice | null): Promise<void>;
      connect(address: string): Promise<string>;
      disconnect(address: string): Promise<string>;
    };
  };
  /// The Mac's iOS Simulators, likewise only looked at by a listing that asks.
  simulators?: {
    /// Looks at them, and says once it has.
    refresh(): Promise<void>;
    /// Those shut down that could boot.
    bootable(): { udid: string; title: string; model?: string }[];
    /// Boots one of those; the id it will be listed as, or null as for `devices.start`.
    boot(udid: string, allowed: () => boolean): Promise<string | null>;
  };
  /// `f` after `ms` (default: the wall's); gives the function that calls it off.
  after?(ms: number, f: () => void): () => void;
  /// Whether views log their frames' times (default: COMMA_STATION_SCREEN_TIMING), and where (default: the station log).
  timing?: boolean;
  timingLine?(fields: Record<string, unknown>): void;
};

/// What a screen is, as a client draws and drives it: a computer's says little.
function listed(source: ScreenSource): ScreenListed {
  const base = { id: source.id, kind: source.kind, ...(source.peek ? { peek: true } : {}) };
  // The clipboard's types a view that drives it carries both ways (still.fail hub.ts's list `clipboard`); none said where
  // it has none.
  const clipboard = source.clipboard?.() ?? [];
  if (!isDevice(source)) return clipboard.length > 0 ? { ...base, clipboard } : base;
  // (what a client keeps to name this device and no other: its id is only its place)
  const poses = source.poseNames?.() ?? [];
  return {
    ...base,
    title: source.title?.() ?? source.id,
    ...(source.name ? { name: source.name } : {}),
    ...(source.model ? { model: source.model } : {}),
    ...(source.instance ? { instance: source.instance } : {}),
    ...(source.size?.() ?? {}),
    capabilities: {
      input: "touch",
      buttons: ["home", "lock", "volume", "rotate"],
      panels: (source.panels ?? []).map((panel) => ({ ...panel })),
      // (its case and buttons, where Xcode has them on this Mac: their pictures by `GET /screens/<id>/chrome/<panel>/<turn>`)
      ...(source.chrome?.length ? { chrome: source.chrome.map(toldOf) } : {}),
      ...(poses.length > 0 ? { poses } : {}),
      ...(source.discard ? { closable: true } : {}),
      // (its running app's logs: `POST /screens/<id>/logs`; a station from before says nothing, and has none)
      ...(source.logs ? { logs: true } : {}),
      // (what debugs an app on it: `POST /screens/<id>/debug/<action>`; a station from before says nothing, and has none)
      ...(source.debug ? { debug: { actions: [...source.debug.actions], install: [...source.debug.installTypes] } } : {}),
    },
    ...(source.phone ? { phone: true } : {}),
    // (shown while an agent's lease lasts: screens/android-agent.ts)
    ...(source.agent ? { agent: true } : {}),
  };
}

const json = (status: number, body: unknown): MeshReply => ({ status, headers: [["content-type", "application/json"]], body: Buffer.from(JSON.stringify(body)) });

function why(o: ScreenViewsOptions, admitted: Admitted): { status: number; error: string } | null {
  if (admitted.exp * 1000 <= wall.now()) return { status: 401, error: "credential expired" };
  if (!o.mayView(admitted)) return { status: 401, error: "credential revoked" };
  if (!o.up()) return { status: 502, error: "station unreachable: not started" };
  if (o.access() !== "full") return { status: 403, error: "this computer does not allow its screen to be viewed: its access is not Full" };
  return null;
}

/// The view's ask, from its header; null when it is not one. A field it does not know (a client from after it) is let
/// be, and every field may be missing (a client from before it).
export function askOf(headers: Headers): ScreenAsk | null {
  const raw = headers.find(([name]) => name.toLowerCase() === SCREEN_HEADER)?.[1];
  if (raw === undefined) return null;
  let v: any;
  try {
    v = JSON.parse(raw);
  } catch {
    return null;
  }
  if (v === null || typeof v !== "object" || !Array.isArray(v.codecs)) return null;
  const quality = screenQualityOf(v.quality);
  const apps = Array.isArray(v.apps) ? v.apps.filter((app: unknown): app is string => typeof app === "string" && app !== "").slice(0, 8) : [];
  return {
    codecs: v.codecs.filter((codec: unknown): codec is string => typeof codec === "string"),
    control: v.control === true && v.peek !== true,
    ...(v.peek === true ? { peek: true } : {}),
    // (still.fail mesh/screens.ts `asked`: never a preview's)
    ...((v.audio === "pcm_s16le" || v.audio === "opus") && v.peek !== true ? { audio: v.audio as ScreenAudioCodec } : {}),
    // 画质 (still.fail mesh/screens.ts `asked`): only one it knows, never a preview's; none is 自动.
    ...(quality && v.peek !== true ? { quality } : {}),
    ...(apps.length > 0 ? { apps } : {}),
    ...(typeof v.maxWidth === "number" && Number.isFinite(v.maxWidth) ? { maxWidth: Math.min(8192, Math.max(MIN_SIDE, Math.round(v.maxWidth))) } : {}),
    ...(typeof v.maxHeight === "number" && Number.isFinite(v.maxHeight) ? { maxHeight: Math.min(8192, Math.max(MIN_SIDE, Math.round(v.maxHeight))) } : {}),
    ...(typeof v.background === "string" && /^#[0-9a-fA-F]{6}$/.test(v.background) ? { background: v.background } : {}),
    ...(typeof v.instance === "string" && v.instance.length <= 64 ? { instance: v.instance } : {}),
  };
}

/// The most one timer waits (a credential lasts 30 days, more than a timer can).
const LONGEST_WAIT_MS = 2 ** 30;

/// `f` once the wall reaches `at`, gives the function that calls it off.
function atExpiry(at: number, f: () => void): () => void {
  let cancel = () => {};
  const arm = () => {
    const left = at - wall.now();
    if (left <= 0) return f();
    cancel = wall.after(Math.min(left, LONGEST_WAIT_MS), arm);
  };
  arm();
  return () => cancel();
}

async function jsonOf(body: AsyncIterable<Uint8Array>, most: number): Promise<unknown> {
  const parts: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of body) {
    size += chunk.length;
    if (size > most) return null;
    parts.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(parts).toString("utf8"));
  } catch {
    return null;
  }
}

export function makeScreenViews(o: ScreenViewsOptions): ScreenViews {
  const timing = o.timing ?? screenTimingOn();
  /// Views opened so far: a view's number in its frames' times.
  let opened = 0;
  let open = 0;
  let logStreams = 0;
  let peeks = 0;
  const peeksBy = new Map<string, number>();
  const openBy = new Map<string, number>();
  const take = (member: string) => {
    open++;
    openBy.set(member, (openBy.get(member) ?? 0) + 1);
  };
  const free = (member: string) => {
    open--;
    const left = (openBy.get(member) ?? 1) - 1;
    if (left > 0) openBy.set(member, left);
    else openBy.delete(member);
  };
  const takePeek = (client: string) => {
    peeks++;
    peeksBy.set(client, (peeksBy.get(client) ?? 0) + 1);
  };
  const freePeek = (client: string) => {
    peeks--;
    const left = (peeksBy.get(client) ?? 1) - 1;
    if (left > 0) peeksBy.set(client, left);
    else peeksBy.delete(client);
  };
  /// When each client's refusal, by its reason, was last logged.
  const refusalsLogged = new Map<string, number>();
  /// The answer to a view that is refused before it opens, with a line in the station's log: the client's card may show
  /// nothing of it.
  const refuseView = (admitted: Admitted, id: string, status: number, error: string, peek = false): MeshReply => {
    const client = admitted.viewer.device;
    const key = `${client}\n${status}\n${error}`;
    const now = wall.now();
    const last = refusalsLogged.get(key);
    if (last === undefined || now - last >= REFUSAL_LOG_MS) {
      if (refusalsLogged.size >= MAX_REFUSALS_KEPT) refusalsLogged.clear();
      refusalsLogged.set(key, now);
      log.info("screens", "a view was refused", { screen: id, status, error, peek, device: client.slice(0, 12) });
    }
    return json(status, { error });
  };

  const list = async (admitted: Admitted, devices: boolean): Promise<MeshReply> => {
    // No access says why when a view is asked for; a client that sees nothing here goes another way.
    const refused = why(o, admitted);
    if (refused?.status === 401 || refused?.status === 502) return json(refused.status, { error: refused.error });
    // A device is left out, and adb not woken, where a view of it would be refused.
    const shown = devices && refused === null;
    if (shown) await Promise.all([o.devices?.refresh(), o.simulators?.refresh()]);
    const unavailable = shown ? (o.devices?.unavailable() ?? null) : null;
    const phones = shown ? o.devices?.phones : undefined;
    return json(200, {
      screens: o.sources().filter((s) => shown || !isDevice(s)).map(listed),
      codecs: ["h264"],
      ...(shown ? { avds: (await o.devices?.startable()) ?? [], simulators: o.simulators?.bootable() ?? [] } : {}),
      ...(phones ? { phones: { usb: phones.choices().usb, list: phones.phones() } } : {}),
      ...(unavailable ? { devicesUnavailable: unavailable } : {}),
    });
  };

  /// What only one who may drive may do of a device.
  const refusedDriving = (admitted: Admitted): MeshReply | null => {
    const refused = why(o, admitted);
    if (refused) return json(refused.status, { error: refused.error });
    return o.mayControl(admitted) ? null : json(403, { error: "only one who may drive this computer may do that" });
  };

  const start = async (admitted: Admitted, body: AsyncIterable<Uint8Array>, signal: AbortSignal): Promise<MeshReply> => {
    const refused = refusedDriving(admitted);
    if (refused) return refused;
    const asked = (await jsonOf(body, MAX_START_BODY)) as { avd?: unknown; simulator?: unknown } | null;
    const avd = asked?.avd, simulator = asked?.simulator;
    if (typeof avd !== "string" && typeof simulator !== "string") return json(400, { error: "avd or simulator: the device to start" });
    // What allowed it is looked at again after the body, and again just before the emulator is started: access may go
    // meanwhile.
    const still = refusedDriving(admitted);
    if (still) return still;
    if (signal.aborted) return json(499, { error: "given up" });
    const allowed = () => refusedDriving(admitted) === null && !signal.aborted;
    const id = typeof avd === "string" ? await o.devices?.start(avd, allowed) : await o.simulators?.boot(simulator as string, allowed);
    const after = refusedDriving(admitted);
    if (after) return after;
    return id ? json(200, { id }) : json(422, { error: "that device could not be started" });
  };

  /// A person closes an emulator at their word: nothing here does of itself.
  const close = async (admitted: Admitted, id: string, body: AsyncIterable<Uint8Array>): Promise<MeshReply> => {
    const refused = refusedDriving(admitted);
    if (refused) return refused;
    const instance = ((await jsonOf(body, MAX_START_BODY)) as { instance?: unknown } | null)?.instance;
    const source = o.sources().find((s) => s.id === id);
    if (!source) return json(404, { error: "no such screen" });
    // (a device whose instance could not be told is not closed from here: it may be another by now)
    if (isDevice(source) && (source.instance === undefined || instance !== source.instance)) return json(409, { error: REPLACED });
    const still = refusedDriving(admitted);
    if (still) return still;
    if (!source.discard) return json(405, { error: "this screen is not closed from here" });
    try {
      await source.discard();
    } catch (error) {
      if (error instanceof ScreenRefused) return json(error.status, { error: error.message });
      throw error;
    }
    return json(200, {});
  };

  /// A simulator's case, one panel's pictures turned as asked (still.fail's `GET …/chrome/<panel>/<turn>`): to one who may
  /// see its screen, as the list is. They are made of Apple's PDFs on this Mac and go nowhere else.
  const chrome = async (admitted: Admitted, id: string, panel: number, turn: number): Promise<MeshReply> => {
    const refused = why(o, admitted);
    if (refused) return json(refused.status, { error: refused.error });
    const made = o.sources().find((s) => s.id === id)?.chrome?.[panel];
    if (made === undefined) return json(404, { error: "no such screen, or it has no case" });
    try {
      return json(200, await picturesOf(made, turn));
    } catch (error) {
      return json(502, { error: (error as Error).message.split("\n").at(-1)?.slice(0, 300) ?? "" });
    }
  };

  /// The owner chooses phones: USB on or off, a phone shown or not and whether agents may use it, one over Wi-Fi
  /// connected or let go of. Answers the phones as the list gives them.
  const choosePhones = async (admitted: Admitted, body: AsyncIterable<Uint8Array>): Promise<MeshReply> => {
    const refused = refusedDriving(admitted);
    if (refused) return refused;
    const phones = o.devices?.phones;
    if (!phones) return json(404, { error: "this computer lists no phones" });
    const ask = (await jsonOf(body, MAX_START_BODY)) as Record<string, unknown> | null;
    if (ask === null || typeof ask !== "object") return json(400, { error: "what to change, as JSON" });
    const still = refusedDriving(admitted);
    if (still) return still;
    let said: string | undefined;
    try {
      if (typeof ask.usb === "boolean") await phones.setUsb(ask.usb);
      else if (typeof ask.serial === "string" && typeof ask.shown === "boolean") await phones.choose(ask.serial, ask.shown ? { agents: ask.agents === true } : null);
      else if (typeof ask.connect === "string") said = await phones.connect(ask.connect);
      else if (typeof ask.disconnect === "string") said = await phones.disconnect(ask.disconnect);
      else return json(400, { error: "one of {usb}, {serial, shown, agents}, {connect}, {disconnect}" });
    } catch (error) {
      return json(422, { error: (error as Error).message });
    }
    await o.devices!.refresh();
    return json(200, { usb: phones.choices().usb, list: phones.phones(), ...(said !== undefined ? { said } : {}) });
  };

  /// The clients with a view of a source in Control now, how many of them each: the views' own `drive` keeps it.
  const driving = new Map<ScreenSource, Map<string, number>>();
  const startDriving = (source: ScreenSource, client: string) => {
    const clients = driving.get(source) ?? new Map<string, number>();
    driving.set(source, clients);
    clients.set(client, (clients.get(client) ?? 0) + 1);
    return () => {
      const left = (clients.get(client) ?? 1) - 1;
      if (left > 0) clients.set(client, left);
      else clients.delete(client);
      if (clients.size === 0) driving.delete(source);
    };
  };
  const installing = new Set<ScreenSource>();

  /// One thing done to a device, by a client driving it now (the file comment's rules).
  const debug = async (admitted: Admitted, id: string, action: string, query: URLSearchParams, request: Pick<ServedRequest<Admitted>, "body" | "signal">): Promise<MeshReply> => {
    const refused = refusedDriving(admitted);
    if (refused) return refused;
    const source = o.sources().find((s) => s.id === id);
    if (!source) return json(404, { error: "no such screen" });
    const d = source.debug;
    if (!d) return json(405, { error: "this screen has nothing to debug" });
    const allowedNow = () => {
      const denied = refusedDriving(admitted);
      if (denied) return denied;
      if (request.signal.aborted) return json(499, { error: "given up" });
      if (o.sources().find((s) => s.id === id) !== source || source.instance === undefined || query.get("instance") !== source.instance) return json(409, { error: REPLACED });
      if (!driving.get(source)?.has(admitted.viewer.device)) return json(403, { error: "only a view in Control may do that" });
      return null;
    };
    const validate = async () => {
      const denied = allowedNow();
      if (denied) return denied;
      if (!source.current || !(await source.current())) return json(409, { error: REPLACED });
      return allowedNow();
    };
    const can = (one: DeviceDebugAction) => d.actions.includes(one);
    const unable = json(405, { error: "this device cannot do that" });
    try {
      const denied = await validate();
      if (denied) return denied;
      switch (action) {
        case "state":
          return json(200, await d.state());
        case "restart": {
          if (!can("restart")) return unable;
          const restarted = await d.restart();
          return restarted ? json(200, restarted) : json(404, { error: "no app of yours is running on it" });
        }
        case "screenshot":
          if (!can("screenshot")) return unable;
          return { status: 200, headers: [["content-type", "image/png"]], body: await d.screenshot() };
        case "appearance": {
          if (!can("appearance")) return unable;
          const value = query.get("value");
          if (value !== "light" && value !== "dark") return json(400, { error: "appearance: light or dark" });
          await d.setAppearance(value);
          return json(200, { appearance: value });
        }
        case "record": {
          if (!can("record")) return unable;
          const panel = query.get("panel");
          await d.recordStart(panel === "inner" || panel === "cover" ? panel : null);
          return json(200, { recording: true });
        }
        case "record-stop": {
          if (!can("record")) return unable;
          const movie = await d.recordStop();
          if (movie === null) return json(404, { error: "nothing is being recorded" });
          const stream = createReadStream(movie.path);
          stream.once("close", () => movie.release?.());
          const abort = () => stream.destroy();
          request.signal.addEventListener("abort", abort, { once: true });
          stream.once("close", () => request.signal.removeEventListener("abort", abort));
          if (request.signal.aborted) abort();
          return { status: 200, headers: [["content-type", "video/mp4"]], body: stream };
        }
        case "install": {
          if (!can("install")) return unable;
          const type = d.installTypes.find((one) => (query.get("name") ?? "").toLowerCase().endsWith(one));
          if (type === undefined) return json(400, { error: `an app to install is a file of ${d.installTypes.join(", ")}` });
          if (installing.has(source)) return json(503, { error: "another app is being installed on it" });
          installing.add(source);
          try {
            const path = join(d.installFolder(), `${randomBytes(8).toString("hex")}${type}`);
            const whole = await receive(path, request.body, MAX_INSTALL_BYTES).catch(async (error: Error) => {
              await rm(path, { force: true });
              throw error;
            });
            if (!whole) {
              await rm(path, { force: true });
              return json(413, { error: "that file is too large" });
            }
            try {
              const denied = await validate();
              if (denied) return denied;
              const installed = await d.install(path);
              return installed ? json(200, installed) : json(400, { error: "there is no app in that file" });
            } finally {
              await rm(path, { force: true });
            }
          } finally {
            installing.delete(source);
          }
        }
        default:
          return json(404, { error: "no such action" });
      }
    } catch (error) {
      if (error instanceof ScreenRefused) return json(error.status, { error: error.message });
      // (the command's own last line: what is before it is what it ran and how it came to that)
      const said = (error as Error).message.split("\n").map((l) => l.trim()).filter(Boolean).at(-1) ?? "";
      log.info("screens", "a device's debug action failed", { screen: id, action, error: said.slice(0, 300) });
      return json(502, { error: said.slice(0, 500) });
    }
  };

  /// A device's running app's logs, to one who may drive it, for as long as the request's body is open.
  const logs = (admitted: Admitted, id: string, query: URLSearchParams, request: Pick<ServedRequest<Admitted>, "body" | "signal">): MeshReply => {
    const refused = refusedDriving(admitted);
    if (refused) return refused;
    const source = o.sources().find((s) => s.id === id);
    if (!source) return json(404, { error: "no such screen" });
    if (!source.logs) return json(405, { error: "this screen has no app logs" });
    if (isDevice(source) && source.instance !== undefined && query.get("instance") !== source.instance) return json(409, { error: REPLACED });
    const mode = query.get("mode") === "all" ? "all" : "app";
    const app = query.get("app") || null;
    if (app !== null && !BUNDLE_ID.test(app)) return json(400, { error: "app: a bundle id or package name" });
    if (logStreams >= MAX_LOG_STREAMS) return json(503, { error: `at most ${MAX_LOG_STREAMS} app logs can be read at once` });
    const feed = source.logs.feed(mode, app);
    if (feed === null) return json(503, { error: "this device's logs are read with other filters now" });
    logStreams++;
    const session = new LogSession(feed, { mode, ...(app ? { app } : {}) }, request.signal, o.after ?? wall.after);
    const unlisten = o.listen(() => {
      const denied = refusedDriving(admitted);
      if (denied) session.stop(isDevice(source) && o.sources().find((s) => s.id === id) !== source ? REPLACED : "access changed");
    });
    const stopExpiry = atExpiry(admitted.exp * 1000, () => session.stop("credential expired"));
    void session.run(request.body).finally(() => {
      logStreams--;
      unlisten();
      stopExpiry();
    });
    return { status: 200, headers: [["content-type", SCREEN_TYPE]], body: session.frames() };
  };

  const view = async (admitted: Admitted, id: string, request: Pick<ServedRequest<Admitted>, "headers" | "body" | "signal">, via: () => string | null, link: () => LinkStats | null): Promise<MeshReply> => {
    const refused = why(o, admitted);
    if (refused) return refuseView(admitted, id, refused.status, refused.error);
    const source = o.sources().find((s) => s.id === id);
    if (!source) return refuseView(admitted, id, 404, "no such screen");
    const ask = askOf(request.headers);
    if (ask === null) return refuseView(admitted, id, 400, `${SCREEN_HEADER}: what the view asks, as JSON`);
    const peek = ask.peek === true;
    if (peek && !source.peek) return refuseView(admitted, id, 501, "this screen cannot be previewed", peek);
    // A device is viewed only as the instance the client picked: another may have its place (`ScreenSource.instance`).
    if (isDevice(source) && source.instance !== undefined && ask.instance !== source.instance) return refuseView(admitted, id, 409, REPLACED, peek);
    // What both take, in the source's order (a simulator: H.265 before H.264, and JPEG for a preview).
    const codecs = (source.codecs ?? ["h264"]).filter((codec) => ask.codecs.includes(codec));
    if (!codecs.some((codec) => codec !== "jpeg")) return refuseView(admitted, id, 415, "this computer sends H.264 or H.265 only", peek);
    const member = admitted.viewer.sub;
    // The client's own endpoint, which `verifyMember` held its credential to: two computers of one person are two clients.
    const client = admitted.viewer.device;
    if (peek) {
      if ((peeksBy.get(client) ?? 0) >= MAX_PEEKS_A_CLIENT) return refuseView(admitted, id, 503, `one client can preview at most ${MAX_PEEKS_A_CLIENT} screens at once`, peek);
      if (peeks >= MAX_PEEKS) return refuseView(admitted, id, 503, `at most ${MAX_PEEKS} screens can be previewed at once`, peek);
    } else {
      if (open >= MAX_VIEWS) return refuseView(admitted, id, 503, `at most ${MAX_VIEWS} screens can be viewed at once`);
      if ((openBy.get(member) ?? 0) >= MAX_VIEWS_A_MEMBER) return refuseView(admitted, id, 503, `one member can view at most ${MAX_VIEWS_A_MEMBER} screens at once`);
    }
    // Whether this view may ever drive: a preview only looks, and a device whose instance could not be told is only
    // looked at (what drives it may reach another in its place). Such a view's source takes input from the station
    // (its helper is told so at open); which input goes is the view's current Watch or Control, per event, here.
    const drivable = !peek && o.mayControl(admitted) && !(isDevice(source) && source.instance === undefined);
    /// Why this view may not drive now: the credential and access (`why`), whether one may drive, not a preview, and a
    /// device still the source listed for its id (same object, so the same instance; its boot is not read again). Null:
    /// it may.
    const refusedControl = (): string | null => {
      const refused = why(o, admitted);
      if (refused) return refused.error;
      if (!drivable) return peek ? "a preview only looks" : "this view only looks";
      if (!o.mayControl(admitted)) return "only one who may drive this computer may do that";
      if (isDevice(source) && o.sources().find((s) => s.id === id) !== source) return REPLACED;
      return null;
    };
    // A person driving a device holds an agent's input off it until they let go of it, or the view ends.
    let release: (() => void) | null = null;
    const drive = (on: boolean): string | null => {
      if (!on) {
        release?.();
        release = null;
        return null;
      }
      const refused = refusedControl();
      if (refused === null && release === null) {
        const held = source.hold?.();
        const marked = startDriving(source, client);
        release = () => {
          held?.();
          marked();
        };
      }
      return refused;
    };
    // Its place, held from here until the view ends or its client gives up, once.
    let holds = true;
    const freed = () => {
      if (!holds) return;
      holds = false;
      if (peek) freePeek(client);
      else free(member);
    };
    if (peek) takePeek(client);
    else take(member);
    // A client that gives up while the source opens (another screen chosen meanwhile) says so only on its stream, which
    // it resets: it is read from now, and the place is free at once, not when the source has opened (a phone's takes
    // seconds). A stream that finishes is a view's ordinary end, said once it runs (`ViewSession`'s "finished").
    const sent = request.body[Symbol.asyncIterator]();
    let gaveUp = false;
    const first = sent.next().catch((error: unknown) => {
      gaveUp = true;
      freed();
      throw error;
    });
    first.catch(() => {});
    const body = (async function* () {
      const next = await first;
      if (next.done) return;
      yield next.value;
      yield* { [Symbol.asyncIterator]: () => sent };
    })();
    let screen: ScreenView;
    const bounds = { maxWidth: ask.maxWidth ?? 1920, maxHeight: ask.maxHeight ?? 1080 };
    const timed = timing && !peek;
    try {
      // Its first frame, a whole picture, is its largest: at START_RATE on a narrow link too.
      // The client draws the pointer (`cursor` states): a source that can leaves it out of a view's pictures. A preview's
      // keep it, as still.fail's JPEG pictures do.
      const options: HelperViewOptions = { maxWidth: bounds.maxWidth, maxHeight: bounds.maxHeight, codecs: codecs as Codec[], control: drivable, bitrate: START_RATE, ...(ask.peek ? { peek: true } : { cursor: true }), ...(ask.audio ? { audio: true, ...(ask.audio === "opus" ? { opus: true } : {}) } : {}), ...(ask.apps ? { apps: ask.apps } : {}), ...(ask.background ? { background: ask.background } : {}), ...(timed ? { timing: true } : {}) };
      screen = await source.open(options);
    } catch (error) {
      freed();
      if (error instanceof ScreenRefused) return json(error.status, { error: error.message });
      log.info("screens", "a screen did not open", { screen: id, error: (error as Error).message });
      return json(503, { error: (error as Error).message });
    }
    if (request.signal.aborted || gaveUp) {
      freed();
      screen.close();
      return json(499, { error: "given up" });
    }
    // Opening takes its time (starting the helper, its capture), and what allowed it may have gone meanwhile. From here
    // to `listen` nothing waits, so nothing is missed.
    const denied = why(o, admitted);
    if (denied) {
      freed();
      screen.close();
      return json(denied.status, { error: denied.error });
    }
    const control = ask.control && drive(true) === null;
    const session = new ViewSession(screen, control, drive, isDevice(source) ? deviceInput : helperInput, request.signal, () => why(o, admitted), o.after ?? wall.after, { peek, via, bounds, ...(ask.quality ? { quality: ask.quality } : {}), clipboard: source.clipboard?.() ?? [], audio: ask.audio !== undefined && !peek, link, ...(timed ? { timing: { fields: { view: ++opened, screen: id }, link: () => ({ via: via(), ...link() }), ...(o.timingLine ? { line: o.timingLine } : {}) } } : {}) });
    const unlisten = o.listen(() => session.look());
    // It ends when its credential does: a client that keeps its connection renews it for what comes next, and opens anew.
    const stopExpiry = atExpiry(admitted.exp * 1000, () => session.look());
    let unwatchAgent: (() => void) | undefined;
    void session.run(body).finally(() => {
      freed();
      drive(false);
      unwatchAgent?.();
      unlisten();
      stopExpiry();
    });
    // After the view's first state (`run` said it): whether an agent's lease on the device lasts, each time that
    // changes, and where the agent's finger is as it acts. A preview is told none of it.
    if (!peek) unwatchAgent = source.watchAgent?.((said) => session.say(said));
    return { status: 200, headers: [["content-type", SCREEN_TYPE]], body: session.frames() };
  };

  return {
    async catalog() {
      if (!o.up()) return { screens: [], avds: [], simulators: [], refused: "the station is not started" };
      if (o.access() !== "full") return { screens: [], avds: [], simulators: [], refused: "this computer does not allow its screen to be viewed: its access is not Full" };
      await Promise.all([o.devices?.refresh(), o.simulators?.refresh()]);
      const unavailable = o.devices?.unavailable() ?? null;
      return {
        screens: o.sources().map(listed),
        avds: (await o.devices?.startable()) ?? [],
        simulators: o.simulators?.bootable() ?? [],
        ...(unavailable ? { devicesUnavailable: unavailable } : {}),
      };
    },
    handle(admitted, request, via = () => null, link = () => null) {
      const path = request.path.split("?", 1)[0]!;
      const method = request.method.toUpperCase();
      if (path === LIST) return method === "GET" ? list(admitted, new URLSearchParams(request.path.split("?", 2)[1] ?? "").get("devices") === "1") : Promise.resolve(json(405, { error: "the screens are listed with GET" }));
      if (path === PHONES) return method === "POST" ? choosePhones(admitted, request.body) : Promise.resolve(json(405, { error: "phones are chosen with POST" }));
      if (path === START) return method === "POST" ? start(admitted, request.body, request.signal) : Promise.resolve(json(405, { error: "a device is started with POST" }));
      const cased = CHROME.exec(path);
      if (cased !== null) return method === "GET" ? chrome(admitted, decodeURIComponent(cased[1]!), Number(cased[2]), Number(cased[3])) : Promise.resolve(json(405, { error: "a case is read with GET" }));
      const closing = CLOSE.exec(path);
      if (closing !== null) return method === "POST" ? close(admitted, decodeURIComponent(closing[1]!), request.body) : Promise.resolve(json(405, { error: "a device is closed with POST" }));
      const logged = LOGS.exec(path);
      if (logged !== null) return Promise.resolve(method === "POST" ? logs(admitted, decodeURIComponent(logged[1]!), new URLSearchParams(request.path.split("?", 2)[1] ?? ""), request) : json(405, { error: "logs are read with POST" }));
      const debugged = DEBUG.exec(path);
      if (debugged !== null) return method === "POST" ? debug(admitted, decodeURIComponent(debugged[1]!), debugged[2]!, new URLSearchParams(request.path.split("?", 2)[1] ?? ""), request) : Promise.resolve(json(405, { error: "a device is debugged with POST" }));
      const found = VIEW.exec(path);
      if (found === null) return null;
      if (method !== "POST") return Promise.resolve(json(405, { error: "a screen is viewed with POST" }));
      return view(admitted, decodeURIComponent(found[1]!), request, via, link);
    },
  };
}

/// `body` written to a new file at `path`; false when it is past `most` bytes.
async function receive(path: string, body: AsyncIterable<Uint8Array>, most: number): Promise<boolean> {
  const file = await open(path, "wx");
  try {
    let size = 0;
    for await (const chunk of body) {
      size += chunk.length;
      if (size > most) return false;
      await file.write(chunk);
    }
    return true;
  } finally {
    await file.close();
  }
}

/// One reader of a device's app logs while it lasts: what goes out as the reply's body. Lines wait here at most
/// READER_QUEUE (the oldest dropped and counted past it) for a client that reads slower than they come.
class LogSession {
  readonly #feed: AppLogFeed;
  readonly #filter: { mode: string; app?: string };
  readonly #after: (ms: number, f: () => void) => () => void;
  #lines: AppLogLine[] = [];
  #dropped = 0;
  #ended: string | null = null;
  #over = false;
  #leave: () => void = () => {};
  #wake: () => void = () => {};
  #stopAlive: () => void = () => {};
  #done!: () => void;
  readonly #finished = new Promise<void>((resolve) => (this.#done = resolve));

  constructor(feed: AppLogFeed, filter: { mode: string; app?: string }, signal: AbortSignal, after: (ms: number, f: () => void) => () => void) {
    this.#feed = feed;
    this.#filter = filter;
    this.#after = after;
    signal.addEventListener("abort", () => this.#abandon(), { once: true });
  }

  /// Ends it once: the reader leaves its feed (the last to leave stops its process), and the client is told `reason`.
  stop(reason: string) {
    if (this.#ended !== null || this.#over) return;
    this.#ended = reason;
    this.#leave();
    this.#stopAlive();
    this.#wake();
  }

  #abandon() {
    this.#over = true;
    this.#leave();
    this.#stopAlive();
    this.#lines = [];
    this.#wake();
    this.#done();
  }

  async run(body: AsyncIterable<Uint8Array>): Promise<void> {
    this.#leave = this.#feed.join({
      lines: (lines, dropped) => {
        this.#dropped += dropped;
        this.#lines.push(...lines);
        if (this.#lines.length > READER_QUEUE) this.#dropped += this.#lines.splice(0, this.#lines.length - READER_QUEUE).length;
        this.#wake();
      },
      ended: (reason) => this.stop(reason),
    });
    this.#alive();
    // What the client sends is nothing but its stream kept open: its end is the panel closed.
    try {
      for await (const _ of body) if (this.#over || this.#ended !== null) break;
      this.stop("finished");
    } catch {
      this.#abandon();
    }
    await this.#finished;
  }

  /// It says it is alive while nothing else goes; one such word waits at most, however long the client reads nothing.
  #alive() {
    this.#stopAlive = this.#after(ALIVE_MS, () => {
      if (this.#ended !== null || this.#over) return;
      if (this.#lines.length === 0 && !this.#aliveDue) {
        this.#aliveDue = true;
        this.#wake();
      }
      this.#alive();
    });
  }

  #aliveDue = false;

  async *frames(): AsyncGenerator<Uint8Array> {
    try {
      yield encodeScreenJson(ScreenKind.state, { logs: this.#filter });
      for (;;) {
        if (this.#over) return;
        if (this.#aliveDue) {
          this.#aliveDue = false;
          yield encodeScreenJson(ScreenKind.state, { alive: true });
          continue;
        }
        if (this.#lines.length > 0) {
          const lines = this.#lines.splice(0, LOG_BATCH);
          const dropped = this.#dropped;
          this.#dropped = 0;
          yield encodeScreenJson(ScreenKind.state, { lines, ...(dropped > 0 ? { dropped } : {}) });
          continue;
        }
        if (this.#ended !== null) {
          yield encodeScreenJson(ScreenKind.state, { ended: this.#ended });
          return;
        }
        await new Promise<void>((resolve) => (this.#wake = resolve));
      }
    } finally {
      this.#abandon();
    }
  }
}

/// One view while it lasts: what goes out as the reply's body, what comes in as the request's.
class ViewSession {
  readonly #view: ScreenView;
  /// Control (input goes) or Watch, as the client last switched it and the station let it.
  #control: boolean;
  /// Asks to drive (null: it may) or lets go.
  readonly #drive: (on: boolean) => string | null;
  readonly #inputOf: (event: unknown) => ScreenInput | null;
  readonly #denied: () => { error: string } | null;
  readonly #after: (ms: number, f: () => void) => () => void;
  /// Whose loop stands still is not the link's fault (screen-pace.ts LoopStall).
  readonly #stall = loopStall.use();
  readonly #pacer = new Pacer(hostNow, START_RATE, undefined, this.#stall.stalled);
  readonly #latency = new FrameLatency();
  /// Where each frame's time went, logged (screen-timing.ts); null: not asked.
  readonly #timing: FrameTiming | null;
  #rate: number | null = null;
  /// A preview's: its rate no higher than the source's own (still.fail#4384).
  readonly #peek: boolean;
  /// The 画质 the view asked (none: 自动, or a client from before it): the most its bit rate goes to, and whether its
  /// picture is made smaller (screen-pace.ts rateCeiling, Sizer).
  readonly #quality: Quality | undefined;
  /// How the view's connection runs now; and the picture's size and the way the bit rate's ceiling was last set for.
  readonly #via: () => string | null;
  #size: { width: number; height: number } | null = null;
  #ceilingVia: string | null = null;
  /// What the native mesh says of the view's connection (its round trip goes to the pace: screen-pace.ts LINK_SLACK_MS),
  /// read at most each LINK_READ_MS.
  readonly #link: () => LinkStats | null;
  #linkRead = -Infinity;
  #ceiling: number | null = null;
  /// How the pictures are made as last said (the statistics' capture and encoder).
  #video: ScreenVideo | null = null;
  /// The picture made smaller while the link carries little, and its size again once it carries more (screen-pace.ts
  /// Sizer, still.fail's): a preview's never (it is small, and its rate the source's own).
  readonly #sizer: Sizer | null;
  /// A still screen's picture sent again sharper (screen-pace.ts Sharpener).
  readonly #sharpen = new Sharpener();
  #stillWait = false;
  /// The clipboard's types the source carries, and what stops hearing its copies (watched while the view drives).
  readonly #clipTypes: readonly ClipType[];
  #unclip: (() => void) | null = null;
  /// The system output was asked (not of a preview).
  readonly #audioAsked: boolean;
  /// Whether the view's sound is on (`sound`), and what wakes the sound once it is again.
  #soundOn = true;
  #soundWake: () => void = () => {};
  /// What is to go, in order, each told when it went (or never, once the view ended); a video frame's `ts`.
  #out: { bytes: Uint8Array; went: () => void; ts?: number }[] = [];
  /// The inputs posted so far: each waits for the one before (still.fail mesh/screens.ts `#then`).
  #inputs: Promise<void> = Promise.resolve();
  #more: () => void = () => {};
  #wake: () => void = () => {};
  #closed = false;
  #finished = false;
  #done!: () => void;
  readonly #over = new Promise<void>((resolve) => (this.#done = resolve));

  constructor(view: ScreenView, control: boolean, drive: (on: boolean) => string | null, inputOf: (event: unknown) => ScreenInput | null, signal: AbortSignal, denied: () => { error: string } | null, after: (ms: number, f: () => void) => () => void, o: { peek?: boolean; via?: () => string | null; bounds?: { maxWidth: number; maxHeight: number }; quality?: Quality; clipboard?: readonly ClipType[]; audio?: boolean; link?: () => LinkStats | null; timing?: ConstructorParameters<typeof FrameTiming>[0] } = {}) {
    this.#after = after;
    this.#timing = o.timing ? new FrameTiming({ ...o.timing, pace: () => ({ rate: this.#pacer.rate(), rtt: this.#pacer.rtt(), through: this.#pacer.through(), unacked: this.#pacer.unacked, stalled: this.#stall.stalled() }) }) : null;
    this.#clipTypes = o.clipboard ?? [];
    this.#audioAsked = o.audio === true && o.peek !== true;
    this.#peek = o.peek === true;
    this.#quality = this.#peek ? undefined : o.quality;
    this.#sizer = o.bounds && !this.#peek ? new Sizer(hostNow, o.bounds, this.#quality) : null;
    this.#via = o.via ?? (() => null);
    this.#link = o.link ?? (() => null);
    this.#view = view;
    this.#control = control;
    this.#drive = drive;
    this.#inputOf = inputOf;
    this.#denied = denied;
    signal.addEventListener("abort", () => this.#abandon(), { once: true });
  }

  /// What its source says beside its pictures (an agent's lease on a device, where its finger is), as a `state`.
  say(state: Record<string, unknown>) {
    if (!this.#closed) void this.#send(encodeScreenJson(ScreenKind.state, state));
  }

  /// What was allowed may be no longer.
  look() {
    const denied = this.#denied();
    if (denied) this.#stop(denied.error);
  }

  /// The reply's body. Returning early (the stream broke) ends the view.
  async *frames(): AsyncGenerator<Uint8Array> {
    try {
      for (;;) {
        const next = this.#out.shift();
        if (next) {
          if (next.ts !== undefined) this.#timing?.writing(next.ts);
          yield next.bytes;
          next.went();
          continue;
        }
        if (this.#finished) return;
        await new Promise<void>((resolve) => (this.#more = resolve));
      }
    } finally {
      this.#abandon();
    }
  }

  /// The stream broke, whatever was still to go on it: nothing more goes, and the view is over.
  #abandon() {
    this.#stop(null);
    for (const pending of this.#out.splice(0)) pending.went();
    this.#finished = true;
    this.#more();
    this.#done();
  }

  #send(bytes: Uint8Array, ts?: number): Promise<void> {
    return new Promise((went) => {
      if (this.#finished) return went();
      this.#out.push({ bytes, went, ...(ts !== undefined ? { ts } : {}) });
      const more = this.#more;
      this.#more = () => {};
      more();
    });
  }

  /// Ends the view once: its capture stops, and the client is told `reason` (null: it is told nothing).
  #stop(reason: string | null, endedCode?: "screen_refused") {
    if (this.#closed) return;
    this.#closed = true;
    this.#clip(false);
    this.#view.close();
    this.#stall.done();
    this.#timing?.end();
    this.#wake();
    this.#soundWake();
    if (reason === null) return;
    // Said after all that was waiting to go; a client that stopped reading does not keep its place for it.
    const stopWaiting = this.#after(ENDED_MS, () => this.#abandon());
    void this.#send(encodeScreenJson(ScreenKind.state, { ended: reason, ...(endedCode ? { endedCode } : {}) })).then(() => {
      stopWaiting();
      this.#finished = true;
      this.#more();
      this.#done();
    });
  }

  async run(body: AsyncIterable<Uint8Array>): Promise<void> {
    // (`switches`: this view takes `control` frames; a station from before says nothing of it.) How its pictures are made
    // (the statistics' capture and encoder), where the source says it yet, as still.fail's first state: a source that
    // makes its encoder with the first picture says it with that picture (`#tellVideo`).
    this.#video = this.#view.video?.() ?? null;
    void this.#send(encodeScreenJson(ScreenKind.state, { control: this.#control, switches: true, ...(this.#view.target?.() ?? {}), ...(this.#video ? { video: this.#video } : {}), ...(this.#timing ? { timing: true } : {}) }));
    const stopListening = this.#view.onTarget?.(() => {
      if (!this.#closed) void this.#send(encodeScreenJson(ScreenKind.state, { ...(this.#view.target?.() ?? {}) }));
    });
    const stopWatching = this.#view.watchDevice?.((stands) => {
      if (!this.#closed) void this.#send(encodeScreenJson(ScreenKind.state, stands));
    });
    // The pointer of a source whose pictures leave it out (the Mac helper's desktop asked `cursor`, Windows' desktop
    // video), as still.fail's mesh/screens.ts says it: the state's `cursor`, which the client draws.
    const stopPointing = this.#view.watchCursor?.((cursor) => {
      if (!this.#closed) void this.#send(encodeScreenJson(ScreenKind.state, { cursor }));
    });
    this.#clip(this.#control);
    this.#alive();
    void this.#read(body);
    if (this.#audioAsked && this.#view.nextAudio) void this.#audio();
    await this.#pump();
    await this.#over;
    stopListening?.();
    stopWatching?.();
    stopPointing?.();
  }

  /// The screen's clipboard heard (a copy made on it goes to the client) while the view drives, and no longer once it
  /// only watches or ends: never to one that only looks (still.fail's `run` and `#watchOnly`).
  #clip(on: boolean) {
    if (!on || this.#closed) {
      this.#unclip?.();
      this.#unclip = null;
      return;
    }
    if (this.#unclip || this.#clipTypes.length === 0 || !this.#view.watchClipboard) return;
    this.#unclip = this.#view.watchClipboard((clip) => {
      if (!this.#closed && this.#control && this.#clipTypes.includes(clip.type) && clipFits(clip)) void this.#send(encodeScreenFrame(ScreenKind.clipboard, clipPayload(clip)));
    });
  }

  /// The system output, one packet in flight: the next is asked once the last went on the stream, so the link's
  /// backpressure never builds a queue of sound behind the pictures (still.fail's `#audio`). Its format first, as the
  /// first packet says it (Opus where the view asked it and the source encodes it, else PCM), muted or not. While the
  /// view's sound is off (`sound` 0: the client muted it) nothing more is asked: what the source keeps meanwhile is its
  /// last 300 ms. A packet
  /// is left out while the pictures wait in front of the link (`Pacer.backlogged`): the stream takes it at once whatever
  /// the link carries, and its 1.5 Mbit/s (48 kHz stereo PCM) on a relay of a few hundred kbit/s held every picture
  /// seconds behind it (2026-11-11).
  async #audio(): Promise<void> {
    let configured = false;
    try {
      while (!this.#closed) {
        const next = await this.#view.nextAudio!();
        if (this.#closed || next === null) break;
        // (said muted or not: the client shows the sound and its switch by it)
        if (!configured) {
          await this.#send(encodeScreenJson(ScreenKind.audioConfig, { ...SCREEN_AUDIO, codec: next.codec }));
          configured = true;
        }
        if (!this.#soundOn) {
          await new Promise<void>((resolve) => (this.#soundWake = resolve));
          continue;
        }
        if (this.#pacer.backlogged()) continue;
        await this.#send(encodeScreenAudio(next.ts, next.data));
      }
    } catch (error) {
      log.info("screens", "system audio ended", { error: String(error) });
    }
  }

  #alive() {
    wall.after(ALIVE_MS, () => {
      if (this.#closed) return;
      // Behind what is waiting to go it says nothing new: that going is the sign.
      if (this.#out.length === 0) void this.#send(encodeScreenJson(ScreenKind.state, { alive: true }));
      this.#alive();
    });
  }

  async #pump() {
    while (!this.#closed) {
      const now = hostNow();
      if (now - this.#linkRead >= LINK_READ_MS) {
        this.#linkRead = now;
        this.#pacer.link(this.#link()?.rttMs ?? null);
      }
      if (!this.#pacer.may()) {
        this.#asked();
        await new Promise<void>((resolve) => (this.#wake = resolve));
        continue;
      }
      let next: Frame | null;
      try {
        next = await this.#view.next();
      } catch (error) {
        if (error instanceof ScreenRefused) return this.#stop(error.message, "screen_refused");
        log.warn("screens", "a screen's frame was not had", { error: (error as Error).message });
        next = null;
      }
      if (this.#closed) return;
      if (next === null) return this.#stop("the screen stopped");
      if (next.config) {
        const { codec, width, height, description } = next.config;
        // A new size: the client makes its decoder anew (screen-pace.ts FRESH_MS).
        if (this.#size !== null && (this.#size.width !== width || this.#size.height !== height)) this.#pacer.resized();
        this.#size = { width, height };
        this.#setCeiling();
        this.#asked();
        void this.#send(encodeScreenJson(ScreenKind.config, { codec, width, height, description: Buffer.from(description ?? []).toString("base64") }));
      }
      this.#tellVideo();
      this.#pacer.sent(next.ts, next.data.length);
      this.#latency.sent(next.ts);
      this.#watchStill();
      this.#timing?.sent({ ts: next.ts, key: next.key, bytes: next.data.length, ...(next.timing ? { helper: next.timing } : {}) });
      await this.#send(encodeScreenVideo(next.key, next.ts, next.data), next.ts);
      this.#timing?.written(next.ts);
    }
  }

  /// The most the view's bit rate goes to (screen-pace.ts viewCeiling), set again as the size or the way changes.
  #setCeiling() {
    if (this.#size === null) return;
    const via = this.#via();
    this.#ceilingVia = via;
    this.#ceiling = viewCeiling(this.#size.width, this.#size.height, { peek: this.#peek, via, ...(this.#quality ? { quality: this.#quality } : {}) });
    this.#pacer.ceiling(this.#ceiling);
  }

  /// How the pictures are made, said again when that changed (an encoder made with the first picture, or anew).
  #tellVideo() {
    const video = this.#view.video?.() ?? null;
    if (video === null || (video.capture === this.#video?.capture && video.encoder === this.#video?.encoder && video.hardware === this.#video?.hardware)) return;
    this.#video = video;
    void this.#send(encodeScreenJson(ScreenKind.state, { video }));
  }

  /// Once nothing has gone for a moment, what is shown goes again at the rate the pace asks now, if that is sharper.
  #watchStill() {
    this.#sharpen.sent(hostNow(), this.#view.rate ? (this.#rate ?? START_RATE) : null);
    if (this.#stillWait) return;
    this.#stillWait = true;
    const check = () => {
      if (this.#closed) return;
      const left = this.#sharpen.left(hostNow());
      if (left > 0) return void wall.after(left, check);
      this.#stillWait = false;
      if (this.#sharpen.due(hostNow(), this.#rate)) this.#view.keyframe();
    };
    wall.after(STILL_MS, check);
  }

  /// The source asked for the bit rate the link carries, when that changed by more than a little (a source that can),
  /// and at once when the view's ceiling went below what it was asked (screen-pace.ts rateToAsk).
  #asked() {
    if (this.#via() !== this.#ceilingVia) this.#setCeiling();
    if (!this.#view.rate) return;
    const paced = this.#pacer.rate();
    const rate = rateToAsk(this.#rate, paced, this.#ceiling);
    if (rate !== null) {
      this.#rate = rate;
      this.#view.rate(Math.round(rate));
    }
    // And as small a picture as that rate makes sharpest, a source that changes its size (still.fail's `#pace`).
    if (paced !== null && this.#size && this.#sizer && this.#view.bounds) {
      const bounds = this.#sizer.step(paced, this.#pacer.through(), this.#size);
      if (bounds) {
        log.info("screens", "a view's picture resized for its link", { ...bounds, rate: Math.round(paced) });
        this.#view.bounds(bounds.maxWidth, bounds.maxHeight);
      }
    }
  }

  /// What the client says, until it finishes.
  async #read(body: AsyncIterable<Uint8Array>) {
    // A clipboard frame may be a picture's size; any other, one input event's (still.fail's `limitIn`).
    const reader = new ScreenFrameReader(screenInLimit);
    try {
      for await (const chunk of body) {
        for (const { kind, payload } of reader.push(chunk)) {
          if (this.#closed) return;
          if (kind === ScreenKind.ack) {
            const acked = parseScreenAck(payload);
            if (acked === null) continue;
            this.#pacer.acked(acked);
            this.#timing?.acked(acked, parseScreenAckTiming(payload));
            this.#latency.acked(acked, this.#pacer.rtt() ?? 0);
            const latency = this.#latency.take();
            if (latency) void this.#send(encodeScreenJson(ScreenKind.state, { latency }));
            this.#asked();
            this.#wake();
          } else if (kind === ScreenKind.received) {
            const ts = parseScreenReceived(payload);
            if (ts !== null) this.#timing?.received(ts);
          } else if (kind === ScreenKind.keyframe) this.#view.keyframe();
          else if (kind === ScreenKind.input) this.#input(payload);
          else if (kind === ScreenKind.control) this.#switch(payload);
          else if (kind === ScreenKind.setClipboard) this.#setClipboard(payload);
          else if (kind === ScreenKind.sound) this.#sound(parseScreenSound(payload));
          // Kinds of later clients: let be.
        }
      }
      this.#stop("finished");
    } catch {
      this.#abandon();
    }
  }

  /// The view's sound off (the client muted it: none is asked of the source, none goes) or on again.
  #sound(on: boolean | null) {
    if (on === null || on === this.#soundOn) return;
    this.#soundOn = on;
    if (on) {
      const wake = this.#soundWake;
      this.#soundWake = () => {};
      wake();
    }
  }

  /// Watch or Control, on this view as it runs: Watch at once, Control after `refusedControl`'s checks. The
  /// client is told which it is now, and why not when it asked Control and was refused.
  #switch(payload: Uint8Array) {
    const asked = parseScreenControl(payload);
    if (asked === null) return;
    const refused = asked ? this.#drive(true) : null;
    if (refused !== null || !asked) this.#drive(false);
    this.#control = asked && refused === null;
    this.#clip(this.#control);
    void this.#send(encodeScreenJson(ScreenKind.state, { control: this.#control, ...(refused !== null ? { refused } : {}) }));
  }

  #input(payload: Uint8Array) {
    if (!this.#control || payload.length > MAX_INPUT_BYTES) return;
    let event: unknown;
    try {
      event = JSON.parse(Buffer.from(payload).toString("utf8"));
    } catch {
      return;
    }
    const input = this.#inputOf(event);
    if (input === null) return;
    this.#then(() => this.#view.input(input));
  }

  /// A paste here (still.fail's `setClipboard` frame): only from a view that drives it now, of a type the source carries,
  /// within bounds; after the input before it.
  #setClipboard(payload: Uint8Array) {
    if (!this.#control || !this.#view.setClipboard) return;
    const asked = parseClip(payload);
    if (asked === null || !this.#clipTypes.includes(asked.clip.type)) return;
    this.#then(() => this.#view.setClipboard!(asked.clip, asked.paste));
  }

  /// What the client asks of the source, after what it asked before: a paste comes after the keys before it, and a touch
  /// after a turn that waits for adb (still.fail mesh/screens.ts `#then`).
  #then(f: () => Promise<void>) {
    this.#inputs = this.#inputs.then(f).catch((error: Error) => log.info("screens", "input not posted", { error: error.message }));
  }
}

/// The wire's input (`ScreenStreamInput`, @comma/mesh's screen-wire.ts) as the helper takes it, which happens to be near:
/// only what it knows of it, so nothing a client says reaches it as a command of its own (`stop`, `bitrate`). A source
/// with another form of input has an adapter of its own here.
export function helperInput(event: unknown): ScreenInput | null {
  if (event === null || typeof event !== "object" || !INPUT_TYPES.has((event as { type?: unknown }).type as string)) return null;
  // Text (an IME's, a paste's): the computer's form of still.fail's `{t:"text"}`, checked as its `parseInput` checks it.
  if ((event as { type: string }).type === "text") {
    const text = (event as { text?: unknown }).text;
    return typeof text === "string" && text.length > 0 && text.length <= MAX_TEXT ? { type: "text", text } : null;
  }
  return event as ScreenInput;
}

const number = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const unit = (v: number) => Math.min(1, Math.max(0, v));
const POSES = new Set(["closed", "book", "open"]);
const DEVICE_NAMES = new Set(["volume_up", "volume_down", "rotate"]);
/// How far one wheel event may say it went, in a page's pixels.
const WHEEL_MOST = 10_000;
const wheel = (v: number) => Math.min(WHEEL_MOST, Math.max(-WHEEL_MOST, v));

/// The wire's input as a device takes it (`DeviceInput`): only what it knows, checked, so nothing a client says reaches a
/// device's command line or its control socket as anything else. Names of poses and buttons are checked here and again by
/// the source, which takes a pose only by a state the device itself listed.
export function deviceInput(event: unknown): DeviceInput | null {
  if (event === null || typeof event !== "object") return null;
  const v = event as Record<string, unknown>;
  const at = number(v.x) && number(v.y) ? { x: unit(v.x), y: unit(v.y) } : null;
  const code = typeof v.code === "string" && v.code.length <= 64 ? v.code : null;
  switch (v.t) {
    case "pointer":
      return at && (v.kind === "down" || v.kind === "up" || v.kind === "move") ? { t: "pointer", kind: v.kind, ...at, buttons: number(v.buttons) ? v.buttons & 7 : 0 } : null;
    case "wheel":
      return at && number(v.dx) && number(v.dy) ? { t: "wheel", ...at, dx: wheel(v.dx), dy: wheel(v.dy) } : null;
    case "key":
      return code !== null && (v.kind === "down" || v.kind === "up") ? { t: "key", kind: v.kind, key: "", code, mods: number(v.mods) ? v.mods & 15 : 0 } : null;
    // (still.fail mesh/screens.ts `parseInput`)
    case "text":
      return typeof v.text === "string" && v.text.length > 0 && v.text.length <= MAX_TEXT ? { t: "text", text: v.text } : null;
    case "pose":
      return POSES.has(v.name as string) ? { t: "pose", name: v.name as "closed" | "book" | "open" } : null;
    case "device":
      return DEVICE_NAMES.has(v.name as string) ? { t: "device", name: v.name as "volume_up" | "volume_down" | "rotate" } : null;
    // A button of a simulator's case by its HID usage, down or up (still.fail mesh/screens.ts `parseInput`).
    case "button":
      return Number.isInteger(v.page) && Number.isInteger(v.usage) && (v.page as number) > 0 && (v.page as number) < 0x10000 && (v.usage as number) > 0 && (v.usage as number) < 0x10000 && typeof v.down === "boolean"
        ? { t: "button", page: v.page as number, usage: v.usage as number, down: v.down }
        : null;
    default:
      return null;
  }
}
