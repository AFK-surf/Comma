// Agents on the computer's iOS Simulators: Salix's `env.screen` (docs/simulator-screen.md, "Agents on a simulator"),
// the device connection's `screen` method. As an Android device's (android-agent.ts): a Worker leases one booted
// simulator the station lists, looks at it (CoreSimulator's own screenshot, simulator.ts `agentScreenshot`) and acts on
// it in the screenshot's pixels: tap, swipe, text, keys and the device's buttons, through a view of the helper's that
// drives it as a person's Control does (sim-input.ts). One lease a device; it ends at `end`, when its time is up, when
// the device shuts down or boots again, or when the station stops.
//
// A simulator runs on its owner's computer: it is leased only with Salix's word that the computer's owner allowed this
// chat (`consent`, from the `computer_use_start` card's record, which only that owner answers). While a person drives it
// in a view of theirs, an agent's input is refused until they leave it.
import { Context, Effect, Layer } from "effect";
import { randomBytes } from "node:crypto";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type AgentClock, AgentError, type ImageStore, pngSize } from "./android-agent.ts";
import { ScreenHelpersService } from "./helper.ts";
import { Simulators } from "./simulator.ts";
import { type DeviceInput, type ScreenView, makeScreens } from "./source.ts";

type Json = Record<string, unknown>;

/// A lease's length when none is asked, and the longest and shortest (Salix also caps it).
const LEASE_DEFAULT_S = 600;
const LEASE_MOST_S = 3600;
const LEASE_LEAST_S = 60;
/// The longest text typed at once, and a swipe's longest and default time.
const TEXT_MOST = 1000;
const SWIPE_MOST_MS = 5000;
const SWIPE_DEFAULT_MS = 300;
/// A swipe's moves: one about every frame, at most this many.
const SWIPE_STEPS_MOST = 30;
/// How long a tap's finger stays down (ms): a touch that ends at once is taken as no tap by some views.
const TAP_HOLD_MS = 60;
const COORD_MOST = 20_000;

/// The keys an agent may press: a keyboard's by their `KeyboardEvent.code`, and the device's buttons by Simulator.app's
/// shortcuts (sim-input.ts: ⌘⇧H home, ⌃⌘⇧H the app switcher, ⌘L lock, ⌘K the software keyboard).
const KEYS: Record<string, { code: string; mods: number }> = {
  home: { code: "KeyH", mods: 4 | 8 },
  app_switcher: { code: "KeyH", mods: 2 | 4 | 8 },
  lock: { code: "KeyL", mods: 4 },
  keyboard: { code: "KeyK", mods: 4 },
  enter: { code: "Enter", mods: 0 },
  delete: { code: "Backspace", mods: 0 },
  tab: { code: "Tab", mods: 0 },
  escape: { code: "Escape", mods: 0 },
  space: { code: "Space", mods: 0 },
  up: { code: "ArrowUp", mods: 0 },
  down: { code: "ArrowDown", mods: 0 },
  left: { code: "ArrowLeft", mods: 0 },
  right: { code: "ArrowRight", mods: 0 },
};

/// A booted simulator as an agent's lease uses it (simulator.ts `Simulator`).
export type AgentSimulator = {
  readonly id: string;
  readonly instance?: string;
  agent: string | null;
  title(): string;
  size(): { width: number; height: number };
  held(): boolean;
  current(): Promise<boolean>;
  agentScreenshot(): Promise<Buffer>;
  agentView(): Promise<ScreenView>;
  /// Where the agent's finger is as it acts (0..1 of the picture), for those who look at the device meanwhile.
  agentPoints?(at: { x: number; y: number }, down: boolean): void;
};

/// The booted simulators (simulator.ts `Simulators`).
export type AgentSimulators = {
  refresh(): Promise<void>;
  list(): AgentSimulator[];
  sourceOf(id: string): AgentSimulator | undefined;
  watch(heard: () => void): () => void;
};

type Lease = {
  id: string;
  epoch: number;
  target: string;
  instance: string;
  until: number;
  stopTimer: () => void;
  observation: number;
  /// The latest screenshot's size: an action's pixels are of it.
  shot: { width: number; height: number } | null;
  view: Promise<ScreenView> | null;
};

function coord(v: unknown, name: string): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > COORD_MOST) throw new AgentError("screen_bad_args", `${name}: pixels of the latest screenshot`);
  return v;
}

function pair(v: unknown, name: string): [number, number] | null {
  if (!Array.isArray(v) || v.length !== 2) return null;
  return [coord(v[0], `${name}[0]`), coord(v[1], `${name}[1]`)];
}

const failure = (code: string, error: string): Json => ({ ok: false, error_code: code, error });

export class SimulatorAgents {
  readonly #sims: AgentSimulators;
  readonly #clock: AgentClock;
  readonly #leases = new Map<string, Lease>();
  /// Each device's turn: what is asked of one device runs one after the other.
  readonly #turns = new Map<string, Promise<unknown>>();
  readonly #unwatch: () => void;
  #epoch = 0;
  #closed = false;

  constructor(sims: AgentSimulators, clock: AgentClock = wall) {
    this.#sims = sims;
    this.#clock = clock;
    // A device that shuts down or boots again ends its lease.
    this.#unwatch = sims.watch(() => {
      for (const lease of [...this.#leases.values()]) {
        const source = sims.sourceOf(lease.target);
        if (!source || source.instance !== lease.instance) void this.#inTurn(lease.target, () => this.#drop(lease));
      }
    });
  }

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

  /// One `env.screen` request; `images` keeps a screenshot. Never throws: a refusal is `{ok: false}`.
  async call(params: Json, images: ImageStore | null): Promise<Json> {
    try {
      return await this.#call(params, images);
    } catch (error) {
      if (error instanceof AgentError) return failure(error.code, error.message);
      log.info("screens", "an agent's action on a simulator failed", { action: String(params.action), error: (error as Error).message });
      return failure("screen_action_failed", (error as Error).message);
    }
  }

  async #call(p: Json, images: ImageStore | null): Promise<Json> {
    const action = typeof p.action === "string" ? p.action : "";
    this.#open();
    if (action === "status") {
      await this.#sims.refresh();
      return this.#status();
    }
    if (action === "start") {
      await this.#sims.refresh();
      const target = typeof p.target === "string" ? p.target : "";
      return this.#inTurn(target, () => this.#start(target, p));
    }
    const known = this.#leaseOf(p);
    return this.#inTurn(known.target, () => this.#act(action, p, images));
  }

  #open() {
    if (this.#closed) throw new AgentError("screen_environment_unavailable", "the station is stopping");
  }

  #status(): Json {
    const devices = this.#sims.list().flatMap((source) => {
      if (!source.instance) return [];
      return [{ target: source.id, title: source.title(), kind: "simulator", instance: source.instance, ...source.size(), leased: this.#leases.has(source.id), held_by_person: source.held() }];
    });
    return { ok: true, devices };
  }

  async #start(target: string, p: Json): Promise<Json> {
    this.#open();
    const source = this.#sims.sourceOf(target);
    if (!source || !source.instance) throw new AgentError("screen_target_unknown", `no booted simulator ${target || "(none)"} here: status lists them`);
    if (typeof p.instance === "string" && p.instance !== source.instance) throw new AgentError("screen_target_replaced", "that simulator is no longer running: it booted again or shut down");
    // (a simulator is its owner's: leased only on the word of the card its owner answered in this chat)
    if (p.consent !== true) return { ...failure("screen_consent_required", "the computer's owner allows this chat first"), title: source.title(), target: source.id, instance: source.instance };
    const held = this.#leases.get(source.id);
    if (held && held.until > this.#clock.now()) throw new AgentError("screen_leased", "another agent uses this simulator now");
    if (held) await this.#drop(held);
    if (!(await source.current())) throw new AgentError("screen_target_replaced", "that simulator is no longer running: it booted again or shut down");
    this.#open();
    if (this.#sims.sourceOf(target) !== source) throw new AgentError("screen_target_replaced", "that simulator is no longer running: it booted again or shut down");
    const asked = p.lease_seconds === undefined ? LEASE_DEFAULT_S : Number(p.lease_seconds);
    const seconds = Number.isFinite(asked) ? Math.min(LEASE_MOST_S, Math.max(LEASE_LEAST_S, Math.round(asked))) : LEASE_DEFAULT_S;
    const lease: Lease = { id: randomBytes(12).toString("hex"), epoch: ++this.#epoch, target: source.id, instance: source.instance, until: this.#clock.now() + seconds * 1000, stopTimer: () => {}, observation: 0, shot: null, view: null };
    lease.stopTimer = this.#clock.after(seconds * 1000, () => void this.#inTurn(lease.target, () => this.#drop(lease)));
    this.#leases.set(source.id, lease);
    source.agent = "agent";
    return { ok: true, lease_id: lease.id, lease_epoch: lease.epoch, expires_at: Math.floor(lease.until / 1000), target: source.id, instance: source.instance, kind: "simulator", title: source.title(), ...source.size() };
  }

  #leaseOf(p: Json): Lease {
    this.#open();
    const lease = [...this.#leases.values()].find((l) => l.id === p.lease_id);
    if (!lease) throw new AgentError("screen_lease_unknown", "no such lease: start one");
    if (p.lease_epoch !== undefined && p.lease_epoch !== lease.epoch) throw new AgentError("screen_lease_stale", "that lease was replaced: start again");
    return lease;
  }

  /// The one check of a lease, in its device's turn: as an action starts and after every wait, before anything more
  /// reaches the device. One that no longer holds is ended here and the action refused.
  async #check(lease: Lease): Promise<AgentSimulator> {
    if (this.#leases.get(lease.target) !== lease) throw new AgentError("screen_lease_unknown", "no such lease: start one");
    if (this.#closed) {
      await this.#drop(lease);
      this.#open();
    }
    if (lease.until <= this.#clock.now()) {
      await this.#drop(lease);
      throw new AgentError("screen_lease_expired", "the lease's time is up: start again");
    }
    const source = this.#sims.sourceOf(lease.target);
    if (!source || source.instance !== lease.instance) {
      await this.#drop(lease);
      throw new AgentError("screen_target_replaced", "that simulator is no longer running");
    }
    return source;
  }

  /// Input may go now: the lease still on, and no person driving the device.
  async #mayAct(lease: Lease, source: AgentSimulator): Promise<ScreenView> {
    if (source.held()) throw new AgentError("screen_held_by_person", "a person is driving this simulator in Comma now: wait, or ask them in the chat");
    lease.view ??= source.agentView();
    const view = await lease.view.catch((error: Error) => {
      lease.view = null;
      throw new AgentError("screen_environment_unavailable", `the simulator takes no input now: ${error.message}`);
    });
    await this.#check(lease);
    if (source.held()) throw new AgentError("screen_held_by_person", "a person is driving this simulator in Comma now: wait, or ask them in the chat");
    return view;
  }

  /// A point of the latest screenshot as a share of the screen (sim-input.ts takes 0..1).
  #at(lease: Lease, source: AgentSimulator, x: number, y: number): { x: number; y: number } {
    const shot = lease.shot ?? source.size();
    if (!(shot.width > 0 && shot.height > 0)) throw new AgentError("screen_observe_first", "observe first: actions are in the pixels of the latest screenshot");
    if (x > shot.width || y > shot.height) throw new AgentError("screen_bad_args", `x, y: within the latest screenshot (${shot.width}×${shot.height})`);
    return { x: x / shot.width, y: y / shot.height };
  }

  #wait(ms: number): Promise<void> {
    return new Promise((resolve) => this.#clock.after(ms, resolve));
  }

  async #act(action: string, p: Json, images: ImageStore | null): Promise<Json> {
    const lease = this.#leaseOf(p);
    if (action === "end") {
      if (this.#leases.get(lease.target) !== lease) throw new AgentError("screen_lease_unknown", "no such lease: start one");
      await this.#drop(lease);
      return { ok: true, ended: true };
    }
    const source = await this.#check(lease);
    // (a person driving it is said first, before what the action asks is looked at)
    if (action !== "observe" && source.held()) throw new AgentError("screen_held_by_person", "a person is driving this simulator in Comma now: wait, or ask them in the chat");
    // (each press, move and lift is also said to those who look at the device: they see where the agent acts)
    const send = (view: ScreenView, ...events: DeviceInput[]) =>
      Promise.all(
        events.map((event) => {
          if (event.t === "pointer") source.agentPoints?.({ x: event.x, y: event.y }, event.kind !== "up");
          return view.input(event);
        }),
      );
    switch (action) {
      case "observe":
        return this.#observe(lease, source, images);
      case "tap": {
        const at = this.#at(lease, source, coord(p.x, "x"), coord(p.y, "y"));
        const view = await this.#mayAct(lease, source);
        await send(view, { t: "pointer", kind: "down", ...at, buttons: 1 });
        await this.#wait(TAP_HOLD_MS);
        await send(view, { t: "pointer", kind: "up", ...at, buttons: 0 });
        return { ok: true };
      }
      case "swipe": {
        const from = pair(p.from, "from") ?? [coord(p.x1, "x1"), coord(p.y1, "y1")];
        const to = pair(p.to, "to") ?? [coord(p.x2, "x2"), coord(p.y2, "y2")];
        const ms = p.duration_ms === undefined ? SWIPE_DEFAULT_MS : Number(p.duration_ms);
        if (!Number.isFinite(ms) || ms < 1 || ms > SWIPE_MOST_MS) throw new AgentError("screen_bad_args", `duration_ms: 1 to ${SWIPE_MOST_MS}`);
        const a = this.#at(lease, source, from[0], from[1]);
        const b = this.#at(lease, source, to[0], to[1]);
        const view = await this.#mayAct(lease, source);
        const steps = Math.min(SWIPE_STEPS_MOST, Math.max(2, Math.round(ms / 16)));
        const at = (k: number) => ({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k });
        let where = a;
        let down = true;
        await send(view, { t: "pointer", kind: "down", ...a, buttons: 1 });
        try {
          for (let i = 1; i <= steps; i++) {
            await this.#wait(ms / steps);
            // After each wait, the whole lease again (its time, the station stopping, the device) and no person
            // driving it: what no longer holds ends the swipe where it is, its finger lifted first.
            const over = this.#closed || lease.until <= this.#clock.now() || this.#leases.get(lease.target) !== lease || this.#sims.sourceOf(lease.target) !== source || source.held();
            if (over) {
              down = false;
              await send(view, { t: "pointer", kind: "up", ...where, buttons: 0 }).catch(() => {});
              await this.#check(lease);
              throw new AgentError("screen_held_by_person", "a person took this simulator during the swipe");
            }
            where = at(i / steps);
            await send(view, { t: "pointer", kind: "move", ...where, buttons: 1 });
          }
          down = false;
          await send(view, { t: "pointer", kind: "up", ...b, buttons: 0 });
        } finally {
          // (the finger is never left down: lifted where it was)
          if (down) await send(view, { t: "pointer", kind: "up", ...where, buttons: 0 }).catch(() => {});
        }
        return { ok: true };
      }
      case "type": {
        const text = typeof p.text === "string" ? p.text : "";
        if (text === "" || text.length > TEXT_MOST) throw new AgentError("screen_bad_args", `text: 1 to ${TEXT_MOST} characters`);
        const view = await this.#mayAct(lease, source);
        await send(view, { t: "text", text });
        return { ok: true };
      }
      case "key": {
        const name = typeof p.key === "string" ? p.key.toLowerCase() : "";
        const key = KEYS[name];
        if (key === undefined) throw new AgentError("screen_bad_args", `key: one of ${Object.keys(KEYS).join(", ")}`);
        const view = await this.#mayAct(lease, source);
        await send(view, { t: "key", kind: "down", key: name, code: key.code, mods: key.mods });
        await send(view, { t: "key", kind: "up", key: name, code: key.code, mods: key.mods });
        return { ok: true };
      }
      default:
        throw new AgentError("screen_action_unsupported", `${action || "(none)"} is not offered: status, start, observe, tap, swipe, type, key, end`);
    }
  }

  async #observe(lease: Lease, source: AgentSimulator, images: ImageStore | null): Promise<Json> {
    if (images === null) throw new AgentError("screen_environment_unavailable", "screenshots cannot be kept on this computer");
    const png = await source.agentScreenshot();
    const size = pngSize(png);
    if (size === null) throw new AgentError("screen_action_failed", "the simulator gave no screenshot");
    await this.#check(lease);
    const stored = await images(png);
    if (stored.ok === false) throw new AgentError("screen_action_failed", String(stored.error ?? "the screenshot was not kept"));
    await this.#check(lease);
    lease.observation++;
    lease.shot = size;
    return {
      ok: true,
      observation_id: lease.observation,
      ...stored,
      image_width: size.width,
      image_height: size.height,
      held_by_person: source.held(),
      note: "Coordinates are the screenshot's pixels.",
    };
  }

  /// A lease ends: its view closes. Called in the device's turn.
  async #drop(lease: Lease): Promise<void> {
    if (this.#leases.get(lease.target) !== lease) return;
    this.#leases.delete(lease.target);
    lease.stopTimer();
    const view = lease.view;
    lease.view = null;
    if (view) await view.then((v) => (v as { close?: () => void }).close?.(), () => {});
    const source = this.#sims.sourceOf(lease.target);
    if (source && source.instance === lease.instance) source.agent = null;
  }

  /// The station stopping: nothing new starts, every lease ends.
  async close(): Promise<void> {
    this.#closed = true;
    this.#unwatch();
    await Promise.all([...this.#leases.values()].map((lease) => this.#inTurn(lease.target, () => this.#drop(lease))));
    await Promise.all([...this.#turns.values()]);
  }
}

/// The station's one set of simulators: the screens its owner's views show (mesh.ts) and the agents' leases on them
/// (the connector's `screen` method). Listed once a listing or an agent asks.
export type StationSimulators = { screens: ReturnType<typeof makeScreens>; simulators: Simulators; agents: SimulatorAgents };

export class SimulatorsService extends Context.Service<SimulatorsService, StationSimulators>()("comma/Simulators") {
  static readonly layer = Layer.effect(
    SimulatorsService,
    Effect.gen(function* () {
      const helpers = yield* ScreenHelpersService;
      return yield* Effect.acquireRelease(
        Effect.sync(() => {
          const screens = makeScreens();
          const simulators = new Simulators({ screens, helper: () => helpers.current() });
          return { screens, simulators, agents: new SimulatorAgents(simulators) };
        }),
        ({ simulators, agents }) => Effect.promise(() => agents.close()).pipe(Effect.andThen(Effect.sync(() => simulators.close()))),
      );
    }),
  );
}
