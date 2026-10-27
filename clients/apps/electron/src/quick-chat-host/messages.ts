// What Quick Chat's helper and Main say on its stdin and stdout, one JSON object per line: the macOS QuickChatHost's
// HostWire.swift and the Windows QuickChatHost's main.rs (native/windows/QuickChatHost) speak it.

/** The interface text in Comma's language (Main's `configure`). */
export interface QuickChatStrings {
  listening: string;
  close: string;
  send: string;
  preparing: string;
  microphoneDenied: string;
  speechUnavailable: string;
  sendFailed: string;
  resume: string;
}

/** Main → helper. */
export type HostCommand =
  | {
      type: "configure";
      strings: QuickChatStrings;
      /** Windows: Comma's AppUserModelID, which the helper notifies a failed send as. */
      appUserModelId?: string;
    }
  | { type: "result"; requestId: string; ok: boolean; message?: string }
  | { type: "transcript"; clipId: string; text?: string | null }
  /** A ticket for live dictation (`dictationTicket`), or none (no `url`) when there is no live dictation. */
  | { type: "dictationTicket"; requestId: string; url?: string; ticket?: string }
  | { type: "listen" };
