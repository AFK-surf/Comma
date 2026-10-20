// The native mesh addon (native/mesh, docs/station-ts-native.md §3): what it offers (iroh, and the image codecs of the
// thumbnails), and where it is. A release has it beside the station's code (mesh.node); a checkout has it where cargo
// built it; STILLFAIL_MESH_NATIVE says otherwise.
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

/// `salix`: reachable through Salix as well, the relay of last resort (native/mesh/src/salix.rs).
export type Addr = { id: string; relays?: string[]; ips?: string[]; salix?: boolean };
/// Where an endpoint may be reached now: its home relay, if it has one, and its direct addresses (`ip:port`, sorted).
export type Reach = { homeRelay: string | null; addrs: string[] };
export type Stream = {
  read(): Promise<Buffer | null>;
  write(bytes: Buffer): Promise<void>;
  finish(): Promise<void>;
  stopped(): Promise<void>;
  reset(code: number): Promise<void>;
};
export type Connection = {
  remoteId(): string;
  alpn(): Buffer;
  /// "direct", "relay" or "salix", or null while no way is chosen.
  via(): string | null;
  /// How it runs once that is not `last`: at once when it differs already, else at its next change (the client core reads it).
  nextVia?(last: string | null): Promise<{ via: string | null; closed: boolean }>;
  acceptBi(): Promise<Stream | null>;
  openBi(): Promise<Stream>;
  close(code: number, reason: string): void;
  isClosed(): boolean;
  closed(): Promise<string>;
};
export type Endpoint = {
  id(): string;
  sockets(): string[];
  online(): Promise<void>;
  home(): string | null;
  /// Where it may be reached, once that is not `last`: at once when it differs already, else at its next change; null
  /// once the endpoint is closed.
  reach(last: Reach | null): Promise<Reach | null>;
  insertRelay(url: string): Promise<void>;
  removeRelay(url: string): Promise<void>;
  publicRelays(on: boolean): Promise<void>;
  keep(urls: string[]): void;
  accept(): Promise<Connection | null>;
  connect(addr: Addr, alpn: Buffer): Promise<Connection>;
  /// Packets through Salix (an endpoint bound with `salixRelay`): one that came from `from`, and those to send.
  relayIncoming?(from: string, data: Buffer): void;
  relayOutgoing?(max: number): Promise<Array<{ to: string; data: Buffer }>>;
  close(): Promise<void>;
};
export type Mesh = {
  bind(options: { secretKey: Buffer; alpns: Buffer[]; relayUrls: string[]; discovery?: boolean; bindAddr?: string; salixRelay?: boolean }): Promise<Endpoint>;
  /// thumbs.rs `thumbnail` (native/mesh/src/thumbs.rs): the image's thumbnail in `dir`, made if not there yet; null when
  /// the image is shown itself.
  thumbnail(image: string, dir: string): Promise<{ path: string; type: string } | null>;
  /// thumbs.rs `keep` for one image: its ThumbHash (base64) and its size as seen; with `dir`, its thumbnail made after
  /// (not waited for) when it is over 24 KiB. Null when it is not readable as an image.
  thumbhash(image: string, dir?: string | null): Promise<{ hash: string; width: number; height: number } | null>;
  /// archive.rs `file_lock` (native/mesh/src/local.rs): an exclusive flock on the file, across processes.
  fileLock(path: string): Promise<{ release(): void }>;
  /// local_links.rs `prepare`: the text with local links made attachments, and the attachments' paths; throws its refusal.
  prepareLocalLinks(text: string, paths: string[], workspace: string): { text: string; paths: string[] };
  /// nofollow.rs: `name` opened inside the directory `dirFd` without following a final symlink (the connector's read_ref).
  openatNofollow(dirFd: number, name: string, directory: boolean): number;
  /// nofollow.rs: an absolute directory opened one component at a time, never following a symlink.
  openDirectoryNofollow(path: string): number;
  // Profiles as Comma and the stations both use them (systems/profiles, native/mesh/src/profiles.rs): JSON in and out.
  profileSources(): string;
  profileRank(profiles: string, request: string): string[];
  profileState(profile: string, signals: string, model: string | null | undefined, now: number): string;
  profileRuntimeConfig(profile: string, runtime: string, key: string): string;
  profileRuntimes(profile: string): string[];
  profileCodexOverrides(profile: string): string;
  profileEndpoints(source: string, endpoint: string | null | undefined, protocol: string | null | undefined): string | null;
  cleanEndpoint(endpoint: string): string | null;
  modelKey(spelled: string): string;
  profileQuota(provider: string, body: string, now: number): string;
  profileWindowLabel(minutes: number | null | undefined, fallback: string): string;
};

/// config.json `mesh.port`: the UDP port of the station's IPv4 QUIC socket, kept across restarts so that a firewall
/// rule can name it. Unset: any free port, a new one at each start (the IPv6 socket always takes any free port). Throws
/// what is wrong with it: a port that was named is never swapped for another.
export function meshPort(raw: unknown): number | undefined {
  const mesh = (raw as { mesh?: unknown } | null)?.mesh;
  if (mesh === undefined || mesh === null) return undefined;
  if (typeof mesh !== "object" || Array.isArray(mesh)) throw new Error("mesh: an object, as {\"port\": 4770}");
  for (const k of Object.keys(mesh)) if (k !== "port") throw new Error(`unknown field \`mesh.${k}\`, expected \`port\``);
  const port = (mesh as { port?: unknown }).port;
  if (port === undefined || port === null) return undefined;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error("mesh.port: a UDP port, from 1 to 65535");
  return port;
}

/// Loaded once: the mesh (services.ts) and the thumbnails (sessions/thumbs.ts) share it.
let loaded: Mesh | undefined;

export function loadMesh(): Mesh {
  if (loaded !== undefined) return loaded;
  const candidates = [
    process.env.STILLFAIL_MESH_NATIVE,
    fileURLToPath(new URL("./mesh.node", import.meta.url)),
    fileURLToPath(new URL("../../native/mesh/target/release/libstillfail_mesh.dylib", import.meta.url)),
    fileURLToPath(new URL("../../native/mesh/target/release/libstillfail_mesh.so", import.meta.url)),
  ];
  const path = candidates.find((p) => p && existsSync(p));
  if (!path) throw new Error(`the mesh addon is not there (looked at ${candidates.filter(Boolean).join(", ")})`);
  const module = { exports: {} as Mesh };
  process.dlopen(module, path);
  loaded = module.exports;
  return loaded;
}
