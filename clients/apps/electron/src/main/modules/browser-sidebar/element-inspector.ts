import type { BrowserSidebarInspectResult } from "@comma/native-bridge";

type BrowserSidebarElementSelectionResult =
  | Exclude<BrowserSidebarInspectResult, { status: "selected" }>
  | Omit<Extract<BrowserSidebarInspectResult, { status: "selected" }>, "userMessage">;

type InspectionController = {
  cancel(): void;
  start(): Promise<BrowserSidebarElementSelectionResult>;
};

declare global {
  // This function is stringified and executed inside the inspected page.
  // eslint-disable-next-line no-var
  var commaBrowserSidebarElementInspector: InspectionController | undefined;
}

// oxlint-disable unicorn/consistent-function-scoping -- The page script must remain self-contained so it can be stringified safely.
function runBrowserSidebarElementInspector(): Promise<BrowserSidebarElementSelectionResult> {
  const existing = globalThis.commaBrowserSidebarElementInspector;
  if (existing) return existing.start();

  const maxTextLength = 3_000;
  const maxHtmlLength = 6_000;
  const allowedAttributes = new Set([
    "alt",
    "aria-label",
    "class",
    "href",
    "id",
    "name",
    "placeholder",
    "role",
    "src",
    "title",
    "type",
  ]);
  let active = false;
  let hoveredElement: Element | undefined;
  let selectedElement: Element | undefined;
  let resolveSelection:
    | ((result: BrowserSidebarElementSelectionResult) => void)
    | undefined;
  let selectionTimeout: ReturnType<typeof setTimeout> | undefined;

  const host = document.createElement("div");
  host.id = "comma-browser-sidebar-element-inspector";
  Object.assign(host.style, {
    display: "none",
    inset: "0",
    pointerEvents: "none",
    position: "fixed",
    zIndex: "2147483647",
  });
  const shadow = host.attachShadow({ mode: "closed" });
  const style = document.createElement("style");
  style.textContent = `
    .comma-inspector-box {
      background: rgba(90, 111, 255, 0.22);
      border: 2px solid rgba(90, 111, 255, 0.9);
      border-radius: 4px;
      box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.55);
      box-sizing: border-box;
      display: none;
      pointer-events: none;
      position: fixed;
    }
  `;
  const hoverBox = document.createElement("div");
  hoverBox.className = "comma-inspector-box";
  shadow.append(style, hoverBox);
  document.documentElement.append(host);

  const clipped = (value: string, maxLength: number) => {
    const normalized = value.replace(/\s+/gu, " ").trim();
    return normalized.length <= maxLength
      ? normalized
      : `${normalized.slice(0, maxLength)}\n...[truncated]`;
  };
  const hideBox = () => {
    hoverBox.style.display = "none";
  };
  const showBox = (element: Element) => {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      hideBox();
      return;
    }
    Object.assign(hoverBox.style, {
      display: "block",
      height: `${rect.height}px`,
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
    });
  };
  const cssEscape = (value: string) =>
    globalThis.CSS?.escape
      ? globalThis.CSS.escape(value)
      : value.replace(/[^a-zA-Z0-9_-]/gu, "\\$&");
  const selectorForElement = (element: Element) => {
    if (element.id) return `#${cssEscape(element.id)}`;
    const parts: string[] = [];
    let current: Element | null = element;
    while (current && current !== document.documentElement && parts.length < 6) {
      let part = current.tagName.toLowerCase();
      const classes = Array.from(current.classList).slice(0, 3);
      if (classes.length > 0) part += `.${classes.map(cssEscape).join(".")}`;
      const parent: Element | null = current.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter(
          (sibling) => sibling.tagName === current?.tagName
        );
        if (siblings.length > 1) {
          part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
        }
      }
      parts.unshift(part);
      current = parent;
    }
    return parts.join(" > ") || element.tagName.toLowerCase();
  };
  const finish = (result: BrowserSidebarElementSelectionResult) => {
    active = false;
    hoveredElement = undefined;
    selectedElement = undefined;
    host.style.display = "none";
    hideBox();
    const resolve = resolveSelection;
    resolveSelection = undefined;
    if (selectionTimeout !== undefined) {
      globalThis.clearTimeout(selectionTimeout);
      selectionTimeout = undefined;
    }
    resolve?.(result);
  };
  const elementFromEvent = (event: Event) => {
    const target = event.target;
    if (target instanceof Element) return target;
    if (target instanceof Node && target.parentElement) return target.parentElement;
    return undefined;
  };
  const visibleElementText = (element: Element) => {
    if (element instanceof HTMLInputElement) {
      return ["hidden", "password"].includes(element.type.toLowerCase())
        ? ""
        : element.value;
    }
    if (element instanceof HTMLTextAreaElement) return element.value;
    if (element instanceof HTMLSelectElement) {
      return element.selectedOptions[0]?.textContent || element.value;
    }
    if (element instanceof HTMLElement) return element.innerText || "";
    return element.textContent || "";
  };
  const blockedHtmlTags = new Set([
    "embed",
    "iframe",
    "noscript",
    "object",
    "script",
    "style",
    "template",
  ]);
  const isSensitiveOrHiddenElement = (element: Element) => {
    const tagName = element.tagName.toLowerCase();
    if (blockedHtmlTags.has(tagName)) return true;
    if (
      tagName === "input" &&
      ["hidden", "password"].includes(
        (element.getAttribute("type") || "text").toLowerCase()
      )
    ) {
      return true;
    }
    if (
      element.hasAttribute("hidden") ||
      element.hasAttribute("inert") ||
      element.getAttribute("aria-hidden")?.toLowerCase() === "true"
    ) {
      return true;
    }
    try {
      const computedStyle = globalThis.getComputedStyle(element);
      return (
        computedStyle.display === "none" ||
        computedStyle.opacity === "0" ||
        computedStyle.visibility === "collapse" ||
        computedStyle.visibility === "hidden"
      );
    } catch {
      return true;
    }
  };
  const sanitizedElementHtml = (element: Element) => {
    if (isSensitiveOrHiddenElement(element)) return "";
    const clone = element.cloneNode(true);
    if (!(clone instanceof Element)) return "";

    const sanitizeElement = (source: Element, sanitized: Element) => {
      for (const attribute of Array.from(sanitized.attributes)) {
        if (!allowedAttributes.has(attribute.name)) {
          sanitized.removeAttribute(attribute.name);
        }
      }
      if (sanitized.tagName.toLowerCase() === "textarea") {
        sanitized.textContent = "";
      }
      for (const child of Array.from(sanitized.childNodes)) {
        if (child.nodeType === Node.COMMENT_NODE) child.remove();
      }

      const sourceChildren = Array.from(source.children);
      const sanitizedChildren = Array.from(sanitized.children);
      for (const [index, sourceChild] of sourceChildren.entries()) {
        const sanitizedChild = sanitizedChildren[index];
        if (!sanitizedChild) continue;
        if (isSensitiveOrHiddenElement(sourceChild)) {
          sanitizedChild.remove();
          continue;
        }
        sanitizeElement(sourceChild, sanitizedChild);
      }
    };

    sanitizeElement(element, clone);
    return clipped(clone.outerHTML || "", maxHtmlLength);
  };
  const onMouseMove = (event: MouseEvent) => {
    if (!active) return;
    hoveredElement = elementFromEvent(event);
    if (hoveredElement) showBox(hoveredElement);
  };
  const onClick = (event: MouseEvent) => {
    if (!active) return;
    const element = elementFromEvent(event);
    if (!element) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    event.stopPropagation();
    const rect = element.getBoundingClientRect();
    const attributes: Record<string, string> = {};
    for (const attribute of Array.from(element.attributes)) {
      if (allowedAttributes.has(attribute.name)) {
        attributes[attribute.name] = clipped(attribute.value, 500);
      }
    }
    active = false;
    selectedElement = element;
    showBox(element);
    const resolve = resolveSelection;
    resolveSelection = undefined;
    if (selectionTimeout !== undefined) {
      globalThis.clearTimeout(selectionTimeout);
      selectionTimeout = undefined;
    }
    resolve?.({
      element: {
        attributes,
        outerHTML: sanitizedElementHtml(element),
        rect: {
          height: rect.height,
          width: rect.width,
          x: rect.x,
          y: rect.y,
        },
        selector: selectorForElement(element),
        tagName: element.tagName.toLowerCase(),
        text: clipped(visibleElementText(element), maxTextLength),
      },
      inspectionId:
        globalThis.crypto?.randomUUID?.() ??
        `inspection-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      page: { title: document.title || undefined, url: globalThis.location.href },
      status: "selected",
    });
  };
  const cancel = () => finish({ status: "cancelled" });
  const updateOverlay = () => {
    const element = selectedElement ?? (active ? hoveredElement : undefined);
    if (element) showBox(element);
  };
  const start = () => {
    if (resolveSelection) finish({ status: "cancelled" });
    active = true;
    host.style.display = "block";
    hoveredElement = undefined;
    selectedElement = undefined;
    return new Promise<BrowserSidebarElementSelectionResult>((resolve) => {
      resolveSelection = resolve;
      selectionTimeout = globalThis.setTimeout(
        () => finish({ status: "cancelled" }),
        120_000
      );
    });
  };

  document.addEventListener("mousemove", onMouseMove, true);
  document.addEventListener("click", onClick, true);
  document.addEventListener(
    "keydown",
    (event) => {
      if (active && event.key === "Escape") cancel();
    },
    true
  );
  globalThis.addEventListener("scroll", updateOverlay, true);
  globalThis.addEventListener("resize", updateOverlay);
  globalThis.addEventListener("pagehide", cancel);

  const controller = { cancel, start };
  globalThis.commaBrowserSidebarElementInspector = controller;
  return controller.start();
}
// oxlint-enable unicorn/consistent-function-scoping

export const browserSidebarElementInspectorSource = `(${runBrowserSidebarElementInspector.toString()})()`;

export const browserSidebarElementInspectorCancelSource =
  "globalThis.commaBrowserSidebarElementInspector?.cancel();";
