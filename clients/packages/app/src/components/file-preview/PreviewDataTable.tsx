import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import type { ReactNode } from "react";
import { PreviewNotice, usePreviewLinkHandlers } from "./FilePreviewChrome";
import { csvTableLayout, isCellUrl, type ParsedCsv } from "./csv";

/**
 * A parsed table (a CSV or TSV file, JSONL records) in a scroll of its own that scrolls both ways: a sticky header
 * row, sticky row numbers (each shows a shadow once the body scrolls under it), columns sized to their content that
 * fill a wide panel, numbers set to the right in tabular figures, and web/mailto links that open in the browser.
 * The notice of what was cut (`PreviewDataTableNotice`) goes above it, outside the scroll.
 */
export function PreviewDataTable({
  table,
  testId,
  onOpenBrowser,
  children,
}: {
  table: ParsedCsv;
  /** On the element that holds the `<table>`. */
  testId: string;
  onOpenBrowser: (url: string) => void;
  /** Content after the table, in the same scroll. */
  children?: ReactNode;
}) {
  const linkHandlers = usePreviewLinkHandlers(onOpenBrowser);
  const { fill, rowNumberWidth } = csvTableLayout(table);
  return (
    <ScrollArea
      className="min-h-0 flex-1"
      viewportClassName="h-full"
      contentClassName="flex min-h-full w-max min-w-full flex-col"
      edgeEffect="none"
      orientation="both"
    >
      <div className="flex min-h-full flex-1 flex-col">
        <div className="min-w-0 flex-1" data-testid={testId} {...linkHandlers}>
          <table className="comma-csv-table">
            <colgroup>
              <col style={{ width: rowNumberWidth }} />
              {table.columnWidths.map((width, index) => (
                // Columns have no identity beyond their order. The fill column has no width: it takes what the panel
                // has beyond the table's own width.
                // eslint-disable-next-line react/no-array-index-key
                <col
                  key={index}
                  style={index === fill ? undefined : { width: `${width}px` }}
                />
              ))}
            </colgroup>
            <thead>
              <tr>
                <th className="comma-csv-corner" scope="col">
                  #
                </th>
                {table.headers.map((header, columnIndex) => (
                  <th
                    data-number={table.numericColumns[columnIndex] ? "true" : undefined}
                    // eslint-disable-next-line react/no-array-index-key
                    key={columnIndex}
                    scope="col"
                    title={header || undefined}
                  >
                    <span className="comma-csv-cell">{header}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((row, rowIndex) => (
                // Rows have no identity beyond their order.
                // eslint-disable-next-line react/no-array-index-key
                <tr key={rowIndex}>
                  <th scope="row">{rowIndex + 1}</th>
                  {row.map((cell, columnIndex) => {
                    const trimmed = cell.trim();
                    return (
                      <td
                        data-number={
                          table.numericColumns[columnIndex] ? "true" : undefined
                        }
                        // eslint-disable-next-line react/no-array-index-key
                        key={columnIndex}
                        title={cell || undefined}
                      >
                        <span className="comma-csv-cell">
                          {isCellUrl(trimmed) ? <a href={trimmed}>{trimmed}</a> : cell}
                        </span>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {children}
      </div>
    </ScrollArea>
  );
}

/** What a cut table leaves out ("Showing the first 500 rows…"), or nothing when it shows all of the file. */
export function PreviewDataTableNotice({
  table,
  testId,
}: {
  table: ParsedCsv;
  testId?: string | undefined;
}) {
  const messages = useCommaMessages();
  if (!table.rowsCut && !table.columnsCut) return null;
  return (
    <PreviewNotice testId={testId}>
      {table.columnsCut
        ? messages.file_preview_csv_truncated({
            rows: table.rows.length,
            columns: table.columnCount,
          })
        : messages.file_preview_csv_truncated_rows({ rows: table.rows.length })}
    </PreviewNotice>
  );
}
