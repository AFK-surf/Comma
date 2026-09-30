import type { FC } from "react";

export const isReactComponent = (value: unknown): value is FC<{ className?: string }> =>
  typeof value === "function";
