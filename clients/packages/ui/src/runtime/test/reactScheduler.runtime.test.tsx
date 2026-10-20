import { expect, it } from "vitest";
import { reactSchedulerScenario } from "./reactScheduler.scenario";

it("React renders only when the test runtime runs it (jsdom)", async () => {
  const first = await reactSchedulerScenario();
  expect(first.log).toContain('0ms 20 real tasks later: text="" pending=true');
  expect(first.log.at(-1)).toMatch(/^300ms advanced 300: text=".*slow 100/);
  for (let run = 0; run < 4; run += 1)
    expect(await reactSchedulerScenario()).toEqual(first);
});
