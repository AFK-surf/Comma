import { getNativeBridge } from "@comma/native-bridge";
import { useSyncExternalStore } from "react";
import type { ChatSidebarScreenPage } from "../chat-sidebar/ChatSidebarContext";

/**
 * Screens shown in windows of their own. A window is a child of this page (`window.open` of a blank document of its
 * origin): this page renders the screen into it, so the screen keeps this page's stream, connection and decoder, and no
 * other copy of the app starts. Main lets only these names open (`screenWindowName`).
 *
 * One window a screen (a side panel page's id): opening a screen that has one brings that window forward. Closing the
 * window gives the screen back to its tab.
 */
export type ScreenWindow = {
  id: string;
  /** Its `window.open` name: Main knows the window by it. */
  name: string;
  page: ChatSidebarScreenPage;
  /** The window's document's root, where the screen renders. */
  root: HTMLElement;
  view: Window;
};

/** The child window names Main opens as screen windows. */
export const SCREEN_WINDOW_NAME_PREFIX = "comma-screen:";

/** How long a screen window's picture is on its long side, where it opens as a new one: a comfortable size. */
const LONG_SIDE = 960;
/** The picture's shape where it has none yet (a 16:10 display). */
const DEFAULT_RATIO = 16 / 10;

/**
 * A new screen window's content size: its picture, of this width over height, `LONG_SIDE` on its long side, under the
 * page's `toolbar` (its height). Main fits it to the display and centres it there (screen-windows.ts).
 */
export function screenWindowSize(ratio: number | undefined, toolbar: number) {
  const shape = ratio && Number.isFinite(ratio) && ratio > 0 ? ratio : DEFAULT_RATIO;
  const width = shape >= 1 ? LONG_SIDE : LONG_SIDE * shape;
  const height = shape >= 1 ? LONG_SIDE / shape : LONG_SIDE;
  return { width: Math.round(width), height: Math.round(height + toolbar) };
}

/**
 * The screen's key in its window's name: Main keeps the place of each screen's window by it. (FNV-1a of the page's id:
 * short, and no names of the person's apps in Main's file.)
 */
export function screenWindowKey(id: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < id.length; index += 1) {
    hash ^= id.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(36);
}

const windows = new Map<string, ScreenWindow>();
let shown: readonly ScreenWindow[] = [];
const listeners = new Set<() => void>();

function changed() {
  shown = [...windows.values()];
  for (const listener of listeners) listener();
}

/**
 * Shows the page's screen in a window of its own, or brings forward the window it has. `from` is the page it leaves
 * (its picture's shape and its toolbar size the new window). Returns whether a window shows it (a browser may refuse
 * the window).
 */
export function openScreenWindow(
  page: ChatSidebarScreenPage,
  { from, opener = window }: { from?: Element | null | undefined; opener?: Window } = {}
): boolean {
  if (focusScreenWindow(page.id)) return true;
  const picture = from?.querySelector("video");
  const size = screenWindowSize(
    picture?.videoHeight ? picture.videoWidth / picture.videoHeight : undefined,
    from?.querySelector("header")?.getBoundingClientRect().height ?? 0
  );
  const features = ["popup", `width=${size.width}`, `height=${size.height}`].join(",");
  // (one name a window, across the app's windows: Main brings it forward by it)
  const name = `${SCREEN_WINDOW_NAME_PREFIX}${crypto.randomUUID()}:${screenWindowKey(page.id)}`;
  const view = opener.open("about:blank", name, features);
  if (!view) return false;
  const document = view.document;
  const stopStyles = mirrorStyles(opener.document, document);
  document.body.replaceChildren();
  const root = document.createElement("div");
  root.className = "comma-remote-screen-window";
  document.body.append(root);
  const entry: ScreenWindow = { id: page.id, name, page, root, view };
  // Closed (by the person, or as this page goes): the screen goes back to its tab.
  view.addEventListener("pagehide", () => {
    stopStyles();
    if (windows.get(page.id) !== entry) return;
    windows.delete(page.id);
    changed();
  });
  windows.set(page.id, entry);
  changed();
  return true;
}

/**
 * Brings the screen's window forward. Returns whether it has one. A browser raises it for the page's `focus()`; the
 * desktop app does not, and Main raises it (`windows.focusScreen`).
 */
export function focusScreenWindow(id: string): boolean {
  const entry = windows.get(id);
  if (!entry) return false;
  if (entry.view.closed) {
    windows.delete(id);
    changed();
    return false;
  }
  entry.view.focus();
  const bridge = getNativeBridge();
  if (bridge.platform === "electron")
    void bridge.windows.focusScreen({ name: entry.name }).catch(() => undefined);
  return true;
}

/**
 * The screens in Control, by their side panel page's id, while a place shows them. A screen that moves (to its own
 * window, or back to its tab) starts in its new place as it was in the old one: the new place renders, and reads this,
 * before the old one's cleanup in the same commit. Once no place shows it, it is gone: a screen shown again later
 * starts in Watch.
 */
const inControl = new Set<string>();

/** Whether the screen of this page was in Control where it last showed. */
export function screenInControl(id: string): boolean {
  return inControl.has(id);
}

/** Keeps whether the screen of this page is in Control, while its place shows it. Returns that place's cleanup. */
export function keepScreenControl(id: string, control: boolean): () => void {
  if (control) inControl.add(id);
  else inControl.delete(id);
  return () => void inControl.delete(id);
}

/** Closes the screen's window: the screen goes back to its tab. */
export function closeScreenWindow(id: string) {
  const entry = windows.get(id);
  if (!entry) return;
  windows.delete(id);
  changed();
  entry.view.close();
}

/** Closes every screen window: the page that renders them goes. */
export function closeScreenWindows() {
  for (const id of windows.keys()) closeScreenWindow(id);
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/** The screens shown in windows of their own now. */
export function useScreenWindows(): readonly ScreenWindow[] {
  return useSyncExternalStore(subscribe, () => shown);
}

/** Whether this side panel page's screen shows in a window of its own now. */
export function useInScreenWindow(id: string): boolean {
  return useSyncExternalStore(subscribe, () => windows.has(id));
}

/**
 * The window an element is in. A screen in a window of its own runs from the app's page: what watches its elements or
 * waits for its frames is that window's, which paints while the app's window is hidden.
 */
export function viewOf(element: Element): Window & typeof globalThis {
  return (element.ownerDocument.defaultView ?? window) as Window & typeof globalThis;
}

/**
 * Gives `to` the look of `from`: its style sheets and its root's classes and attributes (theme, language), as they
 * change (a theme switch, a style sheet a lazy page brings). Returns a stop.
 */
export function mirrorStyles(from: Document, to: Document): () => void {
  const copies = new Map<Node, Node>();
  const isSheet = (node: Node): node is HTMLStyleElement | HTMLLinkElement =>
    node instanceof from.defaultView!.HTMLStyleElement ||
    (node instanceof from.defaultView!.HTMLLinkElement && node.rel === "stylesheet");
  const copy = (node: Node) => {
    if (!isSheet(node) || copies.has(node)) return;
    const clone = to.importNode(node, true) as HTMLElement;
    // (a link's address as the page resolved it: the blank document resolves none of its own)
    if (clone instanceof to.defaultView!.HTMLLinkElement)
      clone.href = (node as HTMLLinkElement).href;
    copies.set(node, clone);
    to.head.append(clone);
  };
  const root = () => {
    const into = to.documentElement;
    for (const name of into.getAttributeNames())
      if (!from.documentElement.hasAttribute(name)) into.removeAttribute(name);
    for (const name of from.documentElement.getAttributeNames())
      into.setAttribute(name, from.documentElement.getAttribute(name) ?? "");
    to.body.className = from.body.className;
  };
  for (const node of from.head.childNodes) copy(node);
  root();
  const watch = new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "attributes") {
        root();
        continue;
      }
      const target =
        record.type === "characterData" ? record.target.parentNode : record.target;
      if (target === from.head) {
        for (const node of record.addedNodes) copy(node);
        for (const node of record.removedNodes) {
          (copies.get(node) as ChildNode | undefined)?.remove();
          copies.delete(node);
        }
      } else if (target) {
        // (a style element's text changed in place: a style sheet's hot reload)
        const clone = copies.get(target);
        if (clone) clone.textContent = target.textContent;
      }
    }
  });
  watch.observe(from.head, { childList: true, subtree: true, characterData: true });
  watch.observe(from.documentElement, { attributes: true });
  watch.observe(from.body, { attributes: true, attributeFilter: ["class"] });
  return () => watch.disconnect();
}
