import type { ReactNode } from "react";
import { Tooltip } from "../../tooltip";

const VOICE_INPUT_SHORTCUT = ["⌃", "D"] as const;

export const VoiceInputTooltip = ({
  prefix,
  suffix,
  children,
}: {
  prefix: string;
  suffix: string;
  children: ReactNode;
}) => (
  <Tooltip
    content={prefix}
    placement="top"
    shortcut={VOICE_INPUT_SHORTCUT}
    suffix={suffix}
  >
    {children}
  </Tooltip>
);

export const SendInputTooltip = ({
  sendLabel,
  newLineLabel,
  children,
}: {
  sendLabel: string;
  newLineLabel: string;
  children: ReactNode;
}) => (
  <Tooltip
    content={sendLabel}
    placement="top"
    rows={[
      {
        label: sendLabel,
        shortcut: "↩",
        shortcutLabel: "Enter",
      },
      {
        label: newLineLabel,
        shortcut: ["⇧", "↩"],
        shortcutLabel: "Shift Enter",
      },
    ]}
  >
    {children}
  </Tooltip>
);
