import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { z } from "zod";

const noteSchema = z.object({
  id: z.string().max(100),
  start: z.number().int().min(0),
  end: z.number().int().min(0),
  quote: z.string().max(4000),
  body: z.string().min(1).max(4000),
});
type Note = z.infer<typeof noteSchema>;
type Anchor = Pick<Note, "start" | "end" | "quote">;

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
}

/** The anchor's range while the rendered text still holds its quote. */
function textRange(root: HTMLElement, anchor: Anchor, text = root.textContent ?? "") {
  if (text.slice(anchor.start, anchor.end) !== anchor.quote) return;
  return rangeAt(root, anchor.start, anchor.end);
}

// `textContent` joins rendered blocks with no separator ("noon.first item");
// a reader, and an agent matching the source, sees a line break there.
const blockElements =
  "p, li, h1, h2, h3, h4, h5, h6, pre, blockquote, td, th, dt, dd, div";
function readableText(root: HTMLElement, range: Range) {
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let text = "";
  let block: Element | null | undefined;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!range.intersectsNode(node)) continue;
    const value = node.textContent ?? "";
    const part = value.slice(
      node === range.startContainer ? range.startOffset : 0,
      node === range.endContainer ? range.endOffset : value.length
    );
    if (!part) continue;
    const owner = node.parentElement?.closest(blockElements) ?? null;
    if (block !== undefined && owner !== block && !text.endsWith("\n")) text += "\n";
    block = owner;
    text += part;
  }
  return text;
}

/** What the agent reads: preview text it can find in the source, never preview offsets. */
function annotationMessage(root: HTMLElement | null, fileName: string, notes: Note[]) {
  const text = root?.textContent ?? "";
  return [
    `Artifact annotations: ${fileName}`,
    "Quotes and context are text from the rendered preview: Markdown markup is removed and a line break separates blocks.",
    ...notes.map((note, index) => {
      const quoted = root && textRange(root, note, text);
      const around =
        root &&
        quoted &&
        rangeAt(
          root,
          Math.max(0, note.start - 40),
          Math.min(text.length, note.end + 40)
        );
      const quote = root && quoted ? readableText(root, quoted) : note.quote;
      const context = root && around ? readableText(root, around) : quote;
      return `${index + 1}. Quote: ${JSON.stringify(quote)}\n${context === quote ? "" : `Context: ${JSON.stringify(context)}\n`}Comment: ${note.body}`;
    }),
  ].join("\n\n");
}

/** Local annotation drafts. Sending uses the conversation's existing message authority. */
export function ArtifactAnnotations({
  storageKey,
  fileName,
  onSend,
  children,
}: {
  storageKey: string;
  fileName: string;
  onSend: (text: string) => void;
  children: ReactNode;
}) {
  const messages = useCommaMessages();
  const content = useRef<HTMLDivElement>(null);
  const editor = useRef<HTMLTextAreaElement>(null);
  const [anchorTop, setAnchorTop] = useState(0);
  const [failed, setFailed] = useState(false);
  const [notes, setNotes] = useState<Note[]>(() => {
    try {
      const raw = sessionStorage.getItem(storageKey);
      if (!raw || raw.length > 2_000_000) return [];
      const parsed = z.array(noteSchema).max(100).safeParse(JSON.parse(raw));
      return parsed.success ? parsed.data : [];
    } catch {
      return [];
    }
  });
  const [selection, setSelection] = useState<Anchor>();
  const [draft, setDraft] = useState<{ anchor: Anchor; id?: string }>();
  const [body, setBody] = useState("");
  useEffect(() => {
    if (draft) editor.current?.focus();
  }, [draft]);
  const [rects, setRects] = useState<
    Array<{ id: string; left: number; top: number; width: number; height: number }>
  >([]);
  useEffect(() => {
    const root = content.current;
    if (!root || !notes.length) {
      setRects((current) => (current.length ? [] : current));
      return;
    }
    const measure = () => {
      const bounds = root.getBoundingClientRect();
      const text = root.textContent ?? "";
      setRects(
        notes.flatMap((note) => {
          const range = textRange(root, note, text);
          return range
            ? Array.from(range.getClientRects(), (rect) => ({
                id: note.id,
                left: rect.left - bounds.left,
                top: rect.top - bounds.top,
                width: rect.width,
                height: rect.height,
              }))
            : [];
        })
      );
    };
    // The text arrives after its blob loads and code highlights later; a parent
    // render (a streamed reply in the host chat) changes neither.
    const resized = new ResizeObserver(measure);
    const changed = new MutationObserver(measure);
    resized.observe(root);
    changed.observe(root, { characterData: true, childList: true, subtree: true });
    measure();
    return () => {
      resized.disconnect();
      changed.disconnect();
    };
  }, [notes]);
  const commit = (next: Note[]) => {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(next));
      setNotes(next);
      setFailed(false);
      return true;
    } catch {
      setFailed(true);
      return false;
    }
  };
  const select = () => {
    const root = content.current;
    const selected = root?.ownerDocument.getSelection();
    if (!root || !selected || selected.isCollapsed || !selected.rangeCount) {
      setSelection(undefined);
      return;
    }
    const range = selected.getRangeAt(0);
    if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) {
      setSelection(undefined);
      return;
    }
    const prefix = range.cloneRange();
    prefix.selectNodeContents(root);
    prefix.setEnd(range.startContainer, range.startOffset);
    const quote = range.toString();
    setAnchorTop(
      range.getBoundingClientRect().bottom - root.getBoundingClientRect().top
    );
    setSelection(
      quote.trim() && quote.length <= 4000
        ? {
            start: prefix.toString().length,
            end: prefix.toString().length + quote.length,
            quote,
          }
        : undefined
    );
  };
  return (
    <div className="flex min-w-0 flex-col gap-md">
      <p className="text-sm text-secondary">{messages.artifact_notes_hint()}</p>
      <div className="relative">
        {/* Selection belongs to rendered document text, including noninteractive paragraphs. */}
        {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions */}
        <div ref={content} onPointerUp={select} onKeyUp={select}>
          {children}
        </div>
        <div className="pointer-events-none absolute inset-0" aria-hidden="true">
          {rects.map((rect, index) => (
            <mark
              key={`${rect.id}:${index}`}
              className="absolute bg-warning-solid opacity-20"
              style={{
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
              }}
            />
          ))}
        </div>
        {notes.map((note, index) => {
          const rect = rects.find((item) => item.id === note.id);
          return rect ? (
            <Button
              key={note.id}
              size="sm"
              hierarchy="secondary-gray"
              className="absolute right-0 z-10"
              style={{ top: rect.top }}
              aria-label={`${messages.artifact_notes_edit()} ${index + 1}`}
              onPress={() => {
                setAnchorTop(rect.top + rect.height);
                setDraft({ anchor: note, id: note.id });
                setBody(note.body);
              }}
            >
              {index + 1}
            </Button>
          ) : null;
        })}
        {selection && !draft ? (
          <div
            className="absolute left-0 z-10 rounded-lg bg-primary shadow-lg"
            style={{ top: anchorTop }}
          >
            <Button
              hierarchy="tertiary-gray"
              onPress={() => {
                setDraft({ anchor: selection });
                setBody("");
              }}
            >
              {messages.artifact_notes_add()}
            </Button>
          </div>
        ) : null}
        {draft ? (
          <form
            className="absolute inset-x-0 z-10 flex flex-col gap-sm rounded-lg border border-primary bg-primary p-md shadow-lg"
            style={{ top: anchorTop }}
            onSubmit={(event) => {
              event.preventDefault();
              if (!body.trim() || (!draft.id && notes.length >= 100)) return;
              const note = {
                ...draft.anchor,
                id: draft.id ?? crypto.randomUUID(),
                body: body.trim(),
              };
              if (
                commit(
                  draft.id
                    ? notes.map((item) => (item.id === draft.id ? note : item))
                    : [...notes, note]
                )
              ) {
                setDraft(undefined);
                setSelection(undefined);
              }
            }}
          >
            <blockquote className="text-sm text-secondary">
              {draft.anchor.quote}
            </blockquote>
            <label className="flex flex-col gap-sm">
              {messages.artifact_notes_body()}
              <textarea
                ref={editor}
                className="rounded-md border border-primary bg-primary p-sm text-sm text-primary"
                maxLength={4000}
                value={body}
                onChange={(event) => setBody(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key !== "Escape") return;
                  event.preventDefault();
                  event.stopPropagation();
                  setDraft(undefined);
                }}
              />
            </label>
            <div className="flex gap-sm">
              <Button
                type="submit"
                isDisabled={!body.trim() || (!draft.id && notes.length >= 100)}
              >
                {messages.artifact_notes_save()}
              </Button>
              <Button hierarchy="secondary-gray" onPress={() => setDraft(undefined)}>
                {messages.artifact_notes_cancel()}
              </Button>
            </div>
          </form>
        ) : null}
      </div>
      {failed ? <p role="alert">{messages.artifact_notes_failed()}</p> : null}
      {notes.length >= 100 ? <output>{messages.artifact_notes_limit()}</output> : null}
      {notes.length ? (
        <aside
          aria-label={messages.artifact_notes_title()}
          className="flex flex-col gap-md border-t border-primary pt-md"
        >
          <h3 className="text-sm font-medium">
            {messages.artifact_notes_title()} ({notes.length})
          </h3>
          {notes.map((note, index) => (
            <div
              key={note.id}
              className="flex flex-col gap-sm rounded-lg border border-primary p-md"
            >
              <Button
                hierarchy="tertiary-gray"
                size="sm"
                className="h-auto min-w-0 justify-start whitespace-normal break-words text-left"
                onPress={() => {
                  const root = content.current;
                  const range = root && textRange(root, note);
                  if (!range) return;
                  const selected = root.ownerDocument.getSelection();
                  selected?.removeAllRanges();
                  selected?.addRange(range);
                  range.startContainer.parentElement?.scrollIntoView({
                    block: "nearest",
                  });
                }}
              >
                {index + 1}.{" "}
                {note.quote.length > 160 ? `${note.quote.slice(0, 160)}…` : note.quote}
              </Button>
              <p className="whitespace-pre-wrap break-words text-sm">{note.body}</p>
              <div className="flex gap-sm">
                <Button
                  hierarchy="secondary-gray"
                  size="sm"
                  onPress={() => {
                    const root = content.current;
                    const range = root && textRange(root, note);
                    setAnchorTop(
                      root && range
                        ? range.getBoundingClientRect().bottom -
                            root.getBoundingClientRect().top
                        : 0
                    );
                    root?.scrollIntoView({ block: "nearest" });
                    setDraft({ anchor: note, id: note.id });
                    setBody(note.body);
                  }}
                >
                  {messages.artifact_notes_edit()}
                </Button>
                <Button
                  hierarchy="secondary-gray"
                  size="sm"
                  onPress={() => {
                    if (
                      commit(notes.filter((item) => item.id !== note.id)) &&
                      draft?.id === note.id
                    )
                      setDraft(undefined);
                  }}
                >
                  {messages.artifact_notes_delete()}
                </Button>
              </div>
            </div>
          ))}
          <Button
            onPress={() => onSend(annotationMessage(content.current, fileName, notes))}
          >
            {messages.artifact_notes_send()}
          </Button>
        </aside>
      ) : null}
    </div>
  );
}
