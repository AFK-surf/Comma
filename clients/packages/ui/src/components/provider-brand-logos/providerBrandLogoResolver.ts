import { WeChatProviderLogo } from "./WeChatProviderLogo";
import { createElement, type ComponentType } from "react";
import { LarkProviderLogo } from "./LarkProviderLogo";
import { FeishuProviderLogo } from "./FeishuProviderLogo";
import { TelegramProviderLogo } from "./TelegramProviderLogo";
import { SignalProviderLogo } from "./SignalProviderLogo";
import { XBrandIcon } from "../icons";
import {
  GithubProviderLogo,
  GmailProviderLogo,
  GoogleCalendarProviderLogo,
  GoogleDriveProviderLogo,
  GoogleProviderLogo,
  LinearProviderLogo,
  NotionProviderLogo,
  OutlookProviderLogo,
  SlackProviderLogo,
  type ProviderBrandLogoProps,
} from "./ProviderBrandLogos";

type ProviderBrandLogoComponent = ComponentType<ProviderBrandLogoProps>;

const providerBrandLogos: Record<string, ProviderBrandLogoComponent> = {
  feishu: FeishuProviderLogo,
  lark: LarkProviderLogo,
  gmail: GmailProviderLogo,
  github: GithubProviderLogo,
  google: GoogleProviderLogo,
  googlecalendar: GoogleCalendarProviderLogo,
  googledrive: GoogleDriveProviderLogo,
  googleworkspace: GoogleProviderLogo,
  linear: LinearProviderLogo,
  notion: NotionProviderLogo,
  outlook: OutlookProviderLogo,
  signal: SignalProviderLogo,
  slack: SlackProviderLogo,
  telegram: TelegramProviderLogo,
  wechat: WeChatProviderLogo,
  x: ({ className }) =>
    createElement(XBrandIcon, className === undefined ? {} : { className }),
};

export function normalizeProviderBrandName(value: string | null | undefined) {
  return value
    ?.trim()
    .toLowerCase()
    .replaceAll(/[^a-z0-9]/g, "");
}

export function resolveProviderBrandLogo(value: string | null | undefined) {
  const normalizedName = normalizeProviderBrandName(value);
  return normalizedName ? providerBrandLogos[normalizedName] : undefined;
}
