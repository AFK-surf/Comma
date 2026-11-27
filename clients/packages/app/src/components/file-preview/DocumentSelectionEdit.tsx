// Asking Comma for a change to a passage of a document. The reader selects text in the page and takes "Change this
// passage" from the toolbar over the selection: a small window by the selection shows the passage and takes what to
// change. Adding it stages the passage with the chat's next message (it shows as a tile over the chat's composer, and
// is sent from there); the passage stays marked in the page while it is staged, so a reader sees every change they
// have asked for where it applies.
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { useEffect, useRef, useState } from "react";

/** A passage of the document's text: where it is in the page's text, and its words. */
export type DocumentPassage = { start: number; end: number; quote: string };

/** What tells a passage apart in the document: the text around it and the heading it is under. */
export type DocumentPassagePlace = DocumentPassage & {
  before: string;
  after: string;
  heading?: string | undefined;
};

/** What a reader asks of a passage: what to change. */
export type DocumentEdit = DocumentPassagePlace & { note: string };

/**
 * Asking Comma to change passages: the ones staged with the chat's next message, and how one more is staged (false
 * when the message can take no more).
 */
export type DocumentPassages = {
  staged: readonly (DocumentPassage & { id: string })[];
  onAdd: (edit: DocumentEdit) => boolean;
};

const maxQuoteLength = 4_000;
const aroundLength = 80;

/** `[start, end)` of the text of `root`, as a DOM range. */
function rangeAt(root: HTMLElement, start: number, end: number) {
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const range = root.ownerDocument.createRange();
  let offset = 0;
  let started = false;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.textContent?.length ?? 0;
    if (!started && start < offset + length) {
      range.setStart(node, start - offset);
      started = true;
    }
    if (started && end <= offset + length) {
      range.setEnd(node, end - offset);
      return range;
    }
    offset += length;
  }
  return undefined;
}

/** The heading the passage is under: the last heading of the page before the block it starts in. */
function headingBefore(root: HTMLElement, start: Node) {
  let block = start instanceof Element ? start : start.parentElement;
  while (block && block.parentElement !== root) block = block.parentElement;
  for (; block; block = block.previousElementSibling)
    if (/^H[1-6]$/u.test(block.tagName)) return block.textContent?.trim() || undefined;
  return undefined;
}

/**
 * The reader's selection in `root` as a passage, with where a window about it goes (under its last line, from where
 * it starts, from `root`'s own corner). Undefined where nothing of `root` is selected, or too much to ask about.
 */
export function selectedPassage(root: HTMLElement) {
  const selected = root.ownerDocument.getSelection();
  if (!selected || selected.isCollapsed || !selected.rangeCount) return undefined;
  const range = selected.getRangeAt(0);
  const quote = range.toString();
  if (
    !root.contains(range.startContainer) ||
    !root.contains(range.endContainer) ||
    !quote.trim() ||
    quote.length > maxQuoteLength
  )
    return undefined;
  const prefix = range.cloneRange();
  prefix.selectNodeContents(root);
  prefix.setEnd(range.startContainer, range.startOffset);
  const start = prefix.toString().length;
  const text = root.textContent ?? "";
  const lines = Array.from(range.getClientRects());
  const last = lines.at(-1) ?? range.getBoundingClientRect();
  const first = lines[0] ?? last;
  const bounds = root.getBoundingClientRect();
  const passage: DocumentPassagePlace = {
    start,
    end: start + quote.length,
    quote,
    before: text.slice(Math.max(0, start - aroundLength), start),
    after: text.slice(start + quote.length, start + quote.length + aroundLength),
    heading: headingBefore(root, range.startContainer),
  };
  return { passage, top: last.bottom - bounds.top, left: first.left - bounds.left };
}

type Rect = { key: string; left: number; top: number; width: number; height: number };

/**
 * Where `passages` are drawn in `root`, from its own corner, kept current as the page changes. A passage the page no
 * longer holds at its place has no mark.
 */
export function usePassageMarks(
  root: HTMLElement | null,
  passages: readonly (DocumentPassage & { id: string })[]
) {
  const [rects, setRects] = useState<Rect[]>([]);
  useEffect(() => {
    if (!root || passages.length === 0) {
      setRects((current) => (current.length ? [] : current));
      return undefined;
    }
    const measure = () => {
      const bounds = root.getBoundingClientRect();
      const text = root.textContent ?? "";
      setRects(
        passages.flatMap((passage) => {
          if (text.slice(passage.start, passage.end) !== passage.quote) return [];
          const range = rangeAt(root, passage.start, passage.end);
          return range
            ? Array.from(range.getClientRects(), (rect) => ({
                key: passage.id,
                left: rect.left - bounds.left,
                top: rect.top - bounds.top,
                width: rect.width,
                height: rect.height,
              }))
            : [];
        })
      );
    };
    const resized = new ResizeObserver(measure);
    const changed = new MutationObserver(measure);
    resized.observe(root);
    changed.observe(root, { characterData: true, childList: true, subtree: true });
    measure();
    return () => {
      resized.disconnect();
      changed.disconnect();
    };
  }, [passages, root]);
  return rects;
}

/** The marks of the passages asked about, over the page's own text. */
export function DocumentPassageMarks({ rects }: { rects: readonly Rect[] }) {
  return (
    <div aria-hidden="true" className="comma-document-edit-marks">
      {rects.map((rect, index) => (
        <span
          // oxlint-disable-next-line react/no-array-index-key
          key={`${rect.key}:${index}`}
          className="comma-document-edit-mark"
          style={{
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
          }}
        />
      ))}
    </div>
  );
}

/**
 * The window that asks for a change to a passage: the passage, a field for what to change, and Add to chat. Enter
 * or ⌘L adds it, Escape or a press elsewhere closes it.
 */
export function DocumentPassageWindow({
  passage,
  top,
  left,
  onAdd,
  onClose,
}: {
  passage: DocumentPassagePlace;
  top: number;
  left: number;
  /** Stages the change; false when the message can take no more. */
  onAdd: (edit: DocumentEdit) => boolean;
  onClose: () => void;
}) {
  const messages = useCommaMessages();
  const form = useRef<HTMLFormElement>(null);
  const field = useRef<HTMLTextAreaElement>(null);
  const [note, setNote] = useState("");
  const add = () => {
    if (onAdd({ ...passage, note: note.trim() })) onClose();
  };
  const latest = useRef({ add, onClose });
  latest.current = { add, onClose };
  useEffect(() => {
    field.current?.focus();
    const view = form.current?.ownerDocument;
    if (!view) return undefined;
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        latest.current.onClose();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "l") {
        event.preventDefault();
        latest.current.add();
      }
    };
    const press = (event: PointerEvent) => {
      if (event.target instanceof Node && !form.current?.contains(event.target))
        latest.current.onClose();
    };
    view.addEventListener("keydown", key, true);
    view.addEventListener("pointerdown", press, true);
    return () => {
      view.removeEventListener("keydown", key, true);
      view.removeEventListener("pointerdown", press, true);
    };
  }, []);
  return (
    <form
      aria-label={messages.file_preview_document_edit()}
      className="comma-document-edit-window"
      data-testid="document-edit-window"
      onSubmit={(event) => {
        event.preventDefault();
        add();
      }}
      ref={form}
      style={{ top, ["--comma-document-edit-left" as string]: `${left}px` }}
    >
      <blockquote className="comma-document-edit-quote">{passage.quote}</blockquote>
      <div className="comma-document-edit-row">
        <textarea
          aria-label={messages.file_preview_document_edit_placeholder()}
          className="comma-document-edit-field"
          maxLength={4000}
          onChange={(event) => setNote(event.target.value)}
          onKeyDown={(event) => {
            // The page's own keys do not reach the field. Enter adds it; a line break is Shift+Enter, and a word
            // being composed takes its own Enter.
            event.stopPropagation();
            if (event.key === "Escape") onClose();
            if (
              event.key !== "Enter" ||
              event.shiftKey ||
              event.nativeEvent.isComposing
            )
              return;
            event.preventDefault();
            add();
          }}
          placeholder={messages.file_preview_document_edit_placeholder()}
          ref={field}
          rows={1}
          value={note}
        />
        <Button hierarchy="tertiary-gray" size="xs" type="submit">
          {messages.file_preview_document_edit_add()}
          <kbd className="comma-document-edit-keys" aria-hidden="true">
            ⌘L
          </kbd>
        </Button>
      </div>
    </form>
  );
}
