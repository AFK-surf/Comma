import { describe, expect, it } from "vitest";
import { CommaApi } from "../api";
import { CONNECT_WAIT_MS, beginConnect, challengeOf, finishConnect } from "../connect";
import { CommaStore } from "../store";
import { fakeServer, memoryStore } from "./support";

const origin = "https://comma.test";
const pairing = { pairingId: "raycast_pairing_1", pairingSecret: "secret-1" };

function setup() {
  let now = 1_000_000;
  const server = fakeServer(origin, {
    "POST /v1/comma/auth/raycast/exchange": (seen) => {
      const body = seen.body as { verifier: string; pairing_id: string };
      // The server issues a session only for the verifier whose challenge the pairing carries.
      return body.pairing_id === pairing.pairingId &&
        challengeOf(body.verifier) === asked.challenge
        ? {
            status: 200,
            body: {
              token: "comma_sess_raycast",
              expires_at: 99,
              user: { email: "ada@example.test" },
            },
          }
        : { status: 401 };
    },
  });
  const asked = { challenge: "" };
  const store = new CommaStore(memoryStore(), "production");
  const begin = () =>
    beginConnect({
      store,
      scheme: "comma",
      now: () => now,
      open: (url) => {
        asked.challenge = new URL(url).searchParams.get("challenge") ?? "";
        return Promise.resolve();
      },
    });
  const finish = (context: unknown) =>
    finishConnect(context, {
      store,
      api: new CommaApi(origin, server.fetch),
      now: () => now,
      platform: "macos",
    });
  return { ...server, store, asked, begin, finish, pass: (ms: number) => (now += ms) };
}

describe("connecting to Comma", () => {
  it("asks the desktop app with a challenge and exchanges its pairing for a session of its own", async () => {
    const t = setup();
    await t.begin();
    expect(t.asked.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(await t.finish(pairing)).toEqual({
      token: "comma_sess_raycast",
      email: "ada@example.test",
      expiresAt: 99,
    });
    expect(await t.store.session()).toMatchObject({ email: "ada@example.test" });
    expect(t.seen[0]!.body).toMatchObject({
      pairing_id: "raycast_pairing_1",
      pairing_secret: "secret-1",
      client_platform: "macos",
    });
  });

  it("forgets the Workspace of the session before it when it connects again", async () => {
    const t = setup();
    await t.begin();
    await t.finish(pairing);
    await t.store.setWorkspace({
      id: "wsp_old",
      groupId: "grp_old",
      name: "Old account",
    });
    // Connected again without a disconnect, as after switching account in the desktop app.
    await t.begin();
    await t.finish(pairing);
    expect(await t.store.workspace()).toBeUndefined();
    expect(await t.store.session()).toMatchObject({ token: "comma_sess_raycast" });
  });

  it("drops a pairing link it did not ask for, a second one, and a late one", async () => {
    const t = setup();
    await expect(t.finish(pairing)).rejects.toMatchObject({ reason: "not_started" });
    await expect(t.finish({ pairingId: 1 })).rejects.toMatchObject({
      reason: "malformed",
    });

    await t.begin();
    await t.finish(pairing);
    await expect(t.finish(pairing)).rejects.toMatchObject({ reason: "not_started" });

    await t.begin();
    t.pass(CONNECT_WAIT_MS + 1);
    await expect(t.finish(pairing)).rejects.toMatchObject({ reason: "not_started" });
    expect(t.seen).toHaveLength(1);
  });

  it("keeps no session when the server refuses the pairing", async () => {
    const t = setup();
    await t.begin();
    await expect(
      t.finish({ pairingId: "raycast_pairing_other", pairingSecret: "x" })
    ).rejects.toMatchObject({ reason: "refused" });
    expect(await t.store.session()).toBeUndefined();
    // The refused link spent the wait: the right pairing needs a new start.
    await expect(t.finish(pairing)).rejects.toMatchObject({ reason: "not_started" });
  });
});
