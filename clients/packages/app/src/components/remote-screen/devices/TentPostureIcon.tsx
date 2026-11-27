import { createCentralIcon } from "@comma/ui/components/icons/createCentralIcon";
import { CentralIconBase } from "@central-icons-react/round-outlined-radius-2-stroke-2/CentralIconBase";
import { forwardRef, memo, type ComponentProps } from "react";

// Central Icons has no glyph for a foldable stood as a tent, so this one is drawn here on Central's own base: the same
// 24-unit frame, stroke, caps and icon contract as every other glyph (createCentralIcon). Its two halves meet at the
// hinge on top and stand open below, on a table line; the phone app draws the same (PostureGlyph.tent).
const CentralTentPosture = memo(
  forwardRef<SVGSVGElement, ComponentProps<typeof CentralIconBase>>(
    function CentralTentPosture(props, ref) {
      return (
        <CentralIconBase
          {...props}
          ref={ref}
          ariaLabel="tent-posture"
          maskId="comma-TentPosture"
        >
          <path
            d="M5.5 17.5L12 5.5L18.5 17.5"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path
            d="M3 20.5H21"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
          />
        </CentralIconBase>
      );
    }
  )
);

/** A foldable stood as a tent: the remote screen's tent posture. */
export const TentPostureIcon = createCentralIcon(CentralTentPosture);
