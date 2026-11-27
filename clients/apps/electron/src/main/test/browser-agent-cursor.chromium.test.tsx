import { afterEach, describe, expect, it, vi } from "vitest";
import cursorScript from "../modules/browser-sidebar/agent/cursor.js?raw";
import pageScript from "../modules/browser-sidebar/agent/page.js?raw";

// The cursor is drawn over the page, so it runs in a real browser engine.
const AGENT = "__commaAgent";
const CURSOR = "__commaAgentCursor";
const pageGlobal = globalThis as unknown as Record<string, unknown>;

interface Point {
  x: number;
  y: number;
}

interface Cursor {
  activate(holdMs?: number, at?: Point | null): Point;
  moveTo(
    x: number,
    y: number,
    options?: { animate?: boolean; press?: boolean }
  ): Promise<Point>;
}

// The overlay's shadow root is closed: a test that looks inside keeps the one it opens.
function keepShadowRoot() {
  let root: ShadowRoot | undefined;
  const attachShadow = Element.prototype.attachShadow;
  vi.spyOn(Element.prototype, "attachShadow").mockImplementation(function (
    this: Element,
    init: ShadowRootInit
  ) {
    root = attachShadow.call(this, init);
    return root;
  });
  return () => root!;
}

// Whether the system asks for less motion, as the page's matchMedia answers it.
function lessMotion(initial: boolean) {
  let reduced = initial;
  vi.spyOn(window, "matchMedia").mockImplementation(
    (query: string) =>
      ({
        matches: reduced && query.includes("prefers-reduced-motion: reduce"),
        media: query,
      }) as MediaQueryList
  );
  return (next: boolean) => {
    reduced = next;
  };
}

function load() {
  // oxlint-disable-next-line no-new-func -- The scripts are page scripts, evaluated as the driver does.
  new Function(pageScript)();
  // oxlint-disable-next-line no-new-func -- As above.
  new Function(cursorScript)();
  return {
    cursor: pageGlobal[CURSOR] as Cursor,
    snapshot: () =>
      (
        pageGlobal[AGENT] as { snapshot(o: { scope: string }): { text: string } }
      ).snapshot({
        scope: "full",
      }).text,
  };
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  document.body.replaceChildren();
  for (const el of document.querySelectorAll("comma-agent-cursor")) el.remove();
  delete pageGlobal[AGENT];
  delete pageGlobal[CURSOR];
});

describe("in-app browser agent cursor", () => {
  it("draws its edge and cursor over the page without taking its clicks or entering the agent's snapshot", async () => {
    document.body.innerHTML = `<button style="position: fixed; left: 20px; top: 20px; width: 80px; height: 40px">Save</button>`;
    const { cursor, snapshot } = load();
    const before = snapshot();

    cursor.activate();
    await cursor.moveTo(50, 40, { animate: false, press: true });

    const host = document.querySelector("comma-agent-cursor")!;
    expect(host.getAttribute("aria-hidden")).toBe("true");
    // A closed shadow root: page scripts see an empty element.
    expect(host.shadowRoot).toBeNull();
    expect(document.elementFromPoint(50, 40)?.textContent).toBe("Save");
    expect(snapshot()).toBe(before);
  });

  it("shows its cursor for as long as the agent works on the page, also before it points anywhere", () => {
    vi.useFakeTimers();
    const root = keepShadowRoot();
    const { cursor } = load();
    const pointer = () => root().querySelector("svg")!.parentElement!;

    cursor.activate(1_000);
    expect(pointer().style.opacity).toBe("1");

    vi.advanceTimersByTime(1_000);
    expect(pointer().style.opacity).toBe("0");
  });

  it("shows its edge without turning it while the system asks for less motion", () => {
    lessMotion(true);
    const root = keepShadowRoot();
    const { cursor } = load();

    cursor.activate();

    const edge = root().firstElementChild as HTMLElement;
    expect(edge.style.opacity).toBe("1");
    const turns = edge
      .getAnimations({ subtree: true })
      .filter((animation) => animation.effect?.getTiming().iterations === Infinity);
    expect(turns).toHaveLength(2);
    for (const turn of turns) expect(turn.playState).toBe("paused");
  });

  it("stops turning its edge when less motion is asked while the agent works", () => {
    const askLessMotion = lessMotion(false);
    const root = keepShadowRoot();
    const { cursor } = load();
    const edge = () => root().firstElementChild as HTMLElement;
    const turns = () =>
      edge()
        .getAnimations({ subtree: true })
        .filter((animation) => animation.effect?.getTiming().iterations === Infinity);

    cursor.activate();
    expect(turns()).toHaveLength(2);
    for (const turn of turns()) expect(turn.playState).toBe("running");

    askLessMotion(true);
    cursor.activate();

    expect(edge().style.opacity).toBe("1");
    for (const turn of turns()) expect(turn.playState).toBe("paused");
  });

  it("glides in from the corner as the agent starts on the tab, and starts a new page where the last one left it", () => {
    let { cursor } = load();
    // The tab's first page: docked bottom-left, then into the page's centre.
    expect(cursor.activate()).toEqual({ x: innerWidth / 2, y: innerHeight / 2 });

    // A new document has a new world: its cursor starts where Main says.
    for (const el of document.querySelectorAll("comma-agent-cursor")) el.remove();
    delete pageGlobal[CURSOR];
    ({ cursor } = load());
    expect(cursor.activate(undefined, { x: 120, y: 80 })).toEqual({ x: 120, y: 80 });
  });
});
