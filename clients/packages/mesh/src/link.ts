// What the mesh needs of a QUIC endpoint: connections to a peer by its id, and bidirectional streams on them. The
// station's native addon (station-native.ts) is one; testing's in-memory pair (memory.ts) is another. Nothing here knows
// the wire format.

/** Where a peer is: its endpoint id (an Ed25519 public key, as iroh writes it), and how to reach it if known. */
export interface PeerAddr {
  id: string;
  /** The relay the peer is homed on. */
  relayUrl?: string | undefined;
  /** Addresses (`ip:port`) the peer may be reached at directly. */
  addresses?: readonly string[] | undefined;
}

export interface SendHalf {
  /** Resolves once the bytes are queued; fails when the peer stopped reading or the connection is gone. */
  write(bytes: Uint8Array): Promise<void>;
  /** No more bytes: the peer reads the end. */
  finish(): Promise<void>;
  /** Abandons the stream: the peer's read fails with `code`. */
  reset(code: number): void;
}

export interface RecvHalf {
  /** Up to `max` bytes as they arrive, or null at the end. Fails when the stream was reset or the connection went. */
  read(max: number): Promise<Uint8Array | null>;
  /** Stops reading: the peer's writes fail with `code`. */
  stop(code: number): void;
}

export interface BiStream {
  send: SendHalf;
  recv: RecvHalf;
}

/** How a connection runs: straight to the peer, through an iroh relay, or through Salix (the relay of last resort). */
export type MeshVia = "direct" | "relay" | "salix";

/** How a connection runs after a change: `via` null while no way is chosen; `closed` once it is gone. */
export interface ViaChange {
  via: MeshVia | null;
  closed: boolean;
}

export interface MeshConnection {
  /** The peer's endpoint id: authenticated by the QUIC handshake (the peer holds its key). */
  readonly remoteId: string;
  /** How it runs once that is not `last`: at once when it differs already, else when it next changes. Absent: it does not say. */
  nextVia?(last: MeshVia | null): Promise<ViaChange>;
  openBi(): Promise<BiStream>;
  /** The next stream the peer opened, or null once the connection is closed. */
  acceptBi(): Promise<BiStream | null>;
  /** Resolves with the reason when the connection closes, from either side. */
  closed(): Promise<CloseInfo>;
  close(code: number, reason: string): void;
}

/** Why a connection closed: the application code and reason the closing side gave, or a transport loss (code null). */
export interface CloseInfo {
  code: number | null;
  reason: string;
}

export interface MeshEndpoint {
  /** This endpoint's id. */
  readonly id: string;
  /** Connects to `peer` speaking `alpn`. */
  connect(peer: PeerAddr, alpn: string): Promise<MeshConnection>;
  /** The next incoming connection for one of the endpoint's ALPNs, or null once the endpoint is closed. */
  accept(): Promise<MeshConnection | null>;
  close(): Promise<void>;
}
