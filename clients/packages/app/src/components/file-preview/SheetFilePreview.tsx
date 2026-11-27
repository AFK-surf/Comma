import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import {
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  PreviewMessage,
  PreviewNotice,
  usePreviewLinkHandlers,
} from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import {
  opensInBrowser,
  wholeFileOf,
  zipWithinLimits,
  type WholeRead,
} from "./wholeFile";

/** The largest workbook the preview reads: it is a ZIP archive, read whole before a sheet shows. */
export const sheetPreviewMaxBytes = 32 * 1024 * 1024;
/** What the sidebar draws of a sheet: a sheet larger than this is cut, and says so. */
export const sheetPreviewRows = 500;
export const sheetPreviewColumns = 50;

type WorkBook = import("xlsx").WorkBook;
type WorkSheet = import("xlsx").WorkSheet;
type CellObject = import("xlsx").CellObject;

const isZipArchive = (bytes: Uint8Array) =>
  bytes.length >= 4 &&
  bytes[0] === 0x50 &&
  bytes[1] === 0x4b &&
  bytes[2] === 0x03 &&
  bytes[3] === 0x04;

/** Legacy binary .xls (OLE2 Compound File Binary header). */
const isOle2Workbook = (bytes: Uint8Array) =>
  bytes.length >= 8 &&
  bytes[0] === 0xd0 &&
  bytes[1] === 0xcf &&
  bytes[2] === 0x11 &&
  bytes[3] === 0xe0 &&
  bytes[4] === 0xa1 &&
  bytes[5] === 0xb1 &&
  bytes[6] === 0x1a &&
  bytes[7] === 0xe1;

/**
 * A workbook's visible sheets, each read up to `rows` rows. Cells are read as saved: a formula is not computed again,
 * and a value shows as Excel formatted it.
 */
export async function readWorkbook(bytes: Uint8Array<ArrayBuffer>, rows: number) {
  if (isZipArchive(bytes)) {
    if (!zipWithinLimits(bytes)) throw new Error("archive out of bounds");
  } else if (!isOle2Workbook(bytes)) {
    throw new Error("not a workbook");
  }
  const { read } = await import("xlsx");
  const book: WorkBook = read(bytes, {
    type: "array",
    sheetRows: rows,
    // Column widths and hidden columns are read with the cells' styles.
    cellStyles: true,
    cellFormula: false,
    cellHTML: false,
    bookVBA: false,
  });
  const visible = book.SheetNames.filter(
    (_, index) => !book.Workbook?.Sheets?.[index]?.Hidden
  );
  if (visible.length === 0) throw new Error("no sheets");
  return visible.map((name) => ({ name, sheet: book.Sheets[name]! }));
}

/** A column's letters: A, B, …, Z, AA, … */
const columnName = (index: number): string =>
  (index >= 26 ? columnName(Math.floor(index / 26) - 1) : "") +
  String.fromCharCode(65 + (index % 26));

/** A cell's place from its address (A1), from 0. */
const decodeCell = (cell: string) => {
  const [, letters = "A", digits = "1"] = /^\$?([A-Z]+)\$?(\d+)$/u.exec(cell) ?? [];
  let column = 0;
  for (const letter of letters) column = column * 26 + letter.charCodeAt(0) - 64;
  return { r: Number(digits) - 1, c: column - 1 };
};

/** A range's first and last cells from its address (A1:C7). */
const decode = (ref: string) => {
  const [start, end = start] = ref.split(":");
  return { s: decodeCell(start!), e: decodeCell(end!) };
};

/** A cell's text as Excel showed it. */
const cellText = (cell: CellObject | undefined) =>
  cell === undefined || cell.t === "z"
    ? ""
    : (cell.w ?? (cell.v === undefined ? "" : String(cell.v)));

/** Excel's default column width, in pixels. */
const defaultColumnWidth = 64;

/**
 * A sheet drawn as a table from A1, with its columns' letters and its rows' numbers, up to `rows` rows and `columns`
 * columns: merged cells span, hidden rows and columns are left out, numbers and dates are set to the right, and a link
 * keeps its address only when it opens in the browser. A last column with no width takes what is left of a wider
 * container, so the header and the gridlines run to its edge. `cut` says what was left out of a larger sheet, and
 * `empty` is a sheet with no cells.
 */
export function drawSheet(
  sheet: WorkSheet,
  ownerDocument: Document,
  rows: number,
  columns: number
): {
  table: HTMLTableElement;
  cut?: { rows: number; columns: number } | undefined;
  empty: boolean;
} {
  const used = sheet["!ref"] ? decode(sheet["!ref"]) : undefined;
  const full = sheet["!fullref"] ? decode(sheet["!fullref"]) : used;
  const lastRow = Math.min((used?.e.r ?? 0) + 1, rows);
  const lastColumn = Math.min((used?.e.c ?? 0) + 1, columns);
  const cut =
    full && (full.e.r + 1 > rows || full.e.c + 1 > columns)
      ? { rows: Math.min(full.e.r + 1, rows), columns: Math.min(full.e.c + 1, columns) }
      : undefined;
  const cols = sheet["!cols"] ?? [];
  const hiddenRows = sheet["!rows"] ?? [];
  const shownColumns = [...Array(lastColumn).keys()].filter((c) => !cols[c]?.hidden);

  // Each merge's first cell spans it; the cells it covers are not drawn.
  const spans = new Map<string, { rowSpan: number; colSpan: number }>();
  const covered = new Set<string>();
  for (const merge of sheet["!merges"] ?? []) {
    spans.set(`${merge.s.r}:${merge.s.c}`, {
      rowSpan: Math.min(merge.e.r, lastRow - 1) - merge.s.r + 1,
      colSpan: shownColumns.filter((c) => c >= merge.s.c && c <= merge.e.c).length,
    });
    for (let r = merge.s.r; r <= merge.e.r; r += 1)
      for (let c = merge.s.c; c <= merge.e.c; c += 1)
        if (r !== merge.s.r || c !== merge.s.c) covered.add(`${r}:${c}`);
  }

  const make = <K extends keyof HTMLElementTagNameMap>(tag: K, className?: string) => {
    const made = ownerDocument.createElement(tag);
    if (className) made.className = className;
    return made;
  };
  const table = make("table", "comma-sheet");
  const widths = make("colgroup");
  widths.append(make("col", "comma-sheet-row-number"));
  for (const c of shownColumns) {
    const col = make("col");
    col.style.width = `${Math.round(cols[c]?.wpx ?? defaultColumnWidth)}px`;
    widths.append(col);
  }
  widths.append(make("col", "comma-sheet-filler"));
  table.append(widths);
  const filler = (tag: "th" | "td") => {
    const cell = make(tag, "comma-sheet-filler");
    cell.setAttribute("aria-hidden", "true");
    return cell;
  };
  const head = make("thead");
  const letters = make("tr");
  letters.append(make("th", "comma-sheet-corner"));
  for (const c of shownColumns) {
    const letter = make("th");
    letter.scope = "col";
    letter.textContent = columnName(c);
    letters.append(letter);
  }
  letters.append(filler("th"));
  head.append(letters);
  table.append(head);

  const dense = (sheet as { "!data"?: CellObject[][] })["!data"];
  const body = make("tbody");
  for (let r = 0; r < lastRow; r += 1) {
    if (hiddenRows[r]?.hidden) continue;
    const row = make("tr");
    const number = make("th");
    number.scope = "row";
    number.textContent = String(r + 1);
    row.append(number);
    for (const c of shownColumns) {
      const key = `${r}:${c}`;
      if (covered.has(key)) continue;
      const cell: CellObject | undefined = dense
        ? dense[r]?.[c]
        : (sheet[`${columnName(c)}${r + 1}`] as CellObject | undefined);
      const td = make("td");
      const span = spans.get(key);
      if (span) {
        if (span.rowSpan > 1) td.rowSpan = span.rowSpan;
        if (span.colSpan > 1) td.colSpan = span.colSpan;
      }
      if (cell?.t === "n" || cell?.t === "d") td.dataset.number = "true";
      const text = cellText(cell);
      const target = cell?.l?.Target;
      if (target && opensInBrowser(target)) {
        const link = make("a");
        link.href = target;
        link.textContent = text;
        td.append(link);
      } else td.textContent = text;
      // A value cut at its column's edge reads whole on hover.
      if (text) td.title = text;
      row.append(td);
    }
    row.append(filler("td"));
    body.append(row);
  }
  table.append(body);
  return {
    table,
    cut,
    empty: used === undefined,
  };
}

/** A workbook read for the preview: its visible sheets, in order. */
type Workbook = Awaited<ReturnType<typeof readWorkbook>>;

type SheetState =
  | { status: "loading" }
  | { status: "too_large" | "failed" }
  | { status: "ready"; sheets: Workbook };

/**
 * An Excel or OpenDocument workbook (.xlsx, .xls, .xlsm, .xlsb, .ods): one sheet at a time as a grid that fills the panel and scrolls both ways, with its column
 * letters and row numbers fixed at the edges, and the visible sheets as tabs along the bottom, as a spreadsheet app
 * shows them. The file is read whole, up to `sheetPreviewMaxBytes`.
 */
export function SheetFilePreview({
  blob,
  ranged,
  onOpenBrowser,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the sheet, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const [state, setState] = useState<SheetState>({ status: "loading" });
  const [active, setActive] = useState(0);
  const linkHandlers = usePreviewLinkHandlers(onOpenBrowser);
  const tabsId = useId();

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    setState({ status: "loading" });
    setActive(0);
    void (async () => {
      try {
        const read: WholeRead = await wholeFileOf(
          { blob, ranged },
          signal,
          sheetPreviewMaxBytes
        );
        if (signal.aborted) return;
        if ("error" in read) return setState({ status: read.error });
        const sheets = await readWorkbook(read.bytes, sheetPreviewRows);
        if (!signal.aborted) setState({ status: "ready", sheets });
      } catch {
        if (!signal.aborted) setState({ status: "failed" });
      }
    })();
    return () => controller.abort();
  }, [blob, ranged]);

  const sheets = state.status === "ready" ? state.sheets : undefined;
  const sheet = sheets?.[active]?.sheet;
  const drawn = useMemo(
    () =>
      sheet && typeof document !== "undefined"
        ? drawSheet(sheet, document, sheetPreviewRows, sheetPreviewColumns)
        : undefined,
    [sheet]
  );
  const container = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const element = container.current;
    if (!element) return undefined;
    if (drawn && !drawn.empty) element.replaceChildren(drawn.table);
    // Another sheet opens at its A1, not at the last sheet's offset.
    element.closest<HTMLElement>("[data-slot='scroll-area-viewport']")?.scrollTo(0, 0);
    return () => element.replaceChildren();
  }, [drawn]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {drawn?.cut ? (
        <PreviewNotice testId="file-preview-sheet-cut">
          {messages.file_preview_sheet_cut({
            rows: drawn.cut.rows,
            columns: drawn.cut.columns,
          })}
        </PreviewNotice>
      ) : null}
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        contentClassName="flex min-h-full w-max min-w-full flex-col"
        edgeEffect="none"
        orientation="both"
      >
        <div className="flex min-h-full flex-1 flex-col">
          {state.status === "loading" ? <FilePreviewLoading /> : null}
          {state.status === "too_large" || state.status === "failed" ? (
            <PreviewMessage alert>
              {state.status === "too_large"
                ? messages.file_preview_office_too_large({ limit: 32 })
                : messages.file_preview_failed()}
            </PreviewMessage>
          ) : null}
          {drawn?.empty ? (
            <PreviewMessage testId="file-preview-sheet-empty">
              {messages.file_preview_sheet_empty()}
            </PreviewMessage>
          ) : null}
          <div
            aria-labelledby={sheets ? `${tabsId}-${active}` : undefined}
            data-testid="file-preview-sheet"
            id={`${tabsId}-panel`}
            ref={container}
            role={sheets ? "tabpanel" : undefined}
            {...linkHandlers}
          />
          {children}
        </div>
      </ScrollArea>
      {sheets ? (
        <SheetTabs
          active={active}
          baseId={tabsId}
          names={sheets.map(({ name }) => name)}
          onSelect={setActive}
        />
      ) : null}
    </div>
  );
}

/**
 * The workbook's visible sheets as tabs along the bottom of the grid, as a spreadsheet app has them. The tabs scroll
 * across when there are more than fit; the arrow keys, Home and End move between them.
 */
function SheetTabs({
  baseId,
  names,
  active,
  onSelect,
}: {
  /** The tabs' ids are `${baseId}-${index}`; the sheet's panel is `${baseId}-panel`. */
  baseId: string;
  names: string[];
  active: number;
  onSelect: (index: number) => void;
}) {
  const messages = useCommaMessages();
  const select = (index: number) => {
    onSelect(index);
    const tab = document.getElementById(`${baseId}-${index}`);
    tab?.focus();
    tab?.scrollIntoView({ block: "nearest", inline: "nearest" });
  };
  return (
    <div className="comma-sheet-tabs" data-testid="file-preview-sheet-tabs">
      <ScrollArea
        className="min-w-0 flex-1"
        contentClassName="flex h-full"
        edgeEffect="mask"
        orientation="horizontal"
      >
        <div
          aria-label={messages.file_preview_sheet_tabs()}
          className="flex items-stretch"
          role="tablist"
        >
          {names.map((name, index) => {
            const selected = index === active;
            return (
              <button
                aria-controls={`${baseId}-panel`}
                aria-selected={selected}
                className="comma-sheet-tab"
                id={`${baseId}-${index}`}
                // Sheet names are unique within a workbook.
                key={name}
                onClick={() => select(index)}
                onKeyDown={(event) => {
                  const last = names.length - 1;
                  const next =
                    event.key === "ArrowRight"
                      ? Math.min(index + 1, last)
                      : event.key === "ArrowLeft"
                        ? Math.max(index - 1, 0)
                        : event.key === "Home"
                          ? 0
                          : event.key === "End"
                            ? last
                            : undefined;
                  if (next === undefined) return;
                  event.preventDefault();
                  select(next);
                }}
                role="tab"
                tabIndex={selected ? 0 : -1}
                title={name}
                type="button"
              >
                <span className="truncate">{name}</span>
              </button>
            );
          })}
        </div>
      </ScrollArea>
    </div>
  );
}
