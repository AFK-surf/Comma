import { commaProductMarkPathData } from "@comma/config";
import type { useCommaMessages } from "@comma/i18n/react";
import {
  SignalProviderMark,
  SlackProviderLogo,
  TelegramProviderLogo,
} from "@comma/ui/components/provider-brand-logos";
import { InboxIcon, WechatBrandIcon } from "@comma/ui/components/icons";

/** Where a Task was asked for: a chat provider, Comma itself, or another person's Task request. */
export const TASK_ORIGIN_KEYS = [
  "slack",
  "telegram",
  "feishu",
  "lark",
  "wechat",
  "signal",
  "comma",
  "task_request",
] as const;
export type TaskOriginKey = (typeof TASK_ORIGIN_KEYS)[number];

type CommaMessages = ReturnType<typeof useCommaMessages>;

export function taskOriginKey(origin: string | undefined): TaskOriginKey | undefined {
  return TASK_ORIGIN_KEYS.find((key) => key === origin);
}

export function taskOriginLabel(messages: CommaMessages, key: TaskOriginKey): string {
  switch (key) {
    case "slack":
      return messages.task_panel_origin_slack();
    case "telegram":
      return messages.task_panel_origin_telegram();
    case "feishu":
      return messages.task_panel_origin_feishu();
    case "lark":
      return messages.task_panel_origin_lark();
    case "wechat":
      return messages.task_panel_origin_wechat();
    case "signal":
      return messages.task_panel_origin_signal();
    case "task_request":
      return messages.task_panel_origin_task_request();
    default:
      return messages.task_panel_origin_comma();
  }
}

function CommaMark({ className }: { className: string }) {
  return (
    <svg aria-hidden className={className} fill="currentColor" viewBox="0 0 20 20">
      <path d={commaProductMarkPathData} />
    </svg>
  );
}

/** The brand mark for an origin, coloured where the provider's artwork is. */
export function TaskOriginIcon({
  className = "size-5",
  origin,
}: {
  className?: string;
  origin: TaskOriginKey;
}) {
  switch (origin) {
    case "slack":
      return <SlackProviderLogo className={className} />;
    case "telegram":
      return <TelegramProviderLogo className={className} />;
    case "wechat":
      return <WechatBrandIcon className={`${className} comma-task-origin-wechat`} />;
    case "signal":
      return <SignalProviderMark className={className} />;
    case "comma":
      return <CommaMark className={`${className} text-primary`} />;
    case "task_request":
      return <InboxIcon className={className} />;
    default:
      return null;
  }
}
