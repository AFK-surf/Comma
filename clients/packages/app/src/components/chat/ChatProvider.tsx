import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import type { CommaApiClient, CommaConversation } from "../../api";
import type { SessionProductLease } from "@comma/session-contract";
import { BridgeConversationChannel } from "../../runtime-chat/channel/BridgeConversationChannel";
import type { ChatChannel } from "../../runtime-chat/channel/ChatChannel";
import {
  ConversationChannel,
  idleConversationChannelState,
  normalizeServerMessages,
  type ConversationChannelState,
} from "./model/conversationChannel";

export class StaleChatSessionError extends Error {
  constructor() {
    super("The chat session is no longer active.");
    this.name = "StaleChatSessionError";
  }
}

export function isStaleChatSessionError(error: unknown) {
  return error instanceof StaleChatSessionError;
}

export type ChatRegistryLease = {
  channel: ChatChannel;
  release(): void;
};

export type ChatRegistryAttempt = {
  readonly signal: AbortSignal;
  isCurrent(): boolean;
  release(): void;
  retain(
    workspaceId: string,
    groupId: string,
    conversationId: string
  ): ChatRegistryLease;
  run<T>(
    operation: (api: CommaApiClient, signal: AbortSignal) => PromiseLike<T> | T
  ): Promise<T>;
};

export type HomeConversationSummary = Readonly<
  Pick<
    CommaConversation,
    | "created_at"
    | "freshness"
    | "group_id"
    | "id"
    | "kind"
    | "status"
    | "title"
    | "updated_at"
  >
>;

export type HomeConversationTarget = Readonly<{
  conversationId: string;
  groupId: string;
  // Bounded canonical fields from the ensure response; never transcript data.
  summary?: HomeConversationSummary;
  workspaceId: string;
}>;

export type ChatRegistry = {
  beginAttempt(): ChatRegistryAttempt;
  getHomeConversationTarget(): HomeConversationTarget | undefined;
  getRetainedSnapshot(
    groupId: string,
    conversationId: string
  ): ReturnType<ChatChannel["getSnapshot"]> | undefined;
  rememberConversationSnapshot(conversation: CommaConversation): void;
  rememberHomeConversationTarget(
    workspaceId: string,
    groupId: string,
    conversationId: string,
    conversation?: CommaConversation
  ): void;
  retireHomeConversationTarget(groupId: string, conversationId: string): void;
  retain(
    workspaceId: string,
    groupId: string,
    conversationId: string
  ): ChatRegistryLease;
  subscribeHomeConversationTarget(listener: () => void): () => void;
};

export type ChatContextValue = ChatRegistry & {
  api: CommaApiClient;
  productLease: SessionProductLease;
};

type RegistryEntry = {
  channel: ChatChannel;
  leases: Set<symbol>;
  releaseTimer: ReturnType<typeof setTimeout> | undefined;
};

type ChatSessionOwner = {
  current: ChatSession | undefined;
  // Both carries below survive the provider remount a same-session credential
  // generation bump forces, keyed by session identity WITHOUT the generation
  // (audience + authorityInstanceId + sessionId). Any change of account,
  // session, or authority produces a different identity, so nothing crosses
  // an account boundary.
  channelSeeds:
    | {
        identity: string;
        states: Map<string, ConversationChannelState>;
      }
    | undefined;
  homeTargetCarry:
    | {
        identity: string;
        target: HomeConversationTarget;
      }
    | undefined;
};

type AttemptRecord = {
  active: boolean;
  controller: AbortController;
  generation: number;
  leases: Set<ChatRegistryLease>;
};

type ChatSession = {
  context: ChatContextValue;
  readonly identity: number;
  activate(): void;
  bindRevocationSignal(): void;
  deactivate(): void;
  unbindRevocationSignal(): void;
};

const ChatContext = createContext<ChatContextValue | null>(null);
const ChatSessionContext = createContext<ChatSession | null>(null);
let nextSessionIdentity = 0;

export function ChatProvider({ children, ...sessionProps }: ChatSessionProviderProps) {
  return (
    <ChatSessionProvider {...sessionProps}>
      <ChatConsumerBoundary>{children}</ChatConsumerBoundary>
    </ChatSessionProvider>
  );
}

type ChatSessionProviderProps = {
  api: CommaApiClient;
  children: ReactNode;
  productLease: SessionProductLease;
  releaseDelayMs?: number;
  sessionSignal?: AbortSignal;
};

// Owns the registry and its exact-lease lifecycle without publishing chat
// capabilities to every descendant. The main window keeps this owner above its
// one authenticated Outlet. Settings is a product-shell overlay outside the
// keyed consumer boundary, so a generation bump cannot wipe its local state.
export function ChatSessionProvider({
  api,
  children,
  productLease,
  releaseDelayMs = 30_000,
  sessionSignal,
}: ChatSessionProviderProps) {
  const locale = useCommaLocale();
  const owner = useRef<ChatSessionOwner>({
    current: undefined,
    channelSeeds: undefined,
    homeTargetCarry: undefined,
  }).current;
  const stableProductLease = useMemo<SessionProductLease>(
    () => ({
      audience: productLease.audience,
      authorityInstanceId: productLease.authorityInstanceId,
      generation: productLease.generation,
      sessionId: productLease.sessionId,
    }),
    [
      productLease.audience,
      productLease.authorityInstanceId,
      productLease.generation,
      productLease.sessionId,
    ]
  );
  const session = useMemo(
    () =>
      createChatSession({
        api,
        locale,
        owner,
        productLease: stableProductLease,
        releaseDelayMs,
        sessionSignal,
      }),
    [api, locale, owner, releaseDelayMs, sessionSignal, stableProductLease]
  );

  // A changed exact product lease is a changed credential capability. Publish
  // that token-free identity during render so a promise microtask from the
  // previous account cannot win a race against passive-effect cleanup.
  owner.current = session;

  // Layout cleanup makes provider unmount revocation synchronous. Its setup
  // also runs before consumer passive effects during StrictMode's simulated
  // setup -> cleanup -> setup cycle, so those consumers retain against the
  // reactivated generation rather than a permanently disposed registry.
  useLayoutEffect(() => {
    session.activate();
    session.bindRevocationSignal();
    return () => {
      session.unbindRevocationSignal();
      session.deactivate();
    };
  }, [session]);

  return (
    <ChatSessionContext.Provider value={session}>
      {children}
    </ChatSessionContext.Provider>
  );
}

// Publishes chat capabilities and remounts every consumer when the exact
// product lease changes. Drafts and async continuations from one capability
// generation must never become state in the next generation's route tree.
export function ChatConsumerBoundary({ children }: { children: ReactNode }) {
  const session = useContext(ChatSessionContext);
  if (!session) {
    throw new Error("ChatConsumerBoundary must be used within ChatSessionProvider");
  }

  return (
    <ChatContext.Provider key={session.identity} value={session.context}>
      {children}
    </ChatContext.Provider>
  );
}

export function useChatRegistry() {
  const context = useContext(ChatContext);
  if (!context) {
    throw new Error("useChatRegistry must be used within ChatProvider");
  }
  return context;
}

export function useOptionalChatRegistry() {
  return useContext(ChatContext);
}

/** Imperative settings actions use the current owner without remounting the
 * entire settings dialog whenever its product lease changes. */
export function useOptionalChatActionRegistry() {
  const context = useContext(ChatContext);
  const session = useContext(ChatSessionContext);
  return context ?? session?.context ?? null;
}

export function useChatProductLease() {
  return useContext(ChatContext)?.productLease;
}

export function useChatApi() {
  const context = useContext(ChatContext);
  if (!context) {
    throw new Error("useChatApi must be used within ChatProvider");
  }
  return context.api;
}

export function useHomeConversationTarget() {
  const registry = useChatRegistry();
  const subscribe = useCallback(
    (listener: () => void) => registry.subscribeHomeConversationTarget(listener),
    [registry]
  );
  const getSnapshot = useCallback(
    () => registry.getHomeConversationTarget(),
    [registry]
  );

  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

function createChatSession({
  api,
  locale,
  owner,
  productLease,
  releaseDelayMs,
  sessionSignal,
}: {
  api: CommaApiClient;
  locale: CommaLocale;
  owner: ChatSessionOwner;
  productLease: SessionProductLease;
  releaseDelayMs: number;
  sessionSignal: AbortSignal | undefined;
}): ChatSession {
  const identity = ++nextSessionIdentity;
  const entries = new Map<string, RegistryEntry>();
  const attempts = new Set<AttemptRecord>();
  let active = true;
  let generation = 0;
  let permanentlyRevoked = sessionSignal?.aborted === true;
  let revocationBound = false;
  let apiCapability!: CommaApiClient;
  // The Home conversation target is a pair of identifiers, not conversation
  // content, so it may survive the provider remount a product-lease generation
  // bump forces (credential reconcile after a renderer 401/409, token
  // refresh). Without the carry, the route-independent Comma assistant status
  // owner unmounts after every reconcile and the sidebar card loses its
  // history until the user next visits Home. The carry identity deliberately
  // excludes the generation: any change of account, session, or authority
  // still drops the target.
  const homeTargetCarryIdentity = JSON.stringify([
    productLease.audience,
    productLease.authorityInstanceId,
    productLease.sessionId,
  ]);
  // Eager hygiene: a session with a different identity drops the previous
  // identity's carries immediately, not lazily on first use — foreign
  // transcript snapshots must not stay resident just because the new session
  // never happens to retain a conversation.
  if (
    owner.homeTargetCarry &&
    owner.homeTargetCarry.identity !== homeTargetCarryIdentity
  ) {
    owner.homeTargetCarry = undefined;
  }
  if (owner.channelSeeds && owner.channelSeeds.identity !== homeTargetCarryIdentity) {
    owner.channelSeeds = undefined;
  }
  let homeConversationTarget: HomeConversationTarget | undefined =
    owner.homeTargetCarry?.target;
  const homeConversationTargetListeners = new Set<() => void>();

  const isCurrent = (expectedGeneration?: number) =>
    active &&
    !permanentlyRevoked &&
    owner.current === session &&
    (expectedGeneration === undefined || expectedGeneration === generation);

  const assertCurrent = (expectedGeneration?: number) => {
    if (!isCurrent(expectedGeneration)) {
      throw new StaleChatSessionError();
    }
    return generation;
  };

  const releaseEntry = (key: string, entry: RegistryEntry, leaseId: symbol) => {
    if (!entry.leases.delete(leaseId)) {
      return;
    }

    const current = entries.get(key);
    if (current !== entry || entry.leases.size > 0 || entry.releaseTimer) {
      return;
    }

    entry.releaseTimer = setTimeout(() => {
      entry.releaseTimer = undefined;
      if (entries.get(key) !== entry || entry.leases.size > 0) {
        return;
      }
      rememberChannelSeed(
        owner,
        homeTargetCarryIdentity,
        key,
        entry.channel.getSnapshot()
      );
      entry.channel.stop();
      entries.delete(key);
    }, releaseDelayMs);
  };

  const retain = (
    workspaceId: string,
    groupId: string,
    conversationId: string
  ): ChatRegistryLease => {
    const leaseGeneration = assertCurrent();
    const key = channelKey(groupId, conversationId);
    let entry = entries.get(key);

    if (!entry) {
      const seed = takeChannelSeed(owner, homeTargetCarryIdentity, key);
      entry = {
        channel:
          getNativeBridge().platform === "electron" ||
          getNativeBridge().runtimeHost === "shared-worker"
            ? new BridgeConversationChannel({
                conversationId,
                groupId,
                ...(seed ? { initialState: seed } : {}),
                locale,
                session: productLease,
                workspaceId,
              })
            : new ConversationChannel({
                api: apiCapability,
                ...(seed ? { initialState: seed } : {}),
                conversationId,
                groupId,
                locale,
                workspaceId,
              }),
        leases: new Set(),
        releaseTimer: undefined,
      };
      entries.set(key, entry);
    }

    if (entry.releaseTimer) {
      clearTimeout(entry.releaseTimer);
      entry.releaseTimer = undefined;
    }

    const retainedEntry = entry;
    const leaseId = Symbol("chat-registry-lease");
    retainedEntry.leases.add(leaseId);
    retainedEntry.channel.start();
    let leaseActive = true;

    const assertLeaseCurrent = () => {
      assertCurrent(leaseGeneration);
      if (
        !leaseActive ||
        entries.get(key) !== retainedEntry ||
        !retainedEntry.leases.has(leaseId)
      ) {
        throw new StaleChatSessionError();
      }
    };

    const channel = createGuardedChannel(retainedEntry.channel, assertLeaseCurrent);
    return {
      channel,
      release() {
        if (!leaseActive) {
          return;
        }
        leaseActive = false;
        releaseEntry(key, retainedEntry, leaseId);
      },
    };
  };

  const closeAttempt = (attempt: AttemptRecord) => {
    if (!attempt.active) {
      return;
    }
    attempt.active = false;
    attempts.delete(attempt);
    attempt.controller.abort();
    for (const lease of attempt.leases) {
      lease.release();
    }
    attempt.leases.clear();
  };

  const beginAttempt = (): ChatRegistryAttempt => {
    const attempt: AttemptRecord = {
      active: true,
      controller: new AbortController(),
      generation: assertCurrent(),
      leases: new Set(),
    };
    attempts.add(attempt);

    const attemptIsCurrent = () =>
      attempt.active &&
      isCurrent(attempt.generation) &&
      !attempt.controller.signal.aborted;
    const assertAttemptCurrent = () => {
      if (!attemptIsCurrent()) {
        throw new StaleChatSessionError();
      }
      return attempt.generation;
    };
    const attemptApi = createGuardedApi(apiCapability, {
      assertCurrent: assertAttemptCurrent,
    });

    return {
      signal: attempt.controller.signal,
      isCurrent: attemptIsCurrent,
      release: () => closeAttempt(attempt),
      retain(workspaceId, groupId, conversationId) {
        assertAttemptCurrent();
        const retained = retain(workspaceId, groupId, conversationId);
        let tracked = true;
        const lease: ChatRegistryLease = {
          channel: retained.channel,
          release() {
            if (!tracked) {
              return;
            }
            tracked = false;
            attempt.leases.delete(lease);
            retained.release();
          },
        };
        attempt.leases.add(lease);
        return lease;
      },
      run<T>(
        operation: (api: CommaApiClient, signal: AbortSignal) => PromiseLike<T> | T
      ) {
        assertAttemptCurrent();
        let result: PromiseLike<T> | T;
        try {
          result = operation(attemptApi, attempt.controller.signal);
        } catch (error) {
          return Promise.reject(error);
        }
        return guardAttemptPromise(Promise.resolve(result), {
          assertCurrent: assertAttemptCurrent,
          signal: attempt.controller.signal,
        });
      },
    };
  };

  const stopOwnedResources = () => {
    for (const attempt of attempts) {
      closeAttempt(attempt);
    }
    // Snapshot every retained transcript before stopping. A same-session
    // generation remount reads these seeds so the replacement channels paint
    // the transcript that was on screen a moment ago instead of an empty
    // frame; the seed store's identity check keeps them unreachable for any
    // other signed-in session.
    for (const [key, entry] of entries) {
      rememberChannelSeed(
        owner,
        homeTargetCarryIdentity,
        key,
        entry.channel.getSnapshot()
      );
    }
    for (const entry of entries.values()) {
      if (entry.releaseTimer) {
        clearTimeout(entry.releaseTimer);
      }
      entry.leases.clear();
      entry.channel.stop();
    }
    entries.clear();
  };

  const deactivate = () => {
    if (!active) {
      return;
    }
    active = false;
    generation += 1;
    if (owner.current === session) {
      owner.current = undefined;
    }
    homeConversationTargetListeners.forEach((listener) => listener());
    stopOwnedResources();
  };

  // Revocation deliberately keeps the carry: the session transport signal
  // aborts on EVERY generation bump (its identity includes the generation), so
  // clearing here would defeat the carry in exactly the reconcile flow it
  // exists for. Cross-session hygiene is enforced by the carry identity check
  // above — a genuine sign-out produces a new sessionId that never matches.
  const revoke = () => {
    permanentlyRevoked = true;
    deactivate();
  };

  const onSessionAbort = () => revoke();

  const session: ChatSession = {
    context: undefined as unknown as ChatContextValue,
    identity,
    activate() {
      if (permanentlyRevoked) {
        return;
      }
      active = true;
      owner.current = session;
    },
    bindRevocationSignal() {
      if (!sessionSignal || revocationBound) {
        return;
      }
      if (sessionSignal.aborted) {
        revoke();
        return;
      }
      revocationBound = true;
      sessionSignal.addEventListener("abort", onSessionAbort, { once: true });
    },
    deactivate,
    unbindRevocationSignal() {
      if (!sessionSignal || !revocationBound) {
        return;
      }
      revocationBound = false;
      sessionSignal.removeEventListener("abort", onSessionAbort);
    },
  };

  apiCapability = createGuardedApi(api, {
    assertCurrent,
  });
  session.context = {
    api: apiCapability,
    beginAttempt,
    getHomeConversationTarget() {
      return isCurrent() ? homeConversationTarget : undefined;
    },
    getRetainedSnapshot(groupId, conversationId) {
      if (!isCurrent()) return undefined;
      return (
        entries.get(channelKey(groupId, conversationId))?.channel.getSnapshot() ??
        // Old-provider cleanup can publish its seed after the new provider's
        // render. The admitted session identity owns visibility: reject that
        // foreign seed before the first frame, just as takeChannelSeed does.
        (owner.channelSeeds?.identity === homeTargetCarryIdentity
          ? owner.channelSeeds.states.get(channelKey(groupId, conversationId))
          : undefined)
      );
    },
    productLease,
    rememberConversationSnapshot(conversation) {
      assertCurrent();
      const key = channelKey(conversation.group_id, conversation.id);
      // Preparation supplies display-only canonical data. The retained runtime
      // still owns connection, sends, drafts and subsequent reconciliation.
      if (entries.has(key)) return;
      const existing =
        owner.channelSeeds?.identity === homeTargetCarryIdentity
          ? owner.channelSeeds.states.get(key)?.conversation
          : undefined;
      if (existing && (existing.updated_at ?? 0) >= (conversation.updated_at ?? 0))
        return;
      const messages = normalizeServerMessages(
        conversation.messages ?? [],
        [],
        conversation.kind
      );
      // A tail containing only private delivery records cannot establish an
      // empty public transcript or acknowledge an unseen review result.
      if (
        messages.length === 0 &&
        (conversation.message_count ?? conversation.messages?.length ?? 0) > 0
      )
        return;
      rememberChannelSeed(owner, homeTargetCarryIdentity, key, {
        ...idleConversationChannelState,
        conversation,
        messages,
        serverMessages: messages,
      });
    },
    rememberHomeConversationTarget(workspaceId, groupId, conversationId, conversation) {
      assertCurrent();
      const currentTarget = homeConversationTarget;
      const sameTarget =
        currentTarget?.conversationId === conversationId &&
        currentTarget.groupId === groupId &&
        currentTarget.workspaceId === workspaceId;
      const summary = conversation
        ? homeConversationSummary(conversation, groupId, conversationId)
        : sameTarget
          ? currentTarget?.summary
          : undefined;
      if (sameTarget && sameHomeConversationSummary(currentTarget?.summary, summary)) {
        return;
      }
      homeConversationTarget = {
        conversationId,
        groupId,
        ...(summary ? { summary } : {}),
        workspaceId,
      };
      owner.homeTargetCarry = {
        identity: homeTargetCarryIdentity,
        target: homeConversationTarget,
      };
      homeConversationTargetListeners.forEach((listener) => listener());
    },
    retireHomeConversationTarget(groupId, conversationId) {
      assertCurrent();
      // A delayed resolution for A must not retire a newer remembered B.
      if (
        homeConversationTarget?.conversationId !== conversationId ||
        homeConversationTarget.groupId !== groupId
      ) {
        return;
      }
      homeConversationTarget = undefined;
      if (owner.homeTargetCarry?.identity === homeTargetCarryIdentity) {
        owner.homeTargetCarry = undefined;
      }
      homeConversationTargetListeners.forEach((listener) => listener());
    },
    retain,
    subscribeHomeConversationTarget(listener) {
      if (!isCurrent()) return () => {};
      homeConversationTargetListeners.add(listener);
      return () => homeConversationTargetListeners.delete(listener);
    },
  };
  return session;
}

function homeConversationSummary(
  conversation: CommaConversation,
  groupId: string,
  conversationId: string
): HomeConversationSummary {
  if (
    conversation.id !== conversationId ||
    conversation.group_id !== groupId ||
    conversation.kind !== "user_chat"
  ) {
    throw new Error("Workspace Chat summary did not match the Home target.");
  }
  return {
    ...(conversation.created_at === undefined
      ? {}
      : { created_at: conversation.created_at }),
    ...(conversation.freshness ? { freshness: { ...conversation.freshness } } : {}),
    group_id: conversation.group_id,
    id: conversation.id,
    kind: conversation.kind,
    status: conversation.status,
    title: conversation.title,
    ...(conversation.updated_at === undefined
      ? {}
      : { updated_at: conversation.updated_at }),
  };
}

function sameHomeConversationSummary(
  left: HomeConversationSummary | undefined,
  right: HomeConversationSummary | undefined
) {
  return (
    left?.created_at === right?.created_at &&
    left?.freshness?.refreshed_at === right?.freshness?.refreshed_at &&
    left?.freshness?.state === right?.freshness?.state &&
    left?.group_id === right?.group_id &&
    left?.id === right?.id &&
    left?.kind === right?.kind &&
    left?.status === right?.status &&
    left?.title === right?.title &&
    left?.updated_at === right?.updated_at
  );
}

function createGuardedApi(
  api: CommaApiClient,
  session: {
    assertCurrent(expectedGeneration?: number): number;
  }
): CommaApiClient {
  const methods = new Map<PropertyKey, (...args: unknown[]) => unknown>();
  let proxy!: CommaApiClient;
  proxy = new Proxy(api, {
    get(target, property) {
      const value = Reflect.get(target, property, target);
      if (typeof value !== "function") {
        return value;
      }

      const cached = methods.get(property);
      if (cached) {
        return cached;
      }

      const guarded = (...args: unknown[]) => {
        let generation: number;
        let result: unknown;
        try {
          generation = session.assertCurrent();
          result = Reflect.apply(value, proxy, args);
        } catch (error) {
          return Promise.reject(error);
        }
        return Promise.resolve(result).then(
          (resolved) => {
            session.assertCurrent(generation);
            return resolved;
          },
          (error: unknown) => {
            session.assertCurrent(generation);
            throw error;
          }
        );
      };
      methods.set(property, guarded);
      return guarded;
    },
  });
  return proxy;
}

function createGuardedChannel(channel: ChatChannel, assertCurrent: () => void) {
  const methods = new Map<PropertyKey, (...args: unknown[]) => unknown>();
  return new Proxy(channel, {
    get(target, property) {
      const value = Reflect.get(target, property, target);
      if (typeof value !== "function") {
        return value;
      }

      const cached = methods.get(property);
      if (cached) {
        return cached;
      }

      if (property === "getSnapshot") {
        const guardedSnapshot = () => {
          try {
            assertCurrent();
          } catch (error) {
            if (isStaleChatSessionError(error)) {
              return idleConversationChannelState;
            }
            throw error;
          }
          return Reflect.apply(value, target, []);
        };
        methods.set(property, guardedSnapshot);
        return guardedSnapshot;
      }

      if (property === "subscribe") {
        const guardedSubscribe = (...args: unknown[]) => {
          try {
            assertCurrent();
          } catch (error) {
            if (isStaleChatSessionError(error)) {
              return () => {};
            }
            throw error;
          }
          return Reflect.apply(value, target, args);
        };
        methods.set(property, guardedSubscribe);
        return guardedSubscribe;
      }

      const guarded = (...args: unknown[]) => {
        assertCurrent();
        return Reflect.apply(value, target, args);
      };
      methods.set(property, guarded);
      return guarded;
    },
  }) as ChatChannel;
}

function guardAttemptPromise<T>(
  promise: Promise<T>,
  attempt: { assertCurrent(): void; signal: AbortSignal }
) {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) {
        return;
      }
      settled = true;
      attempt.signal.removeEventListener("abort", onAbort);
      callback();
    };
    const onAbort = () => settle(() => reject(new StaleChatSessionError()));
    attempt.signal.addEventListener("abort", onAbort, { once: true });

    promise.then(
      (value) =>
        settle(() => {
          try {
            attempt.assertCurrent();
            resolve(value);
          } catch (error) {
            reject(error);
          }
        }),
      (error: unknown) =>
        settle(() => {
          try {
            attempt.assertCurrent();
            reject(error);
          } catch (staleError) {
            reject(staleError);
          }
        })
    );
  });
}

function channelKey(groupId: string, conversationId: string) {
  return `${groupId}/${conversationId}`;
}

const MAX_CHANNEL_SEEDS = 16;

/**
 * Keeps canonical content for a revisit or the next same-session generation:
 * the canonical transcript and conversation metadata survive with their object
 * identities intact (so memoized rows never re-render). Everything owned by
 * the dead Main entry is dropped — pending sends, attachments, activity,
 * streaming state, and the draft: an auth reset preserves no ghost drafts
 * (ADR 2026-07-17-electron-side-chat-window), and displaying an already
 * fetched transcript is the one thing a revoked generation leaves behind.
 * Returns undefined when there is nothing worth painting.
 */
export function seedableChannelState(
  state: ConversationChannelState
): ConversationChannelState | undefined {
  if (
    (state.errorKind && state.errorKind !== "network") ||
    (!state.conversation && state.serverMessages.length === 0)
  ) {
    return undefined;
  }
  return {
    ...idleConversationChannelState,
    conversation: state.conversation,
    messages: state.serverMessages,
    serverMessages: state.serverMessages,
    status: "ready",
    syncWarning: "stale",
  };
}

// Cache only already-read canonical content: at most 16 conversations, without
// sockets, timers, drafts or pending work. A revisit revalidates through its owner.
function rememberChannelSeed(
  owner: ChatSessionOwner,
  identity: string,
  key: string,
  state: ConversationChannelState
) {
  const seed = seedableChannelState(state);
  if (!seed) return;
  const seeds =
    owner.channelSeeds?.identity === identity
      ? owner.channelSeeds.states
      : new Map<string, ConversationChannelState>();
  seeds.delete(key);
  seeds.set(key, seed);
  while (seeds.size > MAX_CHANNEL_SEEDS) seeds.delete(seeds.keys().next().value!);
  owner.channelSeeds = { identity, states: seeds };
}

function takeChannelSeed(
  owner: ChatSessionOwner,
  identity: string,
  key: string
): ConversationChannelState | undefined {
  const seeds = owner.channelSeeds;
  if (!seeds) return undefined;
  if (seeds.identity !== identity) {
    // A different signed-in session never reads another session's seeds.
    owner.channelSeeds = undefined;
    return undefined;
  }
  const seed = seeds.states.get(key);
  if (seed) seeds.states.delete(key);
  return seed;
}
