import {
  sameSessionProductLease,
  sessionProductLeaseSchema,
  type SessionProductLease,
} from "@comma/session-contract";

export const LOCAL_DATA_SCHEMA_VERSION = 10;

export type LocalDataJsonValue =
  | boolean
  | number
  | string
  | null
  | LocalDataJsonValue[]
  | { [key: string]: LocalDataJsonValue };

export type ProductConversationKind = "user_chat" | "agent_task";

export interface LocalDataProductWorkspaceInput {
  audience: string;
  groupId: string;
  id: string;
  name: string;
  principalId: string;
  raw: LocalDataJsonValue;
}

export interface LocalDataProductConversationInput {
  audience: string;
  groupId: string;
  id: string;
  principalId: string;
  workspaceId: string;
  title: string;
  status: string;
  kind: ProductConversationKind;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  raw: LocalDataJsonValue;
  createdAt?: number | undefined;
  updatedAt?: number | undefined;
}

export type ProductInboxCacheWriteMode = "merge" | "replace";

export interface ProductInboxCacheApplyInput {
  audience: string;
  conversations?:
    | {
        items: LocalDataProductConversationInput[];
        mode: ProductInboxCacheWriteMode;
        workspaceId: string;
      }
    | undefined;
  principalId: string;
  session: SessionProductLease;
  workspaces: {
    items: LocalDataProductWorkspaceInput[];
    mode: ProductInboxCacheWriteMode;
  };
}

export interface LocalProductInboxItem {
  raw?: LocalDataJsonValue | undefined;
  audience: string;
  groupId: string;
  id: string;
  source: "salix.conversation";
  workspaceId: string;
  workspaceName: string;
  conversationId: string;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  kind: ProductConversationKind;
  title: string;
  status: string;
  updatedAt: number;
}

export interface LocalDataOpenInput {
  databasePath: string;
  workerGeneration: number;
}

export interface LocalDataOpenResult {
  schemaVersion: number;
  workerGeneration: number;
}

export interface LocalDataWriteRequest {
  input: ProductInboxCacheApplyInput;
  operationId: string;
  workerGeneration: number;
}

export interface LocalDataWriteAck {
  operationId: string;
  session: SessionProductLease;
  workerGeneration: number;
}

export type LocalDataWriteFailureCode = "stale_session_lease";

export class LocalDataWriteFailure extends Error {
  readonly code: LocalDataWriteFailureCode;
  readonly session: SessionProductLease;

  constructor({
    code,
    session,
  }: {
    code: LocalDataWriteFailureCode;
    session: SessionProductLease;
  }) {
    super("Local data write rejected because its session lease is stale.");
    this.name = "LocalDataWriteFailure";
    this.code = code;
    this.session = sessionProductLeaseSchema.parse(session);
  }
}

export const LOCAL_DATA_WORKER_PROTOCOL_VERSION = 1 as const;
export const LOCAL_DATA_WORKER_CONNECT_MESSAGE =
  "comma:local-data-worker:connect" as const;

export interface LocalDataWorkerConnectMessage {
  protocolVersion: typeof LOCAL_DATA_WORKER_PROTOCOL_VERSION;
  type: typeof LOCAL_DATA_WORKER_CONNECT_MESSAGE;
}

export interface LocalDataWorkerApi {
  applyProductInboxSync(input: LocalDataWriteRequest): LocalDataWriteAck;
  close(): void;
  listProductInboxItems(input: {
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }): LocalProductInboxItem[];
  listProductWorkspaces(input: {
    audience: string;
    principalId: string;
  }): LocalDataProductWorkspaceInput[];
  open(input: LocalDataOpenInput): LocalDataOpenResult;
  referencedBlobIds(): string[];
  schemaVersion(): number;
}

export interface LocalDataRepositoryHealth {
  error?: string | undefined;
  status: "ready" | "degraded" | "closed";
  workerGeneration: number;
}

export interface LocalDataRepository {
  applyProductInboxSync(input: ProductInboxCacheApplyInput): Promise<LocalDataWriteAck>;
  close(): Promise<void>;
  health(): LocalDataRepositoryHealth;
  listProductInboxItems(input: {
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }): Promise<LocalProductInboxItem[]>;
  listProductWorkspaces(input: {
    audience: string;
    principalId: string;
  }): Promise<LocalDataProductWorkspaceInput[]>;
  onRecovered(listener: (workerGeneration: number) => void): () => void;
  referencedBlobIds(): Promise<string[]>;
  schemaVersion(): Promise<number>;
}

export function isLocalDataWorkerGeneration(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

export function assertLocalDataWriteRequest(
  request: LocalDataWriteRequest
): LocalDataWriteRequest {
  assertLocalDataJsonValue(request);
  assertOnlyObjectKeys(
    request,
    ["input", "operationId", "workerGeneration"],
    "Local data write request"
  );
  if (typeof request.operationId !== "string" || !request.operationId.trim()) {
    throw new Error("Local data operationId must not be empty.");
  }
  if (!isLocalDataWorkerGeneration(request.workerGeneration)) {
    throw new Error("Local data workerGeneration must be a positive safe integer.");
  }
  assertProductInboxCacheApplyInput(request.input);
  return request;
}

export function assertLocalDataWriteAck(ack: LocalDataWriteAck): LocalDataWriteAck {
  assertLocalDataJsonValue(ack);
  assertOnlyObjectKeys(
    ack,
    ["operationId", "session", "workerGeneration"],
    "Local data write acknowledgement"
  );
  if (typeof ack.operationId !== "string" || !ack.operationId.trim()) {
    throw new Error("Local data operationId must not be empty.");
  }
  if (!isLocalDataWorkerGeneration(ack.workerGeneration)) {
    throw new Error("Local data workerGeneration must be a positive safe integer.");
  }
  sessionProductLeaseSchema.parse(ack.session);
  return ack;
}

export function assertProductInboxCacheApplyInput(
  input: ProductInboxCacheApplyInput
): ProductInboxCacheApplyInput {
  assertLocalDataJsonValue(input);
  assertOnlyObjectKeys(
    input,
    ["audience", "conversations", "principalId", "session", "workspaces"],
    "Local data ProductInbox cache input"
  );
  assertProductInboxCachePartition(input);
  return input;
}

export function assertNormalizedLocalDataAudience(
  value: unknown
): asserts value is string {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("Local data audience must be a non-empty string.");
  }
  if (value !== value.trim()) {
    throw new Error("Local data audience must already be normalized.");
  }
}

export function assertLocalDataJsonValue(
  value: unknown
): asserts value is LocalDataJsonValue {
  if (value === null) return;

  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("Local data JSON numbers must be finite.");
    }
    return;
  }

  if (typeof value === "boolean" || typeof value === "string") return;

  if (Array.isArray(value)) {
    for (const item of value) assertLocalDataJsonValue(item);
    return;
  }

  if (!value || typeof value !== "object") {
    throw new Error("Local data values must be JSON-compatible.");
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error("Local data JSON objects must be plain objects.");
  }

  for (const item of Object.values(value)) {
    assertLocalDataJsonValue(item);
  }
}

function assertProductInboxCachePartition(input: ProductInboxCacheApplyInput): void {
  assertNormalizedLocalDataAudience(input.audience);
  const session = sessionProductLeaseSchema.parse(input.session);
  if (
    session.audience !== input.audience ||
    !sameSessionProductLease(session, input.session)
  ) {
    throw new Error(
      "Local data cache session lease must be canonical and match the request audience."
    );
  }
  for (const workspace of input.workspaces.items) {
    assertMatchingPartition(input, workspace);
    assertGroupId(workspace.groupId);
  }
  if (input.conversations) {
    const workspace = input.workspaces.items.find(
      (candidate) => candidate.id === input.conversations?.workspaceId
    );
    for (const conversation of input.conversations.items) {
      assertMatchingPartition(input, conversation);
      assertGroupId(conversation.groupId);
      if (conversation.workspaceId !== input.conversations.workspaceId) {
        throw new Error(
          "Local data conversation must match the request workspace partition."
        );
      }
      if (!workspace || conversation.groupId !== workspace.groupId) {
        throw new Error(
          "Local data conversation must match the Workspace's admitted Group."
        );
      }
    }
  }
}

function assertGroupId(groupId: string): void {
  if (typeof groupId !== "string" || !groupId.trim()) {
    throw new Error("Local data record must carry a canonical Group id.");
  }
}

function assertMatchingPartition(
  partition: Pick<ProductInboxCacheApplyInput, "audience" | "principalId">,
  item: { audience: string; principalId: string }
): void {
  assertNormalizedLocalDataAudience(item.audience);
  if (
    item.audience !== partition.audience ||
    item.principalId !== partition.principalId
  ) {
    throw new Error(
      "Local data cache items must match the request principalId and audience."
    );
  }
}

function assertOnlyObjectKeys(
  value: unknown,
  allowedKeys: readonly string[],
  label: string
): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object.`);
  }
  const allowed = new Set(allowedKeys);
  const unexpected = Object.keys(value).find((key) => !allowed.has(key));
  if (unexpected) {
    throw new Error(`${label} contains unexpected field ${unexpected}.`);
  }
}
