import {
  useCall,
  useTopic,
  type Collaboration,
  type CollaborationMember,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { MoreHorizontalIcon, PlusIcon } from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import { useNavigate } from "@tanstack/react-router";
import { useContext, useEffect, useState } from "react";
import { CommaAuthContext } from "../auth-context";
import { useActiveWorkspace, useWorkspacePreference } from "../activeWorkspace";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
} from "react-aria-components";
import { AvatarStack, type Face } from "./AvatarStack";
import { usePeopleAvatars } from "./usePersonName";

/**
 * The Task together the account joined as a member, if `conversationId` is one. Only a Task of another Group
 * (`groupId` not the account's own) can be: a Task of its own Group reads no memberships.
 */
export function useMembership(
  conversationId: string | undefined,
  groupId: string | undefined
): Collaboration | undefined {
  // The account's own Group, from the workspace the app already follows: no subscription of its own.
  const own = useActiveWorkspace()?.workspace;
  const elsewhere = Boolean(
    conversationId && groupId && own && own.groupId !== groupId
  );
  const { value } = useTopic(elsewhere ? { topic: "collaborations" } : null);
  return value?.items?.find(
    (item) => item.status === "active" && item.task.id === conversationId
  );
}

/**
 * Whether a Task is a Task together, and the account's part in it: `host` (it started it), `member` (it joined), or
 * undefined for any other Task.
 */
export function useTogetherRole(
  conversationId: string | undefined,
  workspaceId: string | undefined,
  groupId: string | undefined,
  /** The Task's summary says it was started with people (`together`): only then are its people read. */
  together: boolean
): "host" | "member" | undefined {
  const membership = useMembership(conversationId, groupId);
  const hosted = useTopic(
    !membership && together && conversationId && workspaceId
      ? { topic: "taskMembers", workspace: workspaceId, task: conversationId }
      : null
  ).value?.members;
  if (membership) return "member";
  return hosted && hosted.length > 0 ? "host" : undefined;
}

type Row = {
  id: string;
  name: string;
  /** What its face shows when not its name's initials: a seat given by email shows "@". */
  face?: string;
  /** The host's view of a seat given by email: its id, which a fresh link is sent for. */
  seat?: string;
  /** The host's view of a seat given by email that a guest took by name: the address under the name. */
  email?: string;
  /** Someone in it by the emailed link, without an account. */
  guest?: boolean;
  role: "host" | CollaborationMember["status"];
};

/**
 * The people of a Task together, in its details: the host, then everyone it was started with and where they stand.
 * The host can take a member (or an invite not yet answered) out; a member can leave. Nothing shows for any other Task.
 */
export function TaskMembers({
  changes = 0,
  conversationId,
  done = false,
  groupId,
  together,
  workspaceId,
}: {
  /** How many times someone left or was taken out, as the Task says: each reads a hosted Task's people again. */
  changes?: number;
  conversationId: string;
  groupId: string | undefined;
  /** The Task's summary says it was started with people: only then has it people to show. */
  together: boolean;
  /** The Task is done or in review: its host can start the next one with the same people from here. */
  done?: boolean;
  workspaceId: string | undefined;
}) {
  const m = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const auth = useContext(CommaAuthContext);
  const self = auth?.userId;
  const membership = useMembership(conversationId, groupId);
  const [leaving, setLeaving] = useState(false);
  const [listOpen, setListOpen] = useState(false);
  // The host reads its Task's people; a member already has them in its membership.
  const hosted = useTopic(
    !membership && together && workspaceId
      ? { topic: "taskMembers", workspace: workspaceId, task: conversationId }
      : null
  ).value?.members;

  const hosting = !membership && together && Boolean(workspaceId);
  // A member who joins, declines or leaves writes nothing in the Task: read again when the window comes back too.
  useEffect(() => {
    if (!hosting) return;
    const again = () => {
      if (document.visibilityState !== "hidden")
        void call("taskMembers.refresh", { task: conversationId }).catch(
          () => undefined
        );
    };
    window.addEventListener("focus", again);
    document.addEventListener("visibilitychange", again);
    return () => {
      window.removeEventListener("focus", again);
      document.removeEventListener("visibilitychange", again);
    };
  }, [call, conversationId, hosting]);
  useEffect(() => {
    if (hosting && changes > 0)
      void call("taskMembers.refresh", { task: conversationId }).catch(() => undefined);
  }, [call, changes, conversationId, hosting]);

  // Only a Task together reads People (names and faces): any other Task reads nothing more.
  const withPeople = Boolean(membership) || together;
  const avatarOf = usePeopleAvatars(withPeople);
  // A person with no name set: named from People where the account has them, else plainly unnamed.
  const prefer = useWorkspacePreference();
  const contacts = useTopic(
    withPeople && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  ).value?.people;
  const named = (id: string, name: string | null | undefined) => {
    if (name) return name;
    if (id === self && (auth?.userDisplayName || auth?.userEmail))
      return auth.userDisplayName || auth.userEmail;
    const contact = contacts?.find((person) => person.id === id);
    return contact?.name || contact?.email || m.people_member_unnamed();
  };

  const rows: Row[] = membership
    ? [
        ...(membership.host
          ? [
              {
                id: membership.host.id,
                name: named(membership.host.id, membership.host.name),
                role: "host" as const,
              },
            ]
          : []),
        ...membership.members.map((member, index) =>
          member.person
            ? {
                id: member.person.id,
                name: named(member.person.id, member.person.name),
                role: member.status,
              }
            : // A seat the host gave someone by email: everyone sees it is there, only the host whose. A guest who
              // joined by the emailed link is named by the name they gave, never their address.
              {
                id: `seat-${index}`,
                ...(member.guest_name
                  ? { name: member.guest_name, guest: true }
                  : {
                      // Not yet joined: Pending. Joined without giving a name: Guest.
                      name:
                        member.status === "invited"
                          ? m.collab_guest_member_placeholder_invited()
                          : m.collab_guest_member_placeholder_guest(),
                      face: "@",
                    }),
                role: member.status,
              }
        ),
      ]
    : [
        // The host's own view names itself first, as a member's names the host.
        ...(self && hosted && hosted.length > 0
          ? [{ id: self, name: named(self, null), role: "host" as const }]
          : []),
        ...(hosted ?? []).flatMap((member) =>
          member.person
            ? [
                {
                  id: member.person.id,
                  name: named(member.person.id, member.person.name),
                  role: member.status,
                },
              ]
            : member.invited_email
              ? // Someone not yet on Comma: their address until they sign in with it, or the name they gave on joining
                // by the emailed link, with the address under it.
                [
                  {
                    id: member.invited_email,
                    ...(member.guest_name
                      ? {
                          name: member.guest_name,
                          email: member.invited_email,
                          guest: true,
                        }
                      : { name: member.invited_email, face: "@" }),
                    ...(member.id ? { seat: member.id } : {}),
                    role: member.status,
                  },
                ]
              : []
        ),
      ];
  if (rows.length === 0) return null;
  const faces: Face[] = rows
    .filter(
      (row) => row.role === "host" || row.role === "active" || row.role === "invited"
    )
    .map((row) => ({
      id: row.id,
      name: row.face ?? row.name,
      email: null,
      avatar: row.face ? null : avatarOf(row.id),
    }));
  // Who joined or was invited (not who declined, left or was removed).
  const sameTeam = rows
    .filter((row) => row.role === "active" || row.role === "invited")
    .map((row) => row.id);

  // The list says who is in it: the host, who joined, and who has not joined yet. Who declined, left or was taken
  // out is not in it, and the conversation already says so.
  const listed = rows.filter(
    (row) => row.role === "host" || row.role === "active" || row.role === "invited"
  );
  const pending = m.collab_guest_member_placeholder_invited();

  const remove = (row: Row) => {
    if (!workspaceId) return;
    call("collaborations.remove", {
      workspace: workspaceId,
      task: conversationId,
      person: row.id,
    }).then(
      () => toast.success(m.people_member_removed_toast({ name: row.name })),
      () => toast.error(m.task_requests_failed())
    );
  };
  // A seat given by email gets a fresh link (the last one opens for 7 days); it counts toward the day's invite emails.
  const resend = (row: Row) => {
    if (!workspaceId || !row.seat) return;
    call("collaborations.resend", {
      workspace: workspaceId,
      task: conversationId,
      member: row.seat,
    }).then(
      () =>
        toast.success(m.people_member_resent_toast({ email: row.email ?? row.name })),
      (failure: unknown) =>
        toast.error(
          (failure as { code?: string } | null)?.code === "invite_daily_limit_reached"
            ? m.people_start_failed_invite_daily_limit()
            : m.task_requests_failed()
        )
    );
  };
  // Leaving cannot be undone (who is in a Task is fixed when it starts), so it asks first; left, the Task is gone
  // from the account's lists, and it goes back to them without leaving the Task behind in its history.
  const leave = () => {
    if (!membership) return;
    setLeaving(false);
    call("collaborations.answer", { id: membership.id, answer: "leave" }).then(
      () => {
        toast.success(m.people_member_left_toast());
        void navigate({ replace: true, to: "/tasks" });
      },
      () => toast.error(m.task_requests_failed())
    );
  };

  return (
    <section className="comma-task-panel-section" data-testid="task-panel-members">
      <h2 className="comma-task-panel-heading">{m.people_members()}</h2>
      {/* Everyone in it as overlapping faces, the host first; who declined, left or was taken out is not among them.
          Pressed, a list of each person, where they stand, and taking someone out or leaving. */}
      <DialogTrigger isOpen={listOpen} onOpenChange={setListOpen}>
        <AriaButton
          aria-label={m.people_members()}
          className="-mx-xs flex self-start rounded-full p-xs outline-none hover:bg-quaternary-hover focus-visible:shadow-focus-gray pressed:bg-quaternary-hover"
          data-testid="task-members-trigger"
        >
          <AvatarStack max={5} people={faces} />
        </AriaButton>
        <MenuPopover className={menuSurfaceClasses} placement="bottom start">
          <AriaDialog
            aria-label={m.people_members()}
            className="min-w-64 max-w-80 p-md outline-none"
            data-testid="task-members-list"
          >
            <ul className="m-0 flex list-none flex-col gap-sm p-0">
              {listed.map((row) => {
                const isSelf = row.id === self;
                const removable =
                  !membership && (row.role === "active" || row.role === "invited");
                const resendable = removable && Boolean(row.seat);
                const waiting = row.role === "invited";
                // One word at most, for what the name does not say: who runs it, who has not joined yet, the
                // account's own row, and a guest the host sees no address for.
                const word =
                  row.role === "host"
                    ? m.people_member_host()
                    : waiting
                      ? row.name === pending
                        ? null
                        : pending
                      : isSelf
                        ? m.people_member_you_tag()
                        : row.guest && !row.email
                          ? m.people_member_guest_tag()
                          : null;
                return (
                  <li
                    className="comma-member-row flex min-w-0 items-center gap-sm"
                    data-status={row.role}
                    data-testid="task-member"
                    key={row.id}
                  >
                    {/* Who has not joined yet sits back. */}
                    <span className={cx("flex shrink-0", waiting && "opacity-50")}>
                      <MemberAvatar
                        avatar={row.face ? null : avatarOf(row.id)}
                        name={row.face ?? row.name}
                      />
                    </span>
                    <span className="flex min-w-0 flex-1 flex-col">
                      <span
                        className={cx(
                          "truncate text-sm",
                          waiting ? "text-tertiary" : "text-primary"
                        )}
                      >
                        {row.name}
                      </span>
                      {row.email ? (
                        <span className="truncate text-xs text-tertiary">
                          {row.email}
                        </span>
                      ) : null}
                    </span>
                    {word ? (
                      <span className="comma-member-row-word shrink-0 text-xs text-tertiary">
                        {word}
                      </span>
                    ) : null}
                    {/* Shown on the row under the pointer (always, where there is no pointer to hover). */}
                    {removable ? (
                      <span className="comma-member-row-actions flex">
                        <MenuTrigger>
                          <Button
                            aria-label={m.people_actions({ name: row.name })}
                            hierarchy="tertiary-gray"
                            iconLeading={<MoreHorizontalIcon />}
                            iconOnly
                            size="xs"
                          />
                          <MenuPopover placement="bottom end">
                            <Menu aria-label={m.people_actions({ name: row.name })}>
                              {resendable ? (
                                <MenuItem
                                  id="resend"
                                  onAction={() => {
                                    setListOpen(false);
                                    resend(row);
                                  }}
                                >
                                  {m.people_member_resend()}
                                </MenuItem>
                              ) : null}
                              <MenuItem
                                id="remove"
                                onAction={() => {
                                  setListOpen(false);
                                  remove(row);
                                }}
                                tone="destructive"
                              >
                                {m.people_member_remove()}
                              </MenuItem>
                            </Menu>
                          </MenuPopover>
                        </MenuTrigger>
                      </span>
                    ) : null}
                  </li>
                );
              })}
            </ul>
            {membership ? (
              <div className="mt-sm border-t border-secondary pt-sm">
                <Button
                  className="w-full justify-start text-error-primary [--comma-button-hover-bg:var(--color-bg-error-primary)] [--comma-button-hover-fg:var(--color-text-error-primary)]"
                  data-testid="task-members-leave"
                  hierarchy="tertiary-gray"
                  onPress={() => {
                    setListOpen(false);
                    setLeaving(true);
                  }}
                  size="xs"
                >
                  {m.people_member_leave()}
                </Button>
              </div>
            ) : null}
          </AriaDialog>
        </MenuPopover>
      </DialogTrigger>
      {leaving ? (
        <Dialog
          actions={[
            {
              hierarchy: "secondary-gray",
              label: m.people_cancel(),
              onPress: () => setLeaving(false),
            },
            {
              hierarchy: "destructive",
              label: m.people_member_leave_confirm(),
              onPress: leave,
            },
          ]}
          description={m.people_member_leave_description()}
          isOpen
          onOpenChange={(open) => {
            if (!open) setLeaving(false);
          }}
          title={m.people_member_leave_title()}
        />
      ) : null}
      {!membership && done && sameTeam.length > 0 ? (
        // Something new is a new Task: as easy to start as replying, with the people already in it.
        <Button
          className="self-start"
          hierarchy="tertiary-gray"
          iconLeading={<PlusIcon />}
          onPress={() =>
            void navigate({ to: "/people", search: { with: sameTeam.join(",") } })
          }
          size="xs"
        >
          {m.people_same_team()}
        </Button>
      ) : null}
    </section>
  );
}

/** A member's face in the list: People's avatar where the account has them, else their initials (or "@"). */
function MemberAvatar({ avatar, name }: { avatar: Face["avatar"]; name: string }) {
  const url = useAvatarUrl(avatar ?? undefined);
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      displayName={name}
      email=""
      size="sm"
    />
  );
}
