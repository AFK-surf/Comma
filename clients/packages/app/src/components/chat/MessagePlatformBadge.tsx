import {
  ChatBubbleIcon,
  DiscordBrandIcon,
  GlobeIcon,
  resolveProviderBrandLogo,
  SignalAppTileLogo,
  TelegramAppTileLogo,
  WeChatAppTileLogo,
  type ProviderBrandLogoProps,
} from "@comma/ui";
import type { ComponentType, CSSProperties } from "react";
import "./messagePlatformBadge.css";

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
    Logo: WeChatAppTileLogo,
  },
  telegram: {
    name: "Telegram",
    color: "#b8eaf7",
    foreground: "#082b3a",
    Logo: TelegramAppTileLogo,
  },
  signal: { name: "Signal", color: "#3b6de3", Logo: SignalAppTileLogo },
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
