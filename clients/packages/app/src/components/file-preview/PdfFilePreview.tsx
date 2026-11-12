import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import {
  ChevronDownSmallIcon,
  CrossLargeIcon,
  PanelLeftIcon,
  SquareCursorIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { ScrollArea, type ScrollAreaMetrics } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { isReducedMotionEnabled, spacing, width as widths } from "@comma/ui/tokens";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { Button as AriaButton } from "react-aria-components";
// Vite turns this local package asset into a bundled URL.
// oxlint-disable-next-line import/default
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { PDFDocumentProxy, PDFWorker } from "pdfjs-dist";
import { Composer } from "../chat/composer/Composer";
import { ShellIconButtonControl } from "../ShellIconButton";
import { fixedDraftSource } from "../chat/composer/conversationDraft";
import { FilePreviewLoading } from "./FilePreviewLoading";
import { capturePdfRegion, type PdfRect, type PdfRegionEdit } from "./pdfRegionEdit";

/** A file read in spans: up to `length` bytes from `offset`, and the whole file's size. */
export interface RangedFile {
  read(
    offset: number,
    length: number,
    signal?: AbortSignal
  ): Promise<{ bytes: Uint8Array; size: number }>;
}

/** pdf.js asks for spans of this size: a page reads only the spans it needs. */
const PDF_RANGE_CHUNK = 256 * 1024;
/** The most one read asks for (`files.readRange` takes at most 10 MB): a whole number of chunks. */
const PDF_READ_MAX = 32 * PDF_RANGE_CHUNK;
/** At 100% a PDF point is 4/3 CSS px: the page shows at its printed size on a 96 dpi screen. */
const CSS_PER_POINT = 96 / 72;
const zoomSteps = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;
/** The most pixels one page canvas holds: the image size pdf.js decodes (`maxImageSize`). */
const CANVAS_PIXEL_BUDGET = 16_777_216;
/** A page whose width keeps changing (a panel resize) re-renders once it rests; meanwhile its bitmap stretches. */
const RESIZE_SETTLE_MS = 150;
/** Space around and between the pages. */
const pageGutter = spacing.xl;
const pageGap = spacing.lg;
/** Thumbnail column geometry; the item classes below lay out the same numbers. */
const thumbWidth = spacing["9xl"];
const thumbPadding = spacing.sm;
const thumbGap = spacing.xxs;
/** A selection smaller than this on either side is a click, not an area. */
const minRegion = 4;
/** Pages and thumbnails mounted on each side of the one being read, besides those near the view. */
const mountedAround = 2;

type PageSize = { width: number; height: number };
type Zoom = "fit" | (typeof zoomSteps)[number];
type Selection = { page: number; from: [number, number]; to: [number, number] };

const closed = () => new DOMException("The PDF was closed", "AbortError");

/** The one worker every opening that asks to share it uses (`shareWorker`), started by the first. */
let sharedWorker: PDFWorker | undefined;

/**
 * Opens a PDF from its bytes, or from spans of a file of any size (`ranged`): pdf.js reads only the spans the pages
 * it draws need. `close` stops the reads and frees the document. A read that fails after the document opened reports
 * through `onReadFailed`. With `shareWorker` the document runs in the shared worker, which outlives it, instead of
 * a worker of its own.
 */
export function openPdfDocument(
  source: { blob: Blob } | { ranged: RangedFile },
  {
    onReadFailed,
    shareWorker = false,
  }: { onReadFailed: () => void; shareWorker?: boolean }
) {
  let open = true;
  const reads = new AbortController();
  let loading: ReturnType<(typeof import("pdfjs-dist"))["getDocument"]> | undefined;
  const document = (async () => {
    const pdfjs = await import("pdfjs-dist");
    pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
    const options = {
      enableXfa: false,
      maxImageSize: CANVAS_PIXEL_BUDGET,
      ...(shareWorker ? { worker: (sharedWorker ??= new pdfjs.PDFWorker()) } : {}),
    };
    if ("ranged" in source) {
      const { ranged } = source;
      // The first span carries the file's size; the rest are read as pdf.js asks.
      const first = await ranged.read(0, PDF_RANGE_CHUNK, reads.signal);
      if (!open) throw closed();
      const transport = new pdfjs.PDFDataRangeTransport(first.size, first.bytes);
      // pdf.js may join adjacent chunks into one span larger than a read takes: it is read, and handed on, in
      // chunk-aligned parts.
      transport.requestDataRange = (begin: number, end: number) => {
        for (let from = begin; from < end; from += PDF_READ_MAX) {
          ranged.read(from, Math.min(PDF_READ_MAX, end - from), reads.signal).then(
            (span) => {
              if (open) transport.onDataRange(from, span.bytes);
            },
            () => {
              if (open) onReadFailed();
            }
          );
        }
      };
      loading = pdfjs.getDocument({
        ...options,
        range: transport,
        rangeChunkSize: PDF_RANGE_CHUNK,
        disableAutoFetch: true,
        disableStream: true,
      });
    } else {
      const data = new Uint8Array(await source.blob.arrayBuffer());
      if (!open) throw closed();
      loading = pdfjs.getDocument({ ...options, data });
    }
    return loading.promise;
  })();
  return {
    document,
    close: () => {
      if (!open) return;
      open = false;
      reads.abort();
      void loading?.destroy();
    },
  };
}

function usePdfDocument(blob: Blob | undefined, ranged: RangedFile | undefined) {
  const [pdf, setPdf] = useState<PDFDocumentProxy>();
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let current = true;
    const opened = openPdfDocument(ranged ? { ranged } : { blob: blob! }, {
      onReadFailed: () => setFailed(true),
    });
    opened.document.then(
      (loaded) => {
        if (current) setPdf(loaded);
      },
      () => {
        if (current) setFailed(true);
      }
    );
    return () => {
      current = false;
      opened.close();
    };
  }, [blob, ranged]);
  return { pdf, failed, fail: useCallback(() => setFailed(true), []) };
}

/** The page's size in points as it shows (rotation applied). */
async function pageSize(pdf: PDFDocumentProxy, page: number): Promise<PageSize> {
  const { width, height } = (await pdf.getPage(page)).getViewport({ scale: 1 });
  if (!(Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0))
    throw new Error("Invalid PDF page dimensions");
  return { width, height };
}

/** Index of the last offset at or above `y`: the page a vertical position falls in. */
function pageAt(tops: readonly number[], y: number) {
  let low = 0;
  let high = tops.length - 1;
  while (low < high) {
    const middle = (low + high + 1) >> 1;
    if (tops[middle]! <= y) low = middle;
    else high = middle - 1;
  }
  return low;
}

/** Top offset of each item in a column of `heights` laid out with `start` before and `gap` between. */
function offsets(heights: readonly number[], start: number, gap: number) {
  const tops: number[] = [];
  let top = start;
  for (const height of heights) {
    tops.push(top);
    top += height + gap;
  }
  return tops;
}

/**
 * One page drawn at `width` CSS px while `active`; inactive, it gives its bitmap back. The box around it holds the
 * page's size, so the column keeps its layout either way.
 */
function PdfPageCanvas({
  pdf,
  page,
  width,
  active,
  label,
  onSize,
  onError,
}: {
  pdf: PDFDocumentProxy;
  page: number;
  width: number;
  active: boolean;
  label?: string | undefined;
  onSize: (page: number, size: PageSize) => void;
  onError: () => void;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  /** The canvas holds a drawing of this page (at some width). */
  const drawn = useRef(false);
  useEffect(() => {
    const target = canvas.current;
    if (!target) return;
    if (!active) {
      drawn.current = false;
      target.width = 0;
      target.height = 0;
      return;
    }
    let current = true;
    let render: ReturnType<Awaited<ReturnType<PDFDocumentProxy["getPage"]>>["render"]>;
    const draw = async () => {
      const pdfPage = await pdf.getPage(page);
      const size = await pageSize(pdf, page);
      if (!current) return;
      onSize(page, size);
      const ratio = target.ownerDocument.defaultView?.devicePixelRatio ?? 1;
      const scale = Math.min(
        (width / size.width) * ratio,
        Math.sqrt(CANVAS_PIXEL_BUDGET / (size.width * size.height))
      );
      const viewport = pdfPage.getViewport({ scale });
      target.width = Math.max(1, Math.floor(viewport.width));
      target.height = Math.max(1, Math.floor(viewport.height));
      render = pdfPage.render({ canvas: target, viewport });
      await render.promise;
      drawn.current = true;
    };
    const cancelDraw = uiClock.after(drawn.current ? RESIZE_SETTLE_MS : 0, () => {
      void draw().catch(() => {
        if (current) onError();
      });
    });
    return () => {
      current = false;
      cancelDraw();
      render?.cancel();
    };
  }, [pdf, page, width, active, onSize, onError]);
  return (
    <canvas
      // Canvas pixels need an accessible image name; an img cannot host the PDF renderer.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      className="absolute inset-0 block size-full"
      data-page={page}
      ref={canvas}
    />
  );
}

/** The area being chosen or asked about, and the Composer that sends the request. */
function PdfRegionEditor({
  selection,
  dragging,
  scale,
  pageSize: size,
  pending,
  onSend,
  onCancel,
}: {
  selection: Selection;
  /** The pointer is still drawing the area: no Composer yet. */
  dragging: boolean;
  scale: number;
  pageSize: PageSize;
  pending: boolean;
  onSend: (prompt: string) => void;
  onCancel: () => void;
}) {
  const messages = useCommaMessages();
  const [draft, setDraft] = useState("");
  const draftSource = useMemo(() => fixedDraftSource(draft), [draft]);
  const composer = useRef<HTMLDivElement>(null);
  const rect = selectionRect(selection);
  useEffect(() => {
    if (!dragging)
      composer.current?.querySelector<HTMLElement>('[role="textbox"]')?.focus();
  }, [dragging]);
  const pageWidth = size.width * scale;
  const composerWidth = Math.min(widths.xxs + spacing["4xl"], pageWidth);
  const left = Math.min(Math.max(rect.x * scale, 0), pageWidth - composerWidth);
  const top = rect.y * scale;
  const bottom = (rect.y + rect.height) * scale;
  const above = top >= spacing["7xl"];
  return (
    <>
      <div
        aria-hidden
        className="pointer-events-none absolute border-2 border-dashed border-brand-solid bg-brand-solid/10"
        style={{
          left: rect.x * scale,
          top,
          width: rect.width * scale,
          height: rect.height * scale,
        }}
      >
        <span
          aria-hidden
          className="absolute -top-lg -right-lg size-3xl rounded-full rounded-bl-none bg-brand-solid shadow-sm ring-2 ring-white"
        />
      </div>
      {dragging ? null : (
        <div
          className="absolute"
          data-pdf-edit-composer=""
          ref={composer}
          style={{
            left,
            width: composerWidth,
            ...(above
              ? { bottom: size.height * scale - top + spacing.md }
              : { top: bottom + spacing.md }),
          }}
        >
          <Composer
            draftSource={draftSource}
            onDraftChange={setDraft}
            onSend={(message) => onSend(message)}
            placeholder={messages.file_preview_pdf_edit_placeholder()}
            showVoiceButton
            submitDisabled={!draft.trim()}
            submitPending={pending}
            toolbarLeading={
              // As the browser's element composer: a way out of this area without the keyboard.
              <AriaButton
                aria-label={messages.common_close()}
                className="pointer-events-auto inline-flex size-[30px] shrink-0 items-center justify-center rounded-full bg-quaternary text-ai-input-panel-icon-primary outline-none transition-colors hover:bg-fg-senary focus-visible:shadow-focus-gray"
                onPress={onCancel}
              >
                <CrossLargeIcon className="size-4" />
              </AriaButton>
            }
            variant="compact"
          />
        </div>
      )}
    </>
  );
}

const clamp = (value: number, max: number) => Math.max(0, Math.min(max, value));

/** The indices from `first` to `last`, widened by `mountedAround` around each of `kept`, in order. */
function mountedIndices(
  count: number,
  first: number,
  last: number,
  kept: readonly number[]
) {
  const indices = new Set<number>();
  const add = (from: number, to: number) => {
    for (let index = Math.max(0, from); index <= Math.min(count - 1, to); index += 1)
      indices.add(index);
  };
  add(first, last);
  for (const index of kept) add(index - mountedAround, index + mountedAround);
  return [...indices].toSorted((a, b) => a - b);
}

function selectionRect({ from, to }: Selection): PdfRect {
  return {
    x: Math.min(from[0], to[0]),
    y: Math.min(from[1], to[1]),
    width: Math.abs(to[0] - from[0]),
    height: Math.abs(to[1] - from[1]),
  };
}

/**
 * A PDF reader: pages in one scrolling column at a zoom, a thumbnail rail, and, when `onRequestEdit` is given, an
 * area of a page sent to the conversation with a request. Renders from the file's bytes or from spans of a file of
 * any size (`ranged`); only the pages near the view hold a bitmap.
 */
export function PdfFilePreview({
  blob,
  ranged,
  toolbarSlot,
  onRequestEdit,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  /** Where the zoom and Request edits controls go: the file toolbar. Without one they stay hidden. */
  toolbarSlot?: HTMLElement | null | undefined;
  onRequestEdit?: ((edit: PdfRegionEdit) => void) | undefined;
  /** Content after the last page, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const { pdf, failed, fail } = usePdfDocument(blob, ranged);
  const reader = useRef<HTMLElement>(null);
  const pages = useRef<HTMLDivElement>(null);
  const rail = useRef<HTMLDivElement>(null);
  const [sizes, setSizes] = useState<PageSize[]>();
  const [zoom, setZoom] = useState<Zoom>("fit");
  const [viewportWidth, setViewportWidth] = useState(0);
  const [visible, setVisible] = useState({ current: 0, first: 0, last: 2 });
  const [railView, setRailView] = useState({ first: 0, last: 8 });
  const [railOpen, setRailOpen] = useState<boolean>();
  const [editing, setEditing] = useState(false);
  const [selection, setSelection] = useState<Selection>();
  const [dragging, setDragging] = useState(false);
  const [sending, setSending] = useState(false);
  /**
   * Where the view is, kept across layout changes: a zoom keeps the page being read (`reading`) at the top, from as
   * far into it as the view was; a page taking its real size keeps the page at the view's top edge (`top`) still.
   */
  const anchor = useRef<{
    reading: { page: number; fraction: number };
    top: { page: number; fraction: number };
  }>(undefined);
  const anchoredScale = useRef(0);
  /** A page the person went to; it stays the one being read while all of it is in view. */
  const chosen = useRef<number>(undefined);
  /** The page a thumbnail glides the view to; it is the one being read until the view arrives or the person scrolls. */
  const gliding = useRef<number>(undefined);
  const pageCountId = useId();

  useEffect(() => {
    if (!pdf) return;
    let current = true;
    void pageSize(pdf, 1).then((first) => {
      // Every page starts at the first page's size and takes its own as it nears the view.
      if (current) setSizes(Array.from({ length: pdf.numPages }, () => first));
    }, fail);
    return () => {
      current = false;
    };
  }, [pdf, fail]);
  const onSize = useCallback((page: number, size: PageSize) => {
    setSizes((current) => {
      const known = current?.[page - 1];
      if (
        !current ||
        (known && known.width === size.width && known.height === size.height)
      )
        return current;
      const next = current.slice();
      next[page - 1] = size;
      return next;
    });
  }, []);

  // The rail opens by default where the reader has room for it beside a readable page.
  useLayoutEffect(() => {
    const element = reader.current;
    if (!element || railOpen !== undefined) return;
    setRailOpen(element.clientWidth >= widths.lg);
  }, [railOpen, sizes]);
  useLayoutEffect(() => {
    if (pages.current && !viewportWidth) setViewportWidth(pages.current.clientWidth);
  }, [sizes, viewportWidth, railOpen]);

  const widest = useMemo(
    () => sizes?.reduce((most, size) => Math.max(most, size.width), 0) || 1,
    [sizes]
  );
  const scale =
    zoom === "fit"
      ? Math.max(0.1, (viewportWidth - 2 * pageGutter) / widest)
      : zoom * CSS_PER_POINT;
  const tops = useMemo(
    () =>
      sizes
        ? offsets(
            sizes.map((size) => size.height * scale),
            pageGutter,
            pageGap
          )
        : [],
    [sizes, scale]
  );
  const thumbTops = useMemo(
    () =>
      sizes
        ? offsets(
            sizes.map(
              (size) => (size.height / size.width) * thumbWidth + 2 * thumbPadding
            ),
            thumbPadding,
            thumbGap
          )
        : [],
    [sizes]
  );

  const onMetrics = useCallback(
    ({ scrollTop, clientHeight, maxScrollTop }: ScrollAreaMetrics) => {
      if (!sizes || !tops.length) return;
      const glide = gliding.current;
      if (
        glide !== undefined &&
        Math.abs(scrollTop - Math.min(maxScrollTop, tops[glide]! - pageGutter)) < 1
      )
        gliding.current = undefined;
      const top = pageAt(tops, scrollTop);
      // The page being read is the one that fills most of the view; the earlier one on a tie.
      const bottom = scrollTop + clientHeight;
      let current = top;
      let mostShown = 0;
      for (let page = top; page < tops.length && tops[page]! < bottom; page += 1) {
        const height = sizes[page]!.height * scale;
        const overlap =
          Math.min(bottom, tops[page]! + height) - Math.max(scrollTop, tops[page]!);
        if (overlap > mostShown) {
          mostShown = overlap;
          current = page;
        }
      }
      const picked = chosen.current;
      if (picked !== undefined) {
        const end = tops[picked]! + sizes[picked]!.height * scale;
        if (
          picked === gliding.current ||
          (picked < tops.length && tops[picked]! >= scrollTop - 1 && end <= bottom + 1)
        )
          current = picked;
        else chosen.current = undefined;
      }
      const first = pageAt(tops, scrollTop - clientHeight);
      const last = pageAt(tops, scrollTop + 2 * clientHeight);
      const span = (page: number) => sizes[page]!.height * scale + pageGap;
      anchor.current = {
        reading: {
          page: current,
          fraction: Math.max(
            0,
            (scrollTop - tops[current]! + pageGutter) / span(current)
          ),
        },
        top: { page: top, fraction: (scrollTop - tops[top]! + pageGutter) / span(top) },
      };
      anchoredScale.current = scale;
      setVisible((shown) =>
        shown.current === current && shown.first === first && shown.last === last
          ? shown
          : { current, first, last }
      );
    },
    [sizes, tops, scale]
  );
  const onRailMetrics = useCallback(
    ({ scrollTop, clientHeight }: ScrollAreaMetrics) => {
      if (!thumbTops.length) return;
      const first = pageAt(thumbTops, scrollTop - clientHeight);
      const last = pageAt(thumbTops, scrollTop + 2 * clientHeight);
      setRailView((shown) =>
        shown.first === first && shown.last === last ? shown : { first, last }
      );
    },
    [thumbTops]
  );

  // A zoom or a page's real size moves the pages; the view keeps its place in them.
  useLayoutEffect(() => {
    const viewport = pages.current;
    if (!viewport || !anchor.current || !sizes || !tops.length) return;
    const { page, fraction } =
      anchoredScale.current === scale ? anchor.current.top : anchor.current.reading;
    viewport.scrollTop =
      tops[page]! - pageGutter + fraction * (sizes[page]!.height * scale + pageGap);
    // Setting the place stops a glide; it goes on to where its page now is.
    const glide = gliding.current;
    if (glide !== undefined)
      viewport.scrollTo({ top: tops[glide]! - pageGutter, behavior: "smooth" });
  }, [tops, sizes, scale]);

  /** Keys jump; a thumbnail glides, so the person sees which way the document went. */
  const scrollToPage = (index: number, glide = false) => {
    const viewport = pages.current;
    if (!viewport || !tops.length) return;
    const page = Math.max(0, Math.min(tops.length - 1, index));
    const top = tops[page]! - pageGutter;
    if (glide && !isReducedMotionEnabled()) {
      // A far page arrives from one view away: the glide keeps its direction without drawing every page between.
      const away = top - viewport.scrollTop;
      if (Math.abs(away) > viewport.clientHeight)
        viewport.scrollTop = top - Math.sign(away) * viewport.clientHeight;
      gliding.current = page;
      viewport.scrollTo({ top, behavior: "smooth" });
    } else {
      gliding.current = undefined;
      viewport.scrollTop = top;
    }
    setVisible((shown) => ({ ...shown, current: page }));
    // Pages that all fit do not scroll: the chosen page is the one being read.
    chosen.current = page;
    const kept = { page, fraction: 0 };
    anchor.current = { reading: kept, top: anchor.current?.top ?? kept };
  };

  const stopGlide = () => {
    gliding.current = undefined;
  };

  // The thumbnail of the page being read stays in the rail's view, placed from the rail's geometry so it need not be
  // mounted yet; a thumbnail taking its page's real size leaves the rail where the person scrolled it.
  const currentPage = visible.current;
  const railGeometry = useRef(thumbTops);
  railGeometry.current = thumbTops;
  useLayoutEffect(() => {
    const viewport = rail.current;
    const railTops = railGeometry.current;
    const top = railTops[currentPage];
    if (!railOpen || !viewport || top === undefined) return;
    const bottom = railTops[currentPage + 1] ?? top + viewport.clientHeight;
    if (top - thumbPadding < viewport.scrollTop)
      viewport.scrollTop = top - thumbPadding;
    else if (bottom > viewport.scrollTop + viewport.clientHeight)
      viewport.scrollTop = bottom - viewport.clientHeight;
  }, [railOpen, currentPage]);
  /** A thumbnail Up or Down reached: it takes focus once it is mounted. */
  const focusThumbnail = useRef<number>(undefined);
  useEffect(() => {
    const page = focusThumbnail.current;
    if (page === undefined) return;
    focusThumbnail.current = undefined;
    rail.current
      ?.querySelector<HTMLElement>(`[data-thumbnail="${page + 1}"]`)
      ?.focus({ preventScroll: true });
  });

  const stopEditing = () => {
    setEditing(false);
    setSelection(undefined);
    setDragging(false);
  };
  const pagePoint = (event: ReactPointerEvent<HTMLElement>, size: PageSize) => {
    const box = event.currentTarget.getBoundingClientRect();
    return [
      clamp((event.clientX - box.left) / scale, size.width),
      clamp((event.clientY - box.top) / scale, size.height),
    ] as [number, number];
  };
  const send = async (prompt: string) => {
    if (!pdf || !selection || !onRequestEdit || sending) return;
    setSending(true);
    try {
      onRequestEdit(
        await capturePdfRegion(pdf, {
          prompt,
          page: selection.page,
          region: selectionRect(selection),
          ownerDocument: reader.current?.ownerDocument ?? window.document,
        })
      );
      stopEditing();
      reader.current?.focus({ preventScroll: true });
    } catch {
      toast.error(messages.file_preview_pdf_edit_failed());
    } finally {
      setSending(false);
    }
  };

  if (failed) return <p role="alert">{messages.file_preview_failed()}</p>;
  if (!pdf || !sizes)
    return (
      <div className="flex min-h-0 flex-1 items-center justify-center">
        <FilePreviewLoading />
      </div>
    );
  const pageCount = sizes.length;
  // Only pages and thumbnails near the view, the page being read and the one being asked about are mounted; the
  // rest are space in a column of the known height, so a long document costs what its view shows.
  const mountedPages = mountedIndices(pageCount, visible.first, visible.last, [
    visible.current,
    ...(selection ? [selection.page - 1] : []),
  ]);
  const mountedThumbnails = mountedIndices(pageCount, railView.first, railView.last, [
    visible.current,
  ]);
  const pagesHeight = sizes.length
    ? tops[pageCount - 1]! + sizes[pageCount - 1]!.height * scale + pageGutter
    : 0;
  const railHeight = sizes.length
    ? thumbTops[pageCount - 1]! +
      (sizes[pageCount - 1]!.height / sizes[pageCount - 1]!.width) * thumbWidth +
      3 * thumbPadding
    : 0;
  const percent = Math.round((scale / CSS_PER_POINT) * 100);
  const railToggle = (
    <Button
      aria-expanded={Boolean(railOpen)}
      aria-label={
        railOpen
          ? messages.file_preview_pdf_hide_pages()
          : messages.file_preview_pdf_show_pages()
      }
      hierarchy="tertiary-gray"
      iconLeading={<PanelLeftIcon />}
      iconOnly
      size="xs"
      onPress={() => setRailOpen((open) => !open)}
    />
  );
  const controls = (
    <>
      <MenuTrigger>
        <Button
          aria-label={messages.file_preview_pdf_zoom({ percent })}
          className="tabular-nums"
          hierarchy="tertiary-gray"
          iconTrailing={<ChevronDownSmallIcon />}
          size="xs"
        >
          {`${percent}%`}
        </Button>
        <MenuPopover placement="bottom end">
          <Menu
            aria-label={messages.file_preview_pdf_zoom({ percent })}
            disallowEmptySelection
            onSelectionChange={(keys) => {
              if (keys === "all") return;
              const [key] = Array.from(keys);
              if (key === undefined) return;
              setZoom(key === "fit" ? "fit" : (Number(key) as Zoom));
            }}
            selectedKeys={[String(zoom)]}
            selectionMode="single"
          >
            <MenuItem
              id="fit"
              selectionIndicator="check"
              textValue={messages.file_preview_pdf_zoom_fit()}
            >
              {messages.file_preview_pdf_zoom_fit()}
            </MenuItem>
            {zoomSteps.map((step) => (
              <MenuItem
                id={String(step)}
                key={step}
                selectionIndicator="check"
                textValue={`${step * 100}%`}
              >
                <span className="tabular-nums">{`${step * 100}%`}</span>
              </MenuItem>
            ))}
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      {onRequestEdit ? (
        <Tooltip content={messages.file_preview_pdf_request_edits()} placement="bottom">
          <ShellIconButtonControl
            aria-label={messages.file_preview_pdf_request_edits()}
            aria-pressed={editing}
            className={cx(
              editing && "bg-button-tertiary-bg-hover text-fg-brand-primary"
            )}
            data-testid="file-preview-pdf-request-edits"
            icon={<SquareCursorIcon className="comma-input-icon" />}
            onPress={() => (editing ? stopEditing() : setEditing(true))}
          />
        </Tooltip>
      ) : null}
    </>
  );

  return (
    // The document reader needs focus for page navigation without a global listener.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex
    <section
      ref={reader}
      aria-label={messages.file_preview_pdf_navigation()}
      aria-keyshortcuts="ArrowLeft ArrowRight PageUp PageDown Home End"
      // A reader is a focusable region for local keyboard navigation.
      // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex
      tabIndex={0}
      className="group/reader flex min-h-0 min-w-0 flex-1 outline-none"
      onKeyDown={(event) => {
        if (event.defaultPrevented) return;
        // The zoom and Request edits controls render in the file toolbar: their keys stay theirs, except Escape.
        const inReader =
          event.target instanceof Node &&
          Boolean(reader.current?.contains(event.target));
        if (!inReader && event.key !== "Escape") return;
        gliding.current = undefined;
        if (event.key === "Escape" && editing) {
          event.preventDefault();
          if (selection) {
            setSelection(undefined);
            reader.current?.focus({ preventScroll: true });
          } else stopEditing();
          return;
        }
        if (
          event.altKey ||
          event.ctrlKey ||
          event.metaKey ||
          event.shiftKey ||
          event.nativeEvent.isComposing ||
          pageCount <= 1 ||
          (event.target instanceof Element &&
            event.target.closest(
              'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="slider"], [role="spinbutton"]'
            ))
        )
          return;
        // In the thumbnail list Up and Down step through pages, as in a source list; on the pages they scroll.
        const inRail =
          event.target instanceof Node && Boolean(rail.current?.contains(event.target));
        // Pages wider than the view scroll sideways with Left and Right, as any wide content does.
        const pagesView = pages.current;
        if (
          !inRail &&
          (event.key === "ArrowLeft" || event.key === "ArrowRight") &&
          pagesView &&
          pagesView.scrollWidth > pagesView.clientWidth
        )
          return;
        const target =
          event.key === "ArrowLeft" ||
          event.key === "PageUp" ||
          (inRail && event.key === "ArrowUp")
            ? visible.current - 1
            : event.key === "ArrowRight" ||
                event.key === "PageDown" ||
                (inRail && event.key === "ArrowDown")
              ? visible.current + 1
              : event.key === "Home"
                ? 0
                : event.key === "End"
                  ? pageCount - 1
                  : undefined;
        if (target === undefined) return;
        event.preventDefault();
        event.stopPropagation();
        scrollToPage(target);
        // Focus follows the chosen thumbnail; the rail keeps it in view.
        if (inRail)
          focusThumbnail.current = Math.max(0, Math.min(pageCount - 1, target));
      }}
    >
      {toolbarSlot ? createPortal(controls, toolbarSlot) : null}
      {railOpen ? (
        <nav
          aria-label={messages.file_preview_pdf_thumbnails()}
          className="flex w-11xl shrink-0 flex-col border-r-[0.5px] border-primary bg-primary"
        >
          <div className="flex shrink-0 items-center justify-between gap-xs py-sm pr-sm pl-lg">
            <span className="text-sm text-tertiary">
              {messages.file_preview_pdf_pages({
                count: pageCount,
                formattedCount: String(pageCount),
              })}
            </span>
            {railToggle}
          </div>
          <ScrollArea
            className="min-h-0 flex-1"
            edgeEffect="none"
            onMetricsChange={onRailMetrics}
            ref={rail}
          >
            <div className="relative" style={{ height: railHeight }}>
              {mountedThumbnails.map((index) => {
                const size = sizes[index]!;
                const page = index + 1;
                const selected = index === visible.current;
                return (
                  <button
                    aria-current={selected ? "page" : undefined}
                    // The list is one stop in the tab order, at the page being read.
                    tabIndex={selected ? 0 : -1}
                    aria-label={messages.file_preview_pdf_thumbnail({ page })}
                    className={cx(
                      "absolute flex items-start gap-sm rounded-lg p-sm text-left outline-none focus-visible:shadow-focus-gray",
                      // The selection is blue while the reader has focus, as a source list is; gray once focus is elsewhere.
                      selected
                        ? "bg-tertiary group-focus-within/reader:bg-brand-primary"
                        : "hover:bg-secondary-hover"
                    )}
                    data-thumbnail={page}
                    key={page}
                    onClick={() => scrollToPage(index, true)}
                    style={{
                      top: thumbTops[index],
                      left: thumbPadding,
                      right: thumbPadding,
                      height:
                        (size.height / size.width) * thumbWidth + 2 * thumbPadding,
                    }}
                    type="button"
                  >
                    <span
                      className={cx(
                        "min-w-xl shrink-0 text-right text-xs tabular-nums",
                        selected
                          ? "text-primary group-focus-within/reader:text-brand-secondary"
                          : "text-tertiary"
                      )}
                    >
                      {page}
                    </span>
                    <span
                      className="relative block w-9xl shrink-0 overflow-hidden rounded-xs bg-white ring-[0.5px] ring-primary"
                      style={{ height: (size.height / size.width) * thumbWidth }}
                    >
                      <PdfPageCanvas
                        active={index >= railView.first && index <= railView.last}
                        onError={fail}
                        onSize={onSize}
                        page={page}
                        pdf={pdf}
                        width={thumbWidth}
                      />
                    </span>
                  </button>
                );
              })}
            </div>
          </ScrollArea>
        </nav>
      ) : null}
      <div
        className="relative flex min-w-0 flex-1 flex-col bg-secondary"
        // The person's own scroll takes over from a glide.
        onPointerDown={stopGlide}
        onTouchStart={stopGlide}
        onWheel={stopGlide}
      >
        <ScrollArea
          className="min-h-0 flex-1"
          contentClassName="flex min-h-full w-max min-w-full flex-col"
          edgeEffect="none"
          onMetricsChange={onMetrics}
          onViewportResize={() => {
            const next = pages.current?.clientWidth ?? 0;
            return () => setViewportWidth(next);
          }}
          orientation="both"
          ref={pages}
        >
          <div
            className="relative min-w-full"
            style={{ height: pagesHeight, width: widest * scale + 2 * pageGutter }}
          >
            {mountedPages.map((index) => {
              const size = sizes[index]!;
              const page = index + 1;
              // Fit width draws nothing until the view's width is known.
              const active =
                (zoom !== "fit" || viewportWidth > 0) &&
                index >= visible.first &&
                index <= visible.last;
              const selected = selection?.page === page;
              return (
                <div
                  className={cx(
                    "absolute left-1/2 bg-white shadow-xs ring-[0.5px] ring-primary",
                    editing && "cursor-crosshair touch-none select-none",
                    selected && "z-[1]"
                  )}
                  data-testid="file-preview-pdf-page"
                  key={page}
                  onPointerDown={(event) => {
                    if (
                      event.target instanceof Element &&
                      event.target.closest("[data-pdf-edit-composer]")
                    )
                      return;
                    if (!editing || event.button !== 0) {
                      reader.current?.focus({ preventScroll: true });
                      return;
                    }
                    event.preventDefault();
                    event.currentTarget.setPointerCapture(event.pointerId);
                    const point = pagePoint(event, size);
                    setSelection({ page, from: point, to: point });
                    setDragging(true);
                  }}
                  onPointerMove={(event) => {
                    if (!dragging || !selected) return;
                    const point = pagePoint(event, size);
                    setSelection((current) => current && { ...current, to: point });
                  }}
                  onPointerUp={() => {
                    if (!dragging) return;
                    setDragging(false);
                    if (!selection) return;
                    const rect = selectionRect(selection);
                    if (rect.width < minRegion || rect.height < minRegion)
                      setSelection(undefined);
                  }}
                  onPointerCancel={() => {
                    setDragging(false);
                    setSelection(undefined);
                  }}
                  style={{
                    top: tops[index],
                    width: size.width * scale,
                    height: size.height * scale,
                    marginLeft: (-size.width * scale) / 2,
                  }}
                >
                  <PdfPageCanvas
                    active={active}
                    label={messages.file_preview_pdf_page({ page })}
                    onError={fail}
                    onSize={onSize}
                    page={page}
                    pdf={pdf}
                    width={size.width * scale}
                  />
                  {selected && selection ? (
                    <PdfRegionEditor
                      key={`${selection.from[0]}:${selection.from[1]}`}
                      onSend={(prompt) => void send(prompt)}
                      pageSize={size}
                      dragging={dragging}
                      onCancel={() => {
                        setSelection(undefined);
                        reader.current?.focus({ preventScroll: true });
                      }}
                      pending={sending}
                      scale={scale}
                      selection={selection}
                    />
                  ) : null}
                </div>
              );
            })}
          </div>
          {children}
        </ScrollArea>
        {railOpen ? null : (
          // The whole pill opens the rail, not only its panel icon. The icon keeps
          // the xs tertiary-gray icon-only Button look (Button/styles.ts).
          <AriaButton
            aria-describedby={pageCountId}
            aria-expanded={false}
            aria-label={messages.file_preview_pdf_show_pages()}
            className="absolute top-sm left-sm flex items-center gap-xs rounded-lg bg-primary py-xxs pr-md pl-xxs text-sm text-secondary tabular-nums shadow-xs ring-[0.5px] ring-primary outline-none transition-colors hover:bg-button-tertiary-bg-hover focus-visible:shadow-focus-gray"
            onPress={() => setRailOpen(true)}
          >
            <span
              aria-hidden
              className="inline-flex h-4xl w-4xl shrink-0 items-center justify-center p-sm text-button-tertiary-fg [&_svg]:size-4"
            >
              <PanelLeftIcon />
            </span>
            <span aria-hidden>
              {messages.file_preview_page_count({
                page: visible.current + 1,
                total: pageCount,
              })}
            </span>
            <span className="sr-only" id={pageCountId}>
              {messages.file_preview_page({
                page: visible.current + 1,
                total: pageCount,
              })}
            </span>
          </AriaButton>
        )}
        {editing && !selection ? (
          <output className="pointer-events-none absolute bottom-lg left-1/2 m-0 -translate-x-1/2 rounded-full bg-primary px-lg py-xs text-sm text-secondary shadow-xs ring-[0.5px] ring-primary">
            {messages.file_preview_pdf_edit_hint()}
          </output>
        ) : null}
      </div>
    </section>
  );
}
