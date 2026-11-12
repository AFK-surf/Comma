// The station's commands other than `run` (the Rust station's main.rs `main`): enroll, status, id. Their output is what
// people and `bin/comma-station` read, so its words are the catalog's, as the Rust station says them.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { INSTANCES_DIR } from "./accounts/sources.ts";
import { loadKey } from "./cloud/key.ts";
import { readState, writeState, type CloudState } from "./cloud/state.ts";
import { type Provider, specOf } from "./cloud/provider.ts";
import { stationLang, tr } from "./ops/i18n.ts";
import { version } from "./ops/version.ts";

const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((s): s is string => typeof s === "string") : []);

/// What a control plane's answer (an enrollment's, or a placement's: connector/service.ts) says of where station `id`
/// is, as cloud.json keeps it.
export function placedState(origin: string, id: string, body: any, provider: Provider): CloudState {
  const text = (k: string) => (typeof body?.[k] === "string" ? body[k] : "");
  const relays = strings(body?.relay_urls);
  const state: CloudState = {
    origin, station: id, workspace: text("workspace"), workspace_name: text("workspace_name"), name: text("name"),
    // Comma names no relay of its own apart from the list: its first is the station's home.
    relay_url: text("relay_url") || (provider === "comma" ? (relays[0] ?? "") : ""), relay_urls: relays, grant_keys: body?.grant_keys ?? null, peers: [], revocations: [],
  };
  const was = strings(body?.workspace_was).filter((w) => w !== "");
  if (was.length > 0) state.workspace_was = was;
  if (provider !== "stillfail") {
    state.provider = provider;
    state.gateway_keys = strings(body?.gateway_keys);
  }
  return state;
}

/// The connection to Salix an enrollment gave this machine: an instance of the station's (connector/service.ts), as the
/// desktop app's are, under the name a later enrollment replaces.
export function writeDeviceInstance(data: string, origin: string, connector: any) {
  const dir = join(data, INSTANCES_DIR);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const config = {
    comma: { workspace_id: connector.workspace_id },
    connector: {
      connector_token: connector.token,
      name: connector.name,
      reconnect: true,
      device: true,
      device_state_root: join(data, "connector", "device"),
      workspace_id: connector.workspace_id,
      server: connector.server || origin,
    },
  };
  writeFileSync(join(dir, "device.json"), `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
}

/// Joins a workspace with a one-time token: proves this station holds its key, writes cloud.json. `provider`: whose
/// control plane it is (still.fail cloud unless told; cloud/provider.ts).
export async function enroll(data: string, origin: string, token: string, provider: Provider = "stillfail") {
  const plane = specOf(provider);
  const key = loadKey(data);
  let response: Response | undefined;
  // The new proof first; the old spelling only when a pre-rename cloud explicitly refuses the signature.
  for (const prefix of plane.enrollPrefixes) {
    const signature = key.sign(`${prefix}-station-enroll-v1:${origin}:${token}:${key.id}`);
    response = await fetch(`${origin}${plane.enrollPath}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token, station: key.id, signature, version: version() }),
      signal: AbortSignal.timeout(20_000),
    });
    if (prefix === plane.enrollPrefixes.at(-1) || response.status !== 401) break;
    const text = await response.text();
    let error: unknown;
    try {
      error = JSON.parse(text).error;
    } catch {}
    if (error !== "invalid_signature") throw new Error(`${plane.name} answered ${response.status}: ${text}`);
  }
  if (!response!.ok) throw new Error(`${plane.name} answered ${response!.status}: ${await response!.text()}`);
  const body: any = await response!.json();
  const state = placedState(origin, key.id, body, provider);
  writeState(data, state);
  if (typeof body?.connector?.token === "string") writeDeviceInstance(data, origin, body.connector);
  console.log(tr(stationLang(), "station.cli.joined", { workspace: state.workspace_name, name: state.name, id: key.id.slice(0, 12) }));
}

export function id(data: string) {
  console.log(loadKey(data).id);
}

/// Where the station is: running or not, its workspace, online or why not.
export function status(data: string): string {
  const say = (key: string, args?: Record<string, unknown>) => tr(stationLang(), key, args);
  const when = (secs: number) => new Date(secs * 1000).toISOString();
  const read = (path: string): any => {
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch {
      return null;
    }
  };
  const station = read(join(data, "run", "station.json"));
  const running = station && Number.isInteger(station.pid) && station.pid > 0 && alive(station.pid) ? station : null;
  const out = [say("station.cli.status.data", { path: data })];
  out.push(running ? say("station.cli.status.running", { pid: running.pid, version: typeof running.version === "string" ? running.version : "?" }) : say("station.cli.status.notRunning"));
  const join_ = say("station.cli.status.join");
  const state = existsSync(join(data, "mesh", "cloud.json")) ? readState(data) : null;
  if (!state) {
    out.push(say("station.cli.status.noWorkspace"), say("station.cli.status.idleUnjoined", { join: join_ }));
    return out.join("\n");
  }
  out.push(say("station.cli.status.workspace", { name: state.workspace_name, id: state.workspace }));
  out.push(say("station.cli.status.name", { name: state.name, id: state.station.slice(0, 12) }));
  out.push(say("station.cli.status.cloud", { origin: state.origin }));
  if (state.removed_at !== undefined) {
    const how = state.removed_code === 4004 ? say("station.cli.status.removedOnClose")
      : state.removed_code === 404 ? say("station.cli.status.removedOn404")
      : state.removed_code !== undefined ? say("station.cli.status.removedCode", { code: state.removed_code }) : "";
    out.push(say("station.cli.status.removed", { workspace: state.workspace_name, at: when(state.removed_at), how }));
    out.push(say("station.cli.status.idleRemoved", { join: join_ }));
  }
  const presence = running ? read(join(data, "run", "presence.json")) : null;
  if (presence && presence.online === true) out.push(say("station.cli.status.onlineSince", { at: Number.isInteger(presence.at) ? when(presence.at) : "" }));
  else if (presence) out.push(say("station.cli.status.offlineWhy", { why: typeof presence.error === "string" ? presence.error : say("station.cli.status.notConnectedYet") }));
  else if (!running) out.push(say("station.cli.status.offlineNotRunning"));
  else out.push(say("station.cli.status.offline"));
  if (state.removed_at === undefined) out.push(say("station.cli.status.working"));
  return out.join("\n");
}

/// Whether a process is there (signal 0 only asks; one of another user's counts as not, as `kill` failing does).
function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
