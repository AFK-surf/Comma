// The app reset (`app.reset`): the core lets go of the account, its host clears what the core kept on the device, and
// the host is asked for a new core. A host that cannot reset answers unavailable and nothing is cleared.
import { CoreClient } from "@comma/core-kernel/client";
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    onFault: () => undefined,
  });
  return { core, client, host, time: host.time! };
}

describe("the app reset", () => {
  it("lets the account go, clears the device's values and databases, and asks for a new core", async () => {
    const t = setup();
    t.core.observeSession(signedIn());
    await t.core.runner.run(t.core.session.account());
    await Effect.runPromise(t.host.storageSet("kept", new Uint8Array([1])));
    const [database] = [...t.host.dbs.keys()];
    expect(database).toBeDefined();

    const reset = t.client.call("app.reset", {});
    await t.time.pass(0);
    await expect(reset).resolves.toBeNull();

    expect(t.core.session.current()).toBeNull();
    expect(t.host.storage.size).toBe(0);
    expect(t.host.dbs.size).toBe(0);
    expect(t.host.deleted).toEqual([database]);
    expect(t.host.restarts).toBe(1);
  });

  it("answers unavailable on a host that cannot reset, and clears nothing", async () => {
    const host = new FakeHost();
    host.reset = undefined;
    const t = setup(host);
    t.core.observeSession(signedIn());
    await t.core.runner.run(t.core.session.account());
    await Effect.runPromise(t.host.storageSet("kept", new Uint8Array([1])));

    const reset = t.client.call("app.reset", {}).then(
      () => null,
      (error: unknown) => error
    );
    await t.time.pass(0);
    expect(await reset).toMatchObject({ code: "unavailable" });

    expect(t.core.session.current()).not.toBeNull();
    expect(t.host.storage.size).toBe(1);
    expect(t.host.dbs.size).toBe(1);
  });
});
