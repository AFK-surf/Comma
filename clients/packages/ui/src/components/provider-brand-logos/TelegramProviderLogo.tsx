import { useId } from "react";
import type { ProviderBrandLogoProps } from "./ProviderBrandLogos";

/**
 * Telegram's identity artwork as the design supplies it (Figma asset,
 * 2026-09-07): the blue disc with its two-tone paper plane. Bundled locally;
 * this is a provider brand, not a Central Icons glyph. The gradient id is
 * per instance so several logos on one page never share a definition.
 */
export function TelegramProviderLogo(props: ProviderBrandLogoProps) {
  const gradientId = `telegram-provider-logo-${useId().replaceAll(":", "")}`;
  return (
    <svg
      width="24"
      height="24"
      {...props}
      aria-hidden="true"
      focusable="false"
      data-provider-logo="telegram"
      viewBox="0 0 64 64"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={gradientId}
          x1="32"
          y1="64"
          x2="32"
          y2="0"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#1D93D2" />
          <stop offset="1" stopColor="#38B0E3" />
        </linearGradient>
      </defs>
      <circle cx="32" cy="32" r="32" fill={`url(#${gradientId})`} />
      <path
        d="M21.6621 34.3388L25.4587 44.8473C25.4587 44.8473 25.9333 45.8301 26.4418 45.8301C26.9503 45.8301 34.5096 37.9657 34.5096 37.9657L42.9164 21.7283L21.7977 31.6267L21.6621 34.3388Z"
        fill="#C8DAEA"
      />
      <path
        d="M26.6948 37.0342L25.9659 44.7799C25.9659 44.7799 25.6608 47.1527 28.0337 44.7799C30.4066 42.407 32.6778 40.5765 32.6778 40.5765"
        fill="#A9C6D8"
      />
      <path
        d="M21.7293 34.7142L13.9205 32.1696C13.9205 32.1696 12.9884 31.7913 13.2878 30.9325C13.3496 30.7554 13.4741 30.6049 13.847 30.3448C15.5777 29.1388 45.8752 18.2488 45.8752 18.2488C45.8752 18.2488 46.7308 17.9608 47.2366 18.1522C47.4677 18.2398 47.6152 18.3388 47.7394 18.7C47.7847 18.8315 47.8107 19.1111 47.8072 19.3894C47.8045 19.5901 47.7801 19.7758 47.7622 20.0673C47.5778 23.045 42.0564 45.2655 42.0564 45.2655C42.0564 45.2655 41.7261 46.5658 40.5424 46.61C40.1106 46.6263 39.5867 46.5387 38.9603 45.9999C36.6375 44.0018 28.6085 38.606 26.8347 37.4195C26.7343 37.3528 26.7061 37.2658 26.689 37.1809C26.6641 37.0561 26.7975 36.9005 26.7975 36.9005C26.7975 36.9005 40.7777 24.4733 41.1498 23.1695C41.1786 23.0683 41.0704 23.0184 40.9236 23.0621C39.9951 23.4038 23.8985 33.5678 22.1223 34.6906C22.0184 34.7562 21.7271 34.7139 21.7271 34.7139"
        fill="white"
      />
    </svg>
  );
}
