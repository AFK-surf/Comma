import { uiClock } from "@comma/ui/clock";
import { messages, type CommaLocale } from "@comma/i18n";
import { toast } from "@comma/ui/components/toast";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import type {
  ChatParticipantIssueDetail,
  ChatParticipantStatus,
} from "@comma/core/chat";
import {
  openFundingSettings,
  openUsageBillingSettings,
  showOutOfCreditsToast,
} from "./outOfCredits";

export const FUNDING_STOP_TOAST_ID = "provider-quota";

/** The participant issues that stop work for lack of funds, by who pays. */
export type FundingStopKind = "credits" | "provider" | "subscription";

/** Catalog sources that are subscription plans: they reset, they are not topped up. */
const subscriptionSources = new Set([
  "claude",
  "codex",
  "gemini",
  "grok",
  "kimi-code",
  "github-copilot",
]);

export function fundingStopKind(
  issue: string | undefined,
  detail?: ChatParticipantIssueDetail
): FundingStopKind | undefined {
  switch (issue) {
    case "insufficient_credits":
      return "credits";
    case "provider_quota_exhausted":
      return detail?.source && subscriptionSources.has(detail.source)
        ? "subscription"
        : "provider";
    case "quota_exhausted":
      return "subscription";
    default:
      return undefined;
  }
}

/**
 * Display names of catalog sources, and the billing page for the sources whose
 * page is stable. Others fall back to Model & API, which names the Profile.
 */
const sources: Record<string, { name: string; billingUrl?: string }> = {
  anthropic: {
    name: "Anthropic",
    billingUrl: "https://console.anthropic.com/settings/billing",
  },
  openai: {
    name: "OpenAI",
    billingUrl: "https://platform.openai.com/settings/organization/billing/overview",
  },
  openrouter: {
    name: "OpenRouter",
    billingUrl: "https://openrouter.ai/settings/credits",
  },
  deepseek: { name: "DeepSeek", billingUrl: "https://platform.deepseek.com/top_up" },
  google: { name: "Google Gemini" },
  xai: { name: "xAI" },
  mistral: { name: "Mistral" },
  qwen: { name: "Qwen" },
  "qwen-cn": { name: "Qwen" },
  moonshotai: { name: "Kimi" },
  "moonshotai-cn": { name: "Kimi" },
  zai: { name: "Z.ai" },
  "zai-coding-cn": { name: "Z.ai" },
  minimax: { name: "MiniMax" },
  "minimax-cn": { name: "MiniMax" },
  groq: { name: "Groq" },
  together: { name: "Together AI" },
  fireworks: { name: "Fireworks" },
  "azure-openai": { name: "Azure OpenAI" },
  "vercel-ai-gateway": { name: "Vercel AI Gateway" },
  claude: { name: "Claude" },
  codex: { name: "ChatGPT" },
  gemini: { name: "Google AI" },
  grok: { name: "SuperGrok" },
  "kimi-code": { name: "Kimi Code" },
  "github-copilot": { name: "GitHub Copilot" },
};

export function fundingSourceName(source: string | undefined) {
  if (!source || source === "custom") return undefined;
  return sources[source]?.name;
}

export function fundingBillingUrl(source: string | undefined) {
  return source ? sources[source]?.billingUrl : undefined;
}

/** A reset moment in the reader's words: a time today, else a date and time. */
export function formatFundingReset(
  resetAt: number,
  locale?: CommaLocale,
  now = uiClock.now()
) {
  const when = new Date(resetAt * 1000);
  const today = new Date(now).toDateString() === when.toDateString();
  return new Intl.DateTimeFormat(locale, {
    ...(today ? {} : { month: "short", day: "numeric" }),
    hour: "numeric",
    minute: "2-digit",
  }).format(when);
}

export type FundingStopAction = { label: string; run: () => void };

/** The ways out of a stop, most direct first. */
export function fundingStopActions(
  kind: FundingStopKind,
  detail: ChatParticipantIssueDetail | undefined,
  locale: CommaLocale
): FundingStopAction[] {
  if (kind === "credits") {
    return [
      {
        label: messages.chat_add_credits(undefined, { locale }),
        run: openUsageBillingSettings,
      },
    ];
  }
  const models = {
    label:
      kind === "subscription"
        ? messages.billing_switch_model(undefined, { locale })
        : messages.settings_models_title(undefined, { locale }),
    run: () => openFundingSettings("models", detail?.profileId),
  };
  const provider = fundingSourceName(detail?.source);
  const billingUrl =
    kind === "provider" ? fundingBillingUrl(detail?.source) : undefined;
  return provider && billingUrl
    ? [
        {
          label: messages.billing_open_provider_billing({ provider }, { locale }),
          run: () => void openNativePlatformExternalUrl(billingUrl),
        },
        models,
      ]
    : [models];
}

/** A stop's notice: what stopped, what to do, and the ways out. */
export type StopNotice = {
  title: string;
  detail: string;
  actions: FundingStopAction[];
};

/**
 * The notice for a participant that stopped on something the member fixes:
 * a funding stop, or a model nothing can serve now. The chat shows it in the
 * status line's card; a funding stop also raises it as a toast.
 */
export function stopNotice(
  status: ChatParticipantStatus,
  locale: CommaLocale
): StopNotice | undefined {
  if (status.state !== "error") return undefined;
  const detail = status.issueDetail;
  if (status.issue === "model_unavailable") {
    return {
      title: messages.chat_model_unavailable_title(undefined, { locale }),
      detail: messages.chat_model_unavailable_detail(undefined, { locale }),
      actions: [
        {
          label: messages.settings_models_title(undefined, { locale }),
          run: () => openFundingSettings("models", detail?.profileId),
        },
      ],
    };
  }
  const kind = fundingStopKind(status.issue, detail);
  if (kind === undefined) return undefined;
  const actions = fundingStopActions(kind, detail, locale);
  if (kind === "credits") {
    return {
      title: messages.billing_out_of_credits_title(undefined, { locale }),
      detail: messages.billing_out_of_credits_detail(undefined, { locale }),
      actions,
    };
  }
  const provider = fundingSourceName(detail?.source);
  if (kind === "provider") {
    return {
      title: provider
        ? messages.billing_provider_quota_title_source({ provider }, { locale })
        : messages.billing_provider_quota_title(undefined, { locale }),
      detail:
        provider && detail?.profileName
          ? messages.billing_provider_quota_detail_named(
              { profile: detail.profileName, provider },
              { locale }
            )
          : provider
            ? messages.billing_provider_quota_detail_source({ provider }, { locale })
            : messages.billing_provider_quota_detail(undefined, { locale }),
      actions,
    };
  }
  return {
    title: provider
      ? messages.billing_subscription_limit_title_source({ provider }, { locale })
      : messages.billing_subscription_limit_title(undefined, { locale }),
    detail: detail?.resetAt
      ? messages.billing_subscription_limit_detail_reset(
          { time: formatFundingReset(detail.resetAt, locale) },
          { locale }
        )
      : messages.billing_subscription_limit_detail(undefined, { locale }),
    actions,
  };
}

/** The toast for a participant that stopped for lack of funds. */
export function showFundingStopToast(
  status: ChatParticipantStatus,
  locale: CommaLocale
) {
  const kind = fundingStopKind(status.issue, status.issueDetail);
  if (kind === undefined) return;
  if (kind === "credits") {
    showOutOfCreditsToast(locale);
    return;
  }
  const notice = stopNotice(status, locale);
  if (!notice) return;
  const options = {
    actions: notice.actions.map((action, index) => ({
      label: action.label,
      ...(index > 0 ? { hierarchy: "tertiary-gray" as const } : {}),
      onPress: () => {
        toast.dismiss(FUNDING_STOP_TOAST_ID);
        action.run();
      },
    })),
    description: notice.detail,
    icon: "gauge" as const,
    id: FUNDING_STOP_TOAST_ID,
    testId: FUNDING_STOP_TOAST_ID,
  };
  if (kind === "provider") toast.error(notice.title, options);
  else toast.warning(notice.title, options);
}
