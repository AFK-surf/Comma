import { commaLogoUrl, commaProductMarkPathData } from "@comma/config";
import { useCommaMessages } from "@comma/i18n/react";
import { useId } from "react";

export function EmptyThread({
  exiting = false,
  variant,
}: {
  exiting?: boolean;
  variant: "default" | "side-chat";
}) {
  const messagesApi = useCommaMessages();

  if (variant === "side-chat") {
    return (
      <div
        className="comma-side-chat-empty-card"
        data-exiting={exiting ? "true" : undefined}
        data-testid={exiting ? "chat-empty-exiting" : "chat-empty"}
      >
        <div
          className="comma-side-chat-empty-mark comma-side-chat-empty-mark--brand"
          aria-hidden
        >
          <img alt="" src={commaLogoUrl} />
        </div>
        <div className="comma-side-chat-empty-copy">
          <h2>Comma</h2>
          <p>{messagesApi.chat_new_conversation()}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="comma-chat-empty" data-testid="chat-empty">
      <EmptyThreadMark />
      <div className="comma-chat-empty-copy">
        <h2>{messagesApi.chat_empty_title()}</h2>
        <p>{messagesApi.chat_empty_hint()}</p>
      </div>
    </div>
  );
}

// The product mark pressed into the surface: a 1px inner shadow at 15% black,
// in viewBox units (the 20-unit box renders at 72px).
function EmptyThreadMark() {
  const insetId = useId();
  return (
    <svg
      aria-hidden="true"
      className="comma-chat-empty-mark"
      fill="none"
      viewBox="0 0 20 20"
      xmlns="http://www.w3.org/2000/svg"
    >
      <filter id={insetId} colorInterpolationFilters="sRGB">
        <feOffset dy="0.28" in="SourceAlpha" />
        <feGaussianBlur stdDeviation="0.28" />
        <feComposite in2="SourceAlpha" k2="-1" k3="1" operator="arithmetic" />
        <feColorMatrix values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.15 0" />
        <feBlend in2="SourceGraphic" />
      </filter>
      <path
        d={commaProductMarkPathData}
        fill="currentColor"
        filter={`url(#${insetId})`}
      />
    </svg>
  );
}
