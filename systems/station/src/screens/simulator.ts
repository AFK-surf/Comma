// The iOS Simulators of this Mac as screen sources (`simulator:<udid>`, docs/simulator-screen.md), ported from
// still.fail's station/src/screens/simulator.ts. The Computer Use helper's SimulatorStreamSession.swift reads a booted
// device's framebuffer and posts touches, keys and buttons to it (serve-sim's capture and HID, vendor/serve-sim); macOS
// grants nothing for this, and Simulator.app need not run.
//
// Which devices there are, and which are booted, is CoreSimulator's own simctl's, looked at when a listing asks and, from
// the first listing on, when CoreSimulator rewrites a device's device.plist (as it boots and shuts down) or the list of
// devices changes. Each boot of a device is a process of its own (its launchd_sim): that process and its start are the
// boot's `instance`.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { type FSWatcher, existsSync, readFileSync, readdirSync, watch } from "node:fs";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { type ScreenHelper, openView } from "./helper.ts";
import { type AppLogs, simulatorLogs } from "./app-logs.ts";
import { ScreenRefused } from "./hub.ts";
import { HelperView, type InputOps } from "./screen-pipe.ts";
import { SimDebug } from "./sim-debug.ts";
import { SimInput } from "./sim-input.ts";
import { type ChromeSource, chromeOf, displaysOf } from "./sim-chrome.ts";
import { panelOf } from "./sim-mask.ts";
import { AgentPresence, type AgentSaid, type Codec, type DeviceInput, type DevicePose, type Panel, type ScreenSource, type ScreenView, type Screens, type ViewOptions } from "./source.ts";

/// A preview's pace: a picture about twice a second, small (a card's).
const PEEK_FPS = 2;
const REPLACED = "that simulator is no longer running: it has booted again or shut down";
/// The largest screenshot an agent is given (bytes): an iPad Pro's full screen as a PNG is about 10 MB.
export const AGENT_SHOT_MOST = 24 * 1024 * 1024;
const AGENT_SHOT_TIMEOUT_MS = 20_000;
/// An agent's view's bounds: it carries input; its pictures are not looked at.
const AGENT_VIEW_SIDE = 320;

/// A device's screenshot as a PNG, by its UDID.
export type Capture = (udid: string) => Promise<Buffer>;
const capture: Capture = async (udid) => {
  // (simctl writes a file only: one of its own, read and removed)
  const dir = await mkdtemp(join(tmpdir(), "comma-sim-shot-"));
  const file = join(dir, "shot.png");
  try {
    await new Promise<void>((resolve, reject) =>
      execFile(SIMCTL, ["io", udid, "screenshot", "--type=png", file], { timeout: AGENT_SHOT_TIMEOUT_MS }, (error) =>
        error ? reject(new Error(`simctl gave no screenshot: ${error.message.slice(0, 200)}`)) : resolve(),
      ),
    );
    if ((await stat(file)).size > AGENT_SHOT_MOST) throw new Error("the screenshot is too large");
    return await readFile(file);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
};

const UDID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;

/// A device as simctl lists it.
export type SimDevice = { udid: string; name: string; runtime: string; type: string; booted: boolean };

/// The iOS devices of `simctl list -j devices` that can run: each with its runtime's name ("iOS 26.2", from its
/// identifier). A watch, a TV or a headset is not a touchscreen a person drives from here.
export function devicesOf(listed: unknown): SimDevice[] {
  const devices = (listed as { devices?: Record<string, unknown> } | null)?.devices;
  if (devices === null || typeof devices !== "object") return [];
  const out: SimDevice[] = [];
  for (const [runtime, list] of Object.entries(devices)) {
    const named = runtimeName(runtime);
    if (!Array.isArray(list) || !named.startsWith("iOS ")) continue;
    for (const d of list) {
      if (typeof d?.udid !== "string" || !UDID.test(d.udid) || d.isAvailable === false) continue;
      out.push({ udid: d.udid.toUpperCase(), name: typeof d.name === "string" ? d.name : d.udid, runtime: named, type: typeof d.deviceTypeIdentifier === "string" ? d.deviceTypeIdentifier : "", booted: d.state === "Booted" });
    }
  }
  return out;
}

/// "com.apple.CoreSimulator.SimRuntime.iOS-26-2" → "iOS 26.2"; a runtime of one device type, "…iOS-27-2-iPhone19-4", too.
export function runtimeName(id: string): string {
  const m = /SimRuntime\.([A-Za-z]+)-(\d+(?:-\d+)*)(?:-[A-Za-z].*)?$/.exec(id);
  if (m === null) return id;
  const os = m[1] === "xrOS" ? "visionOS" : m[1]!;
  return `${os} ${m[2]!.replaceAll("-", ".")}`;
}

/// A device type's main screen in pixels, as its capabilities.plist says it (0×0 when it does not).
export function screenOf(capabilities: unknown): { width: number; height: number } {
  const d = (capabilities as { capabilities?: { ScreenDimensionsCapability?: Record<string, unknown> } } | null)?.capabilities?.ScreenDimensionsCapability;
  const width = d?.["main-screen-width"], height = d?.["main-screen-height"];
  return typeof width === "number" && typeof height === "number" && width > 0 && height > 0 ? { width, height } : { width: 0, height: 0 };
}

/// Each booted device's boot in `ps -axww -o pid=,lstart=,args=`, by UDID: its launchd_sim's pid and the time that
/// process started (pids are used again), as `ps` says them.
export function bootsOf(ps: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of ps.split("\n")) {
    const m = /^\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+\S*launchd_sim\s+\S*\/CoreSimulator\/Devices\/([0-9A-F-]{36})\/data\/var\/run\/launchd_bootstrap\.plist/i.exec(line);
    if (m) out.set(m[3]!.toUpperCase(), `${m[1]}/${m[2]!.replace(/\s+/g, " ")}`);
  }
  return out;
}

/// CoreSimulator's simctl, not Xcode's (`xcrun simctl`): that one is a script that first runs `xcodebuild -runFirstLaunch`
/// where CoreSimulator is older than the Xcode, which asks for an administrator's password in a window of macOS's.
export const SIMCTL = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl";

export type Run = (file: string, args: string[]) => Promise<string>;
const run: Run = (file, args) =>
  new Promise((resolve, reject) =>
    execFile(file, args, { timeout: 60_000, maxBuffer: 16 << 20 }, (error, out, err) => (error ? reject(new Error(`${file} ${args.join(" ")}: ${error.signal ?? error.code ?? ""} ${String(err).trim()}`.slice(0, 500))) : resolve(out))),
  );

/// A device type's screen in pixels, its panels, and its case as Xcode has it (sim-chrome.ts; none: Xcode has none here).
type Typed = { size: { width: number; height: number }; panels: Panel[]; chrome: ChromeSource[] };

/// One that could boot, as a person picks it: its UDID, and what they call it ("iPhone 17 · iOS 26.2").
export type Bootable = { udid: string; title: string; model?: string };

export type SimulatorsOptions = {
  screens: Screens;
  /// The Computer Use helper that keeps running here; none: no simulator is listed.
  helper: () => ScreenHelper | null;
  /// Where CoreSimulator keeps the devices (default ~/Library/Developer/CoreSimulator/Devices).
  devices?: string;
  run?: Run;
  /// Whether this machine can have simulators at all (default: a Mac's).
  here?: boolean;
  /// Where Xcode keeps its DeviceKit chrome (default /Library/Developer/DeviceKit/Chrome).
  chrome?: string;
  /// How a device's screenshot is taken for an agent (default: `simctl io screenshot`).
  capture?: Capture;
};

/// The simulators of this Mac: each booted one a source in `screens` while it is booted, and those that could boot.
export class Simulators {
  readonly #o: SimulatorsOptions;
  readonly #run: Run;
  readonly #boots: () => Promise<Map<string, string>>;
  readonly #devices: string;
  readonly #here: boolean;
  readonly #chrome: string | undefined;
  readonly #listed = new Map<string, { source: Simulator; remove: () => void }>();
  #bootable: Bootable[] = [];
  /// A device type's screen and panels (`#typed`), by its identifier.
  readonly #types = new Map<string, Typed>();
  #catalog: Promise<{ identifier?: string; name?: string; bundlePath?: string }[]> | undefined;

  #deviceTypes(): Promise<{ identifier?: string; name?: string; bundlePath?: string }[]> {
    return this.#catalog ??= this.#run(SIMCTL, ["list", "-j", "devicetypes"])
      .then((raw) => JSON.parse(raw).devicetypes ?? [])
      .catch(() => { this.#catalog = undefined; return []; });
  }
  readonly #watchers = new Map<string, FSWatcher>();
  #looking: Promise<void> | null = null;
  #again = false;
  /// Calls off the look armed after a change on disk.
  #soon: (() => void) | null = null;
  #closed = false;
  #said = false;

  constructor(options: SimulatorsOptions) {
    this.#o = options;
    this.#run = options.run ?? run;
    this.#boots = async () => bootsOf(await this.#run("/bin/ps", ["-axww", "-o", "pid=,lstart=,args="]));
    this.#devices = options.devices ?? join(homedir(), "Library/Developer/CoreSimulator/Devices");
    this.#here = options.here ?? (platform.hasComputerUse && existsSync(SIMCTL));
    this.#chrome = options.chrome;
  }

  #can(): boolean {
    return this.#here && this.#o.helper() !== null && !this.#closed;
  }

  /// The devices looked at again (one look at a time; one asked meanwhile is made after it).
  refresh(): Promise<void> {
    if (!this.#can()) return Promise.resolve();
    if (this.#looking !== null) {
      this.#again = true;
      return this.#looking;
    }
    this.#looking = this.#look().finally(() => {
      this.#looking = null;
      if (this.#again) {
        this.#again = false;
        void this.refresh();
      }
    });
    return this.#looking;
  }

  /// Whether this Mac can have simulators at all: what agents are told it offers (simulator-agent.ts).
  here(): boolean {
    return this.#here;
  }

  /// The booted device listed at `id` (`simulator:<udid>`), as the last look found it.
  sourceOf(id: string): Simulator | undefined {
    if (!id.startsWith("simulator:")) return undefined;
    return this.#listed.get(id.slice("simulator:".length).toUpperCase())?.source;
  }

  /// The booted devices, as the last look found them.
  list(): Simulator[] {
    return [...this.#listed.values()].map((listed) => listed.source);
  }

  /// Hears the list each time a device comes or goes, until the returned function.
  watch(heard: () => void): () => void {
    return this.#o.screens.watch(() => heard());
  }

  /// Those that are shut down and could boot now, as the last look found them.
  bootable(): Bootable[] {
    return this.#can() ? this.#bootable : [];
  }

  /// Boots one that the list has as shut down: the id its screen will have, or null when it is no such device, it is not
  /// shut down, or `allowed` says no just before. It boots with no window (Simulator.app is not opened).
  async boot(udid: string, allowed: () => boolean): Promise<string | null> {
    if (!this.#can() || !UDID.test(udid)) return null;
    let devices: SimDevice[];
    try {
      devices = await this.#list();
    } catch {
      return null;
    }
    const device = devices.find((d) => d.udid === udid.toUpperCase());
    if (!device || device.booted || !allowed()) return null;
    try {
      await this.#run(SIMCTL, ["boot", device.udid]);
    } catch (error) {
      log.info("screens", "a simulator did not boot", { udid: device.udid, error: (error as Error).message.slice(0, 300) });
      return null;
    }
    void this.refresh();
    return `simulator:${device.udid}`;
  }

  async #list(): Promise<SimDevice[]> {
    return devicesOf(JSON.parse(await this.#run(SIMCTL, ["list", "-j", "devices"])));
  }

  /// The boot of one device now; null where it is not booted or its boot cannot be told.
  async bootOf(udid: string): Promise<string | null> {
    return (await this.#boots()).get(udid) ?? null;
  }

  async #look() {
    let devices: SimDevice[];
    let booted: Map<string, string>;
    try {
      devices = await this.#list();
      booted = await this.#boots();
    } catch (error) {
      // CoreSimulator too busy to answer (a device booting on a loaded Mac): what is listed stays, said once.
      if (!this.#said) log.info("screens", "simctl did not list the simulators", { error: (error as Error).message.slice(0, 300) });
      this.#said = true;
      return;
    }
    if (this.#closed) return;
    const models = new Map((await this.#deviceTypes()).map((type) => [type.identifier, type.name]));
    if (this.#closed) return;
    this.#bootable = devices.filter((d) => !d.booted).map((d) => ({ udid: d.udid, title: `${d.name} · ${d.runtime}`, ...(models.get(d.type) ? { model: models.get(d.type)! } : {}) }));
    const now = new Map(devices.filter((d) => d.booted).map((d) => [d.udid, d]));
    for (const [udid, listed] of this.#listed) {
      // Gone, or booted again since: another boot is another source.
      if (now.has(udid) && listed.source.boot === (booted.get(udid) ?? null)) continue;
      this.#forget(udid);
    }
    for (const device of now.values()) {
      if (this.#listed.has(device.udid)) continue;
      const { size, panels, chrome } = await this.#typed(device.type);
      if (this.#closed || this.#listed.has(device.udid)) continue;
      const source = new Simulator({ device, model: models.get(device.type), boot: booted.get(device.udid) ?? null, helper: this.#o.helper, size, panels, chrome, run: this.#run, bootOf: (udid) => this.bootOf(udid), replaced: () => void this.refresh(), ...(this.#o.capture ? { capture: this.#o.capture } : {}) });
      this.#listed.set(device.udid, { source, remove: this.#o.screens.add(source) });
    }
    this.#follow();
  }

  #forget(udid: string) {
    const listed = this.#listed.get(udid);
    if (!listed) return;
    this.#listed.delete(udid);
    listed.remove();
    listed.source.gone();
  }

  /// A device type's screen in pixels (its capabilities.plist; 0×0 when it cannot be read), panels (as its masks say
  /// them; none: no corners drawn) and case (as Xcode has it: sim-chrome.ts), read from its bundle once.
  async #typed(type: string): Promise<Typed> {
    const known = this.#types.get(type);
    if (known) return known;
    const typed: Typed = { size: { width: 0, height: 0 }, panels: [], chrome: [] };
    try {
      const types = await this.#deviceTypes();
      const bundle = types.find((t) => t.identifier === type)?.bundlePath;
      if (bundle) {
        const capabilities = JSON.parse(await this.#run("/usr/bin/plutil", ["-convert", "json", "-o", "-", join(bundle, "Contents/Resources/capabilities.plist")]));
        typed.size = screenOf(capabilities);
        const dir = join(bundle, "Contents/Resources");
        typed.panels = readdirSync(dir)
          .filter((f) => f.endsWith(".pdf") && !f.startsWith("sensor_bar"))
          .flatMap((f) => panelOf(readFileSync(join(dir, f))) ?? []);
        const profile = JSON.parse(await this.#run("/usr/bin/plutil", ["-convert", "json", "-o", "-", join(dir, "profile.plist")]));
        const sensor = typeof profile?.sensorBarImage === "string" ? profile.sensorBarImage : null;
        const cases = await Promise.all(displaysOf(capabilities, profile).map((d) => chromeOf(d, dir, sensor, this.#chrome)));
        typed.chrome = cases.flatMap((c) => c ?? []);
      }
    } catch {}
    this.#types.set(type, typed);
    return typed;
  }

  /// Watches the devices' folder (a device made or deleted) and each device's (its device.plist rewritten as it boots
  /// or shuts down; not what is below, which a running device writes all the time).
  #follow() {
    if (this.#closed || !existsSync(this.#devices)) return;
    const dirs = new Set([this.#devices]);
    try {
      for (const e of readdirSync(this.#devices, { withFileTypes: true })) if (e.isDirectory() && UDID.test(e.name)) dirs.add(join(this.#devices, e.name));
    } catch {}
    for (const [dir, w] of this.#watchers) {
      if (dirs.has(dir)) continue;
      w.close();
      this.#watchers.delete(dir);
    }
    for (const dir of dirs) {
      if (this.#watchers.has(dir)) continue;
      try {
        const w = watch(dir, (_event, name) => {
          if (dir === this.#devices || name === null || String(name).startsWith("device.plist")) this.#changed();
        });
        w.on("error", () => {
          w.close();
          this.#watchers.delete(dir);
        });
        this.#watchers.set(dir, w);
      } catch {}
    }
  }

  /// Something changed on disk: looked at once it settles (a boot rewrites device.plist a few times).
  #changed() {
    // CoreSimulator's own writes, waited on in the machine's time.
    this.#soon?.();
    this.#soon = wall.after(300, () => {
      this.#soon = null;
      void this.refresh();
    });
  }

  /// The station stopping: nothing followed, every source gone. No simulator is shut down.
  close() {
    this.#closed = true;
    this.#soon?.();
    for (const w of this.#watchers.values()) w.close();
    this.#watchers.clear();
    for (const udid of [...this.#listed.keys()]) this.#forget(udid);
  }
}

/// One booted simulator: a view is a stream of the helper's.
export class Simulator implements ScreenSource {
  readonly id: string;
  readonly kind = "simulator" as const;
  /// A preview opens as any view does: looking wakes nothing.
  readonly peek = true;
  readonly codecs: readonly Codec[] = ["h265", "h264", "jpeg"];
  readonly panels: Panel[];
  /// Its case and buttons, each panel's, as Xcode has them (sim-chrome.ts); empty where it has none.
  readonly chrome: ChromeSource[];
  /// What CoreSimulator calls it.
  readonly name: string;
  readonly model?: string;
  /// This boot (source.ts `instance`); none where its boot could not be told: it is then only looked at.
  readonly instance?: string;
  readonly boot: string | null;
  /// Shuts it down for good, this boot only.
  readonly discard?: () => Promise<void>;
  /// Its apps' logs, `simctl spawn <udid> log stream` while someone reads them (app-logs.ts).
  readonly logs: AppLogs;
  /// What debugs an app on it (sim-debug.ts).
  readonly debug: SimDebug;
  readonly #poses: boolean;
  readonly #device: SimDevice;
  readonly #helper: () => ScreenHelper | null;
  readonly #size: { width: number; height: number };
  readonly #bootOf: (udid: string) => Promise<string | null>;
  readonly #replaced: () => void;
  readonly #views = new Set<SimulatorView>();
  readonly #capture: Capture;
  /// The views a person drives it in now: an agent's input waits until none is (simulator-agent.ts).
  #held = 0;
  /// An agent's lease on it (simulator-agent.ts), and who hears of it (`watchAgent`).
  readonly #agent = new AgentPresence();

  constructor(o: { model?: string | undefined; device: SimDevice; boot: string | null; helper: () => ScreenHelper | null; size: { width: number; height: number }; panels?: Panel[]; chrome?: ChromeSource[]; run: Run; bootOf: (udid: string) => Promise<string | null>; replaced?: () => void; logs?: AppLogs; capture?: Capture }) {
    this.id = `simulator:${o.device.udid}`;
    this.logs = o.logs ?? simulatorLogs({ simctl: SIMCTL, udid: o.device.udid, run: o.run });
    this.debug = new SimDebug(SIMCTL, o.device.udid, o.run, () => this.#picture());
    this.name = o.device.name;
    if (o.model) this.model = o.model;
    this.boot = o.boot;
    if (o.boot !== null) this.instance = createHash("sha256").update(`${o.device.udid}\n${o.boot}`).digest("hex").slice(0, 16);
    this.#poses = o.device.type.endsWith(".iPhone-Duo");
    this.panels = o.panels ?? [];
    this.chrome = o.chrome ?? [];
    this.#device = o.device;
    this.#helper = o.helper;
    this.#size = o.size;
    this.#bootOf = o.bootOf;
    this.#replaced = o.replaced ?? (() => {});
    this.#capture = o.capture ?? capture;
    // The UDID names the device across its boots: the boot is checked just before it is shut down. A boot that ends and
    // another that starts between the check and simctl's shutdown is the same device booted again, shut down by it.
    if (o.boot !== null)
      this.discard = async () => {
        if (!(await this.current())) throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
        for (const view of [...this.#views]) view.close();
        await o.run(SIMCTL, ["shutdown", o.device.udid]).catch((error: Error) => {
          throw new ScreenRefused(502, "station.screen.failed", { said: error.message.slice(0, 300) });
        });
        this.#replaced();
      };
  }

  /// Still the boot listed.
  async current(): Promise<boolean> {
    const now = await this.#bootOf(this.#device.udid);
    if (this.boot !== null && now === this.boot) return true;
    this.#replaced();
    return false;
  }

  /// An iPhone Duo's hinge.
  poseNames(): DevicePose[] {
    return this.#poses ? ["closed", "open"] : [];
  }

  title(): string {
    return `${this.#device.name} · ${this.#device.runtime}`;
  }

  size(): { width: number; height: number } {
    return this.#size;
  }

  async open(options: ViewOptions & { control?: boolean }): Promise<ScreenView> {
    // A preview is a JPEG now and then where the client takes one; a view H.265 where it decodes it and this Mac encodes
    // it (the helper says which it gives), else H.264.
    const codec: Codec | undefined = options.peek === true && options.codecs.includes("jpeg") ? "jpeg" : options.codecs.find((c) => c === "h265" || c === "h264");
    if (codec === undefined) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264" });
    const running = this.#helper();
    if (running === null) throw new ScreenRefused(501, "station.screen.failed", { said: "this computer does not stream screens" });
    if (this.boot !== null && !(await this.current())) throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
    // A device may stand either way: the longer of the view's bounds is its bound both ways.
    const side = Math.max(options.maxWidth, options.maxHeight);
    const input = new SimInput();
    const ops: InputOps = { ops: (event) => input.ops(event as DeviceInput) };
    // A view the helper refuses ends as it opens, before `openView` gives it back: what it leaves is only known after.
    let view: SimulatorView | undefined;
    let ended = false;
    view = await openView(
      running,
      {
        target: "simulator",
        udid: this.#device.udid,
        // Which boot this is: what the helper knows of a foldable's hinge is of one boot.
        ...(this.boot !== null ? { boot: this.boot } : {}),
        codec,
        control: options.control === true && options.peek !== true,
        maxWidth: side,
        maxHeight: side,
        ...(options.peek ? { fps: PEEK_FPS } : {}),
        ...(options.bitrate !== undefined && codec !== "jpeg" ? { bitrate: Math.round(options.bitrate) } : {}),
        ...(options.timing ? { timing: true } : {}),
      },
      (socket) =>
        new SimulatorView(
          codec,
          socket,
          () => {
            ended = true;
            if (view) this.#views.delete(view);
          },
          ops,
          "CoreSimulator",
          wall.now,
          false,
          options.timing === true,
        ),
    );
    if (!ended) this.#views.add(view);
    return view;
  }

  /// Its screen as a view has it, as large as the device's own: a view of its own for one picture (still.fail's `#picture`).
  async #picture(): Promise<Uint8Array> {
    const { width, height } = this.#size;
    const view = await this.open({ maxWidth: width || 4096, maxHeight: height || 4096, codecs: ["jpeg"], peek: true });
    try {
      const frame = await view.next();
      if (frame === null) throw new Error("the simulator's view ended");
      return frame.data;
    } finally {
      view.close();
    }
  }

  /// A person's view that drives it opened: an agent's input waits until every such view is gone (the function given).
  hold(): () => void {
    this.#held++;
    let held = true;
    return () => {
      if (held) this.#held--;
      held = false;
    };
  }

  /// Whether a person drives it now.
  held(): boolean {
    return this.#held > 0;
  }

  /// What an agent's lease on it says while it lasts; set as one starts or ends, and those who look at it are told.
  get agent(): string | null {
    return this.#agent.lease;
  }

  set agent(next: string | null) {
    this.#agent.lease = next;
  }

  /// A person's view hears an agent's lease on it start and end, and where the agent's finger is (`ScreenSource.watchAgent`).
  watchAgent(heard: (said: AgentSaid) => void): () => void {
    return this.#agent.watch(heard);
  }

  /// Where the agent's finger is now, as it sent it (0..1 of the picture): shown to those who look.
  agentPoints(at: { x: number; y: number }, down: boolean) {
    this.#agent.points(at, down);
  }

  /// A screenshot for an agent: CoreSimulator's own of the device's screen, a PNG in its pixels (`simctl io
  /// screenshot`), at most `AGENT_SHOT_MOST` bytes. Refused once this boot has ended.
  async agentScreenshot(): Promise<Buffer> {
    if (this.boot !== null && !(await this.current())) throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
    return this.#capture(this.#device.udid);
  }

  /// A view an agent's input goes through, small (its pictures are not looked at), driving the device as a person's
  /// Control does. The agent closes it at its lease's end.
  agentView(): Promise<ScreenView> {
    return this.open({ codecs: ["h264"], maxWidth: AGENT_VIEW_SIDE, maxHeight: AGENT_VIEW_SIDE, control: true });
  }

  /// It shut down, booted again, or the station stops: its views end, and its logs and debug actions.
  gone() {
    for (const view of [...this.#views]) view.close();
    this.logs.close();
    this.debug.close();
  }
}

/// A view of a simulator: the helper's messages (screen-pipe.ts `HelperView`, still.fail's SimulatorView a ScreenView
/// too), a person's input translated for it (sim-input.ts). A device may stand either way: the longer side of the
/// bounds asked is its bound both ways (`bounds`, as at open).
export class SimulatorView extends HelperView {
  override bounds(maxWidth: number, maxHeight: number) {
    const side = Math.max(maxWidth, maxHeight);
    super.bounds(side, side);
  }
}
