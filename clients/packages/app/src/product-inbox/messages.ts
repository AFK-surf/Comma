import type { ProductInboxListResult } from "@comma/core-client";
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";

export function productInboxUnavailableResult(
  errorCode: NonNullable<ProductInboxListResult["errorCode"]>
): ProductInboxListResult {
  return { errorCode, items: [], source: "unavailable" };
}

export function productInboxErrorMessage(
  errorCode: ProductInboxListResult["errorCode"] | string,
  locale: CommaLocale = baseLocale
): string {
  switch (errorCode) {
    case "network_unavailable":
      return messages.product_inbox_network_unavailable({}, { locale });
    case "protocol_mismatch":
      return messages.product_inbox_protocol_mismatch({}, { locale });
    case "session_product_lease_unavailable":
      return messages.product_inbox_session_lease_unavailable({}, { locale });
    case "utility_unavailable":
      return messages.product_inbox_utility_unavailable({}, { locale });
    default:
      return messages.product_inbox_unavailable({}, { locale });
  }
}
