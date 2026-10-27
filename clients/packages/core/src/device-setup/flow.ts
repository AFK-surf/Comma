import {
  validName,
  validPassword,
  type Credentials,
  type DeviceStatus,
  type FoundDevice,
  type WifiNetwork,
} from "./protocol.ts";

export type SetupState =
  | { step: "idle" }
  | { step: "scanning"; devices: FoundDevice[]; quiet: boolean }
  | { step: "pairing"; device: FoundDevice; connected: boolean }
  | {
      step: "wifi";
      device: FoundDevice;
      name: string;
      networks: WifiNetwork[] | null;
      scanning: boolean;
      failure: string | null;
    }
  | {
      step: "setup";
      device: FoundDevice;
      name: string;
      ssid: string;
      networks: WifiNetwork[] | null;
      phase: "joining" | "minting" | "saving" | "online";
    }
  | { step: "done"; name: string; deviceId: string; online: boolean }
  | { step: "failed"; problem: string }
  | { step: "cancelled" };
export type Timer = "quiet" | "connect" | "pair" | "scan" | "join" | "save" | "online";
export const timeouts: Record<Timer, number> = {
  quiet: 15_000,
  connect: 20_000,
  pair: 120_000,
  scan: 20_000,
  join: 45_000,
  save: 20_000,
  online: 90_000,
};
export type SetupEvent =
  | { type: "found"; device: FoundDevice }
  | { type: "pick"; id: string }
  | { type: "paired"; name: string }
  | { type: "networks"; networks: WifiNetwork[] }
  | { type: "rename"; name: string }
  | { type: "join"; ssid: string; password: string }
  | { type: "status"; status: DeviceStatus }
  | { type: "minted"; credentials: Credentials; attempt: number }
  | { type: "remembered"; attempt: number }
  | { type: "failed"; problem: string; attempt?: number }
  | { type: "timeout"; timer: Timer; generation: number }
  | {
      type:
        | "connected"
        | "lost"
        | "rescan"
        | "scanFailed"
        | "online"
        | "cancel"
        | "retry";
    };
export type SetupEffect =
  | { type: "scan" | "stopScan" | "pair" | "scanWifi" | "disconnect" | "stopWatching" }
  | { type: "connect"; device: FoundDevice }
  | { type: "join"; network: WifiNetwork; password: string }
  | { type: "mint"; name: string; attempt: number }
  | { type: "remember"; credentials: Credentials; name: string; attempt: number }
  | { type: "write"; credentials: Credentials; name: string }
  | { type: "revoke"; credentials: Credentials }
  | { type: "watch" | "confirm"; deviceId: string }
  | { type: "rename"; deviceId: string; name: string }
  | { type: "arm"; timer: Timer; generation: number };

/** One foreground setup. Credentials and effect inputs never enter the UI projection. */
export class SetupFlow {
  state: SetupState = { step: "idle" };
  private credentials: Credentials | null = null;
  private saved = false;
  private attempt = 0;
  private generation = 0;
  private timer: Timer | null = null;
  start(): SetupEffect[] {
    this.credentials = null;
    this.saved = false;
    this.state = { step: "scanning", devices: [], quiet: false };
    return [{ type: "scan" }, this.arm("quiet")];
  }
  handle(e: SetupEvent): SetupEffect[] {
    const s = this.state;
    if (e.type === "minted") {
      if (
        e.attempt !== this.attempt ||
        s.step !== "setup" ||
        s.phase !== "minting" ||
        this.credentials
      )
        return [{ type: "revoke", credentials: e.credentials }];
      this.credentials = e.credentials;
      return [
        {
          type: "remember",
          credentials: e.credentials,
          name: s.name,
          attempt: e.attempt,
        },
      ];
    }
    if (e.type === "cancel") {
      if (s.step === "done" || s.step === "cancelled") return [];
      const effects = this.end(!(s.step === "setup" && s.phase === "online"));
      this.state = { step: "cancelled" };
      return effects;
    }
    if (e.type === "retry") return s.step === "failed" ? this.start() : [];
    if (e.type === "timeout")
      return e.generation === this.generation && e.timer === this.timer
        ? this.timeout(e.timer)
        : [];
    if (
      s.step === "done" ||
      s.step === "failed" ||
      s.step === "cancelled" ||
      s.step === "idle"
    )
      return [];
    if (e.type === "failed")
      return e.attempt === undefined || e.attempt === this.attempt
        ? this.fail(e.problem)
        : [];
    if (s.step === "scanning") {
      if (e.type === "found")
        this.state = {
          ...s,
          devices: [
            ...s.devices.filter(
              (d) => d.id !== e.device.id && d.name !== e.device.name
            ),
            e.device,
          ]
            .slice(-50)
            .toSorted((a, b) => a.name.localeCompare(b.name)),
        };
      if (e.type === "pick") {
        const device = s.devices.find((d) => d.id === e.id);
        if (device) {
          this.state = { step: "pairing", device, connected: false };
          return [
            { type: "stopScan" },
            { type: "connect", device },
            this.arm("connect"),
          ];
        }
      }
    }
    if (s.step === "pairing") {
      if (e.type === "connected" && !s.connected) {
        this.state = { ...s, connected: true };
        return [{ type: "pair" }, this.arm("pair")];
      }
      if (e.type === "paired") {
        this.state = {
          step: "wifi",
          device: s.device,
          name: e.name,
          networks: null,
          scanning: true,
          failure: null,
        };
        return [{ type: "scanWifi" }, this.arm("scan")];
      }
      if (e.type === "lost")
        return this.fail(s.connected ? "pairing_failed" : "connect_failed");
    }
    if (s.step === "wifi") {
      if (e.type === "networks") {
        this.state = { ...s, networks: e.networks, scanning: false, failure: null };
        this.disarm();
      }
      if (e.type === "scanFailed") {
        this.state = { ...s, scanning: false, failure: "scan_failed" };
        this.disarm();
      }
      if (e.type === "rescan" && !s.scanning) {
        this.state = { ...s, scanning: true, failure: null };
        return [{ type: "scanWifi" }, this.arm("scan")];
      }
      if (e.type === "rename" && validName(e.name))
        this.state = { ...s, name: e.name.trim() };
      if (e.type === "join") {
        const network = s.networks?.find((n) => n.ssid === e.ssid);
        if (network && validName(s.name) && validPassword(network, e.password)) {
          this.state = {
            step: "setup",
            device: s.device,
            name: s.name,
            ssid: network.ssid,
            networks: s.networks,
            phase: "joining",
          };
          return [{ type: "join", network, password: e.password }, this.arm("join")];
        }
      }
      if (e.type === "lost") return this.fail("disconnected");
    }
    if (s.step === "setup") {
      if (s.phase === "joining") {
        if (e.type === "status" && e.status.state === "wifi_failed") {
          this.state = {
            step: "wifi",
            device: s.device,
            name: s.name,
            networks: s.networks,
            scanning: false,
            failure: e.status.error ?? "failed",
          };
          this.disarm();
        }
        if (
          e.type === "status" &&
          e.status.state === "wifi_up" &&
          (!e.status.ssid || e.status.ssid === s.ssid)
        ) {
          this.state = { ...s, phase: "minting" };
          this.disarm();
          return [{ type: "mint", name: s.name, attempt: ++this.attempt }];
        }
        if (e.type === "lost") return this.fail("disconnected");
      } else if (s.phase === "minting") {
        if (e.type === "remembered" && e.attempt === this.attempt && this.credentials) {
          this.state = { ...s, phase: "saving" };
          return [
            { type: "write", credentials: this.credentials, name: s.name },
            this.arm("save"),
          ];
        }
        if (e.type === "lost") return this.fail("disconnected");
      } else if (s.phase === "saving") {
        if (e.type === "status" && e.status.state === "saved") {
          this.saved = true;
          return this.watch();
        }
        if (e.type === "status" && e.status.error === "save_failed")
          return this.fail("save_failed");
        if (e.type === "lost") return this.watch();
      } else {
        if (e.type === "status" && e.status.state === "connector_failed") {
          this.saved = false;
          return this.fail("connector_rejected");
        }
        if (e.type === "online" && this.credentials) {
          const deviceId = this.credentials.deviceId;
          this.saved = true;
          this.disarm();
          this.state = { step: "done", name: s.name, deviceId, online: true };
          return [
            { type: "confirm", deviceId },
            { type: "stopWatching" },
            { type: "disconnect" },
            { type: "rename", deviceId, name: s.name },
          ];
        }
      }
    }
    return [];
  }
  private watch(): SetupEffect[] {
    if (this.state.step !== "setup" || !this.credentials)
      return this.fail("disconnected");
    this.state = { ...this.state, phase: "online" };
    return [{ type: "watch", deviceId: this.credentials.deviceId }, this.arm("online")];
  }
  private timeout(timer: Timer): SetupEffect[] {
    const s = this.state;
    if (timer === "quiet" && s.step === "scanning") {
      this.state = { ...s, quiet: true };
      return [];
    }
    if (timer === "scan" && s.step === "wifi") {
      this.state = { ...s, scanning: false, failure: "scan_failed" };
      return [];
    }
    if (timer === "save") return this.watch();
    if (timer === "online" && this.saved && s.step === "setup" && this.credentials) {
      this.state = {
        step: "done",
        name: s.name,
        deviceId: this.credentials.deviceId,
        online: false,
      };
      // The device holds its credentials, so its record no longer expires: it is confirmed like any offline device.
      return [
        { type: "confirm", deviceId: this.credentials.deviceId },
        { type: "stopWatching" },
        { type: "disconnect" },
      ];
    }
    return this.fail(
      timer === "connect"
        ? "connect_failed"
        : timer === "online"
          ? "not_online"
          : "timeout"
    );
  }
  private fail(problem: string): SetupEffect[] {
    const effects = this.end(true);
    this.state = { step: "failed", problem };
    return effects;
  }
  private end(revoke: boolean): SetupEffect[] {
    const effects: SetupEffect[] = [
      { type: "stopScan" },
      { type: "stopWatching" },
      { type: "disconnect" },
    ];
    if (revoke && this.credentials && !this.saved)
      effects.push({ type: "revoke", credentials: this.credentials });
    this.credentials = null;
    this.disarm();
    return effects;
  }
  private arm(timer: Timer): SetupEffect {
    this.timer = timer;
    return { type: "arm", timer, generation: ++this.generation };
  }
  private disarm(): void {
    this.timer = null;
    this.generation++;
  }
}
