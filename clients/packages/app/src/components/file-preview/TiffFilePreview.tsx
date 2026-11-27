import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useState } from "react";
import { PreviewMessage } from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import { decodeTiff, tiffPreviewMaxBytes } from "./tiff";
import { wholeFileOf } from "./wholeFile";

type TiffState =
  | { status: "loading" }
  | { status: "too_large" }
  | { status: "failed" }
  | { status: "ready"; url: string };

/**
 * A baseline TIFF, decoded on a canvas to a PNG, shown as any other image is: the same `<img>` in the panel's image
 * column, so it fits, centers, rounds and opens the image menu like a PNG or BMP (Chromium/Electron cannot draw a
 * TIFF themselves). It renders only the picture, its loading mark or why it is missing; the caller lays it out.
 */
export function TiffFilePreview({
  fileName,
  blob,
  ranged,
}: {
  fileName: string;
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
}) {
  const messages = useCommaMessages();
  const [state, setState] = useState<TiffState>({ status: "loading" });

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    let objectUrl: string | undefined;
    setState({ status: "loading" });
    void (async () => {
      try {
        const read = await wholeFileOf({ blob, ranged }, signal, tiffPreviewMaxBytes);
        if (signal.aborted) return;
        if ("error" in read) {
          setState({ status: read.error });
          return;
        }
        const decoded = await decodeTiff(read.bytes);
        if (signal.aborted) return;
        const canvas = document.createElement("canvas");
        canvas.width = decoded.width;
        canvas.height = decoded.height;
        const ctx = canvas.getContext("2d");
        if (!ctx) throw new Error("canvas unavailable");
        const imageData = ctx.createImageData(decoded.width, decoded.height);
        imageData.data.set(decoded.rgba);
        ctx.putImageData(imageData, 0, 0);
        const png = await new Promise<Blob | null>((resolve) =>
          canvas.toBlob(resolve, "image/png")
        );
        if (signal.aborted) return;
        if (!png) throw new Error("encode failed");
        objectUrl = URL.createObjectURL(png);
        setState({ status: "ready", url: objectUrl });
      } catch {
        if (!signal.aborted) setState({ status: "failed" });
      }
    })();
    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [blob, ranged]);

  if (state.status === "loading") return <FilePreviewLoading />;

  if (state.status === "too_large" || state.status === "failed")
    return (
      <PreviewMessage alert>
        {state.status === "too_large"
          ? messages.file_preview_office_too_large({ limit: 32 })
          : messages.file_preview_failed()}
      </PreviewMessage>
    );

  // The same element and classes as a PNG's preview (`FilePreviewContent`), so the two cannot drift apart.
  return (
    <img
      alt={fileName}
      className="max-h-full max-w-full rounded-lg object-contain"
      data-testid="file-preview-tiff"
      src={state.url}
    />
  );
}
