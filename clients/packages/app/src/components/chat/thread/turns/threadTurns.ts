import type { ReactNode } from "react";
import type { CommaApiClient } from "../../../../api";
import type { ChatConversationRef } from "../../model/conversationChannel";
import type { LocalFilePreviewLoader } from "../attachments/useLocalFilePreviews";
import type { ConversationTurn } from "../layout/conversationLayout";
import type { OutgoingPresentations } from "../outgoing/useOutgoingPresentations";
import type {
  ReplyChainState,
  RowRelationshipProps,
} from "../replies/messageRelationships";
import type { ResponseFeedback } from "./ConversationTurnEntries";

/** What every row of one thread renders with: its content source and its actions. */
type ThreadRowBindings = {
  api: CommaApiClient | undefined;
  groupId: string;
  onAnchorOutgoingTurn: (turnKey: string) => void;
  onDiscard: (clientRequestId: string) => void;
  onOpenConversationRef: ((conversationRef: ChatConversationRef) => void) | undefined;
  onOutgoingAnimationComplete: (launchId: number) => void;
  onPreviewLocalFile: LocalFilePreviewLoader | undefined;
  onRetry: (clientRequestId: string) => void;
  workspaceId: string;
};

/** What both turn lists render; the variant only decides how a turn is framed. */
export type ThreadTurnsProps = {
  afterMessages: ReactNode;
  anchoredTailsFor: (turnKey: string) => ReactNode;
  conversationTurns: ConversationTurn[];
  historyBoundaryMessageId: string | undefined;
  lastTurnKey: string | undefined;
  outgoing: Pick<
    OutgoingPresentations,
    "outgoingPresentationByTurnKey" | "outgoingTurnKeys"
  >;
  /** A row's reply-chain highlight, by its message. */
  replyChainState: (messageId?: string) => ReplyChainState;
  responseFeedback: ResponseFeedback | undefined;
  /** A row's place among its neighbours, by its message or draft. */
  rowRelationshipProps: (relationshipId: string | undefined) => RowRelationshipProps;
  rows: ThreadRowBindings;
  visibleTurns: ConversationTurn[];
};
