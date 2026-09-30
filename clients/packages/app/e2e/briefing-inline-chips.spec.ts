import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// A briefing paragraph ends in the citations it earned, and the next paragraph
// opens with a blank line in its markdown text (the catalog contract). The
// paragraph boundary and the chip geometry are layout facts, pinned here in a
// real browser rather than in jsdom — one page load, since every assertion
// reads the same rendered summary.
test.use({ timezoneId: "UTC" });

const sources = [
  {
    appId: "slack",
    appName: "Slack",
    connectionId: "local-slack",
    enabled: true,
    kind: "composio",
    label: "Slack",
  },
  {
    appId: "linear",
    appName: "Linear",
    connectionId: "local-linear",
    enabled: true,
    kind: "composio",
    label: "Linear",
  },
];

function envelope() {
  return {
    settings: {
      autoEnableNewSources: true,
      schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
      sourceRevision: 1,
      sources,
      sourcesCheckedAt: "2026-08-27T00:00:00Z",
    },
    snapshot: {
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [
        {
          kind: "markdown",
          // Longer than a title line, so the briefing keeps it in the body.
          text: "The Router opened the circuit and the external worker never started.",
        },
        {
          kind: "inline-link",
          link: {
            href: "https://slack.com/archives/C1/p1",
            label: "Slack diagnosis",
            sourceId: "local-slack",
          },
        },
        { kind: "markdown", text: "\n\nBridge is off." },
        {
          kind: "inline-link",
          link: {
            href: "https://linear.app/comma/issue/COMMA-242",
            label: "COMMA-242",
            sourceId: "local-linear",
          },
        },
        {
          kind: "inline-link",
          link: {
            href: "https://linear.app/comma/issue/BRI-1655",
            label: "BRI-1655",
            sourceId: "local-linear",
          },
        },
        // Prose between two chips: the second citation run of the paragraph,
        // so BRI-1655 has a chip after it but not next to it.
        { kind: "markdown", text: ", while " },
        {
          kind: "inline-link",
          link: {
            href: "https://linear.app/comma/issue/DEV-9",
            label: "DEV-9",
            sourceId: "local-linear",
          },
        },
        { kind: "markdown", text: " is still open." },
      ],
      templateCatalogVersion: 1,
      warnings: [],
    },
    state: "fresh",
  };
}

test("briefing paragraphs own their citations, and chips share the prose grid", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "briefing-chips@comma.local",
      token: "comma_sess_briefing_chips",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({ contentType: "application/json", json: envelope() });
          return;
        }
        await route.continue();
      }
    );
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/");

    const body = page.locator(".comma-recommendations-summary-body");
    await expect(body).toBeVisible();

    // A paragraph that ends in its citations still starts a new block, and
    // each paragraph keeps the citations that close it.
    const paragraphs = body.locator(".markdown-stream p");
    await expect(paragraphs).toHaveCount(2);
    await expect(paragraphs.nth(0)).toHaveText(
      "The Router opened the circuit and the external worker never started.Slack diagnosis"
    );
    await expect(paragraphs.nth(1)).toHaveText(
      "Bridge is off.COMMA-242BRI-1655, while DEV-9 is still open."
    );

    // Adjacent citation chips sit 4px apart on one line.
    const chips = body.locator(".comma-recommendation-inline");
    await expect(chips).toHaveCount(4);
    const gap = await chips.evaluateAll((nodes) => {
      const first = nodes[1]!.getBoundingClientRect();
      const second = nodes[2]!.getBoundingClientRect();
      if (Math.round(first.top) !== Math.round(second.top)) {
        throw new Error("expected COMMA-242 and BRI-1655 to share a line");
      }
      return second.left - first.right;
    });
    expect(gap).toBe(4);

    // That gap belongs to the run, not to every chip with a later one in the
    // same paragraph. The rule's `+` reads past text nodes, so it holds only
    // because MarkdownStream gives prose its own element: pin that here, or a
    // renderer that emitted bare text would silently prise every following
    // comma off its word.
    const trailing = await chips.evaluateAll((nodes) =>
      nodes.map((node) => getComputedStyle(node).marginInlineEnd)
    );
    expect(trailing).toEqual(["0px", "4px", "0px", "0px"]);

    // The chip's fill stops short of the line box, so the chips on consecutive
    // lines of a wrapped paragraph keep a gutter instead of meeting edge to
    // edge — and it stops one step short, not two, so the 16px mark inside
    // keeps a pixel clear of both edges rather than reading as a tile.
    const box = await chips.first().evaluate((node) => ({
      chip: node.getBoundingClientRect().height,
      line: Number.parseFloat(getComputedStyle(node.closest("p")!).lineHeight),
      mark: node.querySelector("svg, img")!.getBoundingClientRect().height,
    }));
    expect(box).toEqual({ chip: 18, line: 20, mark: 16 });

    // Chip labels sit on the prose baseline: compare the glyph boxes of the
    // prose and of the chip label sharing the second paragraph's line — equal
    // font metrics and an equal bottom edge mean one baseline.
    const offset = await paragraphs.nth(1).evaluate((node) => {
      const targets = [
        { element: node.querySelector("span"), what: "the prose span" },
        {
          element: node.querySelector(".comma-recommendation-inline span:last-child"),
          what: "the chip label",
        },
      ];
      const glyphs = targets.map(({ element, what }) => {
        if (!element) throw new Error(`expected the paragraph to render ${what}`);
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let text: Text | null = null;
        let current = walker.nextNode();
        while (current) {
          text = current as Text;
          current = walker.nextNode();
        }
        if (!text) throw new Error(`no text rendered in ${what}`);
        const range = document.createRange();
        range.setStart(text, Math.max(0, text.length - 1));
        range.setEnd(text, text.length);
        return range.getBoundingClientRect();
      });

      const [prose, label] = glyphs as [DOMRect, DOMRect];
      return {
        bottom: label.bottom - prose.bottom,
        height: label.height - prose.height,
        sameLine: Math.abs(label.top - prose.top) < 8,
      };
    });
    expect(offset).toEqual({ bottom: 0, height: 0, sameLine: true });
  } finally {
    await stub.close();
  }
});
