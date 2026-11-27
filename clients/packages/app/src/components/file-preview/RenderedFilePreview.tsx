import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import { opensInBrowser, wholeFileOf, type WholeRead } from "./wholeFile";

/** What a renderer drew into its element, and what it holds until it is destroyed. */
export type Drawn = {
  destroy(): void;
};

/** Draws a whole file into `element`; it throws for a file it cannot draw. */
export type DrawFile = (
  bytes: Uint8Array<ArrayBuffer>,
  element: HTMLElement,
  signal: AbortSignal
) => Promise<Drawn>;

/**
 * An office file drawn in the page from its own parts (a deck's slides, a Word document's pages), in one scrolling
 * column. The file is read whole, up to `maxBytes`, before it is drawn. A link in it opens
 * in the browser, a link to a place in it scrolls there, and any other link does nothing.
 */
export function RenderedFilePreview({
  blob,
  ranged,
  maxBytes,
  tooLarge,
  draw,
  testId,
  onOpenBrowser,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  maxBytes: number;
  /** What the preview says of a file over `maxBytes`. */
  tooLarge: string;
  draw: DrawFile;
  testId: string;
  onOpenBrowser: (url: string) => void;
  /** Content after the file, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const container = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"loading" | "ready" | "too_large" | "failed">(
    "loading"
  );

  useEffect(() => {
    const element = container.current;
    if (!element || (!blob && !ranged)) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    let drawn: Drawn | undefined;
    setState("loading");
    void (async () => {
      try {
        const read: WholeRead = await wholeFileOf({ blob, ranged }, signal, maxBytes);
        if (signal.aborted) return;
        if ("error" in read) return setState(read.error);
        const made = await draw(read.bytes, element, signal);
        if (signal.aborted) return made.destroy();
        drawn = made;
        setState("ready");
      } catch {
        if (!signal.aborted) {
          element.replaceChildren();
          setState("failed");
        }
      }
    })();
    return () => {
      controller.abort();
      drawn?.destroy();
      element.replaceChildren();
    };
  }, [blob, draw, maxBytes, ranged]);

  return (
    <ScrollArea
      className="min-h-0 flex-1"
      viewportClassName="h-full"
      contentClassName="flex min-h-full flex-col"
      edgeEffect="none"
      orientation="vertical"
    >
      <div className="flex min-h-full flex-1 flex-col">
        {/* The file is drawn into the column while the mark shows: it is fitted to its width, so it is laid out from
            the start. */}
        {state === "loading" ? <FilePreviewLoading /> : null}
        {state === "too_large" || state === "failed" ? (
          <div className="flex flex-1 items-center justify-center p-xl">
            <p className="text-sm text-secondary">
              {state === "too_large" ? tooLarge : messages.file_preview_failed()}
            </p>
          </div>
        ) : null}
        {/* A renderer fits the file to its container's whole width, padding included: the gutter is outside it. */}
        <div className="min-w-0 p-xl">
          <div
            data-testid={testId}
            ref={container}
            onAuxClick={(event) => {
              // A middle click on a link would open it in a window of the app.
              if (event.target instanceof Element && event.target.closest("a[href]"))
                event.preventDefault();
            }}
            onClickCapture={(event) => {
              const link =
                event.target instanceof Element
                  ? event.target.closest("a[href]")
                  : null;
              if (!(link instanceof HTMLAnchorElement)) return;
              event.preventDefault();
              event.stopPropagation();
              const href = link.getAttribute("href") ?? "";
              // A link to a place in the file (a Word bookmark) scrolls to it, within the file.
              if (href.startsWith("#")) {
                const name = decodeURIComponent(href.slice(1));
                [...container.current!.querySelectorAll("[id]")]
                  .find((place) => place.id === name)
                  ?.scrollIntoView({ block: "start" });
                return;
              }
              if (opensInBrowser(link.href)) onOpenBrowser(link.href);
            }}
          />
        </div>
        {children}
      </div>
    </ScrollArea>
  );
}
