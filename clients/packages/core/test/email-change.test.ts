// Changing the account's email (src/email-change.ts), with the core's own web session lifecycle against a fake server.
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SessionValue } from "../src/contract.ts";
import {
  FakeCommaApi,
  FakeHost,
  inProcessOpener,
  json,
  startTestCore,
} from "../src/testing/index.ts";

const CODE = "/v1/comma/me/email-change/code";
const NEW_CODE = "/v1/comma/me/email-change/new-email-code";
const CHANGE = "/v1/comma/me/email-change";

function setup() {
  const api = new FakeCommaApi();
  const user = { email: "work@cue.test", id: "user-a", name: "A", status: "active" };
  const session = {
    expires_at: 2_000_000_000,
    session_id: "11111111-1111-4111-8111-111111111111",
    user,
  };
  api.on("GET", "/v1/comma/auth/session", () => json(200, session));
  const host = new FakeHost({ sessionSource: "core", api });
  const core = startTestCore(host, { coalesceMs: 0 });
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as T;
  };
  const time = host.time!;
  return {
    api,
    user,
    time,
    shown: watch<SessionValue>({ topic: "session" }),
    async ask<T>(name: string, params: unknown = {}): Promise<T> {
      const answer = client.call(name, params);
      // Its failure is read below, after the time passed.
      answer.catch(() => undefined);
      await time.pass(50);
      return (await answer) as T;
    },
  };
}

describe("changing the account's email", () => {
  it("sends each mailbox's code, and the session then shows the new email", async () => {
    const t = setup();
    await t.time.pass(20);
    expect(t.shown().lifecycle).toMatchObject({
      phase: "signed_in",
      principal: { email: "work@cue.test" },
    });
    t.api.on("POST", CODE, () => json(200, { challenge_id: "current-1" }));
    t.api.on("POST", NEW_CODE, (request) =>
      (request.body as { code?: string }).code === "111111"
        ? json(200, { challenge_id: "new-1" })
        : json(400, { error: "invalid_verification_code" })
    );
    t.api.on("POST", CHANGE, () => {
      t.user.email = "me@personal.test";
      return json(200, { user: t.user });
    });

    expect(await t.ask("emailChange.requestCode")).toEqual({
      challengeId: "current-1",
    });
    expect(
      await t.ask("emailChange.requestNewCode", {
        email: " me@personal.test ",
        challengeId: "current-1",
        code: "111111",
      })
    ).toEqual({ challengeId: "new-1" });
    expect(t.api.seen("POST", NEW_CODE).at(-1)!.body).toEqual({
      email: "me@personal.test",
      challenge_id: "current-1",
      code: "111111",
    });

    expect(
      await t.ask("emailChange.confirm", { challengeId: "new-1", code: "222222" })
    ).toEqual({ email: "me@personal.test" });
    await t.time.pass(20);
    expect(t.shown().lifecycle).toMatchObject({
      phase: "signed_in",
      principal: { email: "me@personal.test", userId: "user-a" },
    });
  });

  it("answers email_taken when another account has the new email", async () => {
    const t = setup();
    await t.time.pass(20);
    t.api.on("POST", NEW_CODE, () => json(409, { error: "email_taken" }));
    await expect(
      t.ask("emailChange.requestNewCode", {
        email: "taken@cue.test",
        challengeId: "current-1",
        code: "111111",
      })
    ).rejects.toMatchObject({ code: "email_taken" });
    expect(t.shown().lifecycle).toMatchObject({
      principal: { email: "work@cue.test" },
    });
  });
});
