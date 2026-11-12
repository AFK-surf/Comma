import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

/**
 * still.fail's mark as its own site serves it (still.fail `web/public/mark.svg`,
 * 2026-11-07): the dark rounded square with two eyes and two pink cheeks.
 * Bundled locally; this is a provider brand, not a Central Icons glyph.
 */
export function StillfailProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="stillfail"
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect width="32" height="32" rx="7.2" fill="#1C1D20" />
      <path
        d="M12.48 15.23C12.48 16.4 11.54 17.34 10.37 17.34C9.2 17.34 8.26 16.4 8.26 15.23C8.26 14.06 9.2 13.12 10.37 13.12C11.54 13.12 12.48 14.06 12.48 15.23Z"
        fill="#FFFFFF"
      />
      <path
        d="M23.74 15.23C23.74 16.4 22.8 17.34 21.63 17.34C20.46 17.34 19.52 16.4 19.52 15.23C19.52 14.06 20.46 13.12 21.63 13.12C22.8 13.12 23.74 14.06 23.74 15.23Z"
        fill="#FFFFFF"
      />
      <path
        d="M5.73 21.7L7.84 21.7C8.53 21.7 9.09 22.26 9.09 22.94C9.09 23.63 8.53 24.19 7.84 24.19L5.73 24.19C5.04 24.19 4.48 23.63 4.48 22.94C4.48 22.26 5.04 21.7 5.73 21.7Z"
        fill="#F6BC9F"
      />
      <path
        d="M24.16 21.7L26.27 21.7C26.96 21.7 27.52 22.26 27.52 22.94C27.52 23.63 26.96 24.19 26.27 24.19L24.16 24.19C23.47 24.19 22.91 23.63 22.91 22.94C22.91 22.26 23.47 21.7 24.16 21.7Z"
        fill="#F6BC9F"
      />
    </svg>
  );
}
