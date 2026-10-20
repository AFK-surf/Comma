import { commands } from "vitest/browser";
import type { Entry } from "./fixtures/core-alone/src/main";
import type { WebAppStubOptions } from "./fixtures/web-app/stub";
import { fixtureMount } from "./support/fixture";
import { expect, test, useFixture } from "./support/page";
import { stepUntil, testClock } from "./support/virtual-time";
import { useNodeRealm } from "./support/world";

// The core's side of every record (./records): the contract between the view
// and the core for one scenario of a web app spec. The spec itself plays the
// record to the view alone. Here the client core runs alone, in its worker of
// the shipped build, with the server: it is sent what the record has the view
// send, the test's steps on the server are taken again at their times, and
// every message the core sends must be the record's next one. Both sides hold
// against one record, so the two together can only do what the record says.
type CoreRecord = { seed: number; start: WebAppStubOptions; entries: Entry[] };
const recordedOrigin = "http://comma-stub.test";
const title = (file: string) => `the core says what the record has it say: ${file}`;
const records = new Map<string, CoreRecord>();
for (const file of await commands.worldRecordList())
  records.set(title(file), (await commands.worldRecordRead(file)) as CoreRecord);

const stub = useNodeRealm<{ origin: string; userId: string }>(
  "stub",
  "e2e/app-shell/fixtures/web-app/stub.ts",
  (name: string) => records.get(name)!.start
);
useFixture(
  fixtureMount(new URL("./fixtures/core-alone/src/main.ts", import.meta.url)),
  { world: { servers: () => [stub()] } }
);

for (const [name, record] of records)
  test(name, async ({ page }) => {
    // The record names the server once; this run's server has an origin of its own.
    const entries = JSON.parse(
      JSON.stringify(record.entries).replaceAll(recordedOrigin, stub().origin)
    ) as Entry[];
    const take = async (entry: Entry) => {
      const {
        name: step,
        args,
        result,
      } = entry.data as {
        name: string;
        args: unknown[];
        result?: unknown;
      };
      // The server answers the step as it did: its state is the record's too.
      expect((await stub().call(step.replace(/^stub\./, ""), ...args)) ?? null).toEqual(
        result ?? null
      );
    };
    await commands.cdpSend("Storage.clearDataForOrigin", {
      origin: location.origin,
      storageTypes: "file_systems,indexeddb,local_storage",
    });
    await commands.cdpSend("Network.setCookie", {
      name: "comma_session",
      value: record.start.session.token,
      url: stub().origin,
      httpOnly: true,
      sameSite: "Lax",
    });
    // The steps the test took before its page opened.
    const opening = entries.filter((entry) => entry.before);
    for (const entry of opening) await take(entry);
    const played = entries.slice(opening.length);
    const app = await commands.webAppDocument();
    await page.addInitScript(
      (input) => {
        window.coreAloneInput = input;
      },
      {
        entries: played,
        worker: app.coreWorker,
        name: `comma-core:${stub().origin}`,
        seed: record.seed,
      }
    );
    await page.goto("http://fixture.test/");
    const state = () => page.evaluate(() => window.coreAlone!.state());
    for (const [index, entry] of played.entries()) {
      if (entry.dir !== "step") continue;
      // The test took the step at this time: the core has said by then all
      // the record has before it, and nothing that comes after.
      const wait = entry.at - testClock().elapsed();
      if (wait > 0) await testClock().advance(wait);
      expect(await state()).toEqual({ next: index, faults: [] });
      await take(entry);
      await page.evaluate(
        (step) => window.coreAlone!.step(step),
        (entry.data as { name: string }).name
      );
    }
    await stepUntil(async () => {
      const at = await state();
      return at.next === played.length || at.faults.length > 0;
    });
    expect(await state()).toEqual({ next: played.length, faults: [] });
  });
