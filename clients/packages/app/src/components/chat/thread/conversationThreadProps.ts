import type { ScrollEdgeMask } from "@comma/ui";
import type { ReactNode } from "react";
import type { CommaApiClient, CommaConversationKind } from "../../../api";
import type { ConversationFileSource } from "../../../runtime-files/fileSources";
import type {
  ChatAssistantDraft,
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../model/conversationChannel";
import type { RevealTurnHandle } from "./navigation/useTurnReveal";
import type { ChatOutgoingLaunch } from "./outgoing/outgoingPresentation";
import type { ResponseFeedback } from "./turns/ConversationTurnEntries";
import type { AnchoredTail } from "./turns/useAnchoredTails";

export type ConversationThreadProps = {
  api?: CommaApiClient | undefined;
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
  outgoingLaunches?: readonly ChatOutgoingLaunch[] | undefined;
  /**
   * Receives the imperative "reveal this turn" entry point. A stable ref
   * object rather than a callback prop so the owner can hand it to UI outside
   * this memoized thread without breaking the memo boundary.
   */
  revealTurnHandle?: RevealTurnHandle | undefined;
  scrollAreaEdgeMask?: ScrollEdgeMask;
  showMessageActions?: boolean;
  variant?: "default" | "side-chat";
  workspaceId: string;
};
