import type { ReactElement } from "react";
import {
  ApiConnectionIcon,
  ArchiveIcon,
  BellIcon,
  BugIcon,
  CallIcon,
  ChainLink3Icon,
  ChainLinkIcon,
  CmdIcon,
  CreditCard2Icon,
  DevicesIcon,
  GlobeIcon,
  PaintBrushIcon,
  PeopleCircleIcon,
  SettingsIcon,
  ShapesPlusXSquareCircleIcon,
  SquareGridCircleIcon,
  TagLabelIcon,
  VideoIcon,
  WindowCursorIcon,
  type IconProps,
} from "../icons";
import { TailscaleProviderLogo } from "../provider-brand-logos/TailscaleProviderLogo";
import type { SettingsCategoryIcon } from "./settingsRegistry";

export interface SettingsCategoryIconViewProps {
  className?: string;
  icon: SettingsCategoryIcon;
}

/** Central Icons has no Tailscale glyph; its brand mark sits in the glyph slot. */
const TailscaleIcon = ({ className }: IconProps) => (
  <TailscaleProviderLogo
    data-comma-icon=""
    {...(className !== undefined ? { className } : {})}
  />
);

const iconComponents = {
  general: SettingsIcon,
  notifications: BellIcon,
  "archived-tasks": ArchiveIcon,
  "shared-tasks": GlobeIcon,
  apps: SquareGridCircleIcon,
  labels: TagLabelIcon,
  recommendations: ShapesPlusXSquareCircleIcon,
  channels: ChainLink3Icon,
  "inbound-api": ChainLinkIcon,
  voice: CallIcon,
  profile: PeopleCircleIcon,
  appearance: PaintBrushIcon,
  meeting: VideoIcon,
  browser: GlobeIcon,
  "keyboard-shortcuts": CmdIcon,
  "usage-billing": CreditCard2Icon,
  devices: DevicesIcon,
  tailscale: TailscaleIcon,
  "computer-use": WindowCursorIcon,
  "models-api-keys": ApiConnectionIcon,
  debug: BugIcon,
} satisfies Record<SettingsCategoryIcon, (props: IconProps) => ReactElement>;

export const SettingsCategoryIconView = ({
  className,
  icon,
}: SettingsCategoryIconViewProps) => {
  const Icon = iconComponents[icon];
  return <Icon aria-hidden {...(className !== undefined ? { className } : {})} />;
};
