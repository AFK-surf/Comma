import { afterEach, expect, it } from "vitest";
import { createRealm } from "../../../../../e2e/ui-runtime/realm";
import { createTestUiRuntime } from "../../../../ui/src/runtime/test/testing";

// A realm's messages from one peer come on several lines (a frame's window
// and each port the page sent it). Each line delivers in the order it was
// sent; two lines may arrive in either order. The world hands a message over
// by its place on its own line, so what the realm runs does not depend on
// which line the machine delivered first.

let uninstall: (() => void) | undefined;
afterEach(() => {
  uninstall?.();
  uninstall = undefined;
});

/** A line's receiving end in memory: the test decides when each message arrives. */
function line() {
  let arrive: ((event: Event) => void) | undefined;
  const endpoint = {
    addEventListener(_type: string, listener: (event: Event) => void) {
      arrive = listener;
    },
    postMessage() {},
    onmessage: null,
  };
  return {
    endpoint,
    arrive: (data: string) => arrive!(new MessageEvent("message", { data })),
  };
}

function realmWithTwoLines() {
  const runtime = createTestUiRuntime({ seed: 1 });
  uninstall = runtime.install();
  const realm = createRealm(runtime, {
    advance: (ms) => runtime.advance(ms),
    rest: () => runtime.flush(),
  });
  const ran: string[] = [];
  const window = line();
  const port = line();
  for (const [current, options] of [
    [window, {}],
    [port, { line: "port 1" }],
  ] as const) {
    realm.route(
      "page",
      current.endpoint as unknown as Parameters<typeof realm.route>[1],
      () => {},
      options
    );
    current.endpoint.addEventListener("message", (event) =>
      ran.push((event as MessageEvent).data as string)
    );
  }
  return { realm, ran, window, port };
}

it("runs a line's message by its place on that line, whichever line arrived first", async () => {
  const { realm, ran, window, port } = realmWithTwoLines();
  // The page sent "init" on its window, then "theme" on the port; the port's
  // message arrives first.
  port.arrive("theme");
  window.arrive("init");
  await realm.control.deliver("page", 1);
  await realm.control.deliver("page", 1, { line: "port 1" });
  await realm.control.settle(0);
  expect(ran).toEqual(["init", "theme"]);
});

it("waits for a message the world hands over before its line delivered it", async () => {
  const { realm, ran, window, port } = realmWithTwoLines();
  port.arrive("theme");
  let handed = false;
  const delivered = realm.control.deliver("page", 1).then(() => {
    handed = true;
  });
  await Promise.resolve();
  // The port's message is no stand-in for the window's first.
  expect(handed).toBe(false);
  window.arrive("init");
  await delivered;
  await realm.control.deliver("page", 1, { line: "port 1" });
  await realm.control.settle(0);
  expect(ran).toEqual(["init", "theme"]);
});
