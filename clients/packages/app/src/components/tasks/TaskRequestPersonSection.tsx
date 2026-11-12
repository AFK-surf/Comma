import type { FileSource } from "@comma/core-client";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";

/**
 * A Task panel section naming the other person of a Task request: who asked for the Task (Request, on its owner's
 * Task) or whom the person asked (To, on the request they sent). Their avatar, read through the request; their
 * initials until it arrives or without one.
 */
export function TaskRequestPersonSection({
  avatar,
  email,
  heading,
  name,
  note,
  testId,
}: {
  avatar?: FileSource | undefined;
  email?: string | null | undefined;
  heading: string;
  name: string;
  /** A line under the person, such as why they declined. */
  note?: string | null | undefined;
  testId: string;
}) {
  const url = useAvatarUrl(avatar);
  return (
    <section className="comma-task-panel-section" data-testid={testId}>
      <h2 className="comma-task-panel-heading">{heading}</h2>
      <div className="comma-task-panel-row">
        <span className="flex min-w-0 items-center gap-sm text-sm font-medium text-primary">
          <UserAvatar
            {...(url ? { avatarUrl: url } : {})}
            displayName={name}
            email={email ?? ""}
            size="xs"
          />
          <span className="truncate">{name}</span>
        </span>
      </div>
      {note ? <p className="comma-task-panel-feedback m-0">{note}</p> : null}
    </section>
  );
}
