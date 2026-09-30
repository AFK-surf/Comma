import type { CommaLocale } from "@comma/i18n";
import type { ChannelLease } from "../ChannelLease";
import type { DraftCommands } from "../DraftCommands";
import type { NativeAttachments } from "./NativeAttachments";

/** The channel services the draft attachment collaborators share. */
export type AttachmentChannel = {
  commands: DraftCommands;
  lease: ChannelLease;
  locale: CommaLocale;
  native: NativeAttachments;
  /** A renderer-local attachment id, unique across uploads and pick failures. */
  nextLocalId(prefix: "renderer-attachment" | "renderer-intake-failure"): string;
  /** Republishes the draft attachments into the channel state. */
  publish(): void;
  surfaceId: string;
};
