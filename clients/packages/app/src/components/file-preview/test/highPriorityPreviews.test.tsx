import { describe, expect, it } from "vitest";
import { filePreviewKind } from "../FilePreviewContent";
import {
  buildArchiveTree,
  parseArchive,
  parseTarDirectory,
  parseZipDirectory,
  readArchiveDirectory,
} from "../archive";
import { decodeCsvBytes, detectCsvDelimiter, isCellUrl, parseCsv } from "../csv";
import {
  formatJsonValue,
  isJsonNumber,
  parseJsonLines,
  parseJsonPreservingNumbers,
} from "../jsonPreview";
import { parseNotebook, sanitizeNotebookHtml, stripAnsi } from "../notebook";
import { decodeTiff } from "../tiff";
import type { RangedFile } from "../PdfFilePreview";

/** Builds a minimal valid uncompressed ZIP buffer for directory-parser tests. */
function makeZip(
  entries: Array<{
    name?: string;
    nameBytes?: Uint8Array;
    flags?: number;
    data: Uint8Array;
  }>
): Uint8Array {
  const utf8 = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;

  for (const entry of entries) {
    const nameBytes = entry.nameBytes ?? utf8.encode(entry.name ?? "");
    const flags = entry.flags ?? 0x0800;
    const local = new Uint8Array(30 + nameBytes.length + entry.data.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(6, flags, true);
    lv.setUint32(18, entry.data.length, true);
    lv.setUint32(22, entry.data.length, true);
    lv.setUint16(26, nameBytes.length, true);
    local.set(nameBytes, 30);
    local.set(entry.data, 30 + nameBytes.length);
    locals.push(local);

    const central = new Uint8Array(46 + nameBytes.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, flags, true);
    cv.setUint32(20, entry.data.length, true);
    cv.setUint32(24, entry.data.length, true);
    cv.setUint16(28, nameBytes.length, true);
    cv.setUint32(42, offset, true);
    central.set(nameBytes, 46);
    centrals.push(central);
    offset += local.length;
  }

  const cdStart = offset;
  const cdSize = centrals.reduce((sum, part) => sum + part.length, 0);
  const eocd = new Uint8Array(22);
  const ev = new DataView(eocd.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, entries.length, true);
  ev.setUint16(10, entries.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, cdStart, true);

  const total = new Uint8Array(offset + cdSize + 22);
  let pos = 0;
  for (const part of [...locals, ...centrals, eocd]) {
    total.set(part, pos);
    pos += part.length;
  }
  return total;
}

/** Builds a virtual large ZIP backed by a RangedFile whose payload bytes are never read. */
function makeVirtualLargeZipRanged(
  payloadSize: number,
  entries: Array<{ name: string; size: number }>
): { ranged: RangedFile; reads: Array<{ offset: number; length: number }> } {
  const utf8 = new TextEncoder();
  const centrals: Uint8Array[] = [];
  for (const entry of entries) {
    const nameBytes = utf8.encode(entry.name);
    const central = new Uint8Array(46 + nameBytes.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint32(20, entry.size, true);
    cv.setUint32(24, entry.size, true);
    cv.setUint16(28, nameBytes.length, true);
    cv.setUint32(42, 0, true);
    central.set(nameBytes, 46);
    centrals.push(central);
  }
  const cdSize = centrals.reduce((sum, part) => sum + part.length, 0);
  const cdStart = payloadSize;
  const eocd = new Uint8Array(22);
  const ev = new DataView(eocd.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, entries.length, true);
  ev.setUint16(10, entries.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, cdStart, true);

  const tail = new Uint8Array(cdSize + 22);
  let pos = 0;
  for (const part of [...centrals, eocd]) {
    tail.set(part, pos);
    pos += part.length;
  }
  const totalSize = payloadSize + tail.length;
  const headerMagic = new Uint8Array([0x50, 0x4b, 0x03, 0x04]);
  const reads: Array<{ offset: number; length: number }> = [];

  const ranged: RangedFile = {
    async read(offset, length) {
      reads.push({ offset, length });
      const end = Math.min(totalSize, offset + length);
      const out = new Uint8Array(Math.max(0, end - offset));
      if (offset < 4) {
        const take = Math.min(4 - offset, out.length);
        out.set(headerMagic.subarray(offset, offset + take), 0);
      }
      if (end > payloadSize) {
        const tailStart = Math.max(0, offset - payloadSize);
        const destStart = Math.max(0, payloadSize - offset);
        const take = Math.min(tail.length - tailStart, out.length - destStart);
        if (take > 0) out.set(tail.subarray(tailStart, tailStart + take), destStart);
      }
      return { bytes: out, size: totalSize };
    },
  };
  return { ranged, reads };
}

/** Builds a minimal valid USTAR TAR buffer. */
function makeTar(
  entries: Array<{ name: string; data?: Uint8Array; isDir?: boolean }>
): Uint8Array {
  const utf8 = new TextEncoder();
  const blocks: Uint8Array[] = [];
  for (const entry of entries) {
    const header = new Uint8Array(512);
    header.set(utf8.encode(entry.name).subarray(0, 100), 0);
    const data = entry.data ?? new Uint8Array(0);
    const octalSize = data.length.toString(8).padStart(11, "0");
    header.set(utf8.encode(octalSize), 124);
    header[156] = entry.isDir ? "5".charCodeAt(0) : "0".charCodeAt(0);
    header.set(utf8.encode("ustar"), 257);
    blocks.push(header);
    if (data.length > 0) {
      const padded = new Uint8Array(Math.ceil(data.length / 512) * 512);
      padded.set(data);
      blocks.push(padded);
    }
  }
  blocks.push(new Uint8Array(1024));
  const out = new Uint8Array(blocks.reduce((sum, b) => sum + b.length, 0));
  let pos = 0;
  for (const block of blocks) {
    out.set(block, pos);
    pos += block.length;
  }
  return out;
}

/** Builds a minimal uncompressed 2x2 RGB TIFF buffer. */
function makeRgbTiff(): Uint8Array {
  const pixels = new Uint8Array([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]);
  const ifdOffset = 8;
  const entries = 9;
  const bpsOffset = ifdOffset + 2 + entries * 12 + 4;
  const pixelOffset = bpsOffset + 6;
  const buf = new Uint8Array(pixelOffset + pixels.length);
  const view = new DataView(buf.buffer);
  buf[0] = 0x49;
  buf[1] = 0x49;
  view.setUint16(2, 42, true);
  view.setUint32(4, ifdOffset, true);
  view.setUint16(ifdOffset, entries, true);

  let at = ifdOffset + 2;
  const writeTag = (tag: number, type: number, count: number, value: number) => {
    view.setUint16(at, tag, true);
    view.setUint16(at + 2, type, true);
    view.setUint32(at + 4, count, true);
    if (type === 3 && count === 1) view.setUint16(at + 8, value, true);
    else view.setUint32(at + 8, value, true);
    at += 12;
  };
  writeTag(256, 4, 1, 2); // width
  writeTag(257, 4, 1, 2); // height
  writeTag(258, 3, 3, bpsOffset); // bitsPerSample [8,8,8]
  writeTag(259, 3, 1, 1); // uncompressed
  writeTag(262, 3, 1, 2); // RGB
  writeTag(273, 4, 1, pixelOffset); // stripOffset
  writeTag(277, 3, 1, 3); // samplesPerPixel
  writeTag(278, 4, 1, 2); // rowsPerStrip
  writeTag(279, 4, 1, pixels.length); // stripByteCounts

  view.setUint16(bpsOffset, 8, true);
  view.setUint16(bpsOffset + 2, 8, true);
  view.setUint16(bpsOffset + 4, 8, true);
  buf.set(pixels, pixelOffset);
  return buf;
}

describe("filePreviewKind high-priority formats", () => {
  it("classifies spreadsheets, delimited text, notebooks, structured JSON, archives, and images", () => {
    expect(filePreviewKind("report.csv")).toBe("csv");
    expect(filePreviewKind("report.tsv")).toBe("csv");
    expect(filePreviewKind("legacy.xls")).toBe("xlsx");
    expect(filePreviewKind("macros.xlsm")).toBe("xlsx");
    expect(filePreviewKind("binary.xlsb")).toBe("xlsx");
    expect(filePreviewKind("sheet.ods")).toBe("xlsx");
    expect(filePreviewKind("analysis.ipynb")).toBe("notebook");
    expect(filePreviewKind("config.json")).toBe("json");
    expect(filePreviewKind("events.jsonl")).toBe("jsonl");
    expect(filePreviewKind("events.ndjson")).toBe("jsonl");
    expect(filePreviewKind("bundle.zip")).toBe("archive");
    expect(filePreviewKind("release.tar.gz")).toBe("archive");
    expect(filePreviewKind("release.tgz")).toBe("archive");
    expect(filePreviewKind("backup.tar")).toBe("archive");
    expect(filePreviewKind("bitmap.bmp")).toBe("image");
    expect(filePreviewKind("favicon.ico")).toBe("image");
    expect(filePreviewKind("scan.tiff")).toBe("tiff");
    expect(filePreviewKind("scan.tif")).toBe("tiff");
    expect(filePreviewKind("installer.dmg")).toBe("unknown");
  });

  it("prefers known filename extensions over misleading browser MIME types", () => {
    // Windows browsers with Excel installed tag .csv as application/vnd.ms-excel.
    expect(filePreviewKind("sales.csv", "application/vnd.ms-excel")).toBe("csv");
    expect(filePreviewKind("metrics.tsv", "application/vnd.ms-excel")).toBe("csv");
    expect(filePreviewKind("analysis.ipynb", "application/json")).toBe("notebook");
    expect(filePreviewKind("events.jsonl", "application/json")).toBe("jsonl");
    expect(filePreviewKind("index.ts", "video/mp2t")).toBe("text");
    // Extensionless files still fall back to their declared MIME type.
    expect(filePreviewKind("download", "application/vnd.ms-excel")).toBe("xlsx");
  });
});

describe("CSV / TSV parsing", () => {
  it("parses RFC 4180 quotes, escaped quotes, embedded newlines, numeric columns, and URLs", () => {
    const csv =
      'id,title,amount,url\r\nBRI-1,"Hello, ""world""\nsecond line",1234.50,https://linear.app/issue/BRI-1\r\nBRI-2,Plain,-42,mailto:a@example.com\r\n';
    const parsed = parseCsv(csv);
    expect(parsed.headers).toEqual(["id", "title", "amount", "url"]);
    expect(parsed.rows).toEqual([
      [
        "BRI-1",
        'Hello, "world"\nsecond line',
        "1234.50",
        "https://linear.app/issue/BRI-1",
      ],
      ["BRI-2", "Plain", "-42", "mailto:a@example.com"],
    ]);
    expect(parsed.numericColumns).toEqual([false, false, true, false]);
    expect(parsed.rowsCut).toBe(false);
    expect(isCellUrl("https://linear.app/issue/BRI-1")).toBe(true);
    expect(isCellUrl("javascript:alert(1)")).toBe(false);
  });

  it("handles UTF-8 BOM, byte-truncated multibyte tail, semicolon CSV, and row/column caps", () => {
    const utf8Bom = new Uint8Array([
      0xef,
      0xbb,
      0xbf,
      ...new TextEncoder().encode("名称,数值\n甲,10\n"),
    ]);
    expect(decodeCsvBytes(utf8Bom)).toBe("名称,数值\n甲,10\n");

    // Slice mid-3-byte UTF-8 character ('中' = E4 B8 AD)
    const cutBytes = new Uint8Array([
      ...new TextEncoder().encode("a,b\n1,中"),
      0xe4,
      0xb8,
    ]);
    expect(decodeCsvBytes(cutBytes, true)).toBe("a,b\n1,中");

    expect(detectCsvDelimiter("a;b;c\n1;2;3\n", "eu.csv")).toBe(";");
    expect(detectCsvDelimiter("a\tb\n1\t2\n", "data.tsv")).toBe("\t");

    const capped = parseCsv("a,b,c\n1,2,3\n4,5,6\n7,8,9\n", {
      maxRows: 2,
      maxColumns: 2,
    });
    expect(capped.headers).toEqual(["a", "b"]);
    expect(capped.rows).toEqual([
      ["1", "2"],
      ["4", "5"],
    ]);
    expect(capped.rowsCut).toBe(true);
    expect(capped.columnsCut).toBe(true);
  });
});

describe("JSON / JSONL parsing", () => {
  it("preserves exact >53-bit integer precision in parsed JSON trees, copied JSON, and JSONL tables", () => {
    const raw =
      '{"id":12345678901234567890,"neg":-9007199254740993,"price":12.50,"nested":[9007199254740993]}';
    const parsed = parseJsonPreservingNumbers(raw) as Record<string, unknown>;
    expect(isJsonNumber(parsed.id)).toBe(true);
    if (isJsonNumber(parsed.id)) expect(parsed.id.raw).toBe("12345678901234567890");
    expect(formatJsonValue(parsed as never)).toBe(raw);
    expect(formatJsonValue(parsed as never, 2)).toContain('"id": 12345678901234567890');

    const jsonl =
      '{"id":12345678901234567890,"meta":{"parent":9007199254740993}}\n{"id":42,"meta":{"parent":1}}';
    const table = parseJsonLines(jsonl).table;
    expect(table?.numericColumns).toEqual([true, false]);
    expect(table?.rows).toEqual([
      ["12345678901234567890", '{"parent": 9007199254740993}'],
      ["42", '{"parent": 1}'],
    ]);
  });

  it("projects object records into a table and drops partial trailing lines when byte-truncated", () => {
    const text =
      '{"id":1,"name":"alpha","meta":{"ok":true}}\n{"id":2,"name":"beta","extra":"x"}\n{"id":3,"name":"cut';
    const parsed = parseJsonLines(text, { byteTruncated: true });
    expect(parsed.invalid).toBe(false);
    expect(parsed.rowsCut).toBe(true);
    expect(parsed.table?.headers).toEqual(["id", "name", "meta", "extra"]);
    expect(parsed.table?.numericColumns).toEqual([true, false, false, false]);
    expect(parsed.table?.rows).toEqual([
      // A nested value reads as one line with a space after each `:` and `,`.
      ["1", "alpha", '{"ok": true}', ""],
      ["2", "beta", "", "x"],
    ]);
  });
});

describe("Jupyter Notebook parsing", () => {
  it("strips class/id/style and blocks remote image tracking pixels in HTML outputs", () => {
    const hostile = [
      '<div class="fixed inset-0 z-50" id="spoof" style="position:fixed" data-testid="fake">Overlay</div>',
      '<img src="https://tracker.example/pixel.png" alt="track">',
      '<img src="data:image/png;base64,iVBORw0KGgo=" alt="inline">',
      '<a href="https://comma.surf/docs">Docs</a>',
      '<a href="javascript:alert(1)">Bad</a>',
    ].join("");
    const clean = sanitizeNotebookHtml(hostile);
    expect(clean).not.toContain("fixed inset-0");
    expect(clean).not.toContain('id="spoof"');
    expect(clean).not.toContain("data-testid");
    expect(clean).not.toContain("tracker.example");
    expect(clean).not.toContain("javascript:");
    expect(clean).toContain("data:image/png;base64,iVBORw0KGgo=");
    expect(clean).toContain('href="https://comma.surf/docs"');
  });

  it("extracts markdown, code, sanitized HTML tables, images, and ANSI-stripped errors", () => {
    const nb = JSON.stringify({
      metadata: { kernelspec: { display_name: "Python 3", language: "python" } },
      cells: [
        { cell_type: "markdown", source: ["# Report\n", "Summary"] },
        {
          cell_type: "code",
          execution_count: 1,
          source: ["import pandas as pd\ndf.head()"],
          outputs: [
            {
              output_type: "execute_result",
              data: {
                "text/html": [
                  "<script>alert(1)</script><table><tr><td>42</td></tr></table>",
                ],
              },
            },
            {
              output_type: "error",
              ename: "ValueError",
              evalue: "\u001b[31mbad input\u001b[0m",
              traceback: ["\u001b[1;31mTraceback\u001b[0m"],
            },
          ],
        },
      ],
    });
    const parsed = parseNotebook(nb);
    expect(parsed.kernelName).toBe("Python 3");
    expect(parsed.languageExtension).toBe("py");
    expect(parsed.cells).toHaveLength(2);
    expect(parsed.cells[0]).toEqual({ kind: "markdown", source: "# Report\nSummary" });
    const code = parsed.cells[1]!;
    expect(code.kind).toBe("code");
    if (code.kind === "code") {
      expect(code.executionCount).toBe(1);
      expect(code.outputs[0]).toEqual({
        kind: "html",
        html: "<table><tbody><tr><td>42</td></tr></tbody></table>",
      });
      expect(code.outputs[1]).toEqual({
        kind: "error",
        ename: "ValueError",
        evalue: "bad input",
        traceback: "Traceback",
      });
    }
    expect(stripAnsi("\u001b[32mok\u001b[0m")).toBe("ok");
  });
});

describe("Archive directory parsing", () => {
  it("reads ZIP and TAR directories and builds a folder-first size-aggregated tree", async () => {
    const zipBytes = makeZip([
      { name: "src/index.ts", data: new Uint8Array(120) },
      { name: "src/utils/csv.ts", data: new Uint8Array(80) },
      { name: "README.md", data: new Uint8Array(50) },
    ]);
    const zip = parseZipDirectory(zipBytes);
    expect(zip.totalFiles).toBe(3);
    expect(zip.totalUncompressedBytes).toBe(250);
    // The ZIP lists no folder entries: the count is the folders its paths imply, as the tree shows them.
    expect(zip.totalFolders).toBe(2);
    const tree = buildArchiveTree(zip.entries);
    expect(tree.map((n) => n.name)).toEqual(["src", "README.md"]);
    expect(tree[0]!.size).toBe(200);
    expect(tree[0]!.fileCount).toBe(2);

    const tarBytes = makeTar([
      { name: "docs/", isDir: true },
      { name: "docs/guide.md", data: new Uint8Array(40) },
    ]);
    const tar = parseTarDirectory(tarBytes);
    expect(tar.totalFiles).toBe(1);
    expect(tar.totalFolders).toBe(1);
    expect((await parseArchive(zipBytes, "bundle.zip")).format).toBe("zip");
  });

  it("decodes GBK ZIP filenames when the UTF-8 flag (bit 11) is unset", () => {
    // "文档/年度报告.csv" encoded in GBK (CP936): CE C4 B5 B5 2F C4 EA B6 C8 B1 A8 B8 E6 2E 63 73 76
    const gbkName = new Uint8Array([
      0xce, 0xc4, 0xb5, 0xb5, 0x2f, 0xc4, 0xea, 0xb6, 0xc8, 0xb1, 0xa8, 0xb8, 0xe6,
      0x2e, 0x63, 0x73, 0x76,
    ]);
    const zipBytes = makeZip([
      { nameBytes: gbkName, flags: 0, data: new Uint8Array(64) },
    ]);
    const parsed = parseZipDirectory(zipBytes);
    expect(parsed.entries.map((entry) => entry.path)).toEqual(["文档/年度报告.csv"]);
    expect(parsed.totalFiles).toBe(1);
    expect(parsed.totalFolders).toBe(1);
  });

  it("reads only the tail Central Directory for ranged ZIP archives larger than 64 MB", async () => {
    const payloadSize = 200 * 1024 * 1024;
    const { ranged, reads } = makeVirtualLargeZipRanged(payloadSize, [
      { name: "datasets/train.parquet", size: 120 * 1024 * 1024 },
      { name: "datasets/eval.parquet", size: 80 * 1024 * 1024 },
    ]);
    const parsed = await readArchiveDirectory(
      { ranged },
      "big-dataset.zip",
      "application/zip",
      new AbortController().signal
    );
    expect(parsed.format).toBe("zip");
    expect(parsed.totalFiles).toBe(2);
    expect(parsed.totalFolders).toBe(1);
    expect(parsed.entries.map((entry) => entry.path)).toEqual([
      "datasets/train.parquet",
      "datasets/eval.parquet",
    ]);
    const totalBytesRequested = reads.reduce((sum, r) => sum + r.length, 0);
    expect(totalBytesRequested).toBeLessThan(128 * 1024);
  });
});

describe("TIFF decoding", () => {
  it("decodes an uncompressed baseline RGB TIFF into RGBA pixels", async () => {
    const decoded = await decodeTiff(makeRgbTiff());
    expect(decoded.width).toBe(2);
    expect(decoded.height).toBe(2);
    expect(Array.from(decoded.rgba.subarray(0, 8))).toEqual([
      255, 0, 0, 255, 0, 255, 0, 255,
    ]);
  });
});
