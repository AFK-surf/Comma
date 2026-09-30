import { useState, type ImgHTMLAttributes } from "react";
import { PlaceholderIcon } from "../icons";
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
  online?: boolean;
}

const getInitials = (name: string): string =>
  name
    .split(" ")
    .map((part) => part[0])
    .join("")
    .slice(0, 2)
    .toUpperCase();

export const Avatar = ({
  size = "md",
  name,
  online,
  src,
  alt,
  className,
  ...rest
}: AvatarProps) => {
  const [hasImageError, setHasImageError] = useState(false);
  const showImage = Boolean(src) && !hasImageError;

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
          onError={() => setHasImageError(true)}
          {...rest}
        />
      ) : (
        <span
          className={cx(
            "inline-flex items-center justify-center rounded-full bg-avatar-bg font-semibold text-tertiary ring-1 ring-avatar-profile-photo-border",
            sizeClasses[size]
          )}
          aria-label={name}
        >
          {name ? (
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
