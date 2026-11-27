import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { AiInput } from "@comma/ui/components/ai-input";
import { Button } from "@comma/ui/components/Button";
import { ContentHeader } from "@comma/ui/components/content-header";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import { cx } from "@comma/ui/components/utils";
import type { ChatAttachment, ChatMessage } from "@comma/core/chat";
import { useCallback, useMemo, useRef, useState, type ChangeEvent } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
} from "react-aria-components";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { ShellIconButton } from "../ShellIconButton";
import { UserAvatar } from "../UserAvatar";
import { formatAttachmentSize } from "../chat/thread/attachments/attachmentLabels";
import { ConversationThread } from "../chat/thread/ConversationThread";
import { ChatSuggestionChips } from "../chat/suggestions/ChatSuggestionChips";
import { RouterDisplayNameProvider } from "../router-identity/RouterIdentityProvider";
import {
  InlineTaskLinkAdapterProvider,
  passiveInlineTaskLinkAdapter,
} from "../chat/thread/inline/MessageInlineElements";
import { useTaskPanelFold, useTaskPanelOpen } from "../chat/tasks/TaskPanelFold";
import {
  CollabGuestError,
  MAX_GUEST_FILE_BYTES,
  type CollabGuestClient,
  type CollabGuestFilesData,
  type CollabGuestMember,
  type CollabGuestMessage,
  type CollabGuestTaskData,
} from "./collabGuestApi";

// The thread addresses the conversation it renders; a guest's page has only its link.
const GUEST_SCOPE = "collab-guest";
const MENTION_COMMA = /(^|\s)@comma\b/i;
const noop = () => {};

/** Saves the file at `href` under `name`, as a link with `download` would. */
function download(href: string, name: string) {
  const link = document.createElement("a");
  link.href = href;
  link.download = name;
  link.rel = "noreferrer";
  link.click();
}

function fileBasename(path: string): string {
  const parts = path.split("/");
  return parts[parts.length - 1] || path;
}

function memberDisplayName(
  member: CollabGuestMember,
  messages: ReturnType<typeof useCommaMessages>
): string {
  if (member.name && member.name.trim()) return member.name.trim();
  if (member.status === "invited") {
    return messages.collab_guest_member_placeholder_invited();
  }
  return messages.collab_guest_member_placeholder_guest();
}

function createdAtSeconds(value: CollabGuestMessage["createdAt"]): number | undefined {
  if (typeof value === "number") return value;
  if (typeof value !== "string") return undefined;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : Math.floor(parsed / 1000);
}

/**
 * A guest's message as the app's thread draws one: the guest's own on the right, everyone else's on the left under
 * their name, and Comma's as the Router's reply. A Mini App is a link in the reply (opening it asks the guest to sign
 * in); a file opens from the Task's folder.
 */
function toChatMessage(
  message: CollabGuestMessage,
  messages: ReturnType<typeof useCommaMessages>,
  appHref: (appId: string, version: number | undefined) => string
): ChatMessage {
  const assistant = message.role === "assistant";
  const apps = message.miniApps.map(
    (app) =>
      `**[${app.name}](${appHref(app.appId, app.version)})**${app.summary ? `\n${app.summary}` : ""}\n_${messages.collab_guest_mini_app_open_hint()}_`
  );
  const text = [message.text, ...apps].filter(Boolean).join("\n\n");
  const attachments: ChatAttachment[] = message.attachments.map(
    (attachment, index) => ({
      attachmentIndex: index,
      blockType: "file",
      fileName: attachment.fileName,
      mimeType: attachment.mimeType ?? "application/octet-stream",
      ...(attachment.size === undefined ? {} : { size: attachment.size }),
    })
  );
  const createdAt = createdAtSeconds(message.createdAt);
  const name = message.senderName;
  return {
    ...(assistant ? { actorId: GUEST_SCOPE, actorRole: "router" as const } : {}),
    // Someone else: named by the name the server gave, and marked a guest where they came by an emailed link.
    ...(!assistant && !message.isSelf
      ? {
          // An unnamed guest reads Anonymous: no name to add the Guest tag to.
          ...(name ? { authorName: name } : {}),
          createdBy: `${message.isGuestSender ? "guest" : "member"}:${name ?? message.id}`,
        }
      : {}),
    attachments,
    ...(createdAt === undefined ? {} : { createdAt }),
    delivery: "sent",
    messageId: message.id,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role: assistant ? "assistant" : "user",
    source: "server",
    status: "committed",
    text,
  };
}

export function CollabGuestWorkspace({
  client,
  sessionToken,
  taskData,
  messagesList,
  filesData,
  onSendMessage,
  onUploadFile,
  onLeave,
  sending,
  uploading,
  uploadError,
  onClearUploadError,
}: {
  client: CollabGuestClient;
  sessionToken: string;
  taskData: CollabGuestTaskData;
  messagesList: CollabGuestMessage[];
  filesData: CollabGuestFilesData;
  onSendMessage: (text: string, mentionComma: boolean) => Promise<void>;
  onUploadFile: (file: File) => Promise<void>;
  /** Asks to leave the Task (the page confirms it first). */
  onLeave: () => void;
  sending: boolean;
  uploading: boolean;
  uploadError: string | null;
  onClearUploadError: () => void;
}) {
  const messages = useCommaMessages();
  const [draft, setDraft] = useState("");
  const [sendError, setSendError] = useState<string | null>(null);
  const [clientFileError, setClientFileError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const routeRef = useRef<HTMLElement | null>(null);
  const fold = useTaskPanelFold(routeRef, true);
  const panelOpen = useTaskPanelOpen(fold);
  const { task } = taskData;

  const appHref = useCallback(
    (appId: string, version: number | undefined) =>
      `/#/collaborations/${encodeURIComponent(task.group_id)}/${encodeURIComponent(task.conversation_id)}/apps/${encodeURIComponent(appId)}${version ? `?version=${version}` : ""}`,
    [task.conversation_id, task.group_id]
  );
  const chatMessages = useMemo(
    () =>
      messagesList
        // A system line (who joined or left) is the People list's to tell.
        .filter((message) => message.role !== "system")
        .map((message) => toChatMessage(message, messages, appHref)),
    [appHref, messages, messagesList]
  );

  const openAttachment = useCallback(
    (source: ConversationFileSource) => {
      const message = messagesList.find((entry) => entry.id === source.messageId);
      const attachment = message?.attachments[source.attachmentIndex];
      if (attachment?.path) {
        download(
          client.downloadFileUrl(sessionToken, attachment.path),
          attachment.fileName
        );
      }
    },
    [client, messagesList, sessionToken]
  );

  // Comma answers a guest only when named: the guest's own newest line that did not name it gets one chip that does,
  // as in the app. Not while Comma is replying, nor once the host closed the Task.
  const lastMessage = messagesList
    .filter((message) => message.role !== "system")
    .at(-1);
  const closed = task.status === "completed" || task.status === "cancelled";
  const askComma =
    !closed &&
    !sending &&
    lastMessage?.isSelf === true &&
    lastMessage.role === "user" &&
    !MENTION_COMMA.test(lastMessage.text)
      ? { id: "ask-comma", label: messages.people_ask_comma(), prompt: "@Comma" }
      : undefined;
  const askCommaNow = () => {
    setSendError(null);
    onSendMessage("@Comma", true).catch((error: unknown) => {
      if (error instanceof CollabGuestError && error.code === "guest_session_revoked")
        return;
      setSendError(messages.collab_guest_otp_error_generic());
    });
  };

  const submit = async (value: string) => {
    const trimmed = value.trim();
    if (!trimmed || sending) return;
    setSendError(null);
    try {
      await onSendMessage(trimmed, MENTION_COMMA.test(trimmed));
      setDraft("");
    } catch (error) {
      if (error instanceof CollabGuestError && error.code === "guest_session_revoked") {
        return;
      }
      setSendError(messages.collab_guest_otp_error_generic());
    }
  };

  const handleFileChange = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    setClientFileError(null);
    onClearUploadError();
    if (file.size > MAX_GUEST_FILE_BYTES) {
      setClientFileError(messages.collab_guest_files_error_too_large());
      return;
    }
    await onUploadFile(file);
  };

  const details = (
    <>
      <GuestMembers members={task.members} onLeave={onLeave} />
      <GuestFiles client={client} filesData={filesData} sessionToken={sessionToken} />
    </>
  );

  return (
    <section
      aria-label={task.title}
      className="comma-chat-route comma-collab-guest flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="collab-guest-workspace"
      data-variant="route"
      ref={routeRef}
    >
      <input
        className="hidden"
        onChange={(event) => void handleFileChange(event)}
        ref={fileInputRef}
        type="file"
      />
      <ContentHeader className="comma-chat-header">
        <div
          className="flex min-w-0 flex-1 items-center gap-sm"
          data-task-header="true"
        >
          <h1 className="comma-chat-title">{task.title}</h1>
          <span className="hidden min-w-0 shrink truncate text-xs text-tertiary @min-[640px]/comma-window:inline">
            · {messages.collab_guest_hosted_by({ host: task.host_name })}
          </span>
        </div>
        {/* A narrow page folds the details behind the header's trigger, as a Task's route does. */}
        {panelOpen ? null : (
          <DialogTrigger>
            <ShellIconButton
              className="comma-task-panel-toggle"
              icon="list-bullets"
              label={messages.task_panel_toggle()}
              testId="collab-guest-details-toggle"
            />
            <MenuPopover
              className={`${menuSurfaceClasses} comma-task-panel-popover`}
              placement="bottom end"
            >
              <AriaDialog
                aria-label={messages.task_panel_region()}
                className="w-(--container-xxs) max-w-[calc(100vw-2*var(--spacing-xl))] outline-none"
              >
                <div className="comma-task-panel" data-layout="popover">
                  <div className="comma-task-panel-inner">{details}</div>
                </div>
              </AriaDialog>
            </MenuPopover>
          </DialogTrigger>
        )}
      </ContentHeader>
      <div className="comma-chat-body" data-panel-open={panelOpen ? "true" : "false"}>
        <div className="comma-chat-main" data-testid="collab-guest-thread">
          {/* Comma's replies wear its name, as the guest asks it by: "@Comma". */}
          <RouterDisplayNameProvider value="Comma">
            <InlineTaskLinkAdapterProvider adapter={passiveInlineTaskLinkAdapter}>
              <ConversationThread
                afterMessages={
                  chatMessages.length === 0 ? (
                    <p className="text-sm text-tertiary">
                      {messages.collab_guest_messages_empty()}
                    </p>
                  ) : askComma ? (
                    <ChatSuggestionChips
                      align="end"
                      items={[askComma]}
                      onSelect={askCommaNow}
                    />
                  ) : null
                }
                conversationId={GUEST_SCOPE}
                conversationKind="agent_task"
                defaultAssistantActorRole="worker"
                groupId={GUEST_SCOPE}
                messages={chatMessages}
                onDiscard={noop}
                onOpenAttachment={openAttachment}
                onRetry={noop}
                showMessageActions={false}
                workspaceId={GUEST_SCOPE}
              />
            </InlineTaskLinkAdapterProvider>
          </RouterDisplayNameProvider>
          <div className="comma-chat-composer-zone">
            <div className="comma-chat-composer-frame">
              {sendError ? (
                <p className="mb-xs px-md text-xs text-error-primary" role="alert">
                  {sendError}
                </p>
              ) : null}
              {/* A file is added from the composer's +, as in the app: what became of it shows here. */}
              {(clientFileError ?? uploadError) ? (
                <p
                  className="mb-xs px-md text-xs text-error-primary"
                  data-testid="collab-guest-file-error"
                  role="alert"
                >
                  {clientFileError ?? uploadError}
                </p>
              ) : uploading ? (
                <output className="mb-xs block px-md text-xs text-tertiary">
                  {messages.collab_guest_files_uploading()}
                </output>
              ) : null}
              {/* The app's Task composer: its shell and its one-row size. */}
              <div className="comma-chat-composer-shell">
                <AiInput
                  attachLabel={messages.collab_guest_composer_attach()}
                  className="comma-chat-composer"
                  data-testid="collab-guest-composer-input"
                  onAttachPress={() => fileInputRef.current?.click()}
                  onSubmit={(value) => void submit(value)}
                  onValueChange={setDraft}
                  placeholder={
                    // Closed by its host, the Task no longer wakes Comma for a guest: it says so, as for a member.
                    task.status === "cancelled"
                      ? messages.people_composer_cancelled_member()
                      : task.status === "completed"
                        ? messages.people_composer_done_member()
                        : messages.people_composer_together()
                  }
                  sendLabel={messages.chat_send_message()}
                  showAttachButton
                  showVoiceButton={false}
                  size="small"
                  submitDisabled={sending || !draft.trim()}
                  submitPending={sending}
                  value={draft}
                />
              </div>
            </div>
          </div>
        </div>
        <aside
          aria-hidden={!panelOpen}
          aria-label={messages.task_panel_region()}
          className="comma-task-panel"
          data-open={panelOpen ? "true" : "false"}
        >
          <div className="comma-task-panel-inner">{panelOpen ? details : null}</div>
        </aside>
      </div>
    </section>
  );
}

/** The Task's people as a Task's member list shows them: face, name, and a word for the host, the guest and them. */
function GuestMembers({
  members,
  onLeave,
}: {
  members: CollabGuestMember[];
  onLeave: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <section
      className="comma-task-panel-section"
      data-testid="collab-guest-members-panel"
    >
      <h2 className="comma-task-panel-heading">{messages.people_members()}</h2>
      <ul className="m-0 flex list-none flex-col gap-sm p-0">
        {members.map((member, index) => {
          const display = memberDisplayName(member, messages);
          const named = Boolean(member.name?.trim());
          // A word only where the name does not already say it: an unnamed guest reads Anonymous, with no Guest tag.
          const tag =
            member.role === "host"
              ? messages.people_member_host()
              : member.is_self
                ? messages.people_member_you_tag()
                : member.status === "invited"
                  ? named
                    ? messages.collab_guest_member_status_invited()
                    : null
                  : member.is_guest && named
                    ? messages.people_member_guest_tag()
                    : null;
          return (
            <li
              className={cx(
                "flex min-w-0 items-center gap-sm",
                // Who has not joined yet sits back, as in the app's list.
                member.status === "invited" && "opacity-50"
              )}
              key={`${member.role}-${member.name ?? "anon"}-${index}`}
            >
              <UserAvatar displayName={named ? display : "@"} email="" size="xs" />
              <span className="min-w-0 flex-1 truncate text-sm text-primary">
                {display}
              </span>
              {tag ? (
                <span className="shrink-0 text-xs text-tertiary">{tag}</span>
              ) : null}
              {/* The guest leaves from their own row, as a member does in the app. */}
              {member.is_self ? (
                <MenuTrigger>
                  <Button
                    aria-label={messages.people_actions({ name: display })}
                    hierarchy="tertiary-gray"
                    iconLeading={<MoreHorizontalIcon />}
                    iconOnly
                    size="xs"
                  />
                  <MenuPopover placement="bottom end">
                    <Menu aria-label={messages.people_actions({ name: display })}>
                      <MenuItem id="leave" onAction={onLeave} tone="destructive">
                        {messages.people_member_leave()}
                      </MenuItem>
                    </Menu>
                  </MenuPopover>
                </MenuTrigger>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** The Task's folder as a Task panel's Files list shows it. */
function GuestFiles({
  client,
  filesData,
  sessionToken,
}: {
  client: CollabGuestClient;
  filesData: CollabGuestFilesData;
  sessionToken: string;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  return (
    <section
      className="comma-task-panel-section"
      data-testid="collab-guest-files-panel"
    >
      <h2 className="comma-task-panel-heading">{messages.task_panel_files()}</h2>
      {filesData.entries.length > 0 ? (
        <ul className="flex flex-col gap-xs">
          {filesData.entries.map((entry) => {
            const name = fileBasename(entry.path);
            const size = formatAttachmentSize(entry.size, locale);
            return (
              <li key={entry.path}>
                <AriaButton
                  aria-label={`${messages.collab_guest_files_download()} ${name}`}
                  className="comma-task-panel-pill max-w-full min-w-0"
                  data-interactive="true"
                  data-testid="collab-guest-file"
                  onPress={() =>
                    download(client.downloadFileUrl(sessionToken, entry.path), name)
                  }
                >
                  <FileTypeIcon
                    className="size-5"
                    fileName={name}
                    mimeType={entry.content_type}
                  />
                  <span className="truncate" title={name}>
                    {name}
                  </span>
                  {size ? (
                    <span className="shrink-0 font-normal text-quaternary">{size}</span>
                  ) : null}
                </AriaButton>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="comma-task-panel-muted">{messages.collab_guest_files_empty()}</p>
      )}
    </section>
  );
}
