import type { ReactNode } from "react";
import { cx } from "../utils";

export interface PopupProps {
  children?: ReactNode;
  width?: "sm" | "md" | "lg";
  className?: string;
}

const widthClasses = {
  sm: "w-[280px]",
  md: "w-[360px]",
  lg: "w-[480px]",
} as const;

export const Popup = ({ children, width = "md", className }: PopupProps) => (
  <dialog
    open
    className={cx(
      "rounded-2xl border-[0.5px] border-primary bg-popup-primary p-xl shadow-sm",
      widthClasses[width],
      className
    )}
  >
    {children}
  </dialog>
);
