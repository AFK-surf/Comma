import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

/**
 * Google Colab's interlocking double-ring mark in official brand amber (#F9AB00)
 * and deep orange (#E37400). Bundled locally; no SVG mask is used so phone
 * artwork exports render cleanly.
 */
export function GoogleColabProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      height="24"
      width="24"
      {...props}
      aria-hidden="true"
      data-provider-logo="google-colab"
      fill="none"
      focusable="false"
      viewBox="0 0 24 24"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M8.25 6C4.8 6 2 8.69 2 12H5C5 10.34 6.46 9 8.25 9C9.3 9 10.24 9.45 10.87 10.17L13.03 8.15C11.88 6.83 10.16 6 8.25 6Z"
        fill="#E37400"
      />
      <path
        d="M5 12H2C2 15.31 4.8 18 8.25 18C10.15 18 11.86 17.18 13.01 15.88L10.85 13.86C10.22 14.56 9.29 15 8.25 15C6.46 15 5 13.66 5 12Z"
        fill="#F9AB00"
      />
      <path
        d="M15.75 6C13.84 6 12.12 6.83 10.97 8.15L13.13 10.17C13.76 9.45 14.7 9 15.75 9C17.54 9 19 10.34 19 12H22C22 8.69 19.2 6 15.75 6Z"
        fill="#F9AB00"
      />
      <path
        d="M19 12C19 13.66 17.54 15 15.75 15C14.71 15 13.78 14.56 13.15 13.86L10.99 15.88C12.14 17.18 13.85 18 15.75 18C19.2 18 22 15.31 22 12H19Z"
        fill="#E37400"
      />
    </svg>
  );
}
