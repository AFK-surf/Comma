import { useCommaMessages } from "@comma/i18n/react";
import type { BrowserElementInspectionContext } from "../../../../chat-sidebar/browserElementInspection";

export function BrowserElementInspectionContextCard({
  context,
}: {
  context: BrowserElementInspectionContext;
}) {
  const messagesApi = useCommaMessages();
  const pageLabel = context.pageTitle || context.pageUrl;
  return (
    <div
      className="comma-chat-browser-inspection-context"
      data-testid="chat-browser-inspection-context"
    >
      <div className="comma-chat-browser-inspection-context-label">
        {messagesApi.chat_browser_inspection_context()}
      </div>
      <div
        className="comma-chat-browser-inspection-context-page"
        title={context.pageUrl}
      >
        {pageLabel}
      </div>
      <code className="comma-chat-browser-inspection-context-selector">
        {context.selector}
      </code>
      {context.elementText ? (
        <div className="comma-chat-browser-inspection-context-text">
          {context.elementText}
        </div>
      ) : null}
    </div>
  );
}
