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
  /** The viewer's IANA time zone for ISO times; empty uses the frame's own zone. */
  timeZone?: string | undefined;
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
  /**
   * Draws `comma.chart` data the way the trend and bars cards draw theirs.
   * The runtime has checked the data: equal lengths, finite numbers.
   */
  chart(spec: {
    type: "bar" | "line";
    labels: string[];
    series: Array<{ name: string; values: number[] }>;
  }): DocumentFragment;
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
    arrivesBy: "Arrives by {time}",
    orderHeadline: "{status}, {arrival}",
    offline: "Offline",
    upNext: "Up next",
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
    /** The observation time on the viewer's clock. */
    observedAt?: string | undefined;
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
  /**
   * Shapes the templates draw themselves, so controls and seals show on every
   * host, including phones that pass no icons.
   */
  const shapes: Record<string, string> = {
    play: "M8 5.6v12.8a1 1 0 0 0 1.53.85l10.2-6.4a1 1 0 0 0 0-1.7L9.53 4.75A1 1 0 0 0 8 5.6Z",
    pause:
      "M7.5 5h2a1.5 1.5 0 0 1 1.5 1.5v11A1.5 1.5 0 0 1 9.5 19h-2A1.5 1.5 0 0 1 6 17.5v-11A1.5 1.5 0 0 1 7.5 5Zm7 0h2A1.5 1.5 0 0 1 18 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-2a1.5 1.5 0 0 1-1.5-1.5v-11A1.5 1.5 0 0 1 14.5 5Z",
    next: "M4.5 6.3v11.4a1 1 0 0 0 1.56.83l8.3-5.7a1 1 0 0 0 0-1.66l-8.3-5.7A1 1 0 0 0 4.5 6.3ZM17.25 5h.5c.69 0 1.25.56 1.25 1.25v11.5c0 .69-.56 1.25-1.25 1.25h-.5c-.69 0-1.25-.56-1.25-1.25V6.25c0-.69.56-1.25 1.25-1.25Z",
    check: "m5 12.5 4.5 4.5L19 7.5",
  };
  const shape = (name: string, className?: string) =>
    hidden(
      h(
        "span",
        cx("wc-icon", className),
        svg(
          "svg",
          { viewBox: "0 0 24 24", fill: name === "check" ? "none" : "currentColor" },
          svg(
            "path",
            name === "check"
              ? {
                  d: shapes[name]!,
                  stroke: "currentColor",
                  "stroke-width": 2.5,
                  "stroke-linecap": "round",
                  "stroke-linejoin": "round",
                }
              : { d: shapes[name]! }
          )
        )
      )
    );
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
  // Text stays as written: the card's width decides how much of it shows.
  const text = (value: unknown) =>
    typeof value === "string" && value.trim() ? value : undefined;
  // Ids and filter keys stay as written: they must match saved progress.
  const ident = (value: unknown, max: number) =>
    typeof value === "string" && value.trim() ? value.slice(0, max) : undefined;
  const need = (value: unknown, field: string) =>
    text(value) ?? fail(`Card data needs ${field}`);
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
  /**
   * How wide text is, in ems of its own size: a CJK or other full-width
   * character counts one, any other 0.62. Layouts size a column or pick
   * themselves from it before anything is drawn.
   */
  const widthOf = (value: string) => {
    let total = 0;
    for (const character of value)
      total +=
        /[\u1100-\u11ff\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(
          character
        )
          ? 1
          : 0.62;
    return total;
  };
  /**
   * `label` in pieces a narrow slot may wrap between: after a dot, slash, dash
   * or underscore inside it. A domain or a path then breaks there before it
   * breaks inside a word.
   */
  const breakable = (label: string): Child[] =>
    label
      .replaceAll(/(.)([./_-])(?=[^\s./_-])/g, "$1$2\n")
      .split("\n")
      .flatMap((piece, index) =>
        index ? [document.createElement("wbr"), piece] : [piece]
      );
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
  // The arrow shows which way a change went, so a sign written in its text is
  // not shown twice; a change with no direction takes it from that sign. A
  // rise is good and a fall is not, unless the data says otherwise.
  const deltaOf = (value: unknown): Delta | undefined => {
    if (!isRecord(value) || !text(value.value)) return undefined;
    const written = text(value.value)!.trim();
    const sign = /^[+＋]/.test(written)
      ? "up"
      : /^[-−–－]/.test(written)
        ? "down"
        : undefined;
    const direction =
      value.direction === "up" ||
      value.direction === "down" ||
      value.direction === "flat"
        ? value.direction
        : (sign ?? "up");
    const unsigned = written.replace(/^[-+−–＋－]\s*/, "");
    return {
      value: direction === "flat" || !unsigned ? written : unsigned,
      direction,
      good: typeof value.good === "boolean" ? value.good : direction !== "down",
    };
  };
  // A status is its label alone, or a label with a tone.
  const statusOf = (value: unknown) =>
    text(value)
      ? { label: text(value)!, tone: "neutral" as Tone }
      : isRecord(value) && text(value.label)
        ? { label: text(value.label)!, tone: toneOf(value.tone) }
        : undefined;
  // An ISO time with an offset names one moment; anything else is not a moment.
  const momentOf = (value: unknown) => {
    if (
      typeof value !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})$/i.test(
        value
      )
    )
      return undefined;
    const moment = Date.parse(value);
    return Number.isFinite(moment) ? moment : undefined;
  };
  // A moment on the viewer's clock: the time today, the date before that, and
  // the year too outside this year.
  const clockFor = (timeZone: string | undefined) => {
    const at = (options: Intl.DateTimeFormatOptions) =>
      new Intl.DateTimeFormat(env.locale || undefined, {
        timeZone,
        hour: "2-digit",
        minute: "2-digit",
        ...options,
      });
    const day = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    const time = at({});
    const date = at({ month: "numeric", day: "numeric" });
    const full = at({ year: "numeric", month: "numeric", day: "numeric" });
    return (moment: number) => {
      const today = day.format(Date.now());
      const then = day.format(moment);
      if (then === today) return time.format(moment);
      return then.slice(0, 4) === today.slice(0, 4)
        ? date.format(moment)
        : full.format(moment);
    };
  };
  let clockOf: (moment: number) => string;
  try {
    clockOf = clockFor(env.timeZone || undefined);
  } catch {
    // An unknown zone name falls back to the frame's own zone.
    clockOf = clockFor(undefined);
  }
  const momentText = (value: unknown) => {
    const moment = momentOf(value);
    return moment === undefined ? undefined : clockOf(moment);
  };
  const actionsOf = (value: unknown, limit: number): Frame["actions"] =>
    list(value, limit, (action) =>
      // The prompt is sent, not shown, so a cut adds no ellipsis to it.
      isRecord(action) && text(action.label) && ident(action.prompt, 4000)
        ? { label: text(action.label)!, prompt: ident(action.prompt, 4000)! }
        : undefined
    );
  // Actions only propose a follow-up; the user sends it from the chat.
  const actionButton = (action: Frame["actions"][number]) => {
    const button = h("button", "wc-action", action.label) as HTMLButtonElement;
    button.type = "button";
    button.addEventListener("click", (event) => {
      if (event.isTrusted) env.send({ type: "request", value: action.prompt });
    });
    return button;
  };
  const frameOf = (data: Record<string, unknown>): Frame => ({
    title: need(data.title, "a title"),
    meta: text(data.meta),
    source: text(data.source),
    sourceBrand: brandOf(data.sourceBrand),
    updatedAt: text(data.updatedAt),
    observedAt: momentText(data.observedAt),
    actions: actionsOf(data.actions, 2),
  });

  // A number as it was given, grouped for the reader: every digit a double
  // holds, so 0.001 stays 0.001 and 0.1 + 0.2 reads 0.3.
  let formatNumber: (value: number) => string;
  try {
    const format = new Intl.NumberFormat(env.locale || undefined, {
      maximumSignificantDigits: 15,
    });
    formatNumber = (value) => format.format(value);
  } catch {
    formatNumber = (value) => String(value);
  }
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
  /**
   * A known brand's logo on a neutral tile. A name with no brand gets a tinted
   * monogram of the same size, or, among entries that have logos (`plain`), its
   * initial on their tile: one set of entries reads as one family.
   */
  const avatarTones = ["blue", "purple", "success", "orange", "pink", "indigo"];
  const initialOf = (name: string) => [...name][0] ?? "";
  const mark = (
    brand: string | undefined,
    name: string,
    size: "sm" | "md" | "lg" = "md",
    plain = false
  ) => {
    if (!brand && !plain) {
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
    if (brand) {
      tile.dataset.initial = initialOf(name);
      place(tile, brand);
    } else tile.textContent = initialOf(name);
    return tile;
  };
  /** Whether any of `entries` has a brand, so each of them takes a tile. */
  const branded = (entries: Array<{ brand?: string | undefined }>) =>
    entries.some((entry) => entry.brand);

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

  /**
   * Where bars of `values` stand in a plot that runs from the lowest value, or
   * zero, to the highest, `full` or zero. `headroom` is the share of the plot
   * kept clear above the highest bar for its value. A bar runs between zero
   * and its value, so a negative one hangs under the zero line.
   */
  const barPlot = (values: number[], headroom = 0, full = 0) => {
    const low = Math.min(0, ...values);
    const size = (Math.max(0, full, ...values) - low) / (1 - headroom) || 1;
    const at = (value: number) => (value - low) / size;
    return {
      /** Whether a bar hangs under zero, so the zero line shows. */
      signed: low < 0,
      /** How far along the plot `value` is, from 0 to 1. */
      at,
      /** Where the bar of `value` starts and how long it is, as shares of the plot. */
      bar: (value: number) => ({
        from: at(Math.min(value, 0)),
        length: Math.abs(value) / size,
      }),
    };
  };
  const percent = (share: number) => `${share * 100}%`;
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
    options: Array<{ key: string; label: string; count?: number | undefined }>,
    value: string,
    onChange: (key: string) => void
  ) => {
    const group = h("div", "wc-seg");
    group.setAttribute("role", "group");
    group.setAttribute("aria-label", label);
    group.style.setProperty("--wc-seg-count", String(options.length));
    group.append(hidden(h("span", "wc-seg-thumb")));
    const buttons = options.map((option, index) => {
      const button = h(
        "button",
        "wc-seg-option",
        option.label,
        option.count !== undefined && h("span", "wc-seg-count", String(option.count))
      ) as HTMLButtonElement;
      button.type = "button";
      // The count is its own span; the name keeps a space before it.
      if (option.count !== undefined)
        button.setAttribute("aria-label", `${option.label} ${option.count}`);
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

  type FilterOption = { key: string; label: string };
  const filtersOf = (value: unknown) =>
    list(value, 4, (filter): FilterOption | undefined =>
      isRecord(filter) && ident(filter.key, 40) && text(filter.label)
        ? { key: ident(filter.key, 40)!, label: text(filter.label)! }
        : undefined
    );
  const filterKeysOf = (value: unknown) =>
    Array.isArray(value) ? list(value, 8, (key) => ident(key, 40)) : undefined;
  /**
   * Fills `rows` with the items a local filter shows, and returns the filter
   * control. An item without filterKeys shows under every filter. A filter
   * that matches no item is left out, so no choice empties the list; with
   * fewer than two left there is no control and every item shows.
   */
  const filtered = <T extends { filterKeys?: string[] | undefined }>(
    label: string,
    filters: FilterOption[],
    items: T[],
    rows: HTMLElement,
    draw: (item: T) => Node,
    counted = false
  ) => {
    const shows = (item: T, key: string) =>
      !key || (item.filterKeys?.includes(key) ?? true);
    // Each choice can name how many items it shows, counted here from the data.
    const usable = filters
      .map((filter) => ({
        ...filter,
        count: items.filter((item) => shows(item, filter.key)).length,
      }))
      .filter((filter) => filter.count > 0)
      .map((filter) => (counted ? filter : { ...filter, count: undefined }));
    const render = (key: string) =>
      rows.replaceChildren(...items.filter((item) => shows(item, key)).map(draw));
    const first = usable.length > 1 ? usable[0]!.key : "";
    render(first);
    return usable.length > 1 ? segmented(label, usable, first, render) : null;
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
    const provenance = [frame.source, frame.updatedAt, frame.observedAt]
      .filter(Boolean)
      .join(" · ");
    if (provenance || frame.actions.length) {
      const glyph =
        frame.sourceBrand && frame.source ? hidden(h("span", "wc-glyph")) : null;
      if (glyph && frame.sourceBrand) place(glyph, frame.sourceBrand);
      const foot = h(
        "footer",
        "wc-foot",
        h("p", "wc-src", glyph, h("span", null, provenance))
      );
      for (const action of frame.actions) foot.append(actionButton(action));
      root.append(foot);
    }
    return root;
  };

  type Stage = {
    label: string;
    detail?: string | undefined;
    state: "done" | "current" | "upcoming";
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
      text(day.label) &&
      num(day.high) !== undefined &&
      num(day.low) !== undefined
        ? {
            label: text(day.label)!,
            condition: conditionOf(day.condition),
            conditionLabel: text(day.conditionLabel) ?? "",
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
      location: text(data.location),
      current: current && {
        temperature: num(current.temperature)!,
        condition: conditionOf(current.condition),
        label: text(current.label) ?? "",
        details: [
          num(current.feelsLike) === undefined
            ? null
            : `${copy.feelsLike} ${num(current.feelsLike)}°`,
          num(current.humidity) === undefined
            ? null
            : `${copy.humidity} ${num(current.humidity)}%`,
          text(current.wind),
        ]
          .filter(Boolean)
          .join(" · "),
      },
      days,
      highlight: text(data.highlight),
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
    filters: FilterOption[];
    items: Option[];
  };
  const optionsOf = (data: Record<string, unknown>): Options => {
    const items = list(data.items, 8, (item): Option | undefined =>
      isRecord(item) && text(item.primary)
        ? {
            id: ident(item.id, 60) ?? ident(item.primary, 80)!,
            primary: text(item.primary)!,
            secondary: text(item.secondary),
            span: text(item.span),
            meta: text(item.meta),
            price: text(item.price),
            priceNote: text(item.priceNote),
            status: statusOf(item.status),
            tags: list(item.tags, 3, (tag) => text(tag)),
            reason: text(item.reason),
            recommended: item.recommended === true,
            filterKeys: filterKeysOf(item.filterKeys),
          }
        : undefined
    );
    if (!items.length)
      fail(unread(data.items, "items", "primary text") ?? "Card data needs items");
    return {
      frame: frameOf(data),
      filters: filtersOf(data.filters),
      items,
    };
  };
  const timed = (data: Options) =>
    data.items.every((item) => item.secondary !== undefined);
  const priceColumn = (item: Option) =>
    h(
      "span",
      "wc-price-col wc-trail",
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
        const control = filtered(
          data.frame.title,
          data.filters,
          data.items,
          rows,
          (item) =>
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
        );
        return { root: card(data.frame, [control, rows]) };
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
                  "wc-baseline wc-trail",
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
                        item.meta && h("span", "wc-xs wc-c3", item.meta)
                      ),
                      h(
                        "span",
                        "wc-baseline wc-trail",
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
    const metrics = list(data.metrics, 6, (metric): Metric | undefined =>
      isRecord(metric) && text(metric.value)
        ? {
            label: text(metric.label) ?? "",
            value: text(metric.value)!,
            unit: text(metric.unit),
            delta: deltaOf(metric.delta),
            caption: text(metric.caption),
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
        valueLabel: need(goal.valueLabel, "goal.valueLabel"),
        targetLabel: need(goal.targetLabel, "goal.targetLabel"),
        note: text(goal.note),
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
  /**
   * The tiles of several metrics. A tile is as wide as its widest value needs,
   * so a number is never broken across lines: long values get fewer columns.
   * Five or six metrics take three columns at most, so no row is left with one.
   */
  const metricTiles = (metrics: Metric[]) => {
    const widest = Math.max(
      ...metrics.map(
        (metric) => widthOf(metric.value) + widthOf(metric.unit ?? "") * 0.7
      )
    );
    const grid = h(
      "ul",
      "wc-metric-grid",
      ...metrics.map((metric) =>
        h(
          "li",
          "wc-tile",
          h("span", "wc-xs wc-c3", metric.label),
          value(metric, "wc-title-3"),
          metric.delta && delta(metric.delta),
          metric.caption && h("span", "wc-xs wc-c3", metric.caption)
        )
      )
    );
    // A little over the estimate, so the widest value never breaks in its tile.
    grid.style.setProperty("--wc-tile-ems", (widest + 0.4).toFixed(2));
    // Four metrics sit four or two in a row, five or six sit three or two:
    // the wider count when a full-width card's tiles hold the widest value.
    const [many, room] = metrics.length > 4 ? [3, 7] : [4, 5];
    grid.style.setProperty(
      "--wc-tile-columns",
      String(metrics.length > 3 && widest > room ? 2 : many)
    );
    return grid;
  };
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
            // Metrics given beside a goal show under it.
            data.metrics.length > 0 && metricTiles(data.metrics),
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
                  "wc-row-center wc-wrap wc-gap-sm",
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
      (data) => ({ root: card(data.frame, [metricTiles(data.metrics)]) }),
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
      value: text(data.value),
      delta: deltaOf(data.delta),
      ranges: list(data.ranges, 4, (range) => {
        if (!isRecord(range) || !ident(range.key, 20) || !text(range.label))
          return undefined;
        const points = numbers(range.points, 64);
        return points.length > 1
          ? {
              key: ident(range.key, 20)!,
              label: text(range.label)!,
              points,
              axis: list(range.axis, 6, (tick) => text(tick)),
            }
          : undefined;
      }),
      bars: bars && {
        labels: list(bars.labels, 31, (label) => text(label) ?? ""),
        values: numbers(bars.values, 31),
        valueLabels: list(bars.valueLabels, 31, (label) => text(label) ?? ""),
        averageLabel: text(bars.averageLabel),
      },
      series: list(data.series, 6, (item): Series | undefined => {
        if (!isRecord(item) || !text(item.label) || !text(item.value)) return undefined;
        const points = numbers(item.points, 64);
        return points.length > 1
          ? {
              label: text(item.label)!,
              brand: brandOf(item.brand),
              value: text(item.value)!,
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
  /** The trend's main value, its change and its brand; nothing when the data has none. */
  const headline = (data: Trend) =>
    data.brand || data.value || data.delta
      ? h(
          "div",
          "wc-row-center wc-gap-md",
          data.brand && mark(data.brand, data.frame.title, "lg"),
          h(
            "div",
            "wc-col wc-gap-xxs",
            data.value && h("span", "wc-title-2 wc-w6 wc-c1", data.value),
            data.delta && delta(data.delta)
          )
        )
      : null;
  /** Sets an upright bar between zero and its value in the plot. */
  const stand = (
    bar: HTMLElement,
    extent: { from: number; length: number },
    down: boolean
  ) => {
    bar.style.height = percent(extent.length);
    if (extent.from > 0) bar.style.setProperty("--wc-lift", extent.from.toFixed(4));
    if (down) bar.classList.add("wc-bar-down");
  };
  /** Lays a sideways bar's fill between zero and its value on its track. */
  const lay = (track: HTMLElement, extent: { from: number; length: number }) => {
    track.style.setProperty("--wc-share", percent(extent.length));
    if (extent.from > 0) track.style.setProperty("--wc-from", percent(extent.from));
  };
  /** The zero line of a plot that has a bar under it. */
  const zeroLine = (area: ReturnType<typeof barPlot>) => {
    if (!area.signed) return null;
    const line = hidden(h("div", "wc-bars-zero"));
    line.style.bottom = percent(area.at(0));
    return line;
  };
  /**
   * Upright bars over their labels. A series of periods marks its latest bar;
   * up to eight bars each carry their value, and more than that only the
   * latest does. The plot keeps room above its tallest bar for a value.
   */
  const columnBars = (options: {
    title: string;
    labels: string[];
    values: number[];
    shown: string[];
    averageLabel?: string | undefined;
    /** The last bar is the current period. */
    latest: boolean;
    tones?: Array<Tone | undefined> | undefined;
  }) => {
    const { labels, values, shown } = options;
    const count = values.length;
    const last = count - 1;
    const few = count <= 8;
    // Of many bars only one carries its value: the latest of a series of
    // periods, the tallest of anything else.
    const marked = options.latest ? last : values.indexOf(Math.max(...values));
    const area = barPlot(values, 0.2);
    const average = values.reduce((sum, item) => sum + item, 0) / count;
    // The dashed line is the mean of the bars and shows only with its label.
    const averageLine = options.averageLabel
      ? hidden(h("div", "wc-bars-average"))
      : null;
    const plot = hidden(
      h(
        "div",
        "wc-bars-plot",
        ...values.map((item, index) => {
          const bar = h(
            "div",
            cx("wc-bar-col", options.latest && index === last && "wc-bar-latest")
          );
          // Bars that are not a series of periods are all drawn in their tone.
          if (!options.latest) bar.dataset.tone = options.tones?.[index] ?? "brand";
          stand(bar, area.bar(item), item < 0);
          const label =
            few || index === marked
              ? h(
                  "span",
                  cx(
                    "wc-bars-value",
                    index === marked &&
                      (options.latest
                        ? "wc-bars-value-latest"
                        : !few && "wc-bars-value-peak")
                  ),
                  h("span", null, shown[index]!)
                )
              : null;
          // A value stands over its bar, and over the zero line when the bar
          // hangs under it. The styles lift it onto the average line where
          // the bar ends just under that; they read both heights.
          label?.style.setProperty("--wc-bar", percent(area.at(Math.max(item, 0))));
          return h("div", "wc-bar-slot", bar, label);
        }),
        averageLine,
        zeroLine(area)
      )
    );
    if (averageLine) plot.style.setProperty("--wc-average", percent(area.at(average)));
    const figure = h(
      "figure",
      cx("wc-bars", options.averageLabel && "wc-bars-averaged"),
      h(
        "figcaption",
        cx("wc-bars-legend", !options.averageLabel && "wc-sr"),
        sr(options.title),
        options.averageLabel && hidden(h("span", "wc-bars-swatch")),
        options.averageLabel ?? ""
      ),
      plot,
      hidden(
        h(
          "div",
          cx("wc-bars-axis", few && "wc-bars-axis-all"),
          // Every label of a few bars shows, on up to two lines.
          ...labels.map((tick) =>
            h("span", null, h("span", null, ...(few ? breakable(tick) : [tick])))
          )
        )
      )
    );
    // A card is wide, medium or narrow (its container queries); the plot
    // holds about this many ems of its smallest text at each width.
    const widths = [
      ["wide", 40],
      ["medium", 26],
      ["narrow", 18],
    ] as const;
    // Every value shows where the widest one fits over its own bar.
    const widestValue = Math.max(...shown.map(widthOf)) + 1;
    figure.dataset.values = few
      ? widths
          .filter(([, ems]) => widestValue * count <= ems)
          .map(([name]) => name)
          .join(" ")
      : "";
    if (!few) {
      // Many bars are a sequence, so every nth label stands for its
      // neighbours. The step leaves each shown label its own width, counted
      // back from the latest bar.
      const widest = Math.max(...labels.map(widthOf), 1) + 1;
      const ticks = [...figure.querySelectorAll(".wc-bars-axis>span")];
      for (const [name, ems] of widths) {
        const step = Math.max(1, Math.ceil((widest * count) / ems));
        ticks.forEach((tick, index) => {
          if ((last - index) % step === 0) tick.classList.add(`wc-tick-${name}`);
        });
      }
    }
    return figure;
  };
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
        const head = headline(data);
        const picker =
          data.ranges.length > 1 && segmented(copy.range, data.ranges, initial, show);
        return {
          root: card(data.frame, [
            (head || picker) &&
              h("div", "wc-row-end wc-wrap wc-between wc-gap-md", head, picker),
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
        return {
          root: card(data.frame, [
            headline(data),
            columnBars({
              title: data.frame.title,
              labels: bars.labels,
              values: bars.values,
              shown: bars.values.map(
                (item, index) => bars.valueLabels[index] || formatCompact(item)
              ),
              averageLabel: bars.averageLabel,
              latest: true,
            }),
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
            "wc-list wc-watchlist",
            ...data.series.map((item) => {
              const up = item.delta?.direction !== "down";
              return h(
                "li",
                "wc-watch",
                h(
                  "span",
                  "wc-watch-name",
                  mark(item.brand, item.label, "md", branded(data.series)),
                  h("span", "wc-sm wc-w6 wc-c1 wc-clip", item.label)
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
      isRecord(subject) && text(subject.name)
        ? {
            name: text(subject.name)!,
            caption: text(subject.caption),
            recommended: subject.recommended === true,
            brand: brandOf(subject.brand),
          }
        : undefined
    );
    if (subjects.length < 2) fail("Card data needs two or three subjects");
    const rows = list(data.rows, 8, (item) => {
      if (!isRecord(item) || !text(item.label)) return undefined;
      const values = list(item.values, subjects.length, (cell) => text(cell) ?? "—");
      if (values.length !== subjects.length) return undefined;
      const scores = numbers(item.scores, 2);
      const best = num(item.best);
      return {
        label: text(item.label)!,
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
    return { frame: frameOf(data), subjects, rows, verdict: text(data.verdict) };
  };
  const subjectName = (subject: Subject, className: string, among: Subject[]) =>
    h(
      "span",
      "wc-row-center wc-wrap wc-gap-sm",
      branded(among) && mark(subject.brand, subject.name, "md", true),
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
        corner.style.setProperty(
          "--wc-label-ems",
          Math.max(...data.rows.map((item) => widthOf(item.label))).toFixed(2)
        );
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
                          branded(data.subjects) &&
                            mark(subject.brand, subject.name, "md", true),
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
                      subjectName(subject, "wc-sm wc-w5 wc-c1", data.subjects),
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
                  branded(data.subjects) && mark(left.brand, left.name, "md", true),
                  h("span", "wc-md wc-w6 wc-c1 wc-clip", left.name),
                  left.recommended && badge(copy.recommended, "brand")
                ),
                h("span", "wc-xs wc-w5 wc-c4", copy.versus),
                h(
                  "span",
                  "wc-vs-name wc-vs-right",
                  right.recommended && badge(copy.recommended, "brand"),
                  h("span", "wc-md wc-w6 wc-c1 wc-clip", right.name),
                  branded(data.subjects) && mark(right.brand, right.name, "md", true)
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
    /** The date an ISO start falls on; events of several dates show under their dates. */
    day?: string | undefined;
    title: string;
    detail?: string | undefined;
    state: "done" | "current" | "upcoming";
    tone: Tone;
  };
  type Schedule = {
    frame: Frame;
    now?: string | undefined;
    events: Event[];
    stages: Stage[];
    summary?: string | undefined;
  };
  const stateOf = (input: unknown) =>
    input === "done" || input === "current" ? input : "upcoming";
  /**
   * An event time as the card shows it. An ISO time that names a moment is a
   * clock time in the schedule's zone, or on the viewer's clock without one.
   * An ISO time with no offset is the place's own clock time and shows as
   * written. Anything else is display text.
   */
  const clockTime = (input: unknown, zone: unknown) => {
    const written = text(input);
    if (!written) return undefined;
    const zoned = zonedOf(written, zone);
    if (zoned) return { time: zoned.time, day: zoned.date };
    const local =
      /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::\d{2}(?:\.\d{1,9})?)?$/.exec(
        written.trim()
      );
    if (!local) return { time: written, day: undefined };
    const date = Date.UTC(Number(local[1]), Number(local[2]) - 1, Number(local[3]));
    return {
      time: `${local[4]}:${local[5]}`,
      day: Number.isFinite(date)
        ? new Intl.DateTimeFormat(env.locale || undefined, {
            timeZone: "UTC",
            month: "short",
            day: "numeric",
            weekday: "short",
          }).format(date)
        : undefined,
    };
  };
  const scheduleOf = (data: Record<string, unknown>): Schedule => {
    const schedule: Schedule = {
      frame: frameOf(data),
      now: clockTime(data.now, data.zone)?.time,
      events: list(data.events, 8, (event) =>
        isRecord(event) && text(event.start) && text(event.title)
          ? {
              start: clockTime(event.start, data.zone)!.time,
              end: clockTime(event.end, data.zone)?.time,
              day: clockTime(event.start, data.zone)!.day,
              title: text(event.title)!,
              detail: text(event.detail),
              state: stateOf(event.state),
              tone: toneOf(event.tone),
            }
          : undefined
      ),
      stages: list(data.stages, 6, (stage) =>
        isRecord(stage) && text(stage.label)
          ? {
              label: text(stage.label)!,
              detail: text(stage.detail),
              state: stateOf(stage.state),
            }
          : undefined
      ),
      summary: text(data.summary),
    };
    if (!schedule.events.length && schedule.stages.length < 2)
      fail(
        unread(data.events, "events", "a start and a title") ??
          "Card data needs events or at least two stages"
      );
    // One date needs no heading: the card's title names the day.
    if (new Set(schedule.events.map((event) => event.day)).size < 2)
      for (const event of schedule.events) event.day = undefined;
    return schedule;
  };
  /** The heading of a date, before the first event that falls on it. */
  const dayHeading = (event: Event, previous: Event | undefined) =>
    event.day && event.day !== previous?.day ? h("li", "wc-day", event.day) : null;
  const scheduleLayouts: Array<Layout<Schedule>> = [
    [
      "agenda",
      (data) => data.events.length > 0,
      (data) => {
        const items: HTMLElement[] = [];
        for (const [index, event] of data.events.entries()) {
          const heading = dayHeading(event, data.events[index - 1]);
          if (heading) items.push(heading);
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
                  "wc-xs wc-c3",
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
            h("ol", "wc-list wc-times wc-agenda-list", ...items),
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
            "wc-list wc-times",
            ...data.events.flatMap((event, index) => [
              dayHeading(event, data.events[index - 1]),
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
                  (event.end || event.detail) &&
                    h(
                      "span",
                      "wc-xs wc-c3",
                      [event.end ? `${event.start}–${event.end}` : null, event.detail]
                        .filter(Boolean)
                        .join(" · ")
                    )
                )
              ),
            ])
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
        actions: Frame["actions"];
      }>;
    }>;
  };
  const checklistOf = (data: Record<string, unknown>): Checklist => {
    let budget = 20;
    const groups = list(data.groups, 4, (group) => {
      if (!isRecord(group)) return undefined;
      const items = list(group.items, budget, (item) =>
        isRecord(item) && text(item.label)
          ? {
              id: ident(item.id, 60) ?? ident(item.label, 80)!,
              label: text(item.label)!,
              detail: text(item.detail),
              done: item.done === true,
              actions: actionsOf(item.actions, 3),
            }
          : undefined
      );
      budget -= items.length;
      return items.length ? { label: text(group.label) ?? "", items } : undefined;
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
    // One item's actions show at a time.
    const folds: Array<(open: boolean) => void> = [];
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
      const check = h(
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
      if (!item.actions.length) return check;
      // A button inside the label would also toggle the box, so the item's
      // actions sit beside it, folded behind one quiet button. They are built
      // when first shown: a full checklist stays within the node budget.
      const entry = h("div", "wc-check-item", check);
      const more = h("button", "wc-check-more") as HTMLButtonElement;
      more.type = "button";
      more.setAttribute(
        "aria-label",
        item.actions.map((action) => action.label).join(" / ")
      );
      more.setAttribute("aria-expanded", "false");
      let actions: HTMLElement | undefined;
      const fold = (open: boolean) => {
        if (open && !actions)
          entry.append(
            (actions = h("div", "wc-check-actions", ...item.actions.map(actionButton)))
          );
        if (actions) actions.hidden = !open;
        more.setAttribute("aria-expanded", String(open));
      };
      folds.push(fold);
      // Showing the actions sends nothing, so a script may open them too.
      more.addEventListener("click", () => {
        const open = more.getAttribute("aria-expanded") !== "true";
        for (const other of folds) other(false);
        fold(open);
      });
      entry.insertBefore(more, check.nextSibling);
      return entry;
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
      isRecord(segment) && text(segment.label) && (num(segment.value) ?? -1) >= 0
        ? {
            label: text(segment.label)!,
            value: num(segment.value)!,
            valueLabel: text(segment.valueLabel) ?? String(num(segment.value)),
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
      // A total given as a number shows grouped as the viewer's locale writes it.
      total:
        num(data.total) === undefined
          ? need(data.total, "a total")
          : formatNumber(num(data.total)!),
      totalLabel: text(data.totalLabel) ?? "",
      segments,
    };
  };
  const segmentInk = (segment: Composition["segments"][number], index: number) =>
    segment.muted ? ink.muted : seriesInk[index % seriesInk.length]!;
  const legend = (data: Composition, two: boolean) => {
    const sum = data.segments.reduce((total, segment) => total + segment.value, 0);
    // Labels that already state a percent are not followed by a second one.
    const shares = !data.segments.every((segment) => /[%％]/.test(segment.valueLabel));
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
          shares &&
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
      // The ring's centre holds a short total and a label of two short lines.
      (data) => widthOf(data.total) <= 5.6 && widthOf(data.totalLabel) <= 12,
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
    note?: string | undefined;
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
    const places = list(data.places, 8, (item): Place | undefined =>
      isRecord(item) && text(item.name)
        ? {
            name: text(item.name)!,
            category: text(item.category),
            note: text(item.note),
            rating: num(item.rating),
            reviews: text(item.reviews),
            status: statusOf(item.status),
            address: text(item.address),
            distance: text(item.distance),
            eta: text(item.eta),
            href: httpsOf(item.href),
          }
        : undefined
    );
    if (!places.length)
      fail(unread(data.places, "places", "a name") ?? "Card data needs places");
    return { frame: frameOf(data), places };
  };
  /** "4.6 · 2,310 条评价 · 咖啡馆": the rating stands out, the rest reads as one line. */
  const about = (item: Place, withCategory: boolean, className?: string) => {
    const score =
      item.rating === undefined
        ? null
        : h("span", "wc-w5 wc-c1", item.rating.toFixed(1));
    const words = [score && item.reviews, withCategory && item.category]
      .filter(Boolean)
      .join(" · ");
    return score || words
      ? h(
          "span",
          cx("wc-num", className),
          score,
          score && words ? ` · ${words}` : words
        )
      : null;
  };
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
              about(item, true, "wc-xs wc-c3"),
              item.status && status(item.status)
            ),
            item.note && h("p", "wc-sm wc-c2", item.note),
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
      (data) => {
        // A category every row shares says nothing the title does not.
        const mixed = new Set(data.places.map((item) => item.category)).size > 1;
        return {
          root: card(data.frame, [
            h(
              "ol",
              "wc-list",
              ...data.places.map((item, index) => {
                const facts = [
                  about(item, mixed),
                  item.status && status(item.status),
                ].filter(Boolean);
                return h(
                  "li",
                  "wc-divided",
                  row(
                    item.href,
                    "wc-place",
                    hidden(h("span", "wc-place-index", String(index + 1))),
                    h(
                      "span",
                      "wc-col wc-gap-xxs wc-grow",
                      h("span", "wc-sm wc-w5 wc-c1 wc-clamp-2", item.name),
                      facts.length > 0 &&
                        h(
                          "span",
                          "wc-row-center wc-wrap wc-gap-sm wc-xs wc-c3",
                          ...facts
                        ),
                      item.note && h("span", "wc-xs wc-c2", item.note),
                      item.address && h("span", "wc-xs wc-c3", item.address)
                    ),
                    (item.distance || item.eta) &&
                      h(
                        "span",
                        "wc-col wc-end wc-gap-xxs wc-trail",
                        item.distance &&
                          h("span", "wc-sm wc-w5 wc-c1 wc-num", item.distance),
                        item.eta && h("span", "wc-xs wc-c3", item.eta)
                      ),
                    item.href && icon("chevron-right", "wc-chevron")
                  )
                );
              })
            ),
          ]),
        };
      },
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
      tags: string[];
      href?: string | undefined;
      filterKeys?: string[] | undefined;
    }>;
    filters: FilterOption[];
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
      items: list(data.items, 60, (item) =>
        isRecord(item) && text(item.title) && text(item.source)
          ? {
              source: text(item.source)!,
              brand: brandOf(item.brand),
              title: text(item.title)!,
              excerpt: text(item.excerpt),
              time: momentText(item.at) ?? text(item.time),
              status: statusOf(item.status),
              tags: list(item.tags, 3, (tag) => text(tag)),
              href: httpsOf(item.href),
              filterKeys: filterKeysOf(item.filterKeys),
            }
          : undefined
      ),
      filters: filtersOf(data.filters),
      groups: list(data.groups, 6, (group) =>
        isRecord(group) && text(group.source) && text(group.summary)
          ? {
              source: text(group.source)!,
              brand: brandOf(group.brand),
              count: Math.max(0, Math.round(num(group.count) ?? 0)),
              summary: text(group.summary)!,
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
  // Past this many items a feed takes compact rows: a news row costs about
  // twice their nodes, and the widget has 500.
  const newsLimit = 12;
  const feedLayouts: Array<Layout<Feed>> = [
    [
      "news",
      (data) => data.items.length > 0 && data.items.length <= newsLimit,
      (data) => {
        const rows = h("ul", "wc-list");
        const control = filtered(
          data.frame.title,
          data.filters,
          data.items,
          rows,
          (item) =>
            h(
              "li",
              "wc-divided",
              row(
                item.href,
                "wc-news",
                mark(item.brand, item.source, "md", branded(data.items)),
                h(
                  "span",
                  "wc-col wc-gap-xxs wc-grow",
                  h("span", "wc-sm wc-w5 wc-c1 wc-clamp-2", item.title),
                  item.excerpt && h("span", "wc-xs wc-c2", item.excerpt),
                  h(
                    "span",
                    "wc-row-center wc-wrap wc-gap-sm wc-xs wc-c3",
                    item.status && status(item.status),
                    ...item.tags.map((tag) => badge(tag, "gray")),
                    h(
                      "span",
                      null,
                      [item.source, item.time].filter(Boolean).join(" · ")
                    )
                  )
                )
              )
            ),
          true
        );
        return { root: card(data.frame, [control, rows]) };
      },
    ],
    [
      "list",
      // A status list such as a day's pull requests: two lines per item, the
      // status as a colored dot and in words. Excerpts and tags stay out, so a
      // short list with them keeps the news rows.
      (data) =>
        data.items.length > newsLimit ||
        (data.items.length > 1 &&
          data.items.every((item) => !item.excerpt && item.tags.length === 0)),
      (data) => {
        const dotted = data.items.some((item) => item.status);
        const rows = h("ul", cx("wc-list", dotted && "wc-feed-dots"));
        const control = filtered(
          data.frame.title,
          data.filters,
          data.items,
          rows,
          (item) => {
            const line = row(
              item.href,
              "wc-feed-row",
              h("span", "wc-sm wc-w5 wc-c1 wc-clamp-2", item.title),
              h(
                "span",
                "wc-xs wc-c3",
                [item.status?.label, item.source, item.time].filter(Boolean).join(" · ")
              )
            );
            // The dot is drawn by CSS, so a row costs no node for it.
            if (item.status) line.dataset.tone = item.status.tone;
            return h("li", "wc-divided", line);
          },
          true
        );
        return { root: card(data.frame, [control, rows]) };
      },
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
                mark(group.brand, group.source, "md", branded(data.groups)),
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
      label: need(data.label, "a label"),
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
      date: text(data.date),
      elapsedRatio: num(data.elapsedRatio),
      note: text(data.note),
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

  // =============================================================== order
  type Order = {
    frame: Frame;
    brand?: string | undefined;
    orderId?: string | undefined;
    status: string;
    arrival?: string | undefined;
    items: Array<{
      name: string;
      quantity?: number | undefined;
      detail?: string | undefined;
      price?: string | undefined;
    }>;
    total?: string | undefined;
    totalLabel?: string | undefined;
    address?: string | undefined;
    stages: Stage[];
  };
  const orderOf = (data: Record<string, unknown>): Order => {
    const by = momentText(data.arrivesBy);
    const stages = list<Stage>(data.stages, 5, (stage) =>
      isRecord(stage) && text(stage.label)
        ? { label: text(stage.label)!, state: stateOf(stage.state) }
        : undefined
    );
    return {
      frame: frameOf(data),
      brand: brandOf(data.brand),
      orderId: text(data.orderId),
      status: need(data.status, "a status"),
      arrival: by ? fill(copy.arrivesBy, { time: by }) : text(data.arrival),
      items: list(data.items, 6, (item) => {
        if (!isRecord(item) || !text(item.name)) return undefined;
        const quantity = num(item.quantity);
        return {
          name: text(item.name)!,
          quantity:
            quantity !== undefined && quantity >= 1 ? Math.floor(quantity) : undefined,
          detail: text(item.detail),
          price: text(item.price),
        };
      }),
      total: text(data.total),
      totalLabel: text(data.totalLabel),
      address: text(data.address),
      stages: stages.length > 1 ? stages : [],
    };
  };
  /**
   * A header tile: the brand's logo, else the kind's glyph, else (on a host
   * that passes no icons) the title's initial.
   */
  const glyphTile = (brand: string | undefined, title: string, glyph: string) =>
    brand || typeof env.icons[glyph] !== "string"
      ? mark(brand, title, "lg")
      : hidden(h("span", "wc-order-tile", icon(glyph)));
  /** The merchant's logo, or a shopping bag, then its name and the order number. */
  const orderHead = (data: Order) =>
    h(
      "header",
      "wc-row-center wc-gap-md",
      glyphTile(data.brand, data.frame.title, "shopping-bag"),
      h("h3", "wc-order-merchant", data.frame.title),
      data.orderId && h("span", "wc-md wc-c4 wc-num wc-clip", data.orderId),
      data.frame.meta && h("span", "wc-meta wc-clip wc-push", data.frame.meta)
    );
  const orderHeadline = (data: Order) =>
    data.arrival
      ? fill(copy.orderHeadline, { status: data.status, arrival: data.arrival })
      : data.status;
  const itemLine = (item: Order["items"][number]) =>
    [
      item.quantity === undefined ? item.name : `${item.quantity} × ${item.name}`,
      item.detail,
    ]
      .filter(Boolean)
      .join(" · ");
  /**
   * How far the order got, on a rail from where it left to where it arrives:
   * the rail fills to a marker at the current stage, and reaching the last
   * stage fills it whole.
   */
  const orderRail = (stages: Stage[], slim = false) => {
    const current = stages.findIndex((stage) => stage.state === "current");
    const reached =
      current === -1
        ? stages.findLastIndex((stage) => stage.state === "done")
        : current;
    const done = current === -1 && reached === stages.length - 1;
    const ratio = Math.max(reached, 0) / (stages.length - 1);
    const native = h("progress", "wc-sr") as HTMLProgressElement;
    native.max = 100;
    native.value = Math.round(ratio * 100);
    native.setAttribute(
      "aria-label",
      stages[Math.max(reached, 0)]?.label ?? stages[0]?.label ?? ""
    );
    const rail = hidden(
      h(
        "span",
        cx("wc-order-rail", slim && "wc-order-rail-slim"),
        h("span", "wc-order-fill"),
        !slim && h("span", "wc-order-start", icon("send")),
        !slim && h("span", "wc-order-now", icon(done ? "check" : "tag"))
      )
    );
    rail.style.setProperty("--wc-order-progress", String(ratio));
    return h("div", "wc-order-track", native, rail);
  };
  const orderLayouts: Array<Layout<Order>> = [
    [
      "tracking",
      (data) => data.stages.length > 1,
      (data) => ({
        root: card(
          data.frame,
          [
            orderHead(data),
            h(
              "div",
              "wc-col wc-gap-xs",
              h("p", "wc-lg wc-w6 wc-c1", orderHeadline(data)),
              data.items.length > 0 &&
                h(
                  "ul",
                  "wc-col",
                  ...data.items.map((item) =>
                    h("li", "wc-md wc-c3 wc-clip", itemLine(item))
                  )
                )
            ),
            orderRail(data.stages),
          ],
          { header: false }
        ),
      }),
    ],
    [
      "receipt",
      (data) => data.total !== undefined || data.items.some((item) => item.price),
      (data) => ({
        root: card(
          data.frame,
          [
            orderHead(data),
            h("p", "wc-lg wc-w6 wc-c1", orderHeadline(data)),
            data.items.length > 0 &&
              h(
                "ul",
                "wc-col wc-gap-md",
                ...data.items.map((item) =>
                  h(
                    "li",
                    "wc-row-start wc-gap-md",
                    h(
                      "span",
                      "wc-col wc-grow",
                      h("span", "wc-md wc-c1 wc-clamp-2", item.name),
                      item.detail && h("span", "wc-sm wc-c3", item.detail)
                    ),
                    item.quantity !== undefined &&
                      h("span", "wc-md wc-c3 wc-num", `× ${item.quantity}`),
                    item.price && h("span", "wc-md wc-c1 wc-num wc-trail", item.price)
                  )
                )
              ),
            data.total &&
              h(
                "div",
                "wc-order-total",
                h("span", "wc-md wc-c2", data.totalLabel),
                h("span", "wc-title-3 wc-w6 wc-c1 wc-num wc-trail", data.total)
              ),
            data.address && h("p", "wc-sm wc-c3", data.address),
          ],
          { header: false }
        ),
      }),
    ],
    [
      "compact",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            h(
              "div",
              "wc-row-center wc-gap-md",
              glyphTile(data.brand, data.frame.title, "shopping-bag"),
              h(
                "span",
                "wc-col wc-grow",
                h("span", "wc-md wc-w6 wc-c1 wc-clip", orderHeadline(data)),
                h(
                  "span",
                  "wc-sm wc-c3 wc-clip",
                  [data.frame.title, data.items[0] && itemLine(data.items[0])]
                    .filter(Boolean)
                    .join(" · ")
                )
              )
            ),
            data.stages.length > 1 && orderRail(data.stages, true),
          ],
          { header: false, small: true }
        ),
      }),
    ],
  ];

  // ------------------------------------------------- shared by the kinds below
  /** A moment as a clock time and a date in `zone`, or on the viewer's clock. */
  const zonedOf = (input: unknown, zone: unknown) => {
    const moment = momentOf(input);
    if (moment === undefined) return undefined;
    const format = (options: Intl.DateTimeFormatOptions) => {
      const named =
        typeof zone === "string" && /^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/.test(zone)
          ? zone
          : env.timeZone || undefined;
      try {
        return new Intl.DateTimeFormat(env.locale || undefined, {
          ...options,
          timeZone: named,
        }).format(moment);
      } catch {
        return new Intl.DateTimeFormat(env.locale || undefined, options).format(moment);
      }
    };
    return {
      time: format({ hour: "2-digit", minute: "2-digit", hourCycle: "h23" }),
      date: format({ month: "short", day: "numeric", weekday: "short" }),
      month: format({ month: "short" }),
      day: format({ day: "numeric" }),
      weekday: format({ weekday: "short" }),
    };
  };
  type Zoned = NonNullable<ReturnType<typeof zonedOf>>;
  type Fact = { label: string; value: string };
  const factsOf = (input: unknown, max: number) =>
    list(input, max, (item): Fact | undefined =>
      isRecord(item) && text(item.label) && text(item.value)
        ? { label: text(item.label)!, value: text(item.value)! }
        : undefined
    );
  type Control = { label: string; prompt: string };
  const controlOf = (item: unknown): Control | undefined =>
    isRecord(item) && text(item.label) && ident(item.prompt, 4000)
      ? { label: text(item.label)!, prompt: ident(item.prompt, 4000)! }
      : undefined;
  /** A button that proposes its prompt, as a card action does. */
  const proposer = (
    prompt: string,
    className: string,
    label: string,
    ...children: Child[]
  ) => {
    const button = h("button", className, ...children) as HTMLButtonElement;
    button.type = "button";
    button.setAttribute("aria-label", label);
    button.addEventListener("click", (event) => {
      if (event.isTrusted) env.send({ type: "request", value: prompt });
    });
    return button;
  };
  const factRows = (facts: Fact[]) =>
    h(
      "dl",
      "wc-facts",
      ...facts.map((fact) =>
        h(
          "div",
          "wc-fact",
          h("dt", "wc-sm wc-c3", fact.label),
          h("dd", "wc-sm wc-c1 wc-num", fact.value)
        )
      )
    );
  /** An HTTPS picture, fetched as the runtime fetches authored images; a tile stands in without one. */
  const picture = (
    src: string | undefined,
    alt: string,
    className: string,
    glyph: string
  ) => {
    const tile = h(
      "span",
      cx("wc-pic", className),
      glyph in shapes ? shape(glyph, "wc-pic-glyph") : icon(glyph, "wc-pic-glyph")
    );
    if (!src) return hidden(tile);
    const img = document.createElement("img");
    img.alt = alt;
    img.decoding = "async";
    img.loading = "lazy";
    img.setAttribute("crossorigin", "anonymous");
    img.setAttribute("referrerpolicy", "no-referrer");
    img.addEventListener("error", () => img.remove());
    img.src = src;
    tile.append(img);
    return tile;
  };
  /** A header row: the brand's logo or a glyph tile, the title, and trailing context. */
  const kindHead = (
    frame: Frame,
    brand: string | undefined,
    glyph: string,
    ...trailing: Child[]
  ) =>
    h(
      "header",
      "wc-row-center wc-gap-md",
      glyphTile(brand, frame.title, glyph),
      h("h3", "wc-order-merchant", frame.title),
      ...trailing,
      frame.meta && h("span", "wc-meta wc-clip wc-push", frame.meta)
    );

  // ============================================================== ticket
  type Endpoint = {
    place: string;
    code?: string | undefined;
    at: Zoned;
    terminal?: string | undefined;
  };
  type Ticket = {
    frame: Frame;
    brand?: string | undefined;
    mode: "train" | "flight";
    number: string;
    depart: Endpoint;
    arrive: Endpoint;
    duration?: string | undefined;
    facts: Fact[];
    passenger?: string | undefined;
    status?: { label: string; tone: Tone } | undefined;
    reference?: string | undefined;
  };
  const endpointOf = (end: unknown, name: string): Endpoint => {
    if (!isRecord(end) || !text(end.place))
      return fail(`Card data needs ${name} with a place and an ISO time at`);
    const at = zonedOf(end.at, end.zone);
    if (!at) return fail(`Card data ${name}.at needs an ISO time with an offset`);
    return {
      place: text(end.place)!,
      code: text(end.code),
      at,
      terminal: text(end.terminal),
    };
  };
  const ticketOf = (data: Record<string, unknown>): Ticket => ({
    frame: frameOf(data),
    brand: brandOf(data.brand),
    mode: data.mode === "flight" ? "flight" : "train",
    number: need(data.number, "a number"),
    depart: endpointOf(data.depart, "depart"),
    arrive: endpointOf(data.arrive, "arrive"),
    duration: text(data.duration),
    facts: factsOf(data.details, 4),
    passenger: text(data.passenger),
    status: statusOf(data.status),
    reference: text(data.reference),
  });
  const ticketEnd = (end: Endpoint, align: "start" | "end") =>
    h(
      "div",
      cx("wc-col wc-gap-xxs wc-ticket-end", align === "end" && "wc-end"),
      h("span", "wc-display-md wc-tight wc-w6 wc-c1 wc-num", end.at.time),
      h(
        "span",
        "wc-md wc-w5 wc-c1 wc-clip",
        end.code ? `${end.place} ${end.code}` : end.place
      ),
      h(
        "span",
        "wc-xs wc-c3 wc-clip",
        [end.at.date, end.terminal].filter(Boolean).join(" · ")
      )
    );
  const ticketRoute = (data: Ticket, withNumber = true) =>
    h(
      "div",
      "wc-ticket-route",
      ticketEnd(data.depart, "start"),
      h(
        "div",
        "wc-ticket-mid",
        withNumber && h("span", "wc-xs wc-w5 wc-c2 wc-clip", data.number),
        hidden(
          h(
            "span",
            "wc-ticket-line",
            icon(data.mode === "flight" ? "airplane" : "train", "wc-ticket-glyph")
          )
        ),
        data.duration && h("span", "wc-xs wc-c3 wc-clip", data.duration)
      ),
      ticketEnd(data.arrive, "end")
    );
  /** Labeled values side by side, as a pass prints them. */
  const passFields = (facts: Fact[], className?: string) =>
    h(
      "dl",
      cx("wc-pass-fields", className),
      ...facts.map((fact) =>
        h(
          "div",
          "wc-col wc-gap-xxs wc-pass-field",
          h("dt", "wc-micro wc-w5 wc-c3 wc-caps wc-clip", fact.label),
          h("dd", "wc-lg wc-w6 wc-c1 wc-num wc-clip", fact.value)
        )
      )
    );
  const ticketLayouts: Array<Layout<Ticket>> = [
    [
      "ticket",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            kindHead(
              data.frame,
              data.brand,
              data.mode === "flight" ? "airplane" : "train",
              data.status && h("span", "wc-push", status(data.status))
            ),
            ticketRoute(data),
            data.facts.length > 0 && passFields(data.facts),
            (data.passenger || data.reference) &&
              h(
                "p",
                "wc-xs wc-c3 wc-num",
                [data.passenger, data.reference].filter(Boolean).join(" · ")
              ),
          ],
          { header: false }
        ),
      }),
    ],
    [
      "pass",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            kindHead(
              data.frame,
              data.brand,
              data.mode === "flight" ? "airplane" : "train",
              h("span", "wc-sm wc-w5 wc-c2 wc-num wc-push wc-clip", data.number)
            ),
            ticketRoute(data, false),
            hidden(h("span", "wc-perforation")),
            data.facts.length > 0 && passFields(data.facts),
            (data.passenger || data.status || data.reference) &&
              h(
                "div",
                "wc-row-center wc-between wc-gap-md",
                h(
                  "span",
                  "wc-col wc-gap-xxs",
                  data.passenger &&
                    h("span", "wc-md wc-w6 wc-c1 wc-clip", data.passenger),
                  data.status && status(data.status)
                ),
                data.reference &&
                  h("span", "wc-xs wc-c3 wc-num wc-clip", data.reference)
              ),
          ],
          { header: false }
        ),
      }),
    ],
  ];

  // ================================================================ ride
  type Ride = {
    frame: Frame;
    brand?: string | undefined;
    status: string;
    eta?: string | undefined;
    plate?: string | undefined;
    car?: string | undefined;
    driver?:
      | { name: string; rating?: number | undefined; trips?: string | undefined }
      | undefined;
    pickup?: string | undefined;
    dropoff?: string | undefined;
    fare?: string | undefined;
  };
  const rideOf = (data: Record<string, unknown>): Ride => ({
    frame: frameOf(data),
    brand: brandOf(data.brand),
    status: need(data.status, "a status"),
    eta: text(data.eta),
    plate: text(data.plate),
    car: text(data.car),
    driver:
      isRecord(data.driver) && text(data.driver.name)
        ? {
            name: text(data.driver.name)!,
            rating: num(data.driver.rating),
            trips: text(data.driver.trips),
          }
        : undefined,
    pickup: text(data.pickup),
    dropoff: text(data.dropoff),
    fare: text(data.fare),
  });
  const driverLine = (data: Ride) =>
    data.driver &&
    h(
      "span",
      "wc-sm wc-c3 wc-num wc-clip",
      [
        data.driver.name,
        data.driver.rating === undefined ? null : `★ ${data.driver.rating.toFixed(1)}`,
        data.driver.trips,
      ]
        .filter(Boolean)
        .join(" · ")
    );
  const route = (from?: string, to?: string) =>
    (from || to) &&
    h(
      "ol",
      "wc-route",
      from &&
        h(
          "li",
          "wc-route-stop",
          hidden(h("span", "wc-route-dot wc-route-from")),
          h("span", "wc-sm wc-c1", from)
        ),
      to &&
        h(
          "li",
          "wc-route-stop",
          hidden(h("span", "wc-route-dot wc-route-to")),
          h("span", "wc-sm wc-c1", to)
        )
    );
  const rideLayouts: Array<Layout<Ride>> = [
    [
      "pickup",
      (data) => data.plate !== undefined,
      (data) => ({
        root: card(
          data.frame,
          [
            kindHead(data.frame, data.brand, "car"),
            h(
              "div",
              "wc-col wc-gap-xxs",
              h("p", "wc-lg wc-w6 wc-c1", data.status),
              data.eta && h("span", "wc-title-3 wc-w6 wc-text-success wc-num", data.eta)
            ),
            h(
              "div",
              "wc-row-center wc-gap-lg",
              h("span", "wc-plate wc-num", data.plate),
              h(
                "span",
                "wc-col wc-grow",
                data.car && h("span", "wc-md wc-c1 wc-clip", data.car),
                driverLine(data)
              )
            ),
            route(data.pickup, data.dropoff),
          ],
          { header: false }
        ),
      }),
    ],
    [
      "trip",
      (data) => data.pickup !== undefined || data.dropoff !== undefined,
      (data) => ({
        root: card(
          data.frame,
          [
            kindHead(
              data.frame,
              data.brand,
              "car",
              data.fare && h("span", "wc-md wc-w6 wc-c1 wc-num wc-push", data.fare)
            ),
            h(
              "div",
              "wc-col wc-gap-xxs",
              h("p", "wc-lg wc-w6 wc-c1", data.status),
              data.eta && h("span", "wc-sm wc-c2", data.eta)
            ),
            route(data.pickup, data.dropoff),
            (data.plate || data.car || data.driver) &&
              h(
                "div",
                "wc-row-center wc-gap-md wc-ride-foot",
                data.plate && h("span", "wc-plate wc-plate-sm wc-num", data.plate),
                h(
                  "span",
                  "wc-col wc-grow",
                  data.car && h("span", "wc-sm wc-c1 wc-clip", data.car),
                  driverLine(data)
                )
              ),
          ],
          { header: false }
        ),
      }),
    ],
  ];

  // ============================================================= product
  type Product = {
    name: string;
    image?: string | undefined;
    price: string;
    originalPrice?: string | undefined;
    badge?: string | undefined;
    shop?: string | undefined;
    rating?: number | undefined;
    sales?: string | undefined;
    href?: string | undefined;
  };
  type Products = { frame: Frame; products: Product[] };
  const productsOf = (data: Record<string, unknown>): Products => {
    const products = list(data.products, 6, (item): Product | undefined =>
      isRecord(item) && text(item.name) && text(item.price)
        ? {
            name: text(item.name)!,
            image: httpsOf(item.image),
            price: text(item.price)!,
            originalPrice: text(item.originalPrice),
            badge: text(item.badge),
            shop: text(item.shop),
            rating: num(item.rating),
            sales: text(item.sales),
            href: httpsOf(item.href),
          }
        : undefined
    );
    if (!products.length)
      fail(
        unread(data.products, "products", "a name and a price") ??
          "Card data needs products"
      );
    return { frame: frameOf(data), products };
  };
  const priceLine = (item: Product, size: string) =>
    h(
      "span",
      "wc-baseline wc-gap-xs",
      item.badge && h("span", "wc-xs wc-w5 wc-text-error", item.badge),
      h("span", cx(size, "wc-w6 wc-text-error wc-num"), item.price),
      item.originalPrice && h("s", "wc-xs wc-c4 wc-num", item.originalPrice)
    );
  const productFacts = (item: Product) =>
    [
      item.rating === undefined ? null : `★ ${item.rating.toFixed(1)}`,
      item.sales,
      item.shop,
    ]
      .filter(Boolean)
      .join(" · ");
  const productLayouts: Array<Layout<Products>> = [
    [
      "hero",
      (data) => data.products.length === 1,
      (data) => {
        const item = data.products[0]!;
        return {
          root: card(data.frame, [
            row(
              item.href,
              "wc-product-hero",
              picture(item.image, item.name, "wc-pic-hero", "shopping-bag"),
              h(
                "span",
                "wc-col wc-gap-xs wc-grow",
                h("span", "wc-md wc-w5 wc-c1 wc-clamp-2", item.name),
                productFacts(item) &&
                  h("span", "wc-xs wc-c3 wc-clip", productFacts(item)),
                priceLine(item, "wc-title-3")
              )
            ),
          ]),
        };
      },
    ],
    [
      "grid",
      (data) => data.products.length > 1,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-product-grid",
            ...data.products.map((item) =>
              h(
                "li",
                null,
                row(
                  item.href,
                  "wc-product-tile",
                  picture(item.image, item.name, "wc-pic-tile", "shopping-bag"),
                  h("span", "wc-sm wc-c1 wc-clamp-2", item.name),
                  priceLine(item, "wc-md"),
                  item.shop && h("span", "wc-xs wc-c3 wc-clip", item.shop)
                )
              )
            )
          ),
        ]),
      }),
    ],
    [
      "list",
      () => true,
      (data) => ({
        root: card(data.frame, [
          h(
            "ol",
            "wc-list",
            ...data.products.map((item) =>
              h(
                "li",
                "wc-divided",
                row(
                  item.href,
                  "wc-row-center",
                  picture(item.image, item.name, "wc-pic-thumb", "shopping-bag"),
                  h(
                    "span",
                    "wc-col wc-gap-xxs wc-grow",
                    h("span", "wc-sm wc-c1 wc-clamp-2", item.name),
                    productFacts(item) &&
                      h("span", "wc-xs wc-c3 wc-clip", productFacts(item))
                  ),
                  h(
                    "span",
                    "wc-col wc-end wc-trail",
                    h("span", "wc-md wc-w6 wc-text-error wc-num", item.price),
                    item.originalPrice &&
                      h("s", "wc-xs wc-c4 wc-num", item.originalPrice)
                  )
                )
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // ============================================================= booking
  type Booking = {
    frame: Frame;
    brand?: string | undefined;
    status?: { label: string; tone: Tone } | undefined;
    at: Zoned;
    details: Fact[];
    confirmation?: string | undefined;
    address?: string | undefined;
  };
  const bookingOf = (data: Record<string, unknown>): Booking => ({
    frame: frameOf(data),
    brand: brandOf(data.brand),
    status: statusOf(data.status),
    at:
      zonedOf(data.at, data.zone) ??
      fail("Card data at needs an ISO time with an offset"),
    details: factsOf(data.details, 6),
    confirmation: text(data.confirmation),
    address: text(data.address),
  });
  const bookingLayouts: Array<Layout<Booking>> = [
    [
      "confirmation",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            h(
              "div",
              "wc-row-center wc-gap-lg",
              hidden(
                h(
                  "span",
                  "wc-cal",
                  h("span", "wc-cal-month", data.at.month),
                  h("span", "wc-cal-day wc-num", data.at.day)
                )
              ),
              h(
                "span",
                "wc-col wc-gap-xxs wc-grow",
                h("h3", "wc-order-merchant", data.frame.title),
                h("span", "wc-md wc-c1 wc-num", `${data.at.date} ${data.at.time}`),
                data.status && status(data.status)
              )
            ),
            data.details.length > 0 && factRows(data.details),
            (data.confirmation || data.address) &&
              h(
                "div",
                "wc-col wc-gap-xxs",
                data.confirmation &&
                  h("span", "wc-sm wc-w5 wc-c1 wc-num", data.confirmation),
                data.address && h("span", "wc-sm wc-c3", data.address)
              ),
          ],
          { header: false }
        ),
      }),
    ],
    [
      "compact",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            kindHead(
              data.frame,
              data.brand,
              "check",
              data.status && h("span", "wc-push", status(data.status))
            ),
            h(
              "div",
              "wc-col wc-gap-xxs",
              h("p", "wc-lg wc-w6 wc-c1 wc-num", `${data.at.date} ${data.at.time}`),
              data.details.length > 0 &&
                h(
                  "span",
                  "wc-sm wc-c3",
                  data.details.map((fact) => fact.value).join(" · ")
                )
            ),
            data.address && h("p", "wc-sm wc-c3", data.address),
          ],
          { header: false }
        ),
      }),
    ],
  ];

  // ============================================================== device
  type Device = {
    name: string;
    on?: boolean | undefined;
    online: boolean;
    value?: string | undefined;
    unit?: string | undefined;
    mode?: string | undefined;
    detail?: string | undefined;
    controls: Control[];
  };
  type Devices = { frame: Frame; devices: Device[] };
  const devicesOf = (data: Record<string, unknown>): Devices => {
    const devices = list(data.devices, 6, (item): Device | undefined =>
      isRecord(item) && text(item.name)
        ? {
            name: text(item.name)!,
            on: typeof item.on === "boolean" ? item.on : undefined,
            online: item.online !== false,
            value: text(item.value),
            unit: text(item.unit),
            mode: text(item.mode),
            detail: text(item.detail),
            controls: list(item.controls, 4, controlOf),
          }
        : undefined
    );
    if (!devices.length)
      fail(unread(data.devices, "devices", "a name") ?? "Card data needs devices");
    return { frame: frameOf(data), devices };
  };
  const power = (device: Device) =>
    h(
      "span",
      cx(
        "wc-power",
        !device.online
          ? "wc-power-off"
          : device.on === false
            ? "wc-power-idle"
            : "wc-power-on"
      ),
      !device.online ? copy.offline : (device.mode ?? "")
    );
  const reading = (device: Device, size: string) =>
    device.value &&
    h(
      "span",
      cx("wc-baseline", !device.online && "wc-dim"),
      h("span", cx(size, "wc-tight wc-w6 wc-c1 wc-num"), device.value),
      device.unit && h("span", "wc-lg wc-c3", device.unit)
    );
  const controlRow = (device: Device) =>
    device.controls.length > 0 &&
    h(
      "div",
      "wc-row-center wc-wrap wc-gap-sm",
      ...device.controls.map((control) =>
        proposer(control.prompt, "wc-action", control.label, control.label)
      )
    );
  const deviceLayouts: Array<Layout<Devices>> = [
    [
      "single",
      (data) => data.devices.length === 1,
      (data) => {
        const device = data.devices[0]!;
        return {
          root: card(data.frame, [
            h(
              "div",
              "wc-row-end wc-between wc-gap-md",
              h(
                "span",
                "wc-col wc-gap-xxs",
                h("span", "wc-md wc-w6 wc-c1", device.name),
                device.detail && h("span", "wc-sm wc-c3", device.detail)
              ),
              power(device)
            ),
            reading(device, "wc-display-lg"),
            controlRow(device),
          ]),
        };
      },
    ],
    [
      "grid",
      (data) => data.devices.length > 1,
      (data) => ({
        root: card(data.frame, [
          h(
            "ul",
            "wc-device-grid",
            ...data.devices.map((device) =>
              h(
                "li",
                cx("wc-device", device.on && device.online && "wc-device-on"),
                h(
                  "span",
                  "wc-row-center wc-between wc-gap-sm",
                  h("span", "wc-sm wc-w5 wc-c1 wc-clip", device.name),
                  power(device)
                ),
                reading(device, "wc-title-2") ||
                  (device.detail && h("span", "wc-sm wc-c3", device.detail)),
                device.controls.length > 0 &&
                  h(
                    "span",
                    "wc-row-center wc-wrap wc-gap-xs",
                    ...device.controls.map((control) =>
                      proposer(
                        control.prompt,
                        "wc-action wc-action-sm",
                        control.label,
                        control.label
                      )
                    )
                  )
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // ============================================================= payment
  type Payment = {
    frame: Frame;
    brand?: string | undefined;
    amount: string;
    status: { label: string; tone: Tone };
    counterparty?: string | undefined;
    at?: string | undefined;
    details: Fact[];
  };
  const paymentOf = (data: Record<string, unknown>): Payment => ({
    frame: frameOf(data),
    brand: brandOf(data.brand),
    amount: need(data.amount, "an amount"),
    status: statusOf(data.status) ?? fail("Card data needs a status with a label"),
    counterparty: text(data.counterparty),
    at: momentText(data.at),
    details: factsOf(data.details, 5),
  });
  /** A drawn check for a payment that went through; the host's arrow otherwise. */
  const sealGlyph = (tone: Tone) =>
    tone === "success" ? shape("check") : icon("arrow-right");
  const paymentLayouts: Array<Layout<Payment>> = [
    [
      "receipt",
      () => true,
      (data) => ({
        root: card(data.frame, [
          h(
            "div",
            "wc-col wc-gap-sm wc-pay-hero",
            hidden(
              h(
                "span",
                cx("wc-pay-seal", `wc-pay-${data.status.tone}`),
                sealGlyph(data.status.tone)
              )
            ),
            h("span", "wc-display-md wc-tight wc-w6 wc-c1 wc-num", data.amount),
            h(
              "span",
              "wc-col wc-gap-xxs",
              h(
                "span",
                cx("wc-md wc-w5", `wc-text-${data.status.tone}`),
                data.status.label
              ),
              (data.counterparty || data.at) &&
                h(
                  "span",
                  "wc-sm wc-c3 wc-num",
                  [data.counterparty, data.at].filter(Boolean).join(" · ")
                )
            )
          ),
          data.details.length > 0 && factRows(data.details),
        ]),
      }),
    ],
    [
      "compact",
      () => true,
      (data) => ({
        root: card(
          data.frame,
          [
            h(
              "div",
              "wc-row-center wc-gap-md",
              data.brand
                ? mark(data.brand, data.frame.title, "lg")
                : hidden(
                    h(
                      "span",
                      cx("wc-pay-seal wc-pay-seal-sm", `wc-pay-${data.status.tone}`),
                      sealGlyph(data.status.tone)
                    )
                  ),
              h(
                "span",
                "wc-col wc-grow",
                h(
                  "span",
                  "wc-md wc-w6 wc-c1 wc-clip",
                  data.counterparty ?? data.frame.title
                ),
                h(
                  "span",
                  "wc-sm wc-c3 wc-clip wc-num",
                  [data.status.label, data.at].filter(Boolean).join(" · ")
                )
              ),
              h("span", "wc-lg wc-w6 wc-c1 wc-num wc-trail", data.amount)
            ),
          ],
          { header: false, small: true }
        ),
      }),
    ],
  ];

  // =============================================================== media
  type Media = {
    frame: Frame;
    brand?: string | undefined;
    track: string;
    artist?: string | undefined;
    album?: string | undefined;
    cover?: string | undefined;
    playing: boolean;
    position?: number | undefined;
    duration?: number | undefined;
    controls: { previous?: string; toggle?: string; next?: string };
    queue: Array<{ track: string; artist?: string | undefined }>;
  };
  const mediaOf = (data: Record<string, unknown>): Media => {
    const controls = isRecord(data.controls) ? data.controls : {};
    const prompt = (input: unknown) => ident(input, 4000);
    const duration = num(data.duration);
    const position = num(data.position);
    return {
      frame: frameOf(data),
      brand: brandOf(data.brand),
      track: need(data.track, "a track"),
      artist: text(data.artist),
      album: text(data.album),
      cover: httpsOf(data.cover),
      playing: data.playing === true,
      duration: duration !== undefined && duration > 0 ? duration : undefined,
      position: position !== undefined && position >= 0 ? position : undefined,
      controls: Object.fromEntries(
        (["previous", "toggle", "next"] as const)
          .map((name) => [name, prompt(controls[name])])
          .filter(([, given]) => given)
      ),
      queue: list(data.queue, 5, (item) =>
        isRecord(item) && text(item.track)
          ? { track: text(item.track)!, artist: text(item.artist) }
          : undefined
      ),
    };
  };
  const clockOfSeconds = (seconds: number) => {
    const whole = Math.floor(seconds);
    const hours = Math.floor(whole / 3600);
    const minutes = Math.floor((whole % 3600) / 60);
    const rest = String(whole % 60).padStart(2, "0");
    return hours
      ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}`
      : `${minutes}:${rest}`;
  };
  const transport = (data: Media, size: "lg" | "sm" = "lg") => {
    const { previous, toggle, next } = data.controls;
    if (!previous && !toggle && !next) return null;
    return h(
      "div",
      cx("wc-transport", size === "sm" && "wc-transport-sm"),
      previous && proposer(previous, "wc-tbtn", "previous", shape("next", "wc-flip")),
      toggle &&
        proposer(
          toggle,
          "wc-tbtn wc-tbtn-main",
          data.playing ? "pause" : "play",
          shape(data.playing ? "pause" : "play")
        ),
      next && proposer(next, "wc-tbtn", "next", shape("next"))
    );
  };
  /** Elapsed time, a thin rail, and the time left, as a now-playing screen shows them. */
  const scrubber = (data: Media) => {
    if (data.duration === undefined) return null;
    const at = Math.min(data.position ?? 0, data.duration);
    const native = h("progress", "wc-sr") as HTMLProgressElement;
    native.max = 100;
    native.value = Math.round((at / data.duration) * 100);
    native.setAttribute("aria-label", data.track);
    const rail = hidden(h("span", "wc-scrub-rail", h("span", "wc-scrub-fill")));
    rail.style.setProperty("--wc-scrub", String(at / data.duration));
    return h(
      "div",
      "wc-col wc-gap-xs",
      native,
      rail,
      h(
        "span",
        "wc-row-center wc-between wc-micro wc-w5 wc-num wc-player-dim",
        h("span", null, clockOfSeconds(at)),
        h("span", null, `−${clockOfSeconds(data.duration - at)}`)
      )
    );
  };
  /** The cover, blurred past the card's edges, is the card's own color. */
  const playerCard = (data: Media, children: Child[]) => {
    const root = card(data.frame, children);
    root.classList.add("wc-player");
    const backdrop = hidden(picture(data.cover, "", "wc-player-backdrop", "play"));
    root.prepend(backdrop);
    return root;
  };
  const nowPlaying = (data: Media, cover: string) =>
    h(
      "div",
      "wc-row-center wc-gap-lg",
      picture(data.cover, data.album ?? data.track, cover, "play"),
      h(
        "span",
        "wc-col wc-gap-xxs wc-grow",
        h("span", "wc-lg wc-w6 wc-player-ink wc-clamp-2", data.track),
        (data.artist || data.album) &&
          h(
            "span",
            "wc-sm wc-player-dim wc-clip",
            [data.artist, data.album].filter(Boolean).join(" — ")
          )
      )
    );
  const mediaLayouts: Array<Layout<Media>> = [
    [
      "player",
      () => true,
      (data) => ({
        root: playerCard(data, [
          nowPlaying(data, "wc-pic-cover"),
          scrubber(data),
          transport(data),
        ]),
      }),
    ],
    [
      "queue",
      (data) => data.queue.length > 0,
      (data) => ({
        root: playerCard(data, [
          h(
            "div",
            "wc-row-center wc-gap-md",
            h("span", "wc-grow", nowPlaying(data, "wc-pic-thumb")),
            transport(data, "sm")
          ),
          h(
            "div",
            "wc-col wc-gap-xs wc-player-queue",
            h("span", "wc-xs wc-w6 wc-player-dim", copy.upNext),
            h(
              "ol",
              "wc-col",
              ...data.queue.map((item) =>
                h(
                  "li",
                  "wc-row-center wc-gap-md wc-queue-row",
                  h(
                    "span",
                    "wc-col wc-grow",
                    h("span", "wc-sm wc-w5 wc-player-ink wc-clip", item.track),
                    item.artist && h("span", "wc-xs wc-player-dim wc-clip", item.artist)
                  )
                )
              )
            )
          ),
        ]),
      }),
    ],
  ];

  // ================================================================ bars
  type BarItem = {
    label: string;
    value: number;
    shown: string;
    compare?: number | undefined;
    compareShown?: string | undefined;
    delta?: Delta | undefined;
    caption?: string | undefined;
    status?: { label: string; tone: Tone } | undefined;
    tone?: Tone | undefined;
    brand?: string | undefined;
    href?: string | undefined;
  };
  type Bars = {
    frame: Frame;
    items: BarItem[];
    /** Where each bar lies on a track that runs to what a full bar stands for. */
    area: ReturnType<typeof barPlot>;
    /** The data says what a full bar stands for, so every layout keeps that scale. */
    scaled: boolean;
    legend?: { value: string; compare: string } | undefined;
  };
  const barsOf = (data: Record<string, unknown>): Bars => {
    const items = list(data.items, 12, (item): BarItem | undefined => {
      if (!isRecord(item) || !text(item.label) || num(item.value) === undefined)
        return undefined;
      const compare = num(item.compare);
      return {
        label: text(item.label)!,
        value: num(item.value)!,
        shown: text(item.valueLabel) ?? formatNumber(num(item.value)!),
        compare,
        compareShown:
          compare === undefined
            ? undefined
            : (text(item.compareLabel) ?? formatNumber(compare)),
        delta: deltaOf(item.delta),
        caption: text(item.caption),
        status: statusOf(item.status),
        tone: tones.includes(item.tone as Tone) ? (item.tone as Tone) : undefined,
        brand: brandOf(item.brand),
        href: httpsOf(item.href),
      };
    });
    if (!items.length)
      fail(
        unread(data.items, "items", "a label and a number as value") ??
          "Card data needs items"
      );
    const full = num(data.max);
    return {
      frame: frameOf(data),
      items,
      area: barPlot(
        items.flatMap((item) => [item.value, item.compare ?? 0]),
        0,
        full
      ),
      scaled: full !== undefined,
      legend:
        isRecord(data.legend) &&
        text(data.legend.value) &&
        text(data.legend.compare) &&
        items.some((item) => item.compare !== undefined)
          ? { value: text(data.legend.value)!, compare: text(data.legend.compare)! }
          : undefined,
    };
  };
  const barsLegend = (data: Bars) =>
    data.legend &&
    h(
      "div",
      "wc-rank-legend",
      hidden(h("span", "wc-rank-swatch wc-dot-brand")),
      h("span", null, data.legend.value),
      hidden(h("span", "wc-rank-swatch wc-rank-swatch-compare")),
      h("span", null, data.legend.compare)
    );
  /** One item's bar, and under it the bar of the series it is compared with. */
  const barTracks = (data: Bars, item: BarItem) => {
    // The fill is the track's own pseudo-element, so a bar is one node.
    const track = (amount: number, tone: string) => {
      const node = h("span", "wc-rank-track");
      node.dataset.tone = tone;
      lay(node, data.area.bar(amount));
      return node;
    };
    return hidden(
      h(
        "span",
        "wc-rank-tracks",
        track(item.value, item.tone ?? "brand"),
        item.compare !== undefined && track(item.compare, "compare")
      )
    );
  };
  /** An item's value, the value it is compared with, and its change. */
  const barValues = (item: BarItem) => [
    h("span", "wc-sm wc-w5 wc-c1 wc-num", item.shown),
    item.compareShown !== undefined &&
      h("span", "wc-xs wc-c3 wc-num", item.compareShown),
    item.delta && delta(item.delta),
  ];
  const barsLayouts: Array<Layout<Bars>> = [
    [
      "rows",
      () => true,
      (data) => ({
        root: card(data.frame, [
          barsLegend(data),
          h(
            "ul",
            "wc-list wc-rank",
            ...data.items.map((item) =>
              h(
                "li",
                null,
                row(
                  item.href,
                  "wc-rank-row",
                  h(
                    "span",
                    "wc-rank-head",
                    h(
                      "span",
                      "wc-rank-name",
                      branded(data.items) && mark(item.brand, item.label, "sm", true),
                      h("span", "wc-sm wc-c1", item.label),
                      item.status && status(item.status)
                    ),
                    h("span", "wc-rank-values", ...barValues(item))
                  ),
                  barTracks(data, item),
                  item.caption && h("span", "wc-xs wc-c3", item.caption)
                )
              )
            )
          ),
        ]),
      }),
    ],
    [
      "compact",
      (data) =>
        data.items.every(
          (item) =>
            widthOf(item.label) <= 9 && !item.caption && !item.status && !item.href
        ),
      (data) => {
        // Values, compared values and changes each share a column, so a
        // column exists in every row when any item has its part.
        const compared = data.items.some((item) => item.compare !== undefined);
        const changed = data.items.some((item) => item.delta);
        const rows = h(
          "ul",
          "wc-list wc-rank-compact",
          ...data.items.map((item) => {
            const [shown, other, change] = barValues(item);
            return h(
              "li",
              null,
              h(
                "span",
                "wc-rank-name",
                branded(data.items) && mark(item.brand, item.label, "sm", true),
                h("span", "wc-sm wc-c1", item.label)
              ),
              barTracks(data, item),
              shown,
              compared && (other || h("span")),
              changed && (change || h("span"))
            );
          })
        );
        rows.style.setProperty(
          "--wc-rank-columns",
          String(1 + Number(compared) + Number(changed))
        );
        return { root: card(data.frame, [barsLegend(data), rows]) };
      },
    ],
    [
      "columns",
      // Upright bars scale to their tallest, so they do not draw a stated full value.
      (data) =>
        !data.scaled &&
        data.items.length >= 2 &&
        data.items.length <= 7 &&
        data.items.every(
          (item) =>
            widthOf(item.label) <= 5 &&
            item.compare === undefined &&
            !item.caption &&
            !item.status &&
            !item.delta &&
            !item.href &&
            !item.brand
        ),
      (data) => ({
        root: card(data.frame, [
          columnBars({
            title: data.frame.title,
            labels: data.items.map((item) => item.label),
            values: data.items.map((item) => item.value),
            shown: data.items.map((item) => item.shown),
            latest: false,
            tones: data.items.map((item) => item.tone),
          }),
        ]),
      }),
    ],
  ];

  // =============================================================== table
  type Cell = { text: string; tone?: Tone | undefined; numeric: boolean };
  type Table = { frame: Frame; columns: string[]; rows: Cell[][] };
  // A number, with the sign, currency or unit it is written with.
  const numeric = /^[-+−–]?[$¥€£]?\d[\d.,]*\s?[%‰]?[^\d\s]{0,3}$/;
  const cellOf = (input: unknown): Cell | undefined => {
    if (input === null || (typeof input === "string" && !input.trim()))
      return { text: "", numeric: true };
    if (num(input) !== undefined)
      return { text: formatNumber(num(input)!), numeric: true };
    const written = isRecord(input) ? text(input.text) : text(input);
    if (!written) return undefined;
    return {
      text: written,
      tone:
        isRecord(input) && tones.includes(input.tone as Tone)
          ? (input.tone as Tone)
          : undefined,
      numeric: numeric.test(written.trim()),
    };
  };
  const tableOf = (data: Record<string, unknown>): Table => {
    // A column may have no heading, as the one that names the rows often has.
    const columns = list(data.columns, 8, (column) =>
      typeof column === "string" ? column.trim() : undefined
    );
    if (columns.length < 2 || !columns.some(Boolean))
      fail("Card data needs two or more columns with headings");
    const rows = list(data.rows, 24, (item) => {
      if (!Array.isArray(item)) return undefined;
      const cells = list(item, columns.length, cellOf);
      return cells.length === columns.length && cells[0]!.text ? cells : undefined;
    });
    if (!rows.length)
      fail(
        unread(data.rows, "rows", "one cell per column, the first naming the row") ??
          "Card data needs rows with one cell per column"
      );
    return { frame: frameOf(data), columns, rows };
  };
  const tableLayouts: Array<Layout<Table>> = [
    [
      "grid",
      () => true,
      (data) => {
        // A column of numbers reads down its right edge.
        const end = data.columns.map(
          (_, column) =>
            column > 0 &&
            data.rows.some((cells) => cells[column]!.text) &&
            data.rows.every((cells) => cells[column]!.numeric)
        );
        // Short row names keep to one line; long ones wrap in their column.
        const fits = data.rows.every((cells) => widthOf(cells[0]!.text) <= 8);
        // What each column needs, in ems: its longest entry on one line, or a
        // short line of the entries that wrap.
        const ems = data.columns.map((heading, column) => {
          const widest = Math.max(
            widthOf(heading),
            ...data.rows.map((cells) => widthOf(cells[column]!.text))
          );
          const oneLine = column === 0 ? fits : end[column];
          return (oneLine ? widest : Math.min(widest, 6)) + 0.4;
        });
        const table = h(
          "table",
          cx("wc-table", fits && "wc-table-names-fit"),
          h(
            "thead",
            null,
            h(
              "tr",
              null,
              ...data.columns.map((column, index) => {
                const head = h("th", end[index] && "wc-table-end", column);
                head.setAttribute("scope", "col");
                head.style.setProperty("--wc-column-ems", ems[index]!.toFixed(2));
                return head;
              })
            )
          ),
          h(
            "tbody",
            null,
            ...data.rows.map((cells) =>
              h(
                "tr",
                null,
                ...cells.map((item, index) => {
                  const node = h(
                    index === 0 ? "th" : "td",
                    cx(
                      index === 0 && "wc-table-name",
                      end[index] && "wc-table-end",
                      item.tone && `wc-text-${item.tone}`
                    ),
                    item.text
                  );
                  if (index === 0) node.setAttribute("scope", "row");
                  else node.dataset.label = data.columns[index]!;
                  return node;
                })
              )
            )
          )
        );
        // In a card narrower than its columns need, each row stacks into
        // label and value pairs.
        const fit = h("div", "wc-table-fit", table);
        fit.style.setProperty(
          "--wc-table-ems",
          ems.reduce((sum, width) => sum + width, 0).toFixed(2)
        );
        fit.style.setProperty("--wc-table-columns", String(data.columns.length));
        return { root: card(data.frame, [fit]) };
      },
    ],
  ];

  // =============================================================== chart
  /** The names of several series, each beside the color its marks are drawn in. */
  const seriesLegend = (names: string[]) =>
    h(
      "div",
      "wc-rank-legend",
      ...names.flatMap((name, index) => {
        const swatch = hidden(h("span", "wc-rank-swatch"));
        swatch.style.backgroundColor = seriesInk[index % seriesInk.length]!;
        return [swatch, h("span", null, name)];
      })
    );
  /** The labels under a plot: all of up to eight, every nth of more. */
  const plotAxis = (labels: string[]) => {
    const few = labels.length <= 8;
    const axis = hidden(
      h(
        "div",
        cx("wc-bars-axis", few && "wc-bars-axis-all"),
        ...labels.map((tick) =>
          h("span", null, h("span", null, ...(few ? breakable(tick) : [tick])))
        )
      )
    );
    if (!few) {
      const last = labels.length - 1;
      const widest = Math.max(...labels.map(widthOf), 1) + 1;
      [...axis.children].forEach((tick, index) => {
        for (const [name, ems] of [
          ["wide", 40],
          ["medium", 26],
          ["narrow", 18],
        ] as const)
          if (
            (last - index) % Math.max(1, Math.ceil((widest * labels.length) / ems)) ===
            0
          )
            tick.classList.add(`wc-tick-${name}`);
      });
    }
    return axis;
  };
  const chartOf = (spec: Parameters<CardEngine["chart"]>[0]) => {
    const { labels, series } = spec;
    const count = labels.length;
    const first = series[0]!;
    if (spec.type === "bar" && series.length === 1) {
      // Labels that fit under their bars, or stand for a long sequence, keep
      // the bars upright. Up to sixteen that do not fit turn the bars
      // sideways, so every label and value shows.
      const widest = Math.max(...labels.map(widthOf), 1) + 1;
      if (count <= 8 ? widest * count <= 80 : widest * count <= 40 || count > 16)
        return columnBars({
          title: "",
          labels,
          values: first.values,
          shown: first.values.map(formatNumber),
          latest: false,
        });
      const area = barPlot(first.values);
      const rows = h(
        "ul",
        "wc-list wc-rank-compact",
        ...labels.map((label, index) => {
          const track = h("span", "wc-rank-track");
          track.dataset.tone = "brand";
          lay(track, area.bar(first.values[index]!));
          return h(
            "li",
            null,
            h("span", "wc-rank-name", h("span", "wc-sm wc-c1", label)),
            hidden(h("span", "wc-rank-tracks", track)),
            h("span", "wc-sm wc-w5 wc-c1 wc-num", formatNumber(first.values[index]!))
          );
        })
      );
      rows.style.setProperty("--wc-rank-columns", "1");
      return rows;
    }
    const all = series.flatMap((item) => item.values);
    if (spec.type === "bar") {
      // Several series stand side by side over each label.
      const area = barPlot(all);
      return h(
        "figure",
        "wc-bars",
        h(
          "figcaption",
          "wc-bars-legend",
          seriesLegend(series.map((item) => item.name))
        ),
        hidden(
          h(
            "div",
            "wc-bars-plot",
            ...labels.map((_, index) =>
              h(
                "div",
                "wc-bar-slot wc-bar-group",
                ...series.map((item, order) => {
                  const bar = h("div", "wc-bar-col");
                  stand(bar, area.bar(item.values[index]!), item.values[index]! < 0);
                  bar.style.backgroundColor = seriesInk[order % seriesInk.length]!;
                  return bar;
                })
              )
            ),
            zeroLine(area)
          )
        ),
        plotAxis(labels)
      );
    }
    // Lines run through the middle of each label's slot, as bars stand in it.
    const y = scale(all, 100, 6);
    const x = (index: number) => ((index + 0.5) / count) * 100;
    const path = (values: number[]) =>
      values
        .map(
          (item, index) =>
            `${index ? "L" : "M"}${x(index).toFixed(2)},${y(item).toFixed(2)}`
        )
        .join(" ");
    const id = nextId();
    const single = series.length === 1;
    const high = h(
      "span",
      "wc-area-label wc-area-high",
      formatCompact(Math.max(...all))
    );
    high.style.top = `${y(Math.max(...all))}%`;
    const low = h("span", "wc-area-label wc-area-low", formatCompact(Math.min(...all)));
    low.style.top = `${y(Math.min(...all))}%`;
    return h(
      "figure",
      "wc-area",
      !single &&
        h(
          "figcaption",
          "wc-bars-legend",
          seriesLegend(series.map((item) => item.name))
        ),
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
            ...(single
              ? [
                  gradient(id, ink.brand, 0.22),
                  svg("path", {
                    d: `${path(first.values)} L${x(count - 1).toFixed(2)},100 L${x(0).toFixed(2)},100 Z`,
                    fill: `url(#${id})`,
                  }),
                ]
              : []),
            ...series.map((item, order) =>
              svg("path", {
                d: path(item.values),
                fill: "none",
                stroke: seriesInk[order % seriesInk.length]!,
                "stroke-linecap": "round",
                "stroke-linejoin": "round",
                "stroke-width": 2,
                "vector-effect": "non-scaling-stroke",
              })
            )
          ),
          high,
          Math.max(...all) !== Math.min(...all) && low
        )
      ),
      plotAxis(labels)
    );
  };

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
    order: kind(orderOf, orderLayouts),
    ticket: kind(ticketOf, ticketLayouts),
    ride: kind(rideOf, rideLayouts),
    product: kind(productsOf, productLayouts),
    booking: kind(bookingOf, bookingLayouts),
    device: kind(devicesOf, deviceLayouts),
    payment: kind(paymentOf, paymentLayouts),
    media: kind(mediaOf, mediaLayouts),
    bars: kind(barsOf, barsLayouts),
    table: kind(tableOf, tableLayouts),
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
    chart(spec) {
      const fragment = document.createDocumentFragment();
      fragment.append(chartOf(spec));
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
