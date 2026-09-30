/* eslint-disable unicorn/require-post-message-target-origin -- Worker and MessagePort messages do not accept an origin. */
/// <reference lib="dom" />
import { cardEngine, type CardEngine, type CardOutgoing } from "./cards";
import { cardCss } from "./cardStyles";

/** Fixed package resources. Generated content enters only through the bound port. */
export const dynamicUiUrl = "comma-ui://runtime/";
export const dynamicUiCsp =
  "default-src 'none'; script-src 'unsafe-inline' https:; worker-src blob:; style-src 'unsafe-inline' https:; connect-src 'none'; img-src https:; font-src https:; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'";

function workerBootstrap(resources: string[], data: unknown, state: unknown) {
  // Keep the loader private and remove every public entry point before any
  // dependency runs. Only the host-validated declarations may initiate imports.
  const loadDeclaredScripts = (
    globalThis as typeof globalThis & { importScripts(...urls: string[]): void }
  ).importScripts.bind(globalThis);
  for (const name of ["importScripts", "Worker", "SharedWorker", "BroadcastChannel"]) {
    let target: object | null = globalThis;
    while (target) {
      const descriptor = Object.getOwnPropertyDescriptor(target, name);
      if (descriptor?.configurable)
        Object.defineProperty(target, name, {
          value: undefined,
          writable: false,
          configurable: false,
        });
      target = Object.getPrototypeOf(target);
    }
    Object.defineProperty(globalThis, name, {
      value: undefined,
      writable: false,
      configurable: false,
    });
  }
  const post = globalThis.postMessage.bind(globalThis);
  const clone = globalThis.structuredClone.bind(globalThis);
  const measure = JSON.stringify;
  const encode = TextEncoder.prototype.encode.bind(new TextEncoder());
  // SDK calls made in one Worker task leave together when it ends, so one
  // render pass is one update however many elements it touches. A batch stays
  // within the host's budget of 500 changes and 32 KiB per message.
  let batch: unknown[] = [];
  let batchSize = 0;
  const flush = () => {
    if (batch.length === 1) post(batch[0]);
    else if (batch.length) post({ type: "batch", ops: batch });
    batch = [];
    batchSize = 0;
  };
  const send = (update: unknown) => {
    // Copy at call time, as an immediate postMessage did: the script can
    // reuse and change the same object before the batch leaves.
    const copy = clone(update);
    const size = encode(measure(copy)).length + 1;
    if (batch.length === 500 || batchSize + size > 32000) flush();
    if (!batch.length) queueMicrotask(flush);
    batch.push(copy);
    batchSize += size;
  };
  const handlers = new Map<string, (event: unknown) => void>();
  const timers = new Map<number, () => void>();
  let serial = 0;
  let stateHandler: ((state: unknown) => void) | undefined;
  const sdk = {
    data,
    state,
    onState(fn: (state: unknown) => void) {
      stateHandler = fn;
    },
    table(id: string, value: unknown) {
      send({ type: "table", id, value });
    },
    chart(id: string, value: unknown) {
      send({ type: "chart", id, value });
    },
    card(id: string, kind: string, value: unknown, variant?: string) {
      send({ type: "card", id, kind, value, variant });
    },
    on(id: string, event: string, fn: (event: unknown) => void) {
      handlers.set(`${id}:${event}`, fn);
    },
    text(id: string, text: unknown) {
      send({ type: "text", id, value: String(text) });
    },
    value(id: string, value: unknown) {
      send({ type: "value", id, value: String(value) });
    },
    visible(id: string, value: boolean) {
      send({ type: "visible", id, value });
    },
    save(value: unknown) {
      send({ type: "save", value });
    },
    request(text: string) {
      send({ type: "request", value: text });
    },
    every(ms: number, fn: () => void) {
      const id = ++serial;
      timers.set(id, fn);
      send({ type: "timer", id, ms });
    },
  };
  Object.defineProperty(globalThis, "comma", {
    value: sdk,
    writable: false,
    configurable: false,
  });
  globalThis.addEventListener("message", (event: MessageEvent) => {
    const message = event.data;
    if (message.type === "ping") post({ type: "pong", value: message.value });
    if (message.type === "state") {
      sdk.state = message.value;
      stateHandler?.(message.value);
    }
    if (message.type === "event")
      handlers.get(`${message.id}:${message.event}`)?.(message.value);
    if (message.type === "tick") timers.get(message.id)?.();
  });
  // Pass the entire immutable URL list to the native loader before it executes
  // untrusted code. Dependencies cannot modify subsequent import arguments.
  if (resources.length) loadDeclaredScripts(...resources);
}

function runtimeBootstrap(workerSource: string, createCards: typeof cardEngine) {
  const messageEncoder = new TextEncoder();
  // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
  const applyTheme = (theme: Record<string, unknown> | undefined) => {
    if (theme && typeof theme === "object") {
      document.documentElement.style.colorScheme =
        theme.scheme === "dark" ? "dark" : "light";
      for (const name of [
        "warm",
        "motion-enter",
        "motion-feedback",
        "motion-stagger",
        "motion-ease",
        "background",
        "surface",
        "shadow",
        "success",
        "danger",
        "foreground",
        "secondary",
        "muted",
        "border",
        "accent",
        "font",
        "space",
        "radius",
        "size",
        "h2",
        "h3",
        "metric",
        "small",
        "control",
      ]) {
        const value = theme[name];
        if (
          typeof value === "string" &&
          value.length < 300 &&
          !/[;{}]|url\(/i.test(value)
        )
          document.documentElement.style.setProperty(`--comma-${name}`, value);
      }
    }
  };
  // Card templates read Comma tokens the host resolved for the current theme.
  // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
  const applyTokens = (tokens: unknown) => {
    if (!tokens || typeof tokens !== "object") return;
    for (const [name, value] of Object.entries(tokens as Record<string, unknown>)) {
      if (
        /^--(?:(?:color|spacing|radius|text|container|border-width|shadow|motion|font-weight|opacity)-[a-z0-9-]{1,48}|comma-icon-stroke-width)$/.test(
          name
        ) &&
        typeof value === "string" &&
        value.length < 300 &&
        !/[;{}]|url\(/i.test(value)
      )
        document.documentElement.style.setProperty(name, value);
    }
  };
  const tags = new Set(
    "section div p span h2 h3 strong small label button input select option ul li table thead tbody tr th td br progress comma-chart comma-icon img link script a".split(
      " "
    )
  );
  const attributes = new Set(
    "id title aria-label for type value min max step checked disabled selected hidden class name src href alt rel".split(
      " "
    )
  );
  // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
  const countNodes = (root: Node) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ALL);
    let total = 0;
    while (walker.nextNode()) total++;
    return total;
  };

  let initialized = false;
  window.addEventListener("message", (initial: MessageEvent) => {
    if (
      !initialized &&
      initial.source === parent &&
      initial.data?.type === "comma-ui:hello"
    ) {
      parent.postMessage({ type: "comma-ui:ready" }, "*");
      return;
    }
    if (
      initialized ||
      initial.source !== parent ||
      initial.data?.type !== "comma-ui:init" ||
      initial.ports.length !== 1
    )
      return;
    initialized = true;
    const port = initial.ports[0]!;
    let worker: Worker | undefined;
    let cards: CardEngine | undefined;
    // Card progress from init or, later, from another open copy of this widget.
    let cardProgress: unknown;
    let stopped = false;
    let windowStart = performance.now();
    let count = 0;
    let pendingPing: string | undefined;
    let pingAt = 0;
    const timers: number[] = [];
    const send = (message: unknown) => port.postMessage(message);
    // The wheel scrolls the chat natively: this frame never scrolls, so the
    // browser chains the gesture to the transcript. The host only learns that
    // the reader moved it, so following stops instead of pulling back to the
    // tail. A blocking listener lets this message leave before the chained
    // scroll does. Only native input crosses; Worker messages cannot.
    const onWheel = (event: WheelEvent) => {
      if (stopped || !event.isTrusted || event.ctrlKey) return;
      send({
        type: "wheel",
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaMode: event.deltaMode,
      });
    };
    document.addEventListener("wheel", onWheel, { passive: false });
    document.addEventListener(
      "click",
      (event) => {
        const link =
          event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!link) return;
        event.preventDefault();
        if (stopped || !event.isTrusted) return;
        const url = new URL(link.getAttribute("href")!);
        if (url.protocol === "https:" && !url.username && !url.password)
          send({ type: "open-link", url: url.href });
      },
      true
    );
    const stop = (reason: string) => {
      if (stopped) return;
      stopped = true;
      document.removeEventListener("wheel", onWheel);
      worker?.terminate();
      cards?.dispose();
      timers.forEach(clearInterval);
      document.body.replaceChildren();
      send({ type: "error", reason });
    };
    try {
      const { payload, state, theme, icons, tokens, seed, locale, copy, cardState } =
        initial.data;
      applyTokens(tokens);
      cardProgress = cardState;
      // Templates load on the first comma.card call; authored-only widgets never build them.
      const cardsFor = () =>
        (cards ??= createCards({
          seed: typeof seed === "string" ? seed.slice(0, 200) : "",
          locale: typeof locale === "string" ? locale.slice(0, 35) : "",
          copy: copy && typeof copy === "object" ? copy : {},
          icons: icons && typeof icons === "object" ? icons : {},
          state: cardProgress,
          send: (message: CardOutgoing) => send(message),
        }));
      if (
        !payload ||
        payload.version !== 1 ||
        typeof payload.html !== "string" ||
        typeof payload.script !== "string" ||
        JSON.stringify(payload).length > 262144
      )
        throw Error("Invalid UI payload");
      const content = document.createElement("div");
      content.style.display = "flow-root";
      document.body.append(content);
      // Template content is inert. Never attach these parsed nodes to the document.
      const template = document.createElement("template");
      template.innerHTML = payload.html;
      const externalScripts: string[] = [];
      let nodes = 0;
      let charts = 0;
      const ids = new Map<string, HTMLElement>();
      const chartViews = new Map<
        HTMLCanvasElement,
        { width: number; render: () => void }
      >();
      // This bootstrap is serialized into the iframe; helpers must stay inside it.
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const validateDepth = (node: Node, depth: number) => {
        if (depth > 20) throw Error("UI tree exceeds its depth budget");
        for (const child of node.childNodes) validateDepth(child, depth + 1);
      };
      const replaceContent = (element: HTMLElement, fragment: DocumentFragment) => {
        if (!content.contains(element))
          throw Error("UI update target is no longer present");
        let depth = 0;
        for (
          let parent = element.parentElement;
          parent && parent !== content;
          parent = parent.parentElement
        )
          depth++;
        validateDepth(fragment, depth);
        if (countNodes(content) - countNodes(element) + countNodes(fragment) > 500)
          throw Error("UI tree exceeds its node budget");
        for (const [id, child] of ids) {
          if (child !== element && element.contains(child)) ids.delete(id);
        }
        for (const chart of chartViews.keys()) {
          if (element.contains(chart)) chartViews.delete(chart);
        }
        element.replaceChildren(fragment);
      };
      const construct = (node: Node, depth: number): Node => {
        if (++nodes > 500 || depth > 20) throw Error("UI tree exceeds its budget");
        if (node.nodeType === Node.TEXT_NODE)
          return document.createTextNode(node.textContent ?? "");
        if (!(node instanceof HTMLElement) || !tags.has(node.localName))
          throw Error(
            `Unsupported UI element <${node instanceof Element ? node.localName : "unknown"}>`
          );
        if (node.localName === "comma-chart" && ++charts > 8)
          throw Error("A UI supports at most eight charts");
        const resourceAttributes: Record<string, string[]> = {
          src: ["img", "script"],
          href: ["link", "a"],
          rel: ["link"],
          alt: ["img"],
        };
        for (const [name, allowed] of Object.entries(resourceAttributes)) {
          if (node.hasAttribute(name) && !allowed.includes(node.localName))
            throw Error("Unsupported resource attribute");
        }
        if (node.localName === "a") {
          const url = new URL(node.getAttribute("href") ?? "");
          if (url.protocol !== "https:" || url.username || url.password)
            throw Error("Links require an HTTPS URL without credentials");
          if (node.querySelector("a,button,input,select"))
            throw Error("A linked item cannot contain other interactive controls");
        }
        if (["img", "link", "script"].includes(node.localName)) {
          const address = node.getAttribute(node.localName === "link" ? "href" : "src");
          const url = new URL(address ?? "");
          if (url.protocol !== "https:" || url.username || url.password)
            throw Error("Resource URLs must use HTTPS without credentials");
          if (node.localName === "img" && !node.hasAttribute("alt"))
            throw Error("Images require alt text");
          if (node.localName === "link" && node.getAttribute("rel") !== "stylesheet")
            throw Error("Only stylesheet links are supported");
          if (node.localName === "script" && node.childNodes.length)
            throw Error("Inline script elements are unavailable; use the script field");
        }
        const element = document.createElement(
          node.localName === "comma-chart"
            ? "canvas"
            : node.localName === "comma-icon"
              ? "span"
              : node.localName
        );
        if (node.localName === "img" || node.localName === "link") {
          element.setAttribute("crossorigin", "anonymous");
          element.setAttribute("referrerpolicy", "no-referrer");
        }
        for (const attribute of node.attributes) {
          if (!attributes.has(attribute.name) || attribute.value.length > 4000)
            throw Error("Unsupported UI attribute");
          if (
            attribute.name === "class" &&
            attribute.value
              .split(/\s+/)
              .some((value) => value && !/^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$/.test(value))
          )
            throw Error("Invalid CSS class name");
          if (
            attribute.name === "type" &&
            !["button", "text", "number", "range", "checkbox"].includes(attribute.value)
          )
            throw Error("Unsupported input type");
          if (attribute.name === "id") {
            if (
              !/^[a-zA-Z][\w-]{0,63}$/.test(attribute.value) ||
              ids.has(attribute.value)
            )
              throw Error("Invalid or duplicate element id");
            ids.set(attribute.value, element);
          }
          element.setAttribute(attribute.name, attribute.value);
        }
        if (node.localName === "script") {
          externalScripts.push(node.getAttribute("src")!);
          return document.createTextNode("");
        }
        if (node.localName === "comma-icon") {
          const name = node.getAttribute("name");
          if (
            !name ||
            ![
              "clock",
              "check",
              "info",
              "sun",
              "moon",
              "cloud",
              "partly-cloudy",
              "rain",
              "snow",
              "train",
            ].includes(name) ||
            typeof icons?.[name] !== "string"
          )
            throw Error("Unsupported Comma icon");
          element.setAttribute("data-comma-icon", name);
          if (!element.hasAttribute("aria-label"))
            element.setAttribute("aria-hidden", "true");
          else element.setAttribute("role", "img");
          const icon = document.createElement("template");
          icon.innerHTML = icons[name];
          element.append(icon.content.cloneNode(true));
        }
        if (element instanceof HTMLCanvasElement) {
          element.width = 800;
          element.height = 320;
          element.style.width = "100%";
          element.style.height = "160px";
          element.setAttribute("role", "img");
        }
        for (const child of node.childNodes)
          element.append(construct(child, depth + 1));
        if (element.localName === "button") element.setAttribute("type", "button");
        return element;
      };
      for (const node of template.content.childNodes)
        content.append(construct(node, 0));
      if (countNodes(content) > 500) throw Error("UI tree exceeds its node budget");
      for (const node of content.childNodes) validateDepth(node, 0);
      applyTheme(theme);
      if (payload.script.trim() || externalScripts.length) {
        const source = `const __name = (fn) => fn; (${workerSource})(${JSON.stringify(externalScripts)},${JSON.stringify(payload.data ?? {})},${JSON.stringify(state ?? {})});\n${payload.script}\n`;
        const url = URL.createObjectURL(
          new Blob([source], { type: "text/javascript" })
        );
        worker = new Worker(url);
        URL.revokeObjectURL(url);
        worker.addEventListener("error", () => stop("UI script failed"));
        // Applies one SDK change. An invalid change throws and stops the widget.
        const apply = (message: MessageEvent["data"]) => {
          if (!message || typeof message !== "object")
            throw Error("Unsupported UI operation");
          const element = ids.get(message.id);
          switch (message.type) {
            case "pong":
              if (message.value === pendingPing) pendingPing = undefined;
              break;
            case "text":
              if (
                !element ||
                typeof message.value !== "string" ||
                message.value.length > 4000
              )
                throw Error("Invalid text update");
              if (["table", "thead", "tbody", "tr"].includes(element.localName))
                throw Error(
                  "comma.text accepts plain text, not table rows. Use comma.table on a table element."
                );
              {
                const fragment = document.createDocumentFragment();
                fragment.append(document.createTextNode(message.value));
                replaceContent(element, fragment);
              }
              break;
            case "table": {
              const value = message.value;
              if (
                !(element instanceof HTMLTableElement) ||
                !value ||
                !Array.isArray(value.columns) ||
                value.columns.length < 1 ||
                value.columns.length > 6 ||
                !value.columns.every(
                  (column: unknown) =>
                    typeof column === "string" &&
                    column.length > 0 &&
                    column.length <= 80
                ) ||
                !Array.isArray(value.rows) ||
                value.rows.length > 24 ||
                !value.rows.every(
                  (row: unknown) =>
                    Array.isArray(row) &&
                    row.length === value.columns.length &&
                    row.every(
                      (cell: unknown) =>
                        cell === null ||
                        typeof cell === "boolean" ||
                        (typeof cell === "number" && Number.isFinite(cell)) ||
                        (typeof cell === "string" && cell.length <= 500)
                    )
                )
              )
                throw Error(
                  "Invalid table data. Use up to 6 column labels and 24 rows of plain values."
                );
              const fragment = document.createDocumentFragment();
              const head = document.createElement("thead");
              const heading = document.createElement("tr");
              element.setAttribute("role", "table");
              head.setAttribute("role", "rowgroup");
              heading.setAttribute("role", "row");
              for (const column of value.columns) {
                const cell = document.createElement("th");
                cell.scope = "col";
                cell.setAttribute("role", "columnheader");
                cell.textContent = column;
                heading.append(cell);
              }
              head.append(heading);
              fragment.append(head);
              const body = document.createElement("tbody");
              body.setAttribute("role", "rowgroup");
              for (const row of value.rows) {
                const line = document.createElement("tr");
                line.setAttribute("role", "row");
                row.forEach((text: unknown, index: number) => {
                  const cell = document.createElement("td");
                  cell.setAttribute("role", "cell");
                  cell.dataset.commaLabel = value.columns[index];
                  cell.textContent = text === null ? "—" : String(text);
                  line.append(cell);
                });
                body.append(line);
              }
              fragment.append(body);
              replaceContent(element, fragment);
              element.classList.add("comma-data-table");
              break;
            }
            case "value":
              if (
                !(
                  element instanceof HTMLInputElement ||
                  element instanceof HTMLSelectElement ||
                  element instanceof HTMLProgressElement
                ) ||
                typeof message.value !== "string" ||
                message.value.length > 4000
              )
                throw Error("Invalid value update");
              element.setAttribute("value", message.value);
              if (!(element instanceof HTMLProgressElement))
                element.value = message.value;
              break;
            case "visible":
              if (!element || typeof message.value !== "boolean")
                throw Error("Invalid visibility update");
              element.hidden = !message.value;
              break;
            case "chart": {
              const chart = message.value;
              if (
                !(element instanceof HTMLCanvasElement) ||
                !chart ||
                !["bar", "line"].includes(chart.type) ||
                !Array.isArray(chart.values) ||
                !Array.isArray(chart.labels) ||
                chart.values.length === 0 ||
                chart.values.length > 64 ||
                chart.labels.length !== chart.values.length ||
                chart.values.some(
                  (v: unknown) => typeof v !== "number" || !Number.isFinite(v)
                ) ||
                chart.labels.some(
                  (v: unknown) => typeof v !== "string" || v.length > 80
                )
              )
                throw Error("Invalid chart data");
              const render = () => {
                const width = Math.max(1, element.clientWidth);
                const context = element.getContext("2d")!;
                // Draw in CSS pixels so narrow cards retain readable type.
                context.setTransform(800 / width, 0, 0, 2, 0, 0);
                context.clearRect(0, 0, width, 160);
                const magnitude = Math.max(
                  1,
                  ...chart.values.map((value: number) => Math.abs(value))
                );
                const values = chart.values.map((value: number) => value / magnitude);
                const min = Math.min(0, ...values);
                const max = Math.max(0, ...values);
                const range = max - min || 1;
                const y = (value: number) => 125 - ((value - min) / range) * 110;
                const step = Math.max(1, width - 16) / values.length;
                context.strokeStyle = context.fillStyle =
                  getComputedStyle(document.documentElement)
                    .getPropertyValue("--comma-accent")
                    .trim() || "#6366f1";
                context.lineWidth = 2;
                context.beginPath();
                values.forEach((value: number, index: number) => {
                  const x = 8 + index * step;
                  if (chart.type === "bar")
                    context.fillRect(
                      x + step * 0.15,
                      Math.min(y(0), y(value)),
                      step * 0.7,
                      Math.max(1, Math.abs(y(value) - y(0)))
                    );
                  else if (index === 0) context.moveTo(x + step / 2, y(value));
                  else context.lineTo(x + step / 2, y(value));
                });
                if (chart.type === "line") context.stroke();
                const style = getComputedStyle(document.body);
                context.fillStyle = style.color;
                context.font = `${style.fontSize} ${style.fontFamily}`;
                context.textAlign = "center";
                const stride = Math.max(1, Math.ceil(64 / step));
                chart.labels.forEach((label: string, index: number) => {
                  if (index % stride === 0)
                    context.fillText(
                      label,
                      8 + (index + 0.5) * step,
                      150,
                      Math.min(step * stride - 4, width)
                    );
                });
                chartViews.set(element, { width, render });
              };
              render();
              element.setAttribute(
                "aria-label",
                chart.labels
                  .map(
                    (label: string, index: number) => `${label}: ${chart.values[index]}`
                  )
                  .join(", ")
              );
              break;
            }
            case "card":
              if (!element)
                throw Error("comma.card needs the id of an element in html");
              replaceContent(
                element,
                cardsFor().mount(
                  element,
                  {
                    kind: message.kind,
                    data: message.value,
                    variant: message.variant,
                  },
                  message.id
                )
              );
              break;
            case "save":
              send({ type: "save", value: message.value });
              break;
            case "request":
              if (typeof message.value !== "string" || message.value.length > 4000)
                throw Error("Invalid follow-up request");
              send({ type: "request", value: message.value });
              break;
            case "timer":
              if (
                timers.length >= 8 ||
                !Number.isInteger(message.id) ||
                !Number.isFinite(message.ms) ||
                message.ms < 1000 ||
                message.ms > 86400000
              )
                throw Error("Invalid timer");
              timers.push(
                window.setInterval(
                  () => worker?.postMessage({ type: "tick", id: message.id }),
                  message.ms
                )
              );
              break;
            default:
              throw Error("Unsupported UI operation");
          }
        };
        worker.addEventListener("message", (event: MessageEvent) => {
          if (stopped) return;
          try {
            if (performance.now() - windowStart > 1000) {
              count = 0;
              windowStart = performance.now();
            }
            if (++count > 60) throw Error("UI update rate exceeded");
            const message = event.data;
            if (
              !message ||
              typeof message !== "object" ||
              messageEncoder.encode(JSON.stringify(message)).length > 32768
            )
              throw Error("UI message budget exceeded");
            // A batch is one Worker task's SDK calls. It counts as one update.
            const updates: unknown = message.type === "batch" ? message.ops : [message];
            if (!Array.isArray(updates) || updates.length > 500)
              throw Error("UI message budget exceeded");
            for (const update of updates) apply(update);
          } catch (error) {
            stop(error instanceof Error ? error.message : "Invalid UI update");
          }
        });
        for (const eventName of ["click", "input", "change"])
          document.addEventListener(eventName, (event) => {
            if (stopped || !(event.target instanceof Element)) return;
            const value = {
              value: (event.target as HTMLInputElement).value ?? "",
              checked: (event.target as HTMLInputElement).checked ?? false,
            };
            // Mirror DOM bubbling through authored IDs, including when the
            // physical target is a nested label or a trusted SVG icon.
            for (
              let target: Element | null = event.target;
              target && content.contains(target);
              target = target.parentElement
            ) {
              if (ids.get(target.id) !== target) continue;
              worker?.postMessage({
                type: "event",
                id: target.id,
                event: eventName,
                value,
              });
            }
          });
        // Each challenge is issued after the previous response. A blocked Worker
        // cannot read the next random challenge from its event queue.
        timers.push(
          window.setInterval(() => {
            if (pendingPing) {
              if (performance.now() - pingAt > 1500) stop("UI script timed out");
              return;
            }
            pendingPing = Array.from(crypto.getRandomValues(new Uint32Array(4))).join(
              "-"
            );
            pingAt = performance.now();
            worker?.postMessage({ type: "ping", value: pendingPing });
          }, 250)
        );
      }
      let height = 0;
      timers.push(
        window.setInterval(() => {
          for (const [element, view] of chartViews) {
            if (element.clientWidth !== view.width) view.render();
          }
          const bodyStyle = getComputedStyle(document.body);
          const naturalHeight =
            content.getBoundingClientRect().height +
            Number.parseFloat(bodyStyle.paddingTop) +
            Number.parseFloat(bodyStyle.paddingBottom);
          const next = Math.min(12000, Math.max(60, Math.ceil(naturalHeight)));
          if (next !== height) {
            height = next;
            send({ type: "height", value: height });
          }
        }, 100)
      );
      send({ type: "ready" });
    } catch (error) {
      stop(error instanceof Error ? error.message : "UI could not start");
    }
    port.addEventListener("message", (event) => {
      if (event.data?.type === "stop") stop("UI stopped");
      if (event.data?.type === "state") worker?.postMessage(event.data);
      if (event.data?.type === "theme") {
        applyTheme(event.data.theme);
        applyTokens(event.data.tokens);
      }
      if (event.data?.type === "brand-icons") cards?.receiveIcons(event.data.icons);
      if (event.data?.type === "card-state") {
        cardProgress = event.data.value;
        cards?.receiveState(cardProgress);
      }
    });
    port.start();
  });
  parent.postMessage({ type: "comma-ui:ready" }, "*");
}

export function dynamicUiDocument() {
  const css = `
:root{color-scheme:light;--comma-background:light-dark(#fff,#18191b);--comma-foreground:light-dark(#222326,#f1f1f1);--comma-muted:light-dark(#70707b,#a4a5a9);--comma-border:light-dark(#e4e4e7,#343538);--comma-surface:light-dark(#f4f4f5,#27282b)}*{box-sizing:border-box;min-width:0}html{overflow:hidden;background:transparent}
img{max-width:100%;height:auto}body{margin:0;padding:2px;background:transparent;color:var(--comma-secondary,var(--comma-foreground,CanvasText));font-family:var(--comma-font,system-ui);font-size:var(--comma-size,13px);font-weight:450;line-height:1.5;overflow-wrap:anywhere;-webkit-font-smoothing:antialiased}
h2,h3,p{margin:0}h2,.widget-title{font-size:var(--comma-h2,12px);font-weight:500;color:var(--comma-muted,GrayText)}h3{font-size:var(--comma-h3,13px);font-weight:600}small,.sub,.widget-meta{font-size:var(--comma-small,12px);color:var(--comma-muted,GrayText)}
.stack{display:flex;flex-direction:column;gap:var(--comma-control,8px)}.row,.widget-head,.widget-footer{display:flex;flex-wrap:wrap;align-items:center;gap:var(--comma-control,8px)}
.grid,.widget-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,168px),1fr));gap:var(--comma-space,16px)}.span-2{grid-column:span 2}.muted{color:var(--comma-muted,GrayText)}
.metric,.hero{color:var(--comma-foreground,CanvasText);font-size:var(--comma-metric,24px);line-height:1.3;letter-spacing:-.02em;font-weight:600;font-variant-numeric:tabular-nums}.unit{font-size:var(--comma-size,13px);font-weight:500;color:var(--comma-muted,GrayText);letter-spacing:normal}.grow{flex:1}.widget-head{gap:6px;min-height:20px}.widget-head [data-comma-icon]{width:16px;height:16px}.widget-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.widget-head .widget-meta{margin-inline-start:auto}.widget-body{display:flex;flex-direction:column;gap:var(--comma-control,8px);flex:1}.widget-footer{margin-block-start:auto;padding-block-start:var(--comma-control,8px)}
.card{display:flex;flex-direction:column;gap:var(--comma-control,8px);padding:var(--comma-space,16px);border-radius:var(--comma-radius,16px);background:var(--comma-background,Canvas);box-shadow:inset 0 0 0 .5px var(--comma-border,GrayText),var(--comma-shadow,0 1px 2px #0000000d)}
.divider{border:0;border-top:.5px solid var(--comma-border,GrayText);margin-block:var(--comma-control,8px)}.list-item{display:flex;align-items:center;gap:var(--comma-control,8px);padding-block:var(--comma-control,8px)}.list-item.stack{align-items:stretch}.list-item+.list-item{border-top:.5px solid var(--comma-border,GrayText)}.badge{border-radius:999px;padding:2px 8px;background:var(--comma-surface,ButtonFace);font-size:var(--comma-small,12px)}.success{color:var(--comma-success,#067647)}.danger{color:var(--comma-danger,#b42318)}
button,input,select{font:inherit;color:inherit;background:var(--comma-surface,ButtonFace);border:.5px solid var(--comma-border,GrayText);border-radius:var(--comma-radius,16px);padding:var(--comma-control,8px) var(--comma-space,16px);max-width:100%;min-height:44px}input[type=checkbox]{min-height:24px;min-width:24px;margin:10px}input[type=range]{padding-inline:0}button{cursor:pointer;font-weight:500}button.primary{background:var(--comma-accent,Highlight);color:white;border-color:transparent}@media(hover:hover) and (pointer:fine){button:hover{filter:brightness(.96)}}button:disabled{opacity:.5;cursor:default}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--comma-accent,Highlight);outline-offset:2px}
[data-comma-icon]{display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;flex:none;color:inherit}[data-comma-icon]>svg{width:100%;height:100%}[data-comma-icon].icon-lg{width:32px;height:32px}[data-comma-icon].icon-hero{width:48px;height:48px}a{color:inherit;text-decoration:none;cursor:pointer;display:block;min-height:44px}a:hover{background:color-mix(in srgb,var(--comma-accent,#6366f1) 6%,transparent)}a:focus-visible{outline:2px solid var(--comma-accent,Highlight);outline-offset:2px;border-radius:8px}.tone-warm{color:var(--comma-warm,light-dark(#b54708,#fec84b))}.tone-cool{color:var(--comma-accent,light-dark(#4f46e5,#a5b4fc))}.feature{display:flex;flex-wrap:wrap;align-items:center;gap:var(--comma-space,16px);padding:var(--comma-space,16px);border-radius:var(--comma-radius,16px);background:color-mix(in srgb,var(--comma-accent,#6366f1) 6%,var(--comma-background,Canvas))}.compact-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,88px),1fr));gap:var(--comma-space,16px)}
.display{font-size:56px;font-weight:300;line-height:1;letter-spacing:-.04em;font-variant-numeric:tabular-nums}.spread{display:flex;justify-content:space-between;align-items:center;gap:16px}.align-end{align-items:flex-end;text-align:end}.strip{display:flex;gap:4px;justify-content:space-between;padding-block:16px}.strip>*{flex:1;min-width:0;align-items:center;text-align:center;font-variant-numeric:tabular-nums}.strip strong{font-size:13px;white-space:nowrap}.surface-night{background:linear-gradient(155deg,#232638,#39475f);color:#fff;border-color:#ffffff20;--comma-foreground:#fff;--comma-secondary:#fff;--comma-muted:#cbd5e1;--comma-accent:#fff;--comma-warm:#fff;--comma-surface:#ffffff15}.surface-night .widget-title,.surface-night h2{color:inherit}.surface-night small{color:var(--comma-muted)}
@media(max-width:420px){.strip{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));row-gap:16px}.display{font-size:48px}}
button{transition:transform var(--comma-motion-feedback,120ms) var(--comma-motion-ease,cubic-bezier(.16,1,.3,1))}button:active:not(:disabled){transform:scale(.98)}
@media(prefers-reduced-motion:reduce){.motion-enter,.motion-stagger>*{animation:none}button{transition:none}button:active:not(:disabled){transform:none}}
progress{width:100%;accent-color:var(--comma-accent,Highlight)}ul{padding-inline-start:var(--comma-space,16px);margin:0}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}th{font-size:var(--comma-small,12px);font-weight:500;color:var(--comma-muted,GrayText)}td,th{text-align:start;padding:var(--comma-control,8px);border-bottom:.5px solid var(--comma-border,GrayText)}.comma-data-table td{vertical-align:top}.comma-data-table th{overflow-wrap:normal}
@media(max-width:420px){.span-2{grid-column:1/-1}.comma-data-table,.comma-data-table tbody{display:block}.comma-data-table thead{position:absolute;width:1px;height:1px;clip-path:inset(50%);overflow:hidden;white-space:nowrap}.comma-data-table tr{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--comma-control,8px);padding:var(--comma-space,16px) 0;border-bottom:.5px solid var(--comma-border,GrayText)}.comma-data-table td{display:flex;flex-direction:column;padding:0;border:0}.comma-data-table td:first-child{grid-column:1/-1;font-weight:600}.comma-data-table td:not(:first-child)::before{content:attr(data-comma-label);font-size:var(--comma-small,12px);color:var(--comma-muted,GrayText)}}[hidden]{display:none!important}
`;
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${css}${cardCss}</style></head><body><script>const __name = (fn) => fn; (${runtimeBootstrap.toString()})(${JSON.stringify(workerBootstrap.toString())}, ${cardEngine.toString()})</script></body></html>`;
}
