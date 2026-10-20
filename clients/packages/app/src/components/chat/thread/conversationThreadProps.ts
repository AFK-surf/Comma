import type { ScrollEdgeMask } from "@comma/ui/components/scroll-area";
import type { ReactNode } from "react";
import type { CommaConversationKind } from "@comma/core/api-schemas";
import type { ConversationFileSource } from "../../../runtime-files/fileSources";
import type {
  ChatAssistantDraft,
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "@comma/core/chat";
import type { RevealMessageHandle, RevealTurnHandle } from "./navigation/useTurnReveal";
import type { ReplyThreadSelection } from "./replies/replyThread";
import type { ChatOutgoingLaunch } from "./outgoing/outgoingPresentation";
import type { ResponseFeedback } from "./turns/ConversationTurnEntries";
import type { AnchoredTail } from "./turns/useAnchoredTails";

export type ConversationThreadProps = {
  /**
   * The thread shows the core's live data: replies load the messages they quote, attachments read their bytes, and
   * inline Tasks and widgets read theirs. A static thread (a preview, a share) shows only what it was given.
   */
  live?: boolean | undefined;
  assistantDraft?: ChatAssistantDraft | undefined;
  assistantResponseSlotId?: string | undefined;
  afterMessages?: ReactNode;
  /**
   * Nodes that belong to published replies instead of to the newest turn. Each
   * renders after its own reply, and the mount window reaches back to keep that
   * reply mounted, so they scroll away with the history.
   */
  anchoredTails?: readonly AnchoredTail[] | undefined;
  /** The current turn owns both reply presence and feedback placement. */
  responseFeedback?: ResponseFeedback | undefined;
  /** Absent until the conversation resolves; attachments cannot be addressed without it. */
  conversationId?: string | undefined;
  conversationKind?: CommaConversationKind;
  contentMode?: "display-only" | "interactive";
  defaultAssistantActorRole?: ChatMessage["actorRole"];
  freezeContentInlineSizeOnWindowResize?: boolean;
  groupId: string;
  messages: ChatMessage[];
  onDiscard: (clientRequestId: string) => void;
  /**
   * Opens a file card where no chat sidebar hosts the file preview, such as
   * the public Task Share page.
   */
  onOpenAttachment?: ((source: ConversationFileSource) => void) | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onOutgoingAnimationComplete?: ((launchId: number) => void) | undefined;
  onPreviewLocalFile?:
    | ((
        previewRef: ChatImagePreviewRef,
        signal?: AbortSignal
      ) => Promise<LocalFilePreview | undefined>)
    | undefined;
  onRetry: (clientRequestId: string) => void;
  /** Closes the open reply thread; the thread asks when its dimmed space is clicked. */
  onExitReplyThread?: (() => void) | undefined;
  outgoingLaunches?: readonly ChatOutgoingLaunch[] | undefined;
  /**
   * Receives the imperative "reveal this turn" entry point. A stable ref
   * object rather than a callback prop so the owner can hand it to UI outside
   * this memoized thread without breaking the memo boundary.
   */
  revealTurnHandle?: RevealTurnHandle | undefined;
  /**
   * Receives "reveal this message" for UI outside the thread, such as a Task's
   * Activity: a message not loaded yet is read first. A ref object, like
   * `revealTurnHandle`.
   */
  revealMessageHandle?: RevealMessageHandle | undefined;
  /** The thread gathered above the composer for a reply, if one is open. */
  replyThread?: ReplyThreadSelection | undefined;
  scrollAreaEdgeMask?: ScrollEdgeMask;
  showMessageActions?: boolean;
  workspaceId: string;
};
