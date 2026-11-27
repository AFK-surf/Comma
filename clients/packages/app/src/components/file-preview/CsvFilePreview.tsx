import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useEffect, useState, type ReactNode } from "react";
import { PreviewMessage } from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import { PreviewDataTable, PreviewDataTableNotice } from "./PreviewDataTable";
import {
  csvPreviewColumns,
  csvPreviewMaxBytes,
  csvPreviewRows,
  decodeCsvBytes,
  detectCsvDelimiter,
  parseCsv,
  type ParsedCsv,
} from "./csv";
import { readPrefix } from "./readPrefix";

/**
 * A delimited table (.csv, .tsv): a status strip with its format and size, then the table (`PreviewDataTable`) with a
 * notice above it when a large file was cut.
 */
export function CsvFilePreview({
  fileName,
  mimeType,
  blob,
  ranged,
  onOpenBrowser,
  children,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the table, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "failed" }
    | { status: "ready"; parsed: ParsedCsv }
  >({ status: "loading" });

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    setState({ status: "loading" });
    void (async () => {
      try {
        const { bytes, truncated } = await readPrefix(
          { blob, ranged },
          signal,
          csvPreviewMaxBytes
        );
        if (signal.aborted) return;
        const text = decodeCsvBytes(bytes, truncated);
        const delimiter = detectCsvDelimiter(text, fileName, mimeType);
        const parsed = parseCsv(text, {
          delimiter,
          maxRows: csvPreviewRows,
          maxColumns: csvPreviewColumns,
          byteTruncated: truncated,
        });
        setState({ status: "ready", parsed });
      } catch {
        if (!signal.aborted) setState({ status: "failed" });
      }
    })();
    return () => controller.abort();
  }, [blob, fileName, mimeType, ranged]);

  if (state.status === "loading") return <FilePreviewLoading />;

  if (state.status === "failed") {
    return <PreviewMessage alert>{messages.file_preview_failed()}</PreviewMessage>;
  }

  const { parsed } = state;

  if (parsed.columnCount === 0) {
    return (
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        contentClassName="flex min-h-full flex-col"
        edgeEffect="none"
      >
        <div className="flex min-h-full flex-1 flex-col">
          <PreviewMessage testId="file-preview-csv-empty">
            {messages.file_preview_csv_empty()}
          </PreviewMessage>
          {children}
        </div>
      </ScrollArea>
    );
  }

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      <PreviewDataTableNotice table={parsed} testId="file-preview-csv-truncated" />
      <PreviewDataTable
        onOpenBrowser={onOpenBrowser}
        table={parsed}
        testId="file-preview-csv"
      >
        {children}
      </PreviewDataTable>
    </div>
  );
}
