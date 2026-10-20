// What a person's message says, read out of the text a client wrote for the model: the text itself, the passages it
// quotes, the text and workspace files it attached, and a command it names. The page element it was sent about is
// context for the model alone. Every client shows the message from this (`ChatMessage.display`); none reads the wire
// text again.
import {
  parseAttachedTextBlocks,
  parseAttachmentsBlock,
  parseQuotedTextBlock,
  type AttachedText,
  type AttachedWorkspaceFile,
} from "./protocol.ts";

export type UserMessageDisplay = {
  /** The person's own words: what Copy copies. */
  body: string;
  quotes: string[];
  /** Text attached as a block, such as a Routine item; present when there is some. */
  texts?: AttachedText[] | undefined;
  files: AttachedWorkspaceFile[];
  /** The body is a command (`<salix-command>name</salix-command>`), shown as `/name`. */
  command?: string | undefined;
};

export const BROWSER_ELEMENT_INSPECTION_CONTEXT_PATTERN =
  /\s*<user-reminder>\s*<browser-element-inspection\s+id="([^"]+)"\s*\/>\s*<browser_element_context>([\s\S]*?)<\/browser_element_context>\s*<\/user-reminder>\s*$/u;

const COMMAND_PATTERN = /^\s*<salix-command>([^<]{0,256})<\/salix-command>\s*$/u;

/**
 * A person's message as it is shown. Its parts trail one another on the wire: the files last (an inspected element's
 * screenshot uploads after its message is written), the inspected element before them, the quotes and then the
 * attached texts leading the body.
 */
export function decodeUserMessage(text: string): UserMessageDisplay {
  const attached = parseAttachmentsBlock(text);
  // The inspected element is context for the agent; the chat shows its screenshot instead.
  const quoted = parseQuotedTextBlock(
    BROWSER_ELEMENT_INSPECTION_CONTEXT_PATTERN.test(attached.body)
      ? stripBrowserElementInspectionContext(attached.body)
      : attached.body
  );
  const texts = parseAttachedTextBlocks(quoted.body);
  const command = COMMAND_PATTERN.exec(texts.body)?.[1]?.trim();
  return {
    body: texts.body,
    quotes: quoted.quotes,
    ...(texts.texts.length > 0 ? { texts: texts.texts } : {}),
    files: attached.attachments,
    ...(command ? { command } : {}),
  };
}

export function stripBrowserElementInspectionContext(message: string) {
  return message.replace(BROWSER_ELEMENT_INSPECTION_CONTEXT_PATTERN, "").trimEnd();
}
