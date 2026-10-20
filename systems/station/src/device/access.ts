// The computer's one access value (off | read | full): how far the control plane's agents may go on this machine, both
// through the device tools (device/tools.ts) and through the device connector to Salix (connector/connector.ts). It is
// kept once, in config.json: `tools.access`, with `tools.computer: true` once it is the computer's value. Before that
// the value is the device tools' alone (a station from before), and the first device connector that starts gives the
// computer its value: what that connector was configured with (the desktop app's choice, or a standalone device's
// device-access.json), read or full. `tools.owner` is the Comma user the device connection belongs to: only that user
// sets the value through the admin API (api/routes/tools.ts) once it is known.
import type { ConfigFile } from "../ops/config.ts";

export type Access = "off" | "read" | "full";
export const ACCESS: readonly Access[] = ["off", "read", "full"];
export const DEFAULT_ACCESS: Access = "off";

/// The access config.json gives (`tools.access`); off when it names none it knows.
export function accessOf(raw: any): Access {
  const said = raw?.tools?.access;
  return ACCESS.includes(said) ? said : DEFAULT_ACCESS;
}

/// What a device connector keeps its access in: the station's (computerAccess), or its own in memory without one.
export type AccessStore = {
  /// The computer's value; null while it has none yet (the connector's own configuration then gives it).
  get(): Access | null;
  set(next: Access): void;
  /// Hears the value change; gives the function that stops it.
  listen(changed: () => void): () => void;
  /// The Comma user the device connection belongs to, as Salix says it at each connection.
  owner?(userId: string): void;
};

const toolsOf = (raw: any): Record<string, unknown> => (raw?.tools !== null && typeof raw?.tools === "object" ? raw.tools : {});

/// The user whose computer this is, as its device connection last said; null before one said it.
export function ownerOf(raw: any): string | null {
  const owner = toolsOf(raw).owner;
  return typeof owner === "string" && owner !== "" ? owner : null;
}

/// The station's store: config.json, shared by the device tools and every device connector of the station.
export function computerAccess(config: ConfigFile): AccessStore {
  const settled = () => toolsOf(config.raw()).computer === true;
  const edit = (fields: Record<string, unknown>) =>
    config.update((raw) => {
      raw.tools = { ...toolsOf(raw), ...fields };
    });
  return {
    get: () => (settled() ? accessOf(config.raw()) : null),
    set: (next) => {
      if (!ACCESS.includes(next)) throw new Error(`access is one of ${ACCESS.join(", ")}`);
      if (settled() && accessOf(config.raw()) === next) return;
      edit({ access: next, computer: true });
    },
    listen: (changed) => {
      let last = settled() ? accessOf(config.raw()) : null;
      return config.listen(() => {
        const now = settled() ? accessOf(config.raw()) : null;
        if (now === last) return;
        last = now;
        changed();
      });
    },
    owner: (userId) => {
      if (userId !== "" && ownerOf(config.raw()) !== userId) edit({ owner: userId });
    },
  };
}

/// A connector's own store, without a station: the value lives as long as the connector.
export function memoryAccess(): AccessStore {
  let value: Access | null = null;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set: (next) => {
      if (next === value) return;
      value = next;
      for (const listener of listeners) listener();
    },
    listen: (changed) => {
      listeners.add(changed);
      return () => listeners.delete(changed);
    },
  };
}

/// The value an access request asks for: `{access}` (off | read | full), or the 2-level `{allow_operations}` of
/// clients and servers from before: true is full; false is read, and a computer that is off stays off.
export function requestedAccess(params: Record<string, unknown>, current: Access): Access {
  const access = params.access;
  if (access !== undefined) {
    if (typeof access !== "string" || !ACCESS.includes(access as Access)) throw new Error(`access is one of ${ACCESS.join(", ")}`);
    return access as Access;
  }
  const allow = params.allow_operations;
  if (typeof allow !== "boolean") throw new Error("access (off, read or full) or allow_operations (a boolean) is required");
  return fromAllowOperations(allow, current);
}

export const fromAllowOperations = (allow: boolean, current: Access): Access => (allow ? "full" : current === "off" ? "off" : "read");
