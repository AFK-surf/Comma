import { uiClock } from "@comma/ui/clock";
import type { ReactNode } from "react";
import { getActiveCommaConfig } from "@comma/config";
import {
  useCall,
  useTopic,
  type BillingChangePreview,
  type BillingPlan,
  type BillingReturn,
} from "@comma/core-client";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { formatDate } from "@comma/i18n";
import { useCommaI18n, useCommaMessages } from "@comma/i18n/react";
import { Badge } from "@comma/ui/components/Badge";
import { Dialog } from "@comma/ui/components/dialog";
import type { SettingsCategoryDefinition } from "@comma/ui/components/settings";
import type { SettingsPanelItem } from "@comma/ui/components/settings-panel";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../nativePlatformActions";
import { useWorkspacePreference } from "../activeWorkspace";
import {
  BillingAllowanceMeter,
  type BillingPeriod,
  billingPeriods,
  BillingPeriodTabs,
  BillingRedeemForm,
  formatPrice,
  subscriptionActionLabel,
  subscriptionPlanDetail,
  subscriptionPrice,
  subscriptionStatusLabel,
} from "./BillingSettings";

/** Where Stripe sends the person back to. */
function billingReturn(): BillingReturn {
  const config = getActiveCommaConfig();
  return { apiBase: config.apiBaseUrl, environment: config.channel };
}

/**
 * The Settings › Usage & billing category, as five cards of rows: status
 * first (which plan, how many credits, how much of this cycle is left), then
 * what is for sale (subscription plans, credit packs), then the redeem code.
 *
 * The core reads the plans and the workspace's balance while the category is
 * open; the rows are what it says, and each action is one of its calls.
 */
export function useUsageBillingCategory(enabled: boolean): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const { locale } = useCommaI18n();
  const zh = locale === "zh-CN";
  const call = useCall();
  const prefer = useWorkspacePreference();
  const { value: billing = { status: "loading" } } = useTopic(
    enabled && prefer !== undefined ? { topic: "billing", prefer } : null
  );
  const ready = billing.status === "ready" ? billing : undefined;
  const workspace = ready?.workspace;
  const plans = ready?.plans ?? [];
  const summary = ready?.summary;
  const allowance = ready?.allowance ?? undefined;
  const [code, setCode] = useState("");
  const [pending, setPending] = useState<string>();
  // An error stays with the page whose action raised it.
  const [error, setError] = useState<{ key: string; message: string }>();
  const [notice, setNotice] = useState<string>();
  const [changeQuote, setChangeQuote] = useState<{
    plan: BillingPlan;
    preview: BillingChangePreview;
    request: string;
  }>();
  const [billingPeriod, setBillingPeriod] = useState<BillingPeriod>("month");

  const number = useMemo(() => new Intl.NumberFormat(locale), [locale]);
  const activeSubscription = summary?.active_subscription;
  const isActivePlan = (plan: BillingPlan) =>
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
  const loading = enabled && billing.status === "loading";
  const opening = zh ? "正在打开…" : "Opening…";

  // A return from Stripe: the core reads the balance on a backoff, as the webhook can trail the browser.
  const returns = useBillingReturn(enabled);
  const workspaceId = workspace?.id;
  useEffect(() => {
    if (returns === 0 || !workspaceId) return;
    void call("billing.returned", { workspace: workspaceId }).catch(() => undefined);
  }, [call, returns, workspaceId]);

  // Entering the page reads the plans and the balance again, as a topic start
  // does: the menu-bar item can hold this topic, which then does not start
  // (and read) as the page opens. A page that could read nothing tries again.
  const enteredRead = useRef(false);
  useEffect(() => {
    if (!enabled) {
      enteredRead.current = false;
      return;
    }
    if (enteredRead.current || prefer === undefined) return;
    enteredRead.current = true;
    void call("billing.refresh", {}).catch(() => undefined);
  }, [call, enabled, prefer]);

  // Coming back to the window (from Stripe, or anywhere) reads the balance
  // again, so a webhook that landed after that backoff still shows up.
  useEffect(() => {
    if (!enabled || !workspaceId || typeof window === "undefined") return;
    const refresh = () => {
      if (document.visibilityState === "hidden") return;
      void call("billing.refresh", { workspace: workspaceId }).catch(() => undefined);
    };
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [call, enabled, workspaceId]);

  const loadError =
    billing.status === "unavailable"
      ? {
          key: "load",
          message: zh
            ? "账单信息暂时无法加载，请稍后重试。"
            : "Billing is temporarily unavailable. Try again shortly.",
        }
      : undefined;
  const shownError = error ?? loadError;

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

  const startCheckout = (plan: BillingPlan) => {
    if (!workspace) return;
    void run(plan.plan_key, async () => {
      await openNativePlatformExternalUrlFromUserAction(async () => {
        const session = await call("billing.checkout", {
          workspace: workspace.id,
          plan: plan.plan_key,
          return: billingReturn(),
        });
        return session.url;
      });
    });
  };

  const startSubscriptionChange = (plan: BillingPlan) => {
    if (!workspace) return;
    void run(plan.plan_key, async () => {
      const quote = await call("billing.previewChange", {
        workspace: workspace.id,
        plan: plan.plan_key,
      });
      setChangeQuote({ plan, preview: quote.preview, request: quote.request });
    });
  };

  const confirmSubscriptionChange = () => {
    if (!workspace || !changeQuote) return;
    const quote = changeQuote;
    void run(quote.plan.plan_key, async () => {
      const execute = () =>
        call("billing.change", {
          workspace: workspace.id,
          plan: quote.plan.plan_key,
          preview: quote.preview,
          request: quote.request,
          return: billingReturn(),
        });
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
    });
  };

  const openPortal = () => {
    if (!workspace) return;
    void run("portal", async () => {
      const session = await call("billing.portal", {
        workspace: workspace.id,
        return: billingReturn(),
      });
      await openNativePlatformExternalUrl(session.url);
    });
  };

  const redeem = () => {
    const normalized = code.trim();
    if (!workspace || normalized.length < 3) return;
    void run("redeem", async () => {
      await call("billing.redeem", { workspace: workspace.id, code: normalized });
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
    shownError && owns(shownError.key) ? shownError.message : undefined;
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
              await call("billing.cancelRenewal", { workspace: workspace.id });
            });
        },
      },
    });
  }

  const nowUtc = new Date(uiClock.now());
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

/**
 * Counts billing returns while the category is open. Electron reports a return
 * by moving the hash to `…&billing-return=<status>`; when Settings is already
 * showing this category that is only a hashchange, so the category listens for
 * it instead of reading the hash once on open. The parameter is removed once
 * read, so the next return (even with the same status) changes the hash again.
 */
function useBillingReturn(enabled: boolean): number {
  const [count, setCount] = useState(0);
  useEffect(() => {
    if (!enabled || typeof window === "undefined") return;
    const sync = () => {
      if (consumeBillingReturn()) setCount((value) => value + 1);
    };
    sync();
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, [enabled]);
  return count;
}

/** Removes `billing-return` from the hash; true when the return should refresh. */
function consumeBillingReturn(): boolean {
  const hash = window.location.hash;
  const queryStart = hash.indexOf("?");
  if (queryStart < 0) return false;
  const params = new URLSearchParams(hash.slice(queryStart + 1));
  const status = params.get("billing-return");
  if (status === null) return false;
  params.delete("billing-return");
  const query = params.toString();
  window.history.replaceState(
    window.history.state,
    "",
    `${hash.slice(0, queryStart)}${query ? `?${query}` : ""}`
  );
  return status === "success" || status === "portal" || status === "subscription";
}

function billingErrorMessage(reason: unknown, zh: boolean) {
  const code = (reason as { code?: unknown } | null)?.code;
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
  const message =
    typeof code === "string" && Object.hasOwn(messages, code)
      ? messages[code]
      : undefined;
  if (message) return message[zh ? 0 : 1];
  return zh
    ? "操作失败，请检查后重试。"
    : "That didn’t work. Check the details and try again.";
}
