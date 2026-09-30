import { afterEach, describe, expect, it, vi } from "vitest";
import { cardEngine, type CardOutgoing } from "../cards";
import {
  checklistFixture,
  comparisonFixture,
  forecastFixture,
  groupedChecklistFixture,
  hotelOptionsFixture,
  newsFixture,
  placeFixture,
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

function layoutOf(kind: string, data: unknown, seed: string, variant?: string) {
  const { target, engine } = show(kind, data, seed, variant);
  const layout = target.querySelector<HTMLElement>("[data-layout]")?.dataset.layout;
  engine.dispose();
  target.remove();
  return layout?.slice(kind.length + 1);
}

const layoutsFor = (kind: string, data: unknown, variant?: string) =>
  new Set(seeds.map((seed) => layoutOf(kind, data, seed, variant)));

afterEach(() => {
  vi.useRealTimers();
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

    const items = Array.from({ length: 6 }, () => ({ label: "Task" }));
    const checklist = show("checklist", {
      title: "Tasks",
      groups: [{ items }, { items: [...items, {}] }, { items: [{}] }],
    });
    expect(checklist.target.textContent).toContain("0 of 12 done");
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
    vi.useFakeTimers();
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
    vi.useFakeTimers();
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
    vi.useFakeTimers();
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
