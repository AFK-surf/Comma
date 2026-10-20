import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

// Tailscale brand artwork after Simple Icons (CC0), icons/tailscale.svg: the
// nine-dot grid with its "T" in full color and the other dots faded. Drawn in
// currentColor so it reads like an interface glyph beside Central Icons; the
// faded dots use opacity instead of Simple Icons' hairline rings, which
// disappear at sidebar size. Central Icons has no Tailscale mark.
const dots = [
  [4, 4, true],
  [12, 4, true],
  [20, 4, true],
  [4, 12, false],
  [12, 12, false],
  [20, 12, false],
  [4, 20, true],
  [12, 20, false],
  [20, 20, true],
] as const;

export function TailscaleProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="tailscale"
      viewBox="0 0 24 24"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      {dots.map(([cx, cy, faded]) => (
        <circle
          key={`${cx}-${cy}`}
          cx={cx}
          cy={cy}
          r="2.5"
          {...(faded ? { opacity: 0.2 } : {})}
        />
      ))}
    </svg>
  );
}
