// The mesh on the station's native addon (systems/station/native/mesh, `mesh.node`, Node only): the iroh endpoint a
// station serves on, which a client's endpoint shares. The desktop app carries the addon inside its station; the core
// loads it from there. The types below are the part of the addon the mesh uses.
import { createPrivateKey, sign } from "node:crypto";
import type { MeshConnection } from "./link.ts";
import {
  NativeMeshEndpoint,
  nativeConnection as linkConnection,
  type NativeConnection as LinkConnection,
  type NativeEndpoint as LinkEndpoint,
  type NativeStream as LinkStream,
  type ToNative,
} from "./native-link.ts";
import { SalixRelay } from "./salix-relay.ts";

export { SalixRelay, type RelayCarry } from "./salix-relay.ts";
export { NativeMeshEndpoint, type NativeAddr } from "./native-link.ts";

/** The addon's, which takes its bytes as Buffers. */
export type NativeStream = LinkStream<Buffer>;
export type NativeConnection = LinkConnection<Buffer>;
export type NativeEndpoint = LinkEndpoint<Buffer>;

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
const toBuffer: ToNative<Buffer> = buffer;

/** An addon's connection as the mesh's (one a station took, or one it dialed). */
export const nativeConnection = (native: NativeConnection): MeshConnection =>
  linkConnection(native, toBuffer);

/** An Ed25519 private key's PKCS #8 form is this, then its 32-byte seed. */
const PKCS8_ED25519 = Buffer.from("302e020100300506032b657004220420", "hex");

/** Signs with the endpoint's key (`secretKey`, its seed), as Salix asks a socket to prove it. */
function signer(secretKey: Uint8Array): (message: Uint8Array) => Uint8Array {
  const key = createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519, secretKey]),
    format: "der",
    type: "pkcs8",
  });
  return (message) => new Uint8Array(sign(null, message, key));
}

/**
 * Binds a client's endpoint on the addon: never announced, and with relays it looks stations up on the LAN and in the
 * DHT by their ids.
 */
export async function bindNativeEndpoint(
  mesh: NativeMesh,
  options: NativeEndpointOptions
): Promise<NativeMeshEndpoint<Buffer, SalixRelay>> {
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
    options.salixRelay && native.relayIncoming && native.relayOutgoing
      ? new SalixRelay(
          {
            id: () => native.id(),
            relayIncoming: (from, data) => native.relayIncoming!(from, toBuffer(data)),
            relayOutgoing: (max) => native.relayOutgoing!(max),
          },
          signer(options.secretKey)
        )
      : null;
  return new NativeMeshEndpoint(native, relay, toBuffer);
}
