import { SparklesIcon } from "@comma/ui/components/icons";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { cx } from "@comma/ui/components/utils";
import type { ComponentProps } from "react";
import { CommaProductMark } from "../../../CommaProductMark";

/**
 * A Worker as the mark of its model's maker on a plain disc: Comma's mark for
 * Comma's own model, sparkles while the maker is not known.
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
      {vendor === "comma" ? (
        <CommaProductMark viewBox="2 2 16 16" />
      ) : vendor ? (
        <ModelVendorIcon vendor={vendor} />
      ) : (
        <SparklesIcon />
      )}
    </span>
  );
}
