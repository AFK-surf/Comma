import type { FileSource } from "@comma/core-client";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";

/**
 * The other person of a Task request as their avatar, read through the request or grant that names them (`source`);
 * their initials until it arrives or without one. Sized as a chip's or menu row's mark.
 */
export function RequestPersonAvatar({
  className,
  email,
  name,
  source,
}: {
  className?: string | undefined;
  email?: string | null | undefined;
  name: string;
  source?: FileSource | undefined;
}) {
  const url = useAvatarUrl(source);
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      {...(className ? { className } : {})}
      displayName={name}
      email={email ?? ""}
      size="compact"
    />
  );
}
