import { inject } from "vitest";
import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

// The run's pages have one origin, whatever port its server listens on
// (vite/app-shell-origin.ts): what a page stores, compares and builds from
// its address is the same from run to run.
useFixture(
  fixtureMount(
    new URL("./fixtures/focus-ring/src/main.ts", import.meta.url),
    '<video id="clip" src="assets/clip.mp4"></video>'
  )
);

test("the runner and its pages are documents of one origin, not of the server's port", async ({
  page,
}) => {
  await page.goto("http://fixture.test/");
  const port = String(inject("browserServerPort"));
  const seen = {
    runner: location.origin,
    ...(await page.evaluate(() => ({
      page: location.href,
      media: (document.getElementById("clip") as HTMLVideoElement).src,
    }))),
  };
  expect(seen).toEqual({
    runner: "http://app-shell.localhost",
    page: "http://app-shell.localhost/",
    media: "http://app-shell.localhost/assets/clip.mp4",
  });
  expect(JSON.stringify(seen)).not.toContain(port);
});

test("a request to a host outside the run fails, as a name that does not resolve", async ({
  page,
}) => {
  // As the page loads: a test itself makes no requests.
  await page.addInitScript(() => {
    Reflect.set(
      window,
      "outsideRequest",
      fetch("http://outside.example/").then(
        (response) => `answered ${response.status}`,
        (error: unknown) => `failed: ${String(error)}`
      )
    );
  });
  await page.goto("http://fixture.test/");
  expect(
    await page.evaluate(() => Reflect.get(window, "outsideRequest") as Promise<string>)
  ).toBe("failed: TypeError: Failed to fetch");
});
