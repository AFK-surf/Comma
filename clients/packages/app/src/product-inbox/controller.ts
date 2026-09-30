import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import {
  getNativeBridge,
  productInboxStateEnvelopeSchema,
  type ProductInboxBridge,
  type ProductInboxListResult,
} from "@comma/native-bridge";
import {
  sessionProductLeaseSchema,
  type SessionBoundStateEnvelope,
  type SessionProductLease,
} from "@comma/session-contract";
import {
  appendProductInboxPages,
  combineProductInboxPages,
  refreshProductInboxPages,
} from "./pages";

export type ProductInboxProjectionEnvelope =
  SessionBoundStateEnvelope<ProductInboxListResult>;

export type ProductInboxRetention = {
  session: SessionProductLease;
};

export type ProductInboxRefresh = {
  conversationIds?: string[] | undefined;
  cursor?: string | undefined;
  limit?: number | undefined;
  workspaceId?: string | undefined;
};

export type ProductInboxArchiveIntent = {
  conversationId: string;
  groupId: string;
  /**
   * The Task version the decision was taken against. The decision stops
   * overriding the projection as soon as the authority reports a later version
   * of that Task, so another client's archive or restore always wins.
   */
  version?: number | undefined;
};

/**
 * The handle for one staged archive decision. `confirm` keeps the decision
 * until the authority's own state carries it; `rollback` drops it, so a refused
 * decision returns the Task instead of leaving a lie on screen.
 */
export type ProductInboxArchiveStage = {
  confirm(): void;
  rollback(): void;
};

export type ProductInboxProjectionBridge = Pick<
  ProductInboxBridge,
  "refresh" | "release" | "retain" | "state"
>;

export interface ProductInboxProjectionController {
  /** The list readers render; `subscribe` reports only a change to it. */
  getSnapshotSync(): ProductInboxProjectionEnvelope | null;
  /**
   * The owner's latest envelope, before local archive decisions apply. Every
   * owner read delivers a new one, including a reread that repeats the
   * published list. Facts cached outside the owner's page revalidate on each.
   */
  getOwnerSnapshotSync(): ProductInboxProjectionEnvelope | null;
  refresh(input?: ProductInboxRefresh): Promise<ProductInboxProjectionEnvelope>;
  retain(input: ProductInboxRetention): () => void;
  /**
   * Shows a Task as archived before the authority confirms it, so an archive
   * the user has already chosen leaves the list at once instead of waiting for
   * a reread. The returned handle confirms or rolls the local view back, and
   * the decision only ever overrides the version of the Task it was taken
   * against.
   */
  stageTaskArchived(input: ProductInboxArchiveIntent): ProductInboxArchiveStage;
  subscribe(listener: () => void): () => void;
  subscribeOwnerSnapshot(listener: () => void): () => void;
}

const productInboxProjectionEnvelopeSchema = productInboxStateEnvelopeSchema;

type ArchiveIntent = {
  conversationId: string;
  groupId: string;
  /** The authority accepted the decision; only its own state may clear it. */
  settled: boolean;
  version?: number | undefined;
};

type ActiveRetention = {
  bridgeUnsubscribe: () => void;
  epoch: number;
  input: ProductInboxRetention;
  key: string;
  refreshQueue?:
    | {
        workspaceId: string | undefined;
        tail: Promise<void>;
        requests: Map<string, Promise<ProductInboxProjectionEnvelope>>;
      }
    | undefined;
  recentCommandFingerprint?: string | undefined;
  ready: Promise<void>;
  references: number;
};

export function createElectronProductInboxProjectionController(input?: {
  bridge?: ProductInboxProjectionBridge;
}): ProductInboxProjectionController {
  return createProductInboxProjectionController({
    bridge: input?.bridge ?? getNativeBridge().productInbox,
  });
}

/** Host-neutral renderer projection over a Main or SharedWorker owner bridge. */
export function createProductInboxProjectionController(input: {
  bridge: ProductInboxProjectionBridge;
}): ProductInboxProjectionController {
  return new ProductInboxProjectionControllerImpl(input.bridge);
}

class ProductInboxProjectionControllerImpl implements ProductInboxProjectionController {
  private active: ActiveRetention | undefined;
  private epoch = 0;
  private readonly listeners = new Set<() => void>();
  private readonly ownerListeners = new Set<() => void>();
  private pages: ProductInboxListResult[] = [];
  private requestedWorkspaceId: string | undefined;
  /** The owner's own envelope: server facts only, never a local decision. */
  private snapshot: ProductInboxProjectionEnvelope | null = null;
  /** Every archive the user chose and the authority has not confirmed yet. */
  private readonly archiveIntents = new Map<string, ArchiveIntent>();
  /** What this renderer reads: the owner envelope plus those decisions. */
  private published: ProductInboxProjectionEnvelope | null = null;
  private publishedFingerprint: string | undefined;

  constructor(private readonly bridge: ProductInboxProjectionBridge) {}

  getSnapshotSync() {
    return this.published;
  }

  getOwnerSnapshotSync() {
    return this.snapshot;
  }

  retain(inputValue: ProductInboxRetention) {
    const input = parseRetention(inputValue);
    const key = retentionKey(input);
    if (this.active?.key === key) {
      this.active.references += 1;
    } else {
      this.replaceActiveRetention(input, key);
    }

    let released = false;
    return () => {
      if (released) {
        return;
      }
      released = true;
      const active = this.active;
      if (!active || active.key !== key) {
        return;
      }
      active.references -= 1;
      if (active.references === 0) {
        this.releaseActiveRetention(active);
      }
    };
  }

  async refresh(input: ProductInboxRefresh = {}) {
    const active = this.active;
    if (!active) {
      throw new Error("ProductInbox refresh requires an active retained projection.");
    }

    const workspaceId = input.workspaceId?.trim();
    const nextWorkspaceId = workspaceId || undefined;
    if (
      input.workspaceId !== undefined &&
      nextWorkspaceId !== this.requestedWorkspaceId
    ) {
      this.requestedWorkspaceId = nextWorkspaceId;
      const projectedWorkspaceId =
        this.snapshot?.snapshot.activeWorkspaceId ??
        this.snapshot?.snapshot.items[0]?.workspaceId;
      if (
        projectedWorkspaceId !== undefined &&
        projectedWorkspaceId !== nextWorkspaceId
      ) {
        this.pages = [];
        this.publish(null);
      }
    }
    // The owner has one refresh intent. Serialize reads for the same Workspace
    // so startup refreshes cannot supersede a cursor request. A Workspace switch
    // starts a new queue immediately and revokes commands still in the old one.
    const targetWorkspaceId =
      workspaceId ??
      this.requestedWorkspaceId ??
      this.snapshot?.snapshot.activeWorkspaceId;
    const queue =
      active.refreshQueue && active.refreshQueue.workspaceId === targetWorkspaceId
        ? active.refreshQueue
        : {
            workspaceId: targetWorkspaceId,
            tail: Promise.resolve(),
            requests: new Map<string, Promise<ProductInboxProjectionEnvelope>>(),
          };
    // Columns and other readers share an identical pending page request.
    const key = JSON.stringify([
      targetWorkspaceId,
      input.cursor,
      input.limit,
      input.conversationIds,
    ]);
    const pending = queue.requests.get(key);
    if (pending) return pending;
    const previous = queue.tail;
    const settled = Promise.withResolvers<void>();
    queue.tail = settled.promise;
    active.refreshQueue = queue;
    const current = () => this.active === active && active.refreshQueue === queue;
    const request = (async () => {
      let requested = false;
      try {
        await previous;
        if (!current()) throw new Error("ProductInbox refresh was superseded.");
        await active.ready;
        if (!current()) throw new Error("ProductInbox refresh was superseded.");
        if (input.cursor && this.snapshot?.snapshot.nextCursor !== input.cursor) {
          throw new Error("ProductInbox refresh cursor is no longer current.");
        }
        requested = true;
        const envelope = await this.bridge.refresh({
          ...input,
          ...(workspaceId ? { workspaceId } : {}),
          session: active.input.session,
        });
        if (!current()) throw new Error("ProductInbox refresh was superseded.");
        const accepted = this.acceptEnvelope(
          active,
          envelope,
          input.cursor ? "append" : "refresh"
        );
        if (!accepted) {
          throw new Error(
            "ProductInbox refresh did not match the active Session projection."
          );
        }
        active.recentCommandFingerprint = envelopeFingerprint(envelope);
        return accepted;
      } catch (error) {
        if (current() && requested) {
          this.publishUnavailable(active, "utility_unavailable");
        }
        throw error;
      } finally {
        queue.requests.delete(key);
        settled.resolve();
        if (current() && queue.tail === settled.promise) {
          active.refreshQueue = undefined;
        }
      }
    })();
    queue.requests.set(key, request);
    return request;
  }

  stageTaskArchived(input: ProductInboxArchiveIntent): ProductInboxArchiveStage {
    const key = archiveIntentKey(input.groupId, input.conversationId);
    const intent: ArchiveIntent = {
      conversationId: input.conversationId,
      groupId: input.groupId,
      settled: false,
      ...(input.version === undefined ? {} : { version: input.version }),
    };
    this.archiveIntents.set(key, intent);
    this.publish(this.snapshot);
    return {
      confirm: () => this.settleArchiveIntent(key, intent, true),
      rollback: () => this.settleArchiveIntent(key, intent, false),
    };
  }

  /**
   * Settles one staged decision. A superseding stage of the same Task owns the
   * slot, so an older handle never clears a newer decision.
   */
  private settleArchiveIntent(key: string, intent: ArchiveIntent, accepted: boolean) {
    if (this.archiveIntents.get(key) !== intent) {
      return;
    }
    if (accepted) {
      intent.settled = true;
    } else {
      this.archiveIntents.delete(key);
    }
    this.publish(this.snapshot);
  }

  subscribe(listener: () => void) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  subscribeOwnerSnapshot(listener: () => void) {
    this.ownerListeners.add(listener);
    return () => {
      this.ownerListeners.delete(listener);
    };
  }

  private replaceActiveRetention(input: ProductInboxRetention, key: string) {
    if (this.active) {
      this.releaseActiveRetention(this.active);
    }

    this.archiveIntents.clear();

    const epoch = ++this.epoch;
    const active: ActiveRetention = {
      bridgeUnsubscribe: () => undefined,
      epoch,
      input,
      key,
      ready: Promise.resolve(),
      references: 1,
    };
    this.active = active;
    this.pages = [];
    this.requestedWorkspaceId = undefined;
    this.publish(null);

    try {
      active.bridgeUnsubscribe = this.bridge.state.subscribe(
        (envelope) => {
          this.acceptStateEnvelope(active, envelope);
        },
        { session: input.session }
      );
    } catch {
      this.publishUnavailable(active, "utility_unavailable");
      return;
    }

    active.ready = this.bridge.retain({ session: input.session }).then((envelope) => {
      this.acceptStateEnvelope(active, envelope);
    });
    void active.ready
      .then(() => this.bridge.state.get({ session: input.session }))
      .then((envelope) => {
        this.acceptStateEnvelope(active, envelope);
      })
      .catch(() => {
        this.publishUnavailable(active, "utility_unavailable");
      });
  }

  private releaseActiveRetention(active: ActiveRetention) {
    if (this.active !== active) {
      return;
    }
    this.active = undefined;
    this.pages = [];
    this.requestedWorkspaceId = undefined;
    active.bridgeUnsubscribe();
    this.publish(null);
    void this.bridge.release({ session: active.input.session }).catch(() => undefined);
  }

  private acceptStateEnvelope(active: ActiveRetention, value: unknown) {
    if (active.refreshQueue) {
      return;
    }
    const fingerprint = envelopeFingerprint(value);
    if (fingerprint !== undefined && active.recentCommandFingerprint === fingerprint) {
      active.recentCommandFingerprint = undefined;
      return;
    }
    this.acceptEnvelope(active, value, "refresh");
  }

  private acceptEnvelope(
    active: ActiveRetention,
    value: unknown,
    mode: "append" | "refresh"
  ): ProductInboxProjectionEnvelope | null {
    if (this.active !== active || active.epoch !== this.epoch) {
      return null;
    }

    const parsed = productInboxProjectionEnvelopeSchema.safeParse(value);
    if (
      !parsed.success ||
      sessionLeaseIdentity(parsed.data.session) !==
        sessionLeaseIdentity(active.input.session) ||
      !projectionMatchesWorkspace(parsed.data.snapshot, this.requestedWorkspaceId)
    ) {
      return null;
    }
    // A failed cursor read is not a page. Return its outcome to the caller
    // without replacing loaded rows or the cursor needed for a retry.
    if (mode === "append" && parsed.data.snapshot.source !== "live-sync") {
      return parsed.data;
    }
    this.pages =
      mode === "append"
        ? appendProductInboxPages(this.pages, parsed.data.snapshot)
        : refreshProductInboxPages(this.pages, parsed.data.snapshot);
    const combined = combineProductInboxPages(this.pages);
    if (!combined) {
      return null;
    }
    this.publish({ session: parsed.data.session, snapshot: combined });
    return this.published;
  }

  private publishUnavailable(
    active: ActiveRetention,
    errorCode: NonNullable<ProductInboxListResult["errorCode"]>
  ) {
    if (this.active !== active) {
      return;
    }
    this.acceptEnvelope(
      active,
      {
        session: active.input.session,
        snapshot: {
          ...(this.requestedWorkspaceId
            ? { activeWorkspaceId: this.requestedWorkspaceId }
            : {}),
          errorCode,
          items: [],
          source: "unavailable",
        },
      },
      "refresh"
    );
  }

  /**
   * One owner envelope carries two facts, and each has its own readers. The
   * list changes only when its content does: demand-driven rereads (a view
   * mounting, a route returning) mostly confirm the list already published,
   * and re-rendering every list reader on each of them made switching pages
   * stall. The read itself happens every time: a cache of facts outside the
   * owner's page revalidates on it, whether or not the page changed.
   */
  private publish(snapshot: ProductInboxProjectionEnvelope | null) {
    const ownerRead = snapshot !== this.snapshot;
    this.snapshot = snapshot;
    this.publishProjection(this.project(snapshot));
    if (!ownerRead) return;
    for (const listener of this.ownerListeners) {
      listener();
    }
  }

  /**
   * Readers treat a new object as a change, so an equal list keeps the old one,
   * and in a changed list every Task whose facts are the same keeps its item.
   */
  private publishProjection(projected: ProductInboxProjectionEnvelope | null) {
    if (projected === this.published) return;
    const fingerprint = projected ? JSON.stringify(projected) : undefined;
    if (fingerprint === this.publishedFingerprint) return;
    this.published =
      projected && this.published
        ? keepUnchangedItems(this.published, projected)
        : projected;
    this.publishedFingerprint = fingerprint;
    for (const listener of this.listeners) {
      listener();
    }
  }

  /**
   * Applies the user's unconfirmed archive decisions to one owner envelope and
   * forgets the ones the owner has reported its way. A decision is only ever a
   * view of a Task the authority owns: it ends when the owner states the Task
   * archived, when the owner reports a later version of the Task than the
   * decision was taken against — another client may have archived or restored
   * it meanwhile — and, once accepted, when the list no longer carries the Task
   * at all. Removing a decision here is what keeps one read model instead of
   * two.
   */
  private project(envelope: ProductInboxProjectionEnvelope | null) {
    if (!envelope) {
      return null;
    }
    for (const [key, intent] of this.archiveIntents) {
      const item = envelope.snapshot.items.find(
        (candidate) =>
          candidate.groupId === intent.groupId &&
          candidate.conversationId === intent.conversationId
      );
      if (!item) {
        if (intent.settled) {
          this.archiveIntents.delete(key);
        }
        continue;
      }
      if (
        item.status === "archived" ||
        (intent.version !== undefined && (item.archiveVersion ?? 0) > intent.version)
      ) {
        this.archiveIntents.delete(key);
      }
    }
    if (this.archiveIntents.size === 0) {
      return envelope;
    }

    let archived = false;
    const items = envelope.snapshot.items.map((item) => {
      if (
        item.status === "archived" ||
        !this.archiveIntents.has(archiveIntentKey(item.groupId, item.conversationId))
      ) {
        return item;
      }
      archived = true;
      return { ...item, status: "archived" };
    });
    return archived
      ? { session: envelope.session, snapshot: { ...envelope.snapshot, items } }
      : envelope;
  }
}

function archiveIntentKey(groupId: string, conversationId: string) {
  return `${groupId} ${conversationId}`;
}

/**
 * Every owner read parses into new objects. A Task whose facts did not change
 * keeps the item its readers already hold, so only the Tasks that changed
 * render again.
 */
function keepUnchangedItems(
  previous: ProductInboxProjectionEnvelope,
  next: ProductInboxProjectionEnvelope
): ProductInboxProjectionEnvelope {
  const held = new Map(
    previous.snapshot.items.map((item) => [
      archiveIntentKey(item.groupId, item.conversationId),
      item,
    ])
  );
  let kept = false;
  const items = next.snapshot.items.map((item) => {
    const heldItem = held.get(archiveIntentKey(item.groupId, item.conversationId));
    if (!heldItem || itemFingerprint(heldItem) !== itemFingerprint(item)) return item;
    kept = true;
    return heldItem;
  });
  return kept ? { ...next, snapshot: { ...next.snapshot, items } } : next;
}

// Items are never mutated, so each is serialized once however often it is kept.
const itemFingerprints = new WeakMap<object, string>();
function itemFingerprint(item: object) {
  let fingerprint = itemFingerprints.get(item);
  if (fingerprint === undefined) {
    fingerprint = JSON.stringify(item);
    itemFingerprints.set(item, fingerprint);
  }
  return fingerprint;
}

export function productInboxUnavailableResult(
  errorCode: NonNullable<ProductInboxListResult["errorCode"]>
): ProductInboxListResult {
  return {
    errorCode,
    items: [],
    source: "unavailable",
  };
}

export function productInboxErrorMessage(
  errorCode: ProductInboxListResult["errorCode"],
  locale: CommaLocale = baseLocale
): string {
  switch (errorCode) {
    case "network_unavailable":
      return messages.product_inbox_network_unavailable({}, { locale });
    case "protocol_mismatch":
      return messages.product_inbox_protocol_mismatch({}, { locale });
    case "session_product_lease_unavailable":
      return messages.product_inbox_session_lease_unavailable({}, { locale });
    case "utility_unavailable":
      return messages.product_inbox_utility_unavailable({}, { locale });
    default:
      return messages.product_inbox_unavailable({}, { locale });
  }
}

function parseRetention(input: ProductInboxRetention): ProductInboxRetention {
  const session = sessionProductLeaseSchema.parse(input.session);
  return { session };
}

function retentionKey(input: ProductInboxRetention) {
  return sessionLeaseIdentity(input.session);
}

function sessionLeaseIdentity(session: SessionProductLease) {
  return JSON.stringify([
    session.authorityInstanceId,
    session.generation,
    session.sessionId,
    session.audience,
  ]);
}

function projectionMatchesWorkspace(
  snapshot: ProductInboxListResult,
  workspaceId: string | undefined
) {
  if (!workspaceId) {
    return true;
  }
  if (
    snapshot.activeWorkspaceId !== undefined &&
    snapshot.activeWorkspaceId !== workspaceId
  ) {
    return false;
  }
  return snapshot.items.every((item) => item.workspaceId === workspaceId);
}

function envelopeFingerprint(value: unknown) {
  const parsed = productInboxProjectionEnvelopeSchema.safeParse(value);
  return parsed.success ? JSON.stringify(parsed.data) : undefined;
}
