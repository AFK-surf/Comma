import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { ArchiveFilePreview } from "../ArchiveFilePreview";
import { CsvFilePreview } from "../CsvFilePreview";
import { JsonFilePreview } from "../JsonFilePreview";
import { NotebookFilePreview } from "../NotebookFilePreview";
import { TiffFilePreview } from "../TiffFilePreview";

afterEach(cleanup);

async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, {
        attributes: true,
        characterData: true,
        childList: true,
        subtree: true,
      });
    });
}

function Panel({ children }: { children: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", height: 640, width: 620 }}>
      {children}
    </div>
  );
}

function makeZip(
  entries: Array<{ name: string; data: Uint8Array }>
): Uint8Array<ArrayBuffer> {
  const utf8 = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBytes = utf8.encode(entry.name);
    const local = new Uint8Array(30 + nameBytes.length + entry.data.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
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

function makeRgbTiff(): Uint8Array<ArrayBuffer> {
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
  writeTag(256, 4, 1, 2);
  writeTag(257, 4, 1, 2);
  writeTag(258, 3, 3, bpsOffset);
  writeTag(259, 3, 1, 1);
  writeTag(262, 3, 1, 2);
  writeTag(273, 4, 1, pixelOffset);
  writeTag(277, 3, 1, 3);
  writeTag(278, 4, 1, 2);
  writeTag(279, 4, 1, pixels.length);
  view.setUint16(bpsOffset, 8, true);
  view.setUint16(bpsOffset + 2, 8, true);
  view.setUint16(bpsOffset + 4, 8, true);
  buf.set(pixels, pixelOffset);
  return buf;
}

it("renders CSV with sticky header, numeric right-alignment, and clickable links", async () => {
  const onOpenBrowser = vi.fn();
  const csv = [
    "identifier,title,count,url",
    "BRI-1523,首句延迟排查,42,https://linear.app/surf-cue/issue/BRI-1523",
    "CUE-270,点击卡片闪退,18,https://linear.app/surf-cue/issue/CUE-270",
  ].join("\n");
  render(
    <Panel>
      <CsvFilePreview
        blob={new Blob([csv], { type: "text/csv" })}
        fileName="issues.csv"
        onOpenBrowser={onOpenBrowser}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-csv']") !== null
  );
  const table = document.querySelector("[data-testid='file-preview-csv'] table")!;
  expect(table.querySelector("thead th[data-number='true']")?.textContent).toBe(
    "count"
  );
  await userEvent.click(table.querySelector("a")!);
  expect(onOpenBrowser).toHaveBeenCalledWith(
    "https://linear.app/surf-cue/issue/BRI-1523"
  );
});

it("renders JSON tree with collapse/expand and switches to source via toolbar slot", async () => {
  const toolbar = document.createElement("div");
  document.body.append(toolbar);
  const payload = JSON.stringify({
    service: "comma",
    metrics: { p99: 142, ok: true },
    docs: "https://comma.surf/docs",
  }).replace("142", "12345678901234567890");
  const onOpenBrowser = vi.fn();
  render(
    <Panel>
      <JsonFilePreview
        blob={new Blob([payload], { type: "application/json" })}
        fileName="config.json"
        onOpenBrowser={onOpenBrowser}
        toolbarSlot={toolbar}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-json-tree']") !== null
  );
  // Preserves >53-bit integer precision verbatim instead of IEEE-754 rounding.
  expect(document.body.textContent).toContain("12345678901234567890");
  await userEvent.click(
    document.querySelector("[data-testid='file-preview-json-tree'] a")!
  );
  expect(onOpenBrowser).toHaveBeenCalledWith("https://comma.surf/docs");
  await userEvent.click(toolbar.querySelector("button[aria-label='Source view']")!);
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-json-source']") !== null
  );
  toolbar.remove();
});

it("caps JSON source view at 256 KB without reading the full file when over 2 MB", async () => {
  const chunk = `${JSON.stringify({ message: "x".repeat(120) })}\n`;
  const bigSize = 3 * 1024 * 1024;
  const readBytes = vi.fn(async (offset: number, length: number) => {
    const end = Math.min(bigSize, offset + length);
    const text = chunk.repeat(Math.ceil((end - offset) / chunk.length));
    return {
      bytes: new TextEncoder().encode(text).subarray(0, end - offset),
      size: bigSize,
    };
  });
  render(
    <Panel>
      <JsonFilePreview
        fileName="huge.json"
        onOpenBrowser={() => undefined}
        ranged={{ read: readBytes }}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-json-source']") !== null
  );
  expect(
    document.querySelector("[data-testid='file-preview-json-source-truncated']")
  ).not.toBeNull();
  const totalRequested = readBytes.mock.calls.reduce(
    (sum, [, length]) => sum + length,
    0
  );
  expect(totalRequested).toBeLessThanOrEqual(256 * 1024);
});

it("says when the JSON tree stops at its row cap", async () => {
  // More rows than the tree draws: the reader is told the tree stops there, rather than it ending silently.
  const payload = JSON.stringify(Array.from({ length: 3000 }, (_, i) => i));
  render(
    <Panel>
      <JsonFilePreview
        blob={new Blob([payload], { type: "application/json" })}
        fileName="big.json"
        onOpenBrowser={() => undefined}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-json-tree']") !== null
  );
  const notice = document.querySelector(
    "[data-testid='file-preview-json-tree-capped']"
  );
  expect(notice?.textContent).toContain("2500");
  const tree = document.querySelector("[data-testid='file-preview-json-tree']")!;
  expect(tree.textContent).toContain("2498");
  expect(tree.textContent).not.toContain("2999");
});

it("renders JSONL records as a structured table", async () => {
  const jsonl = [
    JSON.stringify({ ts: "2026-11-25", latency_ms: 120, status: "ok" }),
    JSON.stringify({ ts: "2026-11-25", latency_ms: 95, status: "ok" }),
  ].join("\n");
  render(
    <Panel>
      <JsonFilePreview
        blob={new Blob([jsonl], { type: "application/x-ndjson" })}
        fileName="trace.jsonl"
        lines
        onOpenBrowser={() => undefined}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-jsonl-table']") !== null
  );
  expect(document.body.textContent).toContain("latency_ms");
  expect(document.body.textContent).toContain("120");
});

it("lets JSONL records that are not a table be expanded and collapsed as a tree", async () => {
  // Records that are not all objects fall back to the tree; the toolbar keeps Expand all / Collapse all
  // like a JSON file's.
  const toolbar = document.createElement("div");
  document.body.append(toolbar);
  const jsonl = [
    JSON.stringify(["plan", { attrs: { model: "deep" } }]),
    JSON.stringify(["act", { attrs: { model: "fast" } }]),
  ].join("\n");
  render(
    <Panel>
      <JsonFilePreview
        blob={new Blob([jsonl], { type: "application/x-ndjson" })}
        fileName="spans.jsonl"
        lines
        onOpenBrowser={() => undefined}
        toolbarSlot={toolbar}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-json-tree']") !== null
  );
  const tree = document.querySelector("[data-testid='file-preview-json-tree']")!;
  expect(tree.textContent).not.toContain("deep");
  await userEvent.click(toolbar.querySelector("button[aria-label='Expand all']")!);
  await untilPage(() => tree.textContent.includes("deep"));
  expect(tree.querySelector("button[aria-label='Copy value of model']")).not.toBeNull();
  await userEvent.click(toolbar.querySelector("button[aria-label='Collapse all']")!);
  await untilPage(() => !tree.textContent.includes("plan"));
  toolbar.remove();
});

it("renders Jupyter Notebook cells with Markdown, code, and sanitized HTML output", async () => {
  const nb = JSON.stringify({
    metadata: { kernelspec: { display_name: "Python 3", language: "python" } },
    cells: [
      { cell_type: "markdown", source: "## Latency Analysis" },
      {
        cell_type: "code",
        execution_count: 1,
        source: "print('hello')",
        outputs: [
          { output_type: "stream", name: "stdout", text: "hello\n" },
          {
            output_type: "execute_result",
            data: {
              "text/html":
                '<div class="fixed inset-0 z-50"><img src="https://tracker.invalid/px.png"><table class="dataframe"><thead><tr><th>metric</th><th>p95</th></tr></thead><tbody><tr><td>ttft</td><td>320ms</td></tr></tbody></table></div>',
            },
          },
        ],
      },
    ],
  });
  render(
    <Panel>
      <NotebookFilePreview
        blob={new Blob([nb], { type: "application/x-ipynb+json" })}
        onOpenBrowser={() => undefined}
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-notebook']") !== null
  );
  expect(document.body.textContent).toContain("Latency Analysis");
  expect(document.body.textContent).toContain("In [1]");
  expect(document.body.textContent).toContain("320ms");
  const htmlBox = document.querySelector(".comma-notebook-html")!;
  expect(htmlBox.querySelector("img")).toBeNull();
  expect(htmlBox.querySelector("[class]")).toBeNull();
});

it("renders a ZIP archive as a collapsible folder tree with sizes", async () => {
  const zip = makeZip([
    { name: "src/app.tsx", data: new Uint8Array(1024) },
    { name: "README.md", data: new Uint8Array(256) },
  ]);
  render(
    <Panel>
      <ArchiveFilePreview
        blob={new Blob([zip], { type: "application/zip" })}
        fileName="release.zip"
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("[data-testid='file-preview-archive']") !== null
  );
  expect(document.body.textContent).toContain("src");
  expect(document.body.textContent).toContain("app.tsx");
  const folderBtn = document.querySelector(
    "[data-testid='file-preview-archive'] button"
  )!;
  await userEvent.click(folderBtn);
  expect(document.body.textContent).not.toContain("app.tsx");
});

it("decodes and displays a baseline TIFF image", async () => {
  render(
    <Panel>
      <TiffFilePreview
        blob={new Blob([makeRgbTiff()], { type: "image/tiff" })}
        fileName="sample.tiff"
      />
    </Panel>
  );
  await untilPage(
    () => document.querySelector("img[data-testid='file-preview-tiff']") !== null
  );
  const img = document.querySelector<HTMLImageElement>(
    "img[data-testid='file-preview-tiff']"
  )!;
  expect(img.src.startsWith("blob:")).toBe(true);
});
