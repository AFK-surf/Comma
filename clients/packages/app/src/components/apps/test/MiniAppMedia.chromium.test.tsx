import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { MiniAppScreenshots } from "../MiniAppScreenshots";
import { MiniAppCard } from "@comma/ui/components/mini-apps";
import { afterEach, expect, it } from "vitest";
import { page } from "vitest/browser";
import cover from "./fixtures/mini-app-cover.png?inline";

afterEach(cleanup);

it("decodes real Version artwork in the gallery and static chat card", async () => {
  const read: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "miniAppImage" ? { status: "ready", src: cover } : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "miniAppImage") read.push(topic);
    },
  });
  const url = "/v1/comma/apps/a1/screenshots/0?v=2";
  render(
    core.wrap(
      <div
        data-testid="mini-app-media"
        className="max-w-(--container-sm) bg-primary p-lg"
      >
        <MiniAppScreenshots urls={[url]} via={{ workspace: "wsp" }} name="Notes" />
        <MiniAppCard
          name="Notes"
          version={2}
          summary="Your notes, in one place."
          coverUrl={cover}
        />
      </div>
    )
  );
  await expect.element(page.getByRole("img", { name: "Notes · 1" })).toBeVisible();
  for (const image of document.querySelectorAll("img")) {
    await image.decode();
    expect(image.naturalWidth).toBe(390);
    expect(image.naturalHeight).toBe(844);
  }
  await page
    .getByTestId("mini-app-media")
    .screenshot({ path: "test-results/mini-app-media.png" });
  expect(read).toEqual([{ topic: "miniAppImage", url, workspace: "wsp" }]);
});
