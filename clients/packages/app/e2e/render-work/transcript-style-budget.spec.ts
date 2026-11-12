import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../../e2e/helpers/browser-auth";
import { waitForFiniteAnimations } from "../../../../e2e/helpers/motion";
import { browserRenderWork } from "../../../../e2e/helpers/render-work";
import { startChatSmokeStub } from "../../../../e2e/p0/chat-stub";

// A theme, window-material, appearance or `inert` change restyles every
// element of the document, so the cost of one restyled element multiplies
// with the transcript a Home has mounted. These budgets count the work of one
// whole-document restyle on a long transcript; they do not time it.

// The thread first mounts the latest six turns, so every turn mounts. Each
// reply is long and nested, so most of the document is Markdown.
const turns = 6;
const listItems = 40;

const reply = (turn: number) =>
  [
    `### Step ${turn}`,
    "The rollout is **on track** and the `dashboards` are quiet. See [the runbook](https://example.com/runbook).",
    Array.from(
      { length: listItems },
      (_, item) =>
        `- Item ${item} is **confirmed** with \`check-${item}\` and *a note*.`
    ).join("\n"),
    "| Stage | Owner | State |\n| --- | --- | --- |\n" +
      Array.from(
        { length: 12 },
        (_, row) => `| Stage ${row} | **Team ${row}** | \`ready\` |`
      ).join("\n"),
    "> A quoted line with **emphasis** and `code`.",
    "```ts\nexport const ready = true;\nexport const stage = 1;\n```",
  ].join("\n\n");

const transcript = () =>
  Array.from({ length: turns }, (_, turn) => [
    message(turn, "user", `Where does step ${turn} stand?`),
    message(turn, "agent", reply(turn)),
  ]).flat();

function message(turn: number, actor: "user" | "agent", text: string) {
  return {
    actor_type: actor,
    content: [{ type: "text" as const, text }],
    created_at: 1_720_000_000 + turn * 10 + (actor === "agent" ? 5 : 0),
    kind: "message",
    message_id: `budget-${actor === "agent" ? "assistant" : "user"}-${turn}`,
  };
}

/** Opens a Home whose transcript is most of the document. */
async function openLongHome(page: Page, apiBaseUrl: string, name: string) {
  await page.setViewportSize({ width: 1600, height: 960 });
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: `${name}@comma.local`,
    token: `comma_sess_${name.replaceAll("-", "_")}`,
  });
  await page.goto("/");
  const column = page.locator(".comma-home-chat .comma-chat-column");
  await expect(column.locator('[data-message-id^="budget-assistant-"]')).toHaveCount(
    turns
  );
  await expect(column.locator(".markdown-stream li")).toHaveCount(turns * listItems);
  await waitForFiniteAnimations(page);
  const shape = await page.evaluate(() => ({
    elements: document.querySelectorAll("*").length,
    markdown: document.querySelectorAll(".markdown-stream *").length,
  }));
  // A style that each Markdown descendant computes for itself shows in the
  // counts.
  expect(shape.markdown).toBeGreaterThan(shape.elements / 2);
  return shape;
}

/**
 * Restyles the whole document once, as a root custom-property write does.
 * Returns the elements of that restyle and, with `selectors`, each selector's
 * work during it.
 */
async function restyleWholeDocument(
  page: Page,
  shape: { markdown: number },
  options?: { selectors: boolean }
) {
  const work = await browserRenderWork(
    page,
    () =>
      page.evaluate(() => {
        const root = document.documentElement;
        root.style.setProperty("--comma-style-budget-probe", "1");
        void root.offsetHeight;
      }),
    options
  );
  // The trace holds this restyle, and at most the small restyles of frames
  // that ran beside it.
  const restyled = Math.max(0, ...work.restyled);
  // It reached the transcript, so the budgets below count a real restyle.
  expect(restyled).toBeGreaterThan(shape.markdown);
  return { restyled, selectors: work.selectors };
}

test("a whole-document restyle of a long Home computes about one style per element", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ workspaceTranscript: transcript() });
  try {
    const shape = await openLongHome(page, stub.baseUrl, "transcript-style-count");
    const { restyled } = await restyleWholeDocument(page, shape);

    // Each element computes its own style, and a few have ::before, ::after
    // or ::marker styles. A highlight style (::selection, ::highlight) is
    // computed on the root it is declared on and inherited by descendants;
    // a highlight rule with a descendant subject made every Markdown
    // descendant compute one more style.
    expect(restyled).toBeLessThan(shape.elements * 1.2);
  } finally {
    await stub.close();
  }
});

test("a whole-document restyle of a long Home checks few selectors that match nothing", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ workspaceTranscript: transcript() });
  try {
    const shape = await openLongHome(page, stub.baseUrl, "transcript-style-selectors");
    // Reduced motion is off, no display-only preview is open, and no search
    // highlight is painted: the rules for those states match nothing.
    const { restyled, selectors } = await restyleWholeDocument(page, shape, {
      selectors: true,
    });
    expect(selectors.size).toBeGreaterThan(0);

    // The ancestor filter rejects a rule without a check when an ancestor
    // class or attribute name that the rule needs is absent; it cannot reject
    // on an attribute value. A state attribute written as "false" at rest, or
    // a highlight rule with a universal subject, is checked on every element.
    const unmatched = [...selectors]
      .filter(([, work]) => work.matched === 0)
      .map(([selector, work]) => ({ selector, perElement: work.checked / restyled }))
      .toSorted((a, b) => b.perElement - a.perElement);
    const perElement = unmatched.reduce((sum, rule) => sum + rule.perElement, 0);

    // The rules that match nothing cost about 8 checks per element today;
    // one more such rule checked on every element exceeds the budget.
    expect(
      perElement,
      `unmatched rules checked on most elements:\n${unmatched
        .filter((rule) => rule.perElement > 0.5)
        .map((rule) => `${rule.perElement.toFixed(2)} ${rule.selector}`)
        .join("\n")}`
    ).toBeLessThan(8.5);
  } finally {
    await stub.close();
  }
});
