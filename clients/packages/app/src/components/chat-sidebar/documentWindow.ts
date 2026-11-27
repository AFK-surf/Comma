import { getNativeBridge } from "@comma/native-bridge";
import type { ConversationFileSource } from "../../runtime-files/fileSources";

/**
 * A document shown as the whole of its own window: the workspace it is read in, and the document. A document is its
 * conversation and file name, as its tab is, whichever of its versions is shown: so the window a document has is
 * found again after a new version arrives or the reader goes to another one.
 */
export type DocumentWindowTarget = {
  workspaceId: string;
  groupId: string;
  conversationId: string;
  fileName: string;
};

/** The document a version is of, as the window that shows it is named. */
export const documentWindowOf = (
  workspaceId: string,
  source: Pick<ConversationFileSource, "groupId" | "conversationId" | "fileName">
): DocumentWindowTarget => ({
  workspaceId,
  groupId: source.groupId,
  conversationId: source.conversationId,
  fileName: source.fileName,
});

/**
 * The hash route that shows a document as the whole of its own window (`DocumentWindowRoute`), outside Comma's
 * shell. It names the document and no version of it: the window shows the newest, and goes to the others from the
 * document's name.
 */
export function documentWindowRoute(target: DocumentWindowTarget) {
  const search = new URLSearchParams({
    w: target.workspaceId,
    g: target.groupId,
    c: target.conversationId,
    n: target.fileName,
  });
  return `/documents/window?${search}`;
}

const searchKeys = ["w", "g", "c", "n"] as const;
export type DocumentWindowSearch = Partial<Record<(typeof searchKeys)[number], string>>;

/** The route's search as its own keys, each as text: the router reads a value that looks like a number as one. */
export function documentWindowSearch(
  search: Record<string, unknown>
): DocumentWindowSearch {
  const out: DocumentWindowSearch = {};
  for (const key of searchKeys) {
    const value = search[key];
    if (typeof value === "string" || typeof value === "number")
      out[key] = String(value);
  }
  return out;
}

/** The route's search as the document it names; undefined where a part is missing. */
export function documentWindowTarget(
  search: DocumentWindowSearch
): DocumentWindowTarget | undefined {
  const { w, g, c, n } = search;
  return w && g && c && n
    ? { workspaceId: w, groupId: g, conversationId: c, fileName: n }
    : undefined;
}

/**
 * The version a document's window shows. It is the document's newest. A version the reader chose in the window is
 * shown instead until another version arrives: `chosen.among` is how many versions there were when they chose.
 */
export function documentWindowVersion<Version>(
  versions: readonly Version[],
  chosen: { version: Version; among: number } | undefined
) {
  return chosen?.among === versions.length ? chosen.version : versions.at(-1);
}

/** A document window's size where it has no panel to take the place of: a page's width, most of a screen's height. */
const WINDOW_WIDTH = 760;
const WINDOW_HEIGHT = 900;

/**
 * Shows the document in a window of its own (desktop), over the panel it leaves (`from`), or brings forward the
 * window it has. Resolves with whether a window shows it.
 */
export async function openDocumentWindow(
  target: DocumentWindowTarget,
  from?: Element | null
): Promise<boolean> {
  const bridge = getNativeBridge();
  if (bridge.platform !== "electron") return false;
  const route = documentWindowRoute(target);
  const open = await bridge.surfaces.state().then(
    ({ windows }) => windows.find((shown) => shown.route === route),
    () => undefined
  );
  if (open)
    return bridge.windows.focus({ windowId: open.id }).then(
      () => true,
      () => false
    );
  const rect = from?.getBoundingClientRect();
  const place =
    rect && rect.width > 0 && rect.height > 0
      ? rect
      : {
          left: (window.innerWidth - WINDOW_WIDTH) / 2,
          top: (window.innerHeight - WINDOW_HEIGHT) / 2,
          width: WINDOW_WIDTH,
          height: Math.min(WINDOW_HEIGHT, window.innerHeight),
        };
  return bridge.windows
    .create({
      route,
      bounds: {
        x: Math.round(window.screenX + place.left),
        y: Math.round(window.screenY + Math.max(0, place.top)),
        width: Math.round(place.width),
        height: Math.round(place.height),
      },
    })
    .then(
      () => true,
      () => false
    );
}
