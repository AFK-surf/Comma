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
  TagLabelIcon,
  VideoIcon,
  WindowCursorIcon,
} from "../icons";
import type { SettingsCategoryIcon } from "./settingsRegistry";

export interface SettingsCategoryIconViewProps {
  className?: string;
  icon: SettingsCategoryIcon;
}

const iconComponents = {
  general: SettingsIcon,
  notifications: BellIcon,
  "archived-tasks": ArchiveIcon,
  "shared-tasks": GlobeIcon,
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
  "computer-use": WindowCursorIcon,
  "models-api-keys": ApiConnectionIcon,
  debug: BugIcon,
} satisfies Record<SettingsCategoryIcon, typeof SettingsIcon>;

export const SettingsCategoryIconView = ({
  className,
  icon,
}: SettingsCategoryIconViewProps) => {
  const Icon = iconComponents[icon];
  return <Icon aria-hidden {...(className !== undefined ? { className } : {})} />;
};
