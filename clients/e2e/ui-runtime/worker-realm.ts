// Runs first in each worker of the test build, after its seed
// (../app-shell/support/worker-seed.ts). A worker whose page is a realm of a
// world (../app-shell/support/world.ts) is a realm too: its URL names it, and
// the world reaches it on its own port, beside the messages it exchanges with
// the page.
import { testEpoch } from "@comma/test-utils/test-epoch";
import {
  createTestUiRuntime,
  installTestUiHost,
  realHost,
} from "../../packages/ui/src/runtime/test/testing";
import { workerSeedParameter } from "../app-shell/support/random";
import { createRealm, type HttpRoute, type WorldReply } from "./realm";
import { routeRequests } from "./realm-http";
import { routePlatform } from "./realm-platform";
import { wholly } from "../app-shell/support/requests";
import {
  workerPeerParameter,
  workerRealmParameter,
  workerRoutesParameter,
} from "./realm-names";

// A module the worker imports on demand (clients/vitest.config.ts,
// `trackDynamicImports`): leaf IO of a realm, nothing to any other worker.
const imports = globalThis as {
  commaTrackImport?: <T>(loading: Promise<T>) => Promise<T>;
};
imports.commaTrackImport = (loading) => loading;

const parameters = new URLSearchParams(self.location.hash.slice(1));
if (parameters.has(workerRealmParameter)) {
  // Before the worker's own modules load: they keep the host functions they find.
  installTestUiHost();
  const runtime = createTestUiRuntime({
    seed: Number(parameters.get(workerSeedParameter) ?? 0),
    start: testEpoch,
  });
  runtime.install();
  const realm = createRealm(runtime, {
    advance: (ms) => runtime.advance(ms),
    rest: () => runtime.flush(),
  });
  // The worker's requests to a realm of the world are messages of the world;
  // any other request is the runtime's to refuse.
  const requests = routeRequests(realm, {
    name: parameters.get(workerRealmParameter)!,
    hostFetch: realHost().fetch!,
  });
  for (const route of JSON.parse(
    parameters.get(workerRoutesParameter) ?? "[]"
  ) as HttpRoute[])
    requests.add(route);
  // A file of its own build (a WebAssembly module) is leaf IO: it reaches
  // the worker whole, in the order the requests started.
  const hostFetch = realHost().fetch!;
  self.fetch = (input, init) =>
    requests.fetch(input, init) ??
    runtime.load.work(
      `fetch ${input instanceof Request ? input.url : String(input)}`,
      () => hostFetch(input, init).then(wholly)
    );
  imports.commaTrackImport = (loading) => runtime.load.work("import", () => loading);
  const outside: string[] = [];
  routePlatform(runtime, (what) => outside.push(what));
  const post = realm.route(
    parameters.get(workerPeerParameter) ?? "page",
    self as unknown as Parameters<typeof realm.route>[1],
    (message) => {
      if (!("call" in message)) return;
      const answer = (reply: Omit<WorldReply, "reply">) =>
        post({ commaWorld: { reply: message.call, ...reply } });
      let done: Promise<Omit<WorldReply, "reply">>;
      if (message.op === "settle")
        done = realm.control.settle(message.now).then((report) => {
          const problems = [...outside.splice(0), ...runtime.violations()];
          if (problems.length > 0)
            throw new Error(
              `did what its runtime does not control:\n${problems.join("\n")}`
            );
          return { report };
        });
      else if (message.op === "deliver")
        done = realm.control
          .deliver(message.from, message.id, message.detail)
          .then(() => ({}));
      else {
        requests.add(message.route);
        done = Promise.resolve({});
      }
      done.then(answer, (error: unknown) => answer({ error: String(error) }));
    }
  );
  post({ commaWorld: { ready: true } });
}
