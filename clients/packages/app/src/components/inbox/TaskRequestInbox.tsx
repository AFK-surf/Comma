import {
  useCall,
  useTopic,
  type Collaboration,
  type TaskRequestIncoming,
  type TaskRequestSent,
} from "@comma/core-client";
import type {
  FileSource,
  TaskRequestGrant,
  TaskRequestPerson,
} from "@comma/core/contract";
import { taskStatusBucket, taskStatusLabel, type CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  InviteIcon,
  MoreHorizontalIcon,
  ResetIcon,
  TrashCanIcon,
} from "@comma/ui/components/icons";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
import { ContentHeader } from "@comma/ui/components/content-header";
import { TaskListItem } from "@comma/ui/components/TaskListItem";
import { taskRequestAcceptBillingFailure } from "../billing/billingError";
import { toast } from "@comma/ui/components/toast";
import { useNavigate, useParams } from "@tanstack/react-router";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useWorkspacePreference } from "../activeWorkspace";
import { CommaAuthContext } from "../auth-context";
import { useOptionalCommaClientSettings } from "../commaClientSettings";
import { playRequestSound } from "../notifications/notificationSound";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import { readFileBlob } from "../../runtime-files/fileSources";
import { TaskRequestPersonSection } from "../tasks/TaskRequestPersonSection";
import { TaskRequestChip } from "../tasks/taskChips";
import { NewStationTaskDialog } from "../tasks/station/NewStationTaskDialog";
import { formatCompactRelative } from "./InboxGroup";
import {
  inboxItemMenuTrigger,
  InboxItemMenuPopover,
  useInboxItemMenu,
} from "./InboxItemMenu";

// The reply comes from another workspace's Task: its images stay text and load nothing, and only its http(s) links open.
const sentReplyResourcePolicy = {
  onOpenLink: (url: string) => void openNativePlatformExternalUrl(url),
};

/** The workspace's requests waiting for its owner and those the person sent, as the core reads them (`taskRequests`). */
function useWaitingRequests() {
  const prefer = useWorkspacePreference();
  const { value } = useTopic(
    prefer !== undefined ? { topic: "taskRequests", prefer } : null
  );
  return {
    workspace: value?.workspace ?? undefined,
    incoming: value?.incoming ?? undefined,
    received: value?.received ?? undefined,
    sent: value?.sent ?? undefined,
    grants: value?.grants ?? undefined,
    people: value?.people ?? undefined,
  };
}

/**
 * Each person who took the account's own invite link, by its grant: they joined its People then. A grant made back when
 * the account took someone else's link is no news to it.
 */
function joinedGrants(grants: readonly TaskRequestGrant[] | undefined) {
  return (grants ?? []).filter(
    (grant) =>
      grant.status === "active" &&
      grant.from_invite &&
      grant.grantee &&
      grant.accepted_at
  );
}

type Messages = ReturnType<typeof useCommaMessages>;

export const recipientName = (sent: TaskRequestSent) =>
  sent.workspace?.owner?.name ||
  sent.workspace?.owner?.email ||
  sent.workspace?.name ||
  "";

/** What came of a sent request, in a word: the owner's decision, then its Task's status as the Task last reported it. */
export function sentStatusLabel(
  sent: TaskRequestSent,
  m: Messages,
  locale: CommaLocale
) {
  switch (sent.status) {
    case "pending":
      return m.task_requests_status_pending();
    case "declined":
      return m.task_requests_status_declined();
    case "withdrawn":
      return m.task_requests_status_withdrawn();
    case "expired":
      return m.task_requests_status_expired();
    default:
      return sent.task_status
        ? taskStatusLabel(sent.task_status, locale)
        : m.task_requests_status_accepted();
  }
}

/**
 * A withdraw or decline that failed. One the other side or the request's expiry closed first fails the same way on a
 * retry: the person hears it no longer waits, and the lists read what came of it.
 */
function answerFailed(
  call: ReturnType<typeof useCall>,
  messages: Messages,
  failure: unknown
) {
  const billingError = taskRequestAcceptBillingFailure(failure, messages);
  if (billingError) {
    toast.error(billingError);
    return;
  }
  if ((failure as { code?: string }).code !== "task_request_closed") {
    toast.error(messages.task_requests_failed());
    return;
  }
  toast(messages.task_requests_no_longer_waiting());
  void call("taskRequests.refresh", {}).catch(() => undefined);
}

/** A sent request has something new to read: its owner declined it, or its Task stopped with a result. */
const sentHasResult = (sent: TaskRequestSent) =>
  sent.status === "declined" ||
  (sent.status === "accepted" &&
    !!sent.task_status &&
    !["in_progress", "archived"].includes(taskStatusBucket(sent.task_status)));

export const senderName = (request: TaskRequestIncoming) =>
  request.sender?.name || request.sender?.email || "";

/** The sender's avatar, read for the workspace's owner; their initials until it arrives or without one. */
function SenderAvatar({
  request,
  size,
  workspace,
}: {
  request: TaskRequestIncoming;
  size: "compact" | "xs";
  workspace: string;
}) {
  const revision = request.sender?.avatar_id;
  const url = useAvatarUrl(
    revision
      ? { source: "sender-avatar", workspace, request: request.id, revision }
      : undefined
  );
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      displayName={request.sender?.name ?? undefined}
      email={request.sender?.email ?? ""}
      size={size}
    />
  );
}

/** A waiting request as a row of the Inbox's list, among the Tasks by when it was sent. */
export interface InboxRequestRow {
  kind: "task_request";
  id: string;
  /** Unix seconds, as Inbox items' times may be. */
  updatedAt: number;
  request: TaskRequestIncoming;
  /** The workspace it waits in: the sender's avatar is read for it. */
  workspace?: string | undefined;
}

/**
 * Reads the requests again when the person comes back to the window: the server tells no client of a new request, so
 * this is when one sent meanwhile shows. One read of the requests' lists per return to the window, for the one
 * surface that calls it (the sidebar, mounted once per window).
 */
export function useRefreshRequestsOnReturn() {
  const call = useCall();
  const peopleEnabled = useOptionalCommaClientSettings()?.peopleEnabled ?? false;
  useEffect(() => {
    const refresh = () => {
      if (document.visibilityState !== "hidden") {
        void call("taskRequests.refresh", {}).catch(() => undefined);
        if (peopleEnabled)
          void call("collaborations.refresh", {}).catch(() => undefined);
      }
    };
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [call, peopleEnabled]);
}

/** A sent request's result toast, by the request: raised once per result. */
const resultToastId = (request: string) => `task-request-result:${request}`;

/** A request's toast, by the request: raised once, taken away when the request leaves the waiting list. */
const arrivalToastId = (request: string) => `task-request:${request}`;

/** At most this much of a request's words shows on its toast; the Inbox shows the rest. */
const ARRIVAL_WORDS = 160;

/**
 * Each request that comes while the window is open raises a toast: the sender's avatar and name, the request's words,
 * and View, which opens it in the Inbox. Those waiting when the window first reads the list raise none: the Inbox's
 * dot shows them. A request answered or withdrawn takes its toast away. The first toast of the requests a read brings
 * plays the request sound, when the person keeps it on (`requestSound`).
 */
export function useRequestArrivalToasts() {
  const messages = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const locale = useCommaLocale();
  const { grants, incoming, sent, workspace } = useWaitingRequests();
  // Read when a toast shows, so turning the sound on or off does not read the requests again.
  const requestSound = useRef(true);
  requestSound.current = useOptionalCommaClientSettings()?.requestSound ?? true;
  const auth = useContext(CommaAuthContext);
  // Scoped by workspace (from the same `taskRequests` snapshot as `sent`) with an
  // account fallback when a user has no workspace yet, so switching accounts never
  // replays the next account's already-finished requests as live toasts.
  const sentScope = workspace ?? auth?.userId ?? "";
  // Of each sent request, what it last said (none until the first read for this scope):
  // a change to a result raises its toast.
  const sentSeen = useRef<{
    scope: string;
    said: Map<string, string>;
    unfilled: Set<string>;
    suppressed: Set<string>;
    oldestCreatedAt: number | null;
  } | null>(null);
  useEffect(() => {
    if (!sent) return;
    const said = new Map(sent.map((r) => [r.id, `${r.status}:${r.task_status ?? ""}`]));
    const prev = sentSeen.current?.scope === sentScope ? sentSeen.current : null;
    let oldestCreatedAt = prev?.oldestCreatedAt ?? null;
    for (const request of sent) {
      if (
        request.created_at !== null &&
        (oldestCreatedAt === null || request.created_at < oldestCreatedAt)
      ) {
        oldestCreatedAt = request.created_at;
      }
    }
    if (!prev) {
      const unfilled = new Set(
        sent.filter((r) => r.status === "accepted" && !r.task_status).map((r) => r.id)
      );
      sentSeen.current = {
        scope: sentScope,
        said,
        unfilled,
        suppressed: new Set(),
        oldestCreatedAt,
      };
      return;
    }
    const unfilled = new Set(prev.unfilled);
    const suppressed = new Set(prev.suppressed);
    const prevOldest = prev.oldestCreatedAt;
    for (const request of sent) {
      const prior = prev.said.get(request.id);
      const current = said.get(request.id);
      const isOlderShift =
        prior === undefined &&
        prevOldest !== null &&
        request.created_at !== null &&
        request.created_at < prevOldest;
      if (isOlderShift && request.status === "accepted" && !request.task_status) {
        unfilled.add(request.id);
      }
      const wasUnfilled = unfilled.has(request.id);
      if (request.task_status) unfilled.delete(request.id);
      if (!sentHasResult(request)) {
        suppressed.delete(request.id);
        continue;
      }
      if (isOlderShift) continue;
      const reply = request.reply?.trim() ?? "";
      const lateReply =
        prior === current && suppressed.has(request.id) && reply.length > 0;
      if (prior === current && !lateReply) continue;
      // Historical receipt backfill fills a missing `task_status` without a reply;
      // update the list silently instead of raising persistent toasts for old Tasks.
      // Remember it so a live Router report arriving afterwards still raises its toast.
      if (wasUnfilled && prior === "accepted:" && !reply) {
        suppressed.add(request.id);
        continue;
      }
      suppressed.delete(request.id);
      const id = resultToastId(request.id);
      const name = recipientName(request);
      toast(
        request.status === "declined"
          ? messages.task_requests_declined_by({ name })
          : messages.task_requests_result({
              name,
              status: sentStatusLabel(request, messages, locale),
            }),
        {
          id,
          testId: "task-request-result",
          ...(reply
            ? {
                description:
                  reply.length > ARRIVAL_WORDS
                    ? `${reply.slice(0, ARRIVAL_WORDS)}…`
                    : reply,
              }
            : {}),
          leading: (
            <UserAvatar
              displayName={request.workspace?.owner?.name ?? undefined}
              email={request.workspace?.owner?.email ?? ""}
              size="compact"
            />
          ),
          actions: [
            {
              label: messages.task_requests_view(),
              onPress: () => {
                toast.dismiss(id);
                void navigate({
                  params: { requestId: request.id },
                  to: "/inbox/request/$requestId",
                });
              },
            },
          ],
        }
      );
    }
    sentSeen.current = {
      scope: sentScope,
      said,
      unfilled,
      suppressed,
      oldestCreatedAt,
    };
  }, [locale, messages, navigate, sent, sentScope]);
  const peopleEnabled = useOptionalCommaClientSettings()?.peopleEnabled ?? false;
  // Someone took the account's invite link while the window is open: a toast, as a request's arrival raises one.
  const joinedSeen = useRef<{ workspace: string; ids: Set<string> } | null>(null);
  useEffect(() => {
    if (!peopleEnabled) {
      joinedSeen.current = null;
      return;
    }
    if (!grants || !workspace) return;
    const joined = joinedGrants(grants);
    const before =
      joinedSeen.current?.workspace === workspace ? joinedSeen.current.ids : null;
    joinedSeen.current = { workspace, ids: new Set(joined.map((grant) => grant.id)) };
    // The first read of a workspace is what joined before: the Inbox lists those.
    if (!before) return;
    for (const grant of joined) {
      if (before.has(grant.id) || !grant.grantee) continue;
      const person = grant.grantee;
      const id = `people-joined:${grant.id}`;
      toast(messages.people_joined({ name: personName(person, messages) }), {
        id,
        testId: "people-joined",
        description: messages.people_joined_detail(),
        leading: (
          <UserAvatar
            displayName={person.name ?? undefined}
            email={person.email ?? ""}
            size="compact"
          />
        ),
        actions: [
          {
            label: messages.task_requests_view(),
            onPress: () => {
              toast.dismiss(id);
              void navigate({ to: "/people", search: { person: person.id } });
            },
          },
        ],
      });
    }
  }, [grants, messages, navigate, peopleEnabled, workspace]);
  // What the window has already seen of a workspace (none until its first read); each raised toast's avatar URL, to
  // revoke with it.
  const seen = useRef<{ workspace: string; ids: Set<string> } | null>(null);
  const raised = useRef(new Map<string, string | undefined>());

  useEffect(() => {
    if (!incoming || !workspace) return;
    const waiting = new Set(incoming.map((r) => r.id));
    for (const [id, url] of raised.current) {
      if (waiting.has(id)) continue;
      raised.current.delete(id);
      toast.dismiss(arrivalToastId(id));
      if (url) URL.revokeObjectURL(url);
    }
    const before = seen.current?.workspace === workspace ? seen.current.ids : null;
    seen.current = { workspace, ids: waiting };
    // Another workspace's list, as the first, is what waited already.
    if (!before) return;
    let sounded = false;
    for (const request of incoming) {
      if (before.has(request.id)) continue;
      const id = arrivalToastId(request.id);
      const done = () => {
        const url = raised.current.get(request.id);
        raised.current.delete(request.id);
        if (url) URL.revokeObjectURL(url);
      };
      const show = (avatarUrl?: string) => {
        // Answered or withdrawn while its avatar loaded: no toast.
        if (!seen.current?.ids.has(request.id)) {
          if (avatarUrl) URL.revokeObjectURL(avatarUrl);
          return;
        }
        raised.current.set(request.id, avatarUrl);
        if (!sounded && requestSound.current) playRequestSound();
        sounded = true;
        const words = request.content.trim();
        toast(messages.task_requests_arrived({ name: senderName(request) }), {
          id,
          testId: "task-request-arrived",
          description:
            words.length > ARRIVAL_WORDS ? `${words.slice(0, ARRIVAL_WORDS)}…` : words,
          leading: (
            <UserAvatar
              {...(avatarUrl ? { avatarUrl } : {})}
              displayName={request.sender?.name ?? undefined}
              email={request.sender?.email ?? ""}
              size="compact"
            />
          ),
          actions: [
            {
              label: messages.task_requests_view(),
              onPress: () => {
                toast.dismiss(id);
                done();
                void navigate({
                  params: { requestId: request.id },
                  to: "/inbox/request/$requestId",
                });
              },
            },
          ],
          onClose: done,
        });
      };
      const revision = request.sender?.avatar_id;
      if (!revision) {
        show();
        continue;
      }
      readFileBlob(call, {
        source: "sender-avatar",
        workspace,
        request: request.id,
        revision,
      }).then(
        (blob) => show(URL.createObjectURL(blob)),
        () => show()
      );
    }
  }, [call, incoming, messages, navigate, workspace]);
}

/** The workspace's waiting requests as Inbox rows, newest first. */
export function useInboxRequestRows(): InboxRequestRow[] {
  const { incoming, workspace } = useWaitingRequests();
  return useMemo(
    () =>
      (incoming ?? []).map((request) => ({
        kind: "task_request" as const,
        id: `task-request:${request.id}`,
        updatedAt: request.created_at ?? 0,
        request,
        ...(workspace ? { workspace } : {}),
      })),
    [incoming, workspace]
  );
}

/**
 * A request the person sent, as an Inbox row: the Task it asked for, as the person follows it. Its status is the
 * owner's decision and then what the Task last reported; it sits among the Tasks by when that last changed.
 */
export interface InboxSentRow {
  kind: "task_request_sent";
  id: string;
  /**
   * Unix milliseconds, as a Task's: its Inbox deleted mark sits among the Tasks' marks, which the core trims oldest
   * first.
   */
  updatedAt: number;
  sent: TaskRequestSent;
}

/** An invitation to a Task another person hosts, as an Inbox row: it waits for the person, as a request does. */
export interface InboxInvitationRow {
  kind: "collaboration_invite";
  id: string;
  /** Unix seconds, as a request's. */
  updatedAt: number;
  invitation: Collaboration;
}

/** Someone who took the account's invite link, as an Inbox row: they are in its People now. */
export interface InboxJoinedRow {
  kind: "people_joined";
  id: string;
  /** Unix milliseconds, as a sent request's: its Inbox deleted mark sits among the Tasks' marks. */
  updatedAt: number;
  person: TaskRequestPerson;
  avatar: FileSource | null;
}

/** A request's row of either side (waiting for the owner, or sent by the person), an invitation waiting, or a join. */
export type InboxRequestEntry =
  | InboxRequestRow
  | InboxSentRow
  | InboxInvitationRow
  | InboxJoinedRow;

/** The people who took the account's invite links, as Inbox rows, the latest first. */
export function useInboxJoinedRows(): InboxJoinedRow[] {
  const peopleEnabled = useOptionalCommaClientSettings()?.peopleEnabled ?? false;
  const { grants, people } = useWaitingRequests();
  return useMemo(
    () =>
      peopleEnabled
        ? joinedGrants(grants).flatMap((grant) =>
            grant.grantee
              ? [
                  {
                    kind: "people_joined" as const,
                    id: `people-joined:${grant.id}`,
                    updatedAt: (grant.accepted_at ?? 0) * 1000,
                    person: grant.grantee,
                    avatar:
                      people?.find((p) => p.id === grant.grantee?.id)?.avatar ?? null,
                  },
                ]
              : []
          )
        : [],
    [grants, people, peopleEnabled]
  );
}

const personName = (
  person: TaskRequestPerson,
  messages: ReturnType<typeof useCommaMessages>
) => person.name || person.email || messages.task_requests_unknown_person();

/**
 * A join's row: their face, that they joined the account's People, and when. Opens them in People; its menu hides it.
 */
export function InboxJoinedRowView({
  onDelete,
  row,
}: {
  onDelete: () => void;
  row: InboxJoinedRow;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const rowRef = useRef<HTMLButtonElement | null>(null);
  const menu = useInboxItemMenu();
  const avatarUrl = useAvatarUrl(row.avatar ?? undefined);
  return (
    <>
      <button
        className="block w-full rounded-xl border-0 bg-transparent p-0 text-left outline-none focus-visible:shadow-focus-gray"
        data-testid="inbox-people-joined"
        onClick={() =>
          void navigate({ to: "/people", search: { person: row.person.id } })
        }
        {...inboxItemMenuTrigger(menu, rowRef)}
        ref={rowRef}
        type="button"
      >
        <TaskListItem
          icon={
            <UserAvatar
              {...(avatarUrl ? { avatarUrl } : {})}
              displayName={row.person.name ?? undefined}
              email={row.person.email ?? ""}
              size="compact"
            />
          }
          layout="sidebar"
          selected={menu.isOpen}
          tail={
            <span>
              {row.updatedAt ? formatCompactRelative(row.updatedAt, locale) : ""}
            </span>
          }
          title={messages.people_joined({ name: personName(row.person, messages) })}
          titleIdentity={row.id}
        />
      </button>
      <InboxItemMenuPopover
        actions={["delete"]}
        isOpen={menu.isOpen}
        onAction={() => onDelete()}
        onOpenChange={menu.onOpenChange}
        pointerOffsets={menu.pointerOffsets}
        triggerRef={rowRef}
      />
    </>
  );
}

/** The person's invitations to Tasks others host, as Inbox rows. */
export function useInboxInvitationRows(): InboxInvitationRow[] {
  const peopleEnabled = useOptionalCommaClientSettings()?.peopleEnabled ?? false;
  const { value } = useTopic(peopleEnabled ? { topic: "collaborations" } : null);
  return useMemo(
    () =>
      peopleEnabled
        ? (value?.items ?? [])
            .filter((item) => item.status === "invited")
            .map((invitation) => ({
              kind: "collaboration_invite" as const,
              id: `collaboration:${invitation.id}`,
              updatedAt: invitation.invited_at ?? 0,
              invitation,
            }))
        : [],
    [peopleEnabled, value?.items]
  );
}

/** The requests the person sent as Inbox rows, but those they withdrew. */
export function useInboxSentRows(): InboxSentRow[] {
  const { sent } = useWaitingRequests();
  return useMemo(
    () =>
      (sent ?? [])
        .filter((request) => request.status !== "withdrawn")
        .map((request) => ({
          kind: "task_request_sent" as const,
          id: `task-request-sent:${request.id}`,
          updatedAt:
            (request.task_updated_at ?? request.decided_at ?? request.created_at ?? 0) *
            1000,
          sent: request,
        })),
    [sent]
  );
}

/**
 * A sent request's row: its Task's status mark, its title, whom it went to and when it last changed. Opens it in the
 * detail pane. Its menu withdraws it while it waits; once decided it only hides it (`onDelete`): the Task it became is
 * its owner's, not the person's to stop.
 */
export function InboxSentRowView({
  onDelete,
  row,
  selected,
}: {
  onDelete: () => void;
  row: InboxSentRow;
  selected: boolean;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const call = useCall();
  const rowRef = useRef<HTMLButtonElement | null>(null);
  const menu = useInboxItemMenu();
  const { sent } = row;
  const withdraw = () =>
    void call("taskRequests.withdraw", { request: sent.id }).then(
      () => {
        if (selected) void navigate({ replace: true, to: "/inbox" });
      },
      (failure: unknown) => answerFailed(call, messages, failure)
    );
  return (
    <>
      <button
        aria-current={selected ? "page" : undefined}
        className="block w-full rounded-xl border-0 bg-transparent p-0 text-left outline-none focus-visible:shadow-focus-gray"
        data-testid="inbox-task-request-sent"
        onClick={() =>
          void navigate({
            params: { requestId: sent.id },
            to: "/inbox/request/$requestId",
          })
        }
        {...inboxItemMenuTrigger(menu, rowRef)}
        ref={rowRef}
        type="button"
      >
        <TaskListItem
          // Once it is a Task: whom it went to.
          badges={
            sent.status === "accepted" ? (
              <TaskRequestChip
                avatar={
                  sent.workspace?.owner?.avatar_id
                    ? {
                        source: "recipient-avatar",
                        request: sent.id,
                        revision: sent.workspace.owner.avatar_id,
                      }
                    : undefined
                }
                direction="to"
                email={sent.workspace?.owner?.email}
                iconOnly
                name={recipientName(sent) || messages.task_requests_unknown_person()}
                nested
                testId="inbox-sent-request-chip"
              />
            ) : undefined
          }
          icon={
            sent.status === "accepted" && sent.task_status ? (
              taskStatusIcon(taskStatusBucket(sent.task_status))
            ) : (
              <InviteIcon className="text-orange-500" />
            )
          }
          layout="sidebar"
          selected={selected || menu.isOpen}
          // When it changed, as the Tasks beside it; only an end that left no Task says it in words.
          tail={
            <span>
              {sent.status === "declined" || sent.status === "expired"
                ? sentStatusLabel(sent, messages, locale)
                : row.updatedAt
                  ? formatCompactRelative(row.updatedAt, locale)
                  : ""}
            </span>
          }
          title={sent.title}
          titleIdentity={sent.id}
        />
      </button>
      <InboxItemMenuPopover
        actions={[sent.status === "pending" ? "withdraw" : "delete"]}
        isOpen={menu.isOpen}
        onAction={(action) => (action === "withdraw" ? withdraw() : onDelete())}
        onOpenChange={menu.onOpenChange}
        pointerOffsets={menu.pointerOffsets}
        triggerRef={rowRef}
      />
    </>
  );
}

/**
 * A request the person sent, opened in the detail pane: whom it went to and what came of it, its words, and the
 * words of its Task's latest Agent Message once the Task has a result. The person reads nothing else of that Task.
 */
function InboxSentRequestPane({ sent }: { sent: TaskRequestSent }) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const owner = sent.workspace?.owner;
  const status = sentStatusLabel(sent, messages, locale);
  const remove = () => {
    if (busy) return;
    setConfirmingDelete(false);
    setBusy(true);
    const write =
      sent.status === "pending"
        ? call("taskRequests.withdraw", { request: sent.id })
        : call("taskRequests.hide", { request: sent.id });
    void write.then(
      () => void navigate({ replace: true, to: "/inbox" }),
      (failure: unknown) => {
        setBusy(false);
        answerFailed(call, messages, failure);
      }
    );
  };
  return (
    <section
      aria-label={sent.title}
      className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="inbox-sent-request-pane"
    >
      <ContentHeader className="comma-chat-header">
        <div
          className="flex min-w-0 flex-1 items-center gap-sm"
          data-task-header="true"
        >
          <h1 className="comma-chat-title">{sent.title}</h1>
          <MenuTrigger>
            <Button
              aria-label={messages.inbox_item_actions()}
              data-testid="inbox-sent-request-actions"
              hierarchy="tertiary-gray"
              iconLeading={<MoreHorizontalIcon />}
              iconOnly
              isDisabled={busy}
              size="xs"
            />
            <MenuPopover placement="bottom start">
              <Menu
                aria-label={messages.inbox_item_actions()}
                className="min-w-44 bg-popup-secondary px-sm py-sm shadow-2xl"
                onAction={() => {
                  if (sent.status === "pending") remove();
                  else setConfirmingDelete(true);
                }}
              >
                <MenuItem
                  contentClassName="h-8"
                  gutter="none"
                  icon={sent.status === "pending" ? <ResetIcon /> : <TrashCanIcon />}
                  id={sent.status === "pending" ? "withdraw" : "delete"}
                  tone={sent.status === "pending" ? "default" : "destructive"}
                >
                  {sent.status === "pending"
                    ? messages.task_requests_withdraw_request()
                    : messages.task_requests_delete_request()}
                </MenuItem>
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </div>
      </ContentHeader>
      {/* The Task the person asked for, as a Task shows: its words and reply, and its details beside them. */}
      <div className="comma-chat-body" data-panel-open="true">
        <div className="comma-chat-thread">
          <div className="comma-chat-column flex flex-col gap-lg">
            <div className="comma-chat-message-user">
              <div className="comma-chat-user-bubble-slot">
                <div className="comma-chat-user-bubble">{sent.content}</div>
              </div>
            </div>
            {sent.reply ? (
              <div className="text-primary" data-testid="inbox-sent-request-reply">
                <MarkdownStream
                  animation="none"
                  className="text-sm leading-5"
                  content={sent.reply}
                  documentResourcePolicy={sentReplyResourcePolicy}
                  final
                  htmlPolicy="escape"
                  streamId={`task-request-reply:${sent.id}`}
                />
              </div>
            ) : sent.status === "declined" ? null : (
              <p className="m-0 text-sm text-tertiary">
                {messages.task_requests_no_result()}
              </p>
            )}
          </div>
        </div>
        <aside
          aria-label={messages.task_panel_region()}
          className="comma-task-panel"
          data-layout="column"
          data-open="true"
          data-testid="inbox-sent-request-panel"
        >
          <div className="comma-task-panel-inner">
            <section className="comma-task-panel-section">
              <h2 className="comma-task-panel-heading">
                {messages.task_panel_properties()}
              </h2>
              <div className="comma-task-panel-row">
                <span
                  className="comma-task-panel-pill"
                  data-status={
                    sent.status === "accepted" && sent.task_status
                      ? taskStatusBucket(sent.task_status)
                      : undefined
                  }
                  data-testid="inbox-sent-request-status"
                >
                  {sent.status === "accepted" && sent.task_status ? (
                    taskStatusIcon(taskStatusBucket(sent.task_status))
                  ) : (
                    <InviteIcon />
                  )}
                  {status}
                </span>
              </div>
            </section>
            <TaskRequestPersonSection
              avatar={
                owner?.avatar_id
                  ? {
                      source: "recipient-avatar",
                      request: sent.id,
                      revision: owner.avatar_id,
                    }
                  : undefined
              }
              email={owner?.email}
              heading={messages.task_panel_to()}
              name={recipientName(sent)}
              note={sent.decline_reason}
              testId="inbox-sent-request-to"
            />
          </div>
        </aside>
      </div>
      {confirmingDelete ? (
        <Dialog
          actions={[
            {
              hierarchy: "secondary-gray",
              label: messages.people_cancel(),
              onPress: () => setConfirmingDelete(false),
            },
            {
              hierarchy: "destructive",
              label: messages.task_requests_delete(),
              onPress: remove,
            },
          ]}
          description={messages.task_requests_delete_description()}
          isOpen
          onOpenChange={(open) => {
            if (!open) setConfirmingDelete(false);
          }}
          title={messages.task_requests_delete_title()}
        />
      ) : null}
    </section>
  );
}

/**
 * One request's row in the Inbox's list: the sender's avatar, the request's title and when it came. Opens it in the
 * detail pane. Its menu declines it: a request the owner only hid would still hold a place of its sender's pending
 * limit, unanswered.
 */
export function InboxRequestRowView({
  row,
  selected,
}: {
  row: InboxRequestRow;
  selected: boolean;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const call = useCall();
  const rowRef = useRef<HTMLButtonElement | null>(null);
  const menu = useInboxItemMenu();
  const { workspace } = useWaitingRequests();
  const { request } = row;
  // Its pane closes by itself once the request leaves the waiting list.
  const decline = () =>
    workspace &&
    void call("taskRequests.decline", { workspace, request: request.id }).catch(
      (failure: unknown) => answerFailed(call, messages, failure)
    );
  return (
    <>
      <button
        aria-current={selected ? "page" : undefined}
        className="block w-full rounded-xl border-0 bg-transparent p-0 text-left outline-none focus-visible:shadow-focus-gray"
        data-testid="inbox-task-request"
        onClick={() =>
          void navigate({
            params: { requestId: request.id },
            to: "/inbox/request/$requestId",
          })
        }
        {...inboxItemMenuTrigger(menu, rowRef)}
        ref={rowRef}
        type="button"
      >
        <TaskListItem
          // A request waits for the owner, as a Task to review does: it carries the attention dot until answered.
          dot
          icon={
            <SenderAvatar
              request={request}
              size="compact"
              workspace={workspace ?? ""}
            />
          }
          layout="sidebar"
          selected={selected || menu.isOpen}
          tail={
            <span>
              {row.updatedAt ? formatCompactRelative(row.updatedAt, locale) : ""}
            </span>
          }
          title={request.title}
          titleIdentity={request.id}
        />
      </button>
      <InboxItemMenuPopover
        actions={["decline"]}
        isOpen={menu.isOpen}
        onAction={decline}
        onOpenChange={menu.onOpenChange}
        pointerOffsets={menu.pointerOffsets}
        triggerRef={rowRef}
      />
    </>
  );
}

/**
 * The Task a request just became, so the detail pane can show it coming out of the request's blurred preview. The
 * Inbox's workspace owns it; the request's pane sets it as it opens the Task.
 */
interface InboxLaunch {
  launched: string | undefined;
  launch: (conversationId: string) => void;
  settle: () => void;
}

const InboxLaunchContext = createContext<InboxLaunch>({
  launched: undefined,
  launch: () => undefined,
  settle: () => undefined,
});

export function InboxLaunchProvider({ children }: { children: ReactNode }) {
  const [launched, setLaunched] = useState<string>();
  const settle = useCallback(() => setLaunched(undefined), []);
  const value = useMemo(
    () => ({ launched, launch: setLaunched, settle }),
    [launched, settle]
  );
  return (
    <InboxLaunchContext.Provider value={value}>{children}</InboxLaunchContext.Provider>
  );
}

export const useInboxLaunch = () => useContext(InboxLaunchContext);

/** The card leaving when its Task is made: fast and out of the way (Emil Kowalski's exit: ease-out, under 200ms). */
const CARD_EXIT: Keyframe[] = [
  { filter: "blur(0)", opacity: 1, transform: "none" },
  { filter: "blur(2px)", opacity: 0, transform: "translateY(8px) scale(0.97)" },
];
const CARD_EXIT_TIMING: KeyframeAnimationOptions = {
  duration: 180,
  easing: "cubic-bezier(0.23, 1, 0.32, 1)",
  fill: "forwards",
};

const reducedMotion = () =>
  document.documentElement.dataset.commaReducedMotion === "true";

/** What came of a received request, in a word. */
function incomingStatusLabel(request: TaskRequestIncoming, m: Messages) {
  switch (request.status) {
    case "pending":
      return m.task_requests_status_pending();
    case "accepted":
      return m.task_requests_status_accepted();
    case "declined":
      return m.task_requests_status_declined();
    case "withdrawn":
      return m.task_requests_status_withdrawn();
    case "expired":
      return m.task_requests_status_expired();
  }
}

/**
 * A received request that has already been answered (declined, expired, withdrawn, or accepted), opened read-only in
 * the detail pane: its title, words, status, and who sent it.
 */
function InboxAnsweredRequestPane({
  request,
  workspace,
}: {
  request: TaskRequestIncoming;
  workspace: string;
}) {
  const messages = useCommaMessages();
  const sender = request.sender;
  return (
    <section
      aria-label={request.title}
      className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="inbox-answered-request-pane"
    >
      <ContentHeader className="comma-chat-header">
        <div className="flex min-w-0 flex-1 items-center gap-sm">
          <h1 className="comma-chat-title">{request.title}</h1>
        </div>
      </ContentHeader>
      <div className="comma-chat-body" data-panel-open="true">
        <div className="comma-chat-thread">
          <div className="comma-chat-column flex flex-col gap-lg">
            <div className="comma-chat-message-user">
              <div className="comma-chat-user-bubble-slot">
                <div className="comma-chat-user-bubble">{request.content}</div>
              </div>
            </div>
          </div>
        </div>
        <aside
          aria-label={messages.task_panel_region()}
          className="comma-task-panel"
          data-layout="column"
          data-open="true"
          data-testid="inbox-answered-request-panel"
        >
          <div className="comma-task-panel-inner">
            <section className="comma-task-panel-section">
              <h2 className="comma-task-panel-heading">
                {messages.task_panel_properties()}
              </h2>
              <div className="comma-task-panel-row">
                <span
                  className="comma-task-panel-pill"
                  data-testid="inbox-answered-request-status"
                >
                  <InviteIcon />
                  {incomingStatusLabel(request, messages)}
                </span>
              </div>
            </section>
            <TaskRequestPersonSection
              avatar={
                sender?.avatar_id
                  ? {
                      source: "sender-avatar",
                      workspace,
                      request: request.id,
                      revision: sender.avatar_id,
                    }
                  : undefined
              }
              email={sender?.email}
              heading={messages.task_panel_request()}
              name={senderName(request)}
              note={request.decline_reason}
              testId="inbox-answered-request-from"
            />
          </div>
        </aside>
      </div>
    </section>
  );
}

/**
 * A request opened in the Inbox's detail pane, as the Task it would become: the Task's header with the request's
 * title, a conversation behind a blur (the request's words and a reply still to come), and the request's card where
 * the Task's message box would be. There the owner chooses where and on what it runs, and creates the Task or
 * declines the request. Making the Task takes the card away and opens the Task's own conversation here, sharpening out
 * of the blur; declining closes the pane. A request answered elsewhere closes it too.
 */
export function InboxRequestPane() {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const { launch } = useInboxLaunch();
  const { requestId } = useParams({ strict: false }) as { requestId?: string };
  const { incoming, received, sent, workspace } = useWaitingRequests();
  const live = incoming?.find((r) => r.id === requestId);
  // Accepting it takes it off the waiting list before its card has left: the pane keeps it until the Task opens.
  const [held, setHeld] = useState(live);
  if (live && live !== held) setHeld(live);
  const [launching, setLaunching] = useState(false);
  const request = live ?? (launching ? held : undefined);
  // An answered incoming request (declined, expired, withdrawn, accepted) stays readable from `received`.
  const answered =
    live || launching ? undefined : received?.find((r) => r.id === requestId);
  // A request the person sent opens as what came of it.
  const mine = live || answered ? undefined : sent?.find((r) => r.id === requestId);
  const card = useRef<HTMLDivElement>(null);
  const close = useCallback(
    () => void navigate({ replace: true, to: "/inbox" }),
    [navigate]
  );
  useEffect(() => {
    if (incoming && received && sent && !request && !answered && !mine) close();
  }, [answered, close, incoming, mine, received, request, sent]);

  if (answered && workspace)
    return <InboxAnsweredRequestPane request={answered} workspace={workspace} />;
  if (mine) return <InboxSentRequestPane sent={mine} />;
  if (!request || !workspace) return null;

  const accepted = (task: { id: string; group_id: string }) => {
    setLaunching(true);
    const open = () => {
      launch(task.id);
      void navigate({
        params: {
          conversationId: task.id,
          groupId: task.group_id,
          workspaceId: workspace,
        },
        replace: true,
        to: "/inbox/$workspaceId/$groupId/$conversationId",
      });
    };
    const element = card.current;
    if (!element || typeof element.animate !== "function" || reducedMotion()) {
      open();
      return;
    }
    element.animate(CARD_EXIT, CARD_EXIT_TIMING).finished.then(open, open);
  };

  return (
    <section
      aria-label={request.title}
      className="comma-chat-route comma-inbox-request flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-state={launching ? "launching" : undefined}
      data-testid="inbox-request-pane"
    >
      <ContentHeader className="comma-chat-header">
        <div className="flex min-w-0 flex-1 items-center gap-sm">
          <h1 className="comma-chat-title">{request.title}</h1>
        </div>
      </ContentHeader>
      {/* What the Task will look like, not yet readable: it is no conversation until the owner makes it one. */}
      <div
        aria-hidden
        className="comma-inbox-request-preview"
        data-testid="inbox-request-preview"
      >
        <div className="comma-chat-thread">
          <div className="comma-chat-column">
            <div className="comma-chat-message-user">
              <div className="comma-chat-user-bubble-slot">
                <div className="comma-chat-user-bubble">{request.content}</div>
              </div>
            </div>
            <div className="comma-inbox-request-reply">
              <span className="comma-inbox-request-reply-avatar" />
              <p>{messages.inbox_request_preview_reply()}</p>
              <p>{messages.inbox_request_preview_steps()}</p>
            </div>
          </div>
        </div>
      </div>
      <div className="comma-chat-composer-zone">
        <div className="comma-chat-composer-frame" ref={card}>
          <NewStationTaskDialog
            // A new card for each request: what was typed for one is not the next one's.
            key={request.id}
            onAccepted={accepted}
            onClose={close}
            request={{
              id: request.id,
              title: request.title,
              sender: (
                <div className="inline-flex items-center gap-xs rounded-full bg-tertiary py-0.5 px-sm text-xs text-secondary">
                  <span>{messages.task_requests_from_label()}</span>
                  <SenderAvatar request={request} size="xs" workspace={workspace} />
                  <span className="font-medium text-primary">
                    {senderName(request)}
                  </span>
                </div>
              ),
              content: request.content,
            }}
            workspace={workspace}
          />
        </div>
      </div>
    </section>
  );
}
