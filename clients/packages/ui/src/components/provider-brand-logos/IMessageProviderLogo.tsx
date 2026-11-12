import { useId } from "react";
import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

// The squircle field, the disc that replaces it on a round mark, the speech
// bubble, the lit left edge of its tail, the tail's shaded underside, and the
// darker band along the crease that bounds it.
const disc = "M12 0A12 12 0 1 1 12 24A12 12 0 1 1 12 0Z";
const tile =
  "M6.79 0.03C4.39 0.12 3.03 0.62 1.82 1.82C0.6 3.04 0.14 4.35 0.03 6.86C0 7.73 0 16.27 0.03 17.14C0.14 19.65 0.58 20.91 1.8 22.15C3.02 23.39 4.32 23.86 6.84 23.97C7.7 24 16.3 24 17.16 23.97C19.68 23.86 20.98 23.39 22.2 22.15C23.42 20.91 23.86 19.65 23.97 17.14C24 16.27 24 7.73 23.97 6.86C23.86 4.35 23.4 3.04 22.18 1.82C20.95 0.6 19.64 0.13 17.13 0.02C16.34 0 7.6 0 6.79 0.03Z";
const bubble =
  "M11.32 3.81C6.14 4.1 2.3 8.06 3.01 12.35C3.36 14.4 4.51 16.04 6.55 17.39C7.13 17.78 7.32 18.45 6.98 18.97C6.89 19.13 6.77 19.27 6.52 19.55C6.2 19.92 6.16 19.97 6.18 20.05C6.24 20.3 7.48 19.95 8.17 19.49C8.24 19.44 8.4 19.34 8.52 19.25C8.97 18.95 9.33 18.82 9.83 18.77C10.04 18.75 10.15 18.76 10.55 18.8C11.49 18.92 12.48 18.92 13.41 18.8C15.1 18.58 16.73 17.93 18.03 16.96C19.59 15.79 20.63 14.16 20.92 12.45C21.05 11.74 21.04 10.75 20.9 10.16C20.89 10.1 20.86 9.98 20.84 9.88C20.1 6.23 15.9 3.55 11.32 3.81Z";
const ridge =
  "M6.55 17.39C7.13 17.78 7.32 18.45 6.98 18.97C6.89 19.13 6.77 19.27 6.52 19.55C6.2 19.92 6.16 19.97 6.18 20.05";
const underside =
  "M6.357 20.091C6.886 19.976 7.282 19.645 7.546 19.315C7.745 19.117 7.943 18.852 8.075 18.522C8.158 18.291 8.24 17.961 8.339 17.696C8.438 17.366 8.967 17.465 9.132 17.861C9.363 18.324 9.495 18.753 9.495 19.249C9.099 19.711 8.108 20.075 6.522 20.405Z";
const crease =
  "M6.357 20.091C6.886 19.976 7.282 19.645 7.546 19.315C7.745 19.117 7.943 18.852 8.075 18.522C8.158 18.291 8.24 17.961 8.339 17.696C8.372 17.63 8.438 17.63 8.471 17.729C8.57 18.126 8.57 18.522 8.471 18.819C8.339 19.15 8.141 19.447 7.976 19.678C7.646 20.009 7.183 20.273 6.522 20.372Z";

/**
 * The Messages artwork, redrawn as vector after the macOS Messages icon: the
 * green field, a glossy white bubble with its hooked tail, and the shadow the
 * bubble drops on the field.
 *
 * The depth comes from soft layers. Three blurred copies of the bubble, each
 * lower and wider than the last, make the shadow dark at the contact edge and
 * faint far out. Inside the bubble, a shade toward the right, a rim of bounce
 * light along the lower edge, and a highlight at the upper left model the
 * form; on the tail a lit ridge and a shaded underside follow its curve.
 *
 * On a disc the bubble is drawn smaller, so it keeps clear of the round edge.
 * The ids are per instance so several logos on one page never share a
 * definition.
 */
function IMessageArtwork({
  round = false,
  ...props
}: ProviderBrandLogoProps & { round?: boolean }) {
  const id = `imessage-provider-logo-${useId().replaceAll(":", "")}`;
  const field = round ? disc : tile;
  const art = round ? "translate(1.92 1.92) scale(0.84)" : undefined;
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="imessage"
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={`${id}-field`}
          x1="12"
          y1="0"
          x2="12"
          y2="24"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#82F281" />
          <stop offset="1" stopColor="#5AC24D" />
        </linearGradient>
        <linearGradient
          id={`${id}-body`}
          x1="5.465"
          y1="8.679"
          x2="8.934"
          y2="19.067"
          gradientUnits="userSpaceOnUse"
        >
          <stop offset="0" stopColor="#F3F8F2" />
          <stop offset="0.2" stopColor="#F0F6EE" />
          <stop offset="0.457" stopColor="#E6EFE4" />
          <stop offset="0.63" stopColor="#D8E7D3" />
          <stop offset="0.8" stopColor="#C4DFBC" />
          <stop offset="0.87" stopColor="#BFDDB7" />
          <stop offset="1" stopColor="#BBDCB2" />
        </linearGradient>
        <radialGradient
          id={`${id}-shade`}
          cx="0"
          cy="0"
          r="1"
          gradientUnits="userSpaceOnUse"
          gradientTransform="translate(21.982 12.973) scale(6.276 11.561)"
        >
          <stop offset="0" stopColor="#A0C996" stopOpacity="0.75" />
          <stop offset="0.6" stopColor="#A0C996" stopOpacity="0.36" />
          <stop offset="1" stopColor="#A0C996" stopOpacity="0" />
        </radialGradient>
        <linearGradient
          id={`${id}-rim`}
          x1="12"
          y1="8.679"
          x2="12"
          y2="16.276"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#CFF2C7" stopOpacity="0" />
          <stop offset="1" stopColor="#CFF2C7" stopOpacity="1" />
        </linearGradient>
        <radialGradient
          id={`${id}-gloss`}
          cx="0"
          cy="0"
          r="1"
          gradientUnits="userSpaceOnUse"
          gradientTransform="translate(5.631 8.844) scale(7.284 4.509)"
        >
          <stop offset="0" stopColor="#fff" stopOpacity="1" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </radialGradient>
        <linearGradient
          id={`${id}-ridge`}
          x1="12"
          y1="17.019"
          x2="12"
          y2="19.414"
          gradientUnits="userSpaceOnUse"
        >
          <stop offset="0" stopColor="#FFFFFF" stopOpacity="0" />
          <stop offset="1" stopColor="#FFFFFF" stopOpacity="1" />
        </linearGradient>
        <linearGradient
          id={`${id}-crease`}
          x1="12"
          y1="17.564"
          x2="12"
          y2="19.414"
          gradientUnits="userSpaceOnUse"
        >
          <stop offset="0" stopColor="#6CB76A" stopOpacity="0" />
          <stop offset="0.41" stopColor="#6CB76A" stopOpacity="0.25" />
          <stop offset="0.73" stopColor="#6CB76A" stopOpacity="0.57" />
          <stop offset="1" stopColor="#6CB76A" stopOpacity="1" />
        </linearGradient>
        <filter
          id={`${id}-ridgeBlur`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.297" />
        </filter>
        <filter
          id={`${id}-creaseBlur`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.099" />
        </filter>
        <filter
          id={`${id}-creaseWide`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.363" />
        </filter>
        <filter
          id={`${id}-sh0`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.908" />
        </filter>
        <filter
          id={`${id}-sh1`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.495" />
        </filter>
        <filter
          id={`${id}-sh2`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.198" />
        </filter>
        <filter
          id={`${id}-glow`}
          x="0"
          y="0"
          width="24"
          height="24"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur stdDeviation="0.429" />
        </filter>
        <clipPath id={`${id}-tileClip`}>
          <path d={field} />
        </clipPath>
        <clipPath id={`${id}-bubbleClip`}>
          <path d={bubble} />
        </clipPath>
      </defs>
      <path d={field} fill={`url(#${id}-field)`} />
      <g clipPath={`url(#${id}-tileClip)`}>
        <path d={field} stroke="#fff" strokeOpacity="0.22" strokeWidth="0.3" />
        <g transform={art}>
          <path
            d={bubble}
            transform="translate(0 1.156)"
            fill="#0F5A14"
            fillOpacity="0.253"
            filter={`url(#${id}-sh0)`}
          />
          <path
            d={bubble}
            transform="translate(0 0.562)"
            fill="#0F5A14"
            fillOpacity="0.345"
            filter={`url(#${id}-sh1)`}
          />
          <path
            d={bubble}
            transform="translate(0 0.165)"
            fill="#0F5A14"
            fillOpacity="0.345"
            filter={`url(#${id}-sh2)`}
          />
        </g>
      </g>
      <g transform={art}>
        <path d={bubble} fill={`url(#${id}-body)`} />
        <g clipPath={`url(#${id}-bubbleClip)`}>
          <path d={bubble} fill={`url(#${id}-shade)`} />
          <path
            d={bubble}
            stroke={`url(#${id}-rim)`}
            strokeWidth="2.61"
            filter={`url(#${id}-glow)`}
          />
          <path d={bubble} fill={`url(#${id}-gloss)`} />
          <path
            d={ridge}
            stroke={`url(#${id}-ridge)`}
            strokeWidth="0.925"
            strokeLinecap="round"
            filter={`url(#${id}-ridgeBlur)`}
          />
          <path
            d={underside}
            fill={`url(#${id}-crease)`}
            fillOpacity="0.15"
            filter={`url(#${id}-creaseWide)`}
          />
          <path
            d={crease}
            fill={`url(#${id}-crease)`}
            fillOpacity="0.26"
            filter={`url(#${id}-creaseBlur)`}
          />
        </g>
      </g>
    </svg>
  );
}

/** The Messages app tile, which names the iMessage connection. */
export function IMessageProviderLogo(props: ProviderBrandLogoProps) {
  return <IMessageArtwork {...props} />;
}

/**
 * The round mark a message's source badge wears, a disc like the other
 * platforms' marks.
 */
export function IMessageProviderMark(props: ProviderBrandLogoProps) {
  return <IMessageArtwork round {...props} />;
}
