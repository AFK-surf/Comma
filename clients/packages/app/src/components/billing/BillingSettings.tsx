import { Button, InputField } from "@comma/ui";
import type { CommaBillingPlan, CommaBillingSummary } from "../../api";
import { panelTabButton } from "../panelTabButton";

export type BillingPeriod = "month" | "year";

export const billingPeriods: readonly BillingPeriod[] = ["month", "year"];

export interface CreditAllowance {
  percent: number;
  total: number;
}

/** Measure remaining credits only when every active grant has a known original amount. */
export function creditAllowance(
  summary: CommaBillingSummary | undefined,
  plans: readonly CommaBillingPlan[]
): CreditAllowance | undefined {
  if (!summary) return undefined;
  let total = 0;
  for (const grant of summary.active_grants) {
    const currentPlan = summary.active_subscription?.plan;
    const plan = [currentPlan, ...plans].find(
      (item) =>
        item &&
        item.package_code === grant.package_code &&
        item.package_version === grant.package_version
    );
    if (!plan) return undefined;
    total += plan.grant_credits;
  }
  if (total <= 0) return undefined;
  const percent = Math.round(
    Math.max(0, Math.min(1, summary.current_credits / total)) * 100
  );
  return { percent, total };
}

export function formatPrice(plan: CommaBillingPlan, locale: string) {
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: plan.currency.toUpperCase(),
  }).format(plan.amount_minor / 100);
}

export function billingPeriodLabel(period: string | null | undefined, zh: boolean) {
  const labels: Record<string, readonly [string, string]> = {
    day: ["天", "day"],
    week: ["周", "week"],
    month: ["月", "month"],
    year: ["年", "year"],
  };
  return labels[period ?? ""]?.[zh ? 0 : 1] ?? (zh ? "周期" : "billing period");
}

export function subscriptionStatusLabel(status: string, zh: boolean) {
  const labels: Record<string, readonly [string, string]> = {
    active: ["生效中", "Active"],
    trialing: ["试用中", "Trialing"],
    past_due: ["付款逾期", "Past due"],
  };
  return labels[status]?.[zh ? 0 : 1] ?? status;
}

/** "$20.00 / month" — the price as a plan row or the plan summary says it. */
export function subscriptionPrice(plan: CommaBillingPlan, locale: string, zh: boolean) {
  return `${formatPrice(plan, locale)} / ${billingPeriodLabel(plan.billing_period, zh)}`;
}

export function subscriptionPlanDetail(
  plan: CommaBillingPlan,
  locale: string,
  number: Intl.NumberFormat,
  zh: boolean
) {
  const credits = number.format(plan.grant_credits);
  return zh
    ? `${subscriptionPrice(plan, locale, zh)} · 每月到账 ${credits} credits`
    : `${subscriptionPrice(plan, locale, zh)} · ${credits} credits every month`;
}

export function subscriptionActionLabel(
  plan: CommaBillingPlan,
  activePlan: CommaBillingPlan | undefined,
  zh: boolean
) {
  // The row already says the period twice (pill and price), so the button does not.
  if (!activePlan) return zh ? "订阅" : "Subscribe";
  if (plan.grant_credits > activePlan.grant_credits) {
    return zh ? `升级到 ${plan.name}` : `Upgrade to ${plan.name}`;
  }
  if (plan.grant_credits < activePlan.grant_credits) {
    return zh ? `降级到 ${plan.name}` : `Downgrade to ${plan.name}`;
  }
  return zh ? "切换计费周期" : "Switch billing period";
}

/**
 * The period switch is a view over one list, so it takes the same pill the
 * Drive panels use, not a form control. It sits as the first row of the plans
 * card, the way the reference puts its tabs inside the card; the row backs out
 * of the pill's own px-md so the first label starts on the rows' text edge.
 */
export function BillingPeriodTabs({
  available,
  onChange,
  period,
  zh,
}: {
  available: readonly BillingPeriod[];
  onChange: (period: BillingPeriod) => void;
  period: BillingPeriod;
  zh: boolean;
}) {
  return (
    <fieldset
      aria-label={zh ? "计费周期" : "Billing period"}
      className="m-0 -ml-xs flex min-w-0 items-center gap-xs border-0 p-0"
    >
      {billingPeriods.map((item) => (
        <button
          aria-pressed={period === item}
          className={panelTabButton(period === item)}
          disabled={!available.includes(item)}
          key={item}
          onClick={() => onChange(item)}
          type="button"
        >
          {item === "year" ? (zh ? "年付" : "Annual") : zh ? "月付" : "Monthly"}
        </button>
      ))}
    </fieldset>
  );
}

/** Remaining credits across active grants, including subscription credits and packs. */
export function BillingAllowanceMeter({
  allowance,
  zh,
}: {
  allowance: CreditAllowance;
  zh: boolean;
}) {
  return (
    <div className="flex items-center gap-lg">
      <progress
        aria-label={zh ? "剩余 credits" : "Credits remaining"}
        className="h-1.5 w-[var(--spacing-11xl)] appearance-none [&::-moz-progress-bar]:rounded-full [&::-moz-progress-bar]:bg-brand-solid [&::-webkit-progress-bar]:rounded-full [&::-webkit-progress-bar]:bg-tertiary [&::-webkit-progress-value]:rounded-full [&::-webkit-progress-value]:bg-brand-solid"
        max={100}
        value={allowance.percent}
      />
      <span className="min-w-[7ch] text-right text-sm text-tertiary tabular-nums">
        {zh ? `剩余 ${allowance.percent}%` : `${allowance.percent}% left`}
      </span>
    </div>
  );
}

export interface BillingRedeemFormProps {
  code: string;
  disabled: boolean;
  error: string | undefined;
  notice: string | undefined;
  onCodeChange: (code: string) => void;
  onSubmit: () => void;
  pending: boolean;
  zh: boolean;
}

/** The redeem row: one field and its button, the outcome under them. */
export function BillingRedeemForm({
  code,
  disabled,
  error,
  notice,
  onCodeChange,
  onSubmit,
  pending,
  zh,
}: BillingRedeemFormProps) {
  return (
    <form
      className="flex w-full flex-col gap-md"
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit();
      }}
    >
      <div className="flex flex-wrap items-center gap-md">
        <div className="min-w-0 flex-[1_1_16rem]">
          <InputField
            aria-label={zh ? "兑换码" : "Redeem code"}
            className="w-full"
            fieldSize="sm"
            onChange={(event) => onCodeChange(event.target.value)}
            placeholder={zh ? "输入兑换码" : "Enter redeem code"}
            value={code}
          />
        </div>
        <Button
          hierarchy="secondary-gray"
          isDisabled={disabled || pending || code.trim().length < 3}
          size="sm"
          type="submit"
        >
          {pending ? (zh ? "兑换中…" : "Redeeming…") : zh ? "兑换" : "Redeem"}
        </Button>
      </div>
      {notice ? (
        <output className="text-sm text-success-primary">{notice}</output>
      ) : null}
      {error ? (
        <p className="m-0 text-sm text-error-primary" role="alert">
          {error}
        </p>
      ) : null}
    </form>
  );
}
