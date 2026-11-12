// Agents on the computer's Android devices: Salix's `env.android` in its `device` mode (docs/android-screen.md, "Agents
// on a device"), the device connection's `android` method. A Worker leases one device the station lists (an emulator, or
// a phone its owner chose for agents), looks at it (a screenshot, kept as a computer-use screenshot is, and whether its
// screen is on and locked) and acts on it in the screenshot's pixels: tap, swipe, text, keys, an app started. One lease a
// device; it ends at `end`, when its time is up, when the device leaves adb, or when the station stops.
//
// A phone is a person's: it is leased only where its owner turned `agents` on for it, and only with Salix's word that
// its owner allowed this chat (`consent`: the request card, Salix's own record). While one is leased it shows touches,
// and a notification on it says an agent uses it. A locked phone takes no input but `wakeup`: its owner unlocks it. While
// a person drives the device in a view of theirs, an agent's input waits for them to leave it.
//
// Each call to the device is one fixed command, its arguments checked here, pinned to the device's serial (android.ts).
import { randomBytes } from "node:crypto";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { AndroidScreen } from "./android.ts";
import type { AndroidDevices } from "./devices.ts";

type Json = Record<string, unknown>;

/// A lease's length when none is asked, and the longest (Salix also caps it by its tenant's policy).
const LEASE_DEFAULT_S = 600;
const LEASE_MOST_S = 3600;
const LEASE_LEAST_S = 60;
/// The longest text typed at once, and a swipe's longest and default time.
const TEXT_MOST = 1000;
const SWIPE_MOST_MS = 5000;
const SWIPE_DEFAULT_MS = 300;
/// How a coordinate may be at most (a screen's pixels).
const COORD_MOST = 20_000;

/// The keys an agent may press, as Android's keycodes. No power key: `wakeup` turns the screen on, and nothing here
/// turns a phone off or locks it.
export const AGENT_KEYS: Record<string, number> = {
  home: 3, back: 4, call: 5, dpad_up: 19, dpad_down: 20, dpad_left: 21, dpad_right: 22, dpad_center: 23, volume_up: 24,
  volume_down: 25, tab: 61, space: 62, enter: 66, delete: 67, menu: 82, search: 84, escape: 111, forward_delete: 112,
  move_home: 122, move_end: 123, page_up: 92, page_down: 93, app_switch: 187, wakeup: 224,
};

/// Whether its screen is on and whether it is locked, read in one call.
const STATE = "dumpsys power | grep -m1 -E 'mWakefulness='; dumpsys window | grep -m1 -E 'mDreamingLockscreen='; dumpsys deviceidle | grep -m1 -E 'mScreenLocked='";

/// What `STATE` says: `locked` is null where nothing said.
export function stateOf(said: string): { screen_on: boolean | null; locked: boolean | null } {
  const wake = /mWakefulness=(\w+)/.exec(said)?.[1];
  const dreaming = /mDreamingLockscreen=(true|false)/.exec(said)?.[1];
  const screenLocked = /mScreenLocked=(true|false)/.exec(said)?.[1];
  const locked = dreaming === undefined && screenLocked === undefined ? null : dreaming === "true" || screenLocked === "true";
  return { screen_on: wake === undefined ? null : wake === "Awake", locked };
}

/// Text as `input text` takes it in one shell word: printable ASCII only (`input text` types no other), a space as %s
/// (which `input text` alone turns back into a space, so a text with `%s` of its own cannot be typed this way).
export function textCommand(text: string): string {
  if (![...text].every((c) => c >= " " && c <= "~")) throw new AgentError("android_text_unsupported", "only printable ASCII is typed: send other text another way (clipboard is not offered here)");
  if (text.includes("%s")) throw new AgentError("android_text_unsupported", "`%s` cannot be typed: input text takes it for a space");
  const escaped = text.replaceAll(" ", "%s").replaceAll("'", "'\\''");
  return `input text '${escaped}'`;
}

/// A PNG's size, from its header; null when it is no PNG.
export function pngSize(png: Buffer): { width: number; height: number } | null {
  if (png.length < 24 || png.readUInt32BE(0) !== 0x89504e47 || png.toString("latin1", 12, 16) !== "IHDR") return null;
  return { width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
}

export class AgentError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/// Where a screenshot is kept for Salix to read it (connector/computer-use.ts `storeImage`): its path and what it is.
export type ImageStore = (png: Buffer) => Promise<Json>;

type Lease = {
  id: string;
  epoch: number;
  target: string;
  instance: string;
  phone: boolean;
  until: number;
  stopTimer: () => void;
  observation: number;
  /// What the phone's show_touches was before (null: not read).
  touches: string | null;
  /// The size of the latest screenshot, whose pixels an action's coordinates are (none before the first).
  shot?: { width: number; height: number };
};

/// Where an action presses, as a share of the screenshot its coordinates are in, for those who look at the device
/// (`AndroidScreen.agentPoints`); nothing before a screenshot says the size.
function pointer(lease: Lease, source: AndroidScreen, at: readonly number[], down: boolean) {
  const [x = 0, y = 0] = at;
  if (lease.shot) source.agentPoints({ x: x / lease.shot.width, y: y / lease.shot.height }, down);
}

/// A coordinate: a whole number of pixels within the screen.
function coord(v: unknown, name: string): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > COORD_MOST) throw new AgentError("android_bad_args", `${name}: pixels of the latest screenshot`);
  return Math.round(v);
}

function pair(v: unknown, name: string): [number, number] | null {
  if (!Array.isArray(v) || v.length !== 2) return null;
  return [coord(v[0], `${name}[0]`), coord(v[1], `${name}[1]`)];
}

const failure = (code: string, error: string): Json => ({ ok: false, error_code: code, error });

const NOTE_TAG = "comma_agent";
const NOTE_ON = "A Comma agent is using this phone. Its owner sees it in Comma and can stop it there.";
const NOTE_OFF = "The Comma agent stopped using this phone.";

/// The time leases go by (a test's own; the station's `wall` otherwise).
export type AgentClock = { now(): number; after(ms: number, f: () => void): () => void };

export class AndroidAgents {
  readonly #devices: AndroidDevices;
  readonly #clock: AgentClock;
  readonly #leases = new Map<string, Lease>();
  /// Each device's turn: a start, an action, an end and what puts a phone back run one after the other on a device,
  /// so two starts never both lease it and a start never runs while a phone is still being put back.
  readonly #turns = new Map<string, Promise<unknown>>();
  #epoch = 0;
  #closed = false;

  constructor(devices: AndroidDevices, clock: AgentClock = wall) {
    this.#devices = devices;
    this.#clock = clock;
    // A device that leaves adb ends its lease: nothing is done to what may take its place.
    devices.screens.watch((sources) => {
      for (const lease of [...this.#leases.values()]) {
        const source = sources.find((s) => s.id === lease.target);
        if (!source || source.instance !== lease.instance) void this.#inTurn(lease.target, () => this.#drop(lease, false));
      }
    });
  }

  /// `f` in `target`'s turn, after what was asked of it before has ended.
  #inTurn<T>(target: string, f: () => Promise<T>): Promise<T> {
    const before = this.#turns.get(target) ?? Promise.resolve();
    const run = before.then(f, f);
    const settled = run.then(() => {}, () => {});
    this.#turns.set(target, settled);
    void settled.then(() => {
      if (this.#turns.get(target) === settled) this.#turns.delete(target);
    });
    return run;
  }

  /// One `env.android` request in `device` mode; `images` keeps a screenshot. Never throws: a refusal is `{ok: false}`.
  async call(params: Json, images: ImageStore | null): Promise<Json> {
    try {
      return await this.#call(params, images);
    } catch (error) {
      if (error instanceof AgentError) return failure(error.code, error.message);
      log.info("android", "an agent's action failed", { action: String(params.action), error: (error as Error).message });
      return failure("android_action_failed", (error as Error).message);
    }
  }

  async #call(p: Json, images: ImageStore | null): Promise<Json> {
    const action = typeof p.action === "string" ? p.action : "";
    this.#open();
    // (an agent's look for devices takes adb's word first, as a person's listing does: a phone not chosen is asked
    // nothing, android.ts `shownDevice`)
    if (action === "status") {
      await this.#devices.androids.refresh();
      return this.#status();
    }
    if (action === "start") {
      await this.#devices.androids.refresh();
      const target = typeof p.target === "string" ? p.target : "";
      return this.#inTurn(target, () => this.#start(target, p));
    }
    const known = this.#leaseOf(p);
    return this.#inTurn(known.target, () => this.#act(action, p, images));
  }

  #open() {
    if (this.#closed) throw new AgentError("android_environment_unavailable", "the station is stopping");
  }

  /// One action on a leased device, in its turn. The lease, the device and its owner's word are looked at again here,
  /// and again after each wait, before anything reaches the device.
  async #act(action: string, p: Json, images: ImageStore | null): Promise<Json> {
    const lease = this.#leaseOf(p);
    if (action === "end") {
      if (this.#leases.get(lease.target) !== lease) throw new AgentError("android_lease_unknown", "no such lease: start one");
      await this.#drop(lease, true);
      return { ok: true, ended: true };
    }
    const source = await this.#check(lease);
    switch (action) {
      case "observe":
        return this.#observe(lease, source, images);
      case "tap": {
        const [x, y] = [coord(p.x, "x"), coord(p.y, "y")];
        await this.#mayAct(lease, source, false);
        // (each press and lift is also said to those who look at the device: they see where the agent acts)
        pointer(lease, source, [x, y], true);
        await source.agentShell(`input tap ${x} ${y}`).finally(() => pointer(lease, source, [x, y], false));
        return { ok: true };
      }
      case "swipe": {
        const from = pair(p.from, "from") ?? [coord(p.x1 ?? p.x, "x1"), coord(p.y1 ?? p.y, "y1")];
        const to = pair(p.to, "to") ?? [coord(p.x2, "x2"), coord(p.y2, "y2")];
        const ms = p.duration_ms === undefined ? SWIPE_DEFAULT_MS : Number(p.duration_ms);
        if (!Number.isFinite(ms) || ms < 1 || ms > SWIPE_MOST_MS) throw new AgentError("android_bad_args", `duration_ms: 1 to ${SWIPE_MOST_MS}`);
        await this.#mayAct(lease, source, false);
        // (one shell command: those who look see the finger go down where it starts and lift where it ends)
        pointer(lease, source, from, true);
        await source.agentShell(`input swipe ${from[0]} ${from[1]} ${to[0]} ${to[1]} ${Math.round(ms)}`).finally(() => pointer(lease, source, to, false));
        return { ok: true };
      }
      case "type": {
        const text = typeof p.text === "string" ? p.text : "";
        if (text === "" || text.length > TEXT_MOST) throw new AgentError("android_bad_args", `text: 1 to ${TEXT_MOST} characters`);
        // (a newline is Enter)
        const parts = text.split("\n");
        const commands = parts.flatMap((part, i) => [...(part ? [textCommand(part)] : []), ...(i < parts.length - 1 ? [`input keyevent ${AGENT_KEYS.enter}`] : [])]);
        await this.#mayAct(lease, source, false);
        await source.agentShell(commands.join("; "));
        return { ok: true };
      }
      case "key": {
        const name = typeof p.key === "string" ? p.key.toLowerCase() : "";
        const code = AGENT_KEYS[name];
        if (code === undefined) throw new AgentError("android_bad_args", `key: one of ${Object.keys(AGENT_KEYS).join(", ")}`);
        await this.#mayAct(lease, source, name === "wakeup");
        await source.agentShell(`input keyevent ${code}`);
        return { ok: true };
      }
      case "launch": {
        const pkg = typeof p.package === "string" ? p.package : "";
        if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(pkg) || pkg.length > 200) throw new AgentError("android_bad_args", "package: an app's package name");
        await this.#mayAct(lease, source, false);
        await source.agentShell(`monkey -p ${pkg} -c android.intent.category.LAUNCHER 1`);
        return { ok: true };
      }
      default:
        throw new AgentError("android_action_unsupported", `${action || "(none)"} is not offered for a computer's own device: status, start, observe, tap, swipe, type, key, launch, end`);
    }
  }

  /// The devices an agent may lease: the emulators, and the phones chosen for agents. Other phones are not said.
  #status(): Json {
    const devices = this.#devices.screens.list().flatMap((s) => {
      const source = s as AndroidScreen;
      if (source.kind !== "android" || !source.instance || !this.#devices.agentsMay(source)) return [];
      const lease = this.#leases.get(source.id);
      return [{ target: source.id, title: source.title(), kind: source.phone ? "phone" : "emulator", instance: source.instance, ...source.size(), leased: lease !== undefined }];
    });
    return { ok: true, mode: "device", devices };
  }

  /// A lease starts, in the device's turn: nothing else is asked of the device meanwhile.
  async #start(target: string, p: Json): Promise<Json> {
    this.#open();
    const source = this.#devices.androids.sourceOf(target);
    if (!source || !source.instance) throw new AgentError("android_target_unknown", `no device ${target || "(none)"} here: status lists them`);
    if (typeof p.instance === "string" && p.instance !== source.instance) throw new AgentError("android_target_replaced", "that device is no longer running: another has its place");
    this.#offered(source);
    if (source.phone && p.consent !== true) return { ...failure("android_consent_required", "its owner allows this chat first"), title: source.title(), target: source.id, instance: source.instance };
    const held = this.#leases.get(source.id);
    if (held && held.until > this.#clock.now()) throw new AgentError("android_leased", "another agent uses this device now");
    if (held) await this.#drop(held, true);
    if (!(await source.current())) throw new AgentError("android_target_replaced", "that device is no longer running: another has its place");
    // (what may have changed while adb answered: the station stopping, its owner's word, the device at its place)
    this.#open();
    this.#offered(source);
    if (this.#devices.androids.sourceOf(target) !== source) throw new AgentError("android_target_replaced", "that device is no longer running: another has its place");
    const asked = p.lease_seconds === undefined ? LEASE_DEFAULT_S : Number(p.lease_seconds);
    const seconds = Number.isFinite(asked) ? Math.min(LEASE_MOST_S, Math.max(LEASE_LEAST_S, Math.round(asked))) : LEASE_DEFAULT_S;
    const lease: Lease = { id: randomBytes(12).toString("hex"), epoch: ++this.#epoch, target: source.id, instance: source.instance, phone: source.phone, until: this.#clock.now() + seconds * 1000, stopTimer: () => {}, observation: 0, touches: null };
    lease.stopTimer = this.#clock.after(seconds * 1000, () => void this.#inTurn(lease.target, () => this.#drop(lease, true)));
    this.#leases.set(source.id, lease);
    source.agent = "agent";
    this.#devices.screens.changed();
    if (source.phone) {
      // Said on the phone while it lasts: touches drawn, and a notification.
      lease.touches = (await source.agentShell("settings get system show_touches").catch(() => "")).trim() || null;
      await this.#check(lease);
      await source.agentShell(`settings put system show_touches 1; cmd notification post -S bigtext -t Comma ${NOTE_TAG} '${NOTE_ON}'`).catch((error) => log.info("android", "the phone was not told an agent uses it", { error: (error as Error).message }));
    }
    // (the whole lease looked at again after the phone answered; one that no longer holds is ended and put back here)
    await this.#check(lease);
    return { ok: true, mode: "device", lease_id: lease.id, lease_epoch: lease.epoch, expires_at: Math.floor(lease.until / 1000), target: source.id, instance: source.instance, kind: source.phone ? "phone" : "emulator", title: source.title(), ...source.size() };
  }

  #offered(source: AndroidScreen) {
    if (!this.#devices.agentsMay(source)) throw new AgentError("android_phone_not_offered", "its owner has not let agents use this phone: they turn it on in the computer's screen panel");
  }

  /// The lease an action names; whether it still holds is `#check`'s, in the device's turn.
  #leaseOf(p: Json): Lease {
    this.#open();
    const lease = [...this.#leases.values()].find((l) => l.id === p.lease_id);
    if (!lease) throw new AgentError("android_lease_unknown", "no such lease: start one");
    if (p.lease_epoch !== undefined && p.lease_epoch !== lease.epoch) throw new AgentError("android_lease_stale", "that lease was replaced: start again");
    return lease;
  }

  /// The one check of a lease, in its device's turn: as an action starts, and again after every wait on adb, before
  /// anything more reaches the device. The lease must still be this one, before its deadline, the station not stopping,
  /// the device the one leased and its owner still letting agents use it. One that no longer holds is ended here, in
  /// this turn, its phone put back, and the action refused: nothing waits for the lease's own timer.
  async #check(lease: Lease): Promise<AndroidScreen> {
    if (this.#leases.get(lease.target) !== lease) throw new AgentError("android_lease_unknown", "no such lease: start one");
    if (this.#closed) {
      await this.#drop(lease, true);
      this.#open();
    }
    if (lease.until <= this.#clock.now()) {
      await this.#drop(lease, true);
      throw new AgentError("android_lease_expired", "the lease's time is up: start again");
    }
    const source = this.#devices.androids.sourceOf(lease.target);
    if (!source || source.instance !== lease.instance) {
      await this.#drop(lease, false);
      throw new AgentError("android_target_replaced", "that device is no longer running");
    }
    if (!this.#devices.agentsMay(source)) {
      await this.#drop(lease, true);
      this.#offered(source);
    }
    return source;
  }

  /// Whether input may go now: the lease still on, not while a person drives it, and to a locked phone only `wakeup`.
  async #mayAct(lease: Lease, source: AndroidScreen, waking: boolean): Promise<void> {
    if (source.held()) throw new AgentError("android_held_by_person", "a person is driving this device in Comma now: wait, or ask them in the chat");
    if (lease.phone && !waking) {
      const state = stateOf(await source.agentShell(STATE));
      // (a phone that does not say is taken as locked: no input reaches what may be its lock screen)
      if (state.locked !== false) throw new AgentError("android_locked", "the phone is locked: ask its owner to unlock it (never type or tap its PIN); key wakeup turns its screen on");
    }
    // (looked at again after adb answered)
    await this.#check(lease);
    if (source.held()) throw new AgentError("android_held_by_person", "a person is driving this device in Comma now: wait, or ask them in the chat");
  }

  async #observe(lease: Lease, source: AndroidScreen, images: ImageStore | null): Promise<Json> {
    if (images === null) throw new AgentError("android_environment_unavailable", "screenshots cannot be kept on this computer");
    const state = stateOf(await source.agentShell(STATE));
    await this.#check(lease);
    const png = await source.agentScreenshot();
    const size = pngSize(png);
    if (size === null) throw new AgentError("android_action_failed", "the device gave no screenshot");
    await this.#check(lease);
    const stored = await images(png);
    if (stored.ok === false) throw new AgentError("android_action_failed", String(stored.error ?? "the screenshot was not kept"));
    await this.#check(lease);
    lease.observation++;
    lease.shot = size;
    return {
      ok: true,
      observation_id: lease.observation,
      ...stored,
      image_width: size.width,
      image_height: size.height,
      screen_on: state.screen_on,
      locked: lease.phone ? state.locked !== false : state.locked === true,
      held_by_person: source.held(),
      note: "Coordinates are the screenshot's pixels.",
    };
  }

  /// A lease ends: on a phone still there, what it showed is put back, and this resolves once it is. Called in the
  /// device's turn.
  async #drop(lease: Lease, putBack: boolean): Promise<void> {
    if (this.#leases.get(lease.target) !== lease) return;
    this.#leases.delete(lease.target);
    lease.stopTimer();
    const source = this.#devices.androids.sourceOf(lease.target);
    if (source && source.instance === lease.instance) {
      source.agent = null;
      if (putBack && lease.phone) {
        const touches = lease.touches !== null && /^[01]$/.test(lease.touches) ? lease.touches : "0";
        await source.agentShell(`settings put system show_touches ${touches}; cmd notification post -t Comma ${NOTE_TAG} '${NOTE_OFF}'`).catch((error) => log.info("android", "a phone was not put back", { error: (error as Error).message }));
      }
    }
    this.#devices.screens.changed();
  }

  /// The leases on phones its owner no longer lets agents use end now, each put back while it is still a screen.
  /// `allowed`: whether agents may use the phone at an adb serial, by the owner's new word.
  async revoke(allowed: (serial: string) => boolean): Promise<void> {
    await Promise.all(
      [...this.#leases.values()].map((lease) => {
        const source = this.#devices.androids.sourceOf(lease.target);
        if (!lease.phone || !source || allowed(source.serial)) return Promise.resolve();
        return this.#inTurn(lease.target, () => this.#drop(lease, true));
      }),
    );
  }

  /// The station stopping: nothing new starts, every lease ends with its phone put back, and this resolves once each
  /// device's turn has ended.
  async close(): Promise<void> {
    this.#closed = true;
    await Promise.all([...this.#leases.values()].map((lease) => this.#inTurn(lease.target, () => this.#drop(lease, true))));
    await Promise.all([...this.#turns.values()]);
  }
}
