import type { ReactNode } from "react";
import type { useCommaMessages } from "@comma/i18n/react";
import { WindowAppIcon, WindowCursorIcon } from "@comma/ui/components/icons";

export interface ToolCommand {
  skillId: string;
  label: string;
  icon: ReactNode;
  describe: (messages: ReturnType<typeof useCommaMessages>) => string;
}

/**
 * Built-in skills the "/" menu lists as tools with their own icons. Picking one
 * attaches the skill, which has the agent do the message with that tool
 * (computer use in its background mode).
 */
export const toolCommands: readonly ToolCommand[] = [
  {
    skillId: "computer-use",
    label: "Computer use",
    icon: <WindowCursorIcon className="size-4!" />,
    describe: (messages) => messages.chat_command_computer_use(),
  },
  {
    skillId: "browser-use",
    label: "Browser use",
    icon: <WindowAppIcon className="size-4!" />,
    describe: (messages) => messages.chat_command_browser_use(),
  },
];

export function toolCommand(skillId: string) {
  return toolCommands.find((command) => command.skillId === skillId);
}
