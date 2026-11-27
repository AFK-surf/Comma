import { describe, expect, it } from "vitest";
import { RaycastConnector, type RaycastConnectDeps } from "../raycast-connect";

const challenge = "c".repeat(43);

function setup(over: Partial<RaycastConnectDeps> = {}) {
  const opened: string[] = [];
  const paired: string[] = [];
  const failures: unknown[] = [];
  const signedOut: number[] = [];
  const deps: RaycastConnectDeps = {
    account: () => "ada@example.test",
    confirm: () => Promise.resolve(true),
    pair: (asked) => {
      paired.push(asked);
      return Promise.resolve({
        pairingId: "raycast_pairing_1",
        pairingSecret: "secret/1",
        expiresAt: 120,
      });
    },
    open: (url) => {
      opened.push(url);
      return Promise.resolve();
    },
    failed: (error) => {
      failures.push(error);
    },
    signedOut: () => {
      signedOut.push(1);
    },
    ...over,
  };
  return {
    connector: new RaycastConnector(deps),
    opened,
    paired,
    failures,
    signedOut,
  };
}

describe("connecting Raycast", () => {
  it("hands the extension a pairing for its challenge once the person confirms", async () => {
    const t = setup();
    expect(await t.connector.connect(challenge)).toBe("connected");
    expect(t.signedOut).toEqual([]);
    expect(t.paired).toEqual([challenge]);
    expect(t.opened).toHaveLength(1);
    const link = new URL(t.opened[0]!);
    expect(`${link.protocol}//${link.host}${link.pathname}`).toBe(
      "raycast://extensions/afk-inc/comma/connect"
    );
    expect(JSON.parse(link.searchParams.get("context")!)).toEqual({
      pairingId: "raycast_pairing_1",
      pairingSecret: "secret/1",
    });
  });

  it("asks for no pairing when the person declines, is a guest, or the account changed meanwhile", async () => {
    const declined = setup({ confirm: () => Promise.resolve(false) });
    expect(await declined.connector.connect(challenge)).toBe("declined");
    const guest = setup({ account: () => undefined });
    expect(await guest.connector.connect(challenge)).toBe("signed_out");
    let account = "ada@example.test";
    const switched = setup({
      account: () => account,
      confirm: () => {
        account = "grace@example.test";
        return Promise.resolve(true);
      },
    });
    expect(await switched.connector.connect(challenge)).toBe("signed_out");
    for (const t of [declined, guest, switched]) {
      expect(t.paired).toEqual([]);
      expect(t.opened).toEqual([]);
    }
    // Only a missing or changed account tells the person to sign in; declining says nothing more.
    expect(declined.signedOut).toEqual([]);
    expect(guest.signedOut).toHaveLength(1);
    expect(switched.signedOut).toHaveLength(1);
  });

  it("asks once while the person decides, and says when the pairing failed", async () => {
    const decision = Promise.withResolvers<boolean>();
    const t = setup({
      confirm: () => decision.promise,
      pair: () => Promise.reject(new Error("offline")),
    });
    const first = t.connector.connect(challenge);
    expect(await t.connector.connect(challenge)).toBe("busy");
    decision.resolve(true);
    expect(await first).toBe("failed");
    expect(t.failures).toEqual([new Error("offline")]);
    expect(t.opened).toEqual([]);
  });
});
