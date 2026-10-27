// The mesh on an iroh binding that answers as the station's addon does (systems/station/native/mesh, to Node:
// station-native.ts) or as iroh's browser build does (clients/packages/mesh/wasm: web.ts): an endpoint, its connections
// and streams, with promises. Nothing here is Node's or the browser's; how bytes go to the binding is the caller's.
import type {
  BiStream,
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
} from "./link.ts";

/** Where a peer is, as the binding takes it: its id (hex), its relays, its `ip:port` addresses. */
export interface NativeAddr {
  id: string;
  relays?: string[];
  ips?: string[];
  /** Reachable through Salix as well (an endpoint bound with `salixRelay`). */
  salix?: boolean;
}

/** `B`: bytes as the binding takes them (Node's addon: a Buffer; the browser's: a Uint8Array). */
export interface NativeStream<B = Uint8Array> {
  /** The next chunk as it arrives, or null at the end. */
  read(): Promise<Uint8Array | null>;
  write(bytes: B): Promise<void>;
  finish(): Promise<void>;
  reset(code: number): Promise<void>;
}

export interface NativeConnection<B = Uint8Array> {
  remoteId(): string;
  openBi(): Promise<NativeStream<B>>;
  /** The next stream the peer opened, or null once the connection is closed. */
  acceptBi(): Promise<NativeStream<B> | null>;
  close(code: number, reason: string): void;
  /** Why it closed, as text, once it has. */
  closed(): Promise<string>;
  /** How it runs once that is not `last` (an addon from before does not say). */
  nextVia?(last: string | null): Promise<{ via: string | null; closed: boolean }>;
}

export interface NativeEndpoint<B = Uint8Array> {
  /** Its id (hex). */
  id(): string;
  /** Where it listens on this machine: `ip:port`, each. */
  sockets(): string[];
  connect(addr: NativeAddr, alpn: B): Promise<NativeConnection<B>>;
  /** The next connection, its handshake done; null once the endpoint is closed. */
  accept(): Promise<NativeConnection<B> | null>;
  /** Packets through Salix (bound with `salixRelay`, by a binding that has it): one that came from `from`, and those to send. */
  relayIncoming?(from: string, data: B): void;
  relayOutgoing?(max: number): Promise<Array<{ to: string; data: Uint8Array }>>;
  close(): Promise<void>;
}

/** What carries an endpoint's packets through Salix (salix-relay.ts), as the mesh sees it. */
export interface RelayCarrier {
  carry(
    url: string,
    ticket: string,
    signal?: AbortSignal
  ): Promise<{ closed: Promise<void>; close(): void }>;
}

/** Bytes as the binding takes them (Node's addon: a Buffer; the browser's: as they are). */
export type ToNative<B> = (bytes: Uint8Array) => B;

export class NativeMeshEndpoint<
  B = Uint8Array,
  Relay extends RelayCarrier = RelayCarrier,
> implements MeshEndpoint {
  readonly id: string;
  /** Carries its packets through Salix, when it was bound to (and its binding can). */
  readonly relay: Relay | null;
  readonly #native: NativeEndpoint<B>;
  readonly #bytes: ToNative<B>;

  constructor(native: NativeEndpoint<B>, relay: Relay | null, bytes: ToNative<B>) {
    this.#native = native;
    this.relay = relay;
    this.#bytes = bytes;
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
    const native = await this.#native.connect(
      addr,
      this.#bytes(new TextEncoder().encode(alpn))
    );
    return nativeConnection(native, this.#bytes);
  }

  async accept(): Promise<MeshConnection | null> {
    const next = await this.#native.accept();
    return next === null ? null : nativeConnection(next, this.#bytes);
  }

  close(): Promise<void> {
    return this.#native.close();
  }
}

/** A binding's connection as the mesh's. */
export function nativeConnection<B>(
  native: NativeConnection<B>,
  bytes: ToNative<B>
): MeshConnection {
  let closed: Promise<CloseInfo> | null = null;
  return {
    remoteId: native.remoteId(),
    openBi: async () => nativeStream(await native.openBi(), bytes),
    acceptBi: async () => {
      const next = await native.acceptBi();
      return next === null ? null : nativeStream(next, bytes);
    },
    // The binding says why as text; the application code is in it, not apart.
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

function nativeStream<B>(native: NativeStream<B>, bytes: ToNative<B>): BiStream {
  // What a read gave beyond the reader's `max`, for its next read.
  let carry: Uint8Array | null = null;
  return {
    send: {
      write: (chunk) => native.write(bytes(chunk)),
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
      // The binding cannot stop a stream's reading half: what the peer still sends is left unread.
      stop: () => {},
    },
  };
}
