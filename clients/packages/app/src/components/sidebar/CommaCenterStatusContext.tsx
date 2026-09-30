import {
  createContext,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import type { ConversationChannelState } from "../chat/model/conversationChannel";
import { useHomeConversationTarget } from "../chat/ChatProvider";
import { parseAttachmentsBlock } from "../chat/model/protocol";
import { useConversation } from "../chat/conversation/useConversation";

export type CommaCenterStatus =
  | { kind: "idle" }
  | { kind: "typing"; timestamp: number | undefined }
  | {
      kind: "complete";
      messageId: string;
      text: string;
      timestamp: number | undefined;
    };

const idleCommaCenterStatus: CommaCenterStatus = { kind: "idle" };

type CommaCenterStatusPublication = {
  owner: symbol | undefined;
  status: CommaCenterStatus;
};

const idleCommaCenterStatusPublication: CommaCenterStatusPublication = {
  owner: undefined,
  status: idleCommaCenterStatus,
};

const CommaCenterStatusContext = createContext<{
  publication: CommaCenterStatusPublication;
  setPublication: Dispatch<SetStateAction<CommaCenterStatusPublication>>;
} | null>(null);

export function CommaCenterStatusProvider({ children }: { children: ReactNode }) {
  const [publication, setPublication] = useState<CommaCenterStatusPublication>(
    idleCommaCenterStatusPublication
  );
  const value = useMemo(() => ({ publication, setPublication }), [publication]);

  return (
    <CommaCenterStatusContext.Provider value={value}>
      {children}
    </CommaCenterStatusContext.Provider>
  );
}

export function useCommaCenterStatus() {
  return (
    useContext(CommaCenterStatusContext)?.publication.status ?? idleCommaCenterStatus
  );
}

export function CommaCenterStatusOwner() {
  const target = useHomeConversationTarget();

  if (!target) return null;

  return (
    <RetainedCommaCenterConversationStatus
      key={`${target.groupId}:${target.conversationId}`}
      conversationId={target.conversationId}
      groupId={target.groupId}
      workspaceId={target.workspaceId}
    />
  );
}

function RetainedCommaCenterConversationStatus({
  conversationId,
  groupId,
  workspaceId,
}: {
  conversationId: string;
  groupId: string;
  workspaceId: string;
}) {
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const owner = useRef(Symbol("comma-center-status-owner")).current;
  const status = useMemo(
    () => deriveCommaCenterStatus(conversation.state),
    [conversation.state]
  );

  usePublishCommaCenterStatus(owner, status);
  return null;
}

export function usePublishCommaCenterStatus(owner: symbol, status: CommaCenterStatus) {
  const context = useContext(CommaCenterStatusContext);
  const setPublication = context?.setPublication;

  useLayoutEffect(() => {
    setPublication?.((current) => {
      if (current.owner === owner && commaCenterStatusesEqual(current.status, status)) {
        return current;
      }
      return { owner, status };
    });
  }, [owner, setPublication, status]);

  useLayoutEffect(
    () => () => {
      setPublication?.((current) =>
        current.owner === owner ? idleCommaCenterStatusPublication : current
      );
    },
    [owner, setPublication]
  );
}

function commaCenterStatusesEqual(left: CommaCenterStatus, right: CommaCenterStatus) {
  if (left.kind !== right.kind) return false;
  if (left.kind === "idle" && right.kind === "idle") return true;
  if (left.kind === "typing" && right.kind === "typing") {
    return left.timestamp === right.timestamp;
  }
  if (left.kind === "complete" && right.kind === "complete") {
    return (
      left.messageId === right.messageId &&
      left.text === right.text &&
      left.timestamp === right.timestamp
    );
  }
  return false;
}

export function deriveCommaCenterStatus(
  state: Pick<
    ConversationChannelState,
    | "assistantDraft"
    | "awaitingReply"
    | "awaitingSince"
    | "awaitingTimedOut"
    | "messages"
    | "pending"
  >
): CommaCenterStatus {
  const activePending = state.pending.findLast(
    (pending) => pending.status !== "failed"
  );
  const awaitingLiveReply =
    state.awaitingReply &&
    !state.awaitingTimedOut &&
    state.assistantDraft === undefined;
  const streamingDraft = state.assistantDraft?.status === "streaming";

  if (activePending !== undefined || awaitingLiveReply || streamingDraft) {
    return {
      kind: "typing",
      timestamp: state.awaitingSince ?? activePending?.createdAt,
    };
  }

  for (let index = state.messages.length - 1; index >= 0; index -= 1) {
    const message = state.messages[index];
    if (message?.role !== "assistant") continue;

    const text = parseAttachmentsBlock(message.text).body.trim();
    if (!text) continue;

    return {
      kind: "complete",
      messageId: message.messageId,
      text,
      timestamp: message.createdAt,
    };
  }

  return idleCommaCenterStatus;
}
