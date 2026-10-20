// A mesh endpoint (`@comma/mesh`'s link surface: the station's addon in Electron's utility process, memory in tests) as
// the core's station links (host.ts `StationLinks`). The mesh's client keeps one connection per station and gives each
// the member credential the core last gave for it; its promises become Effects here, and an interrupted request is
// given up on both sides. With a Salix relay (the station's addon's), the core's tickets open its sockets.
import { HostError } from "@comma/core-kernel";
import { MeshClient, type MeshEndpoint, type PeerAddr } from "@comma/mesh";
import { Effect } from "effect";
import type {
  Pull,
  StationLinks,
  StationReach,
  StationRelayTicket,
  StreamResponse,
} from "../host.ts";

/**
 * Carries the endpoint's packets through Salix on a socket at `url`, opened with `ticket` (`@comma/mesh`'s
 * `SalixRelay`); `signal` gives it up before it registered.
 */
export interface SalixCarrier {
  carry(
    url: string,
    ticket: string,
    signal?: AbortSignal
  ): Promise<{ closed: Promise<void>; close(): void }>;
}

const failure = (e: unknown) =>
  e instanceof HostError
    ? e
    : new HostError(
        e instanceof Error
          ? `${(e as { code?: string }).code ? `${(e as { code?: string }).code}: ` : ""}${e.message}`
          : String(e)
      );

/**
 * `endpoint`'s connections as station links. `peers` says where a station may be found when the host knows (an
 * Electron e2e's loopback station); otherwise it is dialed at the home relay and addresses the core last gave for it
 * (`reach`), and the endpoint's discovery and relays find it by its id when there are none.
 */
export function meshStationLinks(
  endpoint: MeshEndpoint,
  peers: Readonly<Record<string, readonly string[]>> = {},
  salix?: SalixCarrier | null
): StationLinks & { close(): void } {
  const credentials = new Map<string, string>();
  const reaches = new Map<string, StationReach>();
  const client = new MeshClient({
    endpoint,
    credential: async (peer) => {
      const credential = credentials.get(peer.id);
      if (credential === undefined)
        throw new HostError("no member credential for this station");
      return credential;
    },
  });
  const addr = (station: string): PeerAddr => {
    const addresses = peers[station];
    if (addresses) return { id: station, addresses };
    const reach = reaches.get(station);
    return {
      id: station,
      ...(reach?.relayUrl ? { relayUrl: reach.relayUrl } : {}),
      ...(reach && reach.addrs.length > 0 ? { addresses: reach.addrs } : {}),
    };
  };
  return {
    id: endpoint.id,
    close: () => client.close(),
    credential: (station, credential) => void credentials.set(station, credential),
    reach: (station, reach) => void reaches.set(station, reach),
    nextVia: (station, last) =>
      Effect.tryPromise({ try: () => client.nextVia(station, last), catch: failure }),
    connect: (station) =>
      Effect.tryPromise({
        try: () => client.connect(addr(station)),
        catch: failure,
      }).pipe(
        Effect.map(({ closed }) => Effect.promise(() => closed.then(() => undefined)))
      ),
    request: (station, request) =>
      Effect.acquireRelease(
        Effect.tryPromise({
          try: (signal) =>
            client.request(
              addr(station),
              {
                method: request.method,
                path: request.path,
                headers: request.headers,
                body: request.body,
              },
              signal
            ),
          catch: failure,
        }),
        (response) => Effect.sync(() => response.cancel())
      ).pipe(
        Effect.map((response): StreamResponse => {
          const chunks = response.body[Symbol.asyncIterator]();
          const body: Pull<Uint8Array> = {
            take: Effect.tryPromise({
              try: () => chunks.next(),
              catch: failure,
            }).pipe(Effect.map((next) => (next.done ? null : next.value))),
          };
          return { status: response.status, headers: response.headers, body };
        })
      ),
    ...(salix
      ? {
          relay: (_workspace: string, { url, ticket }: StationRelayTicket) =>
            Effect.acquireRelease(
              Effect.tryPromise({
                try: (signal) => salix.carry(url, ticket, signal),
                catch: failure,
              }),
              (carried) => Effect.sync(() => carried.close())
            ).pipe(Effect.map((carried) => Effect.promise(() => carried.closed))),
        }
      : {}),
  };
}
