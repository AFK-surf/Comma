import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

// A speech bubble with "LINE" on LINE green (#06C755, LINE's brand color),
// drawn for Comma rather than copied from LINE artwork.
export function LineProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="line"
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect width="24" height="24" rx="6" fill="#06C755" />
      <path
        d="M12 4.75c-4.28 0-7.75 2.8-7.75 6.25 0 3.1 2.75 5.69 6.47 6.18.25.05.6.17.68.38.08.2.05.5.03.7l-.11.66c-.03.2-.16.77.68.42.83-.35 4.5-2.65 6.14-4.54 1.13-1.24 1.66-2.5 1.66-3.8 0-3.45-3.47-6.25-7.75-6.25Z"
        fill="#fff"
      />
      <path
        d="M7.6 9.4v3.2h1.9M10.6 9.4v3.2M12.1 12.6V9.4l2.1 3.2V9.4M17.1 9.4h-1.7v3.2h1.7M15.4 11h1.5"
        stroke="#06C755"
        strokeWidth="0.9"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
