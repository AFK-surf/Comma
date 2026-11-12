import { useId } from "react";
import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

/** PostHog's published logomark, the same artwork as its MCP authorization page. */
export function PostHogProviderLogo(props: ProviderBrandLogoProps) {
  const id = `posthog-provider-logo-${useId().replaceAll(":", "")}`;
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="posthog"
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <g transform="translate(2 6.58) scale(0.3872)">
        <path
          fill={`url(#${id}-p6)`}
          d="M10.74 7.16 4.54.8A2.66 2.66 0 0 0 0 2.66V7.5l10.74 11.18z"
        />
        <path fill={`url(#${id}-p7)`} d="M9.19 28h1.55v-9.32L0 7.5v10.73z" />
        <path fill={`url(#${id}-p8)`} d="M0 25.41A2.6 2.6 0 0 0 2.58 28H9.2L0 18.23z" />
        <path
          fill={`url(#${id}-p3)`}
          d="M10.74 2.66v4.5l11.22 11.52V7.63L15.3.8a2.66 2.66 0 0 0-4.56 1.86"
        />
        <path fill={`url(#${id}-p4)`} d="M10.74 28h8.96l-8.96-9.32z" />
        <path fill={`url(#${id}-p5)`} d="M10.74 7.16v11.52L19.7 28h2.26v-9.32z" />
        <path
          fill={`url(#${id}-p0)`}
          d="M21.96 2.67v4.96l11.3 11.6h.02V7.75L26.63.85a2.8 2.8 0 0 0-2-.85 2.67 2.67 0 0 0-2.67 2.67"
        />
        <path fill={`url(#${id}-p1)`} d="M21.96 7.63v11.05L31.03 28h2.25v-8.75z" />
        <path fill={`url(#${id}-p2)`} d="M21.96 28h9.07l-9.07-9.32z" />
        <path
          fill="currentColor"
          d="M51.66 25.22A1.9 1.9 0 0 0 50 23.33l-.34-.04c-1-.13-1.94-.6-2.65-1.33L33.28 7.75V28H49a2.66 2.66 0 0 0 2.67-2.67zM39.2 23.54h-.09a1.78 1.78 0 1 1 .1 0"
        />
      </g>
      <defs>
        <linearGradient
          id={`${id}-p0`}
          x1="21.96"
          x2="33.28"
          y1="9.62"
          y2="9.62"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#ffd849" />
          <stop offset=".96" stopColor="#fbae01" />
        </linearGradient>
        <linearGradient
          id={`${id}-p1`}
          x1="21.96"
          x2="33.28"
          y1="17.81"
          y2="17.81"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#ffb700" />
          <stop offset="1" stopColor="#f9aa01" />
        </linearGradient>
        <linearGradient
          id={`${id}-p2`}
          x1="21.96"
          x2="31.03"
          y1="23.34"
          y2="23.34"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#ff9500" />
          <stop offset="1" stopColor="#f8aa00" />
        </linearGradient>
        <linearGradient
          id={`${id}-p3`}
          x1="10.74"
          x2="21.96"
          y1="9.34"
          y2="9.34"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#ff651e" />
          <stop offset="1" stopColor="#e4400a" />
        </linearGradient>
        <linearGradient
          id={`${id}-p4`}
          x1="10.74"
          x2="19.7"
          y1="23.34"
          y2="23.34"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#c42c00" />
          <stop offset="1" stopColor="#d63600" />
        </linearGradient>
        <linearGradient
          id={`${id}-p5`}
          x1="10.74"
          x2="21.96"
          y1="17.58"
          y2="17.58"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#ef3c00" />
          <stop offset="1" stopColor="#d63601" />
        </linearGradient>
        <linearGradient
          id={`${id}-p6`}
          x1="0"
          x2="10.74"
          y1="9.34"
          y2="9.34"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#3f80ff" />
          <stop offset="1" stopColor="#084fe0" />
        </linearGradient>
        <linearGradient
          id={`${id}-p7`}
          x1="0"
          x2="10.74"
          y1="17.75"
          y2="17.75"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#0255ff" />
          <stop offset="1" stopColor="#0145d2" />
        </linearGradient>
        <linearGradient
          id={`${id}-p8`}
          x1="0"
          x2="9.19"
          y1="23.11"
          y2="23.11"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#0041c6" />
          <stop offset="1" stopColor="#0045d0" />
        </linearGradient>
      </defs>
    </svg>
  );
}
