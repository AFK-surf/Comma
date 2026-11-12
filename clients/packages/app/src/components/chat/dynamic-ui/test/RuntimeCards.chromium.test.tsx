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

/**
 * Every layout, with data that fills it, as the runtime cards gallery shows
 * them. A layout that only fits short text names the fields its fit reads:
 * the stress pass keeps those as written and lengthens every other field.
 */
const layouts: Array<[CardKind, string, object, string[]?]> = [
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
  ["composition", "donut", fixtures.storageFixture, ["total", "totalLabel"]],
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
  ["order", "tracking", fixtures.orderFixture],
  ["order", "receipt", fixtures.receiptFixture],
  ["order", "compact", fixtures.orderFixture],
  ["ticket", "ticket", fixtures.trainTicketFixture],
  ["ticket", "pass", fixtures.boardingPassFixture],
  ["ride", "pickup", fixtures.rideFixture],
  ["ride", "trip", fixtures.rideFixture],
  [
    "product",
    "hero",
    {
      ...fixtures.productFixture,
      products: fixtures.productFixture.products.slice(0, 1),
    },
  ],
  ["product", "grid", fixtures.productFixture],
  ["product", "list", fixtures.productFixture],
  ["booking", "confirmation", fixtures.bookingFixture],
  ["booking", "compact", fixtures.bookingFixture],
  ["device", "single", fixtures.deviceFixture],
  ["device", "grid", fixtures.devicesFixture],
  ["payment", "receipt", fixtures.paymentFixture],
  ["payment", "compact", fixtures.paymentFixture],
  ["media", "player", fixtures.mediaFixture],
  ["media", "queue", fixtures.mediaFixture],
  ["bars", "rows", fixtures.eventBarsFixture],
  ["bars", "rows", fixtures.funnelBarsFixture],
  ["bars", "compact", fixtures.eventBarsFixture, ["label"]],
  ["bars", "columns", fixtures.ratingBarsFixture, ["label"]],
  ["table", "grid", fixtures.leaderboardTableFixture],
  ["table", "grid", fixtures.cohortTableFixture],
  ["table", "grid", fixtures.regionTableFixture],
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
  "arrivesBy",
  "mode",
  "zone",
  "image",
  "cover",
  "observedAt",
  "id",
  "key",
  "filterKeys",
]);
const long = `${"很长的中文说明文字用于检查卡片是否留在边界内".repeat(8)}https://example.com/${"AnUnbrokenLatinRunWithoutSpaces".repeat(8)}`;

/**
 * Agent text at its longest: every text field far past one line, with an
 * unbroken run wider than any card, and every compared subject recommended, so
 * a badge also heads the last column.
 */
/** Names and labels in a slot of fixed width: one line, cut at the slot's edge. */
const slots = [
  ".wc-clip",
  ".wc-opt-times",
  ".wc-opt-price",
  ".wc-watch-value",
  ".wc-pill",
  ".wc-vs-label",
  ".wc-agenda-time",
  ".wc-now-time",
  ".wc-step-time",
  ".wc-fc-week-label",
  ".wc-chip",
  ".wc-area-axis>span",
  ".wc-bars-value",
  ".wc-rank-values>span",
  ".wc-rank-compact>li>.wc-num",
].join(",");

/** Whether an element's visible text takes more than one line. */
const wraps = (element: HTMLElement) => {
  const page = element.ownerDocument;
  const walker = page.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  const tops = new Set<number>();
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.parentElement?.closest(".wc-sr")) continue;
    const range = page.createRange();
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) tops.add(Math.round(rect.top));
  }
  return tops.size > 1;
};

/** How many lines the boxes of `cells` start on. */
const lines = (cells: HTMLElement[]) =>
  new Set(cells.map((cell) => Math.round(cell.getBoundingClientRect().top))).size;

const longest = (value: unknown, keep: string[] = [], key = ""): unknown => {
  if (typeof value === "string")
    return literal.has(key) || keep.includes(key) ? value : long;
  if (Array.isArray(value)) return value.map((item) => longest(item, keep, key));
  if (value === null || typeof value !== "object") return value;
  const entries = Object.entries(value).map(([name, item]) => [
    name,
    longest(item, keep, name),
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

it("keeps Agent text of any length inside the card, and fixed slots on one line, in every layout", () => {
  const overflowing: string[] = [];
  for (const width of [320, 560]) {
    const page = sandbox(width);
    for (const [kind, variant, data, keep] of layouts) {
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
        engine.mount(target, { kind, data: longest(data, keep), variant }, "card")
      );
      const card = target.querySelector<HTMLElement>(".wc-card")!;
      expect(card.dataset.layout).toBe(`${kind}.${variant}`);
      if (card.scrollWidth > card.clientWidth)
        overflowing.push(`${kind}.${variant} at ${width}px`);
      for (const slot of card.querySelectorAll<HTMLElement>(slots))
        if (wraps(slot))
          overflowing.push(`${kind}.${variant} ${slot.className} wraps at ${width}px`);
      engine.dispose();
    }
  }
  expect(overflowing).toEqual([]);
});

it("sets a table's rows in columns where every column has room, and stacks them where not", () => {
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  /** The cells of each row of `data`, in a card as wide as fits `width`. */
  const rowsOf = (width: number, data: object) => {
    const page = sandbox(width);
    const target = page.createElement("section");
    page.body.append(target);
    target.replaceChildren(engine.mount(target, { kind: "table", data }, "card"));
    return [...target.querySelectorAll("tbody tr")].map((row) => [
      ...row.querySelectorAll<HTMLElement>(":scope > *"),
    ]);
  };
  // Eight short columns fit the widest card: one line, no entry broken.
  const [cohort] = rowsOf(720, fixtures.cohortTableFixture);
  expect(lines(cohort!)).toBe(1);
  expect(cohort!.some(wraps)).toBe(false);
  // They do not fit a phone: each entry is a label and its value, and a cell
  // with no value yet shows no label.
  const phone = rowsOf(360, fixtures.cohortTableFixture);
  expect(lines(phone[0]!)).toBeGreaterThan(1);
  const unset = phone.at(-1)!.filter((cell) => !cell.textContent);
  expect(unset).toHaveLength(5);
  expect(unset.every((cell) => cell.getBoundingClientRect().height === 0)).toBe(true);
  // Amounts and names need more room than a card has. Side by side, a name
  // would break after every character.
  const [regions] = rowsOf(720, fixtures.regionTableFixture);
  expect(lines(regions!)).toBeGreaterThan(1);
  expect(regions!.some(wraps)).toBe(false);
  engine.dispose();
});

it("keeps a bar's value off the average line, and breaks a label after a separator", () => {
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  // A card as wide as each of two side by side in a message.
  const page = sandbox(300);
  const target = page.createElement("section");
  page.body.append(target);
  target.replaceChildren(
    engine.mount(
      target,
      {
        kind: "trend",
        variant: "bars",
        data: {
          title: "Sources",
          bars: {
            labels: ["Direct", "google.com", "t.co", "github.com", "Other"],
            // The mean is 216: one bar ends just under it, one far under it.
            values: [300, 280, 260, 200, 40],
            averageLabel: "Average 216",
          },
        },
      },
      "card"
    )
  );
  // The foot of the dashed line: a value stands on it, its text clear of the dashes.
  const line = target.querySelector(".wc-bars-average")!.getBoundingClientRect().bottom;
  const bars = [...target.querySelectorAll(".wc-bar-slot")].map((slot) => ({
    bar: slot.querySelector(".wc-bar-col")!.getBoundingClientRect(),
    value: slot.querySelector(".wc-bars-value")!.getBoundingClientRect(),
  }));
  expect(bars).toHaveLength(5);
  for (const { bar, value } of bars) {
    expect(value.height).toBeGreaterThan(0);
    // Above its bar, and not across the line.
    expect(value.bottom).toBeLessThanOrEqual(bar.top + 0.5);
    expect(value.top < line - 0.5 && value.bottom > line + 0.5).toBe(false);
  }
  // The bar just under the line has its value on the line; the short bar keeps its own.
  expect(bars[3]!.value.bottom).toBeCloseTo(line, 0);
  expect(bars[4]!.value.bottom).toBeCloseTo(bars[4]!.bar.top, 0);
  // A domain too long for its slot breaks after its dot: no piece of it runs over two lines.
  const pieces: number[] = [];
  const walker = page.createTreeWalker(
    target.querySelector(".wc-bars-axis")!,
    NodeFilter.SHOW_TEXT
  );
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const range = page.createRange();
    range.selectNodeContents(node);
    pieces.push(range.getClientRects().length);
  }
  expect(pieces).toEqual(Array<number>(8).fill(1));
  expect(
    wraps(
      target.querySelector<HTMLElement>(".wc-bars-axis")!.children[1] as HTMLElement
    )
  ).toBe(true);
  engine.dispose();
});

it("hangs a chart's bar under the zero line for a value under zero", () => {
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  const page = sandbox(560);
  const figure = page.createElement("figure");
  figure.className = "comma-chart";
  figure.append(
    engine.chart({
      type: "bar",
      labels: ["Loss", "Flat", "Gain"],
      series: [{ name: "", values: [-10, 0, 10] }],
    })
  );
  page.body.append(figure);
  const zero = figure.querySelector(".wc-bars-zero")!.getBoundingClientRect().bottom;
  const plot = figure.querySelector(".wc-bars-plot")!.getBoundingClientRect();
  const [loss, , gain] = [...figure.querySelectorAll(".wc-bar-col")].map((bar) =>
    bar.getBoundingClientRect()
  );
  // The gain stands on the line and the loss hangs from it, at one height.
  expect(gain!.height).toBeGreaterThan(20);
  expect(loss!.height).toBeCloseTo(gain!.height, 0);
  expect(gain!.bottom).toBeCloseTo(zero, 0);
  expect(loss!.top).toBeCloseTo(zero, 0);
  expect(loss!.bottom).toBeLessThanOrEqual(plot.bottom + 0.5);
  // Each value stands over the line or over its bar, inside the plot.
  for (const value of figure.querySelectorAll(".wc-bars-value")) {
    const box = value.getBoundingClientRect();
    expect(box.bottom).toBeLessThanOrEqual(zero + 0.5);
    expect(box.top).toBeGreaterThanOrEqual(plot.top - 0.5);
  }
  engine.dispose();
});

it("sets the cards of an authored grid side by side only where each has room", () => {
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  /** The boxes of two cards in a widget's `.grid`, in a message `width` wide. */
  const pair = (width: number) => {
    const page = sandbox(width);
    const content = page.createElement("div");
    content.className = "wc-root";
    const grid = page.createElement("div");
    grid.className = "grid";
    content.append(grid);
    page.body.append(content);
    return (["first", "second"] as const).map((id) => {
      const target = page.createElement("section");
      grid.append(target);
      target.replaceChildren(
        engine.mount(target, { kind: "trend", data: fixtures.barTrendFixture }, id)
      );
      return target.querySelector<HTMLElement>(".wc-card")!.getBoundingClientRect();
    });
  };
  const [left, right] = pair(640);
  expect(right!.top).toBe(left!.top);
  // On a phone each of two would be too narrow for its own labels.
  const [above, below] = pair(360);
  expect(below!.top).toBeGreaterThan(above!.bottom);
  expect(below!.width).toBe(above!.width);
  engine.dispose();
});

it("draws a name with no logo on the tile its neighbours' logos have", () => {
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: () => {},
  });
  const page = sandbox(560);
  /** The tile of each row of a watchlist of `series`: what it shows and its ground. */
  const tiles = (series: typeof fixtures.watchlistFixture.series) => {
    const target = page.createElement("section");
    page.body.append(target);
    target.replaceChildren(
      engine.mount(
        target,
        { kind: "trend", data: { ...fixtures.watchlistFixture, series } },
        "card"
      )
    );
    return [
      ...target.querySelectorAll<HTMLElement>(".wc-watch-name > :first-child"),
    ].map((tile) => [tile.textContent, getComputedStyle(tile).backgroundColor]);
  };
  // Three of the four stocks have a logo: the fourth shows its initial on their tile.
  const mixed = tiles(fixtures.watchlistFixture.series);
  expect(mixed.map(([shown]) => shown)).toEqual(["", "", "T", ""]);
  expect(new Set(mixed.map(([, ground]) => ground)).size).toBe(1);
  // With no logo among them, each name keeps its own tinted initial.
  const plain = tiles(
    fixtures.watchlistFixture.series!.map(({ brand: _brand, ...item }) => item)
  );
  expect(plain.map(([shown]) => shown)).toEqual(["A", "N", "T", "G"]);
  expect(plain.map(([, ground]) => ground)).not.toContain(mixed[0]![1]);
  engine.dispose();
});

it("sends an action's prompt as written", async () => {
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

it("proposes a device control's prompt when a person presses it", async () => {
  const sent: unknown[] = [];
  const target = document.createElement("section");
  document.body.append(target);
  const engine = cardEngine({
    seed: "block-1",
    locale: "zh-CN",
    copy: {},
    icons: cardIconMarkup(),
    state: {},
    send: (message) => sent.push(message),
  });
  target.replaceChildren(
    engine.mount(target, { kind: "device", data: fixtures.deviceFixture }, "card")
  );
  const raise = [...target.querySelectorAll("button")].find(
    (button) => button.textContent === "+1°"
  )!;
  await userEvent.click(raise);
  expect(sent).toEqual([{ type: "request", value: "把客厅空调调到 27 度" }]);
  engine.dispose();
});

it("lays out a widget's top level as one column of the card width, and leaves an authored layout alone", () => {
  // Wider than the card width, as a desktop message column is.
  const page = sandbox(720);
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
  // The widget's own cards and text after them: as wide as a template card,
  // spaced the same, and a hidden element between two adds no gap.
  const authored = (html: string) => {
    const template = page.createElement("template");
    template.innerHTML = html;
    content.append(template.content);
    return content.lastElementChild!.getBoundingClientRect();
  };
  const card = authored(
    '<section class="card"><h2 class="widget-title">Key conversions</h2><p>Sign-ups 56 / 72</p></section>'
  );
  expect(card.top - second!.bottom).toBe(12);
  expect(card.width).toBe(second!.width);
  authored('<section class="card" hidden><p>Away</p></section>');
  const next = authored('<section class="card"><p>Week over week</p></section>');
  expect(next.top - card.bottom).toBe(12);
  const note = authored('<p class="muted">Source: PostHog, 2026-11-05.</p>');
  expect(note.top - next.bottom).toBe(12);
  expect(note.width).toBe(560);
  expect(first!.width).toBe(560);
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
