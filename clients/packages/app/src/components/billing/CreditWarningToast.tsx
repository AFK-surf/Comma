import { useEffect } from "react";
import { useCommaLocale } from "@comma/i18n/react";
import { useCreditWarning } from "./useCreditWarning";

export function CreditWarningToast({
  workspaceId,
  active,
}: {
  workspaceId: string | undefined;
  active: boolean;
}) {
  const locale = useCommaLocale();
  const { warning, showToast } = useCreditWarning(workspaceId, active);
  useEffect(() => showToast(locale), [locale, showToast, warning]);
  return null;
}
