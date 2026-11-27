import { useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { HoverCard } from "@comma/ui/components/hover-card";
import { cx } from "@comma/ui/components/utils";
import { useWorkspacePreference } from "../activeWorkspace";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";
import { AvatarStack, type Face } from "./AvatarStack";
import { usePeopleFaces } from "./usePersonName";

const nameOf = (face: Face) => face.name || face.email || "";

/**
 * A Task together on its card: the faces of the people it was started with, overlapping, in place of a platform
 * chip. Hovering them lists each person and where they stand. It sits inside the card's button, so it is a plain
 * span and opens its list on pointer hover only; the Task's Members show the same to the keyboard.
 */
export function TaskTogetherChip({
  conversationId,
  people,
}: {
  conversationId: string;
  /** The User ids of the people it was started with, from the Task's summary. */
  people: readonly string[];
}) {
  const m = useCommaMessages();
  const faces = usePeopleFaces(people);
  const said = m.people_together_with({ names: faces.map(nameOf).join(", ") });
  return (
    <HoverCard
      content={<TogetherList conversationId={conversationId} faces={faces} />}
      placement="bottom start"
      pointerOnly
    >
      <span
        aria-label={said}
        className="inline-flex shrink-0 items-center"
        data-chip="together"
        data-testid="task-card-together"
      >
        <AvatarStack max={3} people={faces} size="2xs" surface="card" />
      </span>
    </HoverCard>
  );
}

/**
 * Who is in it, one row each: their face, name, and where they stand (read from the Task's Members when the list
 * opens, so the board reads nothing per card). Who declined, left or was taken out is not listed.
 */
function TogetherList({
  conversationId,
  faces,
}: {
  conversationId: string;
  faces: readonly Face[];
}) {
  const m = useCommaMessages();
  const workspace = useWorkspacePreference();
  const members = useTopic(
    workspace ? { topic: "taskMembers", workspace, task: conversationId } : null
  ).value?.members;
  const standing = new Map(
    (members ?? []).flatMap((member) =>
      member.person ? [[member.person.id, member.status] as const] : []
    )
  );
  // Who is in it: who declined, left or was taken out is not; who has not joined yet sits back and says so.
  const shown = faces.filter((face) => {
    const status = standing.get(face.id);
    return status === undefined || status === "active" || status === "invited";
  });
  return (
    <ul className="m-0 flex min-w-48 list-none flex-col gap-sm p-0">
      {shown.map((face) => {
        const waiting = standing.get(face.id) === "invited";
        return (
          <li className="flex min-w-0 items-center gap-sm" key={face.id}>
            <span className={cx("flex shrink-0", waiting && "opacity-50")}>
              <FaceAvatar face={face} />
            </span>
            <span
              className={cx(
                "min-w-0 flex-1 truncate text-sm",
                waiting ? "text-tertiary" : "text-primary"
              )}
            >
              {nameOf(face) || m.people_member_unnamed()}
            </span>
            {waiting ? (
              <span className="shrink-0 text-xs text-tertiary">
                {m.collab_guest_member_placeholder_invited()}
              </span>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}

function FaceAvatar({ face }: { face: Face }) {
  const url = useAvatarUrl(face.avatar ?? undefined);
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      displayName={nameOf(face)}
      email={face.email ?? ""}
      size="sm"
    />
  );
}
