import { useCommaMessages } from "@comma/i18n/react";
import type { ReactNode } from "react";
import { Button } from "../Button";
import { Dialog } from "../dialog";
import { CircleInfoIcon, PauseIcon, WindowAppIcon } from "../icons";

type Messages = ReturnType<typeof useCommaMessages>;

/** What a viewer reads for a capability: "Allow … to use {label}?". */
export function miniAppCapabilityLabel(messages: Messages, capability: string): string {
  switch (capability) {
    case "identity.basic":
      return messages.mini_app_capability_identity_basic();
    case "ai.chat":
      return messages.mini_app_capability_ai_chat();
    case "web.search":
      return messages.mini_app_capability_web_search();
    case "chat.draft":
      return messages.mini_app_capability_chat_draft();
    case "tasks.create":
      return messages.mini_app_capability_tasks_create();
    case "files.pick":
      return messages.mini_app_capability_files_pick();
    case "drive.app_folder":
      return messages.mini_app_capability_drive_app_folder();
    case "calendar.read":
      return messages.mini_app_capability_calendar_read();
    case "notifications":
      return messages.mini_app_capability_notifications();
    case "clipboard.write":
      return messages.mini_app_capability_clipboard_write();
    case "links.open":
      return messages.mini_app_capability_links_open();
    default:
      return capability;
  }
}

export type MiniAppGrantSheetProps = {
  appName: string;
  /** The capability the app asks for now. */
  capability: string;
  /** Every capability the app's manifest asks for, so the viewer sees the whole request. */
  capabilities: readonly string[];
  /** Hosts the app's backend may send data to: granted data can leave through them. */
  egress: readonly string[];
  onAllow: () => void;
  onDeny: () => void;
};

/** Host UI for a Once grant: what the app asks for and where its backend can send data. */
export function MiniAppGrantSheet({
  appName,
  capability,
  capabilities,
  egress,
  onAllow,
  onDeny,
}: MiniAppGrantSheetProps) {
  const messages = useCommaMessages();
  return (
    <Dialog
      actions={[
        {
          label: messages.mini_app_grant_deny(),
          hierarchy: "secondary-gray",
          onPress: onDeny,
        },
        {
          label: messages.mini_app_grant_allow(),
          hierarchy: "primary",
          onPress: onAllow,
        },
      ]}
      description={messages.mini_app_grant_description()}
      isOpen
      onOpenChange={(open) => {
        if (!open) onDeny();
      }}
      title={messages.mini_app_grant_title({
        name: appName,
        capability: miniAppCapabilityLabel(messages, capability),
      })}
    >
      <div className="flex w-full flex-col gap-md" data-testid="mini-app-grant-sheet">
        {capabilities.length > 0 ? (
          <div className="flex flex-col gap-xs">
            <p className="text-sm text-secondary">
              {messages.mini_app_grant_requested()}
            </p>
            <ul className="flex flex-col gap-xxs text-sm text-primary">
              {capabilities.map((cap) => (
                <li
                  className={cap === capability ? "font-semibold" : undefined}
                  data-capability={cap}
                  key={cap}
                >
                  {miniAppCapabilityLabel(messages, cap)}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        {egress.length > 0 ? (
          <div
            className="flex items-start gap-sm rounded-lg bg-tertiary px-md py-sm"
            data-testid="mini-app-grant-egress"
          >
            <CircleInfoIcon className="mt-xxs size-4 shrink-0 text-fg-quaternary" />
            <p className="min-w-0 text-sm text-secondary">
              {messages.mini_app_grant_egress({ hosts: egress.join(", ") })}
            </p>
          </div>
        ) : null}
      </div>
    </Dialog>
  );
}

export type MiniAppConfirmSheetProps = {
  title: string;
  description?: string | undefined;
  /** What the app proposes, shown as it will be used (a Task's text, a URL). */
  detail?: ReactNode;
  confirmLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
};

/** Host UI for an Each time effect: the viewer's click here is what lets it happen. */
export function MiniAppConfirmSheet({
  title,
  description,
  detail,
  confirmLabel,
  onConfirm,
  onCancel,
}: MiniAppConfirmSheetProps) {
  const messages = useCommaMessages();
  return (
    <Dialog
      actions={[
        {
          label: messages.mini_app_cancel(),
          hierarchy: "secondary-gray",
          onPress: onCancel,
        },
        { label: confirmLabel, hierarchy: "primary", onPress: onConfirm },
      ]}
      {...(description ? { description } : {})}
      isOpen
      onOpenChange={(open) => {
        if (!open) onCancel();
      }}
      title={title}
    >
      {detail ? (
        <div
          className="max-h-60 w-full overflow-auto rounded-lg bg-tertiary px-md py-sm text-sm break-words whitespace-pre-wrap text-secondary"
          data-testid="mini-app-confirm-detail"
        >
          {detail}
        </div>
      ) : null}
    </Dialog>
  );
}

export type MiniAppNoticeProps = {
  kind: "paused" | "failed" | "stalled" | "stopped" | "disabled" | "unavailable";
  /** Why it failed, when the host knows. */
  reason?: string | undefined;
  onRetry?: (() => void) | undefined;
};

/** What the frame's place shows when the app does not run: paused, failed, stalled, or closed for another. */
export function MiniAppNotice({ kind, reason, onRetry }: MiniAppNoticeProps) {
  const messages = useCommaMessages();
  const title = {
    paused: messages.mini_app_paused_title(),
    failed: messages.mini_app_failed_title(),
    stalled: messages.mini_app_stalled_title(),
    stopped: messages.mini_app_stopped_title(),
    disabled: messages.mini_app_disabled_title(),
    unavailable: messages.mini_app_unavailable_title(),
  }[kind];
  const detail = kind === "paused" ? messages.mini_app_paused_description() : reason;
  return (
    <output
      className="flex flex-1 flex-col items-center justify-center gap-sm px-xl py-3xl text-center"
      data-testid={`mini-app-notice-${kind}`}
    >
      {kind === "paused" ? (
        <PauseIcon className="size-5 text-fg-quaternary" />
      ) : (
        <CircleInfoIcon className="size-5 text-fg-quaternary" />
      )}
      <p className="text-sm font-semibold text-primary">{title}</p>
      {detail ? (
        <p className="max-w-(--container-xs) text-sm text-tertiary">{detail}</p>
      ) : null}
      {onRetry ? (
        <Button hierarchy="secondary-gray" onPress={onRetry} size="sm">
          {kind === "stopped" ? messages.mini_app_resume() : messages.mini_app_reload()}
        </Button>
      ) : null}
    </output>
  );
}

export type MiniAppInWindowNoticeProps = {
  onShowWindow: () => void;
  onMoveBack: () => void;
};

/** What a panel shows in its app's place while the app runs in a window of its own. */
export function MiniAppInWindowNotice({
  onShowWindow,
  onMoveBack,
}: MiniAppInWindowNoticeProps) {
  const messages = useCommaMessages();
  return (
    <output
      className="flex flex-1 flex-col items-center justify-center gap-sm px-xl py-3xl text-center"
      data-testid="mini-app-notice-in-window"
    >
      <WindowAppIcon className="size-5 text-fg-quaternary" />
      <p className="text-sm font-semibold text-primary">
        {messages.mini_app_in_window_title()}
      </p>
      <p className="max-w-(--container-xs) text-sm text-tertiary">
        {messages.mini_app_in_window_description()}
      </p>
      <div className="flex flex-wrap justify-center gap-sm">
        <Button hierarchy="secondary-gray" onPress={onShowWindow} size="sm">
          {messages.mini_app_show_window()}
        </Button>
        <Button hierarchy="tertiary-gray" onPress={onMoveBack} size="sm">
          {messages.mini_app_move_back()}
        </Button>
      </div>
    </output>
  );
}
