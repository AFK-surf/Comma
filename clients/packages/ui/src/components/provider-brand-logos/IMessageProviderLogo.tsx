import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

// A plain speech bubble on Messages green (#34C759, Apple's system green), drawn
// for Comma rather than copied from Apple artwork.
export function IMessageProviderLogo(props: ProviderBrandLogoProps) {
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
      <rect width="24" height="24" rx="6" fill="#34C759" />
      <path
        d="M12 5.5c-4.142 0-7.5 2.686-7.5 6 0 1.89 1.093 3.575 2.8 4.675-.12.918-.55 1.79-1.25 2.475 1.47-.05 2.73-.55 3.65-1.33.73.17 1.5.18 2.3.18 4.142 0 7.5-2.686 7.5-6s-3.358-6-7.5-6Z"
        fill="#fff"
      />
    </svg>
  );
}
