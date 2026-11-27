import {
  useCall,
  useTopic,
  type Collaboration,
  type TaskRequestContact,
  type TaskRequestIncoming,
  type TaskRequestSent,
} from "@comma/core-client";
import {
  taskStatusBucket,
  taskStatusBucketLabel,
  type CommaLocale,
  type TaskStatusBucket,
} from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import {
  ChevronTriangleDownSmallIcon,
  CircleXIcon,
  InviteIcon,
  MoreHorizontalIcon,
  ResetIcon,
  TrashCanIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
import { TaskListItem } from "@comma/ui/components/TaskListItem";
import { taskRequestAcceptBillingFailure } from "../billing/billingError";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import { Button as AriaButton } from "react-aria-components";
import { useNavigate } from "@tanstack/react-router";
import { useContext, useMemo, useState, type ReactNode } from "react";
import { useWorkspacePreference } from "../activeWorkspace";
import { CommaAuthContext } from "../auth-context";
import { formatCompactRelative } from "../inbox/InboxGroup";
import { sentStatusLabel } from "../inbox/TaskRequestInbox";
import { openTaskTarget } from "../tasks/openTaskTarget";
import { useWorkspaceTasks } from "../tasks/useWorkspaceTasks";
import { AvatarStack, type Face } from "./AvatarStack";

/** How a Task concerns the person: done together, or handed to one Comma by the other. */
type Kind = "together" | "request";

type RowAction = {
  kind: "delete" | "withdraw" | "decline";
  label: string;
  run: () => void;
};

type Row = {
  key: string;
  kind: Kind;
  title: string;
  /** Where it stands; unknown for a Task together another person hosts (its status is theirs to read). */
  bucket: TaskStatusBucket | undefined;
  /** It waits for the account (an invite or a request to answer). */
  waiting: boolean;
  /** It waits for the other person: a request the account sent, not yet answered. */
  asked?: boolean;
  /** Milliseconds. */
  at: number;
  badge: ReactNode;
  /** Said instead of the time when the row ended without a Task (declined, expired). */
  word?: string | undefined;
  /** Action offered in the row's menu (delete a decided sent request, withdraw a waiting one, or decline). */
  action?: RowAction | undefined;
  open: () => void;
};

const FOLDED_DONE = 5;

type Known = { id: string; name: string | null; avatar?: Face["avatar"] };

const faces = (people: (Known | null)[]): Face[] =>
  people.flatMap((face) =>
    face
      ? [{ id: face.id, name: face.name, email: null, avatar: face.avatar ?? null }]
      : []
  );

/** The latest first. */
const byTime = (a: Row, b: Row) => b.at - a.at;

/**
 * Everything the account has to do with one person, on their page: the Tasks together it hosts with them, those they
 * or a third person host with both of them, and the requests either sent the other's Comma. One compact list, what
 * waits for the account and what runs first, the latest first; ended ones last, folded past five. A filter shows only
 * when there are both kinds.
 */
export function PersonTasks({ person }: { person: TaskRequestContact }) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const navigate = useNavigate();
  const own = useWorkspacePreference();
  const { tasks } = useWorkspaceTasks();
  const collaborations = useTopic({ topic: "collaborations" }).value?.items ?? [];
  const requests = useTopic(
    own !== undefined ? { topic: "taskRequests", prefer: own } : null
  ).value;
  const workspace = requests?.workspace ?? own;
  const [filter, setFilter] = useState<Kind | "all">("all");
  const [folds, setFolds] = useState<Record<string, boolean>>({});
  const name = person.name || person.email || "";
  const auth = useContext(CommaAuthContext);
  const requestFailed = (failure: unknown) => {
    const billingError = taskRequestAcceptBillingFailure(failure, m);
    if (billingError) {
      toast.error(billingError);
      return;
    }
    if ((failure as { code?: string } | null)?.code === "task_request_closed") {
      toast(m.task_requests_no_longer_waiting());
      void call("taskRequests.refresh", {}).catch(() => undefined);
      return;
    }
    toast.error(m.task_requests_failed());
  };
  // Looked up per row: by id, once per list.
  const peopleById = useMemo(
    () => new Map((requests?.people ?? []).map((p) => [p.id, p])),
    [requests?.people]
  );
  const tasksById = useMemo(
    () => new Map(tasks.map((task) => [task.conversationId, task])),
    [tasks]
  );
  // A person of a Task by their id, with their avatar where People has it.
  const known = (id: string, fallback: string | null = null): Known => {
    if (id === auth?.userId)
      return {
        id,
        name: auth.userDisplayName || auth.userEmail || null,
        avatar: auth.avatarRevision
          ? { source: "avatar", revision: auth.avatarRevision }
          : null,
      };
    if (id === person.id) return { id, name, avatar: person.avatar };
    // A seat given by email: shown as one, never by its address.
    if (id.includes("@")) return { id, name: "@" };
    const contact = peopleById.get(id);
    return {
      id,
      // Someone outside the account's People: by the name the Task gave.
      name: contact?.name ?? contact?.email ?? fallback,
      avatar: contact?.avatar ?? null,
    };
  };

  const statusOf = (taskId: string) => {
    const task = tasksById.get(taskId);
    return task ? { bucket: task.statusBucket, at: task.updatedAt } : undefined;
  };

  const rows: Row[] = [
    // Tasks together the account hosts with them.
    ...tasks
      .filter((task) => task.together?.includes(person.id))
      .map(
        (task): Row => ({
          key: `host:${task.conversationId}`,
          kind: "together",
          title: task.title,
          bucket: task.statusBucket,
          waiting: false,
          at: task.updatedAt,
          badge: (
            <AvatarStack
              max={3}
              // The account hosts it: its face first, then everyone it was started with.
              people={faces(
                [auth?.userId, ...(task.together ?? [])]
                  .filter((id): id is string => typeof id === "string")
                  .filter((id, i, ids) => ids.indexOf(id) === i)
                  .map((id) => known(id))
              )}
            />
          ),
          open: () =>
            void navigate(
              openTaskTarget({
                conversationId: task.conversationId,
                groupId: task.groupId,
                workspaceId: task.workspaceId,
              })
            ),
        })
      ),
    // Tasks together they, or a third person, host with both of them.
    ...collaborations
      .filter(
        (item: Collaboration) =>
          item.host?.id === person.id ||
          item.members.some(
            (member) => member.status === "active" && member.person?.id === person.id
          )
      )
      .map(
        (item): Row => ({
          key: `member:${item.id}`,
          kind: "together",
          title: item.title,
          bucket: undefined,
          waiting: item.status === "invited",
          at: (item.invited_at ?? 0) * 1000,
          badge: (
            <AvatarStack
              max={3}
              people={faces(
                [
                  item.host,
                  ...item.members
                    .filter((member) => member.status === "active")
                    .map((member) => member.person),
                ].map((face) => {
                  if (!face) return null;
                  const resolved = known(face.id, face.name);
                  if (resolved.avatar || !face.avatar_id) return resolved;
                  return {
                    ...resolved,
                    avatar: {
                      source: "collaboration-avatar" as const,
                      group: item.task.group_id,
                      task: item.task.id,
                      user: face.id,
                      revision: face.avatar_id,
                    },
                  };
                })
              )}
            />
          ),
          open: () =>
            item.status === "invited"
              ? void navigate({ to: "/inbox" })
              : void navigate(
                  openTaskTarget({
                    conversationId: item.task.id,
                    groupId: item.task.group_id,
                    // Opened in the account's own Workspace: only the Task itself is the host's.
                    workspaceId: own ?? item.task.workspace_id,
                  })
                ),
        })
      ),
    // What they asked of the account's Comma.
    ...(requests?.received ?? [])
      .filter((request: TaskRequestIncoming) => request.sender?.id === person.id)
      .map((request): Row => {
        const task = request.task ? statusOf(request.task.id) : undefined;
        const ended = ["declined", "withdrawn", "expired"].includes(request.status);
        return {
          key: `from:${request.id}`,
          kind: "request",
          title: request.title,
          bucket: task?.bucket ?? (ended ? "cancelled" : undefined),
          waiting: request.status === "pending",
          at: task?.at ?? (request.created_at ?? 0) * 1000,
          badge: <AvatarStack people={faces([known(person.id)])} />,
          word:
            request.status === "declined"
              ? m.task_requests_status_declined()
              : request.status === "expired"
                ? m.task_requests_status_expired()
                : request.status === "withdrawn"
                  ? m.task_requests_status_withdrawn()
                  : undefined,
          action:
            request.status === "pending" && workspace
              ? {
                  kind: "decline",
                  label: m.task_requests_decline(),
                  run: () =>
                    void call("taskRequests.decline", {
                      workspace,
                      request: request.id,
                    }).catch(requestFailed),
                }
              : undefined,
          open: () =>
            request.task?.group_id && own
              ? void navigate(
                  openTaskTarget({
                    conversationId: request.task.id,
                    groupId: request.task.group_id,
                    workspaceId: own,
                  })
                )
              : void navigate({
                  params: { requestId: request.id },
                  to: "/inbox/request/$requestId",
                }),
        };
      }),
    // What the account asked of their Comma.
    ...(requests?.sent ?? [])
      .filter(
        (sent: TaskRequestSent) =>
          sent.workspace?.owner?.id === person.id && sent.status !== "withdrawn"
      )
      .map(
        (sent): Row => ({
          key: `to:${sent.id}`,
          kind: "request",
          title: sent.title,
          bucket: sent.task_status
            ? taskStatusBucket(sent.task_status)
            : ["declined", "expired"].includes(sent.status)
              ? "cancelled"
              : undefined,
          waiting: false,
          asked: sent.status === "pending",
          at: (sent.task_updated_at ?? sent.decided_at ?? sent.created_at ?? 0) * 1000,
          badge: <AvatarStack people={faces([known(person.id)])} />,
          word:
            sent.status === "declined" ||
            sent.status === "expired" ||
            sent.status === "pending"
              ? sentStatusLabel(sent, m, locale)
              : undefined,
          action:
            sent.status === "pending"
              ? {
                  kind: "withdraw",
                  label: m.task_requests_withdraw(),
                  run: () =>
                    void call("taskRequests.withdraw", { request: sent.id }).catch(
                      requestFailed
                    ),
                }
              : {
                  kind: "delete",
                  label: m.task_requests_delete(),
                  run: () =>
                    void call("taskRequests.hide", { request: sent.id }).catch(
                      requestFailed
                    ),
                },
          open: () =>
            void navigate({
              params: { requestId: sent.id },
              to: "/inbox/request/$requestId",
            }),
        })
      ),
  ];

  if (rows.length === 0) return null;
  const both =
    rows.some((r) => r.kind === "together") && rows.some((r) => r.kind === "request");
  // With one kind only the filter is hidden: it shows everything, whatever was chosen before.
  const shown = rows.filter((row) => !both || filter === "all" || row.kind === filter);
  // As the Tasks list groups them: what waits for the account first, then by status. A status the account cannot read
  // (a Task together another person hosts) and a request the other person has not answered yet count as running.
  const groups: {
    id: string;
    label: string;
    icon: ReactNode;
    rows: Row[];
  }[] = [
    {
      id: "waiting",
      label: m.people_tasks_waiting(),
      icon: <InviteIcon className="text-orange-500" />,
      rows: shown.filter((row) => row.waiting),
    },
    ...(["in_progress", "loops", "needs_review", "done", "cancelled"] as const).map(
      (bucket) => ({
        id: bucket,
        label: taskStatusBucketLabel(bucket, locale),
        icon: taskStatusIcon(bucket, { spins: false }),
        rows: shown.filter(
          (row) =>
            !row.waiting &&
            (row.bucket === "archived" ? "done" : (row.bucket ?? "in_progress")) ===
              bucket
        ),
      })
    ),
  ].filter((group) => group.rows.length > 0);

  const line = (row: Row) => <PersonTaskRow key={row.key} locale={locale} row={row} />;

  return (
    <section className="flex flex-col gap-sm" data-testid="person-tasks">
      <div className="flex items-center justify-between gap-md px-lg">
        <h3 className="m-0 flex items-baseline gap-sm text-sm font-medium text-primary">
          {m.people_detail_tasks()}
          <span className="font-mono text-sm tabular-nums text-quaternary">
            {rows.length}
          </span>
        </h3>
        {both ? (
          // A compact segmented control: a quiet track, the chosen part raised.
          <fieldset
            aria-label={m.people_detail_tasks()}
            className="m-0 flex min-w-0 items-center gap-xxs rounded-lg border-0 bg-secondary p-xxs"
          >
            {(
              [
                ["all", m.people_tasks_all()],
                ["together", m.people_task_together()],
                ["request", m.people_tasks_requests()],
              ] as const
            ).map(([id, label]) => (
              <AriaButton
                aria-pressed={filter === id}
                className={cx(
                  "rounded-md px-sm py-xxs text-xs font-medium outline-none focus-visible:shadow-focus-gray",
                  filter === id
                    ? "bg-primary text-primary shadow-xs"
                    : "text-tertiary hover:text-primary"
                )}
                key={id}
                onPress={() => setFilter(id)}
              >
                {label}
              </AriaButton>
            ))}
          </fieldset>
        ) : null}
      </div>
      {groups.map((group) => {
        // Ended ones stay out of the way once there are many.
        const open =
          folds[group.id] ??
          !(
            ["done", "cancelled"].includes(group.id) && group.rows.length > FOLDED_DONE
          );
        return (
          <div className="flex flex-col" key={group.id}>
            {/* The group's header is a row like its Tasks: its status icon over theirs, its name over their titles. */}
            <TaskListItem
              aria-expanded={open}
              as="button"
              className="bg-secondary"
              data-testid="person-task-group"
              icon={group.icon}
              layout="sidebar"
              onClick={() => setFolds((all) => ({ ...all, [group.id]: !open }))}
              tail={
                <ChevronTriangleDownSmallIcon
                  className={cx("size-[18px] text-quaternary", !open && "rotate-180")}
                />
              }
              title={
                <span className="font-medium">
                  {group.label}
                  <span className="ms-sm font-mono font-normal tabular-nums text-quaternary">
                    {group.rows.length}
                  </span>
                </span>
              }
              titleIdentity={group.id}
            />
            {open ? group.rows.toSorted(byTime).map(line) : null}
          </div>
        );
      })}
    </section>
  );
}

const actionIcon = (kind: RowAction["kind"]) => {
  switch (kind) {
    case "delete":
      return <TrashCanIcon />;
    case "withdraw":
      return <ResetIcon />;
    case "decline":
      return <CircleXIcon />;
  }
};

/**
 * One row of a person's Tasks: opens the Task or request, and for actionable requests offers delete/withdraw/decline
 * via both right-click context menu and a quiet hover/focus menu button in the tail slot.
 */
function PersonTaskRow({ locale, row }: { locale: CommaLocale; row: Row }) {
  const m = useCommaMessages();
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const action = row.action;
  const triggerAction = () => {
    if (!action) return;
    if (action.kind === "delete") {
      setConfirmingDelete(true);
      return;
    }
    action.run();
  };
  const menuItem = action ? (
    <MenuItem
      contentClassName="h-8"
      gutter="none"
      icon={actionIcon(action.kind)}
      id={action.kind}
      tone={action.kind === "delete" ? "destructive" : "default"}
    >
      {action.label}
    </MenuItem>
  ) : null;

  const item = (
    <TaskListItem
      as="button"
      badges={<span className="flex w-16 justify-end">{row.badge}</span>}
      className={action ? "min-w-0 flex-1" : undefined}
      {...(action && menuItem
        ? {
            contextMenu: {
              "aria-label": m.inbox_item_actions(),
              children: menuItem,
              className: "bg-popup-secondary px-sm py-sm shadow-2xl",
              onAction: triggerAction,
            },
          }
        : {})}
      data-testid="person-task"
      icon={
        row.waiting || row.asked ? (
          // As Inbox marks a request: orange while the account must answer it, quiet while the other person must.
          <InviteIcon className={row.waiting ? "text-orange-500" : "text-quaternary"} />
        ) : (
          taskStatusIcon(row.bucket ?? "in_progress", {
            spins: row.bucket !== undefined,
          })
        )
      }
      layout="sidebar"
      onClick={row.open}
      selected={menuOpen}
      tail={
        // A word (waiting, declined) is a state, not a time: a quiet pill, apart from the times beside it.
        <span
          className={cx(
            "flex w-18 justify-end",
            action &&
              "transition-opacity group-hover/person-task:opacity-0 group-focus-within/person-task:opacity-0 group-data-[menu-open=true]/person-task:opacity-0"
          )}
        >
          {row.word ? (
            <span className="rounded-full bg-secondary px-sm py-xxs text-xs font-normal text-tertiary">
              {row.word}
            </span>
          ) : (
            <span className="tabular-nums">
              {row.at ? formatCompactRelative(row.at, locale) : ""}
            </span>
          )}
        </span>
      }
      title={row.title}
      titleIdentity={row.key}
    />
  );

  if (!action || !menuItem) return item;

  return (
    <div
      className="group/person-task relative flex items-center"
      data-menu-open={menuOpen ? "true" : undefined}
    >
      {item}
      <div
        className={cx(
          "pointer-events-none absolute right-md flex items-center transition-opacity",
          menuOpen
            ? "pointer-events-auto opacity-100"
            : "opacity-0 group-hover/person-task:pointer-events-auto group-hover/person-task:opacity-100 group-focus-within/person-task:pointer-events-auto group-focus-within/person-task:opacity-100"
        )}
      >
        <MenuTrigger isOpen={menuOpen} onOpenChange={setMenuOpen}>
          <Button
            aria-label={m.inbox_item_actions()}
            data-testid="person-task-actions"
            hierarchy="tertiary-gray"
            iconLeading={<MoreHorizontalIcon />}
            iconOnly
            size="xs"
          />
          <MenuPopover placement="bottom end">
            <Menu
              aria-label={m.inbox_item_actions()}
              className="min-w-44 bg-popup-secondary px-sm py-sm shadow-2xl"
              onAction={triggerAction}
            >
              {menuItem}
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      </div>
      {confirmingDelete ? (
        <Dialog
          actions={[
            {
              hierarchy: "secondary-gray",
              label: m.people_cancel(),
              onPress: () => setConfirmingDelete(false),
            },
            {
              hierarchy: "destructive",
              label: m.task_requests_delete(),
              onPress: () => {
                setConfirmingDelete(false);
                action.run();
              },
            },
          ]}
          description={m.task_requests_delete_description()}
          isOpen
          onOpenChange={(open) => {
            if (!open) setConfirmingDelete(false);
          }}
          title={m.task_requests_delete_title()}
        />
      ) : null}
    </div>
  );
}
