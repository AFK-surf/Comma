import { WeChatProviderLogo } from "./WeChatProviderLogo";
import { createElement, type ComponentType } from "react";
import { LarkProviderLogo } from "./LarkProviderLogo";
import { FeishuProviderLogo } from "./FeishuProviderLogo";
import { FastmailProviderLogo } from "./FastmailProviderLogo";
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
  FeishuProjectProviderLogo,
  FlomoProviderLogo,
  GiteeProviderLogo,
  LuckinProviderLogo,
  MeegleProviderLogo,
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
  GoogleColabProviderLogo,
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
  colab: GoogleColabProviderLogo,
  didi: DidiProviderLogo,
  dropbox: DropboxProviderLogo,
  fastmail: FastmailProviderLogo,
  feishu: FeishuProviderLogo,
  feishuproject: FeishuProjectProviderLogo,
  flomo: FlomoProviderLogo,
  lark: LarkProviderLogo,
  gmail: GmailProviderLogo,
  gitee: GiteeProviderLogo,
  github: GithubProviderLogo,
  google: GoogleProviderLogo,
  googlecalendar: GoogleCalendarProviderLogo,
  googlecolab: GoogleColabProviderLogo,
  googledrive: GoogleDriveProviderLogo,
  googleworkspace: GoogleProviderLogo,
  hubspot: HubSpotProviderLogo,
  linear: LinearProviderLogo,
  luckin: LuckinProviderLogo,
  meegle: MeegleProviderLogo,
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

/** Every brand key with a logo, normalized as `normalizeProviderBrandName` returns it. */
export const providerBrandLogoNames = Object.keys(providerBrandLogos);

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
