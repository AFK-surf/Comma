export type CommaNavTraceEvent = {
  at: string;
  t: number;
  type: string;
  [key: string]: unknown;
};

type CommaNavTraceApi = {
  clear: () => void;
  dump: () => CommaNavTraceEvent[];
  events: CommaNavTraceEvent[];
  report: () => CommaNavTraceReport;
};

type CommaNavTraceReport = {
  elapsedMs: number;
  events: CommaNavTraceEvent[];
  homeLifecycle: CommaNavTraceEvent[];
  imageBursts: CommaNavTraceEvent[];
  longtaskCount: number;
  longtaskMs: number;
  origin: CommaNavTraceEvent | undefined;
  workspaceResolves: CommaNavTraceEvent[];
};

const MAX_EVENTS = 500;
const TRACE_WINDOW_MS = 15_000;
const CONSOLE_SIGNAL_TYPES = new Set([
  "home-mount",
  "home-unmount",
  "longtask",
  "workspace-chat-resolve-end",
  "workspace-chat-resolve-start",
]);

const events: CommaNavTraceEvent[] = [];
let installed = false;

function isCommaNavTraceEnabled() {
  return import.meta.env.DEV === true && import.meta.env.MODE !== "test";
}

export function traceCommaNav(type: string, data: Record<string, unknown> = {}) {
  if (!isCommaNavTraceEnabled()) return;
  const event: CommaNavTraceEvent = {
    at: new Date().toISOString(),
    t: Math.round(performance.now()),
    type,
    ...data,
  };
  events.push(event);
  if (events.length > MAX_EVENTS) events.shift();
  if (CONSOLE_SIGNAL_TYPES.has(type)) {
    console.warn("COMMA_NAV_TRACE", JSON.stringify(event));
  }
}

export function snapshotHomeDom() {
  if (typeof document === "undefined") {
    return { hash: "", homeHidden: null, homePresent: false, paused: false };
  }
  const home = document.querySelector("[data-testid='home-responsive-layout']");
  return {
    hash: window.location.hash,
    homeHidden: home instanceof HTMLElement ? !isVisible(home) : null,
    homePresent: home instanceof HTMLElement,
    paused: Boolean(document.querySelector("[data-comma-surface-paused='true']")),
  };
}

function isVisible(element: HTMLElement) {
  if (typeof element.checkVisibility === "function") {
    return element.checkVisibility({ checkVisibilityCSS: true });
  }
  const style = window.getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
}

function describeClick(event: MouseEvent) {
  const target = event.target;
  if (!(target instanceof Element)) {
    return { tag: "unknown" };
  }
  const host =
    target.closest(
      "a, button, [role='button'], [role='link'], [role='menuitem'], [role='option']"
    ) ?? target;
  const text = (host.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 80);
  return {
    aria: host.getAttribute("aria-label") ?? undefined,
    href: host.getAttribute("href") ?? undefined,
    tag: host.tagName.toLowerCase(),
    testId:
      host.getAttribute("data-testid") ??
      host.closest("[data-testid]")?.getAttribute("data-testid") ??
      undefined,
    text: text || undefined,
  };
}

function isCommaAssistantClick(event: CommaNavTraceEvent) {
  const haystack = `${event.aria ?? ""} ${event.text ?? ""}`.toLowerCase();
  return (
    haystack.includes("comma assistant") ||
    haystack.includes("back to app") ||
    haystack.includes("助手")
  );
}

function report(): CommaNavTraceReport {
  const newestFirst = events.toReversed();
  const origin =
    newestFirst.find(
      (event) => event.type === "click" && isCommaAssistantClick(event)
    ) ?? newestFirst.find((event) => event.type === "click");
  const windowEvents = origin
    ? events.filter(
        (event) => event.t >= origin.t && event.t <= origin.t + TRACE_WINDOW_MS
      )
    : events.slice(-80);
  const longtasks = windowEvents.filter((event) => event.type === "longtask");
  return {
    elapsedMs:
      origin && windowEvents.length > 0 ? Number(windowEvents.at(-1)?.t) - origin.t : 0,
    events: windowEvents,
    homeLifecycle: windowEvents.filter(
      (event) => event.type === "home-mount" || event.type === "home-unmount"
    ),
    imageBursts: windowEvents.filter((event) => event.type === "image-burst-end"),
    longtaskCount: longtasks.length,
    longtaskMs: longtasks.reduce((sum, event) => sum + Number(event.duration ?? 0), 0),
    origin,
    workspaceResolves: windowEvents.filter(
      (event) => event.type === "workspace-chat-resolve-end"
    ),
  };
}

function exposeApi() {
  const api: CommaNavTraceApi = {
    clear: () => {
      events.length = 0;
    },
    dump: () => [...events],
    events,
    report,
  };
  // eslint-disable-next-line no-underscore-dangle -- dev-only window inspect handle
  window.__COMMA_NAV_TRACE = api;
}

export function installCommaNavTrace() {
  if (!isCommaNavTraceEnabled() || installed || typeof window === "undefined") {
    return () => {};
  }
  installed = true;
  exposeApi();

  const onClick = (event: MouseEvent) => {
    traceCommaNav("click", { ...describeClick(event), ...snapshotHomeDom() });
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (!(event.altKey && event.shiftKey && event.code === "KeyD")) return;
    event.preventDefault();
    console.warn("COMMA_NAV_TRACE_REPORT", JSON.stringify(report()));
  };

  window.addEventListener("click", onClick, true);
  window.addEventListener("keydown", onKeyDown);

  const observers: PerformanceObserver[] = [];
  try {
    if (PerformanceObserver.supportedEntryTypes.includes("longtask")) {
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.duration < 50) continue;
          traceCommaNav("longtask", {
            duration: Math.round(entry.duration),
            start: Math.round(entry.startTime),
          });
        }
      });
      observer.observe({ type: "longtask", buffered: true });
      observers.push(observer);
    }
  } catch {
    // Click + route events still diagnose the hang without longtask support.
  }

  traceCommaNav("trace-ready", snapshotHomeDom());
  console.warn(
    "COMMA_NAV_TRACE ready. Reproduce the Comma assistant hang, then Alt+Shift+D or copy(JSON.stringify(window.__COMMA_NAV_TRACE.report(), null, 2))"
  );

  return () => {
    window.removeEventListener("click", onClick, true);
    window.removeEventListener("keydown", onKeyDown);
    for (const observer of observers) observer.disconnect();
    installed = false;
  };
}

declare global {
  interface Window {
    __COMMA_NAV_TRACE?: CommaNavTraceApi;
  }
}
