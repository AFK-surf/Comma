// The fake HTTP layer for Admin tests: Admin's fetch wrapper (adminHttp.ts) over a `fetch` the test gives, so requests
// go through the real Effect HTTP client and only the network is fake.
import { Layer } from "effect";
import { FetchHttpClient } from "effect/http";
import { AdminConfig, AdminFetchLive } from "../src/adminHttp";

export type FakeFetch = (input: string, init?: RequestInit) => Promise<Response>;

export function fakeFetchLayer(apiBaseUrl: string, fetch: FakeFetch) {
  return AdminFetchLive.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(AdminConfig, AdminConfig.of({ apiBaseUrl })),
        Layer.succeed(FetchHttpClient.Fetch, ((
          input: RequestInfo | URL,
          init?: RequestInit
        ) => fetch(String(input), init)) as typeof globalThis.fetch)
      )
    )
  );
}

export function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}

/** Lets what is ready run: promise continuations and the runtime's scheduled fibers. */
export async function flush(rounds = 25) {
  for (let round = 0; round < rounds; round += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}
