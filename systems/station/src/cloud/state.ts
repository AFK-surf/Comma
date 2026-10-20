// Where the station stands with still.fail cloud: <data>/mesh/cloud.json (its fields, mode and pretty JSON as the Rust
// station writes them: the desktop app and `bin/stillfail` read it too). One copy in memory, written through on every
// change and told to whoever listens; the file is watched only for `enroll` writing it from another process.
import { existsSync, readFileSync, watch } from "node:fs";
import { join } from "node:path";
import { writePrivate } from "../ops/files.ts";
import { wall } from "../ops/fibers.ts";
import { type Provider, providerOf } from "./provider.ts";
import type { Reach } from "../mesh/native.ts";

export type Revocation = { kind: string; id: string; at: number };

const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((s): s is string => typeof s === "string" && s !== "") : []);

export type CloudState = {
  /// The control plane it is enrolled in (cloud/provider.ts): absent is still.fail cloud, as files from before say.
  provider?: Provider;
  origin: string;
  station: string;
  /// The id the control plane tells the workspace by now.
  workspace: string;
  /// The ids the control plane says the same workspace was told by before, oldest first (a rename keeps them all);
  /// none from a control plane that renames nothing.
  workspace_was?: string[];
  workspace_name: string;
  name: string;
  relay_url: string;
  /// Every relay, still.fail's (`relay_url`) first; missing from files of before there were several.
  relay_urls: string[];
  grant_keys: any;
  /// The workspace's stations this one may call (peer RPC); none from old clouds.
  peers: any[];
  revocations: Revocation[];
  /// The iroh ids that may call the device tools (Comma's gateways); absent from still.fail cloud.
  gateway_keys?: string[];
  /// When the cloud said the station was removed from its workspace (unix seconds), and how (4004 / 404).
  removed_at?: number;
  removed_code?: number;
};

/// Every id the station's workspace goes or went by, the one told now first: a member credential, a peer's request
/// or a device tool's context that names any of them is for this workspace.
export const workspaceIds = (s: { workspace: string; workspace_was?: string[] }): string[] => [s.workspace, ...(s.workspace_was ?? [])];

/// What the workspace is known by in everything a station keeps and in what stations say to each other (remote jobs,
/// their directories and records, the peer transport): the first id it had, which a rename never changes. The control
/// plane says a rename by telling the new `workspace` with the ids before it in `workspace_was`, so every station of
/// the workspace has the same first id whether the new one reached it yet or not. A `workspace` whose `workspace_was`
/// does not lead back to the id held is another workspace: its first id differs.
export const workspaceKey = (s: { workspace: string; workspace_was?: string[] }): string => s.workspace_was?.[0] ?? s.workspace;

export const meshDir = (data: string) => join(data, "mesh");
const statePath = (data: string) => join(meshDir(data), "cloud.json");

/// The state as the file has it, its optional parts filled as the Rust station's serde defaults fill them.
export function readState(data: string): CloudState | null {
  if (!existsSync(statePath(data))) return null;
  const raw = JSON.parse(readFileSync(statePath(data), "utf8"));
  const state: CloudState = { ...raw, relay_urls: raw.relay_urls ?? [], peers: raw.peers ?? [], revocations: raw.revocations ?? [] };
  if (raw.workspace_was !== undefined) state.workspace_was = strings(raw.workspace_was);
  if (raw.provider !== undefined) state.provider = providerOf(raw.provider);
  return state;
}

/// Pretty JSON, field order as the Rust struct's, the removal only while there is one; the provider, the gateways and
/// the workspace's ids of before only when there are (a still.fail station's file is as it always was).
export function writeState(data: string, s: CloudState) {
  const out: Record<string, unknown> = {
    ...(s.provider !== undefined ? { provider: s.provider } : {}),
    origin: s.origin, station: s.station, workspace: s.workspace,
    ...(s.workspace_was !== undefined && s.workspace_was.length > 0 ? { workspace_was: s.workspace_was } : {}),
    workspace_name: s.workspace_name, name: s.name,
    relay_url: s.relay_url, relay_urls: s.relay_urls, grant_keys: s.grant_keys, peers: s.peers, revocations: s.revocations,
  };
  if (s.gateway_keys !== undefined) out.gateway_keys = s.gateway_keys;
  if (s.removed_at !== undefined) out.removed_at = s.removed_at;
  if (s.removed_code !== undefined) out.removed_code = s.removed_code;
  writePrivate(statePath(data), JSON.stringify(out, null, 2));
}

/// The state in memory, and who wants to hear of its changes.
export class Cloud {
  state: CloudState | null;
  /// Whether `peers` is the cloud's roster as of the current presence socket (fail closed until a `state` frame says so).
  peersCurrent = false;
  /// Runs a device tool request that came over the presence socket (mesh/tools.ts `presenceTools`), while the mesh
  /// is up; null before it.
  toolCalls: ((request: unknown) => Promise<unknown>) | null = null;
  /// Where the mesh endpoint may be reached now (mesh/reach.ts), for the presence socket to tell; null while the mesh
  /// is not up. Kept in memory only.
  reach: Reach | null = null;
  private reachListeners = new Set<() => void>();
  private listeners = new Set<(s: CloudState | null) => void>();
  private writing = false;
  private watcher: { close(): void } | undefined;
  readonly data: string;

  constructor(data: string) {
    this.data = data;
    this.state = readState(data);
    // `enroll` from another process, or an older tool editing the file.
    try {
      this.watcher = watch(meshDir(data), { persistent: false }, (_, name) => {
        if (name === "cloud.json" && !this.writing) this.reload();
      });
    } catch {
      // No mesh directory yet: `enroll` makes it, and the station is started anew after.
    }
  }

  close() {
    this.watcher?.close();
    this.listeners.clear();
  }

  reload() {
    const next = readState(this.data);
    if (JSON.stringify(next) !== JSON.stringify(this.state)) {
      this.state = next;
      this.tell();
    }
  }

  /// Changes the state, writes it, tells the listeners.
  update(change: (s: CloudState) => void) {
    if (!this.state) return;
    change(this.state);
    this.writing = true;
    try {
      writeState(this.data, this.state);
    } finally {
      // Its own write, seen by the file's watch a moment later (the file system's time).
      wall.after(100, () => (this.writing = false));
    }
    this.tell();
  }

  /// The control plane it is enrolled in.
  provider(): Provider {
    return providerOf(this.state?.provider);
  }

  removed(): boolean {
    return this.state?.removed_at !== undefined;
  }

  /// still.fail's relays, ours first, as `relays()` in the Rust station: `relay_urls`, else `relay_url`; what is no URL
  /// left out.
  relays(): string[] {
    const s = this.state;
    if (!s) return [];
    return (s.relay_urls.length > 0 ? s.relay_urls : [s.relay_url]).filter((u) => URL.canParse(u));
  }

  /// The endpoint's reach changed: told to whoever listens (`onReach`) when it differs.
  setReach(reach: Reach | null) {
    if (JSON.stringify(reach) === JSON.stringify(this.reach)) return;
    this.reach = reach;
    for (const f of this.reachListeners) f();
  }

  onReach(f: () => void): () => void {
    this.reachListeners.add(f);
    return () => this.reachListeners.delete(f);
  }

  listen(f: (s: CloudState | null) => void): () => void {
    this.listeners.add(f);
    return () => this.listeners.delete(f);
  }

  private tell() {
    for (const f of this.listeners) f(this.state);
  }
}
