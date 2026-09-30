import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { ProductInboxListResult } from "@comma/native-bridge";
import { toast } from "@comma/ui";
import { useEffect } from "react";
import { productInboxErrorMessage } from "../../product-inbox";

const INBOX_SYNC_TOAST_ID = "inbox-sync-state";
const INBOX_LOAD_MORE_TOAST_ID = "inbox-load-more-error";

/**
 * Sync degradation surfaces as a persistent toast (error = sync failed,
 * warning = serving cache) that dismisses itself once live sync recovers; a
 * failed load-more does the same with its own message.
 */
export function useInboxSyncToasts(
  result: ProductInboxListResult | null,
  loadMoreError: string | undefined,
  onLoadMore: (() => void) | undefined
) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const source = result?.source;
  const syncErrorCode = result?.errorCode;
  const syncDegraded =
    source === "error" ||
    source === "unavailable" ||
    (source === "cache" && Boolean(syncErrorCode));

  useEffect(() => {
    if (!syncDegraded) {
      toast.dismiss(INBOX_SYNC_TOAST_ID);
      return undefined;
    }
    const detail = syncErrorCode
      ? productInboxErrorMessage(syncErrorCode, locale)
      : undefined;
    const showSyncToast = source === "cache" ? toast.warning : toast.error;
    showSyncToast(
      source === "cache"
        ? messages.inbox_showing_cache()
        : messages.inbox_sync_failed(),
      {
        ...(detail ? { description: detail } : {}),
        duration: Number.POSITIVE_INFINITY,
        id: INBOX_SYNC_TOAST_ID,
        testId: "inbox-banner",
      }
    );
    return () => {
      toast.dismiss(INBOX_SYNC_TOAST_ID);
    };
  }, [locale, messages, source, syncDegraded, syncErrorCode]);

  useEffect(() => {
    if (!loadMoreError) {
      toast.dismiss(INBOX_LOAD_MORE_TOAST_ID);
      return undefined;
    }
    toast.error(loadMoreError, {
      ...(onLoadMore
        ? { actions: [{ label: messages.common_retry(), onPress: onLoadMore }] }
        : {}),
      duration: Number.POSITIVE_INFINITY,
      id: INBOX_LOAD_MORE_TOAST_ID,
      testId: "inbox-load-more-error",
    });
    return () => {
      toast.dismiss(INBOX_LOAD_MORE_TOAST_ID);
    };
  }, [loadMoreError, messages, onLoadMore]);
}
