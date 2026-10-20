import { createContext } from "react";
import type { ConversationFileSource } from "../../../runtime-files/fileSources";
import type { UserAvatarProps } from "../../UserAvatar";
import type { ChatMessage } from "@comma/core/chat";

export type ThreadFileSource = {
  groupId: string;
  conversationId: string;
  open?: ((source: ConversationFileSource) => void) | undefined;
};

type ThreadUserAvatar = Pick<UserAvatarProps, "avatarUrl" | "displayName" | "email"> & {
  currentUserAlias: boolean;
  userId?: string | undefined;
};

export type ThreadReplyActions = {
  hover: (messageId: string) => void;
  leave: (messageId: string) => void;
  reveal: (messageId: string, sourceId: string) => Promise<void>;
  canLoad: boolean;
};

export const ThreadFileSourceContext = createContext<ThreadFileSource | undefined>(
  undefined
);
export const ThreadDefaultActorRoleContext =
  createContext<ChatMessage["actorRole"]>(undefined);
/** In a Task: the maker of the model its Worker runs, whose mark stands for the Worker's messages. */
export const ThreadWorkerVendorContext = createContext<string | undefined>(undefined);
export const ThreadUserAvatarContext = createContext<ThreadUserAvatar | undefined>(
  undefined
);
// Only identity-stable reply actions travel by context. Each row gets its own
// place in the thread as props (RowRelationshipProps), so a transcript-wide
// layout rebuild re-renders only the rows whose own place changed.
export const ThreadReplyActionsContext = createContext<ThreadReplyActions | undefined>(
  undefined
);
