// This tab's endpoint on the mesh (host.ts `StationMeshPorts`): iroh's browser build (clients/packages/mesh/wasm),
// which the page's worker loads (`load`) the first time the core reaches a station. On the relays alone, as a browser
// has no UDP, and through Salix as the relay of last resort. The same links over it as Electron's (mesh.ts).
import { HostError } from "@comma/core-kernel";
import { bindWebEndpoint, type WebMesh } from "@comma/mesh/web";
import { Effect } from "effect";
import type { StationMeshPorts } from "../host.ts";
import { meshStationLinks } from "./mesh.ts";

export type { WebMesh } from "@comma/mesh/web";

const failed = (e: unknown) =>
  new HostError(e instanceof Error ? e.message : String(e));

export function webStations(load: () => Promise<WebMesh>): StationMeshPorts {
  return {
    open: ({ secretKey, relays }) =>
      Effect.acquireRelease(
        Effect.tryPromise({
          try: async () => bindWebEndpoint(await load(), { secretKey, relays }),
          catch: failed,
        }),
        (endpoint) => Effect.promise(() => endpoint.close().catch(() => undefined))
      ).pipe(
        Effect.flatMap((endpoint) =>
          Effect.acquireRelease(
            Effect.sync(() => meshStationLinks(endpoint, {}, endpoint.relay)),
            (links) => Effect.sync(() => links.close())
          )
        )
      ),
  };
}
