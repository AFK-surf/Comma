// Redeem code records as Billing shows them: never with plaintext, labelled by package and scope.
import type { Types } from "effect";
import type { AdminPackageVersion, AdminRedeemCode, AdminRedemption } from "./adminApi";
import { messages } from "@comma/i18n";

export const billingViewLimit = 100;

export type CatalogRedeemCode = AdminRedeemCode & { code?: never };

export function withoutRedeemCodePlaintext(code: AdminRedeemCode): CatalogRedeemCode {
  const catalogCode: Types.Mutable<AdminRedeemCode> = { ...code };
  delete catalogCode.code;
  return catalogCode as CatalogRedeemCode;
}

export function packageVersionKey(version: AdminPackageVersion) {
  return `${version.package_code}\u0000${version.version}`;
}

export function selectedPackage(
  packages: ReadonlyArray<AdminPackageVersion>,
  packageKey: string
) {
  return packages.find((item) => packageVersionKey(item) === packageKey);
}

// The same text adminUi's displayText shows.
export function displayPrefix(code: AdminRedeemCode) {
  return code.display_prefix?.trim() || "—";
}

export function packageLabel(
  code: AdminRedeemCode,
  packages: ReadonlyArray<AdminPackageVersion>
) {
  const raw = `${code.package_code}@${code.package_version}`;
  const matched = packages.find(
    (version) =>
      version.package_code === code.package_code &&
      version.version === code.package_version
  );
  return matched?.package_name ? `${matched.package_name} · ${raw}` : raw;
}

export function scopeLabel(code: AdminRedeemCode) {
  if (code.scope_product_owner_type && code.scope_product_owner_id) {
    return `${code.scope_product_owner_type}:${code.scope_product_owner_id}`;
  }
  return code.scope_product_owner_type || messages.admin_scope_global();
}

export function redemptionOwner(redemption: AdminRedemption) {
  if (redemption.product_owner_type && redemption.product_owner_id) {
    return `${redemption.product_owner_type}:${redemption.product_owner_id}`;
  }
  return redemption.product_owner_id || "—";
}
