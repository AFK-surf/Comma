import type { ReactNode } from "react";
import { LoadingIndicator } from "@comma/ui";
import { formatDate } from "@comma/i18n";
import { useCommaI18n, useCommaMessages } from "@comma/i18n/react";
import { Badge, Dialog } from "@comma/ui";
import type { SettingsCategoryDefinition, SettingsPanelItem } from "@comma/ui";
import { useCallback, useEffect, useMemo, useState } from "react";
import type {
  CommaApiClient,
  CommaBillingPlan,
  CommaBillingSummary,
  CommaBillingChangePreview,
  CommaWorkspace,
} from "../../api";
import { CommaApiError } from "../../api";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../runtime-chat/nativePlatformActions";
import { readActiveWorkspaceId } from "../activeWorkspace";
import {
  BillingAllowanceMeter,
  type BillingPeriod,
  billingPeriods,
  BillingPeriodTabs,
  BillingRedeemForm,
  creditAllowance,
  formatPrice,
  subscriptionActionLabel,
  subscriptionPlanDetail,
  subscriptionPrice,
  subscriptionStatusLabel,
} from "./BillingSettings";

/**
 * The Settings › Usage & billing category, as five cards of rows: status
 * first (which plan, how many credits, how much of this cycle is left), then
 * what is for sale (subscription plans, credit packs), then the redeem code.
 *
 * Billing state lives here rather than in a mounted component so every row
 * is a registry row; the catalog and summary load when the category opens.
 */
export function useUsageBillingCategory(
  api: CommaApiClient,
  enabled: boolean
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const { locale } = useCommaI18n();
  const zh = locale === "zh-CN";
  const [workspace, setWorkspace] = useState<CommaWorkspace>();
  const [plans, setPlans] = useState<CommaBillingPlan[]>([]);
  const [summary, setSummary] = useState<CommaBillingSummary>();
  const [code, setCode] = useState("");
  const [pending, setPending] = useState<string>();
  // An error stays with the page whose action raised it.
  const [error, setError] = useState<{ key: string; message: string }>();
  const [notice, setNotice] = useState<string>();
  const [changeQuote, setChangeQuote] = useState<{
    plan: CommaBillingPlan;
    preview: CommaBillingChangePreview;
    requestId: string;
  }>();
  const [billingPeriod, setBillingPeriod] = useState<BillingPeriod>("month");

  const number = useMemo(() => new Intl.NumberFormat(locale), [locale]);
  const activeSubscription = summary?.active_subscription;
  const isActivePlan = (plan: CommaBillingPlan) =>
    activeSubscription?.package_code === plan.package_code &&
    activeSubscription.package_version === plan.package_version;
  const activePlan = activeSubscription?.plan ?? undefined;
  const availablePeriods = billingPeriods.filter(
    (period) =>
      (!activePlan || activePlan.billing_period === period) &&
      plans.some(
        (plan) => plan.mode === "subscription" && plan.billing_period === period
      )
  );
  // A catalog with only one period shows that period, whichever pill was last
  // chosen; the other pill stays visible but cannot be selected.
  const period = availablePeriods.includes(billingPeriod)
    ? billingPeriod
    : (availablePeriods[0] ?? billingPeriod);
  const subscriptionPlans = plans.filter(
    (plan) => plan.mode === "subscription" && plan.billing_period === period
  );
  const creditPacks = plans.filter((plan) => plan.mode === "payment");
  const allowance = useMemo(() => creditAllowance(summary, plans), [summary, plans]);
  const loading = pending === "load";
  const opening = zh ? "正在打开…" : "Opening…";

  const reload = useCallback(
    async (signal?: AbortSignal) => {
      const options = signal ? { signal } : {};
      const [availablePlans, workspaces] = await Promise.all([
        api.listBillingPlans(options),
        api.listWorkspaces(options),
      ]);
      const activeId = readActiveWorkspaceId();
      const selected = workspaces.find((item) => item.id === activeId) ?? workspaces[0];
      if (!selected) throw new Error("workspace_missing");
      if (signal?.aborted) return;
      setWorkspace(selected);
      setPlans(availablePlans);
      const nextSummary = await api.getBillingSummary(selected.id, options);
      if (signal?.aborted) return;
      setSummary(nextSummary);
      return { baseline: nextSummary, workspaceId: selected.id };
    },
    [api]
  );

  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    setPending("load");
    setError(undefined);
    void reload(controller.signal)
      .then(async (loaded) => {
        if (!controller.signal.aborted) setError(undefined);
        if (!loaded || !shouldRefreshBillingReturn()) return;
        const { baseline, workspaceId } = loaded;

        // Stripe webhook delivery can trail the browser return by a few seconds.
        // Keep this client refresh deliberately bounded: four summary reads over
        // 4.2 seconds, independent of catalog/workspace cardinality.
        for (const delayMs of [600, 1_200, 2_400]) {
          await abortableDelay(delayMs, controller.signal);
          const next = await api.getBillingSummary(workspaceId, {
            signal: controller.signal,
          });
          if (controller.signal.aborted) return;
          setSummary(next);
          if (billingSummaryChanged(baseline, next)) return;
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setError({
            key: "load",
            message: zh
              ? "账单信息暂时无法加载，请稍后重试。"
              : "Billing is temporarily unavailable. Try again shortly.",
          });
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setPending(undefined);
      });
    return () => controller.abort();
  }, [api, enabled, reload, zh]);

  const run = async (key: string, action: () => Promise<void>) => {
    setPending(key);
    setError(undefined);
    setNotice(undefined);
    try {
      await action();
    } catch (reason) {
      setError({ key, message: billingErrorMessage(reason, zh) });
    } finally {
      setPending(undefined);
    }
  };

  const startCheckout = (plan: CommaBillingPlan) => {
    if (!workspace) return;
    void run(plan.plan_key, async () => {
      await openNativePlatformExternalUrlFromUserAction(async () => {
        const session = await api.createBillingCheckout(workspace.id, plan.plan_key);
        return session.url;
      });
    });
  };

  const startSubscriptionChange = (plan: CommaBillingPlan) => {
    if (!workspace) return;
    void run(plan.plan_key, async () => {
      const preview = await api.previewBillingSubscriptionChange(
        workspace.id,
        plan.plan_key
      );
      setChangeQuote({ plan, preview, requestId: crypto.randomUUID() });
    });
  };

  const confirmSubscriptionChange = () => {
    if (!workspace || !changeQuote) return;
    const quote = changeQuote;
    void run(quote.plan.plan_key, async () => {
      const execute = async () =>
        api.changeBillingSubscription(
          workspace.id,
          quote.plan.plan_key,
          quote.preview,
          quote.requestId
        );
      if (quote.preview.effect === "upgrade") {
        await openNativePlatformExternalUrlFromUserAction(async () => {
          const result = await execute();
          if (!result.url) throw new Error("subscription_payment_failed");
          return result.url;
        });
      } else {
        await execute();
      }
      setChangeQuote(undefined);
      await reload();
    });
  };

  const openPortal = () => {
    if (!workspace) return;
    void run("portal", async () => {
      const session = await api.createBillingPortal(workspace.id);
      await openNativePlatformExternalUrl(session.url);
    });
  };

  const redeem = () => {
    const normalized = code.trim();
    if (!workspace || normalized.length < 3) return;
    void run("redeem", async () => {
      await api.redeemBillingCode(workspace.id, normalized);
      const next = await api.getBillingSummary(workspace.id);
      setSummary(next);
      setCode("");
      setNotice(
        zh ? "兑换成功，credits 已到账。" : "Code redeemed. Your credits are ready."
      );
    });
  };

  const packKeys = new Set(creditPacks.map((plan) => plan.plan_key));
  const planKeys = new Set(
    plans.filter((plan) => plan.mode === "subscription").map((plan) => plan.plan_key)
  );
  const errorFor = (owns: (key: string) => boolean) =>
    error && owns(error.key) ? error.message : undefined;
  // An annual payment also creates monthly grants. Their expiry is not a renewal date.
  const subscriptionCreditExpiry = summary?.active_grants
    .filter((grant) => grant.source_type === "subscription_cycle" && grant.expires_at)
    .map((grant) => new Date(grant.expires_at!))
    .filter((date) => Number.isFinite(date.getTime()))
    .toSorted((left, right) => left.getTime() - right.getTime())[0];
  const creditExpiry = subscriptionCreditExpiry
    ? zh
      ? `订阅 credits 到期日：${formatDate(subscriptionCreditExpiry, locale, { dateStyle: "medium" })}`
      : `Subscription credits expire ${formatDate(subscriptionCreditExpiry, locale, { dateStyle: "medium" })}`
    : undefined;

  // Your plan: one row — what you are on, and the way to Stripe for its
  // invoices and payment method.
  const planRows: SettingsPanelItem[] = [
    {
      id: "billing.plan.current",
      title: loading
        ? "—"
        : (activePlan?.name ??
          activeSubscription?.package_code ??
          (zh ? "未订阅" : "No subscription")),
      description: activeSubscription
        ? [
            activePlan ? subscriptionPrice(activePlan, locale, zh) : undefined,
            subscriptionStatusLabel(activeSubscription.status, zh),
          ]
            .filter(Boolean)
            .join(" · ")
        : zh
          ? "订阅后每月到账 credits。"
          : "Subscribe for a monthly credit allowance.",
      keywords: ["subscription", "invoice", "stripe", "cancel", "订阅", "发票", "取消"],
      ...(activeSubscription
        ? {
            control: {
              type: "button" as const,
              label: pending === "portal" ? opening : m.settings_manage(),
              disabled: loading || pending === "portal",
              onPress: openPortal,
            },
          }
        : {}),
    },
    ...errorRow(
      "billing.plan.error",
      errorFor((key) => key === "load" || key === "portal")
    ),
  ];

  // The balance includes all active grants. The subscription expiry is a separate fact.
  const balanceRows: SettingsPanelItem[] = [
    {
      id: "billing.credits.balance",
      title: loading ? "—" : number.format(summary?.current_credits ?? 0),
      description: [
        workspace?.name,
        allowance
          ? zh
            ? `有效额度初始共 ${number.format(allowance.total)} credits`
            : `${number.format(allowance.total)} original credits across active grants`
          : zh
            ? "当前余额"
            : "Current balance",
        creditExpiry,
      ]
        .filter(Boolean)
        .join(" · "),
      keywords: ["credits", "balance", "余额"],
      ...(allowance
        ? {
            control: {
              type: "custom" as const,
              content: <BillingAllowanceMeter allowance={allowance} zh={zh} />,
            },
          }
        : {}),
    },
  ];

  // Subscription plans: the period switch is the card's first row, then one
  // row per plan of that period.
  const planListRows: SettingsPanelItem[] = [
    ...(availablePeriods.length > 0
      ? [
          {
            id: "billing.plans.period",
            title: zh ? "计费周期" : "Billing period",
            layout: "stack" as const,
            control: {
              type: "custom" as const,
              content: (
                <BillingPeriodTabs
                  available={availablePeriods}
                  onChange={setBillingPeriod}
                  period={period}
                  zh={zh}
                />
              ),
            },
          },
          ...subscriptionPlans.map(
            (plan): SettingsPanelItem => ({
              id: `billing.plans.${plan.plan_key}`,
              title: plan.name,
              description: subscriptionPlanDetail(plan, locale, number, zh),
              keywords: ["subscription", "upgrade", "订阅", "升级"],
              control: isActivePlan(plan)
                ? {
                    type: "custom",
                    content: (
                      <Badge color="success" size="sm">
                        {zh ? "当前套餐" : "Current plan"}
                      </Badge>
                    ),
                  }
                : {
                    type: "button",
                    label:
                      pending === plan.plan_key
                        ? opening
                        : subscriptionActionLabel(plan, activePlan, zh),
                    disabled: loading || pending === plan.plan_key,
                    onPress: () =>
                      activeSubscription
                        ? startSubscriptionChange(plan)
                        : startCheckout(plan),
                  },
            })
          ),
        ]
      : [
          emptyRow(
            "billing.plans.empty",
            zh ? "订阅套餐" : "Subscription plans",
            loading ? (
              <LoadingIndicator label={zh ? "正在加载套餐…" : "Loading plans…"} />
            ) : zh ? (
              "暂无可用订阅套餐。"
            ) : (
              "No subscription plans available."
            )
          ),
        ]),
    ...errorRow(
      "billing.plans.error",
      errorFor((key) => planKeys.has(key))
    ),
  ];

  if (changeQuote) {
    const preview = changeQuote.preview;
    const due = new Intl.NumberFormat(locale, {
      style: "currency",
      currency: preview.currency,
    }).format(preview.amount_minor / 100);
    const nextBill = formatDate(new Date(preview.period_end * 1000), locale, {
      dateStyle: "medium",
    });
    const description =
      preview.effect === "upgrade"
        ? zh
          ? `立即收取差价 ${due}。付款成功后升档。原定降档将被取消，付款失败不自动恢复。`
          : `Pay ${due} now. The upgrade applies after payment. This cancels any scheduled downgrade, which is not restored if payment fails.`
        : preview.effect === "downgrade"
          ? zh
            ? `${nextBill} 下次续费时降档。当前已付期间的套餐和额度保留。`
            : `The downgrade applies at your next renewal on ${nextBill}. Your current paid plan and credits remain available.`
          : zh
            ? "取消待降档，保持当前套餐。"
            : "Cancel the scheduled downgrade and keep your current plan.";
    planListRows.push({
      id: "billing.plans.confirm",
      title: changeQuote.plan.name,
      control: {
        type: "custom",
        content: (
          <Dialog
            isOpen
            title={zh ? "确认套餐变更" : "Confirm plan change"}
            description={description}
            isDismissable={!pending}
            onOpenChange={(open) => {
              if (!open && !pending) setChangeQuote(undefined);
            }}
            actions={[
              {
                label: zh ? "取消" : "Cancel",
                hierarchy: "secondary-gray",
                disabled: !!pending,
                onPress: () => setChangeQuote(undefined),
              },
              {
                label: zh ? "确认" : "Confirm",
                hierarchy: "primary",
                disabled: !!pending,
                onPress: confirmSubscriptionChange,
              },
            ]}
          />
        ),
      },
    });
  }
  const scheduled = activeSubscription?.source_metadata?.scheduled_plan;
  if (scheduled) {
    const target = plans.find(
      (plan) =>
        plan.package_code === scheduled.package_code &&
        plan.package_version === scheduled.package_version
    );
    planRows.push({
      id: "billing.plan.scheduled",
      title: zh ? "待降档" : "Scheduled downgrade",
      description: `${target?.name ?? scheduled.package_code} · ${formatDate(new Date(scheduled.effective_at * 1000), locale, { dateStyle: "medium" })}`,
      control: {
        type: "button",
        label: zh ? "保持当前套餐" : "Keep current plan",
        disabled: !!pending || !activePlan,
        onPress: () => {
          if (activePlan) startSubscriptionChange(activePlan);
        },
      },
    });
  }

  if (activeSubscription) {
    const cancellation = activeSubscription.source_metadata?.cancel_at_period_end;
    const ends = activeSubscription.source_metadata?.current_period_end;
    planRows.push({
      id: "billing.plan.cancel",
      title: zh ? "取消续费" : "Cancel renewal",
      ...(cancellation
        ? {
            description:
              (zh ? "已取消续费" : "Renewal cancelled") +
              (ends
                ? ` · ${formatDate(new Date(ends * 1000), locale, { dateStyle: "medium" })}`
                : ""),
          }
        : {}),
      control: {
        type: "button",
        label: cancellation
          ? zh
            ? "已取消"
            : "Cancelled"
          : zh
            ? "取消续费"
            : "Cancel renewal",
        disabled: !!pending || !!cancellation,
        onPress: () => {
          if (workspace)
            void run("portal", async () => {
              await api.cancelBillingSubscriptionRenewal(workspace.id);
              await reload();
            });
        },
      },
    });
  }

  const nowUtc = new Date();
  const estimatedPackEnd = new Date(
    Date.UTC(nowUtc.getUTCFullYear(), nowUtc.getUTCMonth() + 1, 0)
  )
    .toISOString()
    .slice(0, 10);
  const paidPackExpiries = [
    ...new Set(
      (summary?.active_grants ?? [])
        .filter((grant) => grant.source_type === "stripe_checkout" && grant.expires_at)
        .map((grant) => `${grant.expires_at!.slice(0, 10)} 00:00 UTC`)
    ),
  ];

  // Credit packs: one row per pack.
  const packRows: SettingsPanelItem[] = [
    ...(paidPackExpiries.length > 0
      ? [
          {
            id: "billing.packs.paid-expiry",
            title: zh ? "已购充值包有效至" : "Purchased credits expire",
            description: paidPackExpiries.join(", "),
          },
        ]
      : []),
    ...(creditPacks.length > 0
      ? creditPacks.map(
          (plan): SettingsPanelItem => ({
            id: `billing.packs.${plan.plan_key}`,
            title: plan.name,
            description: zh
              ? `一次性 · 到账 ${number.format(plan.grant_credits)} credits · 预计 ${estimatedPackEnd} UTC 月底到期，以实际付款月份为准`
              : `One-time · ${number.format(plan.grant_credits)} credits · Estimated expiry: end of ${estimatedPackEnd} UTC, based on the payment month`,
            keywords: ["buy", "credits", "充值"],
            control: {
              type: "button",
              label: pending === plan.plan_key ? opening : formatPrice(plan, locale),
              disabled: loading || pending === plan.plan_key,
              onPress: () => startCheckout(plan),
            },
          })
        )
      : [
          emptyRow(
            "billing.packs.empty",
            m.settings_add_credits(),
            loading ? (
              <LoadingIndicator
                label={zh ? "正在加载充值包…" : "Loading credit packs…"}
              />
            ) : zh ? (
              "暂无可用充值包。"
            ) : (
              "No credit packs available."
            )
          ),
        ]),
    ...errorRow(
      "billing.packs.error",
      errorFor((key) => packKeys.has(key))
    ),
  ];

  return {
    id: "usage-billing",
    icon: "usage-billing",
    label: m.settings_usage_billing(),
    sections: [
      { id: "billing.plan", title: m.settings_your_plan(), items: planRows },
      {
        id: "billing.credits",
        title: m.settings_credits_balance(),
        items: balanceRows,
      },
      {
        id: "billing.plans",
        title: zh ? "订阅套餐" : "Subscription plans",
        items: planListRows,
      },
      { id: "billing.packs", title: m.settings_add_credits(), items: packRows },
      {
        id: "billing.redeem",
        title: m.settings_redeem_credits(),
        items: [
          {
            id: "billing.redeem.code",
            title: m.settings_redeem_code(),
            description: m.settings_redeem_credits_description(),
            keywords: ["code", "coupon", "兑换码"],
            layout: "field",
            control: {
              type: "custom",
              content: (
                <BillingRedeemForm
                  code={code}
                  disabled={loading || !workspace}
                  error={errorFor((key) => key === "redeem")}
                  notice={notice}
                  onCodeChange={setCode}
                  onSubmit={redeem}
                  pending={pending === "redeem"}
                  zh={zh}
                />
              ),
            },
          },
        ],
      },
    ],
  };
}

/** A card's last row when an action in it failed: the message, nothing else. */
function errorRow(id: string, message: string | undefined): SettingsPanelItem[] {
  return message
    ? [
        {
          id,
          title: message,
          layout: "stack",
          control: {
            type: "custom",
            content: (
              <p className="m-0 text-sm text-error-primary" role="alert">
                {message}
              </p>
            ),
          },
        },
      ]
    : [];
}

function emptyRow(id: string, title: string, text: ReactNode): SettingsPanelItem {
  return {
    id,
    title,
    layout: "stack",
    control: {
      type: "custom",
      content: <output className="text-sm text-tertiary">{text}</output>,
    },
  };
}

function shouldRefreshBillingReturn(): boolean {
  if (typeof window === "undefined") return false;
  const queryStart = window.location.hash.indexOf("?");
  if (queryStart < 0) return false;
  const status = new URLSearchParams(window.location.hash.slice(queryStart + 1)).get(
    "billing-return"
  );
  return status === "success" || status === "portal" || status === "subscription";
}

function billingSummaryChanged(
  baseline: CommaBillingSummary,
  current: CommaBillingSummary
): boolean {
  return billingSummarySnapshot(baseline) !== billingSummarySnapshot(current);
}

function billingSummarySnapshot(summary: CommaBillingSummary): string {
  return JSON.stringify({
    activeGrants: summary.active_grants
      .map((grant) => ({
        expiresAt: grant.expires_at ?? null,
        id: grant.id,
        packageCode: grant.package_code,
        packageVersion: grant.package_version,
        remainingCredits: grant.remaining_credits,
        sourceId: grant.source_id,
        sourceType: grant.source_type,
        validFrom: grant.valid_from,
      }))
      .toSorted((left, right) => left.id.localeCompare(right.id)),
    activeSubscription: summary.active_subscription
      ? {
          packageCode: summary.active_subscription.package_code,
          packageVersion: summary.active_subscription.package_version,
          sourceId: summary.active_subscription.source_id,
          status: summary.active_subscription.status,
        }
      : null,
    currentCredits: summary.current_credits,
  });
}

function abortableDelay(delayMs: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    const timer = window.setTimeout(resolve, delayMs);
    signal.addEventListener(
      "abort",
      () => {
        window.clearTimeout(timer);
        reject(signal.reason);
      },
      { once: true }
    );
  });
}

function billingErrorMessage(reason: unknown, zh: boolean) {
  const code = reason instanceof CommaApiError ? reason.body?.error : undefined;
  const messages: Record<string, readonly [string, string]> = {
    redeem_code_not_found: [
      "兑换码不存在，请检查后重试。",
      "That redeem code wasn’t found.",
    ],
    redeem_code_expired: ["这个兑换码已过期。", "That redeem code has expired."],
    redeem_code_disabled: [
      "这个兑换码已停用。",
      "That redeem code is no longer active.",
    ],
    redeem_code_max_redemptions_reached: [
      "这个兑换码已被领完。",
      "That redeem code has reached its redemption limit.",
    ],
    redeem_code_account_limit_reached: [
      "当前账户已经兑换过这个兑换码。",
      "This account has already redeemed that code.",
    ],
    active_subscription_not_found: [
      "当前订阅状态尚未同步，请稍后再试。",
      "Your current subscription is still syncing. Try again shortly.",
    ],
    subscription_change_unavailable: [
      "套餐变更暂时不可用，请稍后重试。",
      "Plan changes are temporarily unavailable. Try again shortly.",
    ],
  };
  const message = code ? messages[code] : undefined;
  if (message) return message[zh ? 0 : 1];
  return zh
    ? "操作失败，请检查后重试。"
    : "That didn’t work. Check the details and try again.";
}
