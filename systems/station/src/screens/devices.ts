// The computer's Android devices, one set for the whole station (docs/android-screen.md): the emulators on its own adb
// server, and the phones its owner chose. The owner's views over the mesh (mesh/screens.ts) and the agents' leases
// (screens/android-agent.ts, through the device connection) both use it. A phone is a screen only once its owner chose
// its serial; before that only what the adb server says of it is listed (`phones`), and the phone is asked nothing.
// Agents reach a chosen phone only where its owner also turned on `agents` for it.
//
// Kept in config.json, `screens.phones`: `{usb, chosen: {<adb serial>: {agents}}}`. USB is off until the owner turns it
// on: the station's adb server then takes the machine's USB phones, as another adb server (Android Studio's, on 5037)
// would, and the two contend for them.
import { Context, Effect, Layer } from "effect";
import type { ConfigFile } from "../ops/config.ts";
import { log } from "../ops/log.ts";
import { Agents } from "../sessions/agents.ts";
import { adbPath } from "../mesh/adb.ts";
import { AndroidScreens, type AndroidScreen, type PhoneOnAdb, phoneCandidate, stationAdbPort, wirelessAddress } from "./android.ts";
import { type AgentClock, AndroidAgents } from "./android-agent.ts";
import { makeScreens } from "./source.ts";

export type PhoneChoice = { agents: boolean };
export type PhoneChoices = { usb: boolean; chosen: Record<string, PhoneChoice> };

/// A phone as its owner is shown it: what adb says of it, whether they chose it, and its screen once it is one.
export type PhoneListed = PhoneOnAdb & { shown: boolean; agents: boolean; screen?: string };

/// The most phones kept chosen: more is no person's computer.
const MOST_CHOSEN = 32;

/// `screens.phones` of config.json, as far as it says something valid.
export function phoneChoicesOf(raw: any): PhoneChoices {
  const phones = raw?.screens?.phones;
  const chosen: Record<string, PhoneChoice> = {};
  if (phones?.chosen !== null && typeof phones?.chosen === "object")
    for (const [serial, choice] of Object.entries(phones.chosen).slice(0, MOST_CHOSEN))
      if (phoneCandidate(serial) && choice !== null && typeof choice === "object") chosen[serial] = { agents: (choice as any).agents === true };
  return { usb: phones?.usb === true, chosen };
}

export class AndroidDevices {
  readonly screens = makeScreens();
  readonly androids: AndroidScreens;
  /// The agents' leases on these devices.
  readonly agents: AndroidAgents;
  readonly #config: ConfigFile;
  #applied = "";
  readonly #unlisten: () => void;

  constructor(o: { config: ConfigFile; androids?: (screens: ReturnType<typeof makeScreens>, choices: PhoneChoices) => AndroidScreens; adb?: () => string | null; serverPort?: number; clock?: AgentClock }) {
    this.#config = o.config;
    const choices = this.choices();
    this.#applied = JSON.stringify(choices);
    this.androids = o.androids
      ? o.androids(this.screens, choices)
      : new AndroidScreens({ screens: this.screens, adb: o.adb ?? adbPath, serverPort: o.serverPort ?? stationAdbPort(o.config.data), usb: choices.usb, phones: Object.keys(choices.chosen) });
    this.agents = new AndroidAgents(this, o.clock);
    // Edited elsewhere too (the file by hand): taken as it is.
    this.#unlisten = o.config.listen(() => void this.#apply());
  }

  choices(): PhoneChoices {
    return phoneChoicesOf(this.#config.raw());
  }

  /// What the server was last told, in turn: each change waits for the one before.
  #applying = Promise.resolve();

  #apply(): Promise<void> {
    this.#applying = this.#applying.then(() => this.#applyNow());
    return this.#applying;
  }

  async #applyNow(): Promise<void> {
    const choices = this.choices();
    const said = JSON.stringify(choices);
    if (said === this.#applied) return;
    this.#applied = said;
    // A phone its owner took back from agents (or no longer shows) has its lease end first, put back while it is
    // still a screen.
    await this.agents.revoke((serial) => choices.chosen[serial]?.agents === true);
    await this.androids.choose({ usb: choices.usb, phones: Object.keys(choices.chosen) }).catch((error) => log.warn("screens", "the phones chosen were not taken", { error: (error as Error).message }));
  }

  #edit(f: (choices: PhoneChoices) => void): Promise<void> {
    this.#config.update((raw) => {
      const choices = phoneChoicesOf(raw);
      f(choices);
      raw.screens = { ...(raw.screens ?? {}), phones: choices };
    });
    return this.#apply();
  }

  /// Whether the station's adb server takes USB phones.
  setUsb(on: boolean): Promise<void> {
    return this.#edit((c) => void (c.usb = on));
  }

  /// A phone shown or not, and whether agents may use it (`agents` only of a phone shown).
  choose(serial: string, choice: PhoneChoice | null): Promise<void> {
    if (!phoneCandidate(serial)) return Promise.reject(new Error("not a phone's serial"));
    return this.#edit((c) => {
      if (choice === null) delete c.chosen[serial];
      else if (Object.keys(c.chosen).length < MOST_CHOSEN || serial in c.chosen) c.chosen[serial] = { agents: choice.agents };
    });
  }

  /// A phone over Wi-Fi at the address its owner gave: connected on the station's server, and shown (agents off).
  async connect(address: string): Promise<string> {
    const checked = wirelessAddress(address);
    if (checked === null) throw new Error("not an address of a phone on the network (host:port)");
    const said = await this.androids.connect(checked);
    if (!(checked in this.choices().chosen)) await this.choose(checked, { agents: false });
    return said;
  }

  /// A phone over Wi-Fi let go of: disconnected, and no longer shown.
  async disconnect(address: string): Promise<string> {
    const checked = wirelessAddress(address);
    if (checked === null) throw new Error("not an address of a phone on the network (host:port)");
    await this.choose(checked, null);
    return this.androids.disconnect(checked);
  }

  /// The phones on the station's adb, and those chosen that are not there now.
  phones(): PhoneListed[] {
    const { chosen } = this.choices();
    const on = this.androids.phonesOn();
    const screens = new Map(this.screens.list().map((s) => [(s as AndroidScreen).serial, s.id]));
    const listed = on.map((p): PhoneListed => ({ ...p, shown: p.serial in chosen, agents: chosen[p.serial]?.agents === true, ...(screens.has(p.serial) ? { screen: screens.get(p.serial)! } : {}) }));
    for (const [serial, choice] of Object.entries(chosen))
      if (!on.some((p) => p.serial === serial)) listed.push({ serial, state: "absent", model: null, transport: wirelessAddress(serial) ? "wifi" : "usb", shown: true, agents: choice.agents });
    return listed;
  }

  /// Whether agents may lease this device: an emulator, or a phone its owner chose for them.
  agentsMay(source: AndroidScreen): boolean {
    return !source.phone || this.choices().chosen[source.serial]?.agents === true;
  }

  async close(): Promise<void> {
    this.#unlisten();
    // (each phone put back before its server stops)
    await this.agents.close();
    this.androids.close();
    await this.androids.stopServer();
  }
}

export class AndroidDevicesService extends Context.Service<AndroidDevicesService, AndroidDevices>()("comma/AndroidDevices") {
  static readonly layer = Layer.effect(
    AndroidDevicesService,
    Effect.gen(function* () {
      const agents = yield* Agents;
      return yield* Effect.acquireRelease(
        Effect.sync(() => new AndroidDevices({ config: agents.config })),
        (devices) => Effect.promise(() => devices.close()),
      );
    }),
  );
}
