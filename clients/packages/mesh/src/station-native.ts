// The mesh on the station's native addon (systems/station/native/mesh, `mesh.node`, Node only): the iroh endpoint a
// station serves on, which a client's endpoint shares. The desktop app carries the addon inside its station; the core
// loads it from there. The types below are the part of the addon the mesh uses.
import type {
  BiStream,
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
} from "./link.ts";
import { SalixRelay } from "./salix-relay.ts";

export { SalixRelay, type RelayCarry } from "./salix-relay.ts";

/** Where a peer is, as the addon takes it: its id (hex), its relays, its `ip:port` addresses. */
export interface NativeAddr {
  id: string;
  relays?: string[];
  ips?: string[];
  /** Reachable through Salix as well (an endpoint bound with `salixRelay`). */
  salix?: boolean;
}

export interface NativeStream {
  /** The next chunk as it arrives, or null at the end. */
  read(): Promise<Uint8Array | null>;
  write(bytes: Buffer): Promise<void>;
  finish(): Promise<void>;
  reset(code: number): Promise<void>;
}

export interface NativeConnection {
  remoteId(): string;
  openBi(): Promise<NativeStream>;
  /** The next stream the peer opened, or null once the connection is closed. */
  acceptBi(): Promise<NativeStream | null>;
  close(code: number, reason: string): void;
  /** Why it closed, as text, once it has. */
  closed(): Promise<string>;
  /** How it runs once that is not `last` (an addon from before does not say). */
  nextVia?(last: string | null): Promise<{ via: string | null; closed: boolean }>;
}

export interface NativeEndpoint {
  /** Its id (hex). */
  id(): string;
  /** Where it listens on this machine: `ip:port`, each. */
  sockets(): string[];
  connect(addr: NativeAddr, alpn: Buffer): Promise<NativeConnection>;
  /** The next connection, its handshake done; null once the endpoint is closed. */
  accept(): Promise<NativeConnection | null>;
  /** Packets through Salix (bound with `salixRelay`, by an addon that has it): one that came from `from`, and those to send. */
  relayIncoming?(from: string, data: Buffer): void;
  relayOutgoing?(max: number): Promise<Array<{ to: string; data: Buffer }>>;
  close(): Promise<void>;
}

export interface NativeBindOptions {
  /** The endpoint's 32-byte secret key: its id is the public half. */
  secretKey: Buffer;
  alpns: Buffer[];
  /** The relays to use; none: relays off. */
  relayUrls: string[];
  /** Announced on the LAN and in the DHT, as a station is. */
  discovery?: boolean;
  /** Looks peers up on the LAN and in the DHT without being announced (with relays only). */
  lookup?: boolean;
  /** `ip:port` to listen on; any free port when absent. */
  bindAddr?: string;
  /** Packets through Salix too, as the relay of last resort (`SalixRelay` carries them). */
  salixRelay?: boolean;
}

export interface NativeMesh {
  bind(options: NativeBindOptions): Promise<NativeEndpoint>;
}

const loaded = new Map<string, NativeMesh>();

/** The addon at `path`, loaded once per path. */
export function loadNativeMesh(path: string): NativeMesh {
  const known = loaded.get(path);
  if (known) return known;
  const module = { exports: {} as NativeMesh };
  process.dlopen(module, path);
  loaded.set(path, module.exports);
  return module.exports;
}

export interface NativeEndpointOptions {
  /** The endpoint's 32-byte secret key. */
  secretKey: Uint8Array;
  /** The protocols this endpoint serves (none: it only connects). */
  alpns?: readonly string[] | undefined;
  /** The relays to use (none: direct addresses only). */
  relays?: readonly string[] | undefined;
  /** `ip:port` to listen on (default: any). */
  bindAddr?: string | undefined;
  /** Reaches stations through Salix as well, on the sockets `relay` carries. */
  salixRelay?: boolean | undefined;
}

const buffer = (bytes: Uint8Array) =>
  Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);

/**
 * Binds a client's endpoint on the addon: never announced, and with relays it looks stations up on the LAN and in the
 * DHT by their ids.
 */
export async function bindNativeEndpoint(
  mesh: NativeMesh,
  options: NativeEndpointOptions
): Promise<NativeMeshEndpoint> {
  const relayUrls = [...(options.relays ?? [])];
  const native = await mesh.bind({
    secretKey: buffer(options.secretKey),
    alpns: (options.alpns ?? []).map((alpn) => Buffer.from(alpn)),
    relayUrls,
    discovery: false,
    lookup: relayUrls.length > 0,
    ...(options.bindAddr ? { bindAddr: options.bindAddr } : {}),
    ...(options.salixRelay ? { salixRelay: true } : {}),
  });
  const relay =
    options.salixRelay && SalixRelay.supported(native)
      ? new SalixRelay(native, options.secretKey)
      : null;
  return new NativeMeshEndpoint(native, relay);
}

export class NativeMeshEndpoint implements MeshEndpoint {
  readonly id: string;
  /** Carries its packets through Salix, when it was bound to (and its addon can). */
  readonly relay: SalixRelay | null;
  readonly #native: NativeEndpoint;

  constructor(native: NativeEndpoint, relay: SalixRelay | null = null) {
    this.#native = native;
    this.relay = relay;
    this.id = native.id();
  }

  /** Where it listens on this machine: `ip:port`, each. */
  sockets(): string[] {
    return this.#native.sockets();
  }

  async connect(peer: PeerAddr, alpn: string): Promise<MeshConnection> {
    const addr: NativeAddr = { id: peer.id };
    if (peer.relayUrl) addr.relays = [peer.relayUrl];
    if (peer.addresses && peer.addresses.length > 0) addr.ips = [...peer.addresses];
    // Through Salix as well: its packets are dropped while no socket carries them.
    if (this.relay) addr.salix = true;
    return nativeConnection(await this.#native.connect(addr, Buffer.from(alpn)));
  }

  async accept(): Promise<MeshConnection | null> {
    const next = await this.#native.accept();
    return next === null ? null : nativeConnection(next);
  }

  close(): Promise<void> {
    return this.#native.close();
  }
}

/** A native connection as the mesh's. */
export function nativeConnection(native: NativeConnection): MeshConnection {
  let closed: Promise<CloseInfo> | null = null;
  return {
    remoteId: native.remoteId(),
    openBi: async () => nativeStream(await native.openBi()),
    acceptBi: async () => {
      const next = await native.acceptBi();
      return next === null ? null : nativeStream(next);
    },
    // The addon says why as text; the application code is in it, not apart.
    closed: () =>
      (closed ??= native.closed().then((reason) => ({ code: null, reason }))),
    close: (code, reason) => {
      try {
        native.close(code, reason);
      } catch {
        // Closed already.
      }
    },
    ...(native.nextVia
      ? {
          nextVia: async (last: MeshVia | null) => {
            const next = await native.nextVia!(last);
            return { via: asVia(next.via), closed: next.closed };
          },
        }
      : {}),
  };
}

const asVia = (via: string | null): MeshVia | null =>
  via === "direct" || via === "relay" || via === "salix" ? via : null;

function nativeStream(native: NativeStream): BiStream {
  // What a read gave beyond the reader's `max`, for its next read.
  let carry: Uint8Array | null = null;
  return {
    send: {
      write: (bytes) => native.write(buffer(bytes)),
      finish: () => native.finish(),
      reset: (code) => void native.reset(code).catch(() => undefined),
    },
    recv: {
      read: async (max) => {
        const chunk = carry ?? (await native.read());
        carry = null;
        if (chunk === null) return null;
        if (chunk.length <= max) return chunk;
        carry = chunk.subarray(max);
        return chunk.subarray(0, max);
      },
      // The addon cannot stop a stream's reading half: what the peer still sends is left unread.
      stop: () => {},
    },
  };
}
