import type { ChatWorkspaceResolution } from "@comma/chat-contract";
import { CommaApiError } from "../../../api";
import {
  StaleChatSessionError,
  type ChatSessionBoundary,
} from "../entries/sessionBoundary";

type WorkspaceChatResolutionRecord = {
  key: string;
  value: ChatWorkspaceResolution;
};

type WorkspaceChatResolutionPromise = {
  key: string;
  promise: Promise<ChatWorkspaceResolution>;
};

/**
 * Resolves the workspace's group chat once per session boundary, sharing an
 * in-flight resolution between callers. A reset cancels every resolution.
 */
export class WorkspaceChatResolver {
  readonly #openBoundary: () => ChatSessionBoundary;
  #sessionEpoch = 0;
  #workspaceChatResolution: WorkspaceChatResolutionRecord | undefined;
  #workspaceChatResolutionPromise: WorkspaceChatResolutionPromise | undefined;

  constructor(openBoundary: () => ChatSessionBoundary) {
    this.#openBoundary = openBoundary;
  }

  async resolve(): Promise<ChatWorkspaceResolution> {
    const boundary = this.#openBoundary();
    boundary.assertCurrent();
    if (
      this.#workspaceChatResolution?.key === boundary.key &&
      this.#workspaceChatResolution.value.status === "ready"
    ) {
      boundary.assertCurrent();
      return this.#workspaceChatResolution.value;
    }
    if (this.#workspaceChatResolutionPromise?.key === boundary.key) {
      return this.#workspaceChatResolutionPromise.promise;
    }

    const resolution = this.#resolve(this.#sessionEpoch, boundary);
    const pending = { key: boundary.key, promise: resolution };
    this.#workspaceChatResolutionPromise = pending;
    try {
      return await resolution;
    } finally {
      if (this.#workspaceChatResolutionPromise === pending) {
        this.#workspaceChatResolutionPromise = undefined;
      }
    }
  }

  reset() {
    this.#sessionEpoch += 1;
    this.#workspaceChatResolution = undefined;
    this.#workspaceChatResolutionPromise = undefined;
  }

  async #resolve(
    sessionEpoch: number,
    boundary: ChatSessionBoundary
  ): Promise<ChatWorkspaceResolution> {
    try {
      boundary.assertCurrent();
      const api = boundary.api;
      const bootstrap = await api.bootstrapWorkspace();
      this.#assertCurrentSession(sessionEpoch, boundary);

      if (bootstrap.status === "provisioning") {
        const result: ChatWorkspaceResolution = {
          groupId: bootstrap.workspace.group_id,
          retryAfterSeconds: bootstrap.retry_after_seconds,
          status: "provisioning",
          workspaceId: bootstrap.workspace.id,
        };
        boundary.assertCurrent();
        return result;
      }

      const workspace = bootstrap.workspace;
      const conversation = await api.ensureGroupChat(workspace.group_id);
      this.#assertCurrentSession(sessionEpoch, boundary);
      const resolution: ChatWorkspaceResolution = {
        conversationId: conversation.id,
        ...(conversation.created_at === undefined
          ? {}
          : { createdAt: conversation.created_at }),
        groupId: workspace.group_id,
        status: "ready",
        ...(conversation.updated_at === undefined
          ? {}
          : { updatedAt: conversation.updated_at }),
        workspaceId: workspace.id,
      };
      this.#workspaceChatResolution = { key: boundary.key, value: resolution };
      boundary.assertCurrent();
      return resolution;
    } catch (error) {
      this.#assertCurrentSession(sessionEpoch, boundary);
      if (error instanceof CommaApiError && error.status === 401) {
        return { status: "unauthorized" };
      }
      if (
        error instanceof CommaApiError &&
        (error.status === 403 || error.status === 404)
      ) {
        return { status: "hidden" };
      }
      throw error;
    }
  }

  #assertCurrentSession(sessionEpoch: number, boundary: ChatSessionBoundary) {
    boundary.assertCurrent();
    if (sessionEpoch !== this.#sessionEpoch) {
      throw new StaleChatSessionError();
    }
  }
}
