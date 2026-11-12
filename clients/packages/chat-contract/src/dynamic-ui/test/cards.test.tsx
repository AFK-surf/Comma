import { afterEach, describe, expect, it, vi } from "vitest";
import { cardEngine, type CardOutgoing } from "../cards";
import {
  checklistFixture,
  cohortTableFixture,
  comparisonFixture,
  eventBarsFixture,
  forecastFixture,
  funnelBarsFixture,
  leaderboardTableFixture,
  progressBarsFixture,
  ratingBarsFixture,
  groupedChecklistFixture,
  hotelOptionsFixture,
  boardingPassFixture,
  devicesFixture,
  mediaFixture,
  newsFixture,
  orderFixture,
  placeFixture,
  pullRequestsFixture,
  storageFixture,
  trainOptionsFixture,
  versusFixture,
} from "../cardFixtures";

const seeds = Array.from({ length: 100 }, (_, index) => `block-${index}`);

function show(
  kind: string,
  data: unknown,
  seed = "block-1",
  variant?: string,
  state: unknown = {}
) {
  const target = document.createElement("section");
  document.body.append(target);
  const engine = cardEngine({
    seed,
    locale: "en",
    copy: {},
    icons: {},
    state,
    send: () => {},
  });
  target.replaceChildren(engine.mount(target, { kind, data, variant }, "card"));
  return { target, engine };
}

/** Nodes a card adds to the widget, counted as the runtime counts them. */
function nodesOf(target: HTMLElement) {
  const walker = document.createTreeWalker(target, NodeFilter.SHOW_ALL);
  let nodes = 1;
  while (walker.nextNode()) nodes++;
  return nodes;
}

function layoutOf(kind: string, data: unknown, seed: string, variant?: string) {
  const { target, engine } = show(kind, data, seed, variant);
  const layout = target.querySelector<HTMLElement>("[data-layout]")?.dataset.layout;
  engine.dispose();
  target.remove();
  return layout?.slice(kind.length + 1);
}

const layoutsFor = (kind: string, data: unknown, variant?: string) =>
  new Set(seeds.map((seed) => layoutOf(kind, data, seed, variant)));

const texts = (target: Element, selector: string) =>
  [...target.querySelectorAll(selector)].map((node) => node.textContent);

/** The number each of `nodes` has in the style `read` returns, 0 where it has none. */
const numbers = (nodes: Iterable<HTMLElement>, read: (node: HTMLElement) => string) =>
  [...nodes].map((node) => Number.parseFloat(read(node) || "0"));

/** Each bar's tone and how much of its track it fills, in percent. */
const shares = (target: Element) =>
  [...target.querySelectorAll<HTMLElement>(".wc-rank-track")].map((track) => [
    track.dataset.tone,
    Math.round(Number.parseFloat(track.style.getPropertyValue("--wc-share"))),
  ]);

/** Which of a table's columns read down their right edge. */
const ends = (target: Element) =>
  [...target.querySelectorAll("thead th")].map((head) =>
    head.classList.contains("wc-table-end")
  );

const chartEngine = () =>
  cardEngine({
    seed: "s",
    locale: "en",
    copy: {},
    icons: {},
    state: {},
    send: () => {},
  });

afterEach(() => {
  document.body.replaceChildren();
});

describe("card layouts", () => {
  it("keeps one card on one layout and varies layouts across cards", () => {
    expect(layoutOf("comparison", structuredClone(versusFixture), "block-42")).toBe(
      layoutOf("comparison", versusFixture, "block-42")
    );
    const fourRows = { ...versusFixture, rows: versusFixture.rows.slice(0, 4) };
    expect(layoutsFor("comparison", fourRows)).toEqual(
      new Set(["columns", "table", "versus"])
    );
    expect(layoutsFor("checklist", groupedChecklistFixture)).toEqual(
      new Set(["progress", "grouped"])
    );
  });

  it("only picks layouts the data can fill", () => {
    expect(layoutsFor("comparison", comparisonFixture)).not.toContain("versus");
    // Each attribute becomes a table column, so five no longer fit.
    expect(layoutsFor("comparison", versusFixture)).toEqual(
      new Set(["columns", "versus"])
    );
    expect(layoutsFor("checklist", checklistFixture)).toEqual(new Set(["progress"]));
    expect(layoutsFor("options", hotelOptionsFixture)).toEqual(new Set(["pick"]));
    expect(layoutsFor("options", trainOptionsFixture)).not.toContain("pick");
    expect(layoutsFor("forecast", forecastFixture)).not.toContain("compact");
  });

  it("honours a requested layout only when it fits", () => {
    expect(layoutOf("composition", storageFixture, "block-1", "donut")).toBe("donut");
    expect(layoutsFor("comparison", comparisonFixture, "versus")).not.toContain(
      "versus"
    );
  });
});

describe("card content", () => {
  it("does not turn option order into a recommendation", () => {
    const items = [{ primary: "Hotel A" }, { primary: "Hotel B", recommended: false }];
    const { target } = show("options", { title: "Hotels", items }, "block-1", "pick");
    expect(target.textContent).toContain("Hotel A");
    expect(target.textContent).toContain("Hotel B");
    expect(target.textContent).not.toContain("Recommended");

    const recommended = show(
      "options",
      { title: "Hotels", items: [items[0], { ...items[1], recommended: true }] },
      "block-1",
      "pick"
    );
    expect(recommended.target.textContent).toContain("RecommendedHotel B");
  });

  it("renders retained list entries without reading discarded data", () => {
    const feed = show("feed", {
      title: "News",
      items: [
        ...Array.from({ length: 6 }, (_, i) => ({
          source: "Comma",
          title: `Update ${i}`,
        })),
        {},
      ],
    });
    expect(feed.target.querySelectorAll("li")).toHaveLength(6);
    expect(feed.target.textContent).toContain("Update 5");
    feed.engine.dispose();

    const comparison = show("comparison", {
      title: "Plans",
      subjects: ["A", "B", "C", "Discarded"].map((name) => ({ name })),
      rows: [{ label: "Price", values: ["1", "2", "3", 4] }],
    });
    expect(comparison.target.textContent).toContain("Price");
    expect(comparison.target.textContent).not.toContain("Discarded");
    comparison.engine.dispose();

    const pair = show("comparison", {
      title: "Plans",
      subjects: [{ name: "A" }, { name: "B" }],
      rows: [{ label: "Price", values: ["1", "2", 3] }],
    });
    expect(pair.target.textContent).toContain("Price");
    pair.engine.dispose();

    const items = Array.from({ length: 12 }, () => ({ label: "Task" }));
    const checklist = show("checklist", {
      title: "Tasks",
      groups: [{ items }, { items: [...items, {}] }, { items: [{}] }],
    });
    expect(checklist.target.textContent).toContain("0 of 20 done");
    checklist.engine.dispose();

    const bars = show("trend", {
      title: "Trend",
      bars: {
        labels: Array(32).fill("Day"),
        values: Array(31).fill(1),
      },
    });
    expect(bars.target.textContent).toContain("Trend");
    bars.engine.dispose();
  });

  it("links only to HTTPS destinations", () => {
    const unsafe = [
      "javascript:alert(1)",
      "http://example.test/",
      "https://user@example.test/",
    ];
    const items = newsFixture.items!.map((item, index) => ({
      ...item,
      href: unsafe[index] ?? item.href,
    }));
    const { target } = show("feed", { ...newsFixture, items }, "block-1", "news");

    const links = [...target.querySelectorAll("a")].map((link) => link.href);
    expect(links).toEqual(
      newsFixture.items!.slice(unsafe.length).map((item) => item.href)
    );
  });

  it("offers directions only for places with an HTTPS link", () => {
    const places = [{ ...placeFixture.places[0]!, href: "http://maps.example.test/" }];
    const { target } = show("place", { ...placeFixture, places }, "block-1", "single");

    expect(target.querySelector("a")).toBeNull();
  });

  it("lists each place's note, and its category only where the places differ", () => {
    const rowsOf = (places: typeof placeFixture.places) =>
      [...show("place", { ...placeFixture, places }).target.querySelectorAll("li")].map(
        (row) => row.textContent
      );
    const shared = rowsOf(placeFixture.places);
    expect(shared[1]).toContain(placeFixture.places[1]!.note);
    expect(shared.filter((row) => row?.includes("咖啡馆"))).toEqual([]);

    const mixed = rowsOf([
      ...placeFixture.places.slice(0, 3),
      { ...placeFixture.places[3]!, category: "烘焙店" },
    ]);
    expect(mixed[0]).toContain("4.6 · 2,310 条评价 · 咖啡馆");
    expect(mixed[3]).toContain("烘焙店");
  });

  it("shows a long label whole and matches saved progress by the id as written", () => {
    const label = "复核".repeat(50);
    const { target } = show(
      "checklist",
      { title: "Launch", groups: [{ items: [{ label }] }] },
      "block-1",
      "progress",
      { card: [label.slice(0, 80)] }
    );
    expect(target.querySelector(".wc-check-label")?.textContent).toBe(label);
    expect(checked(target)).toEqual([true]);
  });

  it("shows a checklist item's why, action and acceptance detail whole", () => {
    const detail = `为什么：${"真实回访形成月流量。".repeat(20)}动作：${"选一条工作切口。".repeat(20)}验收：记录首次成功。`;
    const { target } = show("checklist", {
      title: "Launch",
      groups: [{ items: [{ label: "降低首次成功门槛", detail }] }],
    });
    expect(target.querySelector(".wc-check .wc-xs")?.textContent).toBe(detail);
  });

  it("lists a nearby place's address under its note", () => {
    const place = { ...placeFixture.places[1]!, address: "静安区南京西路 1601 号" };
    const [, row] = [
      ...show("place", {
        ...placeFixture,
        places: [placeFixture.places[0]!, place],
      }).target.querySelectorAll("li"),
    ];
    expect(row?.textContent).toContain(place.note);
    expect(row?.textContent).toContain(place.address);
  });

  it("shows each feed item's status and leaves out a time it does not have", () => {
    const items = [
      {
        source: "Comma #2076",
        title: "Composer typing independent of conversation",
        status: { label: "Clean", tone: "success" },
        href: "https://github.com/AFK-surf/Comma/pull/2076",
      },
      {
        source: "commaboard #2240",
        title: "Cmd+K command palette foundation",
        excerpt: "3 failed checks · review required",
        status: { label: "Blocked", tone: "error" },
        time: "2h",
      },
    ];
    const { target } = show("feed", { title: "Open pull requests", items }, "block-1");
    const [clean, blocked] = [...target.querySelectorAll("li")];

    expect(clean!.querySelector("a")?.href).toBe(items[0]!.href);
    expect(clean!.textContent).toContain("CleanComma #2076");
    expect(clean!.textContent).not.toContain("·");
    expect(blocked!.textContent).toContain("3 failed checks · review required");
    expect(blocked!.textContent).toContain("Blockedcommaboard #2240 · 2h");
  });

  it("drops feed filters that match no item and shows every item without a choice", () => {
    const items = [
      { source: "Figma", title: "Agent ready", tags: ["Review"], filterKeys: ["all"] },
      { source: "Chat", title: "Welcome", filterKeys: ["all", "unread"] },
    ];
    const filters = [
      { key: "all", label: "All" },
      { key: "unread", label: "Unread" },
      { key: "flagged", label: "Flagged" },
    ];
    const { target } = show("feed", { title: "Inbox", items, filters }, "block-1");
    // Each choice names how many items it shows, counted from the data.
    expect(
      [...target.querySelectorAll("[role=group] button")].map((b) => [
        b.firstChild?.textContent,
        b.querySelector(".wc-seg-count")?.textContent,
      ])
    ).toEqual([
      ["All", "2"],
      ["Unread", "1"],
    ]);
    expect(target.querySelectorAll("li")).toHaveLength(2);
    expect(target.querySelector(".wc-badge")?.textContent).toBe("Review");

    // "Unread" matches nothing here, so only "All" is left: no control shows,
    // and even the item "All" would hide stays visible.
    const flagged = { source: "Mail", title: "Invoice", filterKeys: ["flagged"] };
    const one = show(
      "feed",
      { title: "Inbox", items: [items[0], flagged], filters: filters.slice(0, 2) },
      "block-2"
    ).target;
    expect(one.querySelector("[role=group]")).toBeNull();
    expect(one.querySelectorAll("li")).toHaveLength(2);
  });

  it("keeps the feed layouts within the node count the Worker manual names", () => {
    // The runtime's 2,000-node budget covers the whole rendered widget and also
    // counts the card's element. The Worker manual (salix_agent
    // tools/dynamic_ui.ex) says a card is at most 450 of them.

    // The most filters a feed holds, each with a count.
    const filters = [
      ...pullRequestsFixture.filters!,
      { key: "closed", label: "已关闭" },
    ];
    const base = pullRequestsFixture.items!;
    const items = Array.from({ length: 60 }, (_, index) => ({
      ...base[index % base.length]!,
      title: `#${4000 + index} ${base[index % base.length]!.title}`,
    }));
    const list = show("feed", { ...pullRequestsFixture, filters, items }, "block-1");
    expect(
      list.target.querySelector<HTMLElement>("[data-layout]")?.dataset.layout
    ).toBe("feed.list");
    expect(list.target.querySelectorAll("li")).toHaveLength(60);
    expect(nodesOf(list.target)).toBeLessThanOrEqual(390);

    // News rows with every field filled, at the most items news takes.
    const full = items.slice(0, 12).map((item) => ({
      ...item,
      brand: "github",
      excerpt: "Adds a list layout to feed cards",
      tags: ["feed", "cards", "ui"],
    }));
    const news = show(
      "feed",
      { ...pullRequestsFixture, filters, items: full },
      "block-1"
    );
    expect(
      news.target.querySelector<HTMLElement>("[data-layout]")?.dataset.layout
    ).toBe("feed.news");
    expect(nodesOf(news.target)).toBeLessThanOrEqual(270);
  });

  it("shows ISO times on the viewer's clock and keeps a label that is not one", () => {
    vi.setSystemTime(Date.parse("2026-10-05T04:00:00Z"));
    const data = {
      title: "Open pull requests",
      source: "GitHub",
      observedAt: "2026-10-05T03:17:00Z",
      items: [
        {
          source: "#2427",
          title: "Refresh usage after payment",
          at: "2026-10-04T10:15:00Z",
        },
        // Not an ISO time with an offset, so the label stands.
        {
          source: "#2424",
          title: "Recover proactive tasks",
          at: "10:15 UTC",
          time: "2 小时前",
        },
      ],
    };
    const shown = (timeZone: string) => {
      const target = document.createElement("section");
      document.body.append(target);
      const engine = cardEngine({
        seed: "block-1",
        locale: "zh-CN",
        timeZone,
        copy: {},
        icons: {},
        state: {},
        send: () => {},
      });
      target.replaceChildren(engine.mount(target, { kind: "feed", data }, "card"));
      return target;
    };

    const shanghai = shown("Asia/Shanghai");
    expect(shanghai.querySelector("footer")?.textContent).toContain("GitHub · 11:17");
    const [earlier, labeled] = [...shanghai.querySelectorAll("li")];
    expect(earlier!.textContent).toContain("#2427 · 10/4 18:15");
    expect(labeled!.textContent).toContain("#2424 · 2 小时前");
    // The same moment is yesterday in New York, so it carries its date.
    expect(shown("America/New_York").querySelector("footer")?.textContent).toContain(
      "GitHub · 10/4 23:17"
    );
  });

  it("shows an order's arrival moment on the viewer's clock and how far its stages got", () => {
    vi.setSystemTime(Date.parse("2026-10-29T02:00:00Z"));
    const target = document.createElement("section");
    document.body.append(target);
    const engine = cardEngine({
      seed: "block-1",
      locale: "zh-CN",
      timeZone: "Asia/Shanghai",
      copy: { arrivesBy: "预计 {time} 前送达", orderHeadline: "{status}，{arrival}" },
      icons: {},
      state: {},
      send: () => {},
    });
    const data = { ...orderFixture, arrivesBy: "2026-10-29T07:18:00Z" };
    target.replaceChildren(
      engine.mount(target, { kind: "order", data, variant: "compact" }, "card")
    );
    expect(target.textContent).toContain("正在出库，预计 15:18 前送达");
    // Order placed, now leaving the warehouse: the second of four stages.
    expect(target.querySelector("progress")?.value).toBe(33);
    engine.dispose();
  });

  it("shows each end of a ticket at its own place's clock", () => {
    const { target } = show("ticket", boardingPassFixture, "block-1", "ticket");
    // 08:40 in Shanghai and 12:55 in Tokyo, whatever the viewer's zone.
    const times = [...target.querySelectorAll(".wc-display-md")].map(
      (node) => node.textContent
    );
    expect(times).toEqual(["08:40", "12:55"]);
  });

  it("draws the media controls on a host that passes no icons, as phones do", () => {
    // show() mounts with icons: {}, as the iOS and Android hosts do.
    for (const variant of ["player", "queue"]) {
      const { target } = show("media", mediaFixture, "block-1", variant);
      const buttons = [...target.querySelectorAll("button")];
      expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual([
        "previous",
        "pause",
        "next",
      ]);
      for (const button of buttons)
        expect(button.querySelector("svg path")?.getAttribute("d")).toBeTruthy();
    }
  });

  it("offers every control a device has in the device grid", () => {
    const four = [1, 2, 3, 4].map((step) => ({
      label: `+${step}`,
      prompt: `raise ${step}`,
    }));
    const data = {
      ...devicesFixture,
      devices: [
        { ...devicesFixture.devices[0]!, controls: four },
        devicesFixture.devices[1]!,
      ],
    };
    const { target } = show("device", data, "block-1", "grid");
    const first = target.querySelector("li")!;
    expect(
      [...first.querySelectorAll("button")].map((button) => button.textContent)
    ).toEqual(["+1", "+2", "+3", "+4"]);
  });

  it("names the entry it cannot read instead of calling the list missing", () => {
    // The staging forecast that failed: temperatures as text with units.
    const day = {
      label: "Sun 27 Sep",
      condition: "rain",
      conditionLabel: "Scattered showers",
      high: "31°C",
      low: "25°C",
    };
    expect(() => show("forecast", { title: "Shanghai tomorrow", days: [day] })).toThrow(
      "Card data days[0] needs a label and numbers for high and low"
    );
    expect(() =>
      show("forecast", { title: "Shanghai", current: { temperature: "26°C" } })
    ).toThrow("Card data current.temperature needs a number");
    expect(() => show("forecast", { title: "Shanghai" })).toThrow(
      "Card data needs days or current weather"
    );
    expect(() =>
      show("feed", { title: "Pull requests", items: [{ title: "No source" }] })
    ).toThrow("Card data items[0] needs a source and a title");
  });
});

const twoReviews = (done: boolean) => ({
  title: "Launch",
  groups: [
    { label: "Docs", items: [{ label: "Review", done }] },
    { label: "Code", items: [{ label: "Review" }] },
  ],
});
const checked = (root: Element) =>
  [...root.querySelectorAll<HTMLInputElement>("input[type=checkbox]")].map(
    (box) => box.checked
  );
const mountChecklist = (
  key: string,
  state: unknown,
  send: (message: CardOutgoing) => void = () => {}
) => {
  const target = document.createElement("section");
  document.body.append(target);
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: {},
    state,
    send,
  });
  target.replaceChildren(
    engine.mount(
      target,
      { kind: "checklist", data: twoReviews(false), variant: "grouped" },
      key
    )
  );
  return { target, engine };
};

describe("numbers in cards", () => {
  it("shows which way a change went once, from its direction or its sign", () => {
    const { target } = show("metric", {
      title: "Traffic",
      metrics: [
        {
          label: "Visitors",
          value: "181",
          delta: { value: "-37.6%", direction: "down" },
        },
        { label: "Signups", value: "76", delta: { value: "+58.3%" } },
        { label: "Sessions", value: "197", delta: { value: "−37.5%" } },
        {
          label: "Bounce",
          value: "41%",
          delta: { value: "3%", direction: "down", good: true },
        },
      ],
    });
    expect(texts(target, ".wc-delta")).toEqual(["37.6%", "58.3%", "37.5%", "3%"]);
    // A fall reads as bad unless the data calls it good.
    expect(
      [...target.querySelectorAll(".wc-delta")].map((node) =>
        node.classList.contains("wc-text-error")
      )
    ).toEqual([true, false, true, false]);

    const watch = show(
      "trend",
      {
        title: "Holdings",
        series: [
          {
            label: "TSLA",
            value: "$412.90",
            points: [1, 2],
            delta: { value: "+4.85%" },
          },
          {
            label: "GOOGL",
            value: "$201.36",
            points: [2, 1],
            delta: { value: "-0.52%" },
          },
        ],
      },
      "block-1",
      "watchlist"
    );
    expect(texts(watch.target, ".wc-pill")).toEqual(["+4.85%", "−0.52%"]);
  });

  it("shows the metrics given beside a goal, and each tile's caption", () => {
    const { target } = show("metric", {
      title: "This week",
      goal: { current: 312, target: 300, valueLabel: "312 min", targetLabel: "of 300" },
      metrics: [
        { label: "Runs", value: "18.4", unit: "km", caption: "3 runs" },
        { label: "Sleep", value: "6 h 48 min" },
      ],
    });
    expect(target.textContent).toContain("312 min");
    expect(texts(target, ".wc-tile")).toEqual(["Runs18.4km3 runs", "Sleep6 h 48 min"]);
  });

  it("labels every bar of a short series, each with its value, and draws no unnamed line", () => {
    const labels = ["Direct", "google.com", "t.co", "bing.com", "github.com"];
    const { target } = show("trend", {
      title: "Top sources",
      bars: { labels, values: [118, 31, 17, 9, 8] },
    });
    expect(texts(target, ".wc-bars-axis>span")).toEqual(labels);
    expect(target.querySelector(".wc-bars-axis")!.classList).toContain(
      "wc-bars-axis-all"
    );
    expect(texts(target, ".wc-bars-value")).toEqual(["118", "31", "17", "9", "8"]);
    expect(target.querySelector(".wc-bars-average")).toBeNull();
    // No empty band stands where the data gives no main value or mean.
    expect(target.querySelector(".wc-bars-legend")!.classList).toContain("wc-sr");
    expect(target.querySelector(".wc-card")!.children).toHaveLength(2);
  });

  it("keeps every nth label of a long series, counted back from its latest bar", () => {
    const labels = Array.from({ length: 30 }, (_, day) => `10/${day + 1}`);
    const { target } = show("trend", {
      title: "Daily visitors",
      bars: {
        labels,
        values: labels.map((_, day) => 100 + day),
        averageLabel: "Mean 114",
      },
    });
    const ticks = [...target.querySelectorAll(".wc-bars-axis>span")];
    const kept = (name: string) =>
      ticks.filter((tick) => tick.classList.contains(`wc-tick-${name}`)).length;
    expect(ticks.at(-1)!.className).toBe("wc-tick-wide wc-tick-medium wc-tick-narrow");
    expect(kept("wide")).toBeGreaterThan(kept("medium"));
    expect(kept("medium")).toBeGreaterThan(kept("narrow"));
    expect(kept("narrow")).toBeGreaterThan(1);
    // Only the latest bar carries its value, over the named mean line.
    expect(texts(target, ".wc-bars-value")).toEqual(["129"]);
    expect(target.querySelector(".wc-bars-average")).not.toBeNull();
    expect(target.textContent).toContain("Mean 114");
  });

  it("shows ISO event times as clock times and heads each date", () => {
    const { target } = show(
      "schedule",
      {
        title: "Kyoto",
        zone: "Asia/Tokyo",
        events: [
          {
            start: "2026-11-14T00:00:00Z",
            end: "2026-11-14T02:30:00Z",
            title: "Fushimi Inari",
          },
          { start: "2026-11-15T08:30", title: "Bamboo grove" },
          { start: "2026-11-15T10:00:00+09:00", title: "Tenryu-ji" },
        ],
      },
      "block-1",
      "agenda"
    );
    // A moment shows in the schedule's zone; a time with no offset as written.
    expect(texts(target, ".wc-agenda-time")).toEqual(["09:00", "08:30", "10:00"]);
    expect(target.textContent).toContain("09:00–11:30");
    expect(texts(target, ".wc-day")).toEqual(["Sat, Nov 14", "Sun, Nov 15"]);

    // Text that is no ISO time stays as written, and one date needs no heading.
    const plain = show("schedule", {
      title: "Today",
      events: [{ start: "After lunch", title: "Review" }],
    });
    expect(plain.target.textContent).toContain("After lunch");
    expect(plain.target.querySelector(".wc-day")).toBeNull();
  });

  it("reads a status written as text and a total written as a number", () => {
    const feed = show("feed", {
      title: "Hosts",
      items: [{ source: "API", title: "salix-prod-1", status: "Healthy" }],
    });
    expect(feed.target.textContent).toContain("Healthy");

    const split = show(
      "composition",
      {
        title: "Holdings",
        total: 128460.32,
        segments: [
          { label: "NVDA", value: 29797.2, valueLabel: "$29,797.20 · 23.2%" },
          { label: "AAPL", value: 27105, valueLabel: "$27,105.00 · 21.1%" },
        ],
      },
      "block-1",
      "stacked"
    );
    expect(split.target.textContent).toContain("128,460.32");
    // Labels that state a percent get no second one.
    expect(split.target.querySelector(".wc-legend-share")).toBeNull();
    // A total that long does not fit the middle of a ring.
    expect(
      layoutsFor("composition", {
        title: "Holdings",
        total: 128460.32,
        segments: [{ label: "NVDA", value: 1 }],
      })
    ).toEqual(new Set(["stacked"]));
  });
});

describe("bars card", () => {
  it("draws each item's bar, the value it is compared with, and its change", () => {
    const { target } = show("bars", eventBarsFixture, "block-1", "rows");
    expect(texts(target, ".wc-rank-legend>span:not(.wc-rank-swatch)")).toEqual([
      "昨日",
      "前天",
    ]);
    expect(texts(target, ".wc-rank-values").slice(0, 2)).toEqual([
      "764858.3%",
      "324528.9%",
    ]);
    // Both series share one scale: the largest value of either is a full bar.
    expect(shares(target).slice(-4)).toEqual([
      ["brand", 72],
      ["compare", 100],
      ["brand", 63],
      ["compare", 71],
    ]);
  });

  it("scales bars to the stated full value and colors them by tone", () => {
    const { target } = show("bars", progressBarsFixture, "block-1", "rows");
    expect(shares(target)).toEqual([
      ["brand", 46],
      ["success", 80],
      ["warning", 22],
      ["error", 0],
    ]);
    expect(target.textContent).toContain("有风险");
  });

  it("stands bars upright only for a few short labels with values alone", () => {
    expect(layoutsFor("bars", ratingBarsFixture)).toEqual(
      new Set(["rows", "compact", "columns"])
    );
    const columns = show("bars", ratingBarsFixture, "block-1", "columns");
    expect(texts(columns.target, ".wc-bars-axis>span")).toEqual([
      "5 星",
      "4 星",
      "3 星",
      "2 星",
      "1 星",
    ]);
    expect(texts(columns.target, ".wc-bars-value")).toEqual([
      "962",
      "187",
      "61",
      "28",
      "46",
    ]);
    expect(columns.target.querySelector(".wc-bar-latest")).toBeNull();
    // A compared value or a caption needs a row.
    expect(layoutsFor("bars", eventBarsFixture)).toEqual(new Set(["rows", "compact"]));
    expect(layoutsFor("bars", funnelBarsFixture)).toEqual(new Set(["rows"]));
  });

  it("draws a stated full value at one scale in every layout it can take", () => {
    // Upright bars scale to their tallest. With max 100, a 20 and a 40 drew
    // as 40% and 80% there and as 20% and 40% in rows, by the layout picked.
    const progress = {
      title: "Goals",
      max: 100,
      items: [
        { label: "A", value: 20 },
        { label: "B", value: 40 },
      ],
    };
    expect(layoutsFor("bars", progress)).toEqual(new Set(["rows", "compact"]));
    for (const variant of ["rows", "compact", "columns"])
      expect(
        shares(show("bars", progress, "block-1", variant).target),
        variant
      ).toEqual([
        ["brand", 20],
        ["brand", 40],
      ]);
    // Without max the same items may stand upright.
    const { max: _max, ...free } = progress;
    expect(layoutsFor("bars", free)).toContain("columns");
  });

  it("lays a value under zero on the other side of zero from one over it", () => {
    const { target } = show(
      "bars",
      {
        title: "Net change",
        items: [
          { label: "Gained", value: 30 },
          { label: "Lost", value: -10 },
        ],
      },
      "block-1",
      "rows"
    );
    // The track runs from -10 to 30: zero is a quarter along it.
    const tracks = [...target.querySelectorAll<HTMLElement>(".wc-rank-track")].map(
      (track) =>
        ["--wc-from", "--wc-share"].map((name) =>
          Number.parseFloat(track.style.getPropertyValue(name) || "0")
        )
    );
    expect(tracks).toEqual([
      [25, 75],
      [0, 25],
    ]);
    expect(texts(target, ".wc-rank-values")).toEqual(["30", "-10"]);
  });

  it("stays within the node count the Worker manual names", () => {
    const items = Array.from({ length: 12 }, (_, index) => ({
      label: `Step ${index}`,
      value: 100 - index,
      compare: 90 - index,
      delta: { value: "3%", direction: "down" },
      caption: "Conversion 62.1% · median 11 min",
      status: { label: "Behind", tone: "warning" },
      brand: "github",
    }));
    const { target } = show(
      "bars",
      { title: "Funnel", legend: { value: "Now", compare: "Before" }, items },
      "block-1",
      "rows"
    );
    expect(target.querySelectorAll("li")).toHaveLength(12);
    expect(nodesOf(target)).toBeLessThanOrEqual(400);
  });
});

describe("table card", () => {
  it("reads numbers down their right edge, colors toned cells and keeps empty ones", () => {
    const board = show("table", leaderboardTableFixture);
    // Counts and amounts are numbers; a name and an arrow are not.
    expect(ends(board.target)).toEqual([false, true, true, false]);
    expect(board.target.querySelector(".wc-text-success")!.textContent).toBe("↑2");
    expect(board.target.querySelectorAll("tbody th[scope=row]")).toHaveLength(6);

    const cohort = show("table", cohortTableFixture);
    // A column may have no heading; a cell may have no value yet.
    expect(cohort.target.querySelectorAll("thead th")).toHaveLength(8);
    expect(cohort.target.querySelectorAll("tbody td:empty")).toHaveLength(15);
    expect(ends(cohort.target)).toEqual([false, ...Array<boolean>(7).fill(true)]);
    // An empty text is an empty cell, as null is.
    const holdings = show("table", {
      title: "Holdings",
      columns: ["Asset", "Shares", "Value"],
      rows: [
        ["NVDA", 40, "$9,932"],
        ["Cash", "", "$1,200"],
      ],
    });
    expect(holdings.target.querySelectorAll("tbody td:empty")).toHaveLength(1);
    expect(ends(holdings.target)).toEqual([false, true, true]);
  });

  it("shows a number with the decimals it has", () => {
    // Two decimals at most turned 0.001 and 0.004 into the same 0.
    const { target } = show("table", {
      title: "Readings",
      columns: ["Sample", "Value"],
      rows: [
        ["A", 0.001],
        ["B", 0.004],
        ["C", 1234.5678],
        ["D", 0.1 + 0.2],
      ],
    });
    expect(texts(target, "tbody td")).toEqual(["0.001", "0.004", "1,234.5678", "0.3"]);
  });

  it("names the row it cannot read and stays within the node count", () => {
    expect(() =>
      show("table", { title: "Orders", columns: ["Order", "Amount"], rows: [["#1"]] })
    ).toThrow("Card data rows[0] needs one cell per column, the first naming the row");

    // The most rows and columns a table holds.
    const rows = Array.from({ length: 24 }, (_, row) => [
      `Row ${row}`,
      1,
      2,
      3,
      4,
      5,
      { text: "Late", tone: "error" },
      null,
    ]);
    const { target } = show("table", {
      title: "Hosts",
      columns: ["Host", "CPU", "Memory", "Disk", "Load", "Net", "Status", "Note"],
      rows,
    });
    expect(target.querySelectorAll("tbody tr")).toHaveLength(24);
    expect(target.querySelectorAll("tbody tr:first-child > *")).toHaveLength(8);
    expect(nodesOf(target)).toBeLessThanOrEqual(450);
  });
});

describe("comma.chart drawing", () => {
  const draw = (spec: Parameters<ReturnType<typeof chartEngine>["chart"]>[0]) => {
    const figure = document.createElement("figure");
    figure.append(chartEngine().chart(spec));
    document.body.append(figure);
    return figure;
  };

  it("stands a few bars upright with every label and value", () => {
    const figure = draw({
      type: "bar",
      labels: ["Mon", "Tue", "Wed"],
      series: [{ name: "", values: [8412, 11205, 6034] }],
    });
    expect(
      [...figure.querySelectorAll(".wc-bars-axis>span")].map((n) => n.textContent)
    ).toEqual(["Mon", "Tue", "Wed"]);
    expect(
      [...figure.querySelectorAll(".wc-bars-value")].map((n) => n.textContent)
    ).toEqual(["8,412", "11,205", "6,034"]);
  });

  it("turns bars sideways when their labels do not fit under them", () => {
    // The daily report that drew fourteen paired bars and lost half their labels.
    const labels = [
      "注册",
      "工作区",
      "下载",
      "网站App",
      "桌面",
      "任务",
      "客户端",
    ].flatMap((name) => [`${name}·昨`, `${name}·前`]);
    const values = [76, 48, 32, 45, 26, 29, 40, 44, 75, 80, 206, 285, 179, 201];
    const figure = draw({ type: "bar", labels, series: [{ name: "", values }] });
    const rows = [...figure.querySelectorAll("li")];
    expect(rows.map((row) => row.firstElementChild!.textContent)).toEqual(labels);
    expect(rows.map((row) => row.lastElementChild!.textContent)).toEqual(
      values.map(String)
    );
  });

  it("draws a value under zero as a bar under the zero line, in each bar drawing", () => {
    // Upright: a loss and a gain of one size are bars of one height, the loss
    // from the foot of the plot up to the zero line the gain stands on.
    const upright = draw({
      type: "bar",
      labels: ["A", "B", "C"],
      series: [{ name: "", values: [-10, 0, 10] }],
    });
    const bars = upright.querySelectorAll<HTMLElement>(".wc-bar-col");
    expect(numbers(bars, (bar) => bar.style.height)).toEqual([40, 0, 40]);
    expect(numbers(bars, (bar) => bar.style.getPropertyValue("--wc-lift"))).toEqual([
      0, 0.4, 0.4,
    ]);
    expect(upright.querySelector<HTMLElement>(".wc-bars-zero")!.style.bottom).toBe(
      "40%"
    );
    expect(texts(upright, ".wc-bars-value")).toEqual(["-10", "0", "10"]);

    // Side by side: each series keeps its side of zero.
    const grouped = draw({
      type: "bar",
      labels: ["Q1", "Q2"],
      series: [
        { name: "Profit", values: [5, -5] },
        { name: "Cash", values: [10, -10] },
      ],
    });
    const pairs = grouped.querySelectorAll<HTMLElement>(".wc-bar-col");
    expect(numbers(pairs, (bar) => bar.style.height)).toEqual([25, 50, 25, 50]);
    expect(numbers(pairs, (bar) => bar.style.getPropertyValue("--wc-lift"))).toEqual([
      0.5, 0.5, 0.25, 0,
    ]);
    expect(grouped.querySelector(".wc-bars-zero")).not.toBeNull();

    // Sideways, for labels that do not fit under bars.
    const regions = [
      "North America",
      "Latin America",
      "Western Europe",
      "Eastern Europe",
      "Middle East",
      "South Asia",
      "East Asia",
      "Oceania",
      "Africa",
    ];
    const sideways = draw({
      type: "bar",
      labels: regions,
      series: [{ name: "", values: [12, -6, 3, -12, 0, 6, 9, -3, 1] }],
    });
    const tracks = [...sideways.querySelectorAll<HTMLElement>(".wc-rank-track")];
    expect(tracks).toHaveLength(9);
    expect(
      numbers(tracks.slice(0, 2), (t) => t.style.getPropertyValue("--wc-share"))
    ).toEqual([50, 25]);
    expect(
      numbers(tracks.slice(0, 2), (t) => t.style.getPropertyValue("--wc-from"))
    ).toEqual([50, 25]);

    // Nothing under zero: the bars stand on the foot of the plot, with no line.
    expect(
      draw({
        type: "bar",
        labels: ["A", "B"],
        series: [{ name: "", values: [1, 2] }],
      }).querySelector(".wc-bars-zero")
    ).toBeNull();
  });

  it("names several series beside their colors, for bars and for lines", () => {
    const series = [
      { name: "Budget", values: [420, 180] },
      { name: "Actual", values: [451.3, 139.6] },
    ];
    for (const type of ["bar", "line"] as const) {
      const figure = draw({ type, labels: ["R&D", "Marketing"], series });
      expect(
        [...figure.querySelectorAll(".wc-rank-legend>span:not(.wc-rank-swatch)")].map(
          (n) => n.textContent
        )
      ).toEqual(["Budget", "Actual"]);
    }
    expect(
      draw({ type: "bar", labels: ["R&D", "Marketing"], series }).querySelectorAll(
        ".wc-bar-col"
      )
    ).toHaveLength(4);
    expect(
      draw({ type: "line", labels: ["R&D", "Marketing"], series }).querySelectorAll(
        "svg path[stroke]"
      )
    ).toHaveLength(2);
  });
});

describe("checklist progress", () => {
  it("does not assign a duplicate label the saved id of another row", () => {
    const data = twoReviews(false);
    const { target } = show(
      "checklist",
      {
        ...data,
        groups: [
          ...data.groups,
          { label: "Audit", items: [{ id: "Review#2", label: "Audit" }] },
        ],
      },
      "block-1",
      "grouped",
      { card: ["Review#2"] }
    );
    expect(checked(target)).toEqual([false, false, true]);
    expect(target.textContent).toContain("1 of 3 done");
  });

  it("keeps rows that share a label apart", () => {
    const { target } = show("checklist", twoReviews(true), "block-1", "grouped");
    expect(checked(target)).toEqual([true, false]);
    expect(target.textContent).toContain("1 of 2 done");
  });

  it("treats element ids such as constructor as plain keys", () => {
    for (const key of ["constructor", "toString", "__proto__"]) {
      // Without saved progress, a plain object read the inherited member.
      expect(checked(mountChecklist(key, {}).target)).toEqual([false, false]);
      const saved: unknown = JSON.parse(`{"${key}":["Review#2"]}`);
      expect(checked(mountChecklist(key, saved).target)).toEqual([false, true]);
    }
  });

  it("shows progress another copy saved without sending it back", () => {
    const sent: CardOutgoing[] = [];
    const { target, engine } = mountChecklist("card", {}, (message) =>
      sent.push(message)
    );
    expect(checked(target)).toEqual([false, false]);
    engine.receiveState({ card: ["Review#2"] });
    expect(checked(target)).toEqual([false, true]);
    expect(target.textContent).toContain("1 of 2 done");
    expect(sent).toEqual([]);
  });

  it("proposes an item's follow-up without checking the item off", () => {
    const sent: CardOutgoing[] = [];
    const target = document.createElement("section");
    document.body.append(target);
    const engine = cardEngine({
      seed: "block-1",
      locale: "en",
      copy: {},
      icons: {},
      state: {},
      send: (message) => sent.push(message),
    });
    const data = {
      title: "Today",
      groups: [
        {
          items: [
            {
              label: "Review the PLM library with Wei",
              actions: [
                { label: "Calendar", prompt: "Add the PLM review to my calendar" },
                { label: "Routine", prompt: "Add the PLM review to my Routine" },
              ],
            },
          ],
        },
      ],
    };
    target.replaceChildren(engine.mount(target, { kind: "checklist", data }, "card"));
    const more = target.querySelector<HTMLButtonElement>(".wc-check-more")!;
    expect(more.getAttribute("aria-label")).toBe("Calendar / Routine");
    expect(target.querySelector(".wc-check-actions")).toBeNull();
    more.click();
    expect(more.getAttribute("aria-expanded")).toBe("true");
    const button = [...target.querySelectorAll("button")].find(
      (node) => node.textContent === "Routine"
    )!;
    button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    // jsdom marks dispatched events untrusted, as the card does for scripts.
    expect(sent).toEqual([]);
    expect(checked(target)).toEqual([false]);
    expect(button.closest("label")).toBeNull();
    engine.dispose();
  });

  it("keeps a full checklist with item actions within the card node count", () => {
    const actions = ["Calendar", "Reminders", "Routine"].map((label) => ({
      label,
      prompt: `Add this to my ${label}`,
    }));
    const items = Array.from({ length: 5 }, (_, index) => ({
      label: `Confirm the 16:00 review ${index}`,
      detail: "From Wei · private chat",
      actions,
    }));
    const { target } = show(
      "checklist",
      { title: "Today", groups: [{ items }, { items }, { items }, { items }] },
      "block-1",
      "grouped"
    );
    expect(target.textContent).toContain("0 of 20 done");
    expect(target.querySelectorAll(".wc-check-more")).toHaveLength(20);
    expect(nodesOf(target)).toBeLessThanOrEqual(390);
    // One item's actions show at a time.
    const folds = [...target.querySelectorAll<HTMLButtonElement>(".wc-check-more")];
    folds[0]!.click();
    folds[1]!.click();
    expect(
      target.querySelectorAll(".wc-check-actions:not([hidden]) button")
    ).toHaveLength(3);
    expect(folds[0]!.getAttribute("aria-expanded")).toBe("false");
    expect(nodesOf(target)).toBeLessThanOrEqual(390);
  });

  it("rejects kinds that exist only on Object.prototype with a readable reason", () => {
    expect(() => show("constructor", { title: "Launch" })).toThrow(
      /Unsupported card kind/
    );
  });

  it("applies progress saved under a shared label to its first row only", () => {
    const target = document.createElement("section");
    document.body.append(target);
    const engine = cardEngine({
      seed: "block-1",
      locale: "en",
      copy: {},
      icons: {},
      state: { card: ["Review"] },
      send: () => {},
    });
    target.replaceChildren(
      engine.mount(
        target,
        { kind: "checklist", data: twoReviews(false), variant: "grouped" },
        "card"
      )
    );
    expect(checked(target)).toEqual([true, false]);
  });
});

describe("brand logos", () => {
  it.each([
    ["linear", "github"],
    ["github", "linear"],
  ])(
    "keeps overlapping requests independent when %s arrives before %s",
    async (first, second) => {
      const sent: CardOutgoing[] = [];
      const engine = cardEngine({
        seed: "overlap",
        locale: "en",
        copy: {},
        icons: {},
        state: {},
        send: (message) => sent.push(message),
      });
      const targets = new Map<string, HTMLElement>();
      for (const brand of ["linear", "github"]) {
        const target = document.createElement("section");
        document.body.append(target);
        target.replaceChildren(
          engine.mount(
            target,
            {
              kind: "feed",
              data: {
                title: brand,
                groups: [{ source: brand, brand, summary: "Update", count: 1 }],
              },
              variant: "digest",
            },
            brand
          )
        );
        targets.set(brand, target);
        await Promise.resolve();
      }
      expect(sent).toEqual([
        { type: "brand-icons", names: ["linear"] },
        { type: "brand-icons", names: ["github"] },
      ]);
      engine.receiveIcons({ [first]: '<svg data-logo="' + first + '"></svg>' });
      engine.receiveIcons({ [second]: '<svg data-logo="' + second + '"></svg>' });
      for (const brand of ["linear", "github"])
        expect(
          targets.get(brand)!.querySelector("[data-logo]")?.getAttribute("data-logo")
        ).toBe(brand);
      engine.dispose();
    }
  );

  it("shows a logo only for brands the host answers and initials for the rest", async () => {
    const sent: CardOutgoing[] = [];
    const engine = cardEngine({
      seed: "block-1",
      locale: "en",
      copy: {},
      icons: {},
      state: {},
      send: (message) => sent.push(message),
    });
    const data = {
      title: "Since you left",
      groups: [
        {
          source: "Linear",
          brand: "linear",
          count: 5,
          summary: "REL-128 moved to rollout",
        },
        {
          source: "Acme",
          brand: "acme",
          count: 2,
          summary: "Two invoices need approval",
        },
      ],
    };
    const showDigest = (key: string) => {
      const target = document.createElement("section");
      document.body.append(target);
      target.replaceChildren(
        engine.mount(target, { kind: "feed", data, variant: "digest" }, key)
      );
      return [...target.querySelectorAll<HTMLElement>("[data-initial]")];
    };

    const first = showDigest("first");
    await Promise.resolve();
    expect(sent).toEqual([{ type: "brand-icons", names: ["linear", "acme"] }]);
    engine.receiveIcons({ linear: '<svg data-logo="linear"></svg>', acme: "" });
    expect(first.map((tile) => tile.querySelector("[data-logo]") !== null)).toEqual([
      true,
      false,
    ]);
    expect(first[1]!.textContent).toBe("A");

    // A card drawn after the answer reuses it without asking again.
    const second = showDigest("second");
    await Promise.resolve();
    expect(sent).toHaveLength(1);
    expect(second[0]!.querySelector("[data-logo]")).not.toBeNull();
    expect(second[1]!.textContent).toBe("A");
  });
});

describe("timer card", () => {
  const start = new Date("2026-09-23T10:00:00.000Z");
  const running = {
    title: "Focus",
    label: "Quarterly review",
    endsAt: new Date(start.getTime() + 3000).toISOString(),
    totalSeconds: 1500,
  };

  it("keeps a paused remaining duration static", () => {
    vi.setSystemTime(start);
    const { target, engine } = show(
      "timer",
      {
        title: "Focus",
        label: "Quarterly review",
        remainingSeconds: 3,
        paused: true,
      },
      "block-1",
      "countdown"
    );
    vi.advanceTimersByTime(4000);
    expect(target.querySelector("time")?.textContent).toBe("00:03");
    expect(target.textContent).toContain("Paused");
    expect(vi.getTimerCount()).toBe(0);
    engine.dispose();
  });

  it("counts down on its own clock and releases the clock at zero", () => {
    vi.setSystemTime(start);
    const { target } = show("timer", running, "block-1", "countdown");
    const shown = () => target.querySelector("time")?.textContent;

    expect(shown()).toBe("00:03");
    vi.advanceTimersByTime(1100);
    expect(shown()).toBe("00:02");
    vi.advanceTimersByTime(2000);

    expect(target.textContent).toContain("Time's up");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("releases the clock when an update replaces the card", () => {
    vi.setSystemTime(start);
    const { target } = show(
      "timer",
      { ...running, endsAt: new Date(start.getTime() + 60_000).toISOString() },
      "block-1",
      "countdown"
    );
    expect(vi.getTimerCount()).toBe(1);

    target.replaceChildren("Replaced");
    vi.advanceTimersByTime(1100);

    expect(vi.getTimerCount()).toBe(0);
  });
});
