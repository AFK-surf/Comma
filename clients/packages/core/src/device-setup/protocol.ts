import { z } from "zod";
import type { Calls } from "../contract.ts";

export const gatt = {
  service: "f2d20001-eb8e-4a64-9ec7-ab0cbb8107c8",
  wifiScan: "f2d20002-eb8e-4a64-9ec7-ab0cbb8107c8",
  wifiCredentials: "f2d20003-eb8e-4a64-9ec7-ab0cbb8107c8",
  credentials: "f2d20004-eb8e-4a64-9ec7-ab0cbb8107c8",
  status: "f2d20005-eb8e-4a64-9ec7-ab0cbb8107c8",
  info: "f2d20006-eb8e-4a64-9ec7-ab0cbb8107c8",
} as const;

export type Credentials = Calls["connector.provisionDevice"]["result"];
export interface FoundDevice {
  id: string;
  name: string;
  rssi: number;
}
export interface WifiNetwork {
  ssid: string;
  rssi: number;
  secure: boolean;
}
export const infoSchema = z.object({
  mac: z.string().min(1).max(64),
  name: z.string().min(1).max(63),
  model: z.string().optional(),
  fw_version: z.string().optional(),
  provisioned: z.boolean(),
});
export const statusSchema = z.object({
  state: z.string(),
  ssid: z.string().optional(),
  error: z.string().optional(),
});
export type DeviceStatus = z.infer<typeof statusSchema>;
export const utf8Length = (value: string) => new TextEncoder().encode(value).length;
export const validName = (name: string) =>
  name.trim().length > 0 && utf8Length(name.trim()) <= 63;
export const validPassword = (network: WifiNetwork, password: string) =>
  network.secure ? password.length >= 8 && password.length <= 64 : password === "";

/** CoreBluetooth includes the company identifier in manufacturer data. This identifies a setup family, not a board. */
export function advertisement(
  bytes: readonly number[]
): { name: string; state: "new" | "pairing" } | null {
  if (
    bytes.length < 7 ||
    bytes[0] !== 255 ||
    bytes[1] !== 255 ||
    bytes[2] !== 1 ||
    bytes[3] !== 1 ||
    (bytes[4] !== 0 && bytes[4] !== 1)
  )
    return null;
  return {
    name: `Comma-${bytes
      .slice(5, 7)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
      .toUpperCase()}`,
    state: bytes[4] === 0 ? "new" : "pairing",
  };
}

export function wifiJson(network: WifiNetwork, password: string): string {
  if (
    utf8Length(network.ssid) < 1 ||
    utf8Length(network.ssid) > 32 ||
    !validPassword(network, password)
  )
    throw new Error("Invalid network or password");
  return JSON.stringify({ ssid: network.ssid, password });
}

export function credentialsJson(
  c: Credentials,
  workspace: string,
  name: string
): string {
  const bounded = (s: string, max: number) => utf8Length(s) > 0 && utf8Length(s) <= max;
  if (
    !validName(name) ||
    !bounded(workspace, 95) ||
    !bounded(c.voiceGroup, 95) ||
    !bounded(c.voiceServer, 127) ||
    !/^https?:\/\/.+/.test(c.voiceServer) ||
    !bounded(c.connectUrl, 159) ||
    !/^wss?:\/\/.+/.test(c.connectUrl) ||
    !bounded(c.connectorToken, 159) ||
    !c.connectorToken.startsWith("salix_conn_") ||
    !bounded(c.voiceKey, 159) ||
    !c.voiceKey.startsWith("salix_vk_")
  )
    throw new Error("Invalid device credentials");
  const value = JSON.stringify({
    server: c.voiceServer,
    connect_url: c.connectUrl,
    workspace_id: workspace,
    group_id: c.voiceGroup,
    connector_token: c.connectorToken,
    voice_key: c.voiceKey,
    device_name: name.trim(),
  });
  if (utf8Length(value) > 512) throw new Error("Device credentials exceed 512 bytes");
  return value;
}

const pageSchema = z.object({
  page: z.number().int().min(0).max(31),
  pages: z.number().int().min(1).max(32),
  aps: z
    .array(
      z.object({
        ssid: z
          .string()
          .min(1)
          .max(32)
          .refine((value) => utf8Length(value) <= 32),
        rssi: z.number(),
        secure: z.boolean(),
      })
    )
    .max(20),
});
export class WifiPages {
  private total = 0;
  private pages = new Map<number, WifiNetwork[]>();
  reset(): void {
    this.total = 0;
    this.pages.clear();
  }
  accept(value: unknown): WifiNetwork[] | "failed" | null {
    if (value && typeof value === "object" && "error" in value) {
      this.reset();
      return "failed";
    }
    const parsed = pageSchema.safeParse(value);
    if (!parsed.success || parsed.data.page >= parsed.data.pages) return null;
    const p = parsed.data;
    if (p.pages !== this.total) {
      this.reset();
      this.total = p.pages;
    }
    this.pages.set(p.page, p.aps);
    if (this.pages.size !== this.total) return null;
    const networks = new Map<string, WifiNetwork>();
    for (const aps of this.pages.values())
      for (const ap of aps) {
        if (!networks.has(ap.ssid) || networks.get(ap.ssid)!.rssi < ap.rssi)
          networks.set(ap.ssid, ap);
      }
    this.reset();
    return [...networks.values()].toSorted((a, b) => b.rssi - a.rssi).slice(0, 20);
  }
}
