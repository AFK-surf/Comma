import type {
  SessionLifecycleSnapshot,
  SessionPresenceExpectation,
  SessionProductLease,
} from "@comma/session-contract";

export type ProductInboxJsonValue =
  | boolean
  | number
  | string
  | null
  | ProductInboxJsonValue[]
  | { [key: string]: ProductInboxJsonValue };

export interface ProductInboxWorkspaceRecord {
  audience: string;
  groupId: string;
  id: string;
  name: string;
  principalId: string;
  raw: ProductInboxJsonValue;
}

export interface ProductInboxConversationRecord {
  audience: string;
  createdAt?: number | undefined;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  groupId: string;
  id: string;
  kind: "user_chat" | "agent_task";
  principalId: string;
  raw: ProductInboxJsonValue;
  status: string;
  title: string;
  updatedAt?: number | undefined;
  workspaceId: string;
}

export interface ProductInboxStoredItem {
  raw?: ProductInboxJsonValue | undefined;
  audience: string;
  conversationId: string;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  groupId: string;
  id: string;
  kind: "user_chat" | "agent_task";
  source: "salix.conversation";
  status: string;
  title: string;
  updatedAt: number;
  workspaceId: string;
  workspaceName: string;
}

export interface ProductInboxCacheApplyInput {
  audience: string;
  conversations?:
    | {
        items: ProductInboxConversationRecord[];
        mode: "merge" | "replace";
        workspaceId: string;
      }
    | undefined;
  principalId: string;
  session: SessionProductLease;
  workspaces: {
    items: ProductInboxWorkspaceRecord[];
    mode: "merge" | "replace";
  };
}

export interface ProductInboxStoragePort {
  applyProductInboxSync(input: ProductInboxCacheApplyInput): Promise<unknown>;
  health(): { status: "ready" | "degraded" | "closed" };
  listProductInboxItems(input: {
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }): Promise<ProductInboxStoredItem[]>;
  listProductWorkspaces(input: {
    audience: string;
    principalId: string;
  }): Promise<ProductInboxWorkspaceRecord[]>;
  onRecovered(listener: () => void): () => void;
}

export type ProductCredentialLease = Readonly<{
  audience: string;
  authorityInstanceId: string;
  generation: number;
  /** Host-owned HTTP transport details; omitted by bearer-token hosts. */
  request?: Readonly<{
    credentials: RequestCredentials;
    headers: Readonly<Record<string, string>>;
  }>;
  sessionId: string;
  signal: AbortSignal;
  /** Empty means the host transport uses its HttpOnly cookie. */
  token: string;
}>;

export interface ProductCredentialAuthorityPort {
  acquireProductCredential(
    expected: SessionPresenceExpectation
  ): ProductCredentialLease | null;
  getSnapshot(): SessionLifecycleSnapshot;
  isCurrentProductCredential(lease: ProductCredentialLease): boolean;
}
