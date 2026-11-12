import {
  createContext,
  createElement,
  useCallback,
  useContext,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import { MAX_ATTACHMENTS_PER_MESSAGE, sharedScreenLine } from "@comma/core/chat";
import type { BrowserSidebarInspectedElement } from "@comma/native-bridge";

/**
 * Something a person selected to ask about, staged for the next message as one tile: an element picked on a page of
 * the browser sidebar, or an area (or the whole) of a screen. Like quotes and snippets, selections are renderer-only
 * draft state, kept per conversation for the chat session the way its draft is. At send time each one's note and what
 * the agent reads about it are folded into the message's text, and its picture goes as a file of the message.
 */
export type ChatDraftSelection = {
  id: string;
  /** What the person wrote about it. */
  note: string;
  /** Its picture, as the message's file. None for an element that was not on screen. */
  picture?: { bytes: Uint8Array; type: SelectionPictureType } | undefined;
  /** The picture as its tile shows it: a URL that needs no release (a `data:` URL). */
  thumbnail?: string | undefined;
  about: ChatDraftSelectionSubject;
};

export type ChatDraftSelectionSubject =
  | {
      kind: "element";
      /** The pick's id (`BrowserSidebarInspectResult.inspectionId`). */
      inspectionId: string;
      page: { title?: string | undefined; url: string };
      element: BrowserSidebarInspectedElement;
    }
  | {
      kind: "screen";
      /** The computer's device id, and the screen's id (`display`, `android:<serial>`, `simulator:<udid>`). */
      device: string;
      screen: string;
      name?: string | undefined;
      /** When its frame was held (ms). */
      at: number;
      /** Files that go with it, such as the app's recent logs. */
      files?: readonly SelectionFile[] | undefined;
    };

export type SelectionPictureType = "image/png" | "image/jpeg" | "image/webp";
type SelectionFile = { bytes: Uint8Array; name: string; size: number };

/** A conversation's staged selections, shared by every surface that shows it. */
export interface ComposerDraftSelections {
  items: readonly ChatDraftSelection[];
  setItems: Dispatch<SetStateAction<readonly ChatDraftSelection[]>>;
}

const maxNoteLength = 4_000;
const maxElementTextLength = 2_000;
const maxHtmlLength = 4_000;
// With several elements each gets its share of the text and HTML one would have, and no less than this.
const minElementShare = 400;
const EXTENSIONS: Record<SelectionPictureType, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
};

let selectionSequence = 0;

export function createChatDraftSelection(
  selection: Omit<ChatDraftSelection, "id">
): ChatDraftSelection {
  selectionSequence += 1;
  return { ...selection, id: `selection-${selectionSequence}` };
}

/** PNG bytes as a `data:` URL, for a tile: it needs no release when the selection goes. */
export function pictureDataUrl(bytes: Uint8Array, type: SelectionPictureType): string {
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return `data:${type};base64,${btoa(binary)}`;
}

/**
 * The name of selection `index`'s picture among `count`: an element's or a screen's own name where it is the only
 * one, numbered as its note is where there are several.
 */
function pictureName(selection: ChatDraftSelection, index: number, count: number) {
  const base = selection.about.kind === "element" ? "inspected-element" : "screen";
  const extension = EXTENSIONS[selection.picture?.type ?? "image/png"];
  return count === 1 ? `${base}.${extension}` : `${base}-${index + 1}.${extension}`;
}

/**
 * The message's text with the selections folded in: after the typed text come their notes (numbered where there are
 * several, as their pictures are), a line that names each screen by its link, and last, for the agent alone, what
 * the picked elements are on their pages.
 */
export function composeMessageWithSelections(
  text: string,
  selections: readonly ChatDraftSelection[]
) {
  if (selections.length === 0) return text;
  const count = selections.length;
  const notes = selections.map((selection) =>
    clipped(selection.note.trim(), maxNoteLength)
  );
  const said =
    count === 1
      ? notes[0]
      : notes.map((note, index) => `${index + 1}. ${note}`).join("\n");
  const screens = new Map<string, string>();
  for (const { about } of selections) {
    if (about.kind !== "screen") continue;
    const key = `${about.device}\n${about.screen}`;
    if (!screens.has(key)) screens.set(key, sharedScreenLine(about, about.at));
  }
  const elements = selections.flatMap((selection, index) =>
    selection.about.kind === "element"
      ? [{ index, selection, about: selection.about }]
      : []
  );
  const context =
    elements.length === 0
      ? undefined
      : [
          "<user-reminder>",
          `<browser-element-inspection id="${escapedAttribute(elements[0]!.about.inspectionId)}" />`,
          "<browser_element_context>",
          ...elements.flatMap(({ index, selection, about }, at) => [
            ...(at > 0 ? [""] : []),
            ...(count > 1 ? [`Selection ${index + 1} of ${count}`] : []),
            ...elementLines(
              about,
              selection.picture ? pictureName(selection, index, count) : undefined,
              elements.length
            ),
          ]),
          "</browser_element_context>",
          "</user-reminder>",
        ].join("\n");
  return [text.trim(), said, [...screens.values()].join("\n"), context]
    .filter((part) => part !== undefined && part !== "")
    .join("\n\n");
}

/** What the agent reads of one picked element. */
function elementLines(
  { page, element }: Extract<ChatDraftSelectionSubject, { kind: "element" }>,
  picture: string | undefined,
  count: number
) {
  const share = (limit: number) =>
    Math.max(Math.min(limit, minElementShare), Math.floor(limit / count));
  const lines: string[] = [];
  if (page.title?.trim()) lines.push(`Page title: ${page.title.trim()}`);
  lines.push(
    `Page URL: ${page.url}`,
    `Selector: ${element.selector}`,
    `Tag: ${element.tagName}`
  );

  const attributes = Object.entries(element.attributes)
    .toSorted(([left], [right]) => left.localeCompare(right))
    .map(([name, value]) => `${name}=${value}`)
    .join(", ");
  if (attributes) lines.push(`Attributes: ${attributes}`);

  const { rect } = element;
  lines.push(
    `Bounding rect: x=${rounded(rect.x)}, y=${rounded(rect.y)}, width=${rounded(rect.width)}, height=${rounded(rect.height)}`
  );
  if (picture) lines.push(`Screenshot: attached as ${picture}`);

  if (element.text?.trim()) {
    lines.push(
      "",
      "Element text:",
      clipped(element.text.trim(), share(maxElementTextLength))
    );
  }
  if (element.outerHTML?.trim()) {
    lines.push(
      "",
      "Element HTML excerpt:",
      "```html",
      clipped(element.outerHTML.trim(), share(maxHtmlLength)),
      "```"
    );
  }
  return lines;
}

/**
 * The selections' files, for the message that carries them: each one's picture, named as its note is numbered, then
 * what goes with the screens. A screen gives a file of a name once, the last it gave (its app's logs, as they stood at
 * its latest selection). Where several screens give a file of the same name, each is numbered as that selection is:
 * `app-logs-2.txt` goes with `screen-2.png`.
 *
 * All of them: a message takes `MAX_ATTACHMENTS_PER_MESSAGE` files with its composer's own, and what stages or sends
 * selections keeps to that (`selectionsFit`), so none is left out unsaid.
 */
export function selectionFiles(selections: readonly ChatDraftSelection[]) {
  const count = selections.length;
  const pictures = selections.flatMap((selection, index) =>
    selection.picture
      ? [
          {
            bytes: selection.picture.bytes,
            name: pictureName(selection, index, count),
            size: selection.picture.bytes.byteLength,
          },
        ]
      : []
  );
  const others = new Map<string, { file: SelectionFile; index: number }>();
  selections.forEach(({ about }, index) => {
    if (about.kind !== "screen") return;
    for (const file of about.files ?? [])
      others.set(`${about.device}\n${about.screen}\n${file.name}`, { file, index });
  });
  const givers = new Map<string, number>();
  for (const { file } of others.values())
    givers.set(file.name, (givers.get(file.name) ?? 0) + 1);
  return [
    ...pictures,
    ...[...others.values()].map(({ file, index }) =>
      (givers.get(file.name) ?? 0) > 1
        ? { ...file, name: numberedName(file.name, index + 1) }
        : file
    ),
  ];
}

/**
 * How many of a draft's attachments go with its message as files a message counts: those uploaded or uploading (the
 * core's `enqueueSend`). A file kept on this computer is not one of them.
 */
export function draftUploadCount(
  attachments: readonly { status: string; path?: string | undefined }[]
): number {
  return attachments.filter(
    (attachment) =>
      attachment.status === "uploading" ||
      (attachment.status === "uploaded" && Boolean(attachment.path))
  ).length;
}

/** `name` with `-number` before its extension. */
function numberedName(name: string, number: number) {
  const dot = name.lastIndexOf(".");
  return dot > 0
    ? `${name.slice(0, dot)}-${number}${name.slice(dot)}`
    : `${name}-${number}`;
}

/**
 * Whether one message takes these selections' files with `beside` others of its own (what its composer has
 * attached): together they are the message's files.
 */
export function selectionsFit(
  selections: readonly ChatDraftSelection[],
  beside: number
): boolean {
  return selectionFiles(selections).length + beside <= MAX_ATTACHMENTS_PER_MESSAGE;
}

function clipped(value: string, maxLength: number) {
  return value.length <= maxLength
    ? value
    : `${value.slice(0, maxLength)}\n...[truncated]`;
}

function escapedAttribute(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function rounded(value: number) {
  return String(Math.round(value * 10) / 10);
}

const NO_SELECTIONS: readonly ChatDraftSelection[] = [];

type DraftSelectionStore = {
  get(key: string): readonly ChatDraftSelection[];
  subscribe(listener: () => void): () => void;
  update(key: string, action: SetStateAction<readonly ChatDraftSelection[]>): void;
  /** How many files a conversation's next message has besides its selections: what a composer that shows it says. */
  beside(key: string): number;
  /** A composer that shows the conversation says how many files it has attached, until it goes. */
  sayBeside(key: string, count: () => number): () => void;
};

function createDraftSelectionStore(): DraftSelectionStore {
  const staged = new Map<string, readonly ChatDraftSelection[]>();
  const listeners = new Set<() => void>();
  const composers = new Map<string, Set<() => number>>();
  return {
    beside: (key) =>
      Math.max(0, ...[...(composers.get(key) ?? [])].map((count) => count())),
    sayBeside(key, count) {
      const saying = composers.get(key) ?? new Set();
      composers.set(key, saying.add(count));
      return () => {
        saying.delete(count);
        if (saying.size === 0) composers.delete(key);
      };
    },
    get: (key) => staged.get(key) ?? NO_SELECTIONS,
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    update(key, action) {
      const current = staged.get(key) ?? NO_SELECTIONS;
      const next = typeof action === "function" ? action(current) : action;
      if (next === current) return;
      if (next.length === 0) staged.delete(key);
      else staged.set(key, next);
      for (const listener of listeners) listener();
    },
  };
}

const DraftSelectionStoreContext = createContext<DraftSelectionStore | null>(null);

/**
 * Keeps staged selections by conversation for one chat session. It stands above all of the session's surfaces: the
 * browser sidebar and a screen stage into the composer of a conversation that shows in another part of the window.
 * `scope`: the session they belong to; another one starts with none.
 */
export function DraftSelectionsProvider({
  children,
  scope,
}: {
  children: ReactNode;
  scope?: unknown;
}) {
  const [held, setHeld] = useState(() => ({
    scope,
    store: createDraftSelectionStore(),
  }));
  const current =
    held.scope === scope ? held : { scope, store: createDraftSelectionStore() };
  if (current !== held) setHeld(current);
  return createElement(
    DraftSelectionStoreContext.Provider,
    { value: current.store },
    children
  );
}

/**
 * The selections staged for `conversationId`. A conversation without an id yet, or a render without
 * `DraftSelectionsProvider`, keeps them for the caller only.
 */
export function useConversationDraftSelections(
  conversationId: string | undefined
): ComposerDraftSelections {
  const shared = useContext(DraftSelectionStoreContext);
  const [own] = useState(createDraftSelectionStore);
  const unsaved = useId();
  const store = conversationId === undefined ? own : (shared ?? own);
  const key = conversationId ?? unsaved;
  const read = useCallback(() => store.get(key), [key, store]);
  const items = useSyncExternalStore(store.subscribe, read, read);
  const setItems = useCallback<Dispatch<SetStateAction<readonly ChatDraftSelection[]>>>(
    (action) => store.update(key, action),
    [key, store]
  );
  return useMemo(() => ({ items, setItems }), [items, setItems]);
}

/**
 * Stages a selection for a conversation's next message, from a surface beside it (the browser sidebar, a screen):
 * the conversation's composer then shows its tile. It answers false where the message has no room for its files:
 * they count with the files the conversation's composer has attached. Undefined where no chat session keeps
 * selections.
 */
export function useStageDraftSelection():
  | ((conversationId: string, selection: Omit<ChatDraftSelection, "id">) => boolean)
  | undefined {
  const store = useContext(DraftSelectionStoreContext);
  return useMemo(
    () =>
      store
        ? (conversationId, selection) => {
            const staged = createChatDraftSelection(selection);
            const next = [...store.get(conversationId), staged];
            if (!selectionsFit(next, store.beside(conversationId))) return false;
            store.update(conversationId, () => next);
            return true;
          }
        : undefined,
    [store]
  );
}

/**
 * A conversation's composer says how many files it has attached of its own, so a selection staged from beside it
 * counts with them. `count` is read as a selection is staged.
 */
export function useSayFilesBesideSelections(
  conversationId: string | undefined,
  count: () => number
) {
  const store = useContext(DraftSelectionStoreContext);
  const latest = useRef(count);
  useEffect(() => {
    latest.current = count;
  });
  useEffect(() => {
    if (!store || conversationId === undefined) return undefined;
    return store.sayBeside(conversationId, () => latest.current());
  }, [conversationId, store]);
}
