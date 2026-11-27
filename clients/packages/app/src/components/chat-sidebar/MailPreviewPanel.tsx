import { useTopic } from "@comma/core-client";
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { ArrowUpRightIcon, ReloadIcon } from "@comma/ui/components/icons";
import { RightSidebarToolbarButton } from "@comma/ui/components/right-sidebar";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useCallback, useEffect, useMemo, useState } from "react";
import { openUrlInExternalBrowser } from "../chat/thread/inline/linkActions";
import { LinkProviderIcon, providerFromHref } from "../links/linkPreviewCards";
import type { ChatSidebarMailPreview } from "./ChatSidebarContext";

export function MailPreviewPanel({
  active,
  onTitleChange,
  preview: tab,
}: {
  active: boolean;
  onTitleChange?: ((title: string) => void) | undefined;
  preview: ChatSidebarMailPreview;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [refreshCount, setRefreshCount] = useState(0);

  const triggerRefresh = useCallback(() => {
    setRefreshCount((count) => count + 1);
  }, []);

  const { value } = useTopic(
    active
      ? {
          topic: "linkPreview",
          workspace: tab.workspaceId,
          href: tab.href,
          source: "",
          read: String(refreshCount),
        }
      : null,
    { lingerMs: 0 }
  );

  const source = useMemo(
    () => providerFromHref(tab.href) ?? { appId: "outlook", appName: "Mail" },
    [tab.href]
  );
  const providerName = source.appName ?? "Mail";

  const readyPreview =
    value?.status === "ready" &&
    (value.preview.kind === "outlook_message" ||
      value.preview.kind === "outlook_event" ||
      value.preview.kind === "gmail_message")
      ? value.preview
      : undefined;

  useEffect(() => {
    if (readyPreview?.title && readyPreview.title !== tab.title) {
      onTitleChange?.(readyPreview.title);
    }
  }, [onTitleChange, readyPreview?.title, tab.title]);

  const title = readyPreview?.title ?? tab.title ?? providerName;
  const loading = !value || value.status === "loading";
  const openExternalLabel = messages.mail_preview_open_in({
    provider: providerName,
  });

  const bodyText = readyPreview?.body?.trim() || readyPreview?.excerpt?.trim() || "";
  const timestamp =
    readyPreview?.receivedAt ??
    (readyPreview && "startsAt" in readyPreview ? readyPreview.startsAt : null) ??
    null;

  return (
    <div className="comma-stillfail-panel" data-testid="mail-preview-panel">
      <header className="comma-stillfail-header">
        <div className="comma-stillfail-header-main">
          <span aria-hidden="true" className="comma-stillfail-header-mark">
            <LinkProviderIcon source={source} />
          </span>
          <span className="comma-stillfail-header-title" title={title}>
            {title}
          </span>
          <span className="comma-stillfail-station">{providerName}</span>
        </div>
        <div className="comma-stillfail-header-actions">
          <RightSidebarToolbarButton
            aria-label={messages.stillfail_preview_refresh()}
            onClick={triggerRefresh}
            title={messages.stillfail_preview_refresh()}
          >
            <ReloadIcon className="size-4" />
          </RightSidebarToolbarButton>
          <RightSidebarToolbarButton
            aria-label={openExternalLabel}
            onClick={() => {
              void openUrlInExternalBrowser(readyPreview?.href ?? tab.href);
            }}
            title={openExternalLabel}
          >
            <ArrowUpRightIcon className="size-4" />
          </RightSidebarToolbarButton>
        </div>
      </header>

      <ScrollArea className="min-h-0 flex-1">
        {loading ? (
          <div className="flex items-center justify-center py-4xl">
            <LoadingIndicator label={title} />
          </div>
        ) : !readyPreview ? (
          <div className="comma-stillfail-thread">
            <div className="comma-stillfail-notice">
              <span>{messages.mail_preview_unavailable()}</span>
              <Button
                hierarchy="secondary-gray"
                iconTrailing={<ArrowUpRightIcon />}
                onPress={() => {
                  void openUrlInExternalBrowser(tab.href);
                }}
                size="sm"
              >
                {openExternalLabel}
              </Button>
            </div>
          </div>
        ) : (
          <article className="comma-mail-reader">
            <div className="comma-mail-meta">
              <h2 className="comma-mail-subject">{readyPreview.title}</h2>
              <div className="comma-mail-fields">
                {readyPreview.sender ? (
                  <div className="comma-mail-field">
                    <span className="comma-mail-field-label">
                      {messages.mail_preview_from()}
                    </span>
                    <span className="comma-mail-field-value">
                      {readyPreview.sender}
                    </span>
                  </div>
                ) : null}
                {readyPreview.recipients ? (
                  <div className="comma-mail-field">
                    <span className="comma-mail-field-label">
                      {messages.mail_preview_to()}
                    </span>
                    <span className="comma-mail-field-value">
                      {readyPreview.recipients}
                    </span>
                  </div>
                ) : null}
                {timestamp !== null ? (
                  <time
                    className="text-xs text-text-quaternary"
                    dateTime={new Date(timestamp).toISOString()}
                  >
                    {formatDate(timestamp, locale, {
                      year: "numeric",
                      month: "short",
                      day: "numeric",
                      hour: "numeric",
                      minute: "2-digit",
                    })}
                  </time>
                ) : null}
              </div>
            </div>

            {bodyText ? (
              <div className="comma-mail-body">{bodyText}</div>
            ) : (
              <div className="comma-stillfail-notice">
                <span>{messages.mail_preview_empty()}</span>
              </div>
            )}
          </article>
        )}
      </ScrollArea>
    </div>
  );
}
