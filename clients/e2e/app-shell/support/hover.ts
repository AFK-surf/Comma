// Hover in the test's page (./child). Chromium updates hover on its own when
// content moves under a pointer that stays still, a frame or two after a
// layout, on its own schedule: between two test steps, or not yet. Content
// moved only by a transform or `translate` (a transition, a held animation)
// lays nothing out, and hover stays where it was until anything else does. A
// step that ends with the pointer over the page renders real frames, each
// after a layout of the test runner's own document (never the page's), until
// the browser's hover (what `:hover` matches) is what hit-testing at the
// pointer says it must be, so the next step starts from it either way. The
// browser sends the hover events itself; nothing is dispatched here.

let pointer: { x: number; y: number } | undefined;

/** Where the test's pointer is, in this page's coordinates; undefined when outside. */
export function setPointer(at: { x: number; y: number } | undefined) {
  pointer = at;
}

const describe = (element: Element) => {
  const id = element.id ? `#${element.id}` : "";
  const testId = element.getAttribute("data-testid");
  const className = (element.getAttribute("class") ?? "").trim().split(/\s+/)[0];
  return `${element.tagName.toLowerCase()}${id}${testId ? `[data-testid=${testId}]` : ""}${className ? `.${className}` : ""}`;
};

// In the runner's document: changing its size is a layout outside the page,
// after which the browser updates hover in every frame.
let layoutNudge: HTMLElement | undefined;

/** Lays out the runner's document, so the browser updates hover after it. */
export function nudgeLayout() {
  if (!layoutNudge?.isConnected) {
    layoutNudge = parent.document.createElement("div");
    layoutNudge.style.cssText =
      "position: fixed; left: -10px; top: -10px; width: 1px; height: 1px; pointer-events: none";
    parent.document.body.append(layoutNudge);
  }
  layoutNudge.style.width = layoutNudge.style.width === "1px" ? "2px" : "1px";
  layoutNudge.getBoundingClientRect();
}

// The element holding pointer capture, as the browser reports it: while one
// does, hover follows it and not what is under the pointer.
let captured: Element | undefined;
document.addEventListener(
  "gotpointercapture",
  (event) => (captured = event.composedPath()[0] as Element),
  true
);
document.addEventListener("lostpointercapture", () => (captured = undefined), true);

/** The element under the pointer, as the browser hit-tests: `elementFromPoint`
 * (which passes through `pointer-events: none`), into open shadow roots and
 * same-origin frames. */
function hitAt(at: { x: number; y: number }) {
  let x = at.x;
  let y = at.y;
  let hit = document.elementFromPoint(x, y);
  for (;;) {
    if (!hit) break;
    const shadow = hit.shadowRoot;
    if (shadow) {
      const inner = shadow.elementFromPoint(x, y);
      if (inner && inner !== hit) {
        hit = inner;
        continue;
      }
    }
    if (hit.tagName === "IFRAME") {
      const frame = hit as HTMLIFrameElement;
      const inner = frame.contentDocument;
      if (inner) {
        const box = frame.getBoundingClientRect();
        x -= box.left + frame.clientLeft;
        y -= box.top + frame.clientTop;
        const found = inner.elementFromPoint(x, y);
        if (found) {
          hit = found;
          continue;
        }
      }
    }
    break;
  }
  return hit;
}

/**
 * The elements hover must cover: the captured element or the one under the
 * pointer, every ancestor up to the test page's document, crossing a shadow
 * root to its host and a frame to its element, and the control of each label
 * among them. Also the roots whose `:hover` matches are compared.
 */
function hitChain(at: { x: number; y: number }) {
  const roots = new Set<Document | ShadowRoot>([document]);
  const chain = new Set<Element>();
  const start = captured?.isConnected ? captured : hitAt(at);
  for (let node: Element | null = start; node; ) {
    chain.add(node);
    const control = node.tagName === "LABEL" && (node as HTMLLabelElement).control;
    if (control) chain.add(control);
    if (node.parentElement) {
      node = node.parentElement;
      continue;
    }
    // Up through shadow hosts and the page's own nested frames, not out of
    // the test's page.
    const root = node.getRootNode() as Document | ShadowRoot;
    roots.add(root);
    node =
      "host" in root
        ? root.host
        : root === document
          ? null
          : ((root as Document).defaultView?.frameElement ?? null);
  }
  return { chain, roots };
}

/** Whether the browser's hover is what hit-testing at the pointer says. */
export function hoverState() {
  if (!pointer) return { settled: true, at: "outside", expected: [], actual: [] };
  const { chain, roots } = hitChain(pointer);
  const hovered = new Set<Element>();
  for (const root of roots)
    for (const element of root.querySelectorAll(":hover")) hovered.add(element);
  const settled =
    hovered.size === chain.size && [...chain].every((element) => hovered.has(element));
  return {
    settled,
    at: `(${pointer.x}, ${pointer.y})${captured?.isConnected ? `, captured by ${describe(captured)}` : ""}`,
    expected: [...chain].map(describe),
    actual: [...hovered].map(describe),
  };
}
