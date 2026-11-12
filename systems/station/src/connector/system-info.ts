// The host description sent with metadata. Field names and values follow what Salix already stores
// (SalixEnv.Control's system_info fields), so OS and architecture use Go's names.

import { cpus, hostname as osHostname, release, totalmem, type as osType } from "node:os";
import { platform } from "../platform/index.ts";

export const goOs = (): string => platform.goOs;
export const goArch = (): string => ({ x64: "amd64", arm64: "arm64", ia32: "386" } as Record<string, string>)[process.arch] ?? process.arch;

/**
 * The machine's name as a person calls it: its host name without the `.local` macOS gives it on the local network. The
 * connector dials with it, so the device is named so where the app names it nothing else (still.fail names its station
 * so: station/src/read/host.ts, screens/desktop.ts; as this station's read/host.ts does).
 */
export function machineName(name: string = osHostname()): string {
  return name.endsWith(".local") ? name.slice(0, -".local".length) : name;
}

export function hostname(): string {
  return machineName() || "station";
}

let cachedCpuModel: string | undefined;

export function systemInfo(nowMs: number): Record<string, unknown> {
  const info: Record<string, unknown> = { hostname: hostname(), os_type: goOs(), arch: goArch(), cpu_count: cpus().length, collected_at: nowMs };
  cachedCpuModel ??= cpus()[0]?.model?.trim() ?? "";
  if (cachedCpuModel) info.cpu_model = cachedCpuModel;
  const memory = totalmem();
  if (memory > 0) info.memory_total = memory;
  const version = `${osType()} ${release()}`.trim();
  if (version) info.os_version = version;
  return info;
}

/** Which Comma client started this device connector, from the runtime namespace it was given. */
export function clientSource(runtimeNamespace: string): string {
  return ({ "@comma-dev": "comma_dev", "@comma-staging": "comma_staging", "@comma": "comma" } as Record<string, string>)[runtimeNamespace] ?? "connector";
}

