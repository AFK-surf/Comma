export const billingSettingsRoute = "/settings?category=usage-billing";

export type BillingReturn = {
  status: "cancel" | "portal" | "subscription" | "success";
  url: string;
};

export function billingSettingsRouteForReturn(status: BillingReturn["status"]): string {
  return `${billingSettingsRoute}&billing-return=${status}`;
}

export function parseBillingReturnUrl(
  value: string,
  expectedScheme: string
): BillingReturn | undefined {
  try {
    const url = new URL(value);
    if (url.protocol !== `${expectedScheme}:`) return undefined;
    if (url.hostname !== "billing" || url.pathname !== "/return") return undefined;

    const status = url.searchParams.get("status");
    if (
      status !== "success" &&
      status !== "cancel" &&
      status !== "portal" &&
      status !== "subscription"
    ) {
      return undefined;
    }
    return { status, url: url.toString() };
  } catch {
    return undefined;
  }
}

export function findBillingReturnUrl(
  argv: readonly string[],
  expectedScheme: string
): BillingReturn | undefined {
  for (const value of argv) {
    const parsed = parseBillingReturnUrl(value, expectedScheme);
    if (parsed) return parsed;
  }
  return undefined;
}
