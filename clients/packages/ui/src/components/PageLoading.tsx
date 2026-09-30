import type { ComponentProps } from "react";
import { cx } from "./utils";
import { LoadingCircleIcon } from "./icons";
import { CommaLogoAnimation } from "./comma-mascot/CommaLogoAnimation";

export function PageLoading({
  label,
  className,
  indicator = "logo",
  ...props
}: ComponentProps<"output"> & { label: string; indicator?: "logo" | "spinner" }) {
  return (
    <output
      aria-label={label}
      aria-busy="true"
      {...props}
      className={cx(
        "flex size-full min-h-0 flex-1 items-center justify-center p-xl",
        className
      )}
    >
      {indicator === "spinner" ? (
        <LoadingCircleIcon
          className="size-8 shrink-0 text-tertiary motion-safe:animate-spin"
          aria-hidden="true"
        />
      ) : (
        <span className="size-8 shrink-0 text-disabled">
          <CommaLogoAnimation style={{ color: "inherit" }} aria-hidden="true" />
        </span>
      )}
    </output>
  );
}
