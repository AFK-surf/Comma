import {
  sameSessionProductLease,
  sessionAdmissionFailureSchema,
  sessionProductLeaseSchema,
  snapshotMatchesSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import { z } from "zod";
import {
  type ProductInboxCacheApplyInput,
  type ProductInboxConversationRecord,
  type ProductInboxJsonValue,
  type ProductInboxStoragePort,
  type ProductInboxStoredItem,
  type ProductInboxWorkspaceRecord,
  type ProductCredentialAuthorityPort,
  type ProductCredentialLease,
} from "./ports";
import {
  productInboxStateEnvelopeSchema,
  productInboxRefreshInputSchema,
  salixProductConversationPageSchema,
  salixProductConversationWireSchema,
  salixProductWorkspacePageSchema,
  type ProductInboxSnapshot,
  type ProductInboxRefreshInput,
  type ProductInboxStateEnvelope,
  type SalixProductConversation,
  type SalixProductWorkspace,
} from "./contracts";

export type ProductInboxRuntimeFailureCode =
  | "credential_unavailable"
  | "http_error"
  | "invalid_response"
  | "redirect_rejected"
  | "stale_session_lease"
  | "superseded_refresh"
  | "subscriber_limit"
  | "utility_unavailable";

export class ProductInboxRuntimeFailure extends Error {
  readonly code: ProductInboxRuntimeFailureCode;

  constructor(code: ProductInboxRuntimeFailureCode, message: string) {
    super(message);
    this.name = "ProductInboxRuntimeFailure";
    this.code = code;
  }
}

export type ProductInboxStateListener = (envelope: ProductInboxStateEnvelope) => void;

export type ProductInboxRuntimeScheduler = (
  run: () => void,
  delayMs: number
) => () => void;

export interface ProductInboxRuntimeOptions {
  authority: ProductCredentialAuthorityPort;
  fetch?: typeof fetch | undefined;
  limit?: number | undefined;
  localData: ProductInboxStoragePort;
  maxSubscribers?: number | undefined;
  now?: (() => number) | undefined;
  reportSessionChanged?:
    | ((credential: ProductCredentialLease) => Promise<void>)
    | undefined;
  reportUnauthorized: (credential: ProductCredentialLease) => Promise<void>;
  requestTimeoutMs?: number | undefined;
  schedule?: ProductInboxRuntimeScheduler | undefined;
  scheduleDeadline?: ProductInboxRuntimeScheduler | undefined;
}

interface Subscription {
  listener: ProductInboxStateListener;
  session: SessionProductLease;
}

interface ActiveRefresh {
  key: string;
  promise: Promise<ProductInboxStateEnvelope>;
  session: SessionProductLease;
}

interface NormalizedRefreshInput {
  conversationIds?: string[] | undefined;
  callerSignal?: AbortSignal | undefined;
  cursor?: string | undefined;
  intentEpoch: number;
  key: string;
  limit: number;
  session: SessionProductLease;
  workspaceId?: string | undefined;
}

type RecurringRefreshInput = Omit<
  NormalizedRefreshInput,
  "callerSignal" | "cursor" | "intentEpoch" | "key" | "conversationIds"
>;

interface ConversationTraversal {
  conversations: SalixProductConversation[];
  nextCursor: string;
}

interface ConditionalJsonResource {
  etag?: string | undefined;
  value: unknown;
}

interface LiveProjection {
  fingerprint: string;
  groupId?: string | undefined;
  snapshot: ProductInboxSnapshot;
}

interface RefreshRecoveryContext {
  targetGroupId: string | undefined;
  targetGroupResolved: boolean;
}

const DEFAULT_LIMIT = 50;
const DEFAULT_MAX_SUBSCRIBERS = 32;
const DEFAULT_REQUEST_TIMEOUT_MS = 5_000;
const TASK_EVENT_RECONNECT_MAX_MS = 15_000;
const REFRESH_RETRY_BASE_MS = 1_000;
const REFRESH_RETRY_MAX_MS = 15_000;
const MAX_CONDITIONAL_RESOURCES = 64;

const taskListInvalidationSchema = z.discriminatedUnion("type", [
  z.strictObject({
    type: z.literal("conversation_list_resync_required"),
    group_id: z.string().min(1),
    kind: z.literal("agent_task"),
    version: z.string().min(1).max(128),
  }),
  z.strictObject({
    type: z.literal("conversation_list_invalidated"),
    group_id: z.string().min(1),
    kind: z.literal("agent_task"),
    version: z.string().min(1).max(128),
  }),
]);

class ProductInboxHttpRequestError extends TypeError {
  constructor(message: string) {
    super(message);
    this.name = "ProductInboxHttpRequestError";
  }
}

/**
 * Host-owned ProductInbox projection shared by Electron Main and Web SharedWorker.
 *
 * The runtime accepts only token-free exact session leases. It borrows the
 * credential synchronously from the host authority for each refresh,
 * and every async settlement is fenced before cache mutation or publication.
 * Target-Group retry ownership is modeled in
 * `tla/salix/ProductInboxGroupRecovery.tla`.
 */
export class ProductInboxRuntime {
  readonly #authority: ProductCredentialAuthorityPort;
  readonly #fetch: typeof fetch;
  readonly #limit: number;
  readonly #localData: ProductInboxStoragePort;
  readonly #maxSubscribers: number;
  readonly #now: () => number;
  readonly #reportSessionChanged:
    | ((credential: ProductCredentialLease) => Promise<void>)
    | undefined;
  readonly #reportUnauthorized: (credential: ProductCredentialLease) => Promise<void>;
  readonly #requestTimeoutMs: number;
  readonly #schedule: ProductInboxRuntimeScheduler;
  readonly #scheduleDeadline: ProductInboxRuntimeScheduler;
  readonly #stopLocalDataRecovery: () => void;
  readonly #conditionalResources = new Map<string, ConditionalJsonResource>();
  readonly #degradedCacheFingerprints = new Map<string, string>();
  readonly #liveProjections = new Map<string, LiveProjection>();
  readonly #subscriptions = new Set<Subscription>();
  readonly #traversals = new Map<string, ConversationTraversal>();

  #activeSession: SessionProductLease | undefined;
  #cancelScheduled: (() => void) | undefined;
  #cancelTaskEventReconnect: (() => void) | undefined;
  #inFlight: ActiveRefresh | undefined;
  #intentEpoch = 0;
  #pendingRefreshRetryMs: number | undefined;
  #refreshRetryMs = REFRESH_RETRY_BASE_MS;
  #scheduledDelayMs: number | undefined;
  #recurringInput: RecurringRefreshInput | undefined;
  #retainedCount = 0;
  #state: ProductInboxStateEnvelope | undefined;
  #stateFingerprint: string | undefined;
  #taskEventController: AbortController | undefined;
  #taskEventEpoch = 0;
  #taskEventGroupId: string | undefined;
  #taskEventLastVersion: string | undefined;
  #taskEventReconnectMs = 1_000;
  #taskEventRefreshPending = false;
  #taskEventRefreshQueued = false;

  constructor({
    authority,
    fetch: fetchImpl = fetch,
    limit = DEFAULT_LIMIT,
    localData,
    maxSubscribers = DEFAULT_MAX_SUBSCRIBERS,
    now = Date.now,
    reportSessionChanged,
    reportUnauthorized,
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    schedule = scheduleTimeout,
    scheduleDeadline = scheduleTimeout,
  }: ProductInboxRuntimeOptions) {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new Error("ProductInbox limit must be an integer from 1 to 100.");
    }
    if (!Number.isSafeInteger(maxSubscribers) || maxSubscribers < 1) {
      throw new Error("ProductInbox maxSubscribers must be a positive integer.");
    }
    if (
      !Number.isSafeInteger(requestTimeoutMs) ||
      requestTimeoutMs < 1 ||
      requestTimeoutMs > 300_000
    ) {
      throw new Error(
        "ProductInbox requestTimeoutMs must be an integer from 1 to 300000."
      );
    }

    this.#authority = authority;
    // Web platform fetch is receiver-sensitive in workers. Keep every host's
    // adapter callable as a plain function instead of invoking it as a field
    // on ProductInboxRuntime.
    this.#fetch = (...args) => fetchImpl(...args);
    this.#limit = limit;
    this.#localData = localData;
    this.#maxSubscribers = maxSubscribers;
    this.#now = now;
    this.#reportSessionChanged = reportSessionChanged;
    this.#reportUnauthorized = reportUnauthorized;
    this.#requestTimeoutMs = requestTimeoutMs;
    this.#schedule = schedule;
    this.#scheduleDeadline = scheduleDeadline;
    this.#stopLocalDataRecovery = localData.onRecovered(() => {
      // A replacement utility worker may have an empty/rebuilt SQLite cache.
      // Keep the lease-local HTTP representation, but force the next refresh
      // to replay it through the durable cache transaction.
      this.#degradedCacheFingerprints.clear();
      this.#liveProjections.clear();
      const session = this.#activeSession;
      if (session && this.#hasDemandFor(session)) this.#scheduleRefresh(session);
    });
  }

  close(): void {
    this.#cancelScheduled?.();
    this.#cancelScheduled = undefined;
    this.#scheduledDelayMs = undefined;
    this.#pendingRefreshRetryMs = undefined;
    this.#refreshRetryMs = REFRESH_RETRY_BASE_MS;
    this.#stopTaskEventStream();
    this.#retainedCount = 0;
    this.#subscriptions.clear();
    this.#stopLocalDataRecovery();
    this.#conditionalResources.clear();
    this.#degradedCacheFingerprints.clear();
    this.#liveProjections.clear();
    this.#recurringInput = undefined;
    this.#traversals.clear();
  }

  retain(sessionValue: SessionProductLease): void {
    const session = this.#activate(sessionValue);
    this.#retainedCount += 1;
    this.#scheduleRefresh(session);
  }

  release(sessionValue: SessionProductLease): void {
    const session = sessionProductLeaseSchema.parse(sessionValue);
    if (
      !this.#activeSession ||
      !sameSessionProductLease(this.#activeSession, session)
    ) {
      return;
    }

    this.#retainedCount = Math.max(0, this.#retainedCount - 1);
    this.#cancelUnusedScheduledRefresh();
  }

  get(sessionValue: SessionProductLease): ProductInboxStateEnvelope {
    const session = this.#activate(sessionValue);
    return this.#settleForDelivery(this.#stateFor(session));
  }

  subscribe(
    sessionValue: SessionProductLease,
    listener: ProductInboxStateListener
  ): () => void {
    const session = this.#activate(sessionValue);
    if (this.#subscriptions.size >= this.#maxSubscribers) {
      throw new ProductInboxRuntimeFailure(
        "subscriber_limit",
        "ProductInbox subscriber limit reached."
      );
    }

    const subscription = { listener, session };
    this.#subscriptions.add(subscription);
    try {
      listener(this.#settleForDelivery(this.#stateFor(session)));
    } catch {
      // Replay-last delivery cannot let one host observer break registration.
    }
    this.#scheduleRefresh(session);

    return () => {
      this.#subscriptions.delete(subscription);
      this.#cancelUnusedScheduledRefresh();
    };
  }

  refresh(
    inputValue: ProductInboxRefreshInput | SessionProductLease,
    callerSignal?: AbortSignal
  ): Promise<ProductInboxStateEnvelope> {
    const input = normalizeRefreshInput(inputValue, this.#limit);
    const session = this.#activate(input.session);
    const request = {
      ...input,
      ...(callerSignal ? { callerSignal } : {}),
      session,
    };
    this.#recurringInput = recurringRefreshInput(request);
    this.#cancelScheduled?.();
    this.#cancelScheduled = undefined;
    this.#scheduledDelayMs = undefined;
    const inFlight = this.#inFlight;
    if (inFlight?.key === request.key) {
      return inFlight.promise;
    }

    const intentEpoch = ++this.#intentEpoch;
    const currentRequest = { ...request, intentEpoch };
    const promise = this.#refreshAndPublish(currentRequest).finally(() => {
      if (this.#inFlight?.promise === promise) {
        this.#inFlight = undefined;
      }
      // Scheduled here rather than in the failing read itself: this refresh is
      // still the in-flight one while it settles, and demand-gated scheduling
      // must see the slot free.
      const retryMs = this.#pendingRefreshRetryMs;
      this.#pendingRefreshRetryMs = undefined;
      if (retryMs !== undefined) this.#scheduleRefresh(session, retryMs);
    });
    this.#inFlight = { key: request.key, promise, session };
    return promise;
  }

  #activate(sessionValue: SessionProductLease): SessionProductLease {
    const session = sessionProductLeaseSchema.parse(sessionValue);
    this.#assertCurrentSessionLease(session);

    if (this.#activeSession && sameSessionProductLease(this.#activeSession, session)) {
      return session;
    }

    this.#cancelScheduled?.();
    this.#cancelScheduled = undefined;
    this.#scheduledDelayMs = undefined;
    this.#pendingRefreshRetryMs = undefined;
    this.#refreshRetryMs = REFRESH_RETRY_BASE_MS;
    this.#stopTaskEventStream();
    this.#intentEpoch += 1;
    this.#activeSession = session;
    this.#recurringInput = { limit: this.#limit, session };
    this.#retainedCount = 0;
    this.#state = initialEnvelope(session);
    this.#stateFingerprint = undefined;
    this.#conditionalResources.clear();
    this.#degradedCacheFingerprints.clear();
    this.#liveProjections.clear();
    this.#traversals.clear();

    for (const subscription of this.#subscriptions) {
      if (!sameSessionProductLease(subscription.session, session)) {
        this.#subscriptions.delete(subscription);
      }
    }
    return session;
  }

  #scheduleRefresh(session: SessionProductLease, delayMs = 0): void {
    if (!this.#hasDemandFor(session)) return;
    if (this.#inFlight && sameSessionProductLease(this.#inFlight.session, session)) {
      return;
    }
    // One timer slot, earliest deadline wins. Demand-driven refreshes ask for
    // 0 ms; a retry's backoff must not become their floor.
    if (this.#cancelScheduled) {
      if (delayMs >= (this.#scheduledDelayMs ?? 0)) return;
      this.#cancelScheduled();
      this.#cancelScheduled = undefined;
      this.#scheduledDelayMs = undefined;
    }

    let fired = false;
    let cancel = noop;
    cancel = this.#schedule(() => {
      fired = true;
      if (this.#cancelScheduled === cancel) {
        this.#cancelScheduled = undefined;
        this.#scheduledDelayMs = undefined;
      }
      if (!this.#hasDemandFor(session)) {
        return;
      }
      try {
        const input =
          this.#recurringInput &&
          sameSessionProductLease(this.#recurringInput.session, session)
            ? this.#recurringInput
            : { session };
        void this.refresh(input).catch(() => {
          // State publication and explicit refresh callers carry the result.
        });
      } catch {
        // A synchronously stale scheduled lease is simply no longer demand.
      }
    }, delayMs);
    if (fired) return;
    this.#cancelScheduled = cancel;
    this.#scheduledDelayMs = delayMs;
  }

  #cancelUnusedScheduledRefresh(): void {
    const activeSession = this.#activeSession;
    if (activeSession && this.#hasDemandFor(activeSession)) return;

    this.#cancelScheduled?.();
    this.#cancelScheduled = undefined;
    this.#scheduledDelayMs = undefined;
    // Demand ended: the next consumer starts its own recovery ramp rather than
    // inheriting the ceiling this one walked up to.
    this.#refreshRetryMs = REFRESH_RETRY_BASE_MS;
    this.#stopTaskEventStream();
  }

  #hasSubscriberFor(session: SessionProductLease): boolean {
    for (const subscription of this.#subscriptions) {
      if (sameSessionProductLease(subscription.session, session)) return true;
    }
    return false;
  }

  #hasDemandFor(session: SessionProductLease): boolean {
    return (
      !!this.#activeSession &&
      sameSessionProductLease(this.#activeSession, session) &&
      snapshotMatchesSessionProductLease(this.#authority.getSnapshot(), session) &&
      (this.#retainedCount > 0 || this.#hasSubscriberFor(session))
    );
  }

  async #refreshAndPublish(
    input: NormalizedRefreshInput
  ): Promise<ProductInboxStateEnvelope> {
    const recovery: RefreshRecoveryContext = {
      targetGroupId: undefined,
      targetGroupResolved: false,
    };
    try {
      const live = await this.#loadLive(input, recovery);
      this.#assertCurrentRefresh(input);
      this.#refreshRetryMs = REFRESH_RETRY_BASE_MS;
      if (
        this.#state &&
        this.#stateFingerprint === live.fingerprint &&
        sameSessionProductLease(this.#state.session, input.session)
      ) {
        const current = this.#settleForDelivery(this.#state);
        this.#ensureTaskEventStream(input.session, live.groupId);
        return current;
      }
      const published = this.#publish(input.session, live.snapshot, live.fingerprint);
      this.#ensureTaskEventStream(input.session, live.groupId);
      return published;
    } catch (error) {
      if (isSettlementFailure(error)) throw error;
      const fallback = await this.#loadCacheFallback(input, error);
      this.#assertCurrentRefresh(input);
      // A Group stream owns recovery only for a read of that same Group: its
      // reconnect resync cannot repair a newly selected Group. Before the
      // Workspace page settles, retain the existing same-stream assumption;
      // after it settles, bind ownership to the exact selected Group. No owner
      // leaves the cache projection with nothing to wake it, so use the bounded
      // retry rather than introducing list polling.
      const streamOwnsRecovery = recovery.targetGroupResolved
        ? recovery.targetGroupId !== undefined &&
          this.#taskEventGroupId === recovery.targetGroupId
        : this.#taskEventGroupId !== undefined;
      if (!streamOwnsRecovery) {
        this.#pendingRefreshRetryMs = this.#refreshRetryMs;
        this.#refreshRetryMs = Math.min(this.#refreshRetryMs * 2, REFRESH_RETRY_MAX_MS);
      }
      return this.#publish(input.session, fallback);
    }
  }

  async #loadLive(
    input: NormalizedRefreshInput,
    recovery: RefreshRecoveryContext
  ): Promise<LiveProjection> {
    const { cursor, limit, session, workspaceId } = input;
    const { credential, principalId } = this.#acquireCredential(session);
    const workspacesResponse = await this.#requestJson(
      credential,
      new URL("/v1/comma/workspaces", session.audience),
      salixProductWorkspacePageSchema,
      input.callerSignal
    );
    const workspacesPage = workspacesResponse.value;
    this.#settleCredential(session, credential);
    this.#assertCurrentRefresh(input);

    const activeWorkspace = selectActiveWorkspace(workspacesPage.data, workspaceId);
    recovery.targetGroupId = activeWorkspace?.group_id;
    recovery.targetGroupResolved = true;
    const conversationsResponse = activeWorkspace
      ? await this.#requestJson(
          credential,
          conversationListUrl(
            session.audience,
            activeWorkspace.group_id,
            limit,
            cursor
          ),
          salixProductConversationPageSchema,
          input.callerSignal
        )
      : undefined;
    let conversationsPage = conversationsResponse?.value;
    if (activeWorkspace && conversationsPage && input.conversationIds?.length) {
      const exactUrl = new URL(
        `/v1/comma/groups/${encodeURIComponent(activeWorkspace.group_id)}/task-summaries`,
        session.audience
      );
      exactUrl.searchParams.set("ids", input.conversationIds.join(","));
      const exact = await this.#requestJson(
        credential,
        exactUrl,
        salixProductConversationPageSchema,
        input.callerSignal
      );
      const exactIds = new Set(input.conversationIds);
      conversationsPage = {
        ...conversationsPage,
        data: [
          ...conversationsPage.data.filter((item) => !exactIds.has(item.id)),
          ...exact.value.data,
        ],
      };
    }
    this.#settleCredential(session, credential);
    this.#assertCurrentRefresh(input);

    const workspaces = workspacesPage.data;
    const conversations = conversationsPage?.data ?? [];
    assertConversationGroup(conversations, activeWorkspace);
    assertUsableNextCursor(conversationsPage);
    const fingerprint = liveProjectionFingerprint({
      conversationsPage,
      input,
      workspacesPage,
    });
    const previousProjection = this.#liveProjections.get(input.key);
    if (previousProjection?.fingerprint === fingerprint) {
      this.#assertCurrentSessionLease(session);
      return previousProjection;
    }
    const utilityUnavailableProjection = () => ({
      fingerprint: `${fingerprint}\nutility_unavailable`,
      ...(activeWorkspace ? { groupId: activeWorkspace.group_id } : {}),
      snapshot: liveSnapshot({
        activeWorkspace,
        conversations,
        errorCode: "utility_unavailable" as const,
        now: this.#now,
        page: conversationsPage,
        workspaces,
      }),
    });
    if (this.#degradedCacheFingerprints.get(input.key) === fingerprint) {
      this.#assertCurrentSessionLease(session);
      return utilityUnavailableProjection();
    }
    const cacheProjection =
      activeWorkspace && conversationsPage
        ? this.#conversationCacheProjection({
            activeWorkspace,
            conversations,
            cursor,
            page: conversationsPage,
            principalId,
            session,
          })
        : undefined;
    const cacheInput = productInboxCacheInput({
      activeWorkspace,
      audience: session.audience,
      conversationMode: cacheProjection?.mode ?? "replace",
      conversations: cacheProjection?.conversations ?? [],
      principalId,
      session,
      workspaceMode: workspacesPage.has_more === true ? "merge" : "replace",
      workspaces,
    });

    this.#assertCurrentRefresh(input);
    try {
      await this.#localData.applyProductInboxSync(cacheInput);
      this.#assertCurrentRefresh(input);
    } catch (error) {
      if (isStaleStorageWrite(error)) {
        throw staleSessionFailure();
      }
      this.#assertCurrentRefresh(input);
      if (this.#localData.health().status === "degraded") {
        setBoundedMap(this.#degradedCacheFingerprints, input.key, fingerprint);
      }
      return utilityUnavailableProjection();
    }

    this.#degradedCacheFingerprints.delete(input.key);
    const projection = {
      fingerprint,
      ...(activeWorkspace ? { groupId: activeWorkspace.group_id } : {}),
      snapshot: liveSnapshot({
        activeWorkspace,
        conversations,
        now: this.#now,
        page: conversationsPage,
        workspaces,
      }),
    };
    setBoundedMap(this.#liveProjections, input.key, projection);
    return projection;
  }

  #ensureTaskEventStream(
    session: SessionProductLease,
    groupId: string | undefined
  ): void {
    if (!groupId || !this.#hasDemandFor(session)) {
      this.#stopTaskEventStream();
      return;
    }
    if (this.#taskEventGroupId === groupId && this.#taskEventController) return;

    this.#stopTaskEventStream();
    const controller = new AbortController();
    const epoch = ++this.#taskEventEpoch;
    this.#taskEventController = controller;
    this.#taskEventGroupId = groupId;
    this.#taskEventReconnectMs = 1_000;
    void this.#runTaskEventStream(session, groupId, epoch, controller);
  }

  async #runTaskEventStream(
    session: SessionProductLease,
    groupId: string,
    epoch: number,
    controller: AbortController
  ): Promise<void> {
    try {
      const { credential } = this.#acquireCredential(session);
      const url = conversationListEventsUrl(session.audience, groupId);
      if (url.origin !== credential.audience) {
        throw new ProductInboxRuntimeFailure(
          "invalid_response",
          "ProductInbox event stream escaped the credential audience."
        );
      }

      const signal = AbortSignal.any([credential.signal, controller.signal]);
      const response = await this.#fetch(url.toString(), {
        credentials: requestCredentials(credential),
        headers: {
          ...credential.request?.headers,
          accept: "text/event-stream",
          ...(credential.token ? { authorization: `Bearer ${credential.token}` } : {}),
        },
        method: "GET",
        redirect: "manual",
        signal,
      });
      if (signal.aborted) return;
      this.#settleCredential(session, credential);

      if (response.status >= 300 && response.status < 400) {
        throw new ProductInboxRuntimeFailure(
          "redirect_rejected",
          "ProductInbox rejected an event-stream redirect."
        );
      }
      const rejection = await sessionRejectionStatus(
        response,
        this.#reportSessionChanged !== undefined
      );
      if (rejection) {
        await this.#reportSessionRejection(credential, rejection);
        return;
      }
      if (!response.ok) {
        throw new ProductInboxRuntimeFailure(
          "http_error",
          `ProductInbox event stream failed with HTTP ${response.status}.`
        );
      }
      if (!response.body) {
        throw new ProductInboxRuntimeFailure(
          "invalid_response",
          "ProductInbox event stream did not include a body."
        );
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      try {
        while (!signal.aborted) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          buffer = drainTaskEventBuffer(buffer, (eventValue) => {
            const event = taskListInvalidationSchema.parse(eventValue);
            if (event.group_id !== groupId) {
              throw new ProductInboxRuntimeFailure(
                "invalid_response",
                "ProductInbox event stream crossed its canonical Group boundary."
              );
            }
            if (
              epoch !== this.#taskEventEpoch ||
              (event.type !== "conversation_list_resync_required" &&
                event.version === this.#taskEventLastVersion)
            ) {
              return;
            }
            this.#taskEventLastVersion = event.version;
            this.#queueTaskEventRefresh(session, groupId, epoch);
          });
        }
        buffer += decoder.decode();
        drainTaskEventBuffer(buffer, (value) => {
          const event = taskListInvalidationSchema.parse(value);
          if (
            event.group_id === groupId &&
            epoch === this.#taskEventEpoch &&
            (event.type === "conversation_list_resync_required" ||
              event.version !== this.#taskEventLastVersion)
          ) {
            this.#taskEventLastVersion = event.version;
            this.#queueTaskEventRefresh(session, groupId, epoch);
          }
        });
      } finally {
        reader.releaseLock();
      }

      if (!signal.aborted) this.#scheduleTaskEventReconnect(session, groupId, epoch, 0);
    } catch {
      if (controller.signal.aborted || epoch !== this.#taskEventEpoch) return;
      const delayMs = this.#taskEventReconnectMs;
      this.#taskEventReconnectMs = Math.min(
        this.#taskEventReconnectMs * 2,
        TASK_EVENT_RECONNECT_MAX_MS
      );
      this.#scheduleTaskEventReconnect(session, groupId, epoch, delayMs);
    } finally {
      if (this.#taskEventController === controller) {
        this.#taskEventController = undefined;
      }
    }
  }

  #queueTaskEventRefresh(
    session: SessionProductLease,
    groupId: string,
    epoch: number
  ): void {
    if (this.#taskEventRefreshPending) {
      this.#taskEventRefreshQueued = true;
      return;
    }
    this.#taskEventRefreshPending = true;

    void (async () => {
      try {
        do {
          this.#taskEventRefreshQueued = false;
          const inFlight = this.#inFlight;
          if (inFlight && sameSessionProductLease(inFlight.session, session)) {
            await inFlight.promise.catch(noop);
          }
          if (
            epoch !== this.#taskEventEpoch ||
            this.#taskEventGroupId !== groupId ||
            !this.#hasDemandFor(session)
          ) {
            return;
          }
          const input =
            this.#recurringInput &&
            sameSessionProductLease(this.#recurringInput.session, session)
              ? this.#recurringInput
              : { session };
          const settled = await this.refresh(input).catch(() => undefined);
          if (settled?.snapshot.source !== "live-sync") {
            this.#restartTaskEventStreamAfterUnsettledRead(session, groupId, epoch);
            return;
          }
          this.#taskEventReconnectMs = 1_000;
        } while (
          this.#taskEventRefreshQueued &&
          epoch === this.#taskEventEpoch &&
          this.#taskEventGroupId === groupId &&
          this.#hasDemandFor(session)
        );
      } finally {
        if (epoch === this.#taskEventEpoch) {
          this.#taskEventRefreshPending = false;
          this.#taskEventRefreshQueued = false;
        }
      }
    })();
  }

  /**
   * An SSE version is only a reread hint. If its bounded canonical read did
   * not settle live, reconnect the one active Group stream with bounded
   * backoff so its mandatory resync barrier replays the still-unsettled hint.
   * This owns at most one stream and one reconnect timer per runtime; it is
   * not a timer-driven list scan.
   */
  #restartTaskEventStreamAfterUnsettledRead(
    session: SessionProductLease,
    groupId: string,
    epoch: number
  ): void {
    if (
      epoch !== this.#taskEventEpoch ||
      this.#taskEventGroupId !== groupId ||
      !this.#hasDemandFor(session)
    ) {
      return;
    }

    this.#taskEventLastVersion = undefined;
    this.#taskEventController?.abort();
    this.#taskEventController = undefined;
    const delayMs = this.#taskEventReconnectMs;
    this.#taskEventReconnectMs = Math.min(
      this.#taskEventReconnectMs * 2,
      TASK_EVENT_RECONNECT_MAX_MS
    );
    this.#scheduleTaskEventReconnect(session, groupId, epoch, delayMs);
  }

  #scheduleTaskEventReconnect(
    session: SessionProductLease,
    groupId: string,
    epoch: number,
    delayMs: number
  ): void {
    if (
      this.#cancelTaskEventReconnect ||
      epoch !== this.#taskEventEpoch ||
      !this.#hasDemandFor(session)
    ) {
      return;
    }

    let fired = false;
    let cancel = noop;
    cancel = this.#schedule(() => {
      fired = true;
      if (this.#cancelTaskEventReconnect === cancel) {
        this.#cancelTaskEventReconnect = undefined;
      }
      if (
        epoch !== this.#taskEventEpoch ||
        this.#taskEventGroupId !== groupId ||
        !this.#hasDemandFor(session)
      ) {
        return;
      }
      const controller = new AbortController();
      this.#taskEventController = controller;
      void this.#runTaskEventStream(session, groupId, epoch, controller);
    }, delayMs);
    if (!fired) this.#cancelTaskEventReconnect = cancel;
  }

  #stopTaskEventStream(): void {
    this.#taskEventEpoch += 1;
    this.#taskEventController?.abort();
    this.#taskEventController = undefined;
    this.#cancelTaskEventReconnect?.();
    this.#cancelTaskEventReconnect = undefined;
    this.#taskEventGroupId = undefined;
    this.#taskEventLastVersion = undefined;
    this.#taskEventReconnectMs = 1_000;
    this.#taskEventRefreshPending = false;
    this.#taskEventRefreshQueued = false;
  }

  #conversationCacheProjection({
    activeWorkspace,
    conversations,
    cursor,
    page,
    principalId,
    session,
  }: {
    activeWorkspace: SalixProductWorkspace;
    conversations: SalixProductConversation[];
    cursor?: string | undefined;
    page: {
      has_more?: boolean | undefined;
      next_cursor?: string | null | undefined;
    };
    principalId: string;
    session: SessionProductLease;
  }): {
    conversations: SalixProductConversation[];
    mode: "merge" | "replace";
  } {
    const key = conversationTraversalKey(session, principalId, activeWorkspace.id);

    if (!cursor) {
      if (page.has_more === true) {
        this.#traversals.set(key, {
          conversations: structuredClone(conversations),
          nextCursor: page.next_cursor!,
        });
        return { conversations, mode: "merge" };
      }
      this.#traversals.delete(key);
      return { conversations, mode: "replace" };
    }

    const traversal = this.#traversals.get(key);
    if (traversal?.nextCursor !== cursor) {
      return { conversations, mode: "merge" };
    }

    const accumulated = dedupeConversations([
      ...traversal.conversations,
      ...conversations,
    ]);
    if (page.has_more === true) {
      this.#traversals.set(key, {
        conversations: accumulated,
        nextCursor: page.next_cursor!,
      });
      return { conversations, mode: "merge" };
    }

    this.#traversals.delete(key);
    return { conversations: accumulated, mode: "replace" };
  }

  async #loadCacheFallback(
    input: NormalizedRefreshInput,
    liveError: unknown
  ): Promise<ProductInboxSnapshot> {
    const { cursor, limit, session, workspaceId } = input;
    const principalId = this.#verifiedPrincipalId(session);
    this.#assertCurrentRefresh(input);

    try {
      const cachedWorkspaces = await this.#localData.listProductWorkspaces({
        audience: session.audience,
        principalId,
      });
      this.#assertCurrentRefresh(input);
      assertCacheWorkspacePartition(cachedWorkspaces, session, principalId);
      const activeWorkspace = selectActiveWorkspace(cachedWorkspaces, workspaceId);
      const cachedItems =
        activeWorkspace && !cursor
          ? await this.#localData.listProductInboxItems({
              audience: session.audience,
              limit,
              principalId,
              workspaceId: activeWorkspace.id,
            })
          : [];
      this.#assertCurrentRefresh(input);
      assertCacheItemPartition(cachedItems, session);

      return {
        ...(activeWorkspace ? { activeWorkspaceId: activeWorkspace.id } : {}),
        errorCode: snapshotErrorCode(liveError),
        items: cachedItems.map(cacheItem),
        source:
          cachedItems.length > 0 || cachedWorkspaces.length > 0 ? "cache" : "error",
        workspaces: cachedWorkspaces.map(({ groupId, id, name }) => ({
          group_id: groupId,
          id,
          name,
        })),
      };
    } catch (error) {
      if (isSettlementFailure(error)) throw error;
      this.#assertCurrentRefresh(input);
      return {
        errorCode: "utility_unavailable",
        items: [],
        source: "error",
      };
    }
  }

  async #requestJson<Schema extends z.ZodType>(
    credential: ProductCredentialLease,
    url: URL,
    schema: Schema,
    callerSignal?: AbortSignal
  ): Promise<{ notModified: boolean; value: z.output<Schema> }> {
    if (url.origin !== credential.audience) {
      throw new ProductInboxRuntimeFailure(
        "invalid_response",
        "ProductInbox request escaped the credential audience."
      );
    }
    const resourceKey = url.toString();
    const cached = this.#conditionalResources.get(resourceKey);
    const headers: Record<string, string> = {
      ...credential.request?.headers,
      accept: "application/json",
    };
    if (credential.token) headers.authorization = `Bearer ${credential.token}`;
    if (cached?.etag) headers["if-none-match"] = cached.etag;

    const result = await this.#runWithHttpDeadline(
      credential.signal,
      callerSignal,
      async (signal) => {
        const response = await this.#fetch(resourceKey, {
          credentials: requestCredentials(credential),
          headers,
          method: "GET",
          redirect: "manual",
          signal,
        });
        throwIfRequestAborted(signal);
        this.#settleCredential(credentialIdentity(credential), credential);

        if (response.status === 304) {
          const parsed = schema.safeParse(cached?.value);
          if (!parsed.success) {
            throw new ProductInboxRuntimeFailure(
              "invalid_response",
              "ProductInbox received 304 without a valid lease-local representation."
            );
          }
          throwIfRequestAborted(signal);
          this.#settleCredential(credentialIdentity(credential), credential);
          return {
            kind: "value" as const,
            value: { notModified: true, value: parsed.data },
          };
        }
        if (response.status >= 300 && response.status < 400) {
          throw new ProductInboxRuntimeFailure(
            "redirect_rejected",
            "ProductInbox rejected an HTTP redirect."
          );
        }
        const rejection = await sessionRejectionStatus(
          response,
          this.#reportSessionChanged !== undefined
        );
        if (rejection) {
          return { kind: "session_rejection" as const, status: rejection };
        }
        if (!response.ok) {
          throw new ProductInboxRuntimeFailure(
            "http_error",
            `ProductInbox request failed with HTTP ${response.status}.`
          );
        }

        const body = await response.json();
        throwIfRequestAborted(signal);
        this.#settleCredential(credentialIdentity(credential), credential);
        if (credential.token && containsReflectedSecret(body, credential.token)) {
          throw new ProductInboxRuntimeFailure(
            "invalid_response",
            "ProductInbox rejected a response that reflected its credential."
          );
        }
        const parsed = schema.safeParse(body);
        if (!parsed.success) {
          throw new ProductInboxRuntimeFailure(
            "invalid_response",
            "ProductInbox received a response outside the strict Salix contract."
          );
        }
        throwIfRequestAborted(signal);
        this.#settleCredential(credentialIdentity(credential), credential);
        const etag = normalizedEtag(response.headers.get("etag"));
        setBoundedMap(this.#conditionalResources, resourceKey, {
          ...(etag ? { etag } : {}),
          value: structuredClone(parsed.data),
        });
        return {
          kind: "value" as const,
          value: { notModified: false, value: parsed.data },
        };
      }
    );
    if (result.kind === "session_rejection") {
      // The host reporter closes its product gate synchronously. Never publish
      // a cache fallback under the rejected lease; lifecycle cleanup owns its
      // own deadline and must not inherit the response-body timer.
      await this.#reportSessionRejection(credential, result.status);
      throw staleSessionFailure();
    }
    return result.value;
  }

  async #reportSessionRejection(
    credential: ProductCredentialLease,
    status: 401 | 409
  ): Promise<void> {
    if (status === 401) {
      await this.#reportUnauthorized(credential).catch(noop);
      return;
    }
    await this.#reportSessionChanged?.(credential).catch(noop);
  }

  #runWithHttpDeadline<T>(
    credentialSignal: AbortSignal,
    callerSignal: AbortSignal | undefined,
    run: (signal: AbortSignal) => Promise<T>
  ): Promise<T> {
    const deadline = new AbortController();
    const signals = callerSignal
      ? [credentialSignal, callerSignal, deadline.signal]
      : [credentialSignal, deadline.signal];
    const signal = AbortSignal.any(signals);

    return new Promise<T>((resolve, reject) => {
      let settled = false;
      let cancelDeadline = noop;
      const cleanup = () => {
        cancelDeadline();
        signal.removeEventListener("abort", rejectAborted);
      };
      const settleRejected = (error: unknown) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error);
      };
      const rejectAborted = () => {
        settleRejected(
          new ProductInboxHttpRequestError(
            deadline.signal.aborted
              ? `ProductInbox HTTP request timed out after ${this.#requestTimeoutMs} ms.`
              : "ProductInbox HTTP request was cancelled."
          )
        );
      };

      signal.addEventListener("abort", rejectAborted, { once: true });
      cancelDeadline = this.#scheduleDeadline(() => {
        deadline.abort();
      }, this.#requestTimeoutMs);
      if (settled) {
        cancelDeadline();
        return;
      }
      if (signal.aborted) {
        rejectAborted();
        return;
      }

      let pending: Promise<T>;
      try {
        pending = run(signal);
      } catch (error) {
        settleRejected(error);
        return;
      }
      void pending.then((value) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      }, settleRejected);
    });
  }

  #acquireCredential(session: SessionProductLease): {
    credential: ProductCredentialLease;
    principalId: string;
  } {
    this.#assertCurrentSessionLease(session);
    const credential = this.#authority.acquireProductCredential({
      authorityInstanceId: session.authorityInstanceId,
      expectedAudience: session.audience,
      expectedSessionId: session.sessionId,
      generation: session.generation,
    });
    if (!credential) {
      throw new ProductInboxRuntimeFailure(
        "credential_unavailable",
        "ProductInbox credential is unavailable for the exact session lease."
      );
    }
    this.#settleCredential(session, credential);
    return {
      credential,
      principalId: this.#verifiedPrincipalId(session),
    };
  }

  #verifiedPrincipalId(session: SessionProductLease): string {
    const snapshot = this.#authority.getSnapshot();
    if (
      snapshot.phase !== "signed_in" ||
      !snapshotMatchesSessionProductLease(snapshot, session)
    ) {
      throw staleSessionFailure();
    }
    return snapshot.principal.userId;
  }

  #settleCredential(
    session: SessionProductLease,
    credential: ProductCredentialLease
  ): void {
    if (
      !sameSessionProductLease(session, credentialIdentity(credential)) ||
      !this.#authority.isCurrentProductCredential(credential)
    ) {
      throw staleSessionFailure();
    }
    this.#assertCurrentSessionLease(session);
  }

  #assertCurrentSessionLease(session: SessionProductLease): void {
    if (!snapshotMatchesSessionProductLease(this.#authority.getSnapshot(), session)) {
      throw staleSessionFailure();
    }
  }

  #assertCurrentRefresh(input: NormalizedRefreshInput): void {
    this.#assertCurrentSessionLease(input.session);
    if (input.intentEpoch !== this.#intentEpoch) {
      throw supersededRefreshFailure();
    }
  }

  #stateFor(session: SessionProductLease): ProductInboxStateEnvelope {
    if (!this.#state || !sameSessionProductLease(this.#state.session, session)) {
      this.#state = initialEnvelope(session);
    }
    return this.#state;
  }

  #publish(
    session: SessionProductLease,
    snapshot: ProductInboxSnapshot,
    fingerprint?: string | undefined
  ): ProductInboxStateEnvelope {
    this.#assertCurrentSessionLease(session);
    const envelope = productInboxStateEnvelopeSchema.parse({
      session,
      snapshot,
    });
    this.#assertCurrentSessionLease(session);
    this.#state = envelope;
    this.#stateFingerprint = fingerprint;

    const deliverable = this.#settleForDelivery(envelope);
    for (const subscription of this.#subscriptions) {
      if (!sameSessionProductLease(subscription.session, session)) continue;
      try {
        subscription.listener(deliverable);
      } catch {
        // One host observer cannot roll back the canonical Main projection.
      }
    }
    return deliverable;
  }

  #settleForDelivery(
    envelopeValue: ProductInboxStateEnvelope
  ): ProductInboxStateEnvelope {
    const envelope = productInboxStateEnvelopeSchema.parse(envelopeValue);
    this.#assertCurrentSessionLease(envelope.session);
    return envelope;
  }
}

function initialEnvelope(session: SessionProductLease): ProductInboxStateEnvelope {
  return productInboxStateEnvelopeSchema.parse({
    session,
    snapshot: {
      items: [],
      source: "unavailable",
    },
  });
}

function productInboxCacheInput({
  activeWorkspace,
  audience,
  conversationMode,
  conversations,
  principalId,
  session,
  workspaceMode,
  workspaces,
}: {
  activeWorkspace: SalixProductWorkspace | undefined;
  audience: string;
  conversationMode: "merge" | "replace";
  conversations: SalixProductConversation[];
  principalId: string;
  session: SessionProductLease;
  workspaceMode: "merge" | "replace";
  workspaces: SalixProductWorkspace[];
}): ProductInboxCacheApplyInput {
  return {
    audience,
    ...(activeWorkspace
      ? {
          conversations: {
            items: conversations.map((conversation) =>
              conversationCacheInput(
                conversation,
                activeWorkspace.id,
                audience,
                principalId
              )
            ),
            mode: conversationMode,
            workspaceId: activeWorkspace.id,
          },
        }
      : {}),
    principalId,
    session,
    workspaces: {
      items: workspaces.map((workspace) =>
        workspaceCacheInput(workspace, audience, principalId)
      ),
      mode: workspaceMode,
    },
  };
}

function workspaceCacheInput(
  workspace: SalixProductWorkspace,
  audience: string,
  principalId: string
): ProductInboxWorkspaceRecord {
  return {
    audience,
    groupId: workspace.group_id,
    id: workspace.id,
    name: workspace.name,
    principalId,
    raw: {
      group_id: workspace.group_id,
      id: workspace.id,
      name: workspace.name,
    },
  };
}

function conversationCacheInput(
  conversation: SalixProductConversation,
  fallbackWorkspaceId: string,
  audience: string,
  principalId: string
): ProductInboxConversationRecord {
  return {
    audience,
    groupId: conversation.group_id,
    createdAt: normalizeEpochMilliseconds(conversation.created_at),
    ...(conversation.freshness?.state
      ? { freshness: conversation.freshness.state }
      : {}),
    id: conversation.id,
    kind: conversation.kind,
    principalId,
    raw: safeConversationRaw(conversation),
    status: conversation.status,
    title: conversation.title,
    updatedAt: normalizeEpochMilliseconds(conversation.updated_at),
    workspaceId: fallbackWorkspaceId,
  };
}

function safeConversationRaw(
  conversation: SalixProductConversation
): ProductInboxJsonValue {
  return {
    ...(conversation.meeting ? { meeting: { phase: conversation.meeting.phase } } : {}),
    ...(conversation.activity_status === undefined
      ? {}
      : { activity_status: conversation.activity_status }),
    ...(conversation.created_at === undefined
      ? {}
      : { created_at: conversation.created_at }),
    ...(conversation.freshness === undefined
      ? {}
      : { freshness: { state: conversation.freshness.state } }),
    ...(conversation.archive_availability === undefined
      ? {}
      : { archive_availability: conversation.archive_availability }),
    group_id: conversation.group_id,
    id: conversation.id,
    kind: conversation.kind,
    ...(conversation.origin === undefined ? {} : { origin: conversation.origin }),
    ...(conversation.labels === undefined ? {} : { labels: conversation.labels }),
    ...(conversation.client_platform === undefined
      ? {}
      : { client_platform: conversation.client_platform }),
    status: conversation.status,
    title: conversation.title,
    ...(conversation.updated_at === undefined
      ? {}
      : { updated_at: conversation.updated_at }),
  };
}

function liveSnapshot({
  activeWorkspace,
  conversations,
  errorCode,
  now,
  page,
  workspaces,
}: {
  activeWorkspace: SalixProductWorkspace | undefined;
  conversations: SalixProductConversation[];
  errorCode?: ProductInboxSnapshot["errorCode"] | undefined;
  now: () => number;
  page:
    | {
        has_more?: boolean | undefined;
        next_cursor?: string | null | undefined;
      }
    | undefined;
  workspaces: SalixProductWorkspace[];
}): ProductInboxSnapshot {
  return {
    ...(activeWorkspace ? { activeWorkspaceId: activeWorkspace.id } : {}),
    ...(errorCode ? { errorCode } : {}),
    ...(page?.has_more === undefined ? {} : { hasMore: page.has_more }),
    items:
      activeWorkspace === undefined
        ? []
        : conversations.map((conversation) => liveItem(conversation, activeWorkspace)),
    lastSyncedAt: now(),
    ...(page?.next_cursor ? { nextCursor: page.next_cursor } : {}),
    source: "live-sync",
    workspaces,
  };
}

function liveItem(
  conversation: SalixProductConversation,
  workspace: SalixProductWorkspace
): ProductInboxSnapshot["items"][number] {
  return {
    ...(conversation.meeting ? { meetingPhase: conversation.meeting.phase } : {}),
    archiveAvailability: conversation.archive_availability,
    archiveVersion: conversation.updated_at,
    conversationId: conversation.id,
    groupId: conversation.group_id,
    ...(conversation.freshness?.state
      ? { freshness: conversation.freshness.state }
      : {}),
    id: `${conversation.group_id}:${conversation.id}`,
    kind: conversation.kind,
    ...(conversation.origin === undefined ? {} : { origin: conversation.origin }),
    labels: conversation.labels ?? [],
    clientPlatform: conversation.client_platform,
    source: "salix.conversation",
    status: conversation.status,
    title: conversation.title,
    updatedAt:
      normalizeEpochMilliseconds(conversation.updated_at) ??
      normalizeEpochMilliseconds(conversation.created_at) ??
      0,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
  };
}

function cacheItem(
  item: ProductInboxStoredItem
): ProductInboxSnapshot["items"][number] {
  const cached = salixProductConversationWireSchema.safeParse(item.raw);
  return {
    ...(cached.success
      ? {
          ...(cached.data.meeting ? { meetingPhase: cached.data.meeting.phase } : {}),
          archiveAvailability: cached.data.archive_availability,
          archiveVersion: cached.data.updated_at,
          ...(cached.data.origin === undefined ? {} : { origin: cached.data.origin }),
          labels: cached.data.labels,
          clientPlatform: cached.data.client_platform,
        }
      : {}),
    conversationId: item.conversationId,
    groupId: item.groupId,
    ...(item.freshness ? { freshness: item.freshness } : {}),
    id: item.id,
    kind: item.kind,
    source: item.source,
    status: item.status,
    title: item.title,
    updatedAt: item.updatedAt,
    workspaceId: item.workspaceId,
    workspaceName: item.workspaceName,
  };
}

function conversationListUrl(
  audience: string,
  groupId: string,
  limit: number,
  cursor?: string | undefined
) {
  const url = new URL(
    `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations`,
    audience
  );
  url.searchParams.set("archive", "include");
  url.searchParams.set("limit", String(limit));
  if (cursor) url.searchParams.set("cursor", cursor);
  return url;
}

function conversationListEventsUrl(audience: string, groupId: string) {
  return new URL(
    `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/events`,
    audience
  );
}

function drainTaskEventBuffer(
  buffer: string,
  onEvent: (value: unknown) => void
): string {
  let next = buffer;
  let boundary = next.match(/\r?\n\r?\n/);

  while (boundary?.index !== undefined) {
    const raw = next.slice(0, boundary.index);
    next = next.slice(boundary.index + boundary[0].length);
    const data = raw
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice("data:".length).trimStart());
    if (data.length > 0) onEvent(JSON.parse(data.join("\n")));
    boundary = next.match(/\r?\n\r?\n/);
  }

  return next;
}

function normalizeRefreshInput(
  inputValue: ProductInboxRefreshInput | SessionProductLease,
  defaultLimit: number
): NormalizedRefreshInput {
  const parsed: ProductInboxRefreshInput =
    inputValue && typeof inputValue === "object" && "session" in inputValue
      ? productInboxRefreshInputSchema.parse(inputValue)
      : { session: sessionProductLeaseSchema.parse(inputValue) };
  const limit = parsed.limit ?? defaultLimit;
  const normalized = {
    ...(parsed.conversationIds
      ? { conversationIds: [...new Set(parsed.conversationIds)].toSorted() }
      : {}),
    ...(parsed.cursor ? { cursor: parsed.cursor } : {}),
    limit,
    session: parsed.session,
    ...(parsed.workspaceId ? { workspaceId: parsed.workspaceId } : {}),
  };
  return {
    ...normalized,
    intentEpoch: 0,
    key: `${refreshKey(normalized)}${normalized.conversationIds?.length ? `\nexact:${normalized.conversationIds.join(",")}` : ""}`,
  };
}

function recurringRefreshInput(input: NormalizedRefreshInput): RecurringRefreshInput {
  return {
    limit: input.limit,
    session: input.session,
    ...(input.workspaceId ? { workspaceId: input.workspaceId } : {}),
  };
}

function refreshKey({
  cursor,
  limit,
  session,
  workspaceId,
}: {
  cursor?: string | undefined;
  limit: number;
  session: SessionProductLease;
  workspaceId?: string | undefined;
}) {
  return [
    session.authorityInstanceId,
    String(session.generation),
    session.sessionId,
    session.audience,
    workspaceId ?? "",
    String(limit),
    cursor ?? "",
  ].join("\n");
}

function conversationTraversalKey(
  session: SessionProductLease,
  principalId: string,
  workspaceId: string
) {
  return [
    session.authorityInstanceId,
    String(session.generation),
    session.sessionId,
    session.audience,
    principalId,
    workspaceId,
  ].join("\n");
}

function liveProjectionFingerprint({
  conversationsPage,
  input,
  workspacesPage,
}: {
  conversationsPage:
    | {
        data: SalixProductConversation[];
        has_more?: boolean | undefined;
        next_cursor?: string | null | undefined;
      }
    | undefined;
  input: NormalizedRefreshInput;
  workspacesPage: {
    data: SalixProductWorkspace[];
    has_more?: boolean | undefined;
    next_cursor?: string | null | undefined;
  };
}): string {
  return `${input.key}\n${JSON.stringify({ conversationsPage, workspacesPage })}`;
}

function selectActiveWorkspace<T extends { id: string }>(
  workspaces: T[],
  preferredWorkspaceId?: string | undefined
) {
  return (
    workspaces.find((workspace) => workspace.id === preferredWorkspaceId) ??
    workspaces[0]
  );
}

function dedupeConversations(conversations: SalixProductConversation[]) {
  const byId = new Map<string, SalixProductConversation>();
  for (const conversation of conversations) {
    byId.set(conversation.id, conversation);
  }
  return [...byId.values()];
}

function containsReflectedSecret(value: unknown, secret: string): boolean {
  const pending = [value];
  let inspected = 0;
  while (pending.length > 0 && inspected < 20_000) {
    const current = pending.pop();
    inspected += 1;
    if (typeof current === "string" && current.includes(secret)) return true;
    if (Array.isArray(current)) {
      pending.push(...current);
      continue;
    }
    if (current && typeof current === "object") {
      pending.push(...Object.values(current));
    }
  }
  return inspected >= 20_000;
}

function normalizedEtag(value: string | null): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed || trimmed.length > 1_024) return undefined;
  return trimmed;
}

function setBoundedMap<Key, Value>(map: Map<Key, Value>, key: Key, value: Value): void {
  map.delete(key);
  map.set(key, value);
  while (map.size > MAX_CONDITIONAL_RESOURCES) {
    const oldest = map.keys().next().value as Key | undefined;
    if (oldest === undefined) return;
    map.delete(oldest);
  }
}

function credentialIdentity(credential: ProductCredentialLease): SessionProductLease {
  return {
    audience: credential.audience,
    authorityInstanceId: credential.authorityInstanceId,
    generation: credential.generation,
    sessionId: credential.sessionId,
  };
}

function requestCredentials(credential: ProductCredentialLease): RequestCredentials {
  return credential.request?.credentials ?? (credential.token ? "omit" : "include");
}

const sessionChangedResponseSchema = z.strictObject({
  error: z.literal("session_changed"),
});
const sessionProductLeaseUnavailableResponseSchema = z.strictObject({
  error: sessionAdmissionFailureSchema,
});

async function sessionRejectionStatus(
  response: Response,
  recognizesSessionChanged: boolean
): Promise<401 | 409 | undefined> {
  if (response.status === 401) return 401;
  if (response.status !== 409 || !recognizesSessionChanged) return undefined;
  const body = await response
    .clone()
    .json()
    .catch(() => undefined);
  return sessionChangedResponseSchema.safeParse(body).success ||
    sessionProductLeaseUnavailableResponseSchema.safeParse(body).success
    ? 409
    : undefined;
}

function normalizeEpochMilliseconds(timestamp: number | undefined) {
  if (timestamp === undefined) return undefined;
  return timestamp > 0 && timestamp < 10_000_000_000 ? timestamp * 1_000 : timestamp;
}

function snapshotErrorCode(
  error: unknown
): NonNullable<ProductInboxSnapshot["errorCode"]> {
  if (error instanceof ProductInboxRuntimeFailure) {
    if (
      error.code === "credential_unavailable" ||
      error.code === "stale_session_lease"
    ) {
      return "session_product_lease_unavailable";
    }
    if (error.code === "invalid_response" || error.code === "redirect_rejected") {
      return "protocol_mismatch";
    }
    if (error.code === "utility_unavailable") {
      return "utility_unavailable";
    }
  }
  if (error instanceof TypeError) return "network_unavailable";
  return "unknown";
}

function throwIfRequestAborted(signal: AbortSignal): void {
  if (!signal.aborted) return;
  throw new ProductInboxHttpRequestError(
    "ProductInbox HTTP request settled after cancellation."
  );
}

function assertUsableNextCursor(
  page:
    | {
        has_more?: boolean | undefined;
        next_cursor?: string | null | undefined;
      }
    | undefined
): void {
  if (page?.has_more !== true) return;
  if (page.next_cursor?.trim()) return;
  throw new ProductInboxRuntimeFailure(
    "invalid_response",
    "ProductInbox page declared more data without a usable cursor."
  );
}

function assertCacheWorkspacePartition(
  workspaces: ProductInboxWorkspaceRecord[],
  session: SessionProductLease,
  principalId: string
): void {
  if (
    workspaces.some(
      (workspace) =>
        workspace.audience !== session.audience || workspace.principalId !== principalId
    )
  ) {
    throw new ProductInboxRuntimeFailure(
      "utility_unavailable",
      "ProductInbox cache returned a workspace outside its requested partition."
    );
  }
}

function assertCacheItemPartition(
  items: ProductInboxStoredItem[],
  session: SessionProductLease
): void {
  if (items.some((item) => item.audience !== session.audience)) {
    throw new ProductInboxRuntimeFailure(
      "utility_unavailable",
      "ProductInbox cache returned an item outside its requested audience."
    );
  }
}

function isStaleStorageWrite(error: unknown): boolean {
  return (
    error instanceof Error &&
    error.name === "LocalDataWriteFailure" &&
    "code" in error &&
    error.code === "stale_session_lease"
  );
}

function isSettlementFailure(error: unknown): boolean {
  return (
    (error instanceof ProductInboxRuntimeFailure &&
      (error.code === "stale_session_lease" || error.code === "superseded_refresh")) ||
    isStaleStorageWrite(error)
  );
}

function staleSessionFailure() {
  return new ProductInboxRuntimeFailure(
    "stale_session_lease",
    "ProductInbox session lease is no longer current."
  );
}

function supersededRefreshFailure() {
  return new ProductInboxRuntimeFailure(
    "superseded_refresh",
    "ProductInbox refresh intent was superseded by a newer request."
  );
}

function scheduleTimeout(run: () => void, delayMs: number): () => void {
  const timeout = setTimeout(run, delayMs);
  return () => {
    clearTimeout(timeout);
  };
}

function noop() {}

function assertConversationGroup(
  conversations: SalixProductConversation[],
  workspace: SalixProductWorkspace | undefined
): void {
  if (!workspace && conversations.length === 0) return;
  if (!workspace) {
    throw new ProductInboxRuntimeFailure(
      "invalid_response",
      "Conversation page was returned without an active Group."
    );
  }
  if (
    conversations.some((conversation) => conversation.group_id !== workspace.group_id)
  ) {
    throw new ProductInboxRuntimeFailure(
      "invalid_response",
      "Conversation page crossed its canonical Group boundary."
    );
  }
}
