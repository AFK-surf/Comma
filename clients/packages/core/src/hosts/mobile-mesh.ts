// This phone's endpoint on the mesh (host.ts `StationMeshPorts`): the iroh the core's engine carries
// (clients/packages/mesh/native, its `mesh.*` operations: native/engine.cpp sends them there, not to the app) as
// @comma/mesh's link surface, and Salix as the relay of last resort on the sockets it opens. What Electron's host has
// from the station's addon (node.ts `nativeStations`), with the same links over it (mesh.ts).
//
// Operations: mesh.bind {relayUrls, salixRelay} + key → {id, endpoint}; mesh.connect {id, addr} + alpn → {id, remote};
// mesh.endpointClose {id}; mesh.openBi / mesh.acceptBi {id} → {id} or {end}; mesh.closed {id} → {reason};
// mesh.close {id, code, reason}; mesh.nextVia {id, last} → {via, closed}; mesh.read {id} → bytes or {end};
// mesh.write {id} + bytes; mesh.finish {id}; mesh.reset {id, code}; mesh.carry {id, url, ticket} → {id};
// mesh.carried {id} once that socket closed; mesh.uncarry {id}.
import type { HostError } from "@comma/core-kernel";
import type {
  BiStream,
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
} from "@comma/mesh";
import { Effect } from "effect";
import type { StationMeshPorts } from "../host.ts";
import { meshStationLinks, type SalixCarrier } from "./mesh.ts";

type Answer = { json: unknown; bytes: Uint8Array | null };

/** The engine's operations, as the mobile host's bridge makes them. */
export interface MeshOps {
  call(
    op: string,
    json: unknown,
    bytes?: Uint8Array | null
  ): Effect.Effect<Answer, HostError>;
}

type J = Record<string, unknown>;
const fields = (answer: Answer): J => (answer.json ?? {}) as J;

const asVia = (via: unknown): MeshVia | null =>
  via === "direct" || via === "relay" || via === "salix" ? via : null;

/** This phone's mesh: bound when Stations first needs it, with the relays the control plane named and Salix. */
export function mobileStations(ops: MeshOps): StationMeshPorts {
  return {
    open: ({ secretKey, relays }) =>
      Effect.acquireRelease(
        Effect.map(
          ops.call(
            "mesh.bind",
            { relayUrls: [...relays], salixRelay: true },
            secretKey
          ),
          (answer) =>
            new BridgedEndpoint(
              ops,
              Number(fields(answer).id),
              String(fields(answer).endpoint)
            )
        ),
        (endpoint) => Effect.promise(() => endpoint.close().catch(() => undefined))
      ).pipe(
        Effect.flatMap((endpoint) =>
          Effect.acquireRelease(
            Effect.sync(() => meshStationLinks(endpoint, {}, endpoint.salix)),
            (links) => Effect.sync(() => links.close())
          )
        )
      ),
  };
}

class BridgedEndpoint implements MeshEndpoint {
  readonly id: string;
  readonly salix: SalixCarrier;
  readonly #ops: MeshOps;
  readonly #handle: number;

  constructor(ops: MeshOps, handle: number, id: string) {
    this.#ops = ops;
    this.#handle = handle;
    this.id = id;
    this.salix = {
      carry: async (url, ticket, signal) => {
        const socket = Number(
          fields(
            await Effect.runPromise(
              ops.call("mesh.carry", { id: handle, url, ticket }),
              {
                signal,
              }
            )
          ).id
        );
        return {
          closed: Effect.runPromise(ops.call("mesh.carried", { id: socket })).then(
            () => undefined,
            () => undefined
          ),
          close: () =>
            void Effect.runFork(
              Effect.ignore(ops.call("mesh.uncarry", { id: socket }))
            ),
        };
      },
    };
  }

  async connect(peer: PeerAddr, alpn: string): Promise<MeshConnection> {
    const answer = await Effect.runPromise(
      this.#ops.call(
        "mesh.connect",
        {
          id: this.#handle,
          addr: {
            id: peer.id,
            relays: peer.relayUrl ? [peer.relayUrl] : [],
            ips: [...(peer.addresses ?? [])],
            // Through Salix as well: its packets are dropped while no socket carries them.
            salix: true,
          },
        },
        new TextEncoder().encode(alpn)
      )
    );
    return bridgedConnection(
      this.#ops,
      Number(fields(answer).id),
      String(fields(answer).remote)
    );
  }

  /** A phone takes no connections: it is never dialed. */
  accept(): Promise<MeshConnection | null> {
    return Promise.resolve(null);
  }

  close(): Promise<void> {
    return Effect.runPromise(
      Effect.asVoid(this.#ops.call("mesh.endpointClose", { id: this.#handle }))
    );
  }
}

function bridgedConnection(
  ops: MeshOps,
  handle: number,
  remoteId: string
): MeshConnection {
  let closed: Promise<CloseInfo> | null = null;
  const stream = (answer: Answer): BiStream | null =>
    fields(answer).end === true ? null : bridgedStream(ops, Number(fields(answer).id));
  return {
    remoteId,
    openBi: async () =>
      stream(await Effect.runPromise(ops.call("mesh.openBi", { id: handle })))!,
    acceptBi: async () =>
      stream(await Effect.runPromise(ops.call("mesh.acceptBi", { id: handle }))),
    // The engine says why as text; the application code is in it, not apart.
    closed: () =>
      (closed ??= Effect.runPromise(ops.call("mesh.closed", { id: handle })).then(
        (answer) => ({ code: null, reason: String(fields(answer).reason ?? "") }),
        () => ({ code: null, reason: "" })
      )),
    close: (code, reason) =>
      void Effect.runFork(
        Effect.ignore(ops.call("mesh.close", { id: handle, code, reason }))
      ),
    nextVia: async (last) => {
      const next = fields(
        await Effect.runPromise(ops.call("mesh.nextVia", { id: handle, last }))
      );
      return { via: asVia(next.via), closed: next.closed === true };
    },
  };
}

function bridgedStream(ops: MeshOps, handle: number): BiStream {
  // What a read gave beyond the reader's `max`, for its next read.
  let carry: Uint8Array | null = null;
  return {
    send: {
      write: (bytes) =>
        Effect.runPromise(Effect.asVoid(ops.call("mesh.write", { id: handle }, bytes))),
      finish: () =>
        Effect.runPromise(Effect.asVoid(ops.call("mesh.finish", { id: handle }))),
      reset: (code) =>
        void Effect.runFork(
          Effect.ignore(ops.call("mesh.reset", { id: handle, code }))
        ),
    },
    recv: {
      read: async (max) => {
        let chunk = carry;
        carry = null;
        if (chunk === null) {
          const answer = await Effect.runPromise(ops.call("mesh.read", { id: handle }));
          if (fields(answer).end === true) return null;
          chunk = answer.bytes ?? new Uint8Array(0);
        }
        if (chunk.length <= max) return chunk;
        carry = chunk.subarray(max);
        return chunk.subarray(0, max);
      },
      // As the station's addon: the reading half is not stopped; what the station still sends is left unread.
      stop: () => {},
    },
  };
}
