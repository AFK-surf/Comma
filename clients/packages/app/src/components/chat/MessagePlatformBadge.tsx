import { useCommaMessages } from "@comma/i18n/react";
import {
  ChatBubbleIcon,
  DiscordBrandIcon,
  GlobeIcon,
  MicrophoneIcon,
} from "@comma/ui/components/icons";
import {
  resolveProviderBrandLogo,
  type ProviderBrandLogoProps,
} from "@comma/ui/components/provider-brand-logos";
import type { ComponentType, CSSProperties } from "react";
import signalActivityLogo from "./assets/signal-activity.svg";
import telegramActivityLogo from "./assets/telegram-activity.svg";
import wechatActivityLogo from "./assets/wechat-activity.svg";
import "./messagePlatformBadge.css";

// Same round marks the activity line uses, so both sides of the thread match.
function activityLogo(src: string): ComponentType<ProviderBrandLogoProps> {
  return function ActivityLogo({ className }: ProviderBrandLogoProps) {
    return <img src={src} alt="" aria-hidden className={className} />;
  };
}

const platforms: Record<
  string,
  {
    name: string;
    color: string;
    foreground?: string;
    Logo?: ComponentType<ProviderBrandLogoProps>;
  }
> = {
  wechat: {
    name: "WeChat",
    color: "#9df29f",
    foreground: "#082d07",
    Logo: activityLogo(wechatActivityLogo),
  },
  telegram: {
    name: "Telegram",
    color: "#b8eaf7",
    foreground: "#082b3a",
    Logo: activityLogo(telegramActivityLogo),
  },
  signal: { name: "Signal", color: "#3b6de3", Logo: activityLogo(signalActivityLogo) },
  slack: { name: "Slack", color: "#611f69" },
  feishu: { name: "Feishu", color: "#2c61e8" },
  lark: { name: "Lark", color: "#2c61e8" },
  imessage: { name: "iMessage", color: "#36aafc" },
  discord: { name: "Discord", color: "#5865f2" },
};

export function getMessagePlatformBubbleStyle(
  platform: string | undefined
): CSSProperties | undefined {
  const presentation = platform ? platforms[platform] : undefined;
  if (!presentation) return undefined;
  return {
    "--comma-chat-user-bubble-background": presentation.color,
    ...(presentation.foreground
      ? { "--comma-chat-user-bubble-foreground": presentation.foreground }
      : {}),
  } as CSSProperties;
}

export function MessagePlatformBadge({ platform }: { platform: string | undefined }) {
  if (!platform) return null;
  const presentation = platforms[platform];
  const Logo =
    presentation?.Logo ??
    resolveProviderBrandLogo(platform) ??
    (platform === "discord"
      ? DiscordBrandIcon
      : platform === "imessage"
        ? ChatBubbleIcon
        : GlobeIcon);
  return (
    <span
      className="comma-chat-platform-badge"
      data-platform={platform}
      title={presentation?.name ?? platform}
      style={
        {
          "--comma-chat-platform-color":
            presentation?.color ?? "var(--color-text-tertiary)",
        } as CSSProperties
      }
    >
      <span className="app-sr-only">{presentation?.name ?? platform}</span>
      <Logo aria-hidden className="comma-chat-platform-badge-icon" />
    </span>
  );
}

/** Marks a person's message that Quick Chat sent, where a platform's mark would sit. */
export function QuickChatBadge() {
  const messages = useCommaMessages();
  const name = messages.chat_message_quick_chat();
  return (
    <span
      className="comma-chat-platform-badge"
      data-source="quick-chat"
      title={name}
      style={
        { "--comma-chat-platform-color": "var(--color-text-tertiary)" } as CSSProperties
      }
    >
      <span className="app-sr-only">{name}</span>
      <MicrophoneIcon aria-hidden className="comma-chat-platform-badge-icon" />
    </span>
  );
}
