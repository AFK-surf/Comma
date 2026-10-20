// What the page tells the client core about itself: coming back (focus, online, back from the back/forward cache)
// makes the core check the session; a guest import the old session adapter noted is handed to the core once.
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { waitFor } from "@comma/test-utils/render";
import { afterEach, describe, expect, it } from "vitest";
import { wirePageToCore } from "../src/connect-core";

const marker = "comma.guestImportPending.v1:https://api.example";

function page(answer: (name: string) => unknown = () => true) {
  const calls: [string, unknown][] = [];
  const scripted = createScriptedCore({
    calls(name, params) {
      calls.push([name, params]);
      return answer(name);
    },
  });
  const unwire = wirePageToCore(scripted.client, "https://api.example/");
  /** Resolves once the core answered everything asked before it. */
  const settled = () => scripted.client.call("settled");
  return { calls, unwire, settled };
}

function pageshow(persisted: boolean) {
  return Object.assign(new Event("pageshow"), { persisted });
}

describe("the page and its core", () => {
  afterEach(() => localStorage.clear());

  it("asks the core to check the session each time the page comes back", async () => {
    const { calls, unwire, settled } = page();
    window.dispatchEvent(new Event("focus"));
    window.dispatchEvent(new Event("online"));
    // A page loaded anew: the core checks as it starts.
    window.dispatchEvent(pageshow(false));
    window.dispatchEvent(pageshow(true));
    await waitFor(() =>
      expect(calls).toEqual([
        ["session.reconcile", { reason: "focus" }],
        ["session.reconcile", { reason: "focus" }],
        ["session.reconcile", { reason: "focus" }],
      ])
    );
    unwire();
    window.dispatchEvent(new Event("focus"));
    await settled();
    expect(calls).toHaveLength(4);
  });

  it("hands the old adapter's guest import to the core once, then forgets it", async () => {
    localStorage.setItem(
      marker,
      JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
    );
    const first = page();
    await waitFor(() => expect(localStorage.getItem(marker)).toBeNull());
    expect(first.calls).toEqual([
      ["session.guest.handOverImport", { expiresAtEpochSeconds: 2_000_000_000 }],
    ]);
    first.unwire();
    const second = page();
    await second.settled();
    expect(second.calls).toEqual([["settled", {}]]);
    second.unwire();
  });

  it("keeps the guest import for the next page when the core could not take it", async () => {
    localStorage.setItem(
      marker,
      JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
    );
    const { calls, unwire, settled } = page((name) => {
      if (name === "session.guest.handOverImport")
        throw new Error("The core started again.");
      return null;
    });
    await settled();
    expect(calls[0]?.[0]).toBe("session.guest.handOverImport");
    expect(localStorage.getItem(marker)).not.toBeNull();
    unwire();
  });

  it("drops a marker that names no claim, without a call", async () => {
    localStorage.setItem(marker, "{not json");
    const { calls, unwire, settled } = page();
    expect(localStorage.getItem(marker)).toBeNull();
    await settled();
    expect(calls).toEqual([["settled", {}]]);
    unwire();
  });
});
