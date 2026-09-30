import type { ComponentType } from "react";

export type IconProps = {
  className?: string;
  mode?: "masked" | "raw";
};

type CentralIconComponent = ComponentType<{
  ariaHidden?: boolean;
  className?: string;
  "data-comma-icon"?: string;
  mode?: "masked" | "raw";
}>;

/* oxlint-disable unicorn/consistent-function-scoping -- icon factory intentionally scopes each wrapper. */
export const createCentralIcon = (CentralIconComponent: CentralIconComponent) => {
  function CreatedIcon({ className, mode }: IconProps) {
    return (
      <CentralIconComponent
        ariaHidden
        data-comma-icon=""
        {...(className !== undefined ? { className } : {})}
        // Raw mode renders the glyph paths directly. The masked mode emits a
        // deterministic <mask id> per glyph plus a mask="url(#id)" rect; with
        // repeated icons those ids collide document-wide, and when the first
        // instance sits inside a content-visibility:auto subtree (markdown
        // renderer roots), Chromium fails to resolve the mask and paints the
        // currentColor rect unmasked — icons degrade into solid squares.
        mode={mode ?? "raw"}
      />
    );
  }

  CreatedIcon.displayName =
    CentralIconComponent.displayName ?? CentralIconComponent.name;
  return CreatedIcon;
};
