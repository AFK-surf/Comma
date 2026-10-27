import "@comma/ui/styles.css";

import * as fixtures from "@comma/chat-contract/dynamic-ui-card-fixtures";
import { cardEngine, type CardKind } from "@comma/chat-contract/dynamic-ui-cards";
import { dynamicUiDocument } from "@comma/chat-contract/dynamic-ui-runtime";
import { afterEach, expect, it } from "vitest";
import { userEvent } from "vitest/browser";
import { cardIconMarkup, cardTokenProbe } from "../cardHost";

afterEach(() => {
  document.body.replaceChildren();
});

/** Every layout, with data that fills it, as the runtime cards gallery shows them. */
const layouts: Array<[CardKind, string, object]> = [
  ["forecast", "today", fixtures.forecastFixture],
  ["forecast", "week", fixtures.forecastFixture],
  [
    "forecast",
    "compact",
    { ...fixtures.forecastFixture, days: fixtures.forecastFixture.days?.slice(0, 2) },
  ],
  ["options", "timetable", fixtures.trainOptionsFixture],
  ["options", "list", fixtures.trainOptionsFixture],
  ["options", "pick", fixtures.hotelOptionsFixture],
  ["metric", "single", fixtures.metricFixture],
  ["metric", "grid", fixtures.metricGridFixture],
  ["metric", "goal", fixtures.goalFixture],
  ["trend", "area", fixtures.trendFixture],
  ["trend", "bars", fixtures.barTrendFixture],
  ["trend", "watchlist", fixtures.watchlistFixture],
  ["comparison", "columns", fixtures.comparisonFixture],
  ["comparison", "table", fixtures.planComparisonFixture],
  ["comparison", "versus", fixtures.versusFixture],
  ["schedule", "agenda", fixtures.agendaFixture],
  ["schedule", "timeline", fixtures.itineraryFixture],
  ["schedule", "stages", fixtures.stagesFixture],
  ["checklist", "progress", fixtures.checklistFixture],
  ["checklist", "grouped", fixtures.groupedChecklistFixture],
  ["composition", "stacked", fixtures.compositionFixture],
  ["composition", "donut", fixtures.storageFixture],
  [
    "place",
    "single",
    { ...fixtures.placeFixture, places: fixtures.placeFixture.places.slice(0, 1) },
  ],
  ["place", "nearby", fixtures.placeFixture],
  ["feed", "news", fixtures.newsFixture],
  ["feed", "list", fixtures.pullRequestsFixture],
  ["feed", "digest", fixtures.digestFixture],
  ["timer", "countdown", fixtures.timerFixture],
  ["timer", "event", fixtures.eventCountdownFixture],
];

// Values a template reads as a key, a choice, a link or a time, not as text.
const literal = new Set([
  "tone",
  "condition",
  "state",
  "direction",
  "phase",
  "href",
  "brand",
  "sourceBrand",
  "at",
  "endsAt",
  "observedAt",
  "id",
  "key",
  "filterKeys",
]);
const long =
  "很长的中文说明文字用于检查卡片是否留在边界内AnUnbrokenLatinRunWithoutSpaces".repeat(
    8
  );

/**
 * Agent text at its longest: every text field past what a template keeps, and
 * every compared subject recommended, so a badge also heads the last column.
 */
const longest = (value: unknown, key = ""): unknown => {
  if (typeof value === "string") return literal.has(key) ? value : long;
  if (Array.isArray(value)) return value.map((item) => longest(item, key));
  if (value === null || typeof value !== "object") return value;
  const entries = Object.entries(value).map(([name, item]) => [
    name,
    longest(item, name),
  ]);
  if (key === "subjects") entries.push(["recommended", true]);
  return Object.fromEntries(entries);
};

/** A frame with the widget runtime's own document and styles, on the host's tokens. */
function sandbox(width: number) {
  const frame = document.createElement("iframe");
  frame.style.width = `${width}px`;
  document.body.append(frame);
  const page = frame.contentDocument!;
  page.open();
  page.write(dynamicUiDocument().replace(/<script>[\s\S]*<\/script>/, ""));
  page.close();
  const probe = cardTokenProbe(document.body);
  for (const [name, value] of Object.entries(probe.read()))
    page.documentElement.style.setProperty(name, value);
  probe.remove();
  return page;
}

it("keeps Agent text of any length inside the card in every layout", () => {
  const overflowing: string[] = [];
  for (const width of [320, 560]) {
    const page = sandbox(width);
    for (const [kind, variant, data] of layouts) {
      const target = page.createElement("section");
      page.body.append(target);
      const engine = cardEngine({
        seed: "block-1",
        locale: "en",
        copy: {},
        icons: cardIconMarkup(),
        state: {},
        send: () => {},
      });
      target.replaceChildren(
        engine.mount(target, { kind, data: longest(data), variant }, "card")
      );
      const card = target.querySelector<HTMLElement>(".wc-card")!;
      expect(card.dataset.layout).toBe(`${kind}.${variant}`);
      if (card.scrollWidth > card.clientWidth)
        overflowing.push(`${kind}.${variant} at ${width}px`);
      engine.dispose();
    }
  }
  expect(overflowing).toEqual([]);
});

it("sends an action's prompt as written, without the ellipsis display text gets", async () => {
  const sent: unknown[] = [];
  const target = document.createElement("section");
  document.body.append(target);
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: (message) => sent.push(message),
  });
  const prompt = "比较".repeat(2100);
  target.replaceChildren(
    engine.mount(
      target,
      {
        kind: "place",
        data: { ...fixtures.placeFixture, actions: [{ label: "Compare", prompt }] },
      },
      "card"
    )
  );
  await userEvent.click(target.querySelector<HTMLElement>(".wc-action")!);
  expect(sent).toEqual([{ type: "request", value: prompt.slice(0, 4000) }]);
  engine.dispose();
});

it("spaces cards a widget places one after another, and leaves an authored layout alone", () => {
  const page = sandbox(560);
  // A widget's own stylesheet lays out a class or an id it names.
  const sheet = page.createElement("style");
  sheet.textContent =
    ".pair,#pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}";
  page.head.append(sheet);
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  /** The boxes of two cards mounted in sibling elements of a new `parent`. */
  const cardsIn = (parent: HTMLElement) => {
    page.body.append(parent);
    return (["first", "second"] as const).map((id) => {
      const target = page.createElement("section");
      parent.append(target);
      target.replaceChildren(
        engine.mount(
          target,
          { kind: "metric", data: fixtures.metricGridFixture, variant: "grid" },
          id
        )
      );
      return target.querySelector<HTMLElement>(".wc-card")!.getBoundingClientRect();
    });
  };
  const parent = (className?: string, id?: string) => {
    const element = page.createElement("div");
    if (className) element.className = className;
    if (id) element.id = id;
    return element;
  };
  // The runtime places the widget's html in its root, as here.
  const content = parent("wc-root");
  content.style.display = "flow-root";
  const [first, second] = cardsIn(content);
  expect(second!.top - first!.bottom).toBe(12);
  const [above, below] = cardsIn(parent("stack"));
  expect(below!.top - above!.bottom).toBe(8);
  for (const sideBySide of ["pair", "feature", "row"]) {
    const [left, right] = cardsIn(parent(sideBySide));
    expect(right!.top, sideBySide).toBe(left!.top);
  }
  const [left, right] = cardsIn(parent(undefined, "pair"));
  expect(right!.top, "#pair").toBe(left!.top);
  engine.dispose();
});
