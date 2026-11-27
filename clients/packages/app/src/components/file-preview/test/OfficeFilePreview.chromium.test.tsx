import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
// oxlint-disable-next-line import/default
import briefUrl from "./fixtures/brief.docx?url";
// oxlint-disable-next-line import/default
import budgetUrl from "./fixtures/budget.xlsx?url";
import { DocxFilePreview } from "../DocxFilePreview";
import { SheetFilePreview } from "../SheetFilePreview";

afterEach(cleanup);

/** Until the page shows it: the page changing is what is waited on. */
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

const fixture = async (url: string) =>
  new Blob([await (await fetch(url)).arrayBuffer()]);
const docxView = () => document.querySelector("[data-testid='file-preview-docx']")!;
const sheetView = () => document.querySelector("[data-testid='file-preview-sheet']")!;
const loaded = () =>
  document.querySelector("[data-testid='file-preview-loading']") === null;

function Panel({ children }: { children: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", height: 640, width: 560 }}>
      {children}
    </div>
  );
}

it("draws a Word document's pages fitted to the panel, and only its web links open", async () => {
  const onOpenBrowser = vi.fn();
  render(
    <Panel>
      <DocxFilePreview blob={await fixture(briefUrl)} onOpenBrowser={onOpenBrowser} />
    </Panel>
  );
  await untilPage(() => docxView().textContent.includes("Appendix") && loaded());
  expect(docxView().textContent).toContain("Launch Brief");
  // The page break makes two pages, each no wider than the column.
  const pages = [...docxView().querySelectorAll("section")];
  expect(pages).toHaveLength(2);
  const column = docxView().getBoundingClientRect().width;
  for (const page of pages)
    expect(page.getBoundingClientRect().width).toBeLessThanOrEqual(column + 0.5);

  const link = (text: string) =>
    [...docxView().querySelectorAll("a")].find((a) => a.textContent === text)!;
  await userEvent.click(link("full plan"));
  expect(onOpenBrowser).toHaveBeenCalledWith("https://example.com/brief");
  // A script link keeps no address.
  expect(link("do not run").hasAttribute("href")).toBe(false);
  await userEvent.click(link("do not run"));
  expect(onOpenBrowser).toHaveBeenCalledTimes(1);
});

it("draws a workbook's sheets as Excel shows them, one at a time", async () => {
  const onOpenBrowser = vi.fn();
  render(
    <Panel>
      <SheetFilePreview blob={await fixture(budgetUrl)} onOpenBrowser={onOpenBrowser} />
    </Panel>
  );
  await untilPage(() => sheetView().textContent.includes("Q4 Budget") && loaded());
  const table = sheetView().querySelector("table")!;
  // Values as formatted in the file, the merged title across its three columns, a hidden column left out.
  expect(table.textContent).toContain("$3,450.50");
  expect(table.textContent).toContain("2026-12-15");
  const title = [...table.querySelectorAll("td")].find(
    (td) => td.textContent === "Q4 Budget"
  )!;
  expect(title.colSpan).toBe(3);
  expect(table.textContent).not.toContain("hidden column");
  await userEvent.click(
    [...table.querySelectorAll("a")].find((a) => a.textContent === "Pricing page")!
  );
  expect(onOpenBrowser).toHaveBeenCalledWith("https://example.com/pricing");

  // The visible sheets are offered; the hidden one is not.
  const sheets = [...document.querySelectorAll("[role='tab']")].map(
    (b) => b.textContent
  );
  expect(sheets).toEqual(["Budget", "Notes", "Log"]);
  await userEvent.click(
    [...document.querySelectorAll("[role='tab']")].find((b) => b.textContent === "Log")!
  );
  await untilPage(() => sheetView().textContent.includes("entry 500"));
  // A sheet longer than the preview draws is cut, and says so.
  expect(sheetView().textContent).not.toContain("entry 501");
  expect(document.body.textContent).toContain(
    "Showing the first 500 rows and 2 columns of this sheet."
  );
});

it("opens another sheet at its top-left, not at the last sheet's scroll", async () => {
  const { utils, write } = await import("xlsx");
  const grid = (label: string) =>
    utils.aoa_to_sheet(
      Array.from({ length: 200 }, (_, r) =>
        Array.from({ length: 30 }, (__, c) => `${label} ${r}:${c}`)
      )
    );
  const book = utils.book_new();
  utils.book_append_sheet(book, grid("first"), "First");
  utils.book_append_sheet(book, grid("second"), "Second");
  const bytes = write(book, { type: "array", bookType: "xlsx" }) as ArrayBuffer;
  render(
    <Panel>
      <SheetFilePreview blob={new Blob([bytes])} onOpenBrowser={() => undefined} />
    </Panel>
  );
  await untilPage(() => sheetView().textContent.includes("first 0:0") && loaded());
  const viewport = sheetView().closest<HTMLElement>(
    "[data-slot='scroll-area-viewport']"
  )!;
  viewport.scrollTo(2000, 4000);
  expect(viewport.scrollTop).toBeGreaterThan(0);
  expect(viewport.scrollLeft).toBeGreaterThan(0);
  await userEvent.click(
    [...document.querySelectorAll("[role='tab']")].find(
      (b) => b.textContent === "Second"
    )!
  );
  await untilPage(() => sheetView().textContent.includes("second 0:0"));
  expect(viewport.scrollTop).toBe(0);
  expect(viewport.scrollLeft).toBe(0);
});

it("says a file that is not a workbook could not be previewed", async () => {
  render(
    <Panel>
      <SheetFilePreview
        blob={new Blob(["not a workbook"])}
        onOpenBrowser={() => undefined}
      />
    </Panel>
  );
  await untilPage(() =>
    document.body.textContent.includes("Could not preview this file.")
  );
});
