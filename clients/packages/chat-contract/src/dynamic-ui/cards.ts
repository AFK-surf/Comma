/// <reference lib="dom" />
import type { CardCopy } from "./cardTypes";

export type CardOutgoing =
  | { type: "request"; value: string }
  | { type: "card-state"; value: Record<string, string[]> }
  | { type: "brand-icons"; names: string[] };

export interface CardEnv {
  /** Stable identity of the widget; with the element id it picks each card's layout. */
  seed: string;
  locale: string;
  /** Localized chrome text; missing entries fall back to English. */
  copy: Partial<CardCopy>;
  /** Host-rendered SVG glyphs the templates draw with. */
  icons: Record<string, string>;
  /** Template state saved on this device, e.g. checklist progress. */
  state: unknown;
  send(message: CardOutgoing): void;
}

export interface CardEngine {
  /** Builds a card for `target`; throws a readable error for unusable data. */
  mount(
    target: HTMLElement,
    spec: { kind: unknown; data: unknown; variant?: unknown },
    key: string
  ): DocumentFragment;
  receiveIcons(icons: unknown): void;
  /** Progress that another open copy of this widget saved. */
  receiveState(state: unknown): void;
  dispose(): void;
}

/**
 * Card templates for `comma.card`. The runtime serializes this function into the
 * sandboxed iframe, so every helper stays inside it and it reads only globals.
 * Generated data never becomes markup: text is set as text, links must be
 * HTTPS, and every list is bounded so a card stays inside the node budget.
 */
/* oxlint-disable unicorn/consistent-function-scoping -- the runtime serializes cardEngine, so its helpers must live inside it. */
export function cardEngine(env: CardEnv): CardEngine {
  const english: CardCopy = {
    recommended: "Recommended",
    alternatives: "Other options",
    high: "H",
    low: "L",
    feelsLike: "Feels like",
    humidity: "Humidity",
    ongoing: "Now",
    directions: "Directions",
    range: "Range",
    days: "days",
    attribute: "Attribute",
    option: "Option",
    versus: "VS",
    checklistProgress: "{done} of {total} done",
    focus: "Focus",
    rest: "Break",
    paused: "Paused",
    timeUp: "Time's up",
    timerCycle: "Session {current} of {total}",
  };
  const copy: CardCopy = { ...english };
  for (const name of Object.keys(english) as Array<keyof CardCopy>) {
    const localized = env.copy?.[name];
    if (
      typeof localized === "string" &&
      localized.length > 0 &&
      localized.length <= 120
    )
      copy[name] = localized;
  }
  type Tone = "neutral" | "brand" | "success" | "warning" | "error";
  type Child = Node | string | false | null | undefined;
  type Delta = { value: string; direction: "up" | "down" | "flat"; good: boolean };
  type Frame = {
    title: string;
    meta?: string | undefined;
    source?: string | undefined;
    sourceBrand?: string | undefined;
    updatedAt?: string | undefined;
    actions: Array<{ label: string; prompt: string }>;
  };
  type Built = { root: HTMLElement; cleanup?: () => void; sync?: () => void };

  // ---------------------------------------------------------------- DOM
  const cx = (...names: Array<string | false | null | undefined>) =>
    names.filter(Boolean).join(" ");
  const put = <T extends ParentNode>(node: T, children: Child[]) => {
    for (const child of children) if (child) node.append(child);
    return node;
  };
  const h = (tag: string, className?: string | false | null, ...children: Child[]) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    put(node, children);
    return node;
  };
  const hidden = <T extends Element>(node: T) => {
    node.setAttribute("aria-hidden", "true");
    return node;
  };
  const sr = (text: string) => h("span", "wc-sr", text);
  const svg = (
    tag: string,
    attributes: Record<string, string | number>,
    ...children: Node[]
  ) => {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [name, value] of Object.entries(attributes))
      node.setAttribute(name, String(value));
    node.append(...children);
    return node;
  };
  const markup = (node: Element, source: string) => {
    const template = document.createElement("template");
    template.innerHTML = source;
    node.replaceChildren(template.content.cloneNode(true));
  };
  const icon = (name: string, className?: string | false) => {
    const node = hidden(h("span", cx("wc-icon", className)));
    const source = env.icons[name];
    if (typeof source === "string") markup(node, source);
    return node;
  };
  const fill = (template: string, values: Record<string, string | number>) =>
    template.replace(/\{(\w+)\}/g, (_, name: string) => String(values[name] ?? ""));
  // SVG ids are document-wide; a prefix keeps two engines on one page apart.
  const idPrefix = `wc${Math.random().toString(36).slice(2, 8)}`;
  let serial = 0;
  const nextId = () => `${idPrefix}-${++serial}`;

  // ---------------------------------------------------------- data guards
  const fail = (message: string): never => {
    throw new Error(message);
  };
  const isRecord = (value: unknown): value is Record<string, unknown> =>
    typeof value === "object" && value !== null && !Array.isArray(value);
  const text = (value: unknown, max = 200) =>
    typeof value === "string" && value.trim() ? value.slice(0, max) : undefined;
  const need = (value: unknown, field: string, max = 200) =>
    text(value, max) ?? fail(`Card data needs ${field}`);
  const num = (value: unknown) =>
    typeof value === "number" && Number.isFinite(value) ? value : undefined;
  const list = <T>(
    value: unknown,
    max: number,
    map: (item: unknown) => T | undefined
  ) =>
    Array.isArray(value)
      ? value
          .slice(0, max)
          .map(map)
          .filter((item): item is T => item !== undefined)
      : [];
  const numbers = (value: unknown, max: number) =>
    list(value, max, (item) => num(item));
  /**
   * Why a list the card needs came out empty although the data has entries:
   * every entry was skipped, so the first one lacks what the card reads.
   */
  const unread = (value: unknown, name: string, needs: string) =>
    Array.isArray(value) && value.length > 0
      ? `Card data ${name}[0] needs ${needs}`
      : undefined;
  const tones: Tone[] = ["neutral", "brand", "success", "warning", "error"];
  const toneOf = (value: unknown): Tone =>
    tones.includes(value as Tone) ? (value as Tone) : "neutral";
  const brandOf = (value: unknown) =>
    typeof value === "string" && /^[a-z0-9-]{1,40}$/.test(value) ? value : undefined;
  const httpsOf = (value: unknown) => {
    if (typeof value !== "string") return undefined;
    try {
      const url = new URL(value);
      return url.protocol === "https:" && !url.username && !url.password
        ? url.href
        : undefined;
    } catch {
      return undefined;
    }
  };
  const deltaOf = (value: unknown): Delta | undefined =>
    isRecord(value) && text(value.value, 40)
      ? {
          value: text(value.value, 40)!,
          direction:
            value.direction === "down" || value.direction === "flat"
              ? value.direction
              : "up",
          good: value.good !== false,
        }
      : undefined;
  const statusOf = (value: unknown) =>
    isRecord(value) && text(value.label, 40)
      ? { label: text(value.label, 40)!, tone: toneOf(value.tone) }
      : undefined;
  const frameOf = (data: Record<string, unknown>): Frame => ({
    title: need(data.title, "a title"),
    meta: text(data.meta, 60),
    source: text(data.source, 120),
    sourceBrand: brandOf(data.sourceBrand),
    updatedAt: text(data.updatedAt, 60),
    actions: list(data.actions, 2, (action) =>
      isRecord(action) && text(action.label, 40) && text(action.prompt, 4000)
        ? { label: text(action.label, 40)!, prompt: text(action.prompt, 4000)! }
        : undefined
    ),
  });

  let formatCompact: (value: number) => string;
  try {
    const format = new Intl.NumberFormat(env.locale || undefined, {
      notation: "compact",
      // Same precision in every locale: 63.2K and 6.32万.
      maximumSignificantDigits: 3,
    });
    formatCompact = (value) => format.format(value);
  } catch {
    formatCompact = (value) => String(Math.round(value));
  }

  // ------------------------------------------------------------- icons
  const brandIcons = new Map<string, string>();
  const waiting = new Map<string, Set<HTMLElement>>();
  const asked = new Set<string>();
  const queued = new Set<string>();
  /** A logo fills its tile. Without one, a tile shows its initial and a glyph hides. */
  const settle = (node: HTMLElement, source: string, arrived: boolean) => {
    if (source) {
      markup(node, source);
      if (arrived) node.classList.add("wc-arrive");
    } else if (node.dataset.initial !== undefined)
      node.textContent = node.dataset.initial;
    else node.hidden = true;
  };
  const place = (node: HTMLElement, brand: string) => {
    const known = brandIcons.get(brand);
    if (known !== undefined) {
      settle(node, known, false);
      return;
    }
    let targets = waiting.get(brand);
    if (!targets) waiting.set(brand, (targets = new Set()));
    targets.add(node);
    if (asked.has(brand)) return;
    if (!queued.size)
      queueMicrotask(() => {
        const names = [...queued];
        queued.clear();
        for (const name of names) asked.add(name);
        if (names.length) env.send({ type: "brand-icons", names });
      });
    queued.add(brand);
  };
  /** A known brand's logo on a neutral tile; anything else gets a monogram of the same size. */
  const avatarTones = ["blue", "purple", "success", "orange", "pink", "indigo"];
  const initialOf = (name: string) => [...name][0] ?? "";
  const mark = (
    brand: string | undefined,
    name: string,
    size: "sm" | "md" | "lg" = "md"
  ) => {
    if (!brand) {
      const hash = [...name].reduce((sum, char) => sum + (char.codePointAt(0) ?? 0), 0);
      return hidden(
        h(
          "span",
          `wc-mark wc-mark-${size} wc-avatar-${avatarTones[hash % avatarTones.length]}`,
          initialOf(name)
        )
      );
    }
    const tile = hidden(h("span", `wc-mark wc-mark-${size} wc-brand`));
    tile.dataset.initial = initialOf(name);
    place(tile, brand);
    return tile;
  };

  // --------------------------------------------------------- primitives
  const badge = (label: string, color: "brand" | "gray") =>
    h("span", `wc-badge wc-badge-${color}`, label);
  const dot = (tone: Tone) => hidden(h("span", `wc-dot wc-dot-${tone}`));
  const status = (value: { label: string; tone: Tone }) =>
    h("span", `wc-status wc-text-${value.tone}`, dot(value.tone), value.label);
  const insight = (value: string) => h("p", "wc-insight", value);
  const delta = (value: Delta, className?: string) =>
    h(
      "span",
      cx(
        "wc-delta",
        `wc-text-${value.direction === "flat" ? "neutral" : value.good ? "success" : "error"}`,
        className
      ),
      value.direction !== "flat" &&
        icon("arrow-up", value.direction === "down" && "wc-down"),
      value.value
    );
  const weatherIcons: Record<string, [string, string]> = {
    clear: ["sun", "wc-wx-sun"],
    "clear-night": ["moon", "wc-wx-moon"],
    "partly-cloudy": ["partly-cloudy", "wc-wx-sun"],
    cloudy: ["cloud", "wc-wx-cloud"],
    rain: ["rain", "wc-wx-rain"],
    snow: ["snow", "wc-wx-snow"],
  };
  const conditionOf = (value: unknown) =>
    typeof value === "string" && value in weatherIcons ? value : "cloudy";
  const weather = (condition: string, label: string, className: string) => {
    const [name, tone] = weatherIcons[condition] ?? ["cloud", "wc-wx-cloud"];
    return h("span", cx("wc-wx", tone, className), icon(name), sr(label));
  };

  const scale = (points: number[], height: number, inset: number) => {
    const min = Math.min(...points);
    const max = Math.max(...points);
    const pad = (max - min || Math.abs(max) || 1) * 0.12;
    const low = min - pad;
    const high = max + pad;
    return (value: number) =>
      inset + (1 - (value - low) / (high - low)) * (height - inset * 2);
  };
  const linePath = (values: number[], y: (value: number) => number, width: number) => {
    const step = values.length > 1 ? width / (values.length - 1) : 0;
    return values
      .map(
        (value, index) =>
          `${index ? "L" : "M"}${(index * step).toFixed(2)},${y(value).toFixed(2)}`
      )
      .join(" ");
  };
  // Every range draws the same number of vertices, so `d` interpolates between ranges.
  const resample = (points: number[], count: number) =>
    Array.from({ length: count }, (_, index) => {
      const position = (index / (count - 1)) * (points.length - 1);
      const lower = Math.floor(position);
      const from = points[lower] ?? 0;
      return from + ((points[lower + 1] ?? from) - from) * (position - lower);
    });
  const gradient = (id: string, ink: string, opacity: number) =>
    svg(
      "defs",
      {},
      svg(
        "linearGradient",
        { id, x1: 0, x2: 0, y1: 0, y2: 1 },
        svg("stop", { offset: "0%", "stop-color": ink, "stop-opacity": opacity }),
        svg("stop", { offset: "100%", "stop-color": ink, "stop-opacity": 0 })
      )
    );
  const ink = {
    brand: "var(--color-bg-brand-solid)",
    success: "var(--color-fg-success-primary)",
    error: "var(--color-fg-error-primary)",
    muted: "var(--color-utility-gray-300)",
  };
  const seriesInk = [
    "var(--color-bg-brand-solid)",
    "var(--color-utility-purple-300)",
    "var(--color-utility-success-300)",
    "var(--color-utility-warning-300)",
    "var(--color-utility-pink-300)",
    "var(--color-utility-gray-300)",
  ];

  const sparkline = (
    points: number[],
    stroke: string,
    options: { area?: boolean; endDot?: boolean; className: string }
  ) => {
    const box = hidden(h("div", cx("wc-spark", options.className)));
    const y = scale(points, 32, 2);
    const path = linePath(points, y, 100);
    const id = nextId();
    box.append(
      svg(
        "svg",
        { class: "wc-spark-svg", viewBox: "0 0 100 32", preserveAspectRatio: "none" },
        gradient(id, stroke, 0.24),
        ...(options.area === false
          ? []
          : [svg("path", { d: `${path} L100,32 L0,32 Z`, fill: `url(#${id})` })]),
        svg("path", {
          d: path,
          fill: "none",
          stroke,
          "stroke-linecap": "round",
          "stroke-linejoin": "round",
          "stroke-width": 1.5,
          "vector-effect": "non-scaling-stroke",
        })
      )
    );
    if (options.endDot) {
      const end = h("span", "wc-spark-end");
      end.style.top = `${(y(points.at(-1) ?? 0) / 32) * 100}%`;
      end.style.backgroundColor = stroke;
      box.append(end);
    }
    return box;
  };

  const ring = (ratio: number, className: string, ...children: Child[]) => {
    const radius = 15.5;
    const length = 2 * Math.PI * radius;
    const clamped = Math.min(Math.max(ratio, 0), 1);
    return h(
      "div",
      cx("wc-ring", className),
      hidden(
        svg(
          "svg",
          { class: "wc-ring-svg", viewBox: "0 0 36 36" },
          svg("circle", {
            cx: 18,
            cy: 18,
            r: radius,
            fill: "none",
            stroke: "var(--color-bg-quaternary)",
            "stroke-width": 3,
          }),
          svg("circle", {
            cx: 18,
            cy: 18,
            r: radius,
            fill: "none",
            stroke: ink.brand,
            "stroke-dasharray": `${clamped * length} ${length}`,
            "stroke-linecap": "round",
            "stroke-width": 3,
          })
        )
      ),
      put(h("span", "wc-ring-center"), children)
    );
  };

  const progressBar = (label: string) => {
    const native = h("progress", "wc-sr") as HTMLProgressElement;
    native.max = 100;
    native.setAttribute("aria-label", label);
    const fillBar = hidden(h("span", "wc-bar-fill"));
    const node = h("div", "wc-bar", native, fillBar);
    const set = (ratio: number, done = false, name = label) => {
      const value = Math.round(Math.min(Math.max(ratio, 0), 1) * 100);
      native.value = value;
      native.setAttribute("aria-label", name);
      fillBar.style.width = `${value}%`;
      fillBar.classList.toggle("wc-bar-done", done);
    };
    return { node, set };
  };

  const segmented = (
    label: string,
    options: Array<{ key: string; label: string }>,
    value: string,
    onChange: (key: string) => void
  ) => {
    const group = h("div", "wc-seg");
    group.setAttribute("role", "group");
    group.setAttribute("aria-label", label);
    group.style.setProperty("--wc-seg-count", String(options.length));
    group.append(hidden(h("span", "wc-seg-thumb")));
    const buttons = options.map((option, index) => {
      const button = h("button", "wc-seg-option", option.label) as HTMLButtonElement;
      button.type = "button";
      button.addEventListener("click", (event) => {
        if (!event.isTrusted) return;
        select(index);
        onChange(option.key);
      });
      group.append(button);
      return button;
    });
    const select = (index: number) => {
      group.style.setProperty("--wc-seg-index", String(index));
      buttons.forEach((button, position) =>
        button.setAttribute("aria-pressed", String(position === index))
      );
    };
    select(
      Math.max(
        options.findIndex((option) => option.key === value),
        0
      )
    );
    return group;
  };

  /** A row that opens an HTTPS page through the runtime's link handling; plain content otherwise. */
  const row = (href: string | undefined, className: string, ...children: Child[]) => {
    const node = put(
      h(href ? "a" : "div", cx("wc-row", href && "wc-row-link", className)),
      children
    ) as HTMLElement;
    if (href) node.setAttribute("href", href);
    return node;
  };

  // ---------------------------------------------------------------- shell
  const card = (
    frame: Frame,
    children: Child[],
    options: { header?: boolean; small?: boolean } = {}
  ) => {
    const root = h("section", cx("wc-card", options.small && "wc-card-sm"));
    root.setAttribute("aria-label", frame.title);
    if (options.header !== false)
      root.append(
        h(
          "header",
          "wc-head",
          h("h3", "wc-title", frame.title),
          frame.meta && h("span", "wc-meta", frame.meta)
        )
      );
    put(root, children);
    const provenance = [frame.source, frame.updatedAt].filter(Boolean).join(" · ");
    if (provenance || frame.actions.length) {
      const glyph =
        frame.sourceBrand && frame.source ? hidden(h("span", "wc-glyph")) : null;
      if (glyph && frame.sourceBrand) place(glyph, frame.sourceBrand);
      const foot = h(
        "footer",
        "wc-foot",
        h("p", "wc-src", glyph, h("span", null, provenance))
      );
      for (const action of frame.actions) {
        const button = h("button", "wc-action", action.label) as HTMLButtonElement;
        button.type = "button";
        // Actions only propose a follow-up; the user sends it from the chat.
        button.addEventListener("click", (event) => {
          if (event.isTrusted) env.send({ type: "request", value: action.prompt });
        });
        foot.append(button);
      }
      root.append(foot);
    }
    return root;
  };

  // --------------------------------------------------------------- clock
  const tickers = new Set<(now: number) => void>();
  let clockTimer: number | undefined;
  const runTick = () => {
    clockTimer = undefined;
    const now = Date.now();
    for (const listener of tickers) listener(now);
    if (tickers.size && clockTimer === undefined) scheduleTick();
  };
  const scheduleTick = () => {
    clockTimer = window.setTimeout(runTick, 1000 - (Date.now() % 1000) + 8);
  };
  /** One shared 1 Hz clock for every running countdown in this widget. */
  const everySecond = (listener: (now: number) => void) => {
    tickers.add(listener);
    if (clockTimer === undefined) scheduleTick();
    return () => {
      tickers.delete(listener);
      if (!tickers.size && clockTimer !== undefined) {
        window.clearTimeout(clockTimer);
        clockTimer = undefined;
      }
    };
  };

  // ---------------------------------------------------------------- state
  // Keyed by element id. A Map keeps ids such as "constructor" or
  // "__proto__" plain keys instead of reaching Object.prototype.
  const saved = new Map<string, string[]>();
  const restore = (state: unknown) => {
    saved.clear();
    if (isRecord(state))
      for (const [name, ids] of Object.entries(state))
        if (Array.isArray(ids))
          saved.set(
            name,
            ids.filter((id): id is string => typeof id === "string").slice(0, 64)
          );
  };
  restore(env.state);

  // -------------------------------------------------------------- layouts
  type Layout<Data> = [
    string,
    (data: Data) => boolean,
    (data: Data, key: string) => Built,
  ];
  const hash = (value: string) => {
    let result = 0x811c9dc5;
    for (let index = 0; index < value.length; index += 1) {
      result ^= value.charCodeAt(index);
      result = Math.imul(result, 0x01000193);
    }
    result ^= result >>> 16;
    result = Math.imul(result, 0x85ebca6b);
    result ^= result >>> 13;
    result = Math.imul(result, 0xc2b2ae35);
    result ^= result >>> 16;
    return result >>> 0;
  };
  /**
   * A requested layout wins when the data fills it. Otherwise each fitting
   * layout scores the card's seed and the best wins (rendezvous hashing):
   * cards differ from each other, one card keeps its layout everywhere, and a
   * layout added later moves only the cards it wins.
   */
  const pick = <Data>(
    layouts: Array<Layout<Data>>,
    data: Data,
    seed: string,
    requested: unknown
  ) => {
    const fitting = layouts.filter(([, fits]) => fits(data));
    const wanted = fitting.find(([name]) => name === requested);
    if (wanted) return wanted;
    let chosen = fitting[0] ?? layouts[0]!;
    let best = -1;
    for (const layout of fitting) {
      const score = hash(`${seed}\u0000${layout[0]}`);
      if (score > best) {
        best = score;
        chosen = layout;
      }
    }
    return chosen;
  };

  // ============================================================ forecast
  type Day = {
    label: string;
    condition: string;
    conditionLabel: string;
    high: number;
    low: number;
    precipitation?: number | undefined;
  };
  type Forecast = {
    frame: Frame;
    location?: string | undefined;
    current?:
      | { temperature: number; condition: string; label: string; details: string }
      | undefined;
    days: Day[];
    highlight?: string | undefined;
  };
  const forecastOf = (data: Record<string, unknown>): Forecast => {
    const current =
      isRecord(data.current) && num(data.current.temperature) !== undefined
        ? data.current
        : undefined;
    const days = list(data.days, 7, (day): Day | undefined =>
      isRecord(day) &&
      text(day.label, 20) &&
      num(day.high) !== undefined &&
      num(day.low) !== undefined
        ? {
            label: text(day.label, 20)!,
            condition: conditionOf(day.condition),
            conditionLabel: text(day.conditionLabel, 40) ?? "",
            high: num(day.high)!,
            low: num(day.low)!,
            precipitation: num(day.precipitation),
          }
        : undefined
    );
    if (!days.length && !current)
      fail(
        unread(data.days, "days", "a label and numbers for high and low") ??
          (isRecord(data.current)
            ? "Card data current.temperature needs a number"
            : "Card data needs days or current weather")
      );
    return {
      frame: frameOf(data),
      location: text(data.location, 60),
      current: current && {
        temperature: num(current.temperature)!,
        condition: conditionOf(current.condition),
        label: text(current.label, 40) ?? "",
        details: [
          num(current.feelsLike) === undefined
            ? null
            : `${copy.feelsLike} ${num(current.feelsLike)}°`,
          num(current.humidity) === undefined
            ? null
            : `${copy.humidity} ${num(current.humidity)}%`,
          text(current.wind, 40),
        ]
          .filter(Boolean)
          .join(" · "),
      },
      days,
      highlight: text(data.highlight, 200),
    };
  };
  const highLow = (day: Day | undefined) =>
    day ? ` · ${copy.high} ${day.high}° ${copy.low} ${day.low}°` : "";
  const forecastLayouts: Array<Layout<Forecast>> = [
    [
      "today",
      (data) => data.current !== undefined,
      (data) => {
        const current = data.current!;
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-fc-hero",
              h(
                "div",
                "wc-col wc-gap-xs wc-grow",
                h("span", "wc-fc-temp", `${current.temperature}°`),
                h("span", "wc-sm wc-c2", `${current.label}${highLow(data.days[0])}`),
                current.details && h("span", "wc-xs wc-c3", current.details)
              ),
              weather(current.condition, current.label, "wc-fc-hero-glyph")
            ),
            data.highlight && insight(data.highlight),
            data.days.length > 0 &&
              h(
                "ul",
                "wc-fc-strip",
                ...data.days.map((day, index) =>
                  h(
                    "li",
                    cx("wc-fc-day", index === 0 && "wc-fc-today"),
                    h("span", "wc-xs wc-c3", day.label),
                    weather(day.condition, day.conditionLabel, "wc-glyph-md"),
                    h("span", "wc-sm wc-w5 wc-c1 wc-num", `${day.high}°`),
                    h("span", "wc-xs wc-c3 wc-num", `${day.low}°`)
                  )
                )
              ),
          ]),
        };
      },
    ],
    [
      "week",
      (data) => data.days.length > 0,
      (data) => {
        const min = Math.min(...data.days.map((day) => day.low));
        const max = Math.max(...data.days.map((day) => day.high));
        const span = max - min || 1;
        return {
          root: card(data.frame, [
            data.highlight && insight(data.highlight),
            h(
              "ul",
              "wc-list",
              ...data.days.map((day) => {
                const left = ((day.low - min) / span) * 100;
                const width = Math.max(((day.high - day.low) / span) * 100, 6);
                const range = h("span", "wc-range-fill");
                range.style.left = `${left}%`;
                range.style.width = `${width}%`;
                range.style.backgroundSize = `${(100 / width) * 100}% 100%`;
                range.style.backgroundPosition = `${width >= 100 ? 0 : (left / (100 - width)) * 100}% 0`;
                return h(
                  "li",
                  "wc-fc-week-row",
                  h("span", "wc-fc-week-label wc-sm wc-c1", day.label),
                  weather(day.condition, day.conditionLabel, "wc-glyph-md"),
                  h(
                    "span",
                    "wc-fc-rain wc-xs wc-num",
                    (day.precipitation ?? 0) >= 20 ? `${day.precipitation}%` : ""
                  ),
                  h("span", "wc-fc-low wc-sm wc-c3 wc-num", `${day.low}°`),
                  hidden(h("span", "wc-range", range)),
                  h("span", "wc-fc-high wc-sm wc-w5 wc-c1 wc-num", `${day.high}°`)
                );
              })
            ),
          ]),
        };
      },
    ],
    [
      "compact",
      (data) => data.current !== undefined && data.days.length <= 2,
      (data) => {
        const current = data.current!;
        const tomorrow = data.days[1];
        return {
          root: card(
            data.frame,
            [
              h(
                "div",
                "wc-row-center wc-gap-lg",
                weather(current.condition, current.label, "wc-glyph-5xl"),
                h(
                  "div",
                  "wc-col wc-grow",
                  h(
                    "span",
                    "wc-sm wc-w5 wc-c1 wc-clip",
                    data.location ?? data.frame.title
                  ),
                  h(
                    "span",
                    "wc-xs wc-c3 wc-clip",
                    `${current.label}${highLow(data.days[0])}`
                  )
                ),
                h("span", "wc-fc-compact-temp", `${current.temperature}°`)
              ),
              tomorrow &&
                h(
                  "div",
                  "wc-fc-tomorrow",
                  h("span", "wc-c2", tomorrow.label),
                  weather(tomorrow.condition, tomorrow.conditionLabel, "wc-glyph-xl"),
                  h("span", null, tomorrow.conditionLabel),
                  h("span", "wc-push wc-num", `${tomorrow.low}° – ${tomorrow.high}°`)
                ),
            ],
            { header: false, small: true }
          ),
        };
      },
    ],
  ];

  // ============================================================= options
  type Option = {
    id: string;
    primary: string;
    secondary?: string | undefined;
    span?: string | undefined;
    meta?: string | undefined;
    price?: string | undefined;
    priceNote?: string | undefined;
    status?: { label: string; tone: Tone } | undefined;
    tags: string[];
    reason?: string | undefined;
    recommended: boolean;
    filterKeys?: string[] | undefined;
  };
  type Options = {
    frame: Frame;
    filters: Array<{ key: string; label: string }>;
    items: Option[];
  };
  const optionsOf = (data: Record<string, unknown>): Options => {
    const items = list(data.items, 8, (item): Option | undefined =>
      isRecord(item) && text(item.primary, 80)
        ? {
            id: text(item.id, 60) ?? text(item.primary, 80)!,
            primary: text(item.primary, 80)!,
            secondary: text(item.secondary, 40),
            span: text(item.span, 40),
            meta: text(item.meta, 120),
            price: text(item.price, 40),
            priceNote: text(item.priceNote, 20),
            status: statusOf(item.status),
            tags: list(item.tags, 3, (tag) => text(tag, 20)),
            reason: text(item.reason, 240),
            recommended: item.recommended === true,
            filterKeys: Array.isArray(item.filterKeys)
              ? list(item.filterKeys, 8, (value) => text(value, 40))
              : undefined,
          }
        : undefined
    );
    if (!items.length)
      fail(unread(data.items, "items", "primary text") ?? "Card data needs items");
    return {
      frame: frameOf(data),
      filters: list(data.filters, 4, (filter) =>
        isRecord(filter) && text(filter.key, 40) && text(filter.label, 20)
          ? { key: text(filter.key, 40)!, label: text(filter.label, 20)! }
          : undefined
      ),
      items,
    };
  };
  const timed = (data: Options) =>
    data.items.every((item) => item.secondary !== undefined);
  const priceColumn = (item: Option) =>
    h(
      "span",
      "wc-price-col",
      item.price && h("span", "wc-sm wc-w6 wc-c1 wc-num", item.price),
      item.status && status(item.status)
    );
  const optionsLayouts: Array<Layout<Options>> = [
    [
      "timetable",
      timed,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-list",
            ...data.items.map((item) =>
              h(
                "li",
                cx("wc-opt", item.recommended && "wc-opt-pick"),
                h(
                  "div",
                  "wc-row-center wc-gap-lg",
                  h(
                    "div",
                    "wc-leg",
                    h("span", "wc-leg-time wc-c1", item.primary),
                    h(
                      "span",
                      "wc-leg-line",
                      h("span", "wc-micro wc-c3 wc-num", item.span ?? ""),
                      hidden(
                        h(
                          "span",
                          "wc-leg-track",
                          h("span", "wc-leg-from"),
                          h("span", "wc-leg-rule"),
                          h("span", "wc-leg-to")
                        )
                      )
                    ),
                    h("span", "wc-leg-time wc-leg-arrive", item.secondary ?? "")
                  ),
                  priceColumn(item)
                ),
                h(
                  "div",
                  "wc-tags",
                  item.meta && h("span", null, item.meta),
                  item.recommended && badge(copy.recommended, "brand"),
                  ...item.tags.map((tag) => badge(tag, "gray"))
                )
              )
            )
          ),
        ]),
      }),
    ],
    [
      "list",
      timed,
      (data) => {
        const rows = h("ul", "wc-list");
        const render = (filter: string) => {
          const visible = filter
            ? data.items.filter((item) => item.filterKeys?.includes(filter) ?? true)
            : data.items;
          rows.replaceChildren(
            ...visible.map((item) =>
              h(
                "li",
                "wc-opt-dense",
                h(
                  "span",
                  "wc-opt-times wc-sm wc-w5 wc-c1 wc-num",
                  item.primary,
                  h("span", "wc-c4", " – "),
                  item.secondary ?? ""
                ),
                h(
                  "span",
                  "wc-grow wc-xs wc-c3 wc-clip",
                  [item.meta?.split(" · ")[0], item.span].filter(Boolean).join(" · ")
                ),
                item.recommended && badge(copy.recommended, "brand"),
                item.status && status(item.status),
                h("span", "wc-opt-price wc-sm wc-w5 wc-c1 wc-num", item.price ?? "")
              )
            )
          );
        };
        const first = data.filters[0]?.key ?? "";
        render(first);
        return {
          root: card(data.frame, [
            data.filters.length > 1 &&
              segmented(data.frame.title, data.filters, first, render),
            rows,
          ]),
        };
      },
    ],
    [
      "pick",
      (data) => data.items.every((item) => item.secondary === undefined),
      (data) => {
        const chosen = data.items.find((item) => item.recommended) ?? data.items[0]!;
        const others = data.items.filter((item) => item !== chosen);
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-pick",
              h(
                "div",
                "wc-row-start wc-gap-lg",
                h(
                  "div",
                  "wc-col wc-gap-xs wc-grow",
                  chosen.recommended && badge(copy.recommended, "brand"),
                  h("span", "wc-md wc-w6 wc-c1", chosen.primary),
                  chosen.meta && h("span", "wc-xs wc-c3", chosen.meta)
                ),
                h(
                  "span",
                  "wc-baseline",
                  chosen.price && h("span", "wc-title-3 wc-w6 wc-c1", chosen.price),
                  chosen.priceNote && h("span", "wc-xs wc-c3", chosen.priceNote)
                )
              ),
              chosen.reason && h("p", "wc-sm wc-c2", chosen.reason),
              chosen.tags.length > 0 &&
                h("div", "wc-tags", ...chosen.tags.map((tag) => badge(tag, "gray")))
            ),
            others.length > 0 &&
              h(
                "div",
                "wc-col",
                h("span", "wc-xs wc-c3 wc-pad-b", copy.alternatives),
                h(
                  "ul",
                  "wc-list",
                  ...others.map((item) =>
                    h(
                      "li",
                      "wc-opt-alt",
                      h(
                        "span",
                        "wc-col wc-grow",
                        h("span", "wc-sm wc-w5 wc-c1 wc-clip", item.primary),
                        item.meta && h("span", "wc-xs wc-c3 wc-clip", item.meta)
                      ),
                      h(
                        "span",
                        "wc-baseline",
                        item.price && h("span", "wc-sm wc-w5 wc-c1 wc-num", item.price),
                        item.priceNote && h("span", "wc-xs wc-c3", item.priceNote)
                      )
                    )
                  )
                )
              ),
          ]),
        };
      },
    ],
  ];

  // ============================================================== metric
  type Metric = {
    label: string;
    value: string;
    unit?: string | undefined;
    delta?: Delta | undefined;
    caption?: string | undefined;
    series: number[];
  };
  type Metrics = {
    frame: Frame;
    metrics: Metric[];
    goal?:
      | {
          current: number;
          target: number;
          valueLabel: string;
          targetLabel: string;
          note?: string | undefined;
        }
      | undefined;
  };
  const metricsOf = (data: Record<string, unknown>): Metrics => {
    const goal =
      isRecord(data.goal) &&
      num(data.goal.current) !== undefined &&
      num(data.goal.target) !== undefined
        ? data.goal
        : undefined;
    const metrics = list(data.metrics, 4, (metric): Metric | undefined =>
      isRecord(metric) && text(metric.value, 40)
        ? {
            label: text(metric.label, 40) ?? "",
            value: text(metric.value, 40)!,
            unit: text(metric.unit, 12),
            delta: deltaOf(metric.delta),
            caption: text(metric.caption, 60),
            series: numbers(metric.series, 64),
          }
        : undefined
    );
    if (!metrics.length && !goal)
      fail(
        unread(data.metrics, "metrics", "a value as text") ??
          (isRecord(data.goal)
            ? "Card data goal needs numbers for current and target"
            : "Card data needs metrics or a goal")
      );
    return {
      frame: frameOf(data),
      metrics,
      goal: goal && {
        current: num(goal.current)!,
        target: num(goal.target)!,
        valueLabel: need(goal.valueLabel, "goal.valueLabel", 40),
        targetLabel: need(goal.targetLabel, "goal.targetLabel", 60),
        note: text(goal.note, 120),
      },
    };
  };
  const value = (metric: Metric, className: string) =>
    h(
      "span",
      cx("wc-value", className),
      metric.value,
      metric.unit && h("span", "wc-unit", metric.unit)
    );
  const metricLayouts: Array<Layout<Metrics>> = [
    [
      "goal",
      (data) => data.goal !== undefined,
      (data) => {
        const goal = data.goal!;
        const ratio = goal.target > 0 ? goal.current / goal.target : 0;
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-row-center wc-gap-xl",
              ring(
                ratio,
                "wc-ring-8xl",
                h("span", "wc-md wc-w6 wc-c1", `${Math.round(ratio * 100)}%`)
              ),
              h(
                "div",
                "wc-col wc-gap-xxs",
                h("span", "wc-title-2 wc-w6 wc-c1", goal.valueLabel),
                h("span", "wc-sm wc-c3", goal.targetLabel),
                goal.note && h("span", "wc-xs wc-c2 wc-pad-t", goal.note)
              )
            ),
          ]),
        };
      },
    ],
    [
      "single",
      (data) => data.goal === undefined && data.metrics.length === 1,
      (data) => {
        const metric = data.metrics[0]!;
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-metric-single",
              h(
                "div",
                "wc-col wc-gap-xs",
                value(metric, "wc-display-md wc-tight"),
                h(
                  "span",
                  "wc-row-center wc-gap-sm",
                  metric.delta && delta(metric.delta),
                  metric.caption && h("span", "wc-xs wc-c3", metric.caption)
                )
              ),
              metric.series.length > 1 &&
                sparkline(metric.series, ink.brand, {
                  endDot: true,
                  className: "wc-metric-spark",
                })
            ),
          ]),
        };
      },
    ],
    [
      "grid",
      (data) => data.goal === undefined && data.metrics.length > 1,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-metric-grid",
            ...data.metrics.map((metric) =>
              h(
                "li",
                "wc-tile",
                h("span", "wc-xs wc-c3", metric.label),
                value(metric, "wc-title-3"),
                metric.delta && delta(metric.delta)
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // =============================================================== trend
  type Series = {
    label: string;
    brand?: string | undefined;
    value: string;
    delta?: Delta | undefined;
    points: number[];
  };
  type Trend = {
    frame: Frame;
    brand?: string | undefined;
    value?: string | undefined;
    delta?: Delta | undefined;
    ranges: Array<{ key: string; label: string; points: number[]; axis: string[] }>;
    bars?:
      | {
          labels: string[];
          values: number[];
          valueLabels: string[];
          averageLabel?: string | undefined;
        }
      | undefined;
    series: Series[];
  };
  const trendOf = (data: Record<string, unknown>): Trend => {
    const bars = isRecord(data.bars) ? data.bars : undefined;
    const trend: Trend = {
      frame: frameOf(data),
      brand: brandOf(data.brand),
      value: text(data.value, 40),
      delta: deltaOf(data.delta),
      ranges: list(data.ranges, 4, (range) => {
        if (!isRecord(range) || !text(range.key, 20) || !text(range.label, 20))
          return undefined;
        const points = numbers(range.points, 64);
        return points.length > 1
          ? {
              key: text(range.key, 20)!,
              label: text(range.label, 20)!,
              points,
              axis: list(range.axis, 6, (tick) => text(tick, 20)),
            }
          : undefined;
      }),
      bars: bars && {
        labels: list(bars.labels, 31, (label) => text(label, 12) ?? ""),
        values: numbers(bars.values, 31),
        valueLabels: list(bars.valueLabels, 31, (label) => text(label, 20) ?? ""),
        averageLabel: text(bars.averageLabel, 40),
      },
      series: list(data.series, 6, (item): Series | undefined => {
        if (!isRecord(item) || !text(item.label, 12) || !text(item.value, 20))
          return undefined;
        const points = numbers(item.points, 64);
        return points.length > 1
          ? {
              label: text(item.label, 12)!,
              brand: brandOf(item.brand),
              value: text(item.value, 20)!,
              delta: deltaOf(item.delta),
              points,
            }
          : undefined;
      }),
    };
    if (trend.bars && trend.bars.values.length !== trend.bars.labels.length)
      fail("Bar values and labels must match");
    if (!trend.ranges.length && !trend.bars?.values.length && !trend.series.length)
      fail(
        unread(
          data.ranges,
          "ranges",
          "a key, a label and two or more numeric points"
        ) ??
          unread(
            data.series,
            "series",
            "a label, a value and two or more numeric points"
          ) ??
          (bars ? "Card data bars.values needs numbers" : undefined) ??
          "Card data needs ranges, bars or series"
      );
    return trend;
  };
  const headline = (data: Trend) =>
    h(
      "div",
      "wc-row-center wc-gap-md",
      data.brand && mark(data.brand, data.frame.title, "lg"),
      h(
        "div",
        "wc-col wc-gap-xxs",
        data.value && h("span", "wc-title-2 wc-w6 wc-c1", data.value),
        data.delta && delta(data.delta)
      )
    );
  const trendLayouts: Array<Layout<Trend>> = [
    [
      "area",
      (data) => data.ranges.length > 0,
      (data) => {
        const figure = h("figure", "wc-area");
        const caption = h("figcaption", "wc-sr");
        const id = nextId();
        const area = svg("path", { class: "wc-morph", fill: `url(#${id})` });
        const line = svg("path", {
          class: "wc-morph",
          fill: "none",
          stroke: ink.brand,
          "stroke-linecap": "round",
          "stroke-linejoin": "round",
          "stroke-width": 2,
          "vector-effect": "non-scaling-stroke",
        });
        const end = h("span", "wc-area-end wc-glide");
        const high = h("span", "wc-area-label wc-area-high wc-glide");
        const low = h("span", "wc-area-label wc-area-low wc-glide");
        const axis = hidden(h("div", "wc-area-axis"));
        figure.append(
          caption,
          hidden(
            h(
              "div",
              "wc-area-plot",
              h("div", "wc-area-grid", h("div"), h("div"), h("div")),
              svg(
                "svg",
                {
                  class: "wc-area-svg",
                  viewBox: "0 0 100 100",
                  preserveAspectRatio: "none",
                },
                gradient(id, ink.brand, 0.22),
                area,
                line
              ),
              end,
              high,
              low
            )
          ),
          axis
        );
        const show = (key: string) => {
          const range =
            data.ranges.find((candidate) => candidate.key === key) ?? data.ranges[0]!;
          const y = scale(range.points, 100, 6);
          const path = linePath(resample(range.points, 96), y, 100);
          area.setAttribute("d", `${path} L100,100 L0,100 Z`);
          line.setAttribute("d", path);
          const max = Math.max(...range.points);
          const min = Math.min(...range.points);
          end.style.top = `${y(range.points.at(-1) ?? 0)}%`;
          high.style.top = `${y(max)}%`;
          high.textContent = formatCompact(max);
          low.style.top = `${y(min)}%`;
          low.textContent = formatCompact(min);
          axis.replaceChildren(...range.axis.map((tick) => h("span", null, tick)));
          caption.textContent = `${data.frame.title} · ${range.label}`;
        };
        const initial = (data.ranges[1] ?? data.ranges[0]!).key;
        show(initial);
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-row-end wc-wrap wc-between wc-gap-md",
              headline(data),
              data.ranges.length > 1 &&
                segmented(copy.range, data.ranges, initial, show)
            ),
            figure,
          ]),
        };
      },
    ],
    [
      "bars",
      (data) => (data.bars?.values.length ?? 0) > 0,
      (data) => {
        const bars = data.bars!;
        const max = Math.max(...bars.values) * 1.3 || 1;
        const average =
          bars.values.reduce((sum, item) => sum + item, 0) / bars.values.length;
        const last = bars.values.length - 1;
        const averageLine = hidden(h("div", "wc-bars-average"));
        averageLine.style.bottom = `${(average / max) * 100}%`;
        return {
          root: card(data.frame, [
            headline(data),
            h(
              "figure",
              "wc-bars",
              h(
                "figcaption",
                "wc-bars-legend",
                sr(data.frame.title),
                bars.averageLabel && hidden(h("span", "wc-bars-swatch")),
                bars.averageLabel ?? ""
              ),
              hidden(
                h(
                  "div",
                  "wc-bars-plot",
                  ...bars.values.map((item, index) => {
                    const bar = h(
                      "div",
                      cx("wc-bar-col", index === last && "wc-bar-latest")
                    );
                    bar.style.height = `${(item / max) * 100}%`;
                    const label =
                      index === last && bars.valueLabels[index]
                        ? h("span", "wc-bars-value", bars.valueLabels[index]!)
                        : null;
                    if (label) label.style.bottom = `${(item / max) * 100}%`;
                    return h("div", "wc-bar-slot", bar, label);
                  }),
                  averageLine
                )
              ),
              hidden(
                h(
                  "div",
                  "wc-bars-axis",
                  ...bars.labels.map((tick, index) =>
                    h("span", null, index % 2 === last % 2 ? tick : "")
                  )
                )
              )
            ),
          ]),
        };
      },
    ],
    [
      "watchlist",
      (data) => data.series.length > 0,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-list",
            ...data.series.map((item) => {
              const up = item.delta?.direction !== "down";
              return h(
                "li",
                "wc-watch",
                h(
                  "span",
                  "wc-watch-name",
                  mark(item.brand, item.label),
                  h("span", "wc-sm wc-w6 wc-c1", item.label)
                ),
                sparkline(item.points, up ? ink.success : ink.error, {
                  area: false,
                  className: "wc-watch-spark",
                }),
                h("span", "wc-watch-value wc-sm wc-w5 wc-c1 wc-num", item.value),
                item.delta &&
                  h(
                    "span",
                    cx("wc-pill", item.delta.good ? "wc-pill-good" : "wc-pill-bad"),
                    `${item.delta.direction === "down" ? "−" : "+"}${item.delta.value}`
                  )
              );
            })
          ),
        ]),
      }),
    ],
  ];

  // ========================================================== comparison
  type Subject = {
    name: string;
    caption?: string | undefined;
    recommended: boolean;
    brand?: string | undefined;
  };
  type Comparison = {
    frame: Frame;
    subjects: Subject[];
    rows: Array<{
      label: string;
      values: string[];
      best?: number | undefined;
      scores?: number[] | undefined;
    }>;
    verdict?: string | undefined;
  };
  const comparisonOf = (data: Record<string, unknown>): Comparison => {
    const subjects = list(data.subjects, 3, (subject): Subject | undefined =>
      isRecord(subject) && text(subject.name, 40)
        ? {
            name: text(subject.name, 40)!,
            caption: text(subject.caption, 60),
            recommended: subject.recommended === true,
            brand: brandOf(subject.brand),
          }
        : undefined
    );
    if (subjects.length < 2) fail("Card data needs two or three subjects");
    const rows = list(data.rows, 8, (item) => {
      if (!isRecord(item) || !text(item.label, 24)) return undefined;
      const values = list(
        item.values,
        subjects.length,
        (cell) => text(cell, 60) ?? "—"
      );
      if (values.length !== subjects.length) return undefined;
      const scores = numbers(item.scores, 2);
      const best = num(item.best);
      return {
        label: text(item.label, 24)!,
        values,
        best:
          best !== undefined && best >= 0 && best < subjects.length ? best : undefined,
        scores:
          scores.length === 2
            ? scores.map((score) => Math.min(Math.max(score, 0), 10))
            : undefined,
      };
    });
    if (!rows.length)
      fail(
        unread(data.rows, "rows", "a label and one value per subject") ??
          "Card data needs rows with one value per subject"
      );
    return { frame: frameOf(data), subjects, rows, verdict: text(data.verdict, 240) };
  };
  const subjectName = (subject: Subject, className: string) =>
    h(
      "span",
      "wc-row-center wc-gap-sm",
      subject.brand && mark(subject.brand, subject.name),
      h("span", className, subject.name),
      subject.recommended && badge(copy.recommended, "brand")
    );
  const comparisonCard = (data: Comparison, body: HTMLElement) =>
    card(data.frame, [body, data.verdict && insight(data.verdict)]);
  const comparisonLayouts: Array<Layout<Comparison>> = [
    [
      "columns",
      (data) => data.subjects.length <= 3,
      (data) => {
        const corner = h("th", "wc-cmp-corner", sr(copy.attribute));
        corner.setAttribute("scope", "col");
        return {
          root: comparisonCard(
            data,
            h(
              "table",
              "wc-cmp",
              h(
                "thead",
                null,
                h(
                  "tr",
                  null,
                  corner,
                  ...data.subjects.map((subject) => {
                    const head = h(
                      "th",
                      "wc-cmp-head",
                      h(
                        "span",
                        "wc-col wc-gap-xxs",
                        subject.recommended && badge(copy.recommended, "brand"),
                        h(
                          "span",
                          "wc-row-center wc-gap-sm",
                          subject.brand && mark(subject.brand, subject.name),
                          h("span", "wc-sm wc-w6 wc-c1", subject.name)
                        ),
                        subject.caption && h("span", "wc-xs wc-c3", subject.caption)
                      )
                    );
                    head.setAttribute("scope", "col");
                    return head;
                  })
                )
              ),
              h(
                "tbody",
                null,
                ...data.rows.map((item) => {
                  const label = h("th", "wc-cmp-label", item.label);
                  label.setAttribute("scope", "row");
                  return h(
                    "tr",
                    null,
                    label,
                    ...item.values.map((cell, index) =>
                      h(
                        "td",
                        cx("wc-cmp-cell", item.best === index && "wc-cmp-best"),
                        h(
                          "span",
                          "wc-row-center wc-gap-xs",
                          cell,
                          item.best === index && icon("check", "wc-cmp-check")
                        )
                      )
                    )
                  );
                })
              )
            )
          ),
        };
      },
    ],
    [
      "table",
      // Each row becomes a column; more than four stop fitting a chat card.
      (data) => data.rows.length <= 4,
      (data) => {
        const corner = h("th", null, sr(copy.option));
        corner.setAttribute("scope", "col");
        return {
          root: comparisonCard(
            data,
            h(
              "table",
              "wc-attr",
              h(
                "thead",
                null,
                h(
                  "tr",
                  null,
                  corner,
                  ...data.rows.map((item) => {
                    const head = h("th", null, item.label);
                    head.setAttribute("scope", "col");
                    return head;
                  })
                )
              ),
              h(
                "tbody",
                null,
                ...data.subjects.map((subject, subjectIndex) => {
                  const name = h(
                    "th",
                    "wc-attr-name",
                    h(
                      "span",
                      "wc-col wc-gap-xxs",
                      subjectName(subject, "wc-sm wc-w5 wc-c1"),
                      subject.caption && h("span", "wc-xs wc-c3", subject.caption)
                    )
                  );
                  name.setAttribute("scope", "row");
                  return h(
                    "tr",
                    null,
                    name,
                    ...data.rows.map((item) => {
                      const cell = h(
                        "td",
                        null,
                        h(
                          "span",
                          cx(
                            "wc-attr-value",
                            item.best === subjectIndex && "wc-attr-best"
                          ),
                          item.values[subjectIndex] ?? "—"
                        )
                      );
                      // Narrow cards stack each subject into label/value pairs.
                      cell.dataset.label = item.label;
                      return cell;
                    })
                  );
                })
              )
            )
          ),
        };
      },
    ],
    [
      "versus",
      (data) =>
        data.subjects.length === 2 &&
        data.rows.every((item) => item.scores !== undefined),
      (data) => {
        const [left, right] = data.subjects as [Subject, Subject];
        const side = (score: number, winning: boolean, end: boolean) => {
          const fillBar = h(
            "span",
            cx("wc-vs-fill", winning ? "wc-vs-win" : "wc-vs-lose")
          );
          fillBar.style.width = `${score * 10}%`;
          return h("span", cx("wc-vs-track", end && "wc-vs-end"), fillBar);
        };
        return {
          root: comparisonCard(
            data,
            h(
              "div",
              "wc-col wc-gap-md",
              h(
                "div",
                "wc-row-center wc-gap-lg",
                h(
                  "span",
                  "wc-vs-name",
                  left.brand && mark(left.brand, left.name),
                  h("span", "wc-md wc-w6 wc-c1 wc-clip", left.name),
                  left.recommended && badge(copy.recommended, "brand")
                ),
                h("span", "wc-xs wc-w5 wc-c4", copy.versus),
                h(
                  "span",
                  "wc-vs-name wc-vs-right",
                  right.recommended && badge(copy.recommended, "brand"),
                  h("span", "wc-md wc-w6 wc-c1 wc-clip", right.name),
                  right.brand && mark(right.brand, right.name)
                )
              ),
              h(
                "ul",
                "wc-vs-rows",
                ...data.rows.map((item) => {
                  const [a, b] = item.scores as [number, number];
                  return h(
                    "li",
                    "wc-row-center wc-gap-sm",
                    h("span", "wc-vs-score wc-vs-score-left", String(a)),
                    side(a, a >= b, true),
                    h("span", "wc-vs-label", item.label),
                    side(b, b >= a, false),
                    h("span", "wc-vs-score", String(b))
                  );
                })
              )
            )
          ),
        };
      },
    ],
  ];

  // ============================================================ schedule
  type Event = {
    start: string;
    end?: string | undefined;
    title: string;
    detail?: string | undefined;
    state: "done" | "current" | "upcoming";
    tone: Tone;
  };
  type Schedule = {
    frame: Frame;
    now?: string | undefined;
    events: Event[];
    stages: Array<{
      label: string;
      detail?: string | undefined;
      state: "done" | "current" | "upcoming";
    }>;
    summary?: string | undefined;
  };
  const stateOf = (input: unknown) =>
    input === "done" || input === "current" ? input : "upcoming";
  const scheduleOf = (data: Record<string, unknown>): Schedule => {
    const schedule: Schedule = {
      frame: frameOf(data),
      now: text(data.now, 12),
      events: list(data.events, 8, (event) =>
        isRecord(event) && text(event.start, 12) && text(event.title, 80)
          ? {
              start: text(event.start, 12)!,
              end: text(event.end, 12),
              title: text(event.title, 80)!,
              detail: text(event.detail, 80),
              state: stateOf(event.state),
              tone: toneOf(event.tone),
            }
          : undefined
      ),
      stages: list(data.stages, 6, (stage) =>
        isRecord(stage) && text(stage.label, 20)
          ? {
              label: text(stage.label, 20)!,
              detail: text(stage.detail, 40),
              state: stateOf(stage.state),
            }
          : undefined
      ),
      summary: text(data.summary, 120),
    };
    if (!schedule.events.length && schedule.stages.length < 2)
      fail(
        unread(data.events, "events", "a start and a title") ??
          "Card data needs events or at least two stages"
      );
    return schedule;
  };
  const scheduleLayouts: Array<Layout<Schedule>> = [
    [
      "agenda",
      (data) => data.events.length > 0,
      (data) => {
        const items: HTMLElement[] = [];
        for (const event of data.events) {
          items.push(
            h(
              "li",
              cx("wc-agenda", event.state === "current" && "wc-agenda-now"),
              h("span", "wc-agenda-time", event.start),
              hidden(
                h(
                  "span",
                  cx(
                    "wc-agenda-bar",
                    event.state === "done" ? "wc-agenda-done" : `wc-dot-${event.tone}`
                  )
                )
              ),
              h(
                "span",
                "wc-col wc-grow",
                h(
                  "span",
                  cx("wc-sm wc-w5 wc-clip", event.state === "done" ? "wc-c3" : "wc-c1"),
                  event.title,
                  event.state === "current" && sr(` · ${copy.ongoing}`)
                ),
                h(
                  "span",
                  "wc-xs wc-c3 wc-clip",
                  [event.end ? `${event.start}–${event.end}` : null, event.detail]
                    .filter(Boolean)
                    .join(" · ")
                )
              )
            )
          );
          if (event.state === "current" && data.now)
            items.push(
              hidden(
                h(
                  "li",
                  "wc-now",
                  h("span", "wc-now-time", data.now),
                  h("span", "wc-now-dot"),
                  h("span", "wc-now-line")
                )
              )
            );
        }
        return {
          root: card(data.frame, [
            data.summary && insight(data.summary),
            h("ol", "wc-list", ...items),
          ]),
        };
      },
    ],
    [
      "timeline",
      (data) => data.events.length > 0,
      (data) => ({
        root: card(data.frame, [
          data.summary && insight(data.summary),
          h(
            "ol",
            "wc-list",
            ...data.events.map((event, index) =>
              h(
                "li",
                "wc-step",
                h(
                  "span",
                  cx("wc-step-time", event.state === "current" && "wc-step-time-now"),
                  event.start
                ),
                hidden(
                  h(
                    "span",
                    "wc-step-rail",
                    h("span", `wc-step-dot wc-step-${event.state}`),
                    index < data.events.length - 1 &&
                      h(
                        "span",
                        cx(
                          "wc-step-line",
                          event.state === "done" && "wc-step-line-done"
                        )
                      )
                  )
                ),
                h(
                  "span",
                  cx("wc-col wc-grow", index < data.events.length - 1 && "wc-pad-b-lg"),
                  h(
                    "span",
                    cx("wc-sm wc-w5", event.state === "done" ? "wc-c3" : "wc-c1"),
                    event.title
                  ),
                  event.detail && h("span", "wc-xs wc-c3", event.detail)
                )
              )
            )
          ),
        ]),
      }),
    ],
    [
      "stages",
      (data) => data.stages.length > 1,
      (data) => {
        const current = data.stages.find((stage) => stage.state === "current");
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-col wc-gap-xxs",
              data.summary && h("span", "wc-title-3 wc-w6 wc-c1", data.summary),
              current &&
                h(
                  "span",
                  "wc-xs wc-c3",
                  [current.label, current.detail].filter(Boolean).join(" · ")
                )
            ),
            h(
              "ol",
              "wc-stages",
              ...data.stages.map((stage, index) => {
                const reached = stage.state !== "upcoming";
                const next = data.stages[index + 1];
                const nextReached = next !== undefined && next.state !== "upcoming";
                return h(
                  "li",
                  "wc-stage",
                  hidden(
                    h(
                      "span",
                      "wc-stage-track",
                      h(
                        "span",
                        cx(
                          "wc-stage-line",
                          index === 0 && "wc-invisible",
                          reached && "wc-stage-line-on"
                        )
                      ),
                      stage.state === "done"
                        ? h("span", "wc-stage-mark wc-stage-done", icon("check"))
                        : h(
                            "span",
                            cx(
                              "wc-stage-mark",
                              stage.state === "current"
                                ? "wc-stage-current"
                                : "wc-stage-upcoming"
                            ),
                            stage.state === "current" && h("span", "wc-stage-core")
                          ),
                      h(
                        "span",
                        cx(
                          "wc-stage-line",
                          index === data.stages.length - 1 && "wc-invisible",
                          nextReached && "wc-stage-line-on"
                        )
                      )
                    )
                  ),
                  h(
                    "span",
                    cx(
                      "wc-xs",
                      stage.state === "current"
                        ? "wc-w5 wc-c1"
                        : stage.state === "done"
                          ? "wc-c2"
                          : "wc-c3"
                    ),
                    stage.label
                  ),
                  stage.detail && h("span", "wc-stage-detail", stage.detail)
                );
              })
            ),
          ]),
        };
      },
    ],
  ];

  // =========================================================== checklist
  type Checklist = {
    frame: Frame;
    groups: Array<{
      label: string;
      items: Array<{
        id: string;
        label: string;
        detail?: string | undefined;
        done: boolean;
      }>;
    }>;
  };
  const checklistOf = (data: Record<string, unknown>): Checklist => {
    let budget = 12;
    const groups = list(data.groups, 4, (group) => {
      if (!isRecord(group)) return undefined;
      const items = list(group.items, budget, (item) =>
        isRecord(item) && text(item.label, 80)
          ? {
              id: text(item.id, 60) ?? text(item.label, 80)!,
              label: text(item.label, 80)!,
              detail: text(item.detail, 80),
              done: item.done === true,
            }
          : undefined
      );
      budget -= items.length;
      return items.length ? { label: text(group.label, 40) ?? "", items } : undefined;
    });
    if (!groups.length)
      fail(
        unread(data.groups, "groups", "items with a label") ??
          "Card data needs groups with items"
      );
    // Preserve every original id before assigning suffixes to repeated rows.
    // Without explicit ids, repeated labels follow their input order.
    const reserved = new Set(
      groups.flatMap((group) => group.items.map((item) => item.id))
    );
    const used = new Set<string>();
    for (const group of groups)
      for (const item of group.items) {
        let id = item.id;
        if (used.has(id)) {
          let n = 2;
          do id = `${item.id}#${n++}`;
          while (used.has(id) || reserved.has(id));
        }
        used.add(id);
        item.id = id;
      }
    return { frame: frameOf(data), groups };
  };
  const checklistCard = (data: Checklist, key: string, grouped: boolean): Built => {
    const items = data.groups.flatMap((group) => group.items);
    const initial = () =>
      saved.get(key) ?? items.filter((item) => item.done).map((item) => item.id);
    const done = new Set(initial());
    const inputs: Array<{ input: HTMLInputElement; id: string }> = [];
    const bar = progressBar("");
    const counts: Array<{ node: HTMLElement; ids: string[] }> = [];
    const meta = h("span", "wc-meta");
    const refresh = () => {
      const count = items.filter((item) => done.has(item.id)).length;
      const label = fill(copy.checklistProgress, { done: count, total: items.length });
      meta.textContent = label;
      bar.set(items.length ? count / items.length : 0, count === items.length, label);
      for (const counter of counts)
        counter.node.textContent = `${counter.ids.filter((id) => done.has(id)).length}/${counter.ids.length}`;
    };
    const checkRow = (item: Checklist["groups"][number]["items"][number]) => {
      const input = h("input", "wc-check-input") as HTMLInputElement;
      input.type = "checkbox";
      input.checked = done.has(item.id);
      inputs.push({ input, id: item.id });
      input.addEventListener("change", (event) => {
        if (!event.isTrusted) return;
        if (input.checked) done.add(item.id);
        else done.delete(item.id);
        saved.set(key, [...done]);
        env.send({ type: "card-state", value: Object.fromEntries(saved) });
        refresh();
      });
      return h(
        "label",
        "wc-check",
        input,
        hidden(h("span", "wc-check-box", icon("check-large"))),
        h(
          "span",
          "wc-col",
          h("span", "wc-check-label", item.label),
          item.detail && h("span", "wc-xs wc-c3", item.detail)
        )
      );
    };
    const body = grouped
      ? h(
          "div",
          "wc-check-groups",
          ...data.groups.map((group) => {
            const counter = h("span", "wc-xs wc-c3 wc-num");
            counts.push({ node: counter, ids: group.items.map((item) => item.id) });
            return h(
              "section",
              "wc-check-group",
              h(
                "header",
                "wc-check-group-head",
                h("h4", "wc-xs wc-w5 wc-c3", group.label),
                counter
              ),
              ...group.items.map(checkRow)
            );
          })
        )
      : h(
          "div",
          "wc-col",
          ...items.map((item) => h("div", "wc-divided", checkRow(item)))
        );
    const root = card(
      { ...data.frame, meta: undefined },
      grouped ? [body] : [bar.node, body]
    );
    root.querySelector(".wc-head")?.append(meta);
    refresh();
    // Another open copy saved progress: show it without sending it back.
    const sync = () => {
      done.clear();
      for (const id of initial()) done.add(id);
      for (const entry of inputs) entry.input.checked = done.has(entry.id);
      refresh();
    };
    return { root, sync };
  };
  const checklistLayouts: Array<Layout<Checklist>> = [
    ["progress", () => true, (data, key) => checklistCard(data, key, false)],
    [
      "grouped",
      (data) => data.groups.length > 1,
      (data, key) => checklistCard(data, key, true),
    ],
  ];

  // ========================================================= composition
  type Composition = {
    frame: Frame;
    total: string;
    totalLabel: string;
    segments: Array<{
      label: string;
      value: number;
      valueLabel: string;
      muted: boolean;
    }>;
  };
  const compositionOf = (data: Record<string, unknown>): Composition => {
    const segments = list(data.segments, 6, (segment) =>
      isRecord(segment) && text(segment.label, 30) && (num(segment.value) ?? -1) >= 0
        ? {
            label: text(segment.label, 30)!,
            value: num(segment.value)!,
            valueLabel: text(segment.valueLabel, 20) ?? String(num(segment.value)),
            muted: segment.muted === true,
          }
        : undefined
    );
    if (!segments.length)
      fail(
        unread(data.segments, "segments", "a label and a value of 0 or more") ??
          "Card data needs segments"
      );
    return {
      frame: frameOf(data),
      total: need(data.total, "a total", 40),
      totalLabel: text(data.totalLabel, 40) ?? "",
      segments,
    };
  };
  const segmentInk = (segment: Composition["segments"][number], index: number) =>
    segment.muted ? ink.muted : seriesInk[index % seriesInk.length]!;
  const legend = (data: Composition, two: boolean) => {
    const sum = data.segments.reduce((total, segment) => total + segment.value, 0);
    return h(
      "ul",
      cx("wc-legend", two && "wc-legend-two"),
      ...data.segments.map((segment, index) => {
        const swatch = hidden(h("span", "wc-swatch"));
        swatch.style.backgroundColor = segmentInk(segment, index);
        return h(
          "li",
          "wc-row-center wc-gap-sm",
          swatch,
          h("span", "wc-grow wc-sm wc-c2 wc-clip", segment.label),
          h("span", "wc-sm wc-w5 wc-c1 wc-num", segment.valueLabel),
          h(
            "span",
            "wc-legend-share",
            sum > 0 ? `${Math.round((segment.value / sum) * 100)}%` : "0%"
          )
        );
      })
    );
  };
  const compositionLayouts: Array<Layout<Composition>> = [
    [
      "stacked",
      () => true,
      (data) => ({
        root: card(data.frame, [
          h(
            "div",
            "wc-col wc-gap-xxs",
            h("span", "wc-xs wc-c3", data.totalLabel),
            h("span", "wc-title-2 wc-w6 wc-c1", data.total)
          ),
          hidden(
            h(
              "div",
              "wc-stack",
              ...data.segments.map((segment, index) => {
                const part = h("span", "wc-stack-part");
                part.style.flexGrow = String(segment.value);
                part.style.backgroundColor = segmentInk(segment, index);
                return part;
              })
            )
          ),
          legend(data, true),
        ]),
      }),
    ],
    [
      "donut",
      () => true,
      (data) => {
        const sum = data.segments.reduce((total, segment) => total + segment.value, 0);
        let offset = 0;
        const circles = data.segments.map((segment, index) => {
          const length = sum > 0 ? (segment.value / sum) * 100 : 0;
          const visible = Math.max(length - 1.2, 0);
          const circle = svg("circle", {
            cx: 18,
            cy: 18,
            r: 15.9155,
            fill: "none",
            stroke: segmentInk(segment, index),
            "stroke-dasharray": `${visible} ${100 - visible}`,
            "stroke-dashoffset": -offset,
            "stroke-width": 4,
          });
          offset += length;
          return circle;
        });
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-donut-row",
              h(
                "figure",
                "wc-donut",
                h(
                  "figcaption",
                  "wc-sr",
                  `${data.frame.title}: ${data.segments.map((segment) => `${segment.label} ${segment.valueLabel}`).join(", ")}`
                ),
                hidden(
                  svg(
                    "svg",
                    { class: "wc-donut-svg", viewBox: "0 0 36 36" },
                    ...circles
                  )
                ),
                hidden(
                  h(
                    "span",
                    "wc-donut-center",
                    h("span", "wc-md wc-w6 wc-c1", data.total),
                    h("span", "wc-micro wc-c3", data.totalLabel)
                  )
                )
              ),
              h("div", "wc-grow", legend(data, false))
            ),
          ]),
        };
      },
    ],
  ];

  // =============================================================== place
  type Place = {
    name: string;
    category?: string | undefined;
    rating?: number | undefined;
    reviews?: string | undefined;
    status?: { label: string; tone: Tone } | undefined;
    address?: string | undefined;
    distance?: string | undefined;
    eta?: string | undefined;
    href?: string | undefined;
  };
  type Places = { frame: Frame; places: Place[] };
  const placesOf = (data: Record<string, unknown>): Places => {
    const places = list(data.places, 5, (item): Place | undefined =>
      isRecord(item) && text(item.name, 60)
        ? {
            name: text(item.name, 60)!,
            category: text(item.category, 30),
            rating: num(item.rating),
            reviews: text(item.reviews, 30),
            status: statusOf(item.status),
            address: text(item.address, 120),
            distance: text(item.distance, 20),
            eta: text(item.eta, 30),
            href: httpsOf(item.href),
          }
        : undefined
    );
    if (!places.length)
      fail(unread(data.places, "places", "a name") ?? "Card data needs places");
    return { frame: frameOf(data), places };
  };
  const rating = (item: Place) =>
    item.rating === undefined
      ? null
      : h(
          "span",
          "wc-baseline wc-gap-xs",
          h("span", "wc-w5 wc-c1 wc-num", item.rating.toFixed(1)),
          item.reviews && h("span", null, `· ${item.reviews}`)
        );
  const placeLayouts: Array<Layout<Places>> = [
    [
      "single",
      (data) => data.places.length === 1,
      (data) => {
        const item = data.places[0]!;
        const go = item.href
          ? h("a", "wc-action wc-action-link", copy.directions, icon("arrow-right"))
          : null;
        if (go && item.href) go.setAttribute("href", item.href);
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-col wc-gap-xs",
              h("span", "wc-md wc-w6 wc-c1", item.name),
              h(
                "span",
                "wc-row-center wc-wrap wc-gap-sm wc-xs wc-c3",
                item.category && h("span", null, item.category),
                rating(item)
              ),
              item.status && status(item.status)
            ),
            item.address && h("p", "wc-sm wc-c2", item.address),
            h(
              "div",
              "wc-row-center wc-wrap wc-gap-sm",
              item.distance && h("span", "wc-chip", item.distance),
              item.eta && h("span", "wc-chip", item.eta),
              go && h("span", "wc-push", go)
            ),
          ]),
        };
      },
    ],
    [
      "nearby",
      (data) => data.places.length > 1,
      (data) => ({
        root: card(data.frame, [
          h(
            "ol",
            "wc-list",
            ...data.places.map((item, index) =>
              h(
                "li",
                "wc-divided",
                row(
                  item.href,
                  "wc-place",
                  hidden(h("span", "wc-place-index", String(index + 1))),
                  h(
                    "span",
                    "wc-col wc-gap-xxs wc-grow",
                    h("span", "wc-sm wc-w5 wc-c1 wc-clip", item.name),
                    h(
                      "span",
                      "wc-row-center wc-gap-sm wc-xs wc-c3",
                      rating(item),
                      item.status && status(item.status)
                    )
                  ),
                  h(
                    "span",
                    "wc-col wc-end wc-gap-xxs",
                    h("span", "wc-sm wc-w5 wc-c1 wc-num", item.distance ?? ""),
                    h("span", "wc-xs wc-c3", item.eta ?? "")
                  ),
                  item.href && icon("chevron-right", "wc-chevron")
                )
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // ================================================================ feed
  type Feed = {
    frame: Frame;
    items: Array<{
      source: string;
      brand?: string | undefined;
      title: string;
      excerpt?: string | undefined;
      time?: string | undefined;
      status?: { label: string; tone: Tone } | undefined;
      href?: string | undefined;
    }>;
    groups: Array<{
      source: string;
      brand?: string | undefined;
      count: number;
      summary: string;
      tone: Tone;
    }>;
  };
  const feedOf = (data: Record<string, unknown>): Feed => {
    const feed: Feed = {
      frame: frameOf(data),
      items: list(data.items, 6, (item) =>
        isRecord(item) && text(item.title, 160) && text(item.source, 40)
          ? {
              source: text(item.source, 40)!,
              brand: brandOf(item.brand),
              title: text(item.title, 160)!,
              excerpt: text(item.excerpt, 160),
              time: text(item.time, 30),
              status: statusOf(item.status),
              href: httpsOf(item.href),
            }
          : undefined
      ),
      groups: list(data.groups, 6, (group) =>
        isRecord(group) && text(group.source, 40) && text(group.summary, 160)
          ? {
              source: text(group.source, 40)!,
              brand: brandOf(group.brand),
              count: Math.max(0, Math.round(num(group.count) ?? 0)),
              summary: text(group.summary, 160)!,
              tone: toneOf(group.tone),
            }
          : undefined
      ),
    };
    if (!feed.items.length && !feed.groups.length)
      fail(
        unread(data.items, "items", "a source and a title") ??
          unread(data.groups, "groups", "a source and a summary") ??
          "Card data needs items or groups"
      );
    return feed;
  };
  const feedLayouts: Array<Layout<Feed>> = [
    [
      "news",
      (data) => data.items.length > 0,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-list",
            ...data.items.map((item) =>
              h(
                "li",
                "wc-divided",
                row(
                  item.href,
                  "wc-news",
                  mark(item.brand, item.source),
                  h(
                    "span",
                    "wc-col wc-gap-xxs wc-grow",
                    h("span", "wc-sm wc-w5 wc-c1 wc-clamp-2", item.title),
                    item.excerpt && h("span", "wc-xs wc-c2 wc-clamp-1", item.excerpt),
                    h(
                      "span",
                      "wc-row-center wc-gap-sm wc-xs wc-c3",
                      item.status && status(item.status),
                      h(
                        "span",
                        null,
                        [item.source, item.time].filter(Boolean).join(" · ")
                      )
                    )
                  )
                )
              )
            )
          ),
        ]),
      }),
    ],
    [
      "digest",
      (data) => data.groups.length > 0,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-col wc-gap-xs",
            ...data.groups.map((group) =>
              h(
                "li",
                "wc-digest",
                mark(group.brand, group.source),
                h(
                  "span",
                  "wc-col wc-gap-xxs wc-grow",
                  h(
                    "span",
                    "wc-row-center wc-gap-sm",
                    h("span", "wc-sm wc-w5 wc-c1", group.source),
                    h(
                      "span",
                      "wc-row-center wc-gap-xs wc-xs wc-c3 wc-num",
                      dot(group.tone),
                      String(group.count)
                    )
                  ),
                  h("span", "wc-sm wc-c2", group.summary)
                )
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // =============================================================== timer
  type Timer = {
    frame: Frame;
    label: string;
    deadline?: number | undefined;
    remaining?: number | undefined;
    total?: number | undefined;
    paused: boolean;
    phase: "focus" | "break";
    cycle?: { current: number; total: number } | undefined;
    daysLeft?: number | undefined;
    date?: string | undefined;
    elapsedRatio?: number | undefined;
    note?: string | undefined;
  };
  const timerOf = (data: Record<string, unknown>): Timer => {
    const deadline =
      typeof data.endsAt === "string" ? Date.parse(data.endsAt) : Number.NaN;
    const cycle = isRecord(data.cycle) ? data.cycle : undefined;
    const current = Math.round(num(cycle?.current) ?? 0);
    const total = Math.round(num(cycle?.total) ?? 0);
    const timer: Timer = {
      frame: frameOf(data),
      label: need(data.label, "a label", 80),
      deadline: Number.isFinite(deadline) ? deadline : undefined,
      remaining: num(data.remainingSeconds),
      total: num(data.totalSeconds),
      paused: data.paused === true,
      phase: data.phase === "break" ? "break" : "focus",
      cycle:
        total > 0 && total <= 8 && current >= 1 && current <= total
          ? { current, total }
          : undefined,
      daysLeft: num(data.daysLeft),
      date: text(data.date, 40),
      elapsedRatio: num(data.elapsedRatio),
      note: text(data.note, 120),
    };
    if (
      timer.deadline === undefined &&
      timer.remaining === undefined &&
      timer.daysLeft === undefined
    )
      fail(
        data.endsAt == null
          ? "Card data needs endsAt, remainingSeconds or daysLeft"
          : "Card data endsAt needs an ISO time"
      );
    return timer;
  };
  const clockText = (seconds: number) => {
    const whole = Math.max(0, Math.round(seconds));
    return `${String(Math.floor(whole / 60)).padStart(2, "0")}:${String(whole % 60).padStart(2, "0")}`;
  };
  const phaseInk = {
    focus: [
      "var(--color-fg-warning-primary)",
      "var(--color-fg-error-primary)",
      "wc-text-warning",
    ],
    break: [
      "var(--color-fg-success-primary)",
      "var(--color-bg-brand-solid)",
      "wc-text-success",
    ],
    done: [
      "var(--color-fg-success-primary)",
      "var(--color-fg-success-primary)",
      "wc-text-success",
    ],
  } as const;
  const timerLayouts: Array<Layout<Timer>> = [
    [
      "countdown",
      (data) => data.deadline !== undefined || data.remaining !== undefined,
      (data) => {
        const running = data.deadline !== undefined && !data.paused;
        const cycle = data.cycle;
        const secondsLeft = (now: number) =>
          running
            ? Math.max(0, Math.ceil((data.deadline! - now) / 1000))
            : Math.max(0, Math.round(data.remaining ?? 0));
        const total = Math.max(data.total ?? secondsLeft(Date.now()), 1);
        const center = 80;
        const radius = 62;
        const length = 2 * Math.PI * radius;
        const point = (turn: number, distance: number) => ({
          x: (center + distance * Math.sin(turn * 2 * Math.PI)).toFixed(2),
          y: (center - distance * Math.cos(turn * 2 * Math.PI)).toFixed(2),
        });
        const id = nextId();
        const stopFrom = svg("stop", { offset: "0%" });
        const stopTo = svg("stop", { offset: "100%" });
        const arc = svg("circle", {
          class: cx("wc-timer-arc", data.paused && "wc-dim"),
          cx: center,
          cy: center,
          r: radius,
          fill: "none",
          stroke: `url(#${id})`,
          "stroke-linecap": "round",
          "stroke-width": 9,
          transform: `rotate(-90 ${center} ${center})`,
        });
        const bead = svg("circle", { r: 2.5, fill: "var(--color-bg-popup-secondary)" });
        const ticks = Array.from({ length: 60 }, (_, index) => {
          const major = index % 5 === 0;
          const inner = point(index / 60, major ? 70 : 73);
          const outer = point(index / 60, 77);
          return svg("line", {
            x1: inner.x,
            y1: inner.y,
            x2: outer.x,
            y2: outer.y,
            stroke: major ? "var(--color-fg-quinary)" : "var(--color-border-primary)",
            "stroke-linecap": "round",
            "stroke-width": major ? 2 : 1.25,
          });
        });
        const dial = h(
          "div",
          "wc-dial",
          hidden(
            svg(
              "svg",
              { class: "wc-dial-svg", viewBox: "0 0 160 160" },
              svg(
                "defs",
                {},
                svg(
                  "linearGradient",
                  { id, x1: 0, x2: 1, y1: 0, y2: 1 },
                  stopFrom,
                  stopTo
                )
              ),
              svg("g", {}, ...ticks),
              svg("circle", {
                cx: center,
                cy: center,
                r: radius,
                fill: "none",
                stroke: "var(--color-bg-quaternary)",
                "stroke-width": 9,
              }),
              arc,
              bead
            )
          )
        );
        const orbit = running
          ? hidden(h("span", "wc-orbit", h("span", "wc-orbit-dot")))
          : null;
        if (orbit && data.deadline !== undefined) {
          const intoMinute =
            (60_000 - ((data.deadline - Date.now()) % 60_000)) % 60_000;
          orbit.style.animationDelay = `-${intoMinute}ms`;
          dial.append(orbit);
        }
        const digits = h("time", "wc-digits");
        const faceTime = h("span", "wc-dial-time", digits);
        const faceTotal = h("span", "wc-xs wc-c3 wc-num", `/ ${clockText(total)}`);
        const face = h("div", "wc-dial-face", faceTime, faceTotal);
        dial.append(face);
        const chip = h("span", "wc-timer-chip");
        const layout = h("div", "wc-row-center wc-gap-xl", dial);
        let shown = "";
        let finished = false;
        let stop: (() => void) | undefined;
        const update = (now: number) => {
          const left = secondsLeft(now);
          const done = left === 0;
          const inkSet = phaseInk[done ? "done" : data.phase];
          layout.style.setProperty("--wc-accent", inkSet[0]);
          stopFrom.setAttribute("stop-color", inkSet[0]);
          stopTo.setAttribute("stop-color", inkSet[1]);
          arc.style.filter = `drop-shadow(0 0 5px color-mix(in oklch, ${inkSet[1]} 35%, transparent))`;
          const ratio = done ? 1 : left / total;
          arc.setAttribute("stroke-dasharray", `${ratio * length} ${length}`);
          const tip = point(ratio, radius);
          bead.setAttribute("cx", tip.x);
          bead.setAttribute("cy", tip.y);
          bead.style.display = running && !done && ratio > 0 ? "" : "none";
          const paused = data.paused && !done;
          chip.className = cx("wc-timer-chip", paused ? "wc-c3" : inkSet[2]);
          chip.replaceChildren(
            hidden(
              h("span", cx("wc-dot", paused ? "wc-dot-neutral" : "wc-dot-accent"))
            ),
            done
              ? copy.timeUp
              : paused
                ? copy.paused
                : data.phase === "break"
                  ? copy.rest
                  : copy.focus
          );
          if (done && !finished) {
            finished = true;
            stop?.();
            orbit?.remove();
            face.replaceChildren(
              icon("check", "wc-dial-check"),
              h("span", "wc-sm wc-w5 wc-c1", copy.timeUp)
            );
            // Only a countdown seen running celebrates reaching zero.
            if (shown) dial.classList.add("wc-dial-complete");
            return;
          }
          if (done) return;
          const next = clockText(left);
          if (next === shown) return;
          const [minutes = "0", seconds = "0"] = next.split(":");
          digits.setAttribute("datetime", `PT${Number(minutes)}M${Number(seconds)}S`);
          if (!shown || digits.childElementCount !== next.length) {
            digits.replaceChildren(
              ...[...next].map((char) =>
                h("span", "wc-digit-slot", h("span", null, char))
              )
            );
          } else {
            [...next].forEach((char, index) => {
              if (char !== shown[index])
                digits.children[index]?.replaceChildren(
                  h("span", "wc-digit-roll", char)
                );
            });
          }
          shown = next;
        };
        update(Date.now());
        if (running && !finished)
          stop = everySecond((now) => {
            // A card replaced by another update releases the clock on its next tick.
            if (layout.isConnected) update(now);
            else stop?.();
          });
        layout.append(
          h(
            "div",
            "wc-col wc-gap-xs",
            chip,
            h("span", "wc-md wc-w6 wc-c1", data.label),
            data.note && h("span", "wc-sm wc-c3", data.note),
            cycle &&
              h(
                "span",
                "wc-row-center wc-gap-sm wc-pad-t",
                hidden(
                  h(
                    "span",
                    "wc-row-center wc-gap-xs",
                    ...Array.from({ length: cycle.total }, (_, index) =>
                      h(
                        "span",
                        cx(
                          "wc-cycle",
                          index + 1 < cycle.current && "wc-cycle-done",
                          index + 1 === cycle.current && "wc-cycle-now"
                        )
                      )
                    )
                  )
                ),
                h(
                  "span",
                  "wc-xs wc-c3 wc-num",
                  fill(copy.timerCycle, { current: cycle.current, total: cycle.total })
                )
              )
          )
        );
        return { root: card(data.frame, [layout]), cleanup: () => stop?.() };
      },
    ],
    [
      "event",
      (data) => data.daysLeft !== undefined,
      (data) => {
        const bar =
          data.elapsedRatio === undefined
            ? undefined
            : progressBar(data.note ?? data.label);
        bar?.set(data.elapsedRatio ?? 0);
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-col wc-gap-xxs",
              h("span", "wc-sm wc-c2", data.label),
              h(
                "span",
                "wc-baseline wc-gap-xs",
                h("span", "wc-display-lg wc-tight wc-w6 wc-c1", String(data.daysLeft)),
                h("span", "wc-lg wc-c3", copy.days)
              ),
              data.date && h("span", "wc-sm wc-c3", data.date)
            ),
            bar &&
              h(
                "div",
                "wc-col wc-gap-xs",
                bar.node,
                data.note && h("span", "wc-xs wc-c3", data.note)
              ),
          ]),
        };
      },
    ],
  ];

  // ------------------------------------------------------------- dispatch
  type Kind = {
    parse: (data: Record<string, unknown>) => unknown;
    layouts: Array<Layout<unknown>>;
  };
  const kind = <Data>(
    parse: (data: Record<string, unknown>) => Data,
    layouts: Array<Layout<Data>>
  ): Kind => ({
    parse,
    layouts: layouts as unknown as Array<Layout<unknown>>,
  });
  const kinds: Record<string, Kind> = {
    forecast: kind(forecastOf, forecastLayouts),
    options: kind(optionsOf, optionsLayouts),
    metric: kind(metricsOf, metricLayouts),
    trend: kind(trendOf, trendLayouts),
    comparison: kind(comparisonOf, comparisonLayouts),
    schedule: kind(scheduleOf, scheduleLayouts),
    checklist: kind(checklistOf, checklistLayouts),
    composition: kind(compositionOf, compositionLayouts),
    place: kind(placesOf, placeLayouts),
    feed: kind(feedOf, feedLayouts),
    timer: kind(timerOf, timerLayouts),
  };

  const mounted = new Map<HTMLElement, Built>();
  const release = (target: HTMLElement) => {
    mounted.get(target)?.cleanup?.();
    mounted.delete(target);
  };

  return {
    mount(target, spec, key) {
      const definition =
        typeof spec.kind === "string" && Object.hasOwn(kinds, spec.kind)
          ? kinds[spec.kind]
          : undefined;
      if (!definition)
        fail(`Unsupported card kind. Use ${Object.keys(kinds).join(", ")}`);
      if (!isRecord(spec.data)) fail("Card data must be an object");
      const data = definition!.parse(spec.data as Record<string, unknown>);
      const [layout, , render] = pick(
        definition!.layouts,
        data,
        `${env.seed}:${key}`,
        spec.variant
      );
      release(target);
      const built = render(data, key);
      built.root.dataset.layout = `${spec.kind as string}.${layout}`;
      mounted.set(target, built);
      const fragment = document.createDocumentFragment();
      fragment.append(built.root);
      return fragment;
    },
    receiveIcons(icons) {
      const received = isRecord(icons) ? icons : {};
      for (const [name, source] of Object.entries(received)) {
        if (!asked.has(name) || brandIcons.has(name)) continue;
        const known =
          typeof source === "string" && source.length <= 20_000 ? source : "";
        brandIcons.set(name, known);
        for (const node of waiting.get(name) ?? []) settle(node, known, true);
        waiting.delete(name);
      }
    },
    receiveState(state) {
      restore(state);
      for (const built of mounted.values()) built.sync?.();
    },
    dispose() {
      for (const target of mounted.keys()) release(target);
    },
  };
}
