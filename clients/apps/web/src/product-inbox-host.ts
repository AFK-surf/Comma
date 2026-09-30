import {
  type ProductCredentialAuthorityPort,
  type ProductCredentialLease,
  type ProductInboxCacheApplyInput,
  type ProductInboxStoragePort,
  type ProductInboxStoredItem,
  type ProductInboxWorkspaceRecord,
} from "@comma/product-inbox-runtime";
import {
  sameSessionProductLease,
  sessionLifecycleSnapshotSchema,
  snapshotMatchesSessionProductLease,
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
  type SessionProductLease,
} from "@comma/session-contract";

export class WebCookieProductCredentialAuthority implements ProductCredentialAuthorityPort {
  #controller = new AbortController();
  readonly #rejectionListeners = new Set<
    (rejection: { session: SessionProductLease; status: 401 | 409 }) => void
  >();
  #session: SessionProductLease | undefined;
  #snapshot: SessionLifecycleSnapshot | undefined;

  activate(session: SessionProductLease) {
    if (this.#session && sameSessionProductLease(this.#session, session)) return;
    this.#controller.abort();
    this.#controller = new AbortController();
    this.#session = session;
    this.#snapshot = sessionLifecycleSnapshotSchema.parse({
      authority: {
        authorityInstanceId: session.authorityInstanceId,
        kind: "web_cookie",
      },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: session.generation,
      phase: "signed_in",
      principal: {
        email: "web-session@local.invalid",
        userId: session.sessionId,
      },
      revision: session.generation,
      session: {
        audience: session.audience,
        expiresAtEpochSeconds: Number.MAX_SAFE_INTEGER,
        sessionId: session.sessionId,
      },
    });
  }

  invalidate() {
    this.#controller.abort();
  }

  onSessionRejection(
    listener: (rejection: { session: SessionProductLease; status: 401 | 409 }) => void
  ) {
    this.#rejectionListeners.add(listener);
    return () => this.#rejectionListeners.delete(listener);
  }

  reportSessionRejection(lease: ProductCredentialLease, status: 401 | 409) {
    const session: SessionProductLease = {
      audience: lease.audience,
      authorityInstanceId: lease.authorityInstanceId,
      generation: lease.generation,
      sessionId: lease.sessionId,
    };
    this.invalidate();
    for (const listener of this.#rejectionListeners) listener({ session, status });
  }

  acquireProductCredential(
    expected: SessionPresenceExpectation
  ): ProductCredentialLease | null {
    const session = this.#session;
    if (
      !session ||
      this.#controller.signal.aborted ||
      expected.authorityInstanceId !== session.authorityInstanceId ||
      expected.expectedAudience !== session.audience ||
      expected.expectedSessionId !== session.sessionId ||
      expected.generation !== session.generation
    ) {
      return null;
    }
    return {
      ...session,
      request: {
        credentials: "include",
        headers: {
          "x-comma-expected-auth-session-id": session.sessionId,
          "x-comma-session-lifecycle-version": "1",
          "x-comma-session-transport": "cookie",
        },
      },
      signal: this.#controller.signal,
      token: "",
    };
  }

  getSnapshot() {
    if (!this.#snapshot) {
      throw new Error("Web ProductInbox Session authority is inactive.");
    }
    return this.#snapshot;
  }

  isCurrentProductCredential(lease: ProductCredentialLease) {
    return (
      !lease.signal.aborted &&
      lease.signal === this.#controller.signal &&
      !!this.#snapshot &&
      snapshotMatchesSessionProductLease(this.#snapshot, {
        audience: lease.audience,
        authorityInstanceId: lease.authorityInstanceId,
        generation: lease.generation,
        sessionId: lease.sessionId,
      })
    );
  }
}

/** SharedWorker-local storage port; renderer reloads do not own this state. */
export class WebMemoryProductInboxStorage implements ProductInboxStoragePort {
  readonly #conversations = new Map<
    string,
    { item: ProductInboxStoredItem; principalId: string }
  >();
  readonly #workspaceRecords = new Map<string, ProductInboxWorkspaceRecord>();

  async applyProductInboxSync(input: ProductInboxCacheApplyInput) {
    if (input.workspaces.mode === "replace") {
      for (const [key, workspace] of this.#workspaceRecords) {
        if (
          workspace.audience === input.audience &&
          workspace.principalId === input.principalId
        ) {
          this.#workspaceRecords.delete(key);
        }
      }
    }
    for (const workspace of input.workspaces.items) {
      this.#workspaceRecords.set(
        workspaceKey(workspace.audience, workspace.principalId, workspace.id),
        workspace
      );
    }
    if (input.conversations) {
      const { items, mode, workspaceId } = input.conversations;
      if (mode === "replace") {
        for (const [key, record] of this.#conversations) {
          if (
            record.principalId === input.principalId &&
            record.item.audience === input.audience &&
            record.item.workspaceId === workspaceId
          ) {
            this.#conversations.delete(key);
          }
        }
      }
      for (const item of items) {
        const workspace = this.#workspaceRecords.get(
          workspaceKey(item.audience, item.principalId, item.workspaceId)
        );
        if (!workspace) continue;
        const stored: ProductInboxStoredItem = {
          raw: item.raw,
          audience: item.audience,
          conversationId: item.id,
          freshness: item.freshness,
          groupId: item.groupId,
          id: `${item.workspaceId}:${item.id}`,
          kind: item.kind,
          source: "salix.conversation",
          status: item.status,
          title: item.title,
          updatedAt: item.updatedAt ?? item.createdAt ?? 0,
          workspaceId: item.workspaceId,
          workspaceName: workspace.name,
        };
        this.#conversations.set(
          conversationKey(item.audience, item.principalId, item.id),
          { item: stored, principalId: item.principalId }
        );
      }
    }
    return { session: input.session };
  }

  health() {
    return { status: "ready" as const };
  }

  async listProductInboxItems(input: {
    audience: string;
    limit?: number;
    principalId: string;
    workspaceId?: string;
  }) {
    return [...this.#conversations.values()]
      .filter(
        (record) =>
          record.principalId === input.principalId &&
          record.item.audience === input.audience &&
          (!input.workspaceId || record.item.workspaceId === input.workspaceId)
      )
      .map((record) => record.item)
      .toSorted((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, input.limit ?? 50);
  }

  async listProductWorkspaces(input: { audience: string; principalId: string }) {
    return [...this.#workspaceRecords.values()].filter(
      (workspace) =>
        workspace.audience === input.audience &&
        workspace.principalId === input.principalId
    );
  }

  onRecovered() {
    return () => undefined;
  }
}

function workspaceKey(audience: string, principalId: string, workspaceId: string) {
  return `${audience}\u0000${principalId}\u0000${workspaceId}`;
}

function conversationKey(
  audience: string,
  principalId: string,
  conversationId: string
) {
  return `${audience}\u0000${principalId}\u0000${conversationId}`;
}
