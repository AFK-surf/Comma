import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
// oxlint-disable-next-line import/default
import deckUrl from "./fixtures/roadmap.pptx?url";
import { SlidesFilePreview, slidesPreviewMaxBytes } from "../SlidesFilePreview";
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

const deck = async () => new Uint8Array(await (await fetch(deckUrl)).arrayBuffer());

/** A file read a span at a time, as an attachment is, counting what it was asked for. */
function rangedFile(bytes: Uint8Array) {
  const reads: [number, number][] = [];
  const file: RangedFile = {
    read: async (offset, length) => {
      reads.push([offset, length]);
      return { bytes: bytes.subarray(offset, offset + length), size: bytes.length };
    },
  };
  return { file, reads };
}

function Panel(props: Parameters<typeof SlidesFilePreview>[0]) {
  return (
    <div style={{ display: "flex", flexDirection: "column", height: 640, width: 560 }}>
      <SlidesFilePreview {...props} />
    </div>
  );
}

const slides = () => document.querySelector("[data-testid='file-preview-slides']")!;

it("draws a deck's slides fitted to the panel, and a slide's link opens in the browser", async () => {
  const onOpenBrowser = vi.fn();
  const { file, reads } = rangedFile(await deck());
  render(<Panel ranged={file} onOpenBrowser={onOpenBrowser} />);

  // The loading mark goes once the renderer says the deck is open, which may be after its first slides show.
  await untilPage(
    () =>
      slides().textContent.includes("Highlights") &&
      document.querySelector("[data-testid='file-preview-loading']") === null
  );
  expect(slides().textContent).toContain("Q4 Roadmap");
  // The deck is small: one span read it whole.
  expect(reads).toEqual([[0, 8 * 1024 * 1024]]);
  // Each slide is as wide as the column, and no wider.
  const column = slides().getBoundingClientRect();
  const first = slides().firstElementChild!.getBoundingClientRect();
  expect(first.width).toBeGreaterThan(0);
  expect(first.width).toBeLessThanOrEqual(column.width);

  const link = [...slides().querySelectorAll("a")].find(
    (a) => a.textContent === "Release notes"
  )!;
  await userEvent.click(link);
  expect(onOpenBrowser).toHaveBeenCalledWith("https://example.com/notes");
});

it("says a deck over the limit is too large without reading it", async () => {
  const reads: [number, number][] = [];
  const file: RangedFile = {
    read: async (offset, length) => {
      reads.push([offset, length]);
      return { bytes: new Uint8Array(0), size: slidesPreviewMaxBytes + 1 };
    },
  };
  render(<Panel ranged={file} onOpenBrowser={() => undefined} />);
  await untilPage(() =>
    document.body.textContent.includes(
      "This presentation exceeds the 64 MB preview limit."
    )
  );
  expect(reads).toHaveLength(1);
});

it("says a file that is not a deck could not be previewed", async () => {
  render(
    <Panel
      blob={new Blob(["not a deck"], { type: "application/octet-stream" })}
      onOpenBrowser={() => undefined}
    />
  );
  await untilPage(() =>
    document.body.textContent.includes("Could not preview this file.")
  );
});
