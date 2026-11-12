import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { cx } from "@comma/ui/components/utils";
import type { ComponentProps } from "react";
import { CommaProductMark } from "../../../CommaProductMark";

/**
 * A Worker as the mark of its model's maker on a plain disc: Comma's mark for
 * Comma's own model, and while the maker is not known yet (the Task's run has
 * not loaded).
 */
export function WorkerModelMark({
  vendor,
  className,
  ...props
}: { vendor: string | undefined } & ComponentProps<"span">) {
  return (
    <span
      aria-hidden
      {...props}
      className={cx("comma-worker-model-mark", className)}
      data-model-vendor={vendor}
    >
      {vendor && vendor !== "comma" ? (
        <ModelVendorIcon vendor={vendor} />
      ) : (
        <CommaProductMark viewBox="2 2 16 16" />
      )}
    </span>
  );
}
