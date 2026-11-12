import { WeChatProviderLogo } from "./WeChatProviderLogo";
import { createElement, type ComponentType } from "react";
import { LarkProviderLogo } from "./LarkProviderLogo";
import { FeishuProviderLogo } from "./FeishuProviderLogo";
import { BlenderProviderLogo } from "./BlenderProviderLogo";
import { CanvaProviderLogo } from "./CanvaProviderLogo";
import { DropboxProviderLogo } from "./DropboxProviderLogo";
import { HubSpotProviderLogo } from "./HubSpotProviderLogo";
import { PostHogProviderLogo } from "./PostHogProviderLogo";
import { StillfailProviderLogo } from "./StillfailProviderLogo";
import { StripeProviderLogo } from "./StripeProviderLogo";
import { TelegramProviderLogo } from "./TelegramProviderLogo";
import { SignalProviderLogo } from "./SignalProviderLogo";
import { XBrandIcon } from "../icons";
import {
  AmapProviderLogo,
  BaiduMapsProviderLogo,
  DidiProviderLogo,
  FlomoProviderLogo,
  GiteeProviderLogo,
  LuckinProviderLogo,
  PixsoProviderLogo,
  QccProviderLogo,
  TencentDocsProviderLogo,
  TencentMapsProviderLogo,
  ZhipuProviderLogo,
} from "./ChinaServiceProviderLogos";
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
  amap: AmapProviderLogo,
  baidumaps: BaiduMapsProviderLogo,
  blender: BlenderProviderLogo,
  canva: CanvaProviderLogo,
  didi: DidiProviderLogo,
  dropbox: DropboxProviderLogo,
  feishu: FeishuProviderLogo,
  flomo: FlomoProviderLogo,
  lark: LarkProviderLogo,
  gmail: GmailProviderLogo,
  gitee: GiteeProviderLogo,
  github: GithubProviderLogo,
  google: GoogleProviderLogo,
  googlecalendar: GoogleCalendarProviderLogo,
  googledrive: GoogleDriveProviderLogo,
  googleworkspace: GoogleProviderLogo,
  hubspot: HubSpotProviderLogo,
  linear: LinearProviderLogo,
  luckin: LuckinProviderLogo,
  notion: NotionProviderLogo,
  outlook: OutlookProviderLogo,
  pixso: PixsoProviderLogo,
  posthog: PostHogProviderLogo,
  qcc: QccProviderLogo,
  signal: SignalProviderLogo,
  slack: SlackProviderLogo,
  stillfail: StillfailProviderLogo,
  stripe: StripeProviderLogo,
  telegram: TelegramProviderLogo,
  tencentdocs: TencentDocsProviderLogo,
  tencentmaps: TencentMapsProviderLogo,
  wechat: WeChatProviderLogo,
  x: ({ className }) =>
    createElement(XBrandIcon, className === undefined ? {} : { className }),
  zhipusearch: ZhipuProviderLogo,
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
