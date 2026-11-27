import { useCall, useTopic, type TaskRequestContact } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ContentHeader } from "@comma/ui/components/content-header";
import { Dialog } from "@comma/ui/components/dialog";
import { PageLoading } from "@comma/ui/components/PageLoading";
import {
  EmailPlusIcon,
  ExclamationTriangleIcon,
  LoadingCircleIcon,
  MoreHorizontalIcon,
  PlusIcon,
  XIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
} from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { taskToolbarIconButtonClassName } from "@comma/ui/components/task-workspace";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { spacing } from "@comma/ui/tokens";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  Button as AriaButton,
  Header,
  ListBox,
  ListBoxItem,
  MenuSection,
} from "react-aria-components";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { useWorkspacePreference } from "../activeWorkspace";
import { useOptionalCommaClientSettings } from "../commaClientSettings";
import { useNearbyPeople } from "../nearby/useNearbyPeople";
import { commaInboxConversationRailWidth } from "../shellGeometry";
import { useNewTaskDialog } from "../tasks/station/NewTaskDialogContext";
import { openTaskTarget } from "../tasks/openTaskTarget";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";
import { InboxState } from "../inbox/InboxView";
import { AcceptInviteDialog } from "./AcceptInviteDialog";
import { AvatarStack, type Face } from "./AvatarStack";
import { startFailure } from "./startFailure";
import { PersonTasks } from "./PersonTasks";

const nameOf = (person: { name: string | null; email: string | null }) =>
  person.name || person.email || "";

/** What is on the right: nothing yet, one person, or a Task together being written with some of them. */
type Pane =
  | { kind: "none" }
  | { kind: "person"; id: string }
  | { kind: "start"; with: readonly string[]; byEmail?: true };

/**
 * People: the people the account works with, and doing something with them.
 *
 * The left is who they are, by name, nothing else: what waits from them (requests, invitations) is Inbox's. A press
 * opens a person on the right: who they are, a Task together with them, a request when they take requests, and the
 * Tasks the account shares with them. A Task together starts on the right as a new conversation does: who it is with
 * (more people are added from People, as recipients to a mail), its first message, start.
 */
export function PeopleRoute() {
  const m = useCommaMessages();
  const navigate = useNavigate();
  const peopleEnabled = useOptionalCommaClientSettings()?.peopleEnabled ?? false;
  const prefer = useWorkspacePreference();
  const { value } = useTopic(
    peopleEnabled && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  );
  const workspace = value?.workspace ?? undefined;
  const people = value?.people ?? null;
  // A done Task's "same people" opens People on a new Task together with them, already filled in.
  const search = useSearch({ strict: false }) as {
    with?: string;
    together?: string;
    person?: string;
  };
  const handed = search.with;
  const [pane, setPane] = useState<Pane>(() =>
    handed || search.together
      ? { kind: "start", with: (handed ?? "").split(",").filter(Boolean) }
      : search.person
        ? { kind: "person", id: search.person }
        : { kind: "none" }
  );
  // Opened again for another person (from Inbox while People shows): that person.
  useEffect(() => {
    if (search.person) setPane({ kind: "person", id: search.person });
  }, [search.person]);
  useEffect(() => {
    if (!peopleEnabled) void navigate({ to: "/", replace: true });
  }, [navigate, peopleEnabled]);
  if (!peopleEnabled) return null;
  const sorted = (people ?? []).toSorted((a, b) => nameOf(a).localeCompare(nameOf(b)));
  const open =
    pane.kind === "person" ? people?.find((p) => p.id === pane.id) : undefined;
  // Someone who left People (their grant revoked) leaves the Task being written with them.
  const together =
    pane.kind === "start" ? sorted.filter((p) => pane.with.includes(p.id)) : [];

  let detail: ReactNode;
  if (pane.kind === "start")
    detail = (
      <StartTogether
        everyone={sorted}
        onCancel={() =>
          setPane(
            together[0] ? { kind: "person", id: together[0].id } : { kind: "none" }
          )
        }
        byEmail={pane.byEmail === true}
        onChange={(ids) => setPane({ kind: "start", with: ids })}
        people={together}
        workspace={workspace}
      />
    );
  else if (open)
    detail = (
      <Profile
        onTaskTogether={() => setPane({ kind: "start", with: [open.id] })}
        person={open}
        workspace={workspace}
      />
    );
  else
    detail = (
      <div
        className="flex flex-1 flex-col items-center justify-center gap-lg px-xl text-center"
        data-testid="people-no-selection"
      >
        {/* As Inbox's empty pane says it, kept to a readable measure. */}
        <span className="max-w-(--container-xs) text-sm text-balance text-tertiary">
          {people && people.length === 0 ? m.people_empty() : m.people_pick()}
        </span>
        {/* No one yet: the ways to add someone are here, not only behind the list's +. */}
        {people && people.length === 0 ? (
          <AddButtons
            onStartByEmail={() => setPane({ kind: "start", with: [], byEmail: true })}
            workspace={workspace}
          />
        ) : null}
      </div>
    );

  return (
    <div
      className="flex min-h-0 min-w-0 flex-1 bg-main-panel-bg"
      data-testid="people-route"
    >
      <aside
        aria-label={m.people_title()}
        className="relative flex h-full min-h-0 shrink-0 flex-col border-r-[0.5px] border-primary bg-main-panel-bg"
        style={{ width: commaInboxConversationRailWidth }}
      >
        <ContentHeader className="justify-between">
          <h1 className="m-0 text-sm font-medium leading-5 tracking-[-0.14px] text-primary">
            {m.people_title()}
          </h1>
          <AddMenu
            disabled={value == null}
            onStartByEmail={() => setPane({ kind: "start", with: [], byEmail: true })}
            workspace={workspace}
          />
        </ContentHeader>
        <ScrollArea
          className="min-h-0 flex-1"
          contentClassName="flex min-h-full flex-col px-xs py-xs"
          edgeEffect="mask"
          orientation="vertical"
          scrollbarVisibility="scroll"
        >
          {people === null ? (
            // As Inbox shows it is reading: its own loading, in the rail's middle.
            <PageLoading indicator="spinner" label={m.people_loading()} />
          ) : people.length === 0 ? null : (
            <ListBox
              aria-label={m.people_title()}
              className="m-0 flex flex-col gap-px p-0 outline-none"
              dependencies={[pane]}
              items={sorted}
              onSelectionChange={(keys) => {
                if (keys === "all") return;
                const [id] = [...keys];
                if (id !== undefined) setPane({ kind: "person", id: String(id) });
              }}
              selectedKeys={open ? [open.id] : []}
              selectionMode="single"
            >
              {(person) => <PersonRow person={person} />}
            </ListBox>
          )}
        </ScrollArea>
        {people && people.length === 0 ? (
          // As Inbox says it has nothing: on the rail's own middle, level with the detail pane's words beside it.
          <InboxState overlay testId="people-empty" title={m.people_empty_title()} />
        ) : null}
      </aside>
      <section className="flex min-h-0 min-w-0 flex-1 flex-col">{detail}</section>
    </div>
  );
}

/** One person in the list: their face and their name. */
function PersonRow({ person }: { person: TaskRequestContact }) {
  const name = nameOf(person);
  const avatar = useAvatarUrl(person.avatar ?? undefined);
  return (
    <ListBoxItem
      className={({ isFocusVisible, isSelected }) =>
        cx(
          "flex min-w-0 cursor-default items-center gap-md rounded-lg px-md py-sm outline-none",
          isSelected ? "bg-sidebar-bg-item" : "hover:bg-sidebar-bg-item",
          isFocusVisible && "shadow-focus-gray"
        )
      }
      data-testid="people-row"
      id={person.id}
      textValue={name}
    >
      <UserAvatar
        {...(avatar ? { avatarUrl: avatar } : {})}
        displayName={name}
        email={person.email ?? ""}
        size="xs"
      />
      <span className="truncate text-sm text-primary">{name}</span>
    </ListBoxItem>
  );
}

/** The ways to add someone: someone nearby, a new invite link to copy, an invite link someone gave. */
function useAddPeople(workspace: string | undefined) {
  const m = useCommaMessages();
  const call = useCall();
  const nearby = useNearbyPeople(workspace);
  const [accepting, setAccepting] = useState(false);
  const copy = (url: string) =>
    nativePlatformClipboard
      .writeText(url)
      .then(() => toast.success(m.task_requests_invite_copied()));
  const createInvite = () => {
    if (!workspace) return;
    call("taskRequests.createInvite", { workspace, mode: "review" })
      .then(({ inviteUrl }) => copy(inviteUrl))
      .catch(() => toast.error(m.task_requests_failed()));
  };
  const dialogs = (
    <>
      {nearby.dialog}
      {accepting ? (
        <AcceptInviteDialog onClose={() => setAccepting(false)} workspace={workspace} />
      ) : null}
    </>
  );
  return { createInvite, dialogs, enter: () => setAccepting(true), nearby };
}

/**
 * With no one in People yet: the ways to add someone, side by side, under what the pane says. Under them, apart (it
 * adds no one to People): working with someone right away by their email, no link to trade.
 */
function AddButtons({
  onStartByEmail,
  workspace,
}: {
  onStartByEmail: () => void;
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const add = useAddPeople(workspace);
  return (
    <div className="flex flex-col items-center gap-lg">
      <div className="flex flex-wrap items-center justify-center gap-sm">
        {add.nearby.available ? (
          <Button hierarchy="secondary-gray" onPress={add.nearby.open} size="sm">
            {m.nearby_dialog_title()}
          </Button>
        ) : null}
        {/* Each says on hover what it does: who sends the link, who opens it. */}
        <Tooltip
          content={m.people_add_link()}
          placement="bottom"
          supportingText={m.people_add_link_tooltip()}
        >
          <Button
            hierarchy="secondary-gray"
            isDisabled={!workspace}
            onPress={add.createInvite}
            size="sm"
          >
            {m.people_add_link()}
          </Button>
        </Tooltip>
        <Tooltip
          content={m.people_add_enter()}
          placement="bottom"
          supportingText={m.people_add_enter_tooltip()}
        >
          <Button hierarchy="secondary-gray" onPress={add.enter} size="sm">
            {m.people_add_enter()}
          </Button>
        </Tooltip>
      </div>
      {/* A sentence whose "by email" is the link: what it does is said around it. */}
      <p className="m-0 text-sm text-tertiary">
        {m.people_start_by_email_before()}
        <Button
          className="align-baseline"
          data-testid="people-start-by-email"
          hierarchy="link-color"
          isDisabled={!workspace}
          onPress={onStartByEmail}
          size="sm"
        >
          {m.people_start_by_email_link()}
        </Button>
        {m.people_start_by_email_after()}
      </p>
      {add.dialogs}
    </div>
  );
}

/** Add: someone nearby, a new invite link to copy, an invite link someone gave. */
function AddMenu({
  disabled,
  onStartByEmail,
  workspace,
}: {
  disabled: boolean;
  /** Opens a new Task together that first asks for someone's email: no link to trade. */
  onStartByEmail: () => void;
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const { createInvite, dialogs, enter, nearby } = useAddPeople(workspace);
  return (
    <>
      <MenuTrigger>
        <Tooltip content={m.people_add()} placement="bottom">
          <AriaButton
            aria-label={m.people_add()}
            className={taskToolbarIconButtonClassName}
            isDisabled={disabled}
          >
            <PlusIcon />
          </AriaButton>
        </Tooltip>
        <MenuPopover offset={spacing.xs} placement="bottom end">
          <Menu aria-label={m.people_add()} className="min-w-64">
            {nearby.available ? (
              <MenuItem id="nearby" onAction={nearby.open}>
                {m.nearby_dialog_title()}
              </MenuItem>
            ) : null}
            <MenuItem id="link" isDisabled={!workspace} onAction={createInvite}>
              {m.people_add_link()}
            </MenuItem>
            <MenuItem id="enter" onAction={enter}>
              {m.people_add_enter()}
            </MenuItem>
            {/* Apart from adding someone: working with them now, by their email. */}
            <MenuSeparator />
            <MenuItem id="email" isDisabled={!workspace} onAction={onStartByEmail}>
              {m.people_start_by_email()}
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      {dialogs}
    </>
  );
}

/**
 * One person, on the right: who they are and how requests go between you (in plain words), a Task together with
 * them, a request when they take requests, what of theirs waits for the account (in Inbox), and the Tasks you share.
 */
function Profile({
  onTaskTogether,
  person,
  workspace,
}: {
  onTaskTogether: () => void;
  person: TaskRequestContact;
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const newTask = useNewTaskDialog();
  const name = nameOf(person);
  const avatar = useAvatarUrl(person.avatar ?? undefined);
  const sendTo = person.receives.find((target) => !target.full) ?? person.receives[0];
  return (
    // One panel color with the list beside it, as Inbox and Drive; the column is the design system's content
    // width (`--container-xl`), as a Task's messages and Apps.
    <ScrollArea
      className="min-h-0 flex-1"
      contentClassName="mx-auto flex w-full max-w-(--container-xl) flex-col gap-3xl px-xl pb-3xl pt-6xl"
      edgeEffect="mask"
      orientation="vertical"
      scrollbarVisibility="scroll"
    >
      <div
        className="flex flex-col items-center gap-lg text-center"
        data-testid="people-detail"
      >
        <UserAvatar
          {...(avatar ? { avatarUrl: avatar } : {})}
          displayName={name}
          email={person.email ?? ""}
          size="2xl"
        />
        <div className="flex flex-col gap-xxs">
          <h2 className="m-0 text-lg font-medium text-primary">{name}</h2>
          <span className="text-sm text-tertiary">
            {person.email && person.email !== name ? person.email : null}
          </span>
        </div>
        {/* Two ways to work with them, alike to look at; what each means shows on hover. */}
        <div className="flex items-center gap-sm">
          {/* The two ways side by side, one width: the wider one's. */}
          <div className="grid auto-cols-fr grid-flow-col gap-sm">
            <Tooltip content={m.people_task_together_hint({ name })} placement="bottom">
              <Button
                className="w-full justify-center"
                hierarchy="secondary-gray"
                onPress={onTaskTogether}
                size="sm"
              >
                {m.people_task_together()}
              </Button>
            </Tooltip>
            {sendTo ? (
              <Tooltip
                content={m.people_send_request_hint({ name })}
                placement="bottom"
              >
                <Button
                  className="w-full justify-center"
                  hierarchy="secondary-gray"
                  isDisabled={!newTask.available}
                  onPress={() => newTask.open(workspace, { requestTo: sendTo.grant })}
                  size="sm"
                >
                  {m.people_send_request()}
                </Button>
              </Tooltip>
            ) : null}
          </div>
          <PersonMenu name={name} person={person} workspace={workspace} />
        </div>
      </div>
      <PersonTasks key={person.id} person={person} />
    </ScrollArea>
  );
}

/**
 * A Task together being written, on the right, as a new conversation: who it is with in the middle, and where its
 * message box is, the first message, who it is with (more are added from People, as recipients to a mail), and
 * start. Started, it opens as any Task does.
 */
function StartTogether({
  byEmail,
  everyone,
  onCancel,
  onChange,
  people,
  workspace,
}: {
  /** Opened to invite someone by email: the address is asked for first. */
  byEmail: boolean;
  everyone: readonly TaskRequestContact[];
  onCancel: () => void;
  onChange: (ids: readonly string[]) => void;
  people: readonly TaskRequestContact[];
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const navigate = useNavigate();
  const [text, setText] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [key] = useState(newKey);
  // People not yet on Comma, by the address they will sign in with.
  const [emails, setEmails] = useState<readonly string[]>([]);
  const [inviting, setInviting] = useState(byEmail);
  const field = useRef<HTMLTextAreaElement>(null);
  useEffect(() => field.current?.focus(), []);
  const body = text.trim();
  const names = new Intl.ListFormat(locale, { type: "conjunction" }).format([
    ...people.map(nameOf),
    ...emails,
  ]);
  const faces = [
    ...people,
    // Someone not yet on Comma shows as an address ("@"), as a Task's seat given by email does.
    ...emails.map((email) => ({ id: email, name: "@", email, avatar: null })),
  ];
  const nobody = people.length === 0 && emails.length === 0;
  const start = () => {
    if (!workspace || body === "" || pending || nobody) return;
    setPending(true);
    setError(undefined);
    call("collaborations.start", {
      workspace,
      people: people.map((p) => p.id),
      ...(emails.length > 0 ? { emails: [...emails] } : {}),
      content: body,
      key,
    }).then(
      ({ task }) =>
        void navigate(
          openTaskTarget({
            conversationId: task.id,
            groupId: task.group_id,
            workspaceId: workspace,
          })
        ),
      (failure: unknown) => {
        setPending(false);
        setError(startFailure(failure, m));
      }
    );
  };
  return (
    <section
      aria-label={m.people_task_together()}
      className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="people-start-together"
    >
      <ContentHeader className="comma-chat-header">
        <h1 className="comma-chat-title">{m.people_task_together()}</h1>
      </ContentHeader>
      <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-md px-xl text-center">
        <AvatarStack animate people={faces} size="sm" />
        <p className="m-0 max-w-(--container-sm) text-sm text-balance text-primary">
          {m.people_together_with({ names })}
        </p>
        <p className="m-0 max-w-(--container-sm) text-xs text-balance text-tertiary">
          {m.station_task_together_note()}
        </p>
        {emails.length > 0 ? (
          <p className="m-0 max-w-(--container-sm) text-xs text-balance text-tertiary">
            {m.people_invite_email_note()}
          </p>
        ) : null}
      </div>
      <div className="comma-chat-composer-zone">
        <div className="comma-chat-composer-frame">
          {error ? (
            // What went wrong, in words, just above the box, until the person closes it or edits.
            <div
              className="mb-sm flex w-full items-center gap-xs rounded-lg bg-utility-error-50 py-xs ps-md pe-xs text-left text-xs text-error-primary"
              data-testid="people-start-error"
              role="alert"
            >
              <ExclamationTriangleIcon aria-hidden className="size-3.5 shrink-0" />
              <span className="min-w-0 flex-1">{error}</span>
              <Button
                aria-label={m.people_close()}
                className="text-error-primary"
                hierarchy="tertiary-gray"
                iconLeading={<XIcon />}
                iconOnly
                onPress={() => setError(undefined)}
                size="xs"
              />
            </div>
          ) : null}
          <div className="relative m-0 flex w-full flex-col gap-md rounded-2xl border-[0.5px] border-primary bg-popup-primary px-xl py-lg shadow-md">
            <textarea
              aria-label={m.people_compose_placeholder()}
              className="min-h-[calc(var(--text-sm--line-height)*3)] w-full resize-none border-0 bg-transparent p-0 text-sm text-primary outline-none placeholder:text-placeholder"
              onChange={(event) => {
                setText(event.target.value);
                // A change answers what went wrong: the notice goes until the next try.
                setError(undefined);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
                  event.preventDefault();
                  start();
                }
              }}
              placeholder={m.people_compose_placeholder()}
              readOnly={pending}
              ref={field}
              value={text}
            />
            <div className="flex items-center gap-sm">
              <PeoplePicker
                emails={emails}
                everyone={everyone}
                faces={faces}
                onChange={(ids) => {
                  setError(undefined);
                  // An address unchecked is taken off; the rest are People.
                  setEmails(emails.filter((email) => ids.includes(email)));
                  onChange(ids.filter((id) => !emails.includes(id)));
                }}
                people={people}
              />
              {/* Someone not yet on Comma: by the email they will sign in with. */}
              <Tooltip content={m.people_invite_email()} placement="top">
                <Button
                  aria-label={m.people_invite_email()}
                  hierarchy="tertiary-gray"
                  iconLeading={<EmailPlusIcon />}
                  iconOnly
                  onPress={() => setInviting(true)}
                  size="xs"
                />
              </Tooltip>
              <Button
                className="ml-auto"
                hierarchy="tertiary-gray"
                isDisabled={pending}
                onPress={onCancel}
                size="xs"
              >
                {m.people_cancel()}
              </Button>
              <Button
                hierarchy="primary"
                {...(pending
                  ? { iconLeading: <LoadingCircleIcon className="animate-spin" /> }
                  : {})}
                isDisabled={pending || body === "" || !workspace || nobody}
                onPress={start}
                size="xs"
              >
                {m.station_task_together_start()}
              </Button>
            </div>
          </div>
        </div>
      </div>
      {inviting ? (
        <InviteEmailDialog
          onAdd={(email) => {
            setEmails((list) => (list.includes(email) ? list : [...list, email]));
            setInviting(false);
          }}
          onClose={() => {
            setInviting(false);
            // Opened only to ask for an address, and none given: back where it was.
            if (nobody) onCancel();
          }}
        />
      ) : null}
    </section>
  );
}

/** Someone not yet on Comma, by email: they join by signing in to Comma with it. */
function InviteEmailDialog({
  onAdd,
  onClose,
}: {
  onAdd: (email: string) => void;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const [value, setValue] = useState("");
  const email = value.trim().toLowerCase();
  const valid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email);
  return (
    <Dialog
      actions={[
        { label: m.people_cancel(), hierarchy: "secondary-gray", onPress: onClose },
        {
          label: m.people_invite_email_add(),
          hierarchy: "primary",
          onPress: () => valid && onAdd(email),
          disabled: !valid,
        },
      ]}
      input={{
        "aria-label": m.people_invite_email(),
        autoFocus: true,
        onChange: (event) => setValue(event.target.value),
        placeholder: "name@example.com",
        type: "email",
        value,
        hint: m.people_invite_email_hint(),
      }}
      isOpen
      onClose={onClose}
      title={m.people_invite_email()}
      variant="input"
    />
  );
}

/** Who a Task together is with, as their faces: pressed, everyone in People to check or uncheck. */
function PeoplePicker({
  emails,
  everyone,
  faces,
  onChange,
  people,
}: {
  /** Addresses invited, listed checked: unchecking one takes it off. */
  emails: readonly string[];
  everyone: readonly TaskRequestContact[];
  /** Everyone it is with: People picked, and addresses invited. */
  faces: readonly Face[];
  onChange: (ids: readonly string[]) => void;
  people: readonly TaskRequestContact[];
}) {
  const m = useCommaMessages();
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={m.people_add_people()}
        className={({ isFocusVisible }) =>
          cx(
            "flex h-7 cursor-default items-center gap-sm rounded-full border-0 bg-transparent ps-xxs pe-sm text-sm text-secondary outline-none hover:bg-sidebar-bg-item",
            isFocusVisible && "shadow-focus-gray"
          )
        }
        data-testid="people-together-with"
      >
        <AvatarStack animate people={faces} surface="popup" />
        <span className="flex size-5 items-center justify-center rounded-full border-[0.5px] border-dashed border-primary text-tertiary">
          <PlusIcon className="size-3" />
        </span>
      </AriaButton>
      <MenuPopover offset={spacing.xs} placement="top start">
        <Menu
          aria-label={m.people_add_people()}
          className="min-w-60"
          disallowEmptySelection
          onSelectionChange={(keys) => {
            if (keys === "all") return;
            onChange([...keys].map(String));
          }}
          selectedKeys={[...people.map((p) => p.id), ...emails]}
          selectionMode="multiple"
        >
          {everyone.map((person) => (
            <MenuItem
              icon={<PickerAvatar person={person} />}
              id={person.id}
              key={person.id}
              selectionIndicator="check"
              textValue={nameOf(person)}
            >
              {nameOf(person)}
            </MenuItem>
          ))}
          {emails.map((email) => (
            <MenuItem
              icon={<UserAvatar displayName="@" email={email} size="compact" />}
              id={email}
              key={email}
              selectionIndicator="check"
              textValue={email}
            >
              {email}
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

function PickerAvatar({ person }: { person: TaskRequestContact }) {
  const url = useAvatarUrl(person.avatar ?? undefined);
  return (
    <UserAvatar
      {...(url ? { avatarUrl: url } : {})}
      displayName={nameOf(person)}
      email={person.email ?? ""}
      size="compact"
    />
  );
}

/** What else there is to do with one person: how their requests are taken, and stopping them. */
function PersonMenu({
  name,
  person,
  workspace,
}: {
  name: string;
  person: TaskRequestContact;
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const sends = person.sends;
  if (!sends || !workspace) return null;
  const change = (write: Promise<unknown>, done?: string) =>
    write.then(
      () => done && toast.success(done),
      () => toast.error(m.task_requests_failed())
    );
  return (
    <MenuTrigger>
      <Button
        aria-label={m.people_actions({ name })}
        hierarchy="tertiary-gray"
        iconLeading={<MoreHorizontalIcon />}
        iconOnly
        size="sm"
      />
      <MenuPopover placement="bottom start">
        <Menu aria-label={m.people_actions({ name })} className="min-w-56">
          <MenuItem
            id="tasks"
            onAction={() =>
              void navigate({ to: "/tasks", search: { request: `from:${person.id}` } })
            }
          >
            {m.people_their_tasks()}
          </MenuItem>
          <MenuSeparator />
          <MenuSection
            aria-label={m.people_their_requests()}
            disallowEmptySelection
            onSelectionChange={(keys) => {
              if (keys === "all") return;
              const [mode] = [...keys];
              if (mode !== "review" && mode !== "auto_accept") return;
              if (mode === sends.mode) return;
              void change(
                call("taskRequests.setMode", { workspace, grant: sends.grant, mode })
              );
            }}
            selectedKeys={[sends.mode]}
            selectionMode="single"
          >
            <Header className="mx-sm px-md pb-xs pt-sm text-xs font-medium text-quaternary">
              {m.people_their_requests()}
            </Header>
            <MenuItem id="review" selectionIndicator="check">
              {m.task_requests_mode_review()}
            </MenuItem>
            <MenuItem id="auto_accept" selectionIndicator="check">
              {m.task_requests_mode_auto()}
            </MenuItem>
          </MenuSection>
          <MenuSeparator />
          <MenuItem
            id="stop"
            onAction={() =>
              void change(
                call("taskRequests.revokeGrant", { workspace, grant: sends.grant }),
                m.people_stopped({ name })
              )
            }
            tone="destructive"
          >
            {m.people_stop({ name })}
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

/** A random key for one Task being started: started again with it (a retry), it is the same Task. */
function newKey() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
