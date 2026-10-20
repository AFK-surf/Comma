// What differs per platform, as Effects. Electron's host (hosts/node.ts) runs in a utility process: its requests go to
// Main, which adds the bearer it alone holds (the `/v1` proxy), its database is node:sqlite. The web's (hosts/web.ts)
// runs in a dedicated worker: its requests carry the session cookie, which JavaScript cannot read, and its database
// is SQLite's WASM build on OPFS. Tests use testing/index.ts's FakeHost. No session credential reaches the core: a
// request names the session it belongs to, and the host refuses it once that session is not the current one; the
// session lifecycle the core runs names the host's credentials by reference only (`BearerVault`). Waiting is not the
// host's: the core sleeps on Effect's Clock.
import {
  HostError,
  type ClientId,
  type CoreMessage,
  type Sql,
  type SqlError,
} from "@comma/core-kernel";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import type { Effect, Scope } from "effect";
import type { DriveEntry, StationVia } from "./contract.ts";
import type {
  AppleGrant,
  AppRelease,
  AppUpdateStatus,
  BearerVault,
  BearerVaultChange,
  ChatPickAnswer,
  ChatPickRequest,
  CredentialRef,
  GoogleGrant,
  ClientKind,
  ClientPlatform,
  MeetingAnswer,
  MeetingEvent,
  MeetingOp,
  MeetingOps,
  SessionAuthorityResume,
} from "./hosts/utility-protocol.ts";

export type {
  AppleGrant,
  AppRelease,
  AppUpdateStatus,
  ClientKind,
  ClientPlatform,
  BearerCredential,
  BearerVault,
  BearerVaultChange,
  ChatPickAnswer,
  ChatPickedItem,
  ChatPickRequest,
  CredentialRef,
  GoogleGrant,
  SessionAuthorityResume,
  MeetingAnswer,
  MeetingCaptureState,
  MeetingEvent,
  MeetingFailure,
  MeetingLocalFile,
  MeetingOp,
  MeetingOps,
  MeetingPreferences,
  MeetingPresenceMeeting,
  MeetingPresenceState,
  MeetingRecording,
} from "./hosts/utility-protocol.ts";

/** The session a request belongs to (no credential in it). */
export interface SessionLease {
  audience: string;
  authorityInstanceId: string;
  generation: number;
  sessionId: string;
}

export interface ApiRequest {
  method: string;
  /** From `/v1`, with its query. */
  path: string;
  headers: [string, string][];
  body: Uint8Array | null;
  /** The session it is made for: refused by the host when that is not the current one. */
  lease: SessionLease;
}

export interface ApiResponse {
  status: number;
  headers: [string, string][];
  body: Uint8Array;
}

/** The next piece of what streams: null once it ended. */
export type Pull<A> = { readonly take: Effect.Effect<A | null, HostError> };

/** A response whose body arrives in chunks (an event stream). */
export interface StreamResponse {
  status: number;
  headers: [string, string][];
  body: Pull<Uint8Array>;
}

export interface LegacyWorkspaceTasks {
  workspace: { id: string; group_id: string; name: string };
  /** The conversations as the server answered them, newest first. */
  conversations: unknown[];
}

/**
 * A request to the session lifecycle's auth endpoints (`/v1/comma/auth/*`, and the guest import): no lease, as it is
 * what makes or ends a session. The Cookie goes with it (`credentials: include`); `expectedSessionId` is the session
 * the lifecycle believes the Cookie names (`none`, `unknown`, or an id), sent in `authHeaders`.
 */
export interface AuthRequest {
  method: "GET" | "POST";
  path: string;
  headers: [string, string][];
  body: Uint8Array | null;
  /** The Cookie transport (the web): the session the Cookie is expected to name. */
  expectedSessionId?: string;
  /**
   * The bearer transport (Electron): which credential the host attaches, by its reference (`BearerVault`). None: the
   * request carries no credential (a sign-in).
   */
  credential?: CredentialRef;
}

/** An auth request's headers as the server must see them: its own, and the Cookie transport's session headers. */
export function authHeaders(request: AuthRequest): [string, string][] {
  return [
    ...request.headers,
    ["x-comma-expected-auth-session-id", request.expectedSessionId ?? "none"],
    ["x-comma-session-lifecycle-version", "1"],
    ["x-comma-session-transport", "cookie"],
  ];
}

/** What a host has not got at all (a browser without Web Locks). */
export class HostUnsupported extends HostError {}

/** A BroadcastChannel: what is posted reaches the other contexts that opened the same name, not this one. */
export interface HintChannel {
  post(message: unknown): void;
  listen(listener: (message: unknown) => void): () => void;
  close(): void;
}

/** What the web session lifecycle coordinates with besides its requests (all of it works in a worker). */
export interface WebSessionPorts {
  /** The Comma API's origin: the session's audience, and the name of its lock, channel and record. */
  readonly apiOrigin: string;
  /** The browser's user agent (the sign-in requests say the platform). */
  readonly userAgent: string;
  /**
   * Waits for the exclusive Web Lock `name` and answers its release. Interrupted, it stops waiting. Fails
   * `HostUnsupported` where there are no Web Locks.
   */
  lock(name: string): Effect.Effect<() => void, HostError>;
  /** The BroadcastChannel `name`. */
  channel(name: string): HintChannel;
  /** SHA-256 of each input's UTF-8 bytes, in order (the guest proof of work). */
  sha256(inputs: readonly string[]): Effect.Effect<Uint8Array[], HostError>;
}

/**
 * What the bearer session lifecycle needs of its host besides `authFetch`: Electron's Main (over the utility process),
 * or the Android app.
 */
export interface BearerSessionPorts {
  /** The Comma API's origin: the only audience whose credentials are used. */
  readonly apiOrigin: string;
  /** The kind of client the sign-in requests name (Electron unless given). */
  readonly clientKind?: ClientKind | undefined;
  /** The operating system the sign-in requests name. */
  readonly clientPlatform: ClientPlatform;
  /**
   * The host shows what the device keeps for the stored credential's account while its session is checked, and when
   * that check cannot reach the server (a phone opened offline): `Session.keep`. Without it, nothing is shown until
   * the server confirmed the session.
   */
  readonly showsKeptAccount?: boolean | undefined;
  /**
   * Where the host's gate is (the last snapshot the core before this one published, and the session its lease is
   * open for, or null): the core continues that authority, so a restart that finds the same session keeps its lease.
   */
  readonly resumed?: SessionAuthorityResume | undefined;
  /** The credential store, read again from its file. */
  readonly vault: Effect.Effect<BearerVault, HostError>;
  /**
   * Changes the credential store. `quarantine` answers whether it is queued; the others the store after the change,
   * or null when it changed under the core (nothing written). Fails when the write's outcome is unknown.
   */
  change(
    change: BearerVaultChange
  ): Effect.Effect<BearerVault | boolean | null, HostError>;
  /**
   * The snapshot the core publishes and the lease it gives with it (null: none). Told before any UI or request acts on
   * it: the host opens or closes its own gate (the `/v1` proxy, its native consumers) on it, in the order told.
   */
  gate(snapshot: SessionLifecycleSnapshot, lease: SessionLease | null): void;
  /**
   * The platform's Google sign-in (Main's OAuth window, Android's account chooser); interrupted, it closes. A host
   * without one (the iPhone) offers no Google sign-in.
   */
  google?(input: {
    clientId: string;
    nonce: string;
  }): Effect.Effect<GoogleGrant, HostError>;
  /** Tells the Google window how the sign-in ended (its success or failure page). */
  googleDone?(grant: string, ok: boolean): Effect.Effect<void>;
  /** The iPhone's Sign in with Apple sheet, for the server's client and nonce; interrupted, it closes. */
  apple?(input: {
    clientId: string;
    nonce: string;
  }): Effect.Effect<AppleGrant, HostError>;
}

/** Whether the person is at this computer (Main reads the system's idle time and its windows and settings). */
export interface Presence {
  /** Seconds since the last keyboard or pointer input. */
  idleSeconds: number;
  /** A Router reply in Home reaches the person now: the main window is open and Router notifications are on. */
  homeRepliesShown: boolean;
}

/** The page a loopback listener shows the browser that came back to it. */
export type LoopbackPage = "received" | "denied" | "invalid";

/** A browser that came back to a loopback listener: the address it asked for, and the page it is shown. */
export interface LoopbackVisit {
  readonly url: string;
  /** Shows `page` (`received` 200, the others 400); done once the page went out. */
  reply(page: LoopbackPage): Effect.Effect<void>;
}

/** A listener on the loopback address, open while its scope is. */
export interface Loopback {
  /** The port it took (the one asked for, or the system's choice for 0). */
  readonly port: number;
  /**
   * The next GET of its path from `localhost:<port>` or `127.0.0.1:<port>`. Anything else (another path, method or
   * host) the listener answers itself, with a not-found page.
   */
  readonly next: Effect.Effect<LoopbackVisit, HostError>;
}

/** A request to a provider outside the Comma API: no credential, no cookie, no redirect followed. */
export interface ProviderRequest {
  url: string;
  method: "POST";
  headers: [string, string][];
  body: Uint8Array;
  /** The most bytes its answer may have: a longer one fails. */
  maxBytes: number;
}

/** The desktop app's own updates (Electron: Main's Velopack feed). The core decides when to use them. */
export interface AppUpdatePorts {
  readonly status: Effect.Effect<AppUpdateStatus, HostError>;
  /** The newest release, or null when this one is current. */
  readonly check: Effect.Effect<AppRelease | null, HostError>;
  /** Downloads `release`: true once it is on disk. */
  download(release: AppRelease): Effect.Effect<boolean, HostError>;
  /** Quits and restarts into a downloaded release: false when the platform could not start it. */
  apply(release: AppRelease): Effect.Effect<boolean, HostError>;
}

/**
 * What the desktop app offers the core besides requests (Electron): Main's (the person's presence, the system browser,
 * bringing the app to the front, the app's updates, the chat file picker) and its own process's (a loopback listener a browser returns to, a provider's
 * request). The web has none.
 */
export interface DesktopPorts {
  /** The app's URL scheme and product name, as a provider names this app. */
  readonly app: { urlScheme: string; productName: string };
  readonly presence: Effect.Effect<Presence, HostError>;
  /** Opens `url` in the system browser. */
  openExternal(url: string): Effect.Effect<void, HostError>;
  /** Brings the app to the front after a browser authorization (its return link). */
  readonly returnToApp: Effect.Effect<void>;
  /**
   * Main's file dialog on a window, for a chat intake the core opened (`ChatPickRequest`). Interrupted, Main registers
   * no more files for it (an open dialog stays until the person closes it).
   */
  pickAttachments(request: ChatPickRequest): Effect.Effect<ChatPickAnswer, HostError>;
  /**
   * Saves `content` into the Downloads folder as `fileName`: the saved file's opaque handle and the name it took, or
   * null when it could not be saved.
   */
  saveDownload(
    fileName: string,
    content: Uint8Array
  ): Effect.Effect<{ downloadRef: string; fileName: string } | null, HostError>;
  /**
   * Listens on `127.0.0.1:<port>` (0: any free port) for GETs of `path`, with the pages of `source`'s sign-in. Fails
   * `authorization_port_in_use` when the port is taken.
   */
  listen(input: {
    port: number;
    path: string;
    source: "subscription" | "byok";
  }): Effect.Effect<Loopback, HostError, Scope.Scope>;
  providerFetch(request: ProviderRequest): Effect.Effect<ApiResponse, HostError>;
  /** SHA-256 of `input`'s UTF-8 bytes. */
  sha256(input: string): Effect.Effect<Uint8Array, HostError>;
  /** The app's own updates (none: this app does not update itself). */
  readonly updates?: AppUpdatePorts;
}

/**
 * Electron's meeting recorder parts in Main: the audio capture and its recorder window, meeting presence, the local
 * file store and Drive. The core decides (meeting-recorder.ts); Main tells it what it sees and does what it says.
 */
export interface MeetingPorts {
  /** A command for Main: its answer, or a failure Main named; fails when Main could not answer at all. */
  command<O extends MeetingOp>(
    op: O,
    input: MeetingOps[O]["input"]
  ): Effect.Effect<MeetingAnswer<O>, HostError>;
  /** What Main saw, from now on (Main tells it again after the core restarts). */
  listen(listener: (event: MeetingEvent) => void): void;
}

export function header(
  response: { headers: [string, string][] },
  name: string
): string | undefined {
  const lower = name.toLowerCase();
  return response.headers.find(([k]) => k.toLowerCase() === lower)?.[1];
}

/** An image's bytes and media type. */
export interface ImageBytes {
  bytes: Uint8Array;
  mediaType: string;
}

/** An image file's bytes, name and media type. */
export interface NamedImageBytes extends ImageBytes {
  name: string;
}

/** A space of this installation's Drive node, as the node keeps it beside what this install decided about it. */
export interface LocalDriveSpace {
  id: string;
  /** This install's own name for the space; empty when it goes by its id. */
  label: string;
  /** Whether the cluster's files for a space this node publishes are written into its folder as they appear. */
  autoAdopt: boolean;
  /** Where a replica materializes the space; empty when this node keeps no local copy of it. */
  checkoutPath: string;
  /** The local directory this node publishes the space from; empty for a replica. */
  sourcePath: string;
  sourcePaused?: boolean | undefined;
  /** Whether this node keeps a durable copy (a replica) of the space. */
  replica: boolean;
  /** Whether this node owns a source that accepts changes. */
  writable: boolean;
}

/** What the core reads of this installation's Drive node (Electron: the synchronicity daemon Main runs). */
export interface LocalDriveState {
  status: "unavailable" | "starting" | "ready" | "error";
  reason?: string | undefined;
  /** The space this install publishes from its local root. */
  defaultSpace: string;
  spaces: LocalDriveSpace[];
  /** This node's origin (`key:…` until a zone names it), and the trusted origins it knows, its own first. */
  origin: string;
  origins: string[];
  /** What this machine calls itself. */
  deviceName: string;
  /** The membership zone naming this node; empty while it is named by its key. */
  domain: string;
  /** The folder this install publishes its default space from. */
  localRoot: string;
  /** Paths kept on this device whatever retention says, as `<space>/<path>`. */
  pins: string[];
}

export interface LocalDriveListInput {
  space: string;
  policy: string;
  limit: number;
  cursor?: string | undefined;
  /** Only the entries under this path. */
  prefix?: string | undefined;
}

export interface LocalDriveListResult {
  entries: DriveEntry[];
  /** Empty at the end of the listing. */
  nextCursor: string;
}

/** One version of a path the cluster holds: who stands behind it, its content, its place in the node's order. */
export interface LocalDriveVersion {
  /** Origins asserting it, by prefix. */
  attestors: string[];
  /** `tombstone` for a deletion. */
  kind: string;
  /** Content root, hex; empty for a tombstone. */
  root: string;
  seq: number;
  size: number;
}

/** What changing the node does, op by op; each fails when the node refuses or is not running. */
export interface LocalDriveOps {
  versions: { input: { space: string; path: string }; result: LocalDriveVersion[] };
  /** At most 1 MiB of a version of a path (`policy`: `newest` or `origin=<id>`), and the object it came from. */
  read: {
    input: {
      space: string;
      path: string;
      policy: string;
      offset: number;
      length: number;
    };
    result: {
      content: Uint8Array;
      contentRoot: string;
      size: number;
      offset: number;
      eof: boolean;
    };
  };
  write: { input: { space: string; path: string; content: Uint8Array }; result: null };
  delete: { input: { space: string; path: string }; result: null };
  /** Takes the version `select` names into this device's folder; `skipped` when the node left the path alone. */
  adopt: {
    input: { space: string; path: string; select: string; automatic?: boolean };
    result: { skipped: boolean };
  };
  /** What taking the cluster's files for a whole space would do (`dryRun`), or did. */
  adoptTree: {
    input: { space: string; dryRun: boolean; replace: boolean };
    result: { adopt: number; current: number; differing: number; skipped: number };
  };
  pin: { input: { space: string; path: string; action: "add" | "rm" }; result: null };
  /** Publishes a local folder as a space. */
  sourceAdd: { input: { space: string; path: string }; result: null };
  sourceRemove: { input: { space: string }; result: null };
  /** Keeps a replica of a space at `checkoutPath`, or none (""). */
  replicaSet: { input: { space: string; checkoutPath: string }; result: null };
  setSpaceSettings: {
    input: { space: string; label?: string; syncEnabled?: boolean };
    result: LocalDriveState;
  };
  restart: { input: Record<string, never>; result: LocalDriveState };
  /** Names the node by the Workspace's zone; it restarts under it. */
  setDomain: { input: { domain: string }; result: LocalDriveState };
  /** The folder the person picked in the system's dialog; null when they dismissed it. */
  pickFolder: { input: Record<string, never>; result: string | null };
  /**
   * Streams a version of a path into the Downloads folder as `fileName`: the saved file's opaque handle and the name
   * it took, or null when it could not be saved.
   */
  saveDownload: {
    input: { space: string; path: string; policy: string; fileName: string };
    result: { downloadRef: string; fileName: string } | null;
  };
  /** Imports a file a window staged with Main (its opaque `ref`) into a space at `path`, streamed from disk. */
  importStaged: { input: { space: string; path: string; ref: string }; result: null };
  /** Main forgets staged files: nothing will import them again. */
  releaseStaged: { input: { refs: string[] }; result: null };
}

export type LocalDriveOp = keyof LocalDriveOps;

/** This installation's Drive node: its state, a space's listing by pages, its changes, and when its files changed. */
export interface LocalDrivePorts {
  readonly state: Effect.Effect<LocalDriveState, HostError>;
  list(input: LocalDriveListInput): Effect.Effect<LocalDriveListResult, HostError>;
  run<O extends LocalDriveOp>(
    op: O,
    input: LocalDriveOps[O]["input"]
  ): Effect.Effect<LocalDriveOps[O]["result"], HostError>;
  /** Told when the node's files changed (a burst of commits tells many times). */
  onChange(listener: () => void): () => void;
}

/** A request to a station over its direct connection: an admin API path (`/sessions`, `/threads/7/entries`). */
export interface StationRequest {
  method: string;
  path: string;
  headers: [string, string][];
  body: Uint8Array | null;
}

/**
 * This device's endpoint on the mesh (`comma/mesh/1`, the `@comma/mesh` package), open while its scope is: one
 * connection per station, opened by the first request or `connect` and again after it went. A station is named by
 * its endpoint id.
 */
/**
 * Whether a station link's failure is the station refusing the member credential it was given (the mesh's
 * `unauthorized`, which a failure's message begins with: hosts/mesh.ts). Read from the message, which is what a
 * recorded host keeps of a failure.
 */
export const stationRefused = (failure: HostError): boolean =>
  failure.message.startsWith("unauthorized: ");

/** Where a station's endpoint may be reached, as the control plane says while it is online. */
export interface StationReach {
  relayUrl: string | null;
  addrs: readonly string[];
}

/** Comma's client relay socket for a workspace's Group: where it is, and the single-use ticket that opens it. */
export interface StationRelayTicket {
  url: string;
  ticket: string;
}

export interface StationLinks {
  /** This device's endpoint id: the device a member credential names. */
  readonly id: string;
  /**
   * The member credential `station` is given from now on: at its next hello, and when it says the one it has
   * expired. The core keeps it fresh before each connection and request, and gives a new one when the station
   * refuses the one it kept (`stationRefused`).
   */
  credential(station: string, credential: string): void;
  /**
   * Where `station` may be found, as the control plane last said (its home relay and direct addresses): hints for its
   * next connection. The station is still known by its key; without hints the endpoint finds it by id.
   */
  reach(station: string, reach: StationReach): void;
  /**
   * Connects to `station` (its hello answered), or finds the connection open. What it succeeds with ends when that
   * connection closes.
   */
  connect(station: string): Effect.Effect<Effect.Effect<void>, HostError>;
  /** One request; its body arrives as it comes, open while the scope is. */
  request(
    station: string,
    request: StationRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope>;
  /**
   * How the open connection to `station` runs once that is not `last`: at once when it differs already, else at its
   * next change; `closed` when none is open or once it went. Null: the endpoint does not say.
   */
  nextVia(
    station: string,
    last: StationVia | null
  ): Effect.Effect<{ via: StationVia | null; closed: boolean } | null, HostError>;
  /**
   * Carries this device's packets to `workspace`'s stations through Salix, the relay of last resort, on the socket
   * `ticket` opens: it succeeds once Salix took this endpoint's id there, with what ends when the socket closes, and
   * the socket closes with the scope. Absent: the endpoint is not reached through Salix.
   */
  relay?(
    workspace: string,
    ticket: StationRelayTicket
  ): Effect.Effect<Effect.Effect<void>, HostError, Scope.Scope>;
}

/** Direct connections to stations (Electron's host: iroh). A host without them reaches no station. */
export interface StationMeshPorts {
  /** Binds this device's endpoint with `secretKey` (32 bytes, kept by the core) and the relays the control plane named. */
  open(input: {
    secretKey: Uint8Array;
    relays: readonly string[];
  }): Effect.Effect<StationLinks, HostError, Scope.Scope>;
  /**
   * The core keeps every station of the signed-in account's workspaces linked, shown or not (stations/always.ts). A
   * host that is plugged in and stays on (the desktop app) says so.
   */
  readonly alwaysLinked?: boolean;
}

/**
 * Files downloaded to the host's own storage, each under a path the core names (`<account>/<file>`, relative to the
 * host's download directory). The bytes go from the network to the file inside the host; the core decides what is
 * read, when, what is kept, and whether it is the file it asked for. Every answer is JSON, so a record can replay it.
 */
export interface DownloadPorts {
  /**
   * Makes `request` (the session's credential added, as `fetch` does). A 200 begins a download to `path` (its `id`);
   * any other status opens none.
   */
  open(
    request: ApiRequest,
    path: string
  ): Effect.Effect<{ id: number; status: number; total: number | null }, HostError>;
  /**
   * Writes what arrives: how much is written so far, or, once the body is whole, the file put in place of what was at
   * its path, with its size and SHA-256 (lower-case hex).
   */
  step(
    id: number
  ): Effect.Effect<{ received: number } | { size: number; sha256: string }, HostError>;
  /** Gives a download up: nothing of it stays. */
  close(id: number): Effect.Effect<void, HostError>;
  /** Removes `path`: a file, or a directory with all under it. */
  remove(path: string): Effect.Effect<void, HostError>;
  /** Removes every top-level directory but `keep` (an account's); everything when it is null. */
  retain(keep: string | null): Effect.Effect<void, HostError>;
}

/**
 * What brings this device's app back to a new install's state (the core's `app.reset`): the core's data, then the
 * host's own part.
 */
export interface ResetPorts {
  /** Deletes every value and every database the core keeps on this device (the core let its databases go first). */
  readonly clear: Effect.Effect<void, HostError>;
  /**
   * The host's own part, after `clear`: its state back to a new install's, and a new core in place of this one
   * (Electron: Main closes its windows and services, deletes what they keep and starts them again as at launch, with
   * a new core process). It does not return to a core whose process ends with it.
   */
  readonly restart: Effect.Effect<void, HostError>;
}

export interface Host {
  /** A request to the Comma API, with the session's credential added by the host. */
  fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError>;
  /** As `fetch`, its body read as it arrives, open while the scope is. */
  fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope>;

  /** Small values kept on this device by key, whoever is signed in. */
  storageGet(key: string): Effect.Effect<Uint8Array | null, HostError>;
  storageSet(key: string, value: Uint8Array): Effect.Effect<void, HostError>;
  storageDelete(key: string): Effect.Effect<void, HostError>;

  /** A signed-in account's database by name, made empty if it is not there. Fails when it cannot be opened. */
  openDb(name: string): Effect.Effect<Sql, HostError | SqlError>;
  /** A database in memory, for an account whose file cannot be opened: kept this run only. */
  readonly memoryDb: Effect.Effect<Sql, HostError | SqlError>;
  /** An account's database gone (it signed out). */
  deleteDb(name: string): Effect.Effect<void, HostError>;

  /**
   * The Tasks a host kept before the core (Electron's `comma.sqlite`), per workspace, for an account: brought over once,
   * when the account's database is new. A host without one has none.
   */
  legacyTasks?(
    audience: string,
    userId: string
  ): Effect.Effect<LegacyWorkspaceTasks[], HostError>;

  /**
   * An image the server gave, drawn again by the platform's own decoder (Electron's Main, the web worker's
   * `createImageBitmap`) into a preview a UI may show: a UI never draws the server's bytes itself. A host without one
   * shows no previews of workspace images.
   */
  renderImagePreview?(input: ImageBytes): Effect.Effect<Uint8Array, HostError>;
  /** A HEIC/HEIF image as JPEG for an upload (macOS). A host without one refuses such files. */
  transcodeImage?(input: NamedImageBytes): Effect.Effect<NamedImageBytes, HostError>;
  /**
   * A request to the session lifecycle's auth endpoints, with the browser's session Cookie (`AuthRequest`). Only the
   * web's host has it: the core runs the session there (`sessionSource: "core"`).
   */
  authFetch?(request: AuthRequest): Effect.Effect<ApiResponse, HostError>;
  /** The web session lifecycle's lock, hint channel and digests (with `authFetch`). */
  readonly webSession?: WebSessionPorts;
  /** The Electron session lifecycle's credential store, gate and Google window (with `authFetch`): Main's. */
  readonly bearerSession?: BearerSessionPorts;
  /** The desktop app's ports (Electron's): none on the web. */
  readonly desktop?: DesktopPorts;
  /** Electron's meeting recorder parts (Main's). A host without them records no meetings. */
  readonly meeting?: MeetingPorts;

  /** This installation's Drive node (drive-catalog.ts). Only Electron's host has one. */
  readonly localDrive?: LocalDrivePorts;

  /** Direct connections to stations (stations/). Only Electron's host has them. */
  readonly stationMesh?: StationMeshPorts;
  /** Files of any size downloaded to the device's storage (downloads.ts). Only the Android app's host has them. */
  readonly downloads?: DownloadPorts;

  /** Bringing the app back to a new install's state (`app.reset`). Only Electron's host has it. */
  readonly reset?: ResetPorts | undefined;

  randomBytes(buf: Uint8Array): void;

  /**
   * Resumes after the host's next turn (the event loop ran what else was waiting: a UI's messages, a host answer).
   * Long work yields with it, and work that gathers what one moment asks waits one. It is a host answer, so a recorded
   * run notes where each turn came between its inputs.
   */
  readonly yieldTurn: Effect.Effect<void>;

  /** Delivers a message to one connected UI. */
  emit(client: ClientId, message: CoreMessage): void;

  /**
   * Where the session comes from: `core`, the core runs the session lifecycle itself, with `authFetch` and the host's
   * ports: the web's (session/web-lifecycle.ts, `webSession`) or Electron's (session/electron-lifecycle.ts,
   * `bearerSession`); `host`, a test tells the core each change (`Core.observeSession`).
   */
  readonly sessionSource: "host" | "core";
}
