import {
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  ChevronDownIcon,
  ClockIcon,
  EditBigIcon,
  HomeIcon,
  Folder2Icon,
  InboxIcon,
  ListChecksIcon,
  MicrophoneIcon,
  ListBulletsIcon,
  PanelLeftIcon,
  PanelRightIcon,
  PlusIcon,
  PuzzleIcon,
  ReloadIcon,
  SearchIcon,
  SettingsIcon,
  SparklesIcon,
} from "@comma/ui";
import type { ComponentType } from "react";

type CentralAppIcon = ComponentType<{
  className?: string;
  mode?: "masked" | "raw";
}>;

export type AppIconName =
  | "arrow-left"
  | "arrow-right"
  | "arrow-up"
  | "chevron-down"
  | "clock"
  | "drive"
  | "edit"
  | "home"
  | "inbox"
  | "layout-left"
  | "layout-right"
  | "list-bullets"
  | "mic"
  | "plus"
  | "plugins"
  | "reload"
  | "search"
  | "settings"
  | "sparkles"
  | "tasks";

const appIcons: Record<AppIconName, CentralAppIcon> = {
  "arrow-left": ArrowLeftIcon,
  "arrow-right": ArrowRightIcon,
  "arrow-up": ArrowUpIcon,
  "chevron-down": ChevronDownIcon,
  clock: ClockIcon,
  drive: Folder2Icon,
  edit: EditBigIcon,
  home: HomeIcon,
  inbox: InboxIcon,
  "layout-left": PanelLeftIcon,
  "layout-right": PanelRightIcon,
  "list-bullets": ListBulletsIcon,
  mic: MicrophoneIcon,
  plus: PlusIcon,
  plugins: PuzzleIcon,
  reload: ReloadIcon,
  search: SearchIcon,
  settings: SettingsIcon,
  sparkles: SparklesIcon,
  tasks: ListChecksIcon,
};

export function AppIcon({
  className,
  name,
}: {
  className?: string;
  name: AppIconName;
}) {
  const Icon = appIcons[name];
  return (
    <Icon
      {...(className !== undefined ? { className } : {})}
      {...(name === "tasks" ? { mode: "raw" as const } : {})}
    />
  );
}
