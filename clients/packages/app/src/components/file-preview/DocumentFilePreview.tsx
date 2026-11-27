import { useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import {
  ArrowDownIcon,
  ArrowUpIcon,
  ListBulletsIcon,
} from "@comma/ui/components/icons";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import {
  Menu,
  MenuItem,
  MenuPopover,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import {
  lazy,
  Suspense,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import { createPortal } from "react-dom";
import { MenuTrigger } from "react-aria-components";
import { ShellIconButtonControl } from "../ShellIconButton";
import DOMPurify from "dompurify";
import { documentDiff, documentDiffHasChanges } from "./documentDiff";
import {
  documentBodyHtml,
  documentHeadings,
  documentParts,
  documentTree,
  type DocumentHeading,
} from "./documentExport";
import {
  advanceDocumentPlayback,
  documentCaretMark,
  documentFileTitle,
  documentOpensWithTitle,
  documentPlaybackFrame,
  documentPlaybackLimit,
  documentPlaybackStep,
  documentPlaybackStepMs,
  documentRevisionSpan,
  type DocumentRevisionSpan,
} from "./documentRevision";
import type { DocumentEditing } from "./DocumentEditor";
import { documentPictureDrawer, type DocumentPictureRead } from "./DocumentPictureView";
import { revealSectionEvent } from "./documentReveal";
import type { DocumentPassages } from "./DocumentSelectionEdit";
import { textPreviewLimit } from "./FilePreviewContent";
import { FilePreviewLoading } from "./FilePreviewLoading";

/** Who writes the document shown: an Agent whose versions of it arrive while the page is open. */
export type DocumentWriter = {
  name: string;
  /** The writer is at work now: its caret stays in the page between its versions. */
  active: boolean;
};

// One sweep of the shine (`--motion-duration-loading-shine`): a change typed faster still shows a whole one.
const shineMs = 1600;
// The shine's fade (`--motion-duration-feedback-out`), after which the block is plain again.
const shineEndMs = 180;

type Playback = { span: DocumentRevisionSpan; count: number };

/**
 * The Markdown the page draws for `text`: itself, or — when a writer's version replaces the one shown — the change
 * typed in a frame at a time, with the caret mark where the writer is.
 */
function useDocumentPlayback(
  text: string | undefined,
  writer: DocumentWriter | undefined,
  playFirst: boolean
) {
  // The version the page last took: a writer's first one is typed onto an empty page.
  const shown = useRef<string | undefined>(playFirst ? "" : undefined);
  const [playback, setPlayback] = useState<Playback>();
  const [shining, setShining] = useState(false);
  const writes = writer !== undefined;
  useEffect(() => {
    if (text === undefined) return;
    const previous = shown.current;
    shown.current = text;
    if (previous === undefined || !writes) {
      setPlayback(undefined);
      return;
    }
    if (previous === text) return;
    const span = documentRevisionSpan(previous, text);
    const typed = !isReducedMotionEnabled() && text.length <= documentPlaybackLimit;
    setPlayback({ span, count: typed ? 0 : span.insert.length });
  }, [text, writes]);

  const span = playback?.span;
  // Each change shines for one sweep at least, however fast it is typed.
  useEffect(() => {
    if (!span) return undefined;
    setShining(true);
    return uiClock.after(shineMs, () => setShining(false));
  }, [span]);
  const typing = playback !== undefined && playback.count < playback.span.insert.length;
  useEffect(() => {
    if (!span || !typing) return undefined;
    const step = documentPlaybackStep(span.insert.length);
    return uiClock.every(documentPlaybackStepMs, () =>
      setPlayback((current) =>
        current?.span === span
          ? { span, count: advanceDocumentPlayback(span.insert, current.count, step) }
          : current
      )
    );
  }, [span, typing]);

  // Between versions the caret stays where the writer stopped, while the writer is at work.
  const present = playback !== undefined && (typing || writer?.active === true);
  return {
    content: present ? documentPlaybackFrame(playback.span, playback.count) : text,
    present,
    typing,
    shining: present && (typing || shining),
    revision: span,
  };
}

const skipped = "button, [aria-hidden='true'], .comma-document-caret";

/** The caret mark's place in the page's text. */
function findMark(page: HTMLElement) {
  const walker = page.ownerDocument.createTreeWalker(page, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const offset = node.textContent?.indexOf(documentCaretMark) ?? -1;
    if (offset >= 0 && !node.parentElement?.closest(skipped))
      return { node: node as Text, offset };
  }
  return undefined;
}

/** Where the text ends at `offset` of `node`: the line box's right edge there. */
function caretRect(node: Text, offset: number) {
  const range = node.ownerDocument.createRange();
  // The mark has no width; the character before it gives the line and the edge.
  if (offset > 0) {
    range.setStart(node, offset - 1);
    range.setEnd(node, offset);
    const rect = range.getClientRects()[0];
    if (rect) return { x: rect.right, top: rect.top, height: rect.height };
  }
  range.setStart(node, offset);
  range.setEnd(node, offset + 1);
  const rect = range.getClientRects()[0] ?? node.parentElement?.getBoundingClientRect();
  return rect ? { x: rect.left, top: rect.top, height: rect.height } : undefined;
}

/**
 * The writer's caret and name over the page, and the shine on the block it is in. The page's renderer owns its
 * elements, so the caret reads the mark's place from the page after each change of it and moves itself there.
 */
function DocumentWriterCaret({
  name,
  noticeSlot,
  pageRef,
  present,
  revision,
  shining,
  typing,
}: {
  name: string;
  /** Where the notice of a caret out of view goes: over the page, at the bottom of what the reader sees. */
  noticeSlot: HTMLElement | null;
  pageRef: RefObject<HTMLElement | null>;
  present: boolean;
  /** The change being written; a new one follows the caret again. */
  revision: DocumentRevisionSpan | undefined;
  shining: boolean;
  typing: boolean;
}) {
  const caretRef = useRef<HTMLDivElement>(null);
  const shiningRef = useRef(shining);
  shiningRef.current = shining;
  // The reader who scrolls away reads on undisturbed until the next change.
  const follows = useRef(true);
  useEffect(() => {
    follows.current = true;
  }, [revision]);

  // Where the caret is when the reader cannot see it: the notice says the writer is at work there.
  const messages = useCommaMessages();
  const [away, setAway] = useState<"above" | "below">();
  useEffect(() => {
    const caret = caretRef.current;
    const viewport = caret?.closest('[data-slot="scroll-area-viewport"]');
    if (!caret || !viewport) return undefined;
    const seen = new IntersectionObserver(
      ([entry]) => {
        if (!entry) return;
        setAway(
          entry.isIntersecting
            ? undefined
            : entry.boundingClientRect.top < (entry.rootBounds?.top ?? 0)
              ? "above"
              : "below"
        );
      },
      { root: viewport }
    );
    seen.observe(caret);
    return () => seen.disconnect();
  }, []);

  const block = useRef<Element | null>(null);
  const ending = useRef<CancelUiTimer | undefined>(undefined);

  // After the commit, when the page's own element is there to read.
  useEffect(() => {
    const page = pageRef.current;
    const caret = caretRef.current;
    if (!page || !caret) return undefined;
    let frame: CancelUiTimer | undefined;
    // The shine is on one block: the one the caret is in.
    const shine = (next: Element | null) => {
      const previous = block.current;
      if (previous !== next) previous?.removeAttribute("data-document-writing");
      ending.current?.();
      next?.setAttribute("data-document-writing", "true");
      block.current = next;
    };
    const place = () => {
      frame = undefined;
      const mark = findMark(page);
      const rect = mark && caretRect(mark.node, mark.offset);
      if (!mark || !rect) return;
      const origin = page.getBoundingClientRect();
      const x = rect.x - origin.left;
      caret.style.transform = `translate3d(${x}px, ${rect.top - origin.top}px, 0)`;
      caret.style.height = `${rect.height}px`;
      caret.dataset.flag = x > origin.width * 0.7 ? "end" : "start";
      if (shiningRef.current)
        shine(
          mark.node.parentElement?.closest(".markdown-renderer > .node-slot") ?? null
        );
      if (follows.current)
        caret.scrollIntoView({ block: "nearest", inline: "nearest" });
    };
    const schedule = () => {
      frame ??= uiClock.frame(place);
    };
    const mutations = new MutationObserver(schedule);
    mutations.observe(page, { characterData: true, childList: true, subtree: true });
    const sizes = new ResizeObserver(schedule);
    sizes.observe(page);
    const leave = () => {
      follows.current = false;
    };
    page.addEventListener("wheel", leave, { passive: true });
    page.addEventListener("touchmove", leave, { passive: true });
    schedule();
    return () => {
      mutations.disconnect();
      sizes.disconnect();
      page.removeEventListener("wheel", leave);
      page.removeEventListener("touchmove", leave);
      frame?.();
    };
  }, [pageRef]);

  // The shine leaves by its fade, then the block is the renderer's alone again.
  useEffect(() => {
    if (shining) return undefined;
    const lit = block.current;
    if (!lit) return undefined;
    lit.setAttribute("data-document-writing", "ending");
    ending.current = uiClock.after(shineEndMs, () => {
      lit.removeAttribute("data-document-writing");
      if (block.current === lit) block.current = null;
    });
    return undefined;
  }, [shining]);
  useEffect(
    () => () => {
      ending.current?.();
      block.current?.removeAttribute("data-document-writing");
    },
    []
  );

  const noticed = present && away !== undefined;
  return (
    <>
      <div
        aria-hidden="true"
        className="comma-document-caret"
        data-present={present}
        data-testid="document-writer-caret"
        data-typing={typing}
        ref={caretRef}
      >
        <span className="comma-document-caret-flag">{name}</span>
      </div>
      {noticeSlot
        ? createPortal(
            <div
              className="comma-document-notice"
              data-shown={noticed}
              data-testid="document-writer-notice"
              // Out of sight it is out of reach too.
              inert={!noticed}
            >
              <Button
                hierarchy="secondary-gray"
                iconTrailing={away === "above" ? <ArrowUpIcon /> : <ArrowDownIcon />}
                onPress={() => {
                  follows.current = true;
                  caretRef.current?.scrollIntoView({ block: "center" });
                }}
                size="xs"
              >
                {messages.file_preview_document_writing({ name })}
              </Button>
            </div>,
            noticeSlot
          )
        : null}
    </>
  );
}

/**
 * The document's outline, in the panel's toolbar: its headings, each a way to that heading. A document of fewer
 * than two headings has none.
 */
function DocumentOutline({
  headings,
  pageRef,
}: {
  headings: DocumentHeading[];
  pageRef: RefObject<HTMLElement | null>;
}) {
  const messages = useCommaMessages();
  const label = messages.file_preview_document_outline();
  // The shallowest heading sets the left edge, so an outline of second-level headings is not indented.
  const top = Math.min(...headings.map((heading) => heading.level));
  return (
    <MenuTrigger>
      <Tooltip content={label} placement="bottom">
        <ShellIconButtonControl
          aria-label={label}
          data-testid="file-preview-outline"
          icon={<ListBulletsIcon className="comma-input-icon" />}
        />
      </Tooltip>
      <MenuPopover
        placement="bottom end"
        className={cx("w-64 overflow-hidden", menuSurfaceClasses)}
      >
        <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
          <Menu
            aria-label={label}
            className="py-sm"
            onAction={(key) => {
              // The page's headings, as it is read or as it is edited.
              const slots = pageRef.current?.querySelectorAll(
                '.markdown-renderer > .node-slot[data-node-type="heading"], .comma-document-editor > :is(h1, h2, h3, h4, h5, h6)'
              );
              const slot = slots?.[Number(key)];
              // A heading in a section the reader folded away is shown first (`DocumentSections`).
              slot?.dispatchEvent(
                new CustomEvent(revealSectionEvent, { bubbles: true })
              );
              slot?.scrollIntoView({ block: "start" });
            }}
            variant="embedded"
          >
            {headings.map((heading, index) => (
              <MenuItem
                // A heading is its place in the document: two may share their words.
                // oxlint-disable-next-line react/no-array-index-key
                key={index}
                id={String(index)}
                contentClassName={cx(
                  "truncate",
                  heading.level - top === 1 && "pl-xl",
                  heading.level - top >= 2 && "pl-4xl",
                  heading.level - top === 0 ? "text-primary" : "text-secondary"
                )}
                textValue={heading.text}
              >
                {heading.text}
              </MenuItem>
            ))}
          </Menu>
        </ScrollArea>
      </MenuPopover>
    </MenuTrigger>
  );
}

// The editor and its engine load with the first document a reader may change; the page is read meanwhile.
const DocumentEditor = lazy(() => import("./DocumentEditor"));

/** The first `textPreviewLimit` bytes of a file as text, once read. */
function useBlobText(blob: Blob | undefined) {
  const [read, setRead] = useState<{ blob: Blob; text: string }>();
  useEffect(() => {
    if (!blob) return undefined;
    let current = true;
    void blob
      .slice(0, textPreviewLimit)
      .text()
      .then((text) => {
        if (current) setRead({ blob, text });
      });
    return () => {
      current = false;
    };
  }, [blob]);
  return read?.blob === blob ? read?.text : undefined;
}

/**
 * Two versions of the document as one page: what the newer took away is struck through on red, what it added is
 * underlined on green. The page is drawn from the compared documents themselves (`documentBodyHtml` writes every
 * character of them escaped), and a link in it opens beside the chat as any other does.
 */
function DocumentDiffView({
  before,
  after,
  onOpenBrowser,
}: {
  before: string;
  after: string;
  onOpenBrowser: (url: string) => void;
}) {
  const messages = useCommaMessages();
  const { html, changed } = useMemo(() => {
    const tree = documentDiff(
      documentTree(documentParts(before).page),
      documentTree(after)
    );
    return {
      html: DOMPurify.sanitize(documentBodyHtml(tree)),
      changed: documentDiffHasChanges(tree),
    };
  }, [after, before]);
  return (
    <>
      {changed ? null : (
        <p className="comma-document-note" data-testid="document-diff-same">
          {messages.file_preview_document_no_changes()}
        </p>
      )}
      {/* The page is the document's text; its links are followed by the press. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/click-events-have-key-events */}
      <div
        className="comma-document-prose comma-document-diff"
        dangerouslySetInnerHTML={{ __html: html }}
        data-testid="document-diff"
        onClick={(event) => {
          const link =
            event.target instanceof Element ? event.target.closest("a[href]") : null;
          if (!link) return;
          event.preventDefault();
          onOpenBrowser(link.getAttribute("href")!);
        }}
      />
    </>
  );
}

/**
 * A Markdown file read as a page: its title, then its text in a reading column. While `writer` is given, each new
 * version of the file is typed into the page where it differs from the one shown, under the writer's caret.
 */
export function DocumentFilePreview({
  blob,
  fileName,
  writer,
  playFirst = false,
  edits,
  compare,
  editing,
  pictures,
  toolbarSlot,
  onOpenBrowser,
  children,
}: {
  blob: Blob;
  fileName: string;
  writer?: DocumentWriter | undefined;
  /** The version the page opens with is the writer's own, new now: it is typed onto the empty page. */
  playFirst?: boolean | undefined;
  /**
   * The reader's own edits of the page. With it the page is an editor from the start, whenever it shows a whole
   * version at rest; without it the page is read only.
   */
  editing?: DocumentEditing | undefined;
  /** Asking Comma to change a passage selected in the page the reader edits. */
  edits?: DocumentPassages | undefined;
  /** An earlier version of the document: the page shows what this version changed of it. */
  compare?: Blob | undefined;
  /** Reads a file that goes with the document; with it a page that is read draws the document's own pictures. */
  pictures?: DocumentPictureRead | undefined;
  /** Where the page's own controls go in the panel's toolbar (its outline). */
  toolbarSlot?: HTMLElement | null | undefined;
  onOpenBrowser: (url: string) => void;
  /** What the panel shows under the page. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const streamId = useId();
  const pageRef = useRef<HTMLElement>(null);
  // A new version's text replaces the one shown when it is read: the page never blanks between two versions.
  // Each text read is a version of the page (`id`): the editor starts anew on it.
  const [read, setRead] = useState<{ text: string; id: number }>();
  useEffect(() => {
    let current = true;
    void blob
      .slice(0, textPreviewLimit)
      .text()
      .then((value) => {
        if (current)
          setRead((shown) =>
            shown?.text === value ? shown : { text: value, id: (shown?.id ?? 0) + 1 }
          );
      });
    return () => {
      current = false;
    };
  }, [blob]);
  // The page is the document without its front matter: what is read, typed in, outlined and compared is the page.
  const text = useMemo(
    () => (read === undefined ? undefined : documentParts(read.text).page),
    [read]
  );
  const { content, present, typing, shining, revision } = useDocumentPlayback(
    text,
    writer,
    playFirst
  );
  // A page that is read draws the document's own pictures from their files, as the page a reader edits does.
  const policy = useMemo(
    () => ({
      onOpenLink: onOpenBrowser,
      ...(pictures ? { renderPicture: documentPictureDrawer(pictures) } : {}),
    }),
    [onOpenBrowser, pictures]
  );
  // The outline is of the whole version, not of what is typed so far, and of the reader's edits of it.
  const draft = editing?.draft;
  const headings = useMemo(() => {
    const outlined = draft === undefined ? text : documentParts(draft).page;
    return outlined === undefined ? [] : documentHeadings(documentTree(outlined));
  }, [draft, text]);
  const [noticeSlot, setNoticeSlot] = useState<HTMLElement | null>(null);
  const live = present || typing;
  const earlier = useBlobText(compare);
  // The page is edited as a whole version at rest: not while a writer's is typed in, not beside an earlier one,
  // and not a file cut short.
  const edited =
    editing !== undefined &&
    read !== undefined &&
    compare === undefined &&
    !live &&
    blob.size <= textPreviewLimit;
  const body =
    earlier !== undefined && text !== undefined ? (
      <DocumentDiffView after={text} before={earlier} onOpenBrowser={onOpenBrowser} />
    ) : content === undefined ? null : (
      <MarkdownStream
        animation={live ? "reveal" : "none"}
        content={content}
        documentResourcePolicy={policy}
        final={!live}
        htmlPolicy="escape"
        streamId={streamId}
      />
    );
  return (
    <ScrollArea
      className="min-h-0 flex-1"
      contentClassName="flex min-h-full flex-col"
      edgeEffect="none"
      viewportClassName="h-full"
    >
      <div
        className="comma-document flex flex-col"
        data-testid="file-preview-document"
        data-writing={live ? "true" : undefined}
      >
        <article className="comma-document-page" ref={pageRef}>
          {text === undefined ? (
            <FilePreviewLoading />
          ) : (
            <>
              {documentOpensWithTitle(text) ? null : (
                <h1 className="comma-document-title">{documentFileTitle(fileName)}</h1>
              )}
              {edited ? (
                // The page is read as it is while the editor loads.
                <Suspense fallback={body}>
                  <DocumentEditor
                    editing={editing}
                    // A new version of the file, or edits set from outside the page, start the editor anew.
                    key={`${read.id}:${editing.resets}`}
                    markdown={read.text}
                    onOpenBrowser={onOpenBrowser}
                    passages={edits}
                  />
                </Suspense>
              ) : (
                body
              )}
              {blob.size > textPreviewLimit ? (
                <p className="comma-document-note">
                  {messages.file_preview_text_truncated()}
                </p>
              ) : null}
            </>
          )}
          {writer ? (
            <DocumentWriterCaret
              name={writer.name}
              noticeSlot={noticeSlot}
              pageRef={pageRef}
              present={present}
              revision={revision}
              shining={shining}
              typing={typing}
            />
          ) : null}
        </article>
        {children}
        <div className="comma-document-notice-slot" ref={setNoticeSlot} />
      </div>
      {toolbarSlot && headings.length > 1
        ? createPortal(
            <DocumentOutline headings={headings} pageRef={pageRef} />,
            toolbarSlot
          )
        : null}
    </ScrollArea>
  );
}
