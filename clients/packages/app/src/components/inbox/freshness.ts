import type { ProductInboxItem, ProductInboxListSource } from "@comma/native-bridge";

export type ProductFreshness = NonNullable<ProductInboxItem["freshness"]>;

export function effectiveProductFreshness(
  freshness: ProductInboxItem["freshness"],
  source: ProductInboxListSource
): ProductFreshness {
  if (source !== "live-sync") return "stale";
  return freshness ?? "unknown";
}
