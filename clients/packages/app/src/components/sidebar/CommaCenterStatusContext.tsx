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
import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";
import { useHomeConversationTarget } from "../chat/ChatProvider";
import { parseAttachmentsBlock } from "@comma/core/chat";
import { useConversation } from "../chat/conversation/useConversation";
import { useWindowAttended } from "../useWindowAttended";

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
  // Undefined until canonical history is ready; null means no Router reply yet.
  latestReplyId?: string | null;
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

/** One view-local attention mark, fed by the already-retained Home conversation. */
export function useHomeTabUnread(homeVisible: boolean) {
  const publication =
    useContext(CommaCenterStatusContext)?.publication ??
    idleCommaCenterStatusPublication;
  const attended = useWindowAttended();
  const viewing = homeVisible && attended;
  const [observed, setObserved] = useState({
    owner: publication.owner,
    replyId: publication.latestReplyId,
    unread: false,
  });

  if (observed.owner !== publication.owner) {
    setObserved({
      owner: publication.owner,
      replyId: publication.latestReplyId,
      unread: false,
    });
    return false;
  }
  const replyId = publication.latestReplyId;
  if (replyId !== undefined && replyId !== observed.replyId) {
    // The first ready snapshot establishes history, including an empty history.
    // Later committed replies count even while another reply is streaming.
    const unread =
      !viewing &&
      (observed.unread || (observed.replyId !== undefined && replyId !== null));
    setObserved({ ...observed, replyId, unread });
    return unread;
  }
  if (viewing && observed.unread) {
    setObserved({ ...observed, unread: false });
    return false;
  }
  return observed.unread;
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
  const ready = conversation.state.status === "ready";
  const serverMessages = conversation.state.serverMessages;
  const [replyMark, setReplyMark] = useState<RouterReplyMark | undefined>(undefined);
  let currentMark = replyMark;
  if (ready) {
    const nextMark = advanceRouterReplyMark(replyMark, serverMessages);
    if (nextMark !== replyMark) {
      setReplyMark(nextMark);
      currentMark = nextMark;
    }
  }
  const latestReplyId = ready ? currentMark?.published : undefined;

  usePublishCommaCenterStatus(owner, status, latestReplyId);
  return null;
}

/**
 * The Router reply the Home badge counts from. `published` only moves forward
 * to a reply committed after the last one seen, so a deleted or retracted
 * latest reply never reads as a new one; `seen` is the latest reply in the
 * current history, the anchor the next reply is ordered against.
 */
export type RouterReplyMark = { published: string | null; seen: string | null };

export function advanceRouterReplyMark(
  mark: RouterReplyMark | undefined,
  serverMessages: readonly ChatMessage[]
): RouterReplyMark {
  const latestIndex = serverMessages.findLastIndex(isRouterReply);
  const latest = latestIndex === -1 ? null : serverMessages[latestIndex]!.messageId;
  if (!mark) return { published: latest, seen: latest };
  if (latest === mark.seen) return mark;
  const seenIndex =
    mark.seen === null
      ? -1
      : serverMessages.findIndex((message) => message.messageId === mark.seen);
  const after =
    latest !== null &&
    (mark.seen === null || (seenIndex !== -1 && seenIndex < latestIndex));
  return after ? { published: latest, seen: latest } : { ...mark, seen: latest };
}

function isRouterReply(message: ChatMessage) {
  return (
    message.role === "assistant" &&
    !message.platformSource &&
    (message.actorRole === undefined || message.actorRole === "router") &&
    (message.text.trim() !== "" ||
      message.attachments.length > 0 ||
      (message.parts?.some(
        (part) => part.kind !== "markdown" || part.text.trim() !== ""
      ) ??
        false))
  );
}

export function usePublishCommaCenterStatus(
  owner: symbol,
  status: CommaCenterStatus,
  latestReplyId?: string | null
) {
  const context = useContext(CommaCenterStatusContext);
  const setPublication = context?.setPublication;

  useLayoutEffect(() => {
    setPublication?.((current) => {
      if (
        current.owner === owner &&
        current.latestReplyId === latestReplyId &&
        commaCenterStatusesEqual(current.status, status)
      ) {
        return current;
      }
      return {
        owner,
        status,
        ...(latestReplyId !== undefined ? { latestReplyId } : {}),
      };
    });
  }, [owner, setPublication, status, latestReplyId]);

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
    "awaitingSince" | "messages" | "pending" | "reply"
  >
): CommaCenterStatus {
  const activePending = state.pending.findLast(
    (pending) => pending.status !== "failed"
  );

  if (state.reply?.coming) {
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
