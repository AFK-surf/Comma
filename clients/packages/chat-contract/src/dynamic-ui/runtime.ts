/* eslint-disable unicorn/require-post-message-target-origin -- Worker and MessagePort messages do not accept an origin. */
/// <reference lib="dom" />
import { cardEngine, type CardEngine, type CardOutgoing } from "./cards";
import { cardCss } from "./cardStyles";
import { cardTokenDefaults } from "./cardTokenDefaults";
import { dynamicUiLevel } from "./level";

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

function runtimeBootstrap(
  workerSource: string,
  createCards: typeof cardEngine,
  level: number
) {
  const messageEncoder = new TextEncoder();
  // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
  const applyTheme = (theme: Record<string, unknown> | undefined) => {
    if (theme && typeof theme === "object") {
      const scheme = theme.scheme === "dark" ? "dark" : "light";
      document.documentElement.style.colorScheme = scheme;
      // The card tokens' own dark values, for a host that resolves none.
      document.documentElement.dataset.commaScheme = scheme;
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
    // A right-click on a link asks the host for the menu chat gives its own
    // links; the host cannot see events inside this frame.
    document.addEventListener(
      "contextmenu",
      (event) => {
        const link =
          event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!link) return;
        event.preventDefault();
        if (stopped || !event.isTrusted) return;
        const url = new URL(link.getAttribute("href")!);
        if (url.protocol === "https:" && !url.username && !url.password)
          send({
            type: "link-menu",
            url: url.href,
            x: event.clientX,
            y: event.clientY,
          });
      },
      true
    );
    // Hovering or focusing a link asks the host for the preview chat gives its
    // own links, with the link's text and box in frame coordinates. A pointer
    // hover wins over focus. Losing both, or Escape, sends a null url.
    let pointerLink: Element | null = null;
    let focusLink: Element | null = null;
    let reportedLink: Element | null = null;
    let dismissedLink: Element | null = null;
    // Readable text only: card rows lead with an aria-hidden brand mark.
    // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
    const linkLabel = (link: Element) => {
      const walker = document.createTreeWalker(link, NodeFilter.SHOW_TEXT);
      const parts: string[] = [];
      for (let node = walker.nextNode(); node; node = walker.nextNode())
        if (!node.parentElement?.closest('[aria-hidden="true"]'))
          parts.push(node.textContent ?? "");
      return parts.join(" ").replaceAll(/\s+/g, " ").trim().slice(0, 200);
    };
    const reportLink = () => {
      const active = pointerLink ?? focusLink;
      if (active !== dismissedLink) dismissedLink = null;
      const link = active === dismissedLink ? null : active;
      if (link === reportedLink) return;
      reportedLink = link;
      let url: URL | undefined;
      try {
        url = link ? new URL(link.getAttribute("href")!) : undefined;
      } catch {
        url = undefined;
      }
      if (!link || !url || url.protocol !== "https:" || url.username || url.password) {
        send({ type: "link-hover", url: null });
        return;
      }
      const box = link.getBoundingClientRect();
      send({
        type: "link-hover",
        url: url.href,
        label: linkLabel(link),
        x: box.x,
        y: box.y,
        width: box.width,
        height: box.height,
      });
    };
    // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
    const linkOf = (target: EventTarget | null) =>
      target instanceof Element ? target.closest("a[href]") : null;
    // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
    const leaves = (link: Element, next: EventTarget | null) =>
      !(next instanceof Node) || !link.contains(next);
    document.addEventListener(
      "pointerover",
      (event) => {
        if (stopped || !event.isTrusted || event.pointerType === "touch") return;
        pointerLink = linkOf(event.target);
        reportLink();
      },
      true
    );
    document.addEventListener(
      "pointerout",
      (event) => {
        if (stopped || !event.isTrusted || !pointerLink) return;
        if (!leaves(pointerLink, event.relatedTarget)) return;
        pointerLink = null;
        reportLink();
      },
      true
    );
    document.addEventListener(
      "focusin",
      (event) => {
        if (stopped || !event.isTrusted) return;
        focusLink = linkOf(event.target);
        reportLink();
      },
      true
    );
    document.addEventListener(
      "focusout",
      (event) => {
        if (stopped || !event.isTrusted || !focusLink) return;
        if (!leaves(focusLink, event.relatedTarget)) return;
        focusLink = null;
        reportLink();
      },
      true
    );
    document.addEventListener(
      "keydown",
      (event) => {
        if (stopped || !event.isTrusted || event.key !== "Escape" || !reportedLink)
          return;
        dismissedLink = reportedLink;
        reportLink();
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
      const {
        payload,
        state,
        theme,
        icons,
        tokens,
        seed,
        locale,
        timeZone,
        copy,
        cardState,
      } = initial.data;
      applyTokens(tokens);
      cardProgress = cardState;
      // Templates load on the first comma.card call; authored-only widgets never build them.
      const cardsFor = () =>
        (cards ??= createCards({
          seed: typeof seed === "string" ? seed.slice(0, 200) : "",
          locale: typeof locale === "string" ? locale.slice(0, 35) : "",
          timeZone: typeof timeZone === "string" ? timeZone.slice(0, 64) : "",
          copy: copy && typeof copy === "object" ? copy : {},
          icons: icons && typeof icons === "object" ? icons : {},
          state: cardProgress,
          send: (message: CardOutgoing) => send(message),
        }));
      if (
        !payload ||
        !Number.isInteger(payload.version) ||
        payload.version < 1 ||
        typeof payload.html !== "string" ||
        typeof payload.script !== "string" ||
        JSON.stringify(payload).length > 262144
      )
        throw Error("Invalid UI payload");
      // A widget names the lowest runtime level that shows it (level.ts).
      if (payload.version > level) throw Error("UI needs a newer runtime");
      const content = document.createElement("div");
      content.className = "wc-root";
      content.style.display = "flow-root";
      document.body.append(content);
      // Template content is inert. Never attach these parsed nodes to the document.
      const template = document.createElement("template");
      template.innerHTML = payload.html;
      const externalScripts: string[] = [];
      let nodes = 0;
      let charts = 0;
      const ids = new Map<string, HTMLElement>();
      // A budget failure stops the whole widget, even inside one part's update.
      // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
      const overBudget = (reason: string) =>
        Object.assign(Error(reason), { budget: true });
      // This bootstrap is serialized into the iframe; helpers must stay inside it.
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const validateDepth = (node: Node, depth: number) => {
        if (depth > 20) throw overBudget("UI tree exceeds its depth budget");
        for (const child of node.childNodes) validateDepth(child, depth + 1);
      };
      const replaceContent = (element: HTMLElement, fragment: DocumentFragment) => {
        if (!content.contains(element))
          throw Error("UI update target is no longer present");
        // The shell the runtime puts around bare content is not the html's depth.
        let depth = 0;
        for (
          let parent = element.parentElement;
          parent && parent !== content;
          parent = parent.parentElement
        )
          if (!parent.classList.contains("comma-surface")) depth++;
        validateDepth(fragment, depth);
        // The html is at most 500 nodes. What the script renders into it (cards,
        // tables, text) is bounded per element, and by this for the widget.
        if (countNodes(content) - countNodes(element) + countNodes(fragment) > 2000)
          throw overBudget("UI tree exceeds its node budget");
        for (const [id, child] of ids) {
          if (child !== element && element.contains(child)) ids.delete(id);
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
            ? "figure"
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
        if (node.localName === "comma-chart") {
          element.classList.add("comma-chart");
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
      // Content the html leaves outside a card shell gets one, so a chart, a
      // list, a table or a control never sits bare beside cards. A run of
      // neighbours shares one shell. Headings and small print with no content
      // beside them stay as they are: labels and source lines between cards.
      // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
      const blank = (node: Node) =>
        node.nodeType === Node.TEXT_NODE && !node.textContent?.trim();
      const role = (node: ChildNode): "frame" | "layout" | "quiet" | "content" => {
        if (!(node instanceof HTMLElement)) return "content";
        if (node.localName === "link") return "quiet";
        if (node.localName === "section" || node.localName === "div") {
          // A card shell, or an empty element a card will fill.
          if (node.classList.contains("card") || [...node.childNodes].every(blank))
            return "frame";
          // An element that lays cards out holds them; anything else is content.
          return [...node.querySelectorAll("section,div")].some(
            (inner) =>
              inner.classList.contains("card") || [...inner.childNodes].every(blank)
          )
            ? "layout"
            : "content";
        }
        return ["h2", "h3", "small"].includes(node.localName) ||
          ["muted", "sub", "widget-meta", "widget-title"].some((name) =>
            node.classList.contains(name)
          )
          ? "quiet"
          : "content";
      };
      const surface = (parent: Element) => {
        let run: ChildNode[] = [];
        const close = () => {
          if (run.some((node) => !blank(node) && role(node) === "content")) {
            const shell = document.createElement("section");
            shell.className = "card comma-surface";
            run[0]!.before(shell);
            shell.append(...run);
          }
          run = [];
        };
        // A copy: closing a run moves its nodes out of this list.
        for (const node of Array.from(parent.childNodes)) {
          const kind = blank(node) ? "quiet" : role(node);
          if (kind === "frame" || kind === "layout") {
            close();
            if (kind === "layout") surface(node as Element);
          } else run.push(node);
        }
        close();
      };
      surface(content);
      applyTheme(theme);
      if (payload.script.trim() || externalScripts.length) {
        const source = `const __name = (fn) => fn; (${workerSource})(${JSON.stringify(externalScripts)},${JSON.stringify(payload.data ?? {})},${JSON.stringify(state ?? {})});\n${payload.script}\n`;
        const url = URL.createObjectURL(
          new Blob([source], { type: "text/javascript" })
        );
        worker = new Worker(url);
        URL.revokeObjectURL(url);
        worker.addEventListener("error", (event) =>
          stop(
            event.message ? `UI script failed: ${event.message}` : "UI script failed"
          )
        );
        // An update to one part that fails shows a note in that part's place,
        // so the rest of the widget stays. The host learns each reason once.
        const parts = new Set(["text", "table", "value", "visible", "chart", "card"]);
        const notes = new Map<HTMLElement, HTMLElement>();
        const textless = new Set(
          "input select option progress figure img br table thead tbody tr ul".split(
            " "
          )
        );
        const reported = new Set<string>();
        const partFailed =
          typeof copy?.partFailed === "string" &&
          copy.partFailed.length > 0 &&
          copy.partFailed.length <= 120
            ? copy.partFailed
            : "This part couldn’t be shown";
        const failPart = (element: HTMLElement | undefined, reason: string) => {
          if (!reported.has(reason) && reported.size < 8) {
            reported.add(reason);
            send({ type: "part-error", reason: reason.slice(0, 200) });
          }
          if (!element || !content.contains(element) || notes.has(element)) return;
          const note = document.createElement("p");
          note.className = "comma-part-failed";
          note.setAttribute("role", "note");
          if (typeof icons?.info === "string") {
            const icon = document.createElement("span");
            icon.setAttribute("data-comma-icon", "info");
            icon.setAttribute("aria-hidden", "true");
            const markup = document.createElement("template");
            markup.innerHTML = icons.info;
            icon.append(markup.content.cloneNode(true));
            note.append(icon);
          }
          note.append(document.createTextNode(partFailed));
          // Elements that hold no text keep their place hidden, the note beside
          // them (beside its table for a table's rows).
          if (textless.has(element.localName)) {
            element.hidden = true;
            (element.closest("table") ?? element).after(note);
            notes.set(element, note);
          } else {
            const fragment = document.createDocumentFragment();
            fragment.append(note);
            replaceContent(element, fragment);
          }
        };
        // Applies one SDK change. An invalid change to a part fails that part;
        // any other invalid change throws and stops the widget.
        const apply = (message: MessageEvent["data"]) => {
          if (!message || typeof message !== "object")
            throw Error("Unsupported UI operation");
          const element = ids.get(message.id);
          if (!parts.has(message.type)) return applyOther(message);
          // A later update to a part takes the notes of it and of what it holds.
          for (const [failed, note] of notes) {
            if (!element?.contains(failed)) continue;
            note.remove();
            notes.delete(failed);
            failed.hidden = false;
          }
          try {
            applyPart(message, element);
          } catch (error) {
            if ((error as { budget?: boolean }).budget) throw error;
            failPart(
              element,
              error instanceof Error ? error.message : "Invalid UI update"
            );
          }
        };
        const applyPart = (
          message: MessageEvent["data"],
          element: HTMLElement | undefined
        ) => {
          switch (message.type) {
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
              // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized iframe bootstrap.
              const numbers = (values: unknown, length: number) =>
                Array.isArray(values) &&
                values.length === length &&
                values.every((v) => typeof v === "number" && Number.isFinite(v));
              // One series as `values`, or up to four named ones as `series`.
              const series: Array<{ name: string; values: number[] }> | undefined =
                chart && Array.isArray(chart.series)
                  ? chart.series
                  : chart && Array.isArray(chart.values)
                    ? [{ name: "", values: chart.values }]
                    : undefined;
              if (
                !element?.classList.contains("comma-chart") ||
                !chart ||
                !["bar", "line"].includes(chart.type) ||
                !Array.isArray(chart.labels) ||
                chart.labels.length === 0 ||
                chart.labels.length > 64 ||
                chart.labels.some(
                  (v: unknown) => typeof v !== "string" || v.length > 80
                ) ||
                !series ||
                series.length === 0 ||
                series.length > 4 ||
                series.some(
                  (item: unknown) =>
                    !item ||
                    typeof item !== "object" ||
                    typeof (item as { name?: unknown }).name !== "string" ||
                    (item as { name: string }).name.length > 80 ||
                    !numbers((item as { values?: unknown }).values, chart.labels.length)
                ) ||
                (series.length > 1 && series.some((item) => !item.name.trim()))
              )
                throw Error("Invalid chart data");
              replaceContent(
                element,
                cardsFor().chart({
                  type: chart.type,
                  labels: chart.labels,
                  series: series.map((item) => ({
                    name: item.name,
                    values: item.values,
                  })),
                })
              );
              element.setAttribute(
                "aria-label",
                series
                  .map(
                    (item) =>
                      `${item.name ? `${item.name}: ` : ""}${chart.labels
                        .map(
                          (label: string, index: number) =>
                            `${label}: ${item.values[index]}`
                        )
                        .join(", ")}`
                  )
                  .join("; ")
                  .slice(0, 4000)
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
          }
        };
        const applyOther = (message: MessageEvent["data"]) => {
          switch (message.type) {
            case "pong":
              if (message.value === pendingPing) pendingPing = undefined;
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
  // Authored html stands on the design system's tokens, as the card templates
  // do (cardTokenDefaults gives every token a value; a host may resolve its
  // own). A card shell, a button or a progress bar the Agent writes is the
  // same surface and control a template draws.
  const css = `
:root{color-scheme:light}*{box-sizing:border-box;min-width:0}html{overflow:hidden;background:transparent}
img{max-width:100%;height:auto}body{margin:0;padding:2px 2px 4px;background:transparent;color:var(--color-text-secondary);font-family:var(--comma-font,system-ui);font-size:var(--text-sm);line-height:var(--text-sm--line-height);font-weight:var(--font-weight-regular);overflow-wrap:anywhere;-webkit-font-smoothing:antialiased}
h2,h3,p,figure{margin:0}.comma-part-failed{display:flex;align-items:center;gap:var(--spacing-sm);font-size:var(--text-xs);line-height:var(--text-xs--line-height);color:var(--color-text-tertiary)}.comma-part-failed [data-comma-icon]{width:var(--spacing-xl);height:var(--spacing-xl)}
h2,.widget-title{font-size:var(--text-sm);line-height:var(--text-sm--line-height);font-weight:var(--font-weight-medium);color:var(--color-text-secondary)}h3{font-size:var(--text-sm);line-height:var(--text-sm--line-height);font-weight:var(--font-weight-semibold);color:var(--color-text-primary)}strong{font-weight:var(--font-weight-semibold);color:var(--color-text-primary)}
small,.sub,.widget-meta{font-size:var(--text-xs);line-height:var(--text-xs--line-height);color:var(--color-text-tertiary)}.widget-meta{font-variant-numeric:tabular-nums}.muted{color:var(--color-text-tertiary)}
.stack{display:flex;flex-direction:column;gap:var(--spacing-md)}.row,.widget-footer{display:flex;flex-wrap:wrap;align-items:center;gap:var(--spacing-md)}.widget-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:var(--spacing-xxs) var(--spacing-sm)}
.grid,.widget-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,var(--spacing-11xl)),1fr));gap:var(--spacing-lg)}.span-2{grid-column:span 2}
.grid:has(>*>.wc-card),.widget-grid:has(>*>.wc-card){grid-template-columns:repeat(auto-fit,minmax(min(100%,calc(var(--spacing-10xl) * 2)),1fr))}
.metric,.hero{color:var(--color-text-primary);font-size:var(--text-title-2);line-height:var(--text-title-2--line-height);letter-spacing:var(--text-title-2--letter-spacing);font-weight:var(--font-weight-semibold);font-variant-numeric:tabular-nums}.unit{margin-inline-start:var(--spacing-xxs);font-size:var(--text-sm);line-height:var(--text-sm--line-height);font-weight:var(--font-weight-medium);color:var(--color-text-tertiary);letter-spacing:normal}
.grow{flex:1}.widget-head [data-comma-icon]{width:var(--spacing-xl);height:var(--spacing-xl)}.widget-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.widget-head .widget-meta{margin-inline-start:auto}.widget-body{display:flex;flex-direction:column;gap:var(--spacing-md);flex:1}.widget-footer{margin-block-start:auto;padding-block-start:var(--spacing-xs)}
.card{display:flex;flex-direction:column;gap:var(--spacing-lg);height:100%;padding:var(--spacing-xl);border-radius:var(--radius-2xl);background:var(--color-bg-popup-secondary);box-shadow:0 0 0 var(--border-width-default) var(--color-border-primary),var(--shadow-sm)}
.divider{border:0;border-top:var(--border-width-default) solid var(--color-border-secondary);margin-block:var(--spacing-md)}.list-item{display:flex;align-items:center;gap:var(--spacing-md);padding-block:var(--spacing-md)}.list-item.stack{align-items:stretch}.list-item+.list-item{border-top:var(--border-width-default) solid var(--color-border-secondary)}.list-item:first-child{padding-block-start:0}.list-item:last-child{padding-block-end:0}
.badge{display:inline-block;padding:var(--spacing-xxs) var(--spacing-md);border-radius:999px;background:var(--color-utility-gray-50);box-shadow:inset 0 0 0 var(--border-width-default) var(--color-utility-gray-200);color:var(--color-utility-gray-700);font-size:var(--text-xs);line-height:var(--text-xs--line-height);font-weight:var(--font-weight-medium);white-space:nowrap}
.success{color:var(--color-text-success-primary)}.danger{color:var(--color-text-error-primary)}.badge.success{background:var(--color-utility-success-50);box-shadow:inset 0 0 0 var(--border-width-default) var(--color-utility-success-200);color:var(--color-utility-success-700)}.badge.danger{background:var(--color-utility-error-50);box-shadow:inset 0 0 0 var(--border-width-default) var(--color-utility-error-200);color:var(--color-utility-error-700)}.badge.primary{background:var(--color-utility-brand-50);box-shadow:inset 0 0 0 var(--border-width-default) var(--color-utility-brand-200);color:var(--color-utility-brand-700)}
button,input,select{font:inherit;color:inherit;max-width:100%}
button,select,input:not([type=checkbox],[type=range]){min-height:calc(var(--spacing-4xl) + var(--spacing-xs));padding:var(--spacing-xs) var(--spacing-lg);border:var(--border-width-default) solid var(--color-button-secondary-border);border-radius:var(--radius-md);background:var(--color-button-secondary-bg);box-shadow:var(--shadow-xs);color:var(--color-button-secondary-fg)}
button{display:inline-flex;align-items:center;justify-content:center;gap:var(--spacing-xs);cursor:pointer;font-weight:var(--font-weight-medium);text-align:center;transition:transform var(--motion-duration-feedback-out) var(--motion-easing-smooth-out)}
button.primary{border-color:var(--color-button-primary-border);background:var(--color-button-primary-bg);color:var(--color-button-primary-fg)}@media(hover:hover) and (pointer:fine){button:hover{background:var(--color-bg-secondary);color:var(--color-text-primary)}button.primary:hover{background:var(--color-button-primary-bg-hover);color:var(--color-button-primary-fg)}}
button:active:not(:disabled){transform:scale(var(--motion-scale-pressed));transition-duration:var(--motion-duration-feedback-in)}button:disabled,input:disabled,select:disabled{opacity:var(--opacity-disabled);cursor:default}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--color-bg-brand-solid);outline-offset:2px}
input[type=checkbox]{width:var(--spacing-xl);height:var(--spacing-xl);margin:var(--spacing-xs);accent-color:var(--color-bg-brand-solid)}input[type=range]{width:100%;min-height:calc(var(--spacing-4xl) + var(--spacing-xs));margin:0;accent-color:var(--color-bg-brand-solid)}
@media(pointer:coarse){button,select,input:not([type=checkbox]){min-height:calc(var(--spacing-5xl) + var(--spacing-xs))}input[type=checkbox]{margin:calc(var(--spacing-lg) + var(--spacing-xxs))}}
progress{display:block;width:100%;height:var(--spacing-sm);overflow:hidden;appearance:none;border:0;border-radius:999px;background:var(--color-bg-quaternary);accent-color:var(--color-bg-brand-solid)}progress::-webkit-progress-bar{border-radius:999px;background:var(--color-bg-quaternary)}progress::-webkit-progress-value{border-radius:999px;background:var(--color-bg-brand-solid)}
[data-comma-icon]{display:inline-flex;align-items:center;justify-content:center;width:var(--spacing-2xl);height:var(--spacing-2xl);flex:none;color:inherit}[data-comma-icon]>svg{width:100%;height:100%}[data-comma-icon].icon-lg{width:var(--spacing-4xl);height:var(--spacing-4xl)}[data-comma-icon].icon-hero{width:var(--spacing-6xl);height:var(--spacing-6xl)}
a{color:inherit;text-decoration:none;cursor:pointer;display:block;min-height:var(--spacing-5xl);border-radius:var(--radius-md)}a:hover{background:var(--color-bg-quaternary)}a:focus-visible{outline:2px solid var(--color-bg-brand-solid);outline-offset:2px}
.tone-warm{color:var(--color-fg-warning-primary)}.tone-cool{color:var(--color-fg-brand-primary)}.feature{display:flex;flex-wrap:wrap;align-items:center;gap:var(--spacing-xl);padding:var(--spacing-xl);border-radius:var(--radius-lg);background:var(--color-bg-secondary)}.compact-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,var(--spacing-8xl)),1fr));gap:var(--spacing-lg)}
.display{font-size:var(--text-display-lg);font-weight:300;line-height:1;letter-spacing:var(--text-display-lg--letter-spacing);font-variant-numeric:tabular-nums}.spread{display:flex;justify-content:space-between;align-items:center;gap:var(--spacing-xl)}.align-end{align-items:flex-end;text-align:end}.strip{display:flex;gap:var(--spacing-xs);justify-content:space-between;padding-block:var(--spacing-xl)}.strip>*{flex:1;min-width:0;align-items:center;text-align:center;font-variant-numeric:tabular-nums}.strip strong{white-space:nowrap}
.surface-night{background:linear-gradient(155deg,#232638,#39475f);box-shadow:none;color:var(--color-fg-white)}.surface-night .widget-title,.surface-night h2,.surface-night h3,.surface-night strong,.surface-night .metric,.surface-night .hero{color:inherit}.surface-night small,.surface-night .muted,.surface-night .widget-meta,.surface-night .sub,.surface-night .unit{color:var(--color-alpha-white-80)}
@media(max-width:420px){.strip{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));row-gap:var(--spacing-xl)}}
@media(prefers-reduced-motion:reduce){.motion-enter,.motion-stagger>*{animation:none}button{transition:none}button:active:not(:disabled){transform:none}}
ul{margin:0;padding-inline-start:var(--spacing-xl)}ul:has(>.list-item){padding:0;list-style:none}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}th{font-size:var(--text-xs);line-height:var(--text-xs--line-height);font-weight:var(--font-weight-regular);color:var(--color-text-tertiary)}td,th{text-align:start;padding:var(--spacing-md) var(--spacing-sm);border-bottom:var(--border-width-default) solid var(--color-border-secondary)}tr>:first-child{padding-inline-start:0}tr>:last-child{padding-inline-end:0}tbody tr:last-child>*{border-bottom:0;padding-bottom:0}thead th{padding-top:0}
.comma-data-table td{vertical-align:top}.comma-data-table th{overflow-wrap:normal}
.comma-chart{container-type:inline-size;display:block;min-height:var(--spacing-9xl)}
@media(max-width:420px){.span-2{grid-column:1/-1}.comma-data-table,.comma-data-table tbody{display:block}.comma-data-table thead{position:absolute;width:1px;height:1px;clip-path:inset(50%);overflow:hidden;white-space:nowrap}.comma-data-table tr{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--spacing-md);padding:var(--spacing-xl) 0;border-bottom:var(--border-width-default) solid var(--color-border-secondary)}.comma-data-table td{display:flex;flex-direction:column;padding:0;border:0}.comma-data-table td:first-child{grid-column:1/-1;font-weight:var(--font-weight-semibold)}.comma-data-table td:not(:first-child)::before{content:attr(data-comma-label);font-size:var(--text-xs);line-height:var(--text-xs--line-height);color:var(--color-text-tertiary)}}[hidden]{display:none!important}
`;
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${cardTokenDefaults}${css}${cardCss}</style></head><body><script>const __name = (fn) => fn; (${runtimeBootstrap.toString()})(${JSON.stringify(workerBootstrap.toString())}, ${cardEngine.toString()}, ${dynamicUiLevel})</script></body></html>`;
}
