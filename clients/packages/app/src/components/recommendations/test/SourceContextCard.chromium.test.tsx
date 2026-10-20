import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import type { RecommendationEnvelope } from "@comma/recommendation-contract";
import { cleanup, render } from "@comma/test-utils/render";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, expect, it } from "vitest";
import { page, userEvent } from "vitest/browser";
import { RailStoryCore } from "../RailStoryCore";
import { RecommendationRail } from "../RecommendationRail";

// Unmount on the test clock: the rail's resize observers and the card's hover
// timers stop with it.
afterEach(() => {
  cleanup();
  document.body.replaceChildren();
});

const noop = () => undefined;
const mail = "https://outlook.live.com/mail/0/inbox/id/1";
const task = "Check whether disabling Find My on pengx17 was intentional";
const envelope = {
  settings: {
    autoEnableNewSources: true,
    schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
    sourceRevision: 1,
    sources: [
      {
        appId: "outlook",
        appName: "Microsoft Outlook",
        connectionId: "outlook",
        enabled: true,
        kind: "native_mcp_oauth",
        label: "Microsoft Outlook",
      },
    ],
    sourcesCheckedAt: "2026-10-20T06:00:00.000Z",
  },
  snapshot: {
    cards: [
      {
        fallbackText: task,
        id: "outlook",
        items: [
          {
            action: {
              label: task,
              prompt: `${task}.\n\n${mail}`,
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "find-my",
            parts: [
              {
                kind: "inline-link",
                link: {
                  href: mail,
                  label: task,
                  // Outlook text mail shows an image as its URL in brackets.
                  previewText:
                    "Find My has been disabled on pengx17\nFind My: [https://statici.icloud.com/fmipmobile/deviceImages-4.0/iPhone/iPhone18,2-1-9-0/online-nolocation_iphone__2x.png]\nWith Find My disabled, these devices can no longer be located.",
                  sourceId: "outlook",
                  taskPrompt: `${task}.\n\n${mail}`,
                },
              },
            ],
          },
        ],
        sourceIds: ["outlook"],
        template: "text-list@1",
        title: "Microsoft Outlook",
      },
    ],
    generatedAt: 1_792_478_227_000,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary: [{ kind: "markdown", text: "Good afternoon." }],
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
} satisfies RecommendationEnvelope;

const sameLine = (a: DOMRect, b: DOMRect) => a.top < b.bottom && b.top < a.bottom;

it("keeps a row's source context inside the rail and runs a long link in its line", async () => {
  await page.viewport(1024, 720);
  render(
    <RailStoryCore envelope={envelope}>
      {/* Home's rail at its narrowest, a column beside the chat panel. */}
      <div
        style={{ display: "flex", flexDirection: "column", height: 600, width: 300 }}
      >
        <RecommendationRail
          onOpenTask={noop}
          onOpenUrl={noop}
          onUsePrompt={noop}
          workspaceId="wsp_1"
        />
      </div>
    </RailStoryCore>
  );
  setInteractionModality("pointer");
  // The row is its source link; the link takes the pointer over the row.
  await userEvent.hover(page.getByRole("button", { name: task }).last());
  const card = page.getByRole("tooltip");
  await expect.element(card).toBeVisible();

  const rail = document
    .querySelector(".comma-recommendations")!
    .getBoundingClientRect();
  const box = card.element().getBoundingClientRect();
  expect(box.left).toBeGreaterThanOrEqual(rail.left);
  expect(box.right).toBeLessThanOrEqual(rail.right);

  // The link starts on the line of the "[" before it, and the "]" after it
  // follows its last line.
  const link = page
    .getByRole("link", {
      name: "statici.icloud.com/…/online-nolocation_iphone__2x.png",
    })
    .element();
  const linkLines = link.getClientRects();
  const opening = document.createRange();
  opening.selectNodeContents(link.previousSibling!);
  const closing = document.createRange();
  closing.selectNodeContents(link.nextSibling!);
  expect(sameLine(opening.getBoundingClientRect(), linkLines[0]!)).toBe(true);
  expect(
    sameLine(closing.getBoundingClientRect(), linkLines[linkLines.length - 1]!)
  ).toBe(true);
});
