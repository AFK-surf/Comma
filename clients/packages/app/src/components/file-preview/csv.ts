import { opensInBrowser } from "./wholeFile";

/** How much of a delimited file the preview reads: a longer file shows its parsed prefix and says so. */
export const csvPreviewMaxBytes = 2 * 1024 * 1024;
/** What the preview draws of a CSV/TSV file: a larger table is cut, and says so. */
export const csvPreviewRows = 500;
export const csvPreviewColumns = 50;

export type CsvDelimiter = "," | "\t" | ";";

export interface ParsedCsv {
  headers: string[];
  rows: string[][];
  columnCount: number;
  columnWidths: number[];
  numericColumns: boolean[];
  rowsCut: boolean;
  columnsCut: boolean;
}

const minColumnWidth = 72;
const maxColumnWidth = 320;
const numericValue =
  /^[+-]?(?:[$€£¥]\s*)?(?:0(?:\.\d+)?|[1-9]\d{0,2}(?:,\d{3})+|[1-9]\d*(?:\.\d+)?)%?$/u;
const cellUrl = /^(?:https?:\/\/|mailto:)[^\s]+$/iu;

/** Whether a cell's whole text is a link that may open in the browser. */
export function isCellUrl(value: string): boolean {
  const trimmed = value.trim();
  return cellUrl.test(trimmed) && opensInBrowser(trimmed);
}

/** Drops an incomplete trailing UTF-8 multibyte sequence caused by slicing a stream at a byte boundary. */
function trimIncompleteUtf8Tail(bytes: Uint8Array): Uint8Array {
  const len = bytes.length;
  if (len === 0) return bytes;
  let continuations = 0;
  while (continuations < 3 && continuations < len) {
    const b = bytes[len - 1 - continuations]!;
    if ((b & 0xc0) === 0x80) {
      continuations += 1;
    } else {
      break;
    }
  }
  const leadIndex = len - 1 - continuations;
  if (leadIndex < 0) return bytes.subarray(0, len - continuations);
  const lead = bytes[leadIndex]!;
  let expected = 1;
  if ((lead & 0x80) === 0) expected = 1;
  else if ((lead & 0xe0) === 0xc0) expected = 2;
  else if ((lead & 0xf0) === 0xe0) expected = 3;
  else if ((lead & 0xf8) === 0xf0) expected = 4;
  else return bytes;
  const actual = continuations + 1;
  return actual < expected ? bytes.subarray(0, leadIndex) : bytes;
}

/**
 * Decodes CSV/TSV bytes into text: respects UTF-8/UTF-16 BOMs, prefers strict UTF-8, and falls back to GB18030
 * (common for legacy Excel Chinese CSV exports) when the bytes are not valid UTF-8.
 */
export function decodeCsvBytes(bytes: Uint8Array, truncated = false): string {
  if (bytes.length === 0) return "";
  if (
    bytes.length >= 3 &&
    bytes[0] === 0xef &&
    bytes[1] === 0xbb &&
    bytes[2] === 0xbf
  ) {
    const slice = truncated
      ? trimIncompleteUtf8Tail(bytes.subarray(3))
      : bytes.subarray(3);
    return new TextDecoder("utf-8").decode(slice);
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    const payload = bytes.subarray(2);
    const aligned =
      truncated && payload.length % 2 === 1
        ? payload.subarray(0, payload.length - 1)
        : payload;
    return new TextDecoder("utf-16le").decode(aligned);
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    const payload = bytes.subarray(2);
    const aligned =
      truncated && payload.length % 2 === 1
        ? payload.subarray(0, payload.length - 1)
        : payload;
    return new TextDecoder("utf-16be").decode(aligned);
  }
  const utf8Slice = truncated ? trimIncompleteUtf8Tail(bytes) : bytes;
  try {
    return new TextDecoder("utf-8", { fatal: true })
      .decode(utf8Slice)
      .replace(/^\uFEFF/u, "");
  } catch {
    try {
      return new TextDecoder("gb18030").decode(bytes).replace(/^\uFEFF/u, "");
    } catch {
      return new TextDecoder("utf-8").decode(utf8Slice).replace(/^\uFEFF/u, "");
    }
  }
}

/** Counts unquoted occurrences of `delimiter` in a single line. */
function countUnquoted(line: string, delimiter: string): number {
  let inQuotes = false;
  let count = 0;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i]!;
    if (inQuotes) {
      if (ch === '"') {
        if (line[i + 1] === '"') i += 1;
        else inQuotes = false;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === delimiter) {
      count += 1;
    }
  }
  return count;
}

/** Picks the delimiter from the file's type, falling back to `;` for semicolon-delimited CSVs with no commas. */
export function detectCsvDelimiter(
  text: string,
  fileName: string,
  mimeType = ""
): CsvDelimiter {
  const baseName = fileName.split("/").at(-1)?.toLowerCase() ?? "";
  const mediaType = mimeType.split(";")[0]?.trim().toLowerCase() ?? "";
  if (baseName.endsWith(".tsv") || mediaType === "text/tab-separated-values")
    return "\t";
  const sampleLines = text.split(/\r\n|\n|\r/u, 6).filter((line) => line.length > 0);
  if (sampleLines.length === 0) return ",";
  const firstCommas = countUnquoted(sampleLines[0]!, ",");
  if (firstCommas > 0) return ",";
  const firstSemicolons = countUnquoted(sampleLines[0]!, ";");
  if (
    firstSemicolons > 0 &&
    sampleLines.length >= 2 &&
    countUnquoted(sampleLines[1]!, ",") === 0 &&
    countUnquoted(sampleLines[1]!, ";") === firstSemicolons
  )
    return ";";
  return ",";
}

/** Visual character width for column sizing: wide/CJK glyphs count as ~1.85 ASCII columns. */
function displayLength(value: string): number {
  const firstLine = value.split(/\r\n|\n|\r/u, 1)[0] ?? "";
  let total = 0;
  for (const ch of firstLine) {
    const code = ch.codePointAt(0) ?? 0;
    total += code >= 0x1100 ? 1.85 : 1;
  }
  return total;
}

/**
 * Parses RFC 4180 CSV/TSV text into a header row and bounded data rows, estimating column widths and numeric columns
 * for tabular display.
 */
export function parseCsv(
  text: string,
  {
    delimiter = ",",
    maxRows = csvPreviewRows,
    maxColumns = csvPreviewColumns,
    byteTruncated = false,
  }: {
    delimiter?: CsvDelimiter;
    maxRows?: number;
    maxColumns?: number;
    byteTruncated?: boolean;
  } = {}
): ParsedCsv {
  if (text.length === 0) {
    return {
      headers: [],
      rows: [],
      columnCount: 0,
      columnWidths: [],
      numericColumns: [],
      rowsCut: false,
      columnsCut: false,
    };
  }

  // Allow 1 header row + `maxRows` data rows; hitting row `maxRows + 2` proves truncation without scanning further.
  const totalRowLimit = maxRows + 1;
  const allRows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  let fieldStarted = false;
  let currentColumnCount = 0;
  let rowsCut = false;
  let columnsCut = false;

  const finishField = () => {
    if (currentColumnCount < maxColumns) row.push(field);
    else columnsCut = true;
    currentColumnCount += 1;
    field = "";
    fieldStarted = false;
  };

  const finishRow = () => {
    finishField();
    if (allRows.length >= totalRowLimit) {
      rowsCut = true;
      return false;
    }
    allRows.push(row);
    row = [];
    currentColumnCount = 0;
    return true;
  };

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i]!;
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
      continue;
    }
    if (!fieldStarted && ch === '"') {
      inQuotes = true;
      fieldStarted = true;
      continue;
    }
    if (ch === delimiter) {
      finishField();
      continue;
    }
    if (ch === "\r" || ch === "\n") {
      if (ch === "\r" && text[i + 1] === "\n") i += 1;
      if (!finishRow()) break;
      continue;
    }
    field += ch;
    fieldStarted = true;
  }

  if (!rowsCut && (fieldStarted || currentColumnCount > 0)) {
    finishRow();
  }

  // A byte-sliced prefix may end mid-row or mid-quote; drop the trailing partial row when earlier rows exist.
  if (byteTruncated && !rowsCut) {
    if (allRows.length > 1) allRows.pop();
    rowsCut = true;
  }

  if (
    allRows.length === 0 ||
    (allRows.length === 1 && allRows[0]!.length === 1 && allRows[0]![0] === "")
  ) {
    return {
      headers: [],
      rows: [],
      columnCount: 0,
      columnWidths: [],
      numericColumns: [],
      rowsCut,
      columnsCut,
    };
  }

  let columnCount = 0;
  for (const r of allRows) {
    if (r.length > columnCount) columnCount = r.length;
  }
  const pad = (r: string[]) => {
    if (r.length === columnCount) return r;
    const padded = r.slice();
    while (padded.length < columnCount) padded.push("");
    return padded;
  };

  const headers = pad(allRows[0]!);
  const rows = allRows.slice(1).map(pad);

  const numericSample = Math.min(rows.length, 100);
  const numericColumns = Array.from({ length: columnCount }, (_, c) => {
    let seen = 0;
    for (let r = 0; r < numericSample; r += 1) {
      const value = rows[r]![c]!.trim();
      if (value.length === 0) continue;
      if (!numericValue.test(value)) return false;
      seen += 1;
    }
    return seen > 0;
  });

  const widthSample = Math.min(rows.length, 50);
  const columnWidths = Array.from({ length: columnCount }, (_, c) => {
    let widest = displayLength(headers[c]!) * 1.05;
    for (let r = 0; r < widthSample; r += 1) {
      const length = displayLength(rows[r]![c]!);
      if (length > widest) widest = length;
    }
    return Math.round(
      Math.min(maxColumnWidth, Math.max(minColumnWidth, widest * 7.5 + 24))
    );
  });

  return {
    headers,
    rows,
    columnCount,
    columnWidths,
    numericColumns,
    rowsCut,
    columnsCut,
  };
}

/**
 * How a parsed table sits in its panel. Each column's estimated width is its minimum and the table sizes its columns to
 * their content, at least as wide as the panel: the slack goes to one fill column (the last text column, else the last
 * column), so a narrow table has no empty area at its right and a wide one still scrolls. The row-number column fits
 * its largest number.
 */
export function csvTableLayout(
  table: Pick<ParsedCsv, "columnWidths" | "numericColumns" | "rows">
): {
  fill: number;
  rowNumberWidth: string;
} {
  const { columnWidths, numericColumns } = table;
  let fill = columnWidths.length - 1;
  for (let c = columnWidths.length - 1; c >= 0; c -= 1) {
    if (!numericColumns[c]) {
      fill = c;
      break;
    }
  }
  const digits = Math.max(2, String(table.rows.length).length);
  // Digits are tabular, so `ch` is about one digit's width: the cell's padding is on both sides, with a little slack so
  // the widest number is never cut.
  const rowNumberWidth = `calc(${digits}ch + var(--spacing-md) * 2 + var(--spacing-xs))`;
  return { fill, rowNumberWidth };
}
