import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

/**
 * Pi's identity artwork as the design supplies it (2026-09-16): three blocks
 * stepping down and across. Bundled locally rather than drawn from Central
 * Icons, but it takes the text color the way a glyph does, so a row that lists
 * it beside Codex and Claude Code reads as one set rather than one logo among
 * icons. The blocks do not overlap, so a single color leaves the mark solid.
 */
export function PiProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="pi"
      // The source artwork sits in an 800px canvas with wide margins; this box
      // is that artwork plus a margin of its own, so a mark that is solid where
      // its neighbours are strokes does not outweigh them.
      viewBox="100 100 600 600"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path fill="currentColor" d="M165.29 165.29H517.36V400H400V282.65H165.29Z" />
      <path
        fill="currentColor"
        d="M165.29 282.65H282.65V400H400V517.36H282.65V634.72H165.29Z"
      />
      <path fill="currentColor" d="M517.36 400H634.72V634.72H517.36Z" />
    </svg>
  );
}
