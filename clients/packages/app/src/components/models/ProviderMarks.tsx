import { Button as AriaButton } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import {
  ModelIcon,
  ModelVendorIcon,
  Tooltip,
  hasModelIcon,
  hasModelVendorLogo,
} from "@comma/ui";
import type { QuotaMeter } from "./providerPresets";

/** A provider's logo, or its initial where no logo exists yet. */
export function ProviderMark({ brand, name }: { brand: string; name: string }) {
  if (hasModelVendorLogo(brand)) return <ModelVendorIcon vendor={brand} />;
  if (hasModelIcon(brand) || brand === "custom") return <ModelIcon brand={brand} />;
  return (
    <span
      aria-hidden="true"
      className="flex size-4 shrink-0 items-center justify-center rounded-[4px] bg-tertiary text-[9px] font-semibold leading-none text-secondary"
    >
      {name.charAt(0)}
    </span>
  );
}

const resetTime = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

/** What is left of each plan window, with its reset time on hover. */
export function QuotaMeters({ meters }: { meters: readonly QuotaMeter[] }) {
  const m = useCommaMessages();
  return (
    <span className="flex items-center gap-md">
      {meters.map((meter) => {
        const label =
          meter.window === "5h"
            ? m.settings_providers_quota_5h()
            : m.settings_providers_quota_week();
        const left = m.settings_providers_quota_left({ percent: meter.percent });
        return (
          <Tooltip
            key={meter.window}
            content={
              meter.resetAt
                ? m.settings_providers_quota_reset({
                    window: label,
                    time: resetTime.format(new Date(meter.resetAt)),
                  })
                : label
            }
            supportingText={left}
          >
            <AriaButton
              aria-label={`${label} · ${left}`}
              className="flex cursor-default items-center gap-xs rounded-sm outline-none focus-visible:ring-2"
            >
              <span className="text-xs text-tertiary">{label}</span>
              <span className="h-1.5 w-10 overflow-hidden rounded-full bg-tertiary">
                <span
                  className={
                    "block h-full rounded-full " +
                    (meter.percent < 10 ? "bg-error-solid" : "bg-brand-solid")
                  }
                  style={{ width: `${meter.percent}%` }}
                />
              </span>
              <span className="w-[4ch] text-xs tabular-nums text-secondary">
                {meter.percent}%
              </span>
            </AriaButton>
          </Tooltip>
        );
      })}
    </span>
  );
}
