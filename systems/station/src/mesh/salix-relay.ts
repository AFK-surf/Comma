// Salix as the relay of last resort, on the station's side: the iroh endpoint (bound with the Salix transport,
// native/mesh/src/salix.rs) hands its packets for Salix here, and the connector's connection to Salix carries them
// (src/connector/connector.ts, `StationRelay`). While no connection carries them, packets for Salix are dropped, as
// any lost path's are: QUIC sends them again, and iroh tries its other paths.
//
// A desktop signed in to several Workspaces has a connection to Salix for each, each in its own Group, and Salix passes
// a packet only to a peer in the Group of the connection it came on. So a peer's packets go on the connection that peer
// was last heard on; until it is heard, on every connection (Salix drops them where the peer is not).
import { sign as edSign } from "node:crypto";
import { Context, Effect, Layer } from "effect";
import type { StationRelay } from "../connector/connector.ts";
import { log } from "../ops/log.ts";
import { Key } from "../services.ts";
import type { Endpoint } from "./native.ts";

const BATCH = 64;
/// Peers whose connection is remembered: the oldest is forgotten beyond this (its packets go on every connection again).
const MAX_ROUTES = 4096;

type Send = (to: string, data: Buffer) => void;

export class SalixRelayHub implements StationRelay {
  readonly endpointId: string;
  readonly #sign: (message: Buffer) => Buffer;
  #endpoint: Endpoint | null = null;
  /// The connections carrying packets, each by the key it attached with.
  readonly #sends = new Map<object, Send>();
  /// The connection each peer was last heard on.
  readonly #heard = new Map<string, object>();

  constructor(endpointId: string, sign: (message: Buffer) => Buffer) {
    this.endpointId = endpointId;
    this.#sign = sign;
  }

  sign(message: Buffer): Buffer {
    return this.#sign(message);
  }

  /// From the connection to Salix `via`.
  incoming(from: string, data: Buffer, via: object): void {
    if (this.#sends.has(via)) {
      this.#heard.delete(from);
      this.#heard.set(from, via);
      if (this.#heard.size > MAX_ROUTES) this.#heard.delete(this.#heard.keys().next().value!);
    }
    this.#endpoint?.relayIncoming?.(from, data);
  }

  /// The connection `via` carries packets with `send`, until it attaches null.
  attach(via: object, send: Send | null): void {
    if (send) {
      this.#sends.set(via, send);
      return;
    }
    this.#sends.delete(via);
    for (const [peer, on] of this.#heard) if (on === via) this.#heard.delete(peer);
  }

  #send(to: string, data: Buffer): void {
    const via = this.#heard.get(to);
    const send = via && this.#sends.get(via);
    if (send) send(to, data);
    else for (const each of this.#sends.values()) each(to, data);
  }

  /// Carries what `endpoint` sends through Salix until it closes.
  async pump(endpoint: Endpoint): Promise<void> {
    if (!endpoint.relayOutgoing) return;
    this.#endpoint = endpoint;
    try {
      for (;;) {
        const packets = await endpoint.relayOutgoing(BATCH);
        if (packets.length === 0) return;
        for (const packet of packets) this.#send(packet.to, packet.data);
      }
    } catch (error) {
      log.info("mesh", "the Salix relay stopped", { error: (error as Error).message });
    } finally {
      if (this.#endpoint === endpoint) this.#endpoint = null;
    }
  }
}

/// The station's hub, signing with its key.
export class SalixRelay extends Context.Service<SalixRelay, SalixRelayHub>()("stillfail/SalixRelay") {
  static readonly layer = Layer.effect(
    SalixRelay,
    Effect.gen(function* () {
      const key = yield* Key;
      return new SalixRelayHub(key.id, (message) => edSign(null, message, key.private));
    }),
  );
}
