import type { ElementType, HTMLAttributes, ReactNode } from "react";
import type {
  FontWeightKey,
  CompactTypeScaleKey,
  TypeScaleKey,
} from "../tokens/typography";
import { cx } from "./utils";

/** Tailwind classes per type-scale token. */
const sizeClasses: Record<TypeScaleKey | CompactTypeScaleKey, string> = {
  display2xl: "text-display-2xl",
  displayXl: "text-display-xl",
  displayLg: "text-display-lg",
  displayMd: "text-display-md",
  displaySm: "text-display-sm",
  displayXs: "text-display-xs",
  textXl: "text-xl",
  textLg: "text-lg",
  textMd: "text-md",
  textSm: "text-sm",
  textXs: "text-xs",
  micro: "text-micro",
  mini: "text-mini",
  small: "text-small",
  regular: "text-regular",
  large: "text-large",
  title3: "text-title-3",
  title2: "text-title-2",
  title1: "text-title-1",
};

const weightClasses: Record<FontWeightKey, string> = {
  regular: "font-regular",
  medium: "font-medium",
  semibold: "font-semibold",
  bold: "font-bold",
};

export interface TextProps extends HTMLAttributes<HTMLElement> {
  as?: ElementType;
  size?: TypeScaleKey | CompactTypeScaleKey;
  weight?: FontWeightKey;
  children?: ReactNode;
}

export const Text = ({
  as: Tag = "p",
  size = "textMd",
  weight = "regular",
  className,
  children,
  ...rest
}: TextProps) => (
  <Tag className={cx(sizeClasses[size], weightClasses[weight], className)} {...rest}>
    {children}
  </Tag>
);
