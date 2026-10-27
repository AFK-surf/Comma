import {
  CalendarIcon,
  DevicesIcon,
  GaugeIcon,
  HomeIcon,
  Filter2Icon,
  PeopleCircleIcon,
  PuzzleIcon,
  SettingsIcon,
  ShieldCheckIcon,
  SquareGridCircleIcon,
  SunIcon,
} from "@comma/ui/components/icons";
import type { ComponentType } from "react";
import type { NavIconName } from "./navSpec";

export const navIcons: Record<NavIconName, ComponentType<{ className?: string }>> = {
  overview: HomeIcon,
  swarms: SquareGridCircleIcon,
  meetings: CalendarIcon,
  dailyBrief: SunIcon,
  triage: Filter2Icon,
  dataPolicy: ShieldCheckIcon,
  health: GaugeIcon,
  runners: DevicesIcon,
  members: PeopleCircleIcon,
  plugins: PuzzleIcon,
  settings: SettingsIcon,
};
