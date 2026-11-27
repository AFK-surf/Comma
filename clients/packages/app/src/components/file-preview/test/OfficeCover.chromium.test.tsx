import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
// oxlint-disable-next-line import/default
import deckUrl from "./fixtures/roadmap.pptx?url";
// oxlint-disable-next-line import/default
import briefUrl from "./fixtures/brief.docx?url";
// oxlint-disable-next-line import/default
import budgetUrl from "./fixtures/budget.xlsx?url";
import { OfficeCover, officeCoverMaxBytes, type OfficeCoverKind } from "../OfficeCover";
import type { RangedFile } from "../PdfFilePreview";

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

const cover = () =>
  document.querySelector<HTMLElement>("[data-testid='attachment-office-cover']")!;

const drawnPage = () =>
  cover().querySelector(".comma-office-cover-page")!.firstElementChild;

function Card({
  fileKey,
  file,
  kind = "slides",
}: {
  fileKey: string;
  file: RangedFile;
  kind?: OfficeCoverKind;
}) {
  return (
    // As wide as its content, as a chat card is, from its header's width.
    <div
      data-testid="card"
      style={{ height: 180, minWidth: 320, width: "fit-content" }}
    >
      <OfficeCover file={file} fileKey={fileKey} kind={kind} />
    </div>
  );
}

/** A file read a span at a time, as an attachment is, counting what it was asked for. */
async function rangedFile(url: string) {
  const bytes = new Uint8Array(await (await fetch(url)).arrayBuffer());
  const reads: [number, number][] = [];
  const file: RangedFile = {
    read: async (offset, length) => {
      reads.push([offset, length]);
      return { bytes: bytes.subarray(offset, offset + length), size: bytes.length };
    },
  };
  return { file, reads };
}

it("draws a deck's first slide across the card's width, and reads the deck once for each file", async () => {
  const { file, reads } = await rangedFile(deckUrl);
  const { unmount } = render(<Card file={file} fileKey="deck-a" />);
  await untilPage(() => cover().dataset.arrived === "true");
  expect(cover().textContent).toContain("Q4 Roadmap");
  // The second slide is not drawn on the card.
  expect(cover().textContent).not.toContain("Highlights");
  const slide = drawnPage()!.getBoundingClientRect();
  // The slide, drawn at its own size and scaled down, does not widen the card.
  expect(
    document.querySelector("[data-testid='card']")!.getBoundingClientRect().width
  ).toBe(320);
  expect(slide.width).toBeCloseTo(320, 0);
  expect(slide.top).toBeCloseTo(cover().getBoundingClientRect().top, 0);
  const read = reads.length;

  unmount();
  render(<Card file={file} fileKey="deck-a" />);
  await untilPage(() => cover().dataset.arrived === "true");
  expect(reads).toHaveLength(read);
});

it("draws nothing for a deck over the card's limit with no thumbnail, and does not read the deck", async () => {
  const reads: [number, number][] = [];
  let sized!: () => void;
  const read = new Promise<void>((resolve) => (sized = resolve));
  const file: RangedFile = {
    read: async (offset, length) => {
      reads.push([offset, length]);
      sized();
      return { bytes: new Uint8Array(0), size: officeCoverMaxBytes.slides + 1 };
    },
  };
  render(<Card file={file} fileKey="deck-large" />);
  await read;
  // What the card does with the size it read runs in the turns that follow.
  for (let turn = 0; turn < 50; turn += 1) await Promise.resolve();
  // Its size, then the start of the archive for a saved thumbnail: none reads the deck.
  expect(reads).toEqual([
    [0, 4],
    [0, 4],
  ]);
  expect(cover().dataset.arrived).toBeUndefined();
  expect(drawnPage()).toBeNull();
  expect(cover().querySelector("img")).toBeNull();
});

it("draws a Word document's first page across the card's width, not its saved thumbnail", async () => {
  const { file } = await rangedFile(briefUrl);
  render(<Card file={file} fileKey="brief" kind="docx" />);
  await untilPage(() => cover().dataset.arrived === "true");
  expect(cover().textContent).toContain("Launch Brief");
  // The second page is not drawn on the card, and the blank thumbnail the file carries is not shown.
  expect(cover().textContent).not.toContain("Appendix");
  expect(cover().querySelector("img")).toBeNull();
  const page = cover().querySelector("section")!.getBoundingClientRect();
  expect(
    document.querySelector("[data-testid='card']")!.getBoundingClientRect().width
  ).toBe(320);
  expect(page.width).toBeCloseTo(320, 0);
});

it("draws a workbook's first sheet from its top left cells, at their own size", async () => {
  const { file } = await rangedFile(budgetUrl);
  render(<Card file={file} fileKey="budget" kind="xlsx" />);
  await untilPage(() => cover().dataset.arrived === "true");
  const sheet = cover().querySelector("table")!;
  expect(sheet.textContent).toContain("Q4 Budget");
  expect(sheet.textContent).toContain("$1,200.00");
  // Another sheet is not drawn.
  expect(sheet.textContent).not.toContain("Approved by finance");
  expect(sheet.style.transform).toBe("");
  expect(
    document.querySelector("[data-testid='card']")!.getBoundingClientRect().width
  ).toBe(320);
});
