// The mesh on iroh's browser build (clients/packages/mesh/wasm, `@comma/mesh/web`): an endpoint on the relays alone (a
// browser has no UDP), and Salix as the relay of last resort on the page's WebSocket. It answers as the station's addon
// does (native-link.ts), and signs with the endpoint's key itself (Salix's proof). The page loads the module; the core
// binds it when it first reaches a station.
import { NativeMeshEndpoint, type NativeEndpoint } from "./native-link.ts";
import { SalixRelay } from "./salix-relay.ts";

/** An endpoint of the browser build: the addon's surface, and its key's signature. */
export interface WebNativeEndpoint extends NativeEndpoint {
  sign(message: Uint8Array): Uint8Array;
  relayIncoming(from: string, data: Uint8Array): void;
  relayOutgoing(max: number): Promise<Array<{ to: string; data: Uint8Array }>>;
}

/** The browser build's module, its WebAssembly loaded. */
export interface WebMesh {
  bind(options: {
    secretKey: Uint8Array;
    relayUrls: string[];
    salixRelay: boolean;
  }): Promise<WebNativeEndpoint>;
}

/** Binds this tab's endpoint with `secretKey` on `relays`, through Salix as well. */
export async function bindWebEndpoint(
  mesh: WebMesh,
  options: { secretKey: Uint8Array; relays: readonly string[] }
): Promise<NativeMeshEndpoint<Uint8Array, SalixRelay>> {
  const native = await mesh.bind({
    secretKey: options.secretKey,
    relayUrls: [...options.relays],
    salixRelay: true,
  });
  const relay = new SalixRelay(native, (message) => native.sign(message));
  return new NativeMeshEndpoint(native, relay, (bytes) => bytes);
}
