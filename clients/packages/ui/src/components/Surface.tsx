import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "./utils";

export interface SurfaceProps extends HTMLAttributes<HTMLElement> {
  children?: ReactNode;
}

export const Surface = ({ className, children, ...props }: SurfaceProps) => (
  <section
    className={cx("rounded-2xl border border-primary bg-primary shadow-xs", className)}
    {...props}
  >
    {children}
  </section>
);
