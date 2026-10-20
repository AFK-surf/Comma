import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { COMPUTE_TICK_MS } from "../src/desktop-pages.ts";
import { FakeHost, inProcessOpener, startTestCore } from "../src/testing/index.ts";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const watch = <T>(topic: string) => {
    let value: T | undefined;
    const stop = client.subscribe(
      { topic },
      (next) => (value = next as T),
      () => undefined
    );
    return { value: () => value, stop };
  };
  return { time: host.time!, watch };
}

describe("the Compute page's clock", () => {
  it("ticks every 5 s only while shown", async () => {
    const t = setup();
    const tick = t.watch<{ tick: number }>("computeTick");
    await t.time.pass(100);
    expect(tick.value()).toEqual({ tick: 0 });
    await t.time.pass(2 * COMPUTE_TICK_MS);
    expect(tick.value()).toEqual({ tick: 2 });
    tick.stop();
    await t.time.pass(3 * COMPUTE_TICK_MS);
    const again = t.watch<{ tick: number }>("computeTick");
    await t.time.pass(100);
    expect(again.value()).toEqual({ tick: 2 });
  });
});
