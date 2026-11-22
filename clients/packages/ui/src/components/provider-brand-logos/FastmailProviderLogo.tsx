import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

// Fastmail's published identity artwork: https://www.fastmail.com/favicon.svg
export function FastmailProviderLogo(props: ProviderBrandLogoProps) {
  return (
    <svg
      height="24"
      width="24"
      {...props}
      aria-hidden="true"
      data-provider-logo="fastmail"
      fill="none"
      focusable="false"
      viewBox="0 0 40 40"
      xmlns="http://www.w3.org/2000/svg"
    >
      <circle cx="20" cy="20" r="16" fill="#fff" />
      <path d="M19.9998 19.9995L11.6665 14.2695V25.7279L16.8748 24.1645L19.9998 19.9995Z" fill="#FFC107" />
      <path d="M11.6665 25.7298H27.2915C27.8665 25.7298 28.3332 25.2632 28.3332 24.6882V14.2715L11.6665 25.7298Z" fill="#1b1e20" />
      <path d="M32.8707 11.151C34.6034 13.6674 35.6234 16.7129 35.6234 20.0001C35.6234 28.6292 28.6271 35.6256 19.998 35.6256C14.6562 35.6256 9.94344 32.9401 7.12707 28.8492L4.37435 28.7492L3.52344 31.3274C7.13071 36.5638 13.1616 40.0001 19.9998 40.0001C31.0453 40.0001 39.9998 31.0456 39.9998 20.0001C39.9998 15.7929 38.6943 11.8947 36.4762 8.67285L33.7507 8.74921L32.8707 11.151Z" fill="#69B3E7" />
      <path d="M4.37455 20C4.37455 11.3709 11.3709 4.37455 20 4.37455C25.3418 4.37455 30.0545 7.06 32.8709 11.1509L36.4745 8.67273C32.8691 3.43636 26.8382 0 20 0C8.95455 0 0 8.95455 0 20C0 24.2073 1.30545 28.1055 3.52364 31.3273L7.12727 28.8491C5.39455 26.3327 4.37455 23.2873 4.37455 20Z" fill="#0067B9" />
    </svg>
  );
}
