// A station in two workspaces, through the links the core uses (hosts/mesh.ts) to a station on the memory mesh: each
// workspace its own connection and credential, so taking one back leaves the other.
import {
  MESH_ALPN,
  MeshError,
  serveMeshConnection,
  type MeshConnection,
} from "@comma/mesh";
import { MemoryMesh } from "@comma/mesh/testing";
import { Effect } from "effect";
import { expect, it } from "vitest";
import { stationLink } from "../src/host.ts";
import { meshStationLinks } from "../src/hosts/mesh.ts";

it("uses a station for A and B together, and B taken back leaves A working", async () => {
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("computer", [MESH_ALPN]);
  const takes = new Set(["cred-a", "cred-b"]);
  const open = new Map<string, MeshConnection>();
  void (async () => {
    for (;;) {
      const connection = await station.accept();
      if (connection === null) return;
      void serveMeshConnection<string>(connection, {
        verify: async (credential) => {
          if (!takes.has(credential)) throw new MeshError("unauthorized", "revoked");
          open.set(credential, connection);
          return { principal: credential };
        },
        handle: async (request) => ({
          status: 200,
          body: new TextEncoder().encode(request.principal),
        }),
      });
    }
  })();
  const links = meshStationLinks(mesh.endpoint("device"));
  const a = stationLink("wsA", "computer");
  const b = stationLink("wsB", "computer");
  links.credential(a, "cred-a");
  links.credential(b, "cred-b");
  const who = (link: string) =>
    Effect.runPromise(
      Effect.scoped(
        links
          .request(link, { method: "GET", path: "/who", headers: [], body: null })
          .pipe(
            Effect.flatMap((response) =>
              response.body.take.pipe(
                Effect.map((bytes) => new TextDecoder().decode(bytes ?? undefined))
              )
            )
          )
      )
    );

  expect(await who(a)).toBe("cred-a");
  expect(await who(b)).toBe("cred-b");
  expect(open.get("cred-a")).not.toBe(open.get("cred-b"));

  // B is taken back: the station ends its connection and takes its credential no more.
  takes.delete("cred-b");
  open.get("cred-b")!.close(3, "credential_revoked");
  await expect(who(b)).rejects.toThrow();
  expect(await who(a)).toBe("cred-a");
  links.close();
});
