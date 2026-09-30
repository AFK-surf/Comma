import { commaProductMarkPathData } from "@comma/config";
import type { ComponentProps } from "react";

export function CommaProductMark(props: ComponentProps<"svg">) {
  return (
    <svg
      aria-hidden="true"
      data-slot="comma-product-mark"
      fill="none"
      viewBox="0 0 20 20"
      xmlns="http://www.w3.org/2000/svg"
      {...props}
    >
      <path d={commaProductMarkPathData} fill="currentColor" />
    </svg>
  );
}
