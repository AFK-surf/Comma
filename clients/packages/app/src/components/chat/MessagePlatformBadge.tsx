import {
  ChatBubbleIcon,
  DiscordBrandIcon,
  GlobeIcon,
  MacbookAirIcon,
  PhoneDynamicIslandIcon,
  Smartwatch2Icon,
} from "@comma/ui/components/icons";
import type { ChatMessage } from "@comma/core/chat";
import { getNativeBridge } from "@comma/native-bridge";
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

// Comma's own apps. They name where the user typed, not an external chat
// platform, so they mark the message but keep the default bubble.
const clientSources: Record<
  NonNullable<ChatMessage["clientSource"]>,
  { name: string; Logo: typeof GlobeIcon }
> = {
  iphone: { name: "iPhone", Logo: PhoneDynamicIslandIcon },
  watch: { name: "Apple Watch", Logo: Smartwatch2Icon },
  android: { name: "Android", Logo: PhoneDynamicIslandIcon },
  mac: { name: "Mac", Logo: MacbookAirIcon },
  windows: { name: "Windows", Logo: MacbookAirIcon },
  linux: { name: "Linux", Logo: MacbookAirIcon },
  web: { name: "Web", Logo: GlobeIcon },
};

/** The Comma app this window is, named as a message's `clientSource` names it. */
function thisClientSource(): ChatMessage["clientSource"] {
  const bridge = getNativeBridge();
  if (bridge.platform !== "electron") return "web";
  return bridge.os === "macos"
    ? "mac"
    : bridge.os === "windows"
      ? "windows"
      : bridge.os === "linux"
        ? "linux"
        : undefined;
}

/** The app a person's message was sent from, when it is not this one. */
export function otherClientSource(
  source: ChatMessage["clientSource"]
): ChatMessage["clientSource"] {
  return source && source !== thisClientSource() ? source : undefined;
}

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
  const client = clientSources[platform as keyof typeof clientSources];
  const name = presentation?.name ?? client?.name ?? platform;
  const Logo =
    presentation?.Logo ??
    client?.Logo ??
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
      data-client-source={client ? "" : undefined}
      title={name}
      style={
        {
          "--comma-chat-platform-color":
            presentation?.color ?? "var(--color-text-tertiary)",
        } as CSSProperties
      }
    >
      <span className="app-sr-only">{name}</span>
      <Logo aria-hidden className="comma-chat-platform-badge-icon" />
    </span>
  );
}
