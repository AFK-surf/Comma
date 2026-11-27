import { useCall, useTopic, type Collaboration } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ContentHeader } from "@comma/ui/components/content-header";
import { CoinsIcon, LockIcon } from "@comma/ui/components/icons";
import { TaskListItem } from "@comma/ui/components/TaskListItem";
import { toast } from "@comma/ui/components/toast";
import { useNavigate, useParams } from "@tanstack/react-router";
import { useContext, useEffect, useState } from "react";
import { CommaAuthContext } from "../auth-context";
import { useWorkspacePreference } from "../activeWorkspace";
import { formatCompactRelative } from "../inbox/InboxGroup";
import type { InboxInvitationRow } from "../inbox/TaskRequestInbox";
import { openTaskTarget } from "../tasks/openTaskTarget";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";
import { AvatarStack, type Face } from "./AvatarStack";
import { usePeopleAvatars } from "./usePersonName";

const nameOf = (person: Collaboration["host"]) => person?.name || person?.email || "";

/**
 * Who else is in an invitation's Task besides its host and the account itself: who joined or is invited. Their faces
 * are People's where the account has them, else their initials.
 */
function membersOf(
  item: Collaboration,
  self: string | undefined,
  avatarOf: (id: string) => Face["avatar"]
): Face[] {
  return item.members
    .filter((member) => member.status === "active" || member.status === "invited")
    .filter((member) => member.person?.id !== self)
    .flatMap(({ person }) =>
      person
        ? [
            {
              id: person.id,
              name: person.name,
              email: null,
              avatar: avatarOf(person.id),
            },
          ]
        : []
    );
}

/** The host's face: People's avatar where the account has them, else their initials. */
function HostAvatar({
  host,
  size,
}: {
  host: Collaboration["host"];
  size: "compact" | "sm";
}) {
  const avatarOf = usePeopleAvatars();
  const url = useAvatarUrl(avatarOf(host?.id) ?? undefined);
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      displayName={nameOf(host)}
      email=""
      size={size}
    />
  );
}

/**
 * Joins (the Task then opens as any Task does) or declines one invitation; `busy` while the answer is on its way, or
 * while the account's own Workspace is still being made (just signed up from the invite email), as the Task opens in it.
 */
function useAnswer(item: Collaboration) {
  const m = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const preferred = useWorkspacePreference();
  // Just signed up from the invite email: the account's own Workspace is still being made. Following it makes it
  // (`onboardingWorkspace` bootstraps while followed); Join waits until it is there.
  const made = useTopic(
    preferred === "" ? { topic: "onboardingWorkspace" } : null
  ).value;
  const own = preferred || (made?.status === "ready" ? made.workspaceId : undefined);
  const [busy, setBusy] = useState(false);
  const answer = (to: "accept" | "decline") => {
    setBusy(true);
    call("collaborations.answer", { id: item.id, answer: to }).then(
      () => {
        if (to === "accept")
          void navigate(
            openTaskTarget({
              conversationId: item.task.id,
              groupId: item.task.group_id,
              // Opened in the account's own Workspace: only the Task itself is the host's.
              workspaceId: own ?? item.task.workspace_id,
            })
          );
        else void navigate({ replace: true, to: "/inbox" });
      },
      () => {
        setBusy(false);
        toast.error(m.task_requests_failed());
      }
    );
  };
  return { answer, busy: busy || !own };
}

/** An invitation's row in the Inbox: its host's face, the Task's title, when it came; it waits as a request does. */
export function InboxInvitationRowView({
  row,
  selected,
}: {
  row: InboxInvitationRow;
  selected: boolean;
}) {
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const { invitation } = row;
  return (
    <button
      aria-current={selected ? "page" : undefined}
      className="block w-full rounded-xl border-0 bg-transparent p-0 text-left outline-none focus-visible:shadow-focus-gray"
      data-testid="inbox-collaboration-invite"
      onClick={() =>
        void navigate({
          params: { invitationId: invitation.id },
          to: "/inbox/invitation/$invitationId",
        })
      }
      type="button"
    >
      <TaskListItem
        dot
        icon={<HostAvatar host={invitation.host} size="compact" />}
        layout="sidebar"
        selected={selected}
        tail={
          <span>
            {row.updatedAt ? formatCompactRelative(row.updatedAt, locale) : ""}
          </span>
        }
        title={invitation.title}
        titleIdentity={invitation.id}
      />
    </button>
  );
}

/** The Inbox's detail pane for an invitation; one answered (here or elsewhere) closes it. */
export function InboxInvitationPane() {
  const navigate = useNavigate();
  const { invitationId } = useParams({ strict: false }) as { invitationId?: string };
  const { value } = useTopic({ topic: "collaborations" });
  const item = value?.items?.find(
    (candidate) => candidate.id === invitationId && candidate.status === "invited"
  );
  const loaded = value?.items != null;
  useEffect(() => {
    if (loaded && !item) void navigate({ replace: true, to: "/inbox" });
  }, [item, loaded, navigate]);
  return item ? <InvitationDetail item={item} /> : null;
}

/**
 * One invitation: the Task's title in the header; everyone in it by their faces in the middle (nothing of it is
 * readable yet); and where the message box will be, who invited the account and when, who pays, and decline or join.
 * Joined, it opens as any Task does.
 */
export function InvitationDetail({ item }: { item: Collaboration }) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const { answer, busy } = useAnswer(item);
  const self = useContext(CommaAuthContext)?.userId;
  const avatarOf = usePeopleAvatars();
  const host = nameOf(item.host);
  const everyone: Face[] = [
    ...(item.host
      ? [{ id: item.host.id, name: host, email: null, avatar: avatarOf(item.host.id) }]
      : []),
    ...membersOf(item, self, avatarOf),
  ];
  return (
    <section
      aria-label={item.title}
      className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="people-invitation-detail"
    >
      <ContentHeader className="comma-chat-header">
        <div className="flex min-w-0 flex-1 items-center gap-sm">
          <h1 className="comma-chat-title">{item.title}</h1>
        </div>
      </ContentHeader>
      {/* The Task it will be behind a thick blur, not yet readable (it is no conversation of the account's until it
          joins), and over it who it is with and what joining shows. */}
      <div className="relative flex min-h-0 flex-1 flex-col">
        <div
          aria-hidden
          className="comma-inbox-request-preview comma-invitation-preview"
        >
          <div className="comma-chat-thread">
            {/* A conversation of other people (none of it the account's yet): each on the left with a face, the
                host's first message, Comma's reply, a member's answer. Only its shape shows through the blur. */}
            <div className="comma-chat-column">
              <div className="comma-inbox-request-reply">
                <span className="comma-inbox-request-reply-avatar" />
                <p>{item.title}</p>
              </div>
              <div className="comma-inbox-request-reply">
                <span className="comma-inbox-request-reply-avatar" />
                <span className="block h-2 w-[92%] rounded-full bg-quaternary" />
                <span className="block h-2 w-[80%] rounded-full bg-quaternary" />
                <span className="block h-2 w-[56%] rounded-full bg-quaternary" />
              </div>
              <div className="comma-inbox-request-reply w-[40%]">
                <span className="comma-inbox-request-reply-avatar" />
                <span className="block h-2 w-[72%] rounded-full bg-quaternary" />
              </div>
            </div>
          </div>
        </div>
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-md px-xl text-center">
          <AvatarStack people={everyone} size="sm" />
          <p className="m-0 max-w-(--container-sm) text-sm text-balance text-primary">
            {m.people_together_with({
              names: new Intl.ListFormat(locale, { type: "conjunction" }).format(
                everyone.map((face) => face.name ?? "")
              ),
            })}
          </p>
          <p className="m-0 max-w-(--container-sm) text-xs text-balance text-tertiary">
            {m.people_invite_preview()}
          </p>
        </div>
      </div>
      <div className="comma-chat-composer-zone">
        <div className="comma-chat-composer-frame">
          {/* Faces on top, however many; who and what below; the answer at the foot. Concentric: the card's radius
              is its buttons' (md) plus its padding (md). */}
          <div className="mx-auto flex w-full max-w-[480px] flex-col gap-md rounded-2xl border-[0.5px] border-primary bg-popup-primary p-md">
            {/* The host and what they ask; everyone in it shows above. */}
            <div className="flex items-center gap-md px-sm pt-sm">
              <HostAvatar host={item.host} size="sm" />
              <div className="flex min-w-0 flex-1 flex-col">
                <span className="truncate text-sm font-medium text-primary">
                  {m.people_invited_by({ name: host })}
                  {item.invited_at ? (
                    <span className="ms-sm font-normal text-tertiary">
                      {formatCompactRelative(item.invited_at, locale)}
                    </span>
                  ) : null}
                </span>
                {/* What joining costs the account and what it shows it, each a glyph and a few words. */}
                <span className="mt-xs flex flex-wrap items-center gap-x-lg gap-y-xxs text-xs text-tertiary">
                  <span className="inline-flex items-center gap-xs">
                    <CoinsIcon aria-hidden className="size-3.5 text-quaternary" />
                    {m.people_invite_paid({ name: host })}
                  </span>
                  <span className="inline-flex items-center gap-xs">
                    <LockIcon aria-hidden className="size-3.5 text-quaternary" />
                    {m.people_invite_scope()}
                  </span>
                </span>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-sm">
              <Button
                hierarchy="secondary-gray"
                isDisabled={busy}
                onPress={() => answer("decline")}
                size="sm"
              >
                {m.people_decline()}
              </Button>
              <Button
                hierarchy="primary"
                isDisabled={busy}
                onPress={() => answer("accept")}
                size="sm"
              >
                {m.people_join()}
              </Button>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
