import { useState, type ImgHTMLAttributes } from "react";
import { PlaceholderIcon, UserFilledIcon } from "../icons";
import {
  detectAppKeybindingPlatform,
  type AppKeybindingPlatform,
} from "../settings-shortcut/appKeybinding";
import { cx } from "../utils";

export type AvatarSize = "xs" | "sm" | "md" | "lg" | "xl" | "2xl";

const sizeClasses: Record<AvatarSize, string> = {
  xs: "size-6 text-xs",
  sm: "size-8 text-sm",
  md: "size-10 text-md",
  lg: "size-12 text-lg",
  xl: "size-14 text-xl",
  "2xl": "size-16 text-xl",
};

export interface AvatarProps extends ImgHTMLAttributes<HTMLImageElement> {
  size?: AvatarSize;
  name?: string;
  /** Shown instead of the name's initials where there is no image. */
  emoji?: string | null;
  online?: boolean;
  /** Overrides host OS detection for emoji glyph metrics (primarily for tests). */
  platform?: AppKeybindingPlatform;
}

// Han, kana and Hangul: one character stands for the name and fits the smallest circle; two would wrap.
const ideographic =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

// By code point, so a surrogate pair (an emoji, a rare character) is never cut in half.
const first = (part: string) => Array.from(part)[0] ?? "";

/**
 * The name of someone known only by an email address: a seat not yet joined, or a guest who gave no name. Its face
 * is a person, not a letter.
 */
export const EMAIL_SEAT_NAME = "@";

export const getInitials = (name: string): string => {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (ideographic.test(name)) return first(parts.join(""));
  return parts.map(first).slice(0, 2).join("").toUpperCase();
};

export const Avatar = ({
  size = "md",
  name,
  emoji,
  online,
  platform = detectAppKeybindingPlatform(),
  src,
  alt,
  className,
  ...rest
}: AvatarProps) => {
  // The image that failed to load: a new one is shown again.
  const [failedSrc, setFailedSrc] = useState<string>();
  const showImage = Boolean(src) && src !== failedSrc;

  return (
    <span className={cx("relative inline-flex shrink-0", className)}>
      {showImage ? (
        <img
          src={src}
          alt={alt ?? name ?? "Avatar"}
          className={cx(
            "rounded-full object-cover ring-1 ring-avatar-profile-photo-border",
            sizeClasses[size]
          )}
          onError={() => setFailedSrc(src)}
          {...rest}
        />
      ) : (
        <span
          className={cx(
            "inline-flex items-center justify-center whitespace-nowrap rounded-full bg-avatar-bg font-semibold text-tertiary ring-1 ring-avatar-profile-photo-border",
            sizeClasses[size]
          )}
          aria-label={name}
        >
          {emoji ? (
            // Apple Color Emoji draws left-aligned inside a wider advance, so
            // a 1em box centers it on macOS/iOS. Segoe UI Emoji on Windows has
            // symmetric sidebearings (~1.36em advance), so 1em pushes it right;
            // natural width with a slight upward nudge centers it on Windows
            // without changing other platforms.
            <span
              className={
                platform === "windows"
                  ? "inline-flex items-center justify-center text-md font-normal leading-none -translate-y-[0.05em]"
                  : "block w-[1em] text-md font-normal leading-none"
              }
              aria-hidden
            >
              {emoji}
            </span>
          ) : name === EMAIL_SEAT_NAME ? (
            <UserFilledIcon aria-hidden className="size-[62%]" />
          ) : name ? (
            getInitials(name)
          ) : (
            <PlaceholderIcon
              className={cx(size === "xs" || size === "sm" ? "size-4" : "size-5")}
            />
          )}
        </span>
      )}
      {online !== undefined && (
        <span
          className={cx(
            "absolute bottom-0 right-0 block rounded-full ring-2 ring-primary",
            size === "xs" || size === "sm" ? "size-1.5" : "size-2.5",
            online ? "bg-fg-success-primary" : "bg-fg-quaternary"
          )}
          aria-hidden
        />
      )}
    </span>
  );
};
