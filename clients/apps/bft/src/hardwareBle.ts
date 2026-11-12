/**
 * Web Bluetooth side of setting up a Comma hardware board (AFK-surf/Hardware,
 * `docs/ble-provisioning.md`): the GATT service, its Wi-Fi scan pages and the
 * board's `status` notifications. Chrome and Edge on desktop and Android have
 * Web Bluetooth; the browser's own chooser picks the board and the operating
 * system asks for the six-digit code a screen board shows.
 */
import { z } from "zod";
import type { BftHardwareCredentials } from "./api";

const uuid = (n: string) => `f2d2${n}-eb8e-4a64-9ec7-ab0cbb8107c8`;
const gatt = {
  service: uuid("0001"),
  wifiScan: uuid("0002"),
  wifiCredentials: uuid("0003"),
  credentials: uuid("0004"),
  status: uuid("0005"),
  info: uuid("0006"),
} as const;

// The few Web Bluetooth types used here; TypeScript's DOM library has none.
interface Characteristic extends EventTarget {
  value?: DataView;
  readValue(): Promise<DataView>;
  writeValueWithResponse(value: BufferSource): Promise<void>;
  startNotifications(): Promise<Characteristic>;
}
interface Service {
  getCharacteristic(uuid: string): Promise<Characteristic>;
}
interface Server {
  connected: boolean;
  connect(): Promise<Server>;
  disconnect(): void;
  getPrimaryService(uuid: string): Promise<Service>;
}
interface Device extends EventTarget {
  gatt?: Server;
}
interface Bluetooth {
  requestDevice(options: { filters: { services: string[] }[] }): Promise<Device>;
}

const bluetooth = () =>
  (navigator as Navigator & { bluetooth?: Bluetooth }).bluetooth ?? null;

/** Whether this browser can set up a board at all. */
export const bluetoothAvailable = () => bluetooth() !== null;

const infoSchema = z.object({
  name: z.string().min(1).max(63),
  model: z.string().optional(),
  mac: z.string().optional(),
});
const statusSchema = z.object({
  state: z.string(),
  error: z.string().optional(),
});
const pageSchema = z.object({
  page: z.number().int().min(0),
  pages: z.number().int().min(1).max(32),
  aps: z.array(
    z.object({ ssid: z.string().min(1), rssi: z.number(), secure: z.boolean() })
  ),
  error: z.string().optional(),
});

export interface WifiNetwork {
  ssid: string;
  rssi: number;
  secure: boolean;
}
export type BoardStatus = z.infer<typeof statusSchema>;

const encoder = new TextEncoder();
const decode = (view: DataView) =>
  JSON.parse(new TextDecoder().decode(view)) as unknown;
const write = (characteristic: Characteristic, value: unknown) =>
  characteristic.writeValueWithResponse(encoder.encode(JSON.stringify(value)));

/** A board's password rules: open networks take none, others 8 to 64 characters. */
export const validPassword = (network: WifiNetwork, password: string) =>
  network.secure ? password.length >= 8 && password.length <= 64 : password === "";

/** One connected board. */
export class Board {
  private constructor(
    private readonly device: Device,
    private readonly server: Server,
    private readonly chars: Record<
      Exclude<keyof typeof gatt, "service">,
      Characteristic
    >,
    readonly name: string
  ) {}

  /**
   * Lets the person pick a board in the browser's chooser and connects to it.
   * Reading `info` is the first protected access: a screen board shows its
   * code then, and the operating system asks for it.
   */
  static async pick(): Promise<Board> {
    const api = bluetooth();
    if (!api) throw new Error("bluetooth_unavailable");
    const device = await api.requestDevice({ filters: [{ services: [gatt.service] }] });
    const server = await device.gatt!.connect();
    const service = await server.getPrimaryService(gatt.service);
    const get = (key: keyof typeof gatt) => service.getCharacteristic(gatt[key]);
    const chars = {
      wifiScan: await get("wifiScan"),
      wifiCredentials: await get("wifiCredentials"),
      credentials: await get("credentials"),
      status: await get("status"),
      info: await get("info"),
    };
    const info = infoSchema.parse(decode(await chars.info.readValue()));
    return new Board(device, server, chars, info.name);
  }

  /** The 2.4 GHz networks the board sees, strongest first. */
  async scan(): Promise<WifiNetwork[]> {
    const pages = new Map<number, WifiNetwork[]>();
    const scan = this.chars.wifiScan;
    await scan.startNotifications();
    return new Promise((resolve, reject) => {
      const onPage = () => {
        const parsed = scan.value ? pageSchema.safeParse(decode(scan.value)) : null;
        if (!parsed?.success) return;
        if (parsed.data.error) {
          scan.removeEventListener("characteristicvaluechanged", onPage);
          reject(new Error(`wifi_scan_${parsed.data.error}`));
          return;
        }
        pages.set(parsed.data.page, parsed.data.aps);
        if (pages.size < parsed.data.pages) return;
        scan.removeEventListener("characteristicvaluechanged", onPage);
        const best = new Map<string, WifiNetwork>();
        for (const network of [...pages.values()].flat())
          if ((best.get(network.ssid)?.rssi ?? -Infinity) < network.rssi)
            best.set(network.ssid, network);
        resolve([...best.values()].toSorted((a, b) => b.rssi - a.rssi));
      };
      scan.addEventListener("characteristicvaluechanged", onPage);
      write(scan, {}).catch(reject);
    });
  }

  /** Calls `onStatus` with every status the board reports from now on. */
  async watch(onStatus: (status: BoardStatus) => void): Promise<() => void> {
    const status = this.chars.status;
    await status.startNotifications();
    const listener = () => {
      const parsed = status.value ? statusSchema.safeParse(decode(status.value)) : null;
      if (parsed?.success) onStatus(parsed.data);
    };
    status.addEventListener("characteristicvaluechanged", listener);
    return () => status.removeEventListener("characteristicvaluechanged", listener);
  }

  /** Starts a trial connection; `status` reports `wifi_up` or `wifi_failed`. */
  joinWifi(ssid: string, password: string) {
    return write(this.chars.wifiCredentials, { ssid, password });
  }

  /** Stores the credentials; the board then reports `saved` and connects. */
  saveCredentials(credentials: BftHardwareCredentials) {
    const { device_id: _deviceId, ...stored } = credentials;
    return write(this.chars.credentials, stored);
  }

  /** Calls `listener` once the Bluetooth connection drops. */
  onDisconnect(listener: () => void) {
    this.device.addEventListener("gattserverdisconnected", listener, { once: true });
  }

  disconnect() {
    if (this.server.connected) this.server.disconnect();
  }
}
