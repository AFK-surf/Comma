import { spacing } from "../../tokens";

export interface MenuPointerOffsets {
  crossOffset: number;
  offset: number;
}

export const getMenuPointerOffsets = (
  trigger: Element,
  clientX: number,
  clientY: number
): MenuPointerOffsets => {
  const triggerBounds = trigger.getBoundingClientRect();
  return {
    crossOffset: clientY - triggerBounds.top,
    offset: spacing.xs + clientX - triggerBounds.right,
  };
};
