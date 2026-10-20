import type { ProductInboxItem, ProductInboxListSource } from "@comma/core-client";

export type ProductFreshness = NonNullable<ProductInboxItem["freshness"]>;

export function effectiveProductFreshness(
  freshness: ProductInboxItem["freshness"],
  source: ProductInboxListSource
): ProductFreshness {
  if (source !== "live-sync") return "stale";
  return freshness ?? "unknown";
}
