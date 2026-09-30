import { Avatar, cx, type AvatarSize } from "@comma/ui";

export type UserAvatarSize = AvatarSize | "compact";

export type UserAvatarProps = {
  avatarUrl?: string;
  className?: string;
  displayName?: string | undefined;
  email: string;
  size?: UserAvatarSize;
};

export function getUserDisplayName({
  displayName,
  email,
}: Pick<UserAvatarProps, "displayName" | "email">) {
  const normalizedDisplayName = displayName?.trim();
  if (normalizedDisplayName) {
    return normalizedDisplayName;
  }

  const normalizedEmail = email.trim();
  const [localPart] = normalizedEmail.split("@", 1);
  return localPart || normalizedEmail;
}

export function UserAvatar({
  avatarUrl,
  className,
  displayName,
  email,
  size = "sm",
}: UserAvatarProps) {
  const name = getUserDisplayName({ displayName, email });
  const compact = size === "compact";

  return (
    <Avatar
      alt={name}
      className={cx(
        "comma-user-avatar",
        compact && "[&>img]:size-5 [&>span]:size-5",
        className
      )}
      name={name}
      size={compact ? "xs" : size}
      {...(avatarUrl ? { src: avatarUrl } : {})}
    />
  );
}
