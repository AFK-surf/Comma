import { commaProductMarkPathData } from "@comma/config";
import type { useCommaMessages } from "@comma/i18n/react";
import {
  SignalProviderMark,
  SlackProviderLogo,
  TelegramProviderLogo,
  WechatBrandIcon,
} from "@comma/ui";

/** Where a Task was asked for: a chat provider, or Comma itself. */
export const TASK_ORIGIN_KEYS = [
  "slack",
  "telegram",
  "feishu",
  "wechat",
  "signal",
  "comma",
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
    case "wechat":
      return messages.task_panel_origin_wechat();
    case "signal":
      return messages.task_panel_origin_signal();
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
    default:
      return null;
  }
}
