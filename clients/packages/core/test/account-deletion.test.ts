import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SessionValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const CODE = "/v1/comma/me/account-deletion/code";
const DELETE = "/v1/comma/me/account-deletion";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as SessionValue;
  };
  core.observeSession(signedIn());
  return { client, time: host.time!, api: host.api, watch };
}

describe("deleting the account", () => {
  it("sends the mailed code, and the session ends once the server deleted the account", async () => {
    const t = setup();
    const session = t.watch({ topic: "session" });
    t.api.on("POST", CODE, () => json(200, { challenge_id: "chl-1" }));
    t.api.on("POST", DELETE, (request) =>
      (request.body as { code?: string }).code === "123456"
        ? json(200, { deleted: true })
        : json(400, { error: "invalid_verification_code" })
    );

    const asked = t.client.call("accountDeletion.requestCode", {});
    await t.time.pass(100);
    expect(await asked).toEqual({ challengeId: "chl-1" });

    // A wrong code is refused and the session stays.
    const wrong = expect(
      t.client.call("accountDeletion.delete", { challengeId: "chl-1", code: "000000" })
    ).rejects.toMatchObject({ code: "invalid_verification_code" });
    await t.time.pass(100);
    await wrong;
    expect(session().rejected).toBeUndefined();

    const deleted = t.client.call("accountDeletion.delete", {
      challengeId: "chl-1",
      code: "123456",
    });
    await t.time.pass(100);
    expect(await deleted).toBeNull();
    expect(t.api.seen("POST", DELETE).at(-1)!.body).toEqual({
      challenge_id: "chl-1",
      code: "123456",
    });
    expect(session().rejected?.status).toBe(401);
  });

  it("answers subscription_active while a subscription still renews", async () => {
    const t = setup();
    t.api.on("POST", CODE, () => json(409, { error: "subscription_active" }));
    const asked = expect(
      t.client.call("accountDeletion.requestCode", {})
    ).rejects.toMatchObject({
      code: "subscription_active",
    });
    await t.time.pass(100);
    await asked;
  });
});
