import {
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  ChevronDownIcon,
  ClockIcon,
  ColumnWideAddIcon,
  EditBigIcon,
  HomeIcon,
  HomeFilledIcon,
  Folder2Icon,
  Folder2FilledIcon,
  InboxIcon,
  InboxFilledIcon,
  ListChecksIcon,
  ListChecksFilledIcon,
  MicrophoneIcon,
  ListBulletsIcon,
  PanelLeftIcon,
  PanelRightIcon,
  PlusIcon,
  PuzzleIcon,
  PuzzleFilledIcon,
  ReloadIcon,
  SearchIcon,
  SettingsIcon,
  SparklesIcon,
  SquareGridCircleIcon,
  WindowCloseIcon,
  WindowMaximizeIcon,
  WindowMinimizeIcon,
  WindowRestoreIcon,
} from "@comma/ui/components/icons";
import type { ComponentType } from "react";

type CentralAppIcon = ComponentType<{
  className?: string;
  mode?: "masked" | "raw";
}>;

export type AppIconName =
  | "apps"
  | "arrow-left"
  | "arrow-right"
  | "arrow-up"
  | "chevron-down"
  | "clock"
  | "column-wide-add"
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
  | "tasks"
  | "window-close"
  | "window-maximize"
  | "window-minimize"
  | "window-restore";

const appIcons: Record<AppIconName, CentralAppIcon> = {
  apps: SquareGridCircleIcon,
  "arrow-left": ArrowLeftIcon,
  "arrow-right": ArrowRightIcon,
  "arrow-up": ArrowUpIcon,
  "chevron-down": ChevronDownIcon,
  clock: ClockIcon,
  "column-wide-add": ColumnWideAddIcon,
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
  "window-close": WindowCloseIcon,
  "window-maximize": WindowMaximizeIcon,
  "window-minimize": WindowMinimizeIcon,
  "window-restore": WindowRestoreIcon,
};

const filledAppIcons: Partial<Record<AppIconName, CentralAppIcon>> = {
  drive: Folder2FilledIcon,
  home: HomeFilledIcon,
  inbox: InboxFilledIcon,
  plugins: PuzzleFilledIcon,
  tasks: ListChecksFilledIcon,
};

export function AppIcon({
  className,
  filled = false,
  name,
}: {
  className?: string;
  filled?: boolean;
  name: AppIconName;
}) {
  const Icon = (filled && filledAppIcons[name]) || appIcons[name];
  return (
    <Icon
      {...(className !== undefined ? { className } : {})}
      {...(name === "tasks" ? { mode: "raw" as const } : {})}
    />
  );
}
