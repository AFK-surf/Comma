import { createContext } from "react";
import type { CommaApiClient } from "../../../api";
import type { ConversationFileSource } from "../../../runtime-files/fileSources";
import type { UserAvatarProps } from "../../UserAvatar";
import type { ChatMessage } from "../model/conversationChannel";

export type ThreadFileSource = {
  api: CommaApiClient;
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
export const ThreadUserAvatarContext = createContext<ThreadUserAvatar | undefined>(
  undefined
);
// Only identity-stable reply actions travel by context. Each row gets its own
// place in the thread as props (RowRelationshipProps), so a transcript-wide
// layout rebuild re-renders only the rows whose own place changed.
export const ThreadReplyActionsContext = createContext<ThreadReplyActions | undefined>(
  undefined
);
