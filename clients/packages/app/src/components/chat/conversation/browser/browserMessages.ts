import type { useCommaMessages } from "@comma/i18n/react";

type CommaMessages = ReturnType<typeof useCommaMessages>;

// The viewer keeps what happened, not its wording, so the panel words it in
// the reader's language whenever it renders.

/** What the viewer is doing, as the copy it shows. */
const statusCopy = {
  loading: "chat_browser_status_loading",
  connecting: "chat_connecting",
  human: "chat_browser_status_human",
  waiting: "chat_browser_status_waiting",
  agent: "chat_browser_status_agent",
  disconnected: "chat_browser_status_disconnected",
} as const satisfies Record<string, keyof CommaMessages>;

/** Why the viewer stopped or refused, as the copy it shows. */
const errorCopy = {
  tabs: "chat_browser_error_tabs",
  stream: "chat_browser_error_stream",
  control: "chat_browser_error_control",
  queueFull: "chat_browser_error_queue_full",
  input: "chat_browser_error_input",
} as const satisfies Record<string, keyof CommaMessages>;

export type BrowserStatus = keyof typeof statusCopy;
export type BrowserError = keyof typeof errorCopy;

export function browserStatusText(
  messages: CommaMessages,
  status: BrowserStatus
): string {
  return messages[statusCopy[status]]();
}

/** Why the browser's latest storage save fell short, from the server's code. */
export function browserStorageErrorText(messages: CommaMessages, code: string): string {
  return code === "browser_storage_partially_saved"
    ? messages.chat_browser_storage_partially_saved()
    : messages.chat_browser_storage_not_saved();
}

export function browserErrorText(messages: CommaMessages, error: BrowserError): string {
  return messages[errorCopy[error]]();
}
