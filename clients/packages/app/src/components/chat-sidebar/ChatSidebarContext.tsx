import {
  getNativeBridge,
  maxBrowserSidebarSessionsPerOwner,
  type BrowserSidebarState,
} from "@comma/native-bridge";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import {
  commaChatSidebarDefaultWidth,
  commaChatSidebarMinWidth,
} from "../shellGeometry";
import {
  conversationFileSourceKey,
  type ConversationFileSource,
} from "../../runtime-files/fileSources";
import type { ChatParticipantStatus } from "../chat/model/conversationChannel";

export type ChatSidebarHost = {
  conversationId: string;
  groupId: string;
  workspaceId: string;
};

export type ChatSidebarConversationTarget = ChatSidebarHost & {
  kind: "agent_task";
  title?: string | undefined;
};

export type ChatSidebarBrowserTarget = {
  title?: string | undefined;
  url: string;
};

export type ChatSidebarBrowserPage = {
  closeBeforeOpenSessionIds?: string[] | undefined;
  id: string;
  navigationRevision: number;
  title?: string | undefined;
  url: string;
};

/** A Drive file previewed as a tab; `id` is the Drive file id. */
export type ChatSidebarDrivePreview = {
  id: string;
  name: string;
};

export type ChatSidebarHistoryPage = {
  id: string;
  groupId: string;
  participant: Pick<ChatParticipantStatus, "conversationId" | "participantId" | "name">;
};

export type ChatSidebarFilePreview = { id: string; source: ConversationFileSource };

export type ChatSidebarSurface = "browser" | "chat" | "drive" | "history" | "file";

export type ChatSidebarSession = {
  activeBrowserPageId?: string | undefined;
  activeDrivePreviewId?: string | undefined;
  activeFilePreviewId?: string | undefined;
  filePreviews?: ChatSidebarFilePreview[];
  activeSurface: ChatSidebarSurface;
  browserPages: ChatSidebarBrowserPage[];
  chats: ChatSidebarConversationTarget[];
  activeChatId?: string | undefined;
  drivePreviews: ChatSidebarDrivePreview[];
  historyPages?: ChatSidebarHistoryPage[];
  activeHistoryPageId?: string | undefined;
};

export type ChatSidebarContextValue = {
  activeHost?: ChatSidebarHost | undefined;
  activeSession?: ChatSidebarSession | undefined;
  addBrowserTab: (host: ChatSidebarHost) => void;
  canOpenChildChat: (host: ChatSidebarHost) => boolean;
  closeBrowserPage: (host: ChatSidebarHost, pageId: string) => void;
  closeChat: (host: ChatSidebarHost, chatId?: string) => void;
  closeDrivePreview: (host: ChatSidebarHost, previewId: string) => void;
  closeHistoryPage: (host: ChatSidebarHost, pageId: string) => void;
  getNativeBrowserCapacityBlockedEpoch: (sessionId: string) => number | undefined;
  isOpen: boolean;
  nativeBrowserCapacityEpoch: number;
  nativeBrowserStates: ReadonlyMap<string, BrowserSidebarState>;
  openBrowser: (host: ChatSidebarHost, target: ChatSidebarBrowserTarget) => void;
  openChat: (host: ChatSidebarHost, target: ChatSidebarConversationTarget) => void;
  openDrivePreview: (host: ChatSidebarHost, preview: ChatSidebarDrivePreview) => void;
  openFilePreview: (host: ChatSidebarHost, source: ConversationFileSource) => void;
  selectFilePreview: (host: ChatSidebarHost, id: string) => void;
  closeFilePreview: (host: ChatSidebarHost, id: string) => void;
  openSessionHistory: (
    host: ChatSidebarHost,
    target: Omit<ChatSidebarHistoryPage, "id">
  ) => void;
  /**
   * Width the trailing sidebar has yet to take from `host`'s row: positive
   * while it opens, negative while it closes, 0 once its width transition has
   * settled or while it is not animating. Responsive folds beside the sidebar
   * (the Task details column, Home's rails) subtract it from what they measure
   * so they fold for the layout the reader will see, not for a frame in
   * flight — deciding from the in-flight width squeezes the chat, folds late,
   * then lets the chat spring back. Elements inside the sidebar owe nothing.
   */
  pendingTrailingWidth: (host: Element) => number;
  registerHost: (
    host: ChatSidebarHost,
    options?: { commaCenter?: boolean | undefined }
  ) => () => void;
  recordNativeBrowserState: (
    state: BrowserSidebarState,
    capacityAttemptEpoch?: number | undefined
  ) => void;
  selectBrowserPage: (host: ChatSidebarHost, pageId: string) => void;
  selectChat: (host: ChatSidebarHost, chatId?: string) => void;
  selectDrivePreview: (host: ChatSidebarHost, previewId: string) => void;
  selectHistoryPage: (host: ChatSidebarHost, pageId: string) => void;
  toggle: (host: ChatSidebarHost) => void;
  toggleActive: () => void;
  /** The sidebar aside; the surface that renders it attaches the element. */
  trailingRef: RefObject<HTMLElement | null>;
  updateBrowserPage: (
    host: ChatSidebarHost,
    pageId: string,
    patch: Partial<Pick<ChatSidebarBrowserPage, "title" | "url">>
  ) => void;
  updateBrowserPageMetadata: (
    host: ChatSidebarHost,
    pageId: string,
    patch: Partial<Pick<ChatSidebarBrowserPage, "title" | "url">>
  ) => void;
};

// The sidebar width changes on every pointer move of a resize drag; it lives
// in its own context so only width consumers re-render while dragging.
type ChatSidebarWidthContextValue = {
  setWidth: (width: number) => void;
  width: number;
};

type ChatSidebarRegistry = {
  activeHost?: ChatSidebarHost | undefined;
  commaCenterLineage: ReadonlySet<string>;
  openSessionKeys: ReadonlySet<string>;
  sessions: ReadonlyMap<string, ChatSidebarSession>;
};

const maxRememberedCommaLineageChats = 96;
const ChatSidebarContext = createContext<ChatSidebarContextValue | null>(null);
const ChatSidebarWidthContext = createContext<ChatSidebarWidthContextValue | null>(
  null
);

const emptySession = (): ChatSidebarSession => ({
  activeSurface: "browser",
  browserPages: [],
  chats: [],
  drivePreviews: [],
  historyPages: [],
  filePreviews: [],
});

export function activeSidebarChat(session: ChatSidebarSession | undefined) {
  return (
    session?.chats.find((chat) => chatSidebarHostKey(chat) === session.activeChatId) ??
    session?.chats[0]
  );
}

const globalBrowserHost: ChatSidebarHost = {
  conversationId: "__global_browser__",
  groupId: "__global__",
  workspaceId: "__global__",
};

/**
 * Drive is not a conversation, so its previews hang off one shared host —
 * the same arrangement the global browser uses. The Drive route registers it
 * while mounted, which is what makes the shell's one right sidebar show Drive
 * file tabs instead of a second sidebar of its own.
 */
export const driveSidebarHost: ChatSidebarHost = {
  conversationId: "__global_drive__",
  groupId: "__global__",
  workspaceId: "__global__",
};

// Every `BrowserSidebarState` field the renderer reads; `surface` is Main's
// window-registry geometry, carried for tooling and changing on every frame
// of a drag.
const sameConsumedBrowserState = (
  previous: BrowserSidebarState | undefined,
  next: BrowserSidebarState
) =>
  previous !== undefined &&
  previous.available === next.available &&
  previous.active === next.active &&
  previous.canGoBack === next.canGoBack &&
  previous.canGoForward === next.canGoForward &&
  previous.loading === next.loading &&
  previous.title === next.title &&
  previous.visible === next.visible &&
  previous.url === next.url &&
  previous.reason === next.reason &&
  previous.reasonCode === next.reasonCode;

export function ChatSidebarProvider({ children }: { children: ReactNode }) {
  const activeRegistration = useRef<symbol | undefined>(undefined);
  const trailingRef = useRef<HTMLElement | null>(null);
  const pendingTrailingWidth = useCallback<
    ChatSidebarContextValue["pendingTrailingWidth"]
  >((host) => {
    const aside = trailingRef.current;
    if (!aside || aside.contains(host)) return 0;
    // The aside's own width is what transitions; its content keeps the
    // settled width throughout (the surface is pinned to the rendered width,
    // see styles.css), so the content extent is the width it is heading for.
    const target = aside.dataset.open === "true" ? aside.scrollWidth : 0;
    return target - aside.getBoundingClientRect().width;
  }, []);
  const [width, setWidthState] = useState(commaChatSidebarDefaultWidth);
  const [registry, setRegistry] = useState<ChatSidebarRegistry>({
    commaCenterLineage: new Set(),
    openSessionKeys: new Set(),
    sessions: new Map(),
  });
  const [nativeBrowserCapacityEpoch, setNativeBrowserCapacityEpoch] = useState(0);
  const nativeBrowserCapacityEpochRef = useRef(0);
  const [nativeBrowserStates, setNativeBrowserStates] = useState<
    ReadonlyMap<string, BrowserSidebarState>
  >(new Map());
  const nativeBrowserStatesRef = useRef<ReadonlyMap<string, BrowserSidebarState>>(
    new Map()
  );
  // The owner-targeted event stream outlives renderer retention. Keep its active
  // set separate so a forgotten session can still signal one capacity release.
  const activeNativeBrowserSessionIdsRef = useRef<ReadonlySet<string>>(new Set());
  const nativeBrowserCapacityBlockedEpochsRef = useRef<ReadonlyMap<string, number>>(
    new Map()
  );
  const registrySessionsRef = useRef(registry.sessions);
  const retainedNativeBrowserSessionsRef = useRef<ReadonlySet<string>>(new Set());
  const providerMountedRef = useRef(true);
  registrySessionsRef.current = registry.sessions;

  const observeNativeBrowserState = useCallback((state: BrowserSidebarState) => {
    const sessionId = state.sessionId;
    if (!sessionId || state.reasonCode === "capacity") return;
    const wasActive = activeNativeBrowserSessionIdsRef.current.has(sessionId);
    const activeSessionIds = new Set(activeNativeBrowserSessionIdsRef.current);
    if (state.active) {
      activeSessionIds.add(sessionId);
    } else {
      activeSessionIds.delete(sessionId);
    }
    activeNativeBrowserSessionIdsRef.current = activeSessionIds;
    if (wasActive && !state.active) {
      nativeBrowserCapacityEpochRef.current += 1;
      setNativeBrowserCapacityEpoch(nativeBrowserCapacityEpochRef.current);
    }
  }, []);

  const persistNativeBrowserState = useCallback(
    (state: BrowserSidebarState, capacityAttemptEpoch?: number | undefined) => {
      const sessionId = state.sessionId;
      if (!sessionId) return;
      // A delayed capacity settlement belongs to an older open attempt. Once a
      // newer authoritative settlement has made this same session active, do
      // not let the old reply replace it with a blocked snapshot.
      if (
        state.reasonCode === "capacity" &&
        nativeBrowserStatesRef.current.get(sessionId)?.active
      ) {
        return;
      }
      // The bounds sync acks a state on every frame of a window or sidebar
      // drag, and Main broadcasts the same state again as a changed event.
      // Only `surface` moves in those — per-frame geometry with no renderer
      // consumer — so a state that changed nothing the renderer reads is not
      // republished; doing so re-rendered every sidebar consumer per frame.
      if (
        state.reasonCode === undefined &&
        sameConsumedBrowserState(nativeBrowserStatesRef.current.get(sessionId), state)
      ) {
        return;
      }
      const blockedEpochs = new Map(nativeBrowserCapacityBlockedEpochsRef.current);
      if (state.reasonCode === "capacity") {
        const observedEpoch =
          capacityAttemptEpoch ?? nativeBrowserCapacityEpochRef.current;
        const existingEpoch = blockedEpochs.get(sessionId);
        blockedEpochs.set(
          sessionId,
          capacityAttemptEpoch !== undefined || existingEpoch === undefined
            ? observedEpoch
            : Math.min(existingEpoch, observedEpoch)
        );
      } else {
        blockedEpochs.delete(sessionId);
      }
      nativeBrowserCapacityBlockedEpochsRef.current = blockedEpochs;
      const states = new Map(nativeBrowserStatesRef.current);
      states.set(sessionId, state);
      nativeBrowserStatesRef.current = states;
      setNativeBrowserStates(states);
      setRegistry((current) =>
        updateBrowserPageFromNativeState(current, sessionId, state)
      );
    },
    []
  );

  const recordNativeBrowserState = useCallback<
    ChatSidebarContextValue["recordNativeBrowserState"]
  >(
    (state, capacityAttemptEpoch) => {
      observeNativeBrowserState(state);
      persistNativeBrowserState(state, capacityAttemptEpoch);
    },
    [observeNativeBrowserState, persistNativeBrowserState]
  );

  const forgetNativeBrowserState = useCallback((sessionId: string) => {
    if (nativeBrowserStatesRef.current.has(sessionId)) {
      const states = new Map(nativeBrowserStatesRef.current);
      states.delete(sessionId);
      nativeBrowserStatesRef.current = states;
      setNativeBrowserStates(states);
    }
    if (nativeBrowserCapacityBlockedEpochsRef.current.has(sessionId)) {
      const blockedEpochs = new Map(nativeBrowserCapacityBlockedEpochsRef.current);
      blockedEpochs.delete(sessionId);
      nativeBrowserCapacityBlockedEpochsRef.current = blockedEpochs;
    }
  }, []);

  const getNativeBrowserCapacityBlockedEpoch = useCallback(
    (sessionId: string) => nativeBrowserCapacityBlockedEpochsRef.current.get(sessionId),
    []
  );

  useEffect(() => {
    providerMountedRef.current = true;
    return () => {
      providerMountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron") return undefined;
    return bridge.browserSidebar.onChanged((state) => {
      observeNativeBrowserState(state);
      if (
        !state.sessionId ||
        !hasBrowserPageSession(registrySessionsRef.current, state.sessionId)
      ) {
        return;
      }
      persistNativeBrowserState(state);
    });
  }, [observeNativeBrowserState, persistNativeBrowserState]);

  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron") return undefined;
    return bridge.browserSidebar.onOpenTabRequested(({ tabId, url }) => {
      setRegistry((current) => openRequestedBrowserTab(current, tabId, url));
    });
  }, []);

  useEffect(() => {
    const retained = new Set<string>();
    for (const [hostKey, session] of registry.sessions) {
      for (const page of session.browserPages) {
        if (!page.url) continue;
        retained.add(chatSidebarBrowserPageSessionId(hostKey, page.id));
      }
    }
    const bridge = getNativeBridge();
    if (bridge.platform === "electron") {
      for (const sessionId of retainedNativeBrowserSessionsRef.current) {
        if (retained.has(sessionId)) continue;
        void bridge.browserSidebar
          .close({ sessionId })
          .then((state) => {
            if (!providerMountedRef.current) return;
            observeNativeBrowserState({
              ...state,
              sessionId: state.sessionId ?? sessionId,
            });
            forgetNativeBrowserState(sessionId);
          })
          .catch(async () => {
            if (!providerMountedRef.current) return;
            try {
              const state = await bridge.browserSidebar.update({
                sessionId,
                visible: false,
              });
              if (!providerMountedRef.current) return;
              if (!state.active) {
                observeNativeBrowserState({
                  ...state,
                  sessionId: state.sessionId ?? sessionId,
                });
              }
            } catch {
              // The owner event stream remains the fallback capacity signal.
            }
            if (providerMountedRef.current) forgetNativeBrowserState(sessionId);
          });
      }
    } else {
      for (const sessionId of retainedNativeBrowserSessionsRef.current) {
        if (!retained.has(sessionId)) forgetNativeBrowserState(sessionId);
      }
    }
    retainedNativeBrowserSessionsRef.current = retained;
  }, [forgetNativeBrowserState, observeNativeBrowserState, registry.sessions]);

  useEffect(
    () => () => {
      const bridge = getNativeBridge();
      if (bridge.platform !== "electron") return;
      for (const sessionId of retainedNativeBrowserSessionsRef.current) {
        void bridge.browserSidebar.close({ sessionId }).catch(() => undefined);
      }
      retainedNativeBrowserSessionsRef.current = new Set();
    },
    []
  );

  const registerHost = useCallback<ChatSidebarContextValue["registerHost"]>(
    (host, options) => {
      const registration = Symbol(chatSidebarHostKey(host));
      activeRegistration.current = registration;
      setRegistry((current) => {
        const commaCenterLineage = options?.commaCenter
          ? addLineage(current.commaCenterLineage, host)
          : current.commaCenterLineage;
        if (
          sameChatSidebarHost(current.activeHost, host) &&
          commaCenterLineage === current.commaCenterLineage
        ) {
          return current;
        }
        return {
          ...current,
          activeHost: host,
          commaCenterLineage,
        };
      });

      return () => {
        if (activeRegistration.current !== registration) return;
        activeRegistration.current = undefined;
        setRegistry((current) =>
          sameChatSidebarHost(current.activeHost, host)
            ? { ...current, activeHost: undefined }
            : current
        );
      };
    },
    []
  );

  const openBrowser = useCallback<ChatSidebarContextValue["openBrowser"]>(
    (host, target) => {
      const url = safeBrowserUrl(target.url);
      if (!url) return;
      const pageId = createBrowserPageId();
      setRegistry((current) => {
        const sessions = updateSidebarSession(
          current.sessions,
          host,
          (session) => {
            const page: ChatSidebarBrowserPage = {
              id: pageId,
              navigationRevision: 1,
              title: target.title,
              url,
            };
            return {
              ...session,
              activeBrowserPageId: page.id,
              activeSurface: "browser",
              browserPages: [...session.browserPages, page],
            };
          },
          pageId
        );
        return {
          ...current,
          openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
          sessions,
        };
      });
    },
    []
  );

  const addBrowserTab = useCallback<ChatSidebarContextValue["addBrowserTab"]>(
    (host) => {
      const page = createBlankBrowserPage();
      setRegistry((current) => {
        const sessions = updateSidebarSession(current.sessions, host, (session) => {
          return {
            ...session,
            activeBrowserPageId: page.id,
            activeSurface: "browser",
            browserPages: [...session.browserPages, page],
          };
        });
        return {
          ...current,
          openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
          sessions,
        };
      });
    },
    []
  );

  const openChat = useCallback<ChatSidebarContextValue["openChat"]>((host, target) => {
    setRegistry((current) => {
      const sessions = updateSidebarSession(current.sessions, host, (session) => ({
        ...session,
        activeSurface: "chat",
        activeChatId: chatSidebarHostKey(target),
        chats: session.chats.some(
          (chat) => chatSidebarHostKey(chat) === chatSidebarHostKey(target)
        )
          ? session.chats.map((chat) =>
              chatSidebarHostKey(chat) === chatSidebarHostKey(target) ? target : chat
            )
          : [...session.chats, target],
      }));
      return {
        ...current,
        commaCenterLineage: addLineage(
          addLineage(current.commaCenterLineage, host),
          target
        ),
        openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
        sessions,
      };
    });
  }, []);

  const toggle = useCallback<ChatSidebarContextValue["toggle"]>((host) => {
    setRegistry((current) => {
      const key = chatSidebarHostKey(host);
      if (!current.sessions.has(key)) return current;
      const openSessionKeys = new Set(current.openSessionKeys);
      if (openSessionKeys.has(key)) {
        openSessionKeys.delete(key);
      } else {
        openSessionKeys.add(key);
      }
      return { ...current, openSessionKeys };
    });
  }, []);

  const toggleActive = useCallback<ChatSidebarContextValue["toggleActive"]>(() => {
    const page = createBlankBrowserPage();
    setRegistry((current) => {
      const host = current.activeHost ?? globalBrowserHost;
      const key = chatSidebarHostKey(host);
      if (current.sessions.has(key)) {
        const openSessionKeys = new Set(current.openSessionKeys);
        if (openSessionKeys.has(key)) {
          openSessionKeys.delete(key);
        } else {
          openSessionKeys.add(key);
        }
        return { ...current, activeHost: host, openSessionKeys };
      }

      const sessions = updateSidebarSession(
        current.sessions,
        host,
        (session) => ({
          ...session,
          activeBrowserPageId: page.id,
          activeSurface: "browser",
          browserPages: [page],
        }),
        page.id
      );
      return {
        ...current,
        activeHost: host,
        openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
        sessions,
      };
    });
  }, []);

  const selectBrowserPage = useCallback<ChatSidebarContextValue["selectBrowserPage"]>(
    (host, pageId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (
          !session ||
          !session.browserPages.some((page) => page.id === pageId) ||
          (session.activeSurface === "browser" &&
            session.activeBrowserPageId === pageId)
        ) {
          return current;
        }
        const sessions = new Map(current.sessions);
        touchSidebarSession(sessions, key, {
          ...session,
          activeBrowserPageId: pageId,
          activeSurface: "browser",
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const selectChat = useCallback<ChatSidebarContextValue["selectChat"]>(
    (host, chatId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        const activeChatId = chatId ?? session?.activeChatId;
        if (!session?.chats.some((chat) => chatSidebarHostKey(chat) === activeChatId))
          return current;
        if (session.activeSurface === "chat" && session.activeChatId === activeChatId)
          return current;
        const sessions = new Map(current.sessions);
        touchSidebarSession(sessions, key, {
          ...session,
          activeSurface: "chat",
          activeChatId,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const closeBrowserPage = useCallback<ChatSidebarContextValue["closeBrowserPage"]>(
    (host, pageId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (!session) return current;
        const pageIndex = session.browserPages.findIndex((page) => page.id === pageId);
        if (pageIndex < 0) return current;

        const browserPages = session.browserPages.filter((page) => page.id !== pageId);
        const sessions = new Map(current.sessions);
        sessions.delete(key);

        if (
          browserPages.length === 0 &&
          !session.chats.length &&
          session.drivePreviews.length === 0 &&
          !session.historyPages?.length &&
          !session.filePreviews?.length
        ) {
          touchSidebarSession(sessions, key, emptySession());
          return { ...current, sessions };
        }

        const closingActive =
          session.activeSurface === "browser" && session.activeBrowserPageId === pageId;
        let activeBrowserPageId = session.activeBrowserPageId;
        let activeSurface = session.activeSurface;

        if (browserPages.length === 0) {
          activeBrowserPageId = undefined;
          if (closingActive)
            activeSurface = session.chats.length
              ? "chat"
              : session.drivePreviews.length
                ? "drive"
                : "history";
        } else if (closingActive) {
          const next =
            browserPages[Math.min(pageIndex, browserPages.length - 1)] ??
            browserPages[0];
          activeBrowserPageId = next?.id;
          activeSurface = "browser";
        } else if (
          activeBrowserPageId &&
          !browserPages.some((page) => page.id === activeBrowserPageId)
        ) {
          activeBrowserPageId = browserPages[0]?.id;
        }

        touchSidebarSession(sessions, key, {
          ...session,
          activeBrowserPageId,
          activeSurface,
          browserPages,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const closeChat = useCallback<ChatSidebarContextValue["closeChat"]>(
    (host, chatId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (!session) return current;
        const closingId = chatId ?? session.activeChatId;
        const index = session.chats.findIndex(
          (chat) => chatSidebarHostKey(chat) === closingId
        );
        if (index < 0) return current;
        const chats = session.chats.filter(
          (chat) => chatSidebarHostKey(chat) !== closingId
        );
        const next = chats[Math.min(index, chats.length - 1)];
        const sessions = new Map(current.sessions);
        touchSidebarSession(sessions, key, {
          ...session,
          chats,
          activeChatId:
            closingId === session.activeChatId
              ? next && chatSidebarHostKey(next)
              : session.activeChatId,
          activeSurface:
            session.activeSurface === "chat" && chats.length === 0
              ? session.browserPages.length
                ? "browser"
                : session.drivePreviews.length
                  ? "drive"
                  : session.historyPages?.length
                    ? "history"
                    : "file"
              : session.activeSurface,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const openFilePreview = useCallback<ChatSidebarContextValue["openFilePreview"]>(
    (host, source) => {
      const id = conversationFileSourceKey(source);
      setRegistry((current) => {
        const sessions = updateSidebarSession(current.sessions, host, (session) => ({
          ...session,
          activeSurface: "file",
          activeFilePreviewId: id,
          filePreviews: [
            ...(session.filePreviews ?? [])
              .filter((preview) => preview.id !== id)
              .slice(-(maxBrowserSidebarSessionsPerOwner - 1)),
            { id, source },
          ],
        }));
        return {
          ...current,
          sessions,
          openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
        };
      });
    },
    []
  );

  const selectFilePreview = useCallback<ChatSidebarContextValue["selectFilePreview"]>(
    (host, id) => {
      setRegistry((current) => ({
        ...current,
        sessions: updateSidebarSession(current.sessions, host, (session) =>
          session.filePreviews?.some((preview) => preview.id === id)
            ? { ...session, activeSurface: "file", activeFilePreviewId: id }
            : session
        ),
      }));
    },
    []
  );

  const closeFilePreview = useCallback<ChatSidebarContextValue["closeFilePreview"]>(
    (host, id) => {
      setRegistry((current) => ({
        ...current,
        sessions: updateSidebarSession(current.sessions, host, (session) => {
          const previews = session.filePreviews ?? [];
          const index = previews.findIndex((preview) => preview.id === id);
          if (index < 0) return session;
          const filePreviews = previews.filter((preview) => preview.id !== id);
          const next = filePreviews[Math.min(index, filePreviews.length - 1)];
          return {
            ...session,
            filePreviews,
            activeFilePreviewId:
              session.activeFilePreviewId === id
                ? next?.id
                : session.activeFilePreviewId,
            activeSurface:
              session.activeSurface === "file" && !filePreviews.length
                ? session.chats.length
                  ? "chat"
                  : session.drivePreviews.length
                    ? "drive"
                    : session.historyPages?.length
                      ? "history"
                      : "browser"
                : session.activeSurface,
          };
        }),
      }));
    },
    []
  );

  const openDrivePreview = useCallback<ChatSidebarContextValue["openDrivePreview"]>(
    (host, preview) => {
      setRegistry((current) => {
        const sessions = updateSidebarSession(current.sessions, host, (session) => {
          const known = session.drivePreviews.some((entry) => entry.id === preview.id);
          return {
            ...session,
            activeDrivePreviewId: preview.id,
            activeSurface: "drive",
            // Re-opening a file focuses the tab it already has; a renamed file
            // refreshes its label rather than growing a second tab.
            drivePreviews: known
              ? session.drivePreviews.map((entry) =>
                  entry.id === preview.id ? preview : entry
                )
              : [...session.drivePreviews, preview],
          };
        });
        return {
          ...current,
          openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
          sessions,
        };
      });
    },
    []
  );

  const selectDrivePreview = useCallback<ChatSidebarContextValue["selectDrivePreview"]>(
    (host, previewId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (
          !session ||
          !session.drivePreviews.some((preview) => preview.id === previewId) ||
          (session.activeSurface === "drive" &&
            session.activeDrivePreviewId === previewId)
        ) {
          return current;
        }
        const sessions = new Map(current.sessions);
        touchSidebarSession(sessions, key, {
          ...session,
          activeDrivePreviewId: previewId,
          activeSurface: "drive",
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const closeDrivePreview = useCallback<ChatSidebarContextValue["closeDrivePreview"]>(
    (host, previewId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (!session) return current;
        const index = session.drivePreviews.findIndex(
          (preview) => preview.id === previewId
        );
        if (index === -1) return current;

        const drivePreviews = session.drivePreviews.filter(
          (preview) => preview.id !== previewId
        );
        const sessions = new Map(current.sessions);
        sessions.delete(key);

        if (
          drivePreviews.length === 0 &&
          session.browserPages.length === 0 &&
          !session.chats.length &&
          !session.historyPages?.length &&
          !session.filePreviews?.length
        ) {
          touchSidebarSession(sessions, key, emptySession());
          return { ...current, sessions };
        }

        const closingActive =
          session.activeSurface === "drive" &&
          session.activeDrivePreviewId === previewId;
        let activeDrivePreviewId = session.activeDrivePreviewId;
        let activeSurface = session.activeSurface;

        if (drivePreviews.length === 0) {
          activeDrivePreviewId = undefined;
          if (closingActive)
            activeSurface = session.chats.length
              ? "chat"
              : session.browserPages.length
                ? "browser"
                : "history";
        } else if (closingActive) {
          // Closing the active tab lands on its neighbour, the way the browser
          // tabs behave, so the panel never blanks between two open files.
          const next =
            drivePreviews[Math.min(index, drivePreviews.length - 1)] ??
            drivePreviews[0];
          activeDrivePreviewId = next?.id;
          activeSurface = "drive";
        } else if (
          activeDrivePreviewId &&
          !drivePreviews.some((preview) => preview.id === activeDrivePreviewId)
        ) {
          activeDrivePreviewId = drivePreviews[0]?.id;
        }

        touchSidebarSession(sessions, key, {
          ...session,
          activeDrivePreviewId,
          activeSurface,
          drivePreviews,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const openSessionHistory = useCallback<ChatSidebarContextValue["openSessionHistory"]>(
    (host, target) => {
      const id = JSON.stringify([
        target.groupId,
        target.participant.conversationId,
        target.participant.participantId,
      ]);
      setRegistry((current) => {
        const sessions = updateSidebarSession(current.sessions, host, (session) => {
          const pages = session.historyPages ?? [];
          const page = { ...target, id };
          return {
            ...session,
            activeSurface: "history",
            activeHistoryPageId: id,
            // Keep navigation metadata bounded; reopening focuses the same tab.
            historyPages: pages.some((item) => item.id === id)
              ? pages.map((item) => (item.id === id ? page : item))
              : [...pages.slice(-23), page],
          };
        });
        return {
          ...current,
          sessions,
          openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
        };
      });
    },
    []
  );

  const selectHistoryPage = useCallback<ChatSidebarContextValue["selectHistoryPage"]>(
    (host, pageId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        if (!session?.historyPages?.some((page) => page.id === pageId)) return current;
        const sessions = new Map(current.sessions);
        touchSidebarSession(sessions, key, {
          ...session,
          activeSurface: "history",
          activeHistoryPageId: pageId,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  const closeHistoryPage = useCallback<ChatSidebarContextValue["closeHistoryPage"]>(
    (host, pageId) => {
      setRegistry((current) => {
        const key = chatSidebarHostKey(host);
        const session = current.sessions.get(key);
        const index =
          session?.historyPages?.findIndex((page) => page.id === pageId) ?? -1;
        if (!session || index < 0) return current;
        const historyPages = session.historyPages!.filter((page) => page.id !== pageId);
        const closingActive =
          session.activeSurface === "history" && session.activeHistoryPageId === pageId;
        const sessions = new Map(current.sessions);
        const activeHistoryPageId =
          session.activeHistoryPageId === pageId
            ? historyPages[Math.min(index, historyPages.length - 1)]?.id
            : session.activeHistoryPageId;
        const activeSurface =
          closingActive && !historyPages.length
            ? session.browserPages.length
              ? "browser"
              : session.chats.length
                ? "chat"
                : "drive"
            : session.activeSurface;
        touchSidebarSession(sessions, key, {
          ...session,
          historyPages,
          activeHistoryPageId,
          activeSurface,
        });
        return { ...current, sessions };
      });
    },
    []
  );

  // Navigation revision, metadata, and bounded retention are modeled in
  // tla/browser-sidebar/BrowserSidebar.tla.
  const updateBrowserPage = useCallback<ChatSidebarContextValue["updateBrowserPage"]>(
    (host, pageId, patch) => {
      setRegistry((current) => {
        const sessions = updateBrowserPageInRegistry(
          current.sessions,
          host,
          pageId,
          patch,
          true
        );
        if (sessions === current.sessions) return current;
        return {
          ...current,
          openSessionKeys: pruneOpenSidebarSessions(current.openSessionKeys, sessions),
          sessions,
        };
      });
    },
    []
  );

  const updateBrowserPageMetadata = useCallback<
    ChatSidebarContextValue["updateBrowserPageMetadata"]
  >((host, pageId, patch) => {
    setRegistry((current) => {
      const sessions = updateBrowserPageInRegistry(
        current.sessions,
        host,
        pageId,
        patch,
        false
      );
      return sessions === current.sessions ? current : { ...current, sessions };
    });
  }, []);

  const setWidth = useCallback<ChatSidebarWidthContextValue["setWidth"]>(
    (nextWidth) => {
      // The upper bound is dynamic (product route minimum) and enforced by the
      // sidebar itself; keep the floor here.
      setWidthState(Math.max(Math.round(nextWidth), commaChatSidebarMinWidth));
    },
    []
  );

  const activeSession = registry.activeHost
    ? registry.sessions.get(chatSidebarHostKey(registry.activeHost))
    : undefined;
  const isOpen = Boolean(
    registry.activeHost &&
    activeSession &&
    registry.openSessionKeys.has(chatSidebarHostKey(registry.activeHost))
  );
  const value = useMemo<ChatSidebarContextValue>(
    () => ({
      activeHost: registry.activeHost,
      activeSession,
      addBrowserTab,
      canOpenChildChat: (host) =>
        registry.commaCenterLineage.has(chatSidebarHostKey(host)),
      closeBrowserPage,
      closeChat,
      closeDrivePreview,
      closeHistoryPage,
      getNativeBrowserCapacityBlockedEpoch,
      isOpen,
      nativeBrowserCapacityEpoch,
      nativeBrowserStates,
      openBrowser,
      openChat,
      openDrivePreview,
      openFilePreview,
      selectFilePreview,
      closeFilePreview,
      openSessionHistory,
      pendingTrailingWidth,
      registerHost,
      recordNativeBrowserState,
      selectBrowserPage,
      selectChat,
      selectDrivePreview,
      selectHistoryPage,
      toggle,
      toggleActive,
      trailingRef,
      updateBrowserPage,
      updateBrowserPageMetadata,
    }),
    [
      activeSession,
      addBrowserTab,
      closeBrowserPage,
      closeChat,
      closeDrivePreview,
      closeHistoryPage,
      getNativeBrowserCapacityBlockedEpoch,
      isOpen,
      nativeBrowserCapacityEpoch,
      nativeBrowserStates,
      openBrowser,
      openChat,
      openDrivePreview,
      openFilePreview,
      selectFilePreview,
      closeFilePreview,
      openSessionHistory,
      pendingTrailingWidth,
      registerHost,
      recordNativeBrowserState,
      registry.activeHost,
      registry.commaCenterLineage,
      selectBrowserPage,
      selectChat,
      selectDrivePreview,
      selectHistoryPage,
      toggle,
      toggleActive,
      updateBrowserPage,
      updateBrowserPageMetadata,
    ]
  );
  const widthValue = useMemo<ChatSidebarWidthContextValue>(
    () => ({ setWidth, width }),
    [setWidth, width]
  );

  return (
    <ChatSidebarContext.Provider value={value}>
      <ChatSidebarWidthContext.Provider value={widthValue}>
        {children}
      </ChatSidebarWidthContext.Provider>
    </ChatSidebarContext.Provider>
  );
}

export function useChatSidebarWidth() {
  const context = useContext(ChatSidebarWidthContext);
  if (!context) {
    throw new Error("useChatSidebarWidth must be used within ChatSidebarProvider");
  }
  return context;
}

export function useChatSidebar() {
  const context = useContext(ChatSidebarContext);
  if (!context) {
    throw new Error("useChatSidebar must be used within ChatSidebarProvider");
  }
  return context;
}

export function useOptionalChatSidebar() {
  return useContext(ChatSidebarContext);
}

export function useRegisterChatSidebarHost(
  host: ChatSidebarHost | undefined,
  options?: { commaCenter?: boolean | undefined }
) {
  const { registerHost } = useChatSidebar();
  const conversationId = host?.conversationId;
  const groupId = host?.groupId;
  const workspaceId = host?.workspaceId;
  const commaCenter = options?.commaCenter === true;

  useLayoutEffect(() => {
    if (!conversationId || !groupId || !workspaceId) return undefined;
    return registerHost({ conversationId, groupId, workspaceId }, { commaCenter });
  }, [conversationId, commaCenter, groupId, registerHost, workspaceId]);
}

export function chatSidebarHostKey(host: ChatSidebarHost) {
  return JSON.stringify([host.groupId, host.conversationId]);
}

export function chatSidebarBrowserPageSessionId(hostKey: string, pageId: string) {
  return `${hostKey}::${pageId}`;
}

export function browserPageLabel(page: ChatSidebarBrowserPage) {
  if (page.title?.trim()) return page.title.trim();
  if (!page.url) return "New tab";
  try {
    return new URL(page.url).hostname || page.url;
  } catch {
    return page.url;
  }
}

function createBrowserPageId() {
  return globalThis.crypto?.randomUUID?.() ?? `page-${Date.now()}-${Math.random()}`;
}

function createBlankBrowserPage(): ChatSidebarBrowserPage {
  return {
    id: createBrowserPageId(),
    navigationRevision: 0,
    url: "",
  };
}

function openRequestedBrowserTab(
  current: ChatSidebarRegistry,
  tabId: string,
  requestedUrl: string
): ChatSidebarRegistry {
  const url = safeBrowserUrl(requestedUrl);
  if (!url) return current;
  for (const session of current.sessions.values()) {
    if (session.browserPages.some((page) => page.id === tabId)) return current;
  }

  const host = current.activeHost ?? globalBrowserHost;
  const page: ChatSidebarBrowserPage = {
    id: tabId,
    navigationRevision: 1,
    url,
  };
  const sessions = updateSidebarSession(
    current.sessions,
    host,
    (session) => ({
      ...session,
      activeBrowserPageId: tabId,
      activeSurface: "browser",
      browserPages: [...session.browserPages, page],
    }),
    tabId
  );
  return {
    ...current,
    activeHost: host,
    openSessionKeys: openSidebarSession(current.openSessionKeys, sessions, host),
    sessions,
  };
}

function sameChatSidebarHost(
  left: ChatSidebarHost | undefined,
  right: ChatSidebarHost
) {
  return (
    left?.groupId === right.groupId && left.conversationId === right.conversationId
  );
}

function addLineage(
  current: ReadonlySet<string>,
  host: ChatSidebarHost
): ReadonlySet<string> {
  const key = chatSidebarHostKey(host);
  const lineage = new Set(current);
  lineage.delete(key);
  lineage.add(key);
  while (lineage.size > maxRememberedCommaLineageChats) {
    const oldestKey = lineage.values().next().value;
    if (typeof oldestKey !== "string") break;
    lineage.delete(oldestKey);
  }
  return lineage;
}

function updateSidebarSession(
  current: ReadonlyMap<string, ChatSidebarSession>,
  host: ChatSidebarHost,
  update: (session: ChatSidebarSession) => ChatSidebarSession,
  admissionPageId?: string
) {
  const key = chatSidebarHostKey(host);
  const sessions = new Map(current);
  const closeBeforeOpenSessionIds: string[] = [];
  const existing = sessions.get(key) ?? emptySession();
  touchSidebarSession(sessions, key, update(existing));
  while (sessions.size > maxBrowserSidebarSessionsPerOwner) {
    const oldestKey = sessions.keys().next().value;
    if (typeof oldestKey !== "string") break;
    const oldestSession = sessions.get(oldestKey);
    for (const page of oldestSession?.browserPages ?? []) {
      if (!page.url) continue;
      closeBeforeOpenSessionIds.push(
        chatSidebarBrowserPageSessionId(oldestKey, page.id)
      );
    }
    sessions.delete(oldestKey);
  }
  return limitBrowserPageSessions(
    sessions,
    admissionPageId
      ? { closeBeforeOpenSessionIds, hostKey: key, pageId: admissionPageId }
      : undefined
  );
}

// Map iteration order is the host LRU. Every successful product mutation
// removes and reinserts its host; observation-only native metadata must retain
// the existing position.
function touchSidebarSession(
  sessions: Map<string, ChatSidebarSession>,
  hostKey: string,
  session: ChatSidebarSession
) {
  sessions.delete(hostKey);
  sessions.set(hostKey, session);
}

function openSidebarSession(
  current: ReadonlySet<string>,
  sessions: ReadonlyMap<string, ChatSidebarSession>,
  host: ChatSidebarHost
) {
  const openSessionKeys = new Set(current);
  openSessionKeys.add(chatSidebarHostKey(host));
  return pruneOpenSidebarSessions(openSessionKeys, sessions);
}

function pruneOpenSidebarSessions(
  current: ReadonlySet<string>,
  sessions: ReadonlyMap<string, ChatSidebarSession>
) {
  const openSessionKeys = new Set(current);
  for (const key of openSessionKeys) {
    if (!sessions.has(key)) openSessionKeys.delete(key);
  }
  return openSessionKeys;
}

function updateBrowserPageInRegistry(
  current: ReadonlyMap<string, ChatSidebarSession>,
  host: ChatSidebarHost,
  pageId: string,
  patch: Partial<Pick<ChatSidebarBrowserPage, "title" | "url">>,
  navigationIntent: boolean
) {
  const key = chatSidebarHostKey(host);
  const session = current.get(key);
  if (!session) return current;
  const pageIndex = session.browserPages.findIndex((page) => page.id === pageId);
  if (pageIndex < 0) return current;
  const page = session.browserPages[pageIndex];
  if (!page) return current;

  const parsedUrl = patch.url === undefined ? undefined : safeBrowserUrl(patch.url);
  const nextUrl = parsedUrl ?? page.url;
  const nextTitle = patch.title === undefined ? page.title : patch.title;
  const shouldNavigate = navigationIntent && parsedUrl !== undefined;
  if (!shouldNavigate && nextUrl === page.url && nextTitle === page.title) {
    return current;
  }

  const browserPages = session.browserPages.slice();
  browserPages[pageIndex] = {
    ...page,
    title: nextTitle,
    url: nextUrl,
    navigationRevision: shouldNavigate
      ? page.navigationRevision + 1
      : page.navigationRevision,
  };
  const sessions = new Map(current);
  touchSidebarSession(sessions, key, { ...session, browserPages });
  return limitBrowserPageSessions(
    sessions,
    shouldNavigate && page.url === "" && nextUrl !== ""
      ? { closeBeforeOpenSessionIds: [], hostKey: key, pageId }
      : undefined
  );
}

function hasBrowserPageSession(
  sessions: ReadonlyMap<string, ChatSidebarSession>,
  sessionId: string
) {
  for (const [hostKey, session] of sessions) {
    if (
      session.browserPages.some(
        (page) => chatSidebarBrowserPageSessionId(hostKey, page.id) === sessionId
      )
    ) {
      return true;
    }
  }
  return false;
}

function updateBrowserPageFromNativeState(
  current: ChatSidebarRegistry,
  sessionId: string,
  state: BrowserSidebarState
): ChatSidebarRegistry {
  for (const [hostKey, session] of current.sessions) {
    const pageIndex = session.browserPages.findIndex(
      (page) => chatSidebarBrowserPageSessionId(hostKey, page.id) === sessionId
    );
    if (pageIndex < 0) continue;
    const page = session.browserPages[pageIndex];
    if (!page) return current;

    const nextUrl = state.url && state.url !== page.url ? state.url : page.url;
    const nextTitle = state.title === undefined ? page.title : state.title;
    if (nextUrl === page.url && nextTitle === page.title) return current;

    const browserPages = session.browserPages.slice();
    browserPages[pageIndex] = {
      ...page,
      title: nextTitle,
      url: nextUrl,
    };
    const sessions = new Map(current.sessions);
    // Native metadata is observation, not product activity, so preserve this
    // host's existing LRU position.
    sessions.set(hostKey, { ...session, browserPages });
    return { ...current, sessions };
  }
  return current;
}

function limitBrowserPageSessions(
  current: ReadonlyMap<string, ChatSidebarSession>,
  admission?: {
    closeBeforeOpenSessionIds: string[];
    hostKey: string;
    pageId: string;
  }
) {
  const openedPages = Array.from(current, ([hostKey, session]) =>
    session.browserPages
      .map((page) => ({ hostKey, page }))
      .filter(({ page }) => Boolean(page.url))
  ).flat();
  const overflow = openedPages.length - maxBrowserSidebarSessionsPerOwner;
  if (overflow <= 0) {
    return attachBrowserPageAdmissionFence(current, admission);
  }

  const evictionCandidates = [
    ...openedPages.filter(
      ({ hostKey, page }) => current.get(hostKey)?.activeBrowserPageId !== page.id
    ),
    ...openedPages.filter(
      ({ hostKey, page }) => current.get(hostKey)?.activeBrowserPageId === page.id
    ),
  ];
  const evictedPageIdsByHost = new Map<string, Set<string>>();
  for (const { hostKey, page } of evictionCandidates.slice(0, overflow)) {
    admission?.closeBeforeOpenSessionIds.push(
      chatSidebarBrowserPageSessionId(hostKey, page.id)
    );
    const pageIds = evictedPageIdsByHost.get(hostKey) ?? new Set<string>();
    pageIds.add(page.id);
    evictedPageIdsByHost.set(hostKey, pageIds);
  }

  const sessions = new Map(current);
  for (const [hostKey, evictedPageIds] of evictedPageIdsByHost) {
    const session = sessions.get(hostKey);
    if (!session) continue;
    const activePageIndex = session.browserPages.findIndex(
      (page) => page.id === session.activeBrowserPageId
    );
    const browserPages = session.browserPages.filter(
      (page) => !evictedPageIds.has(page.id)
    );
    if (
      browserPages.length === 0 &&
      !session.chats.length &&
      session.drivePreviews.length === 0 &&
      !session.historyPages?.length &&
      !session.filePreviews?.length
    ) {
      sessions.delete(hostKey);
      continue;
    }

    const activeBrowserPageRemoved =
      session.activeBrowserPageId !== undefined &&
      evictedPageIds.has(session.activeBrowserPageId);
    const activeBrowserPageId =
      browserPages.length === 0
        ? undefined
        : activeBrowserPageRemoved
          ? (browserPages[Math.min(activePageIndex, browserPages.length - 1)]?.id ??
            browserPages[0]?.id)
          : (session.activeBrowserPageId ?? browserPages[0]?.id);
    sessions.set(hostKey, {
      ...session,
      activeBrowserPageId,
      activeSurface:
        session.activeSurface === "browser" && browserPages.length === 0
          ? session.chats.length
            ? "chat"
            : session.drivePreviews.length
              ? "drive"
              : "history"
          : session.activeSurface,
      browserPages,
    });
  }
  return attachBrowserPageAdmissionFence(sessions, admission);
}

function attachBrowserPageAdmissionFence(
  current: ReadonlyMap<string, ChatSidebarSession>,
  admission:
    | {
        closeBeforeOpenSessionIds: string[];
        hostKey: string;
        pageId: string;
      }
    | undefined
) {
  if (!admission || admission.closeBeforeOpenSessionIds.length === 0) {
    return current;
  }
  const session = current.get(admission.hostKey);
  const pageIndex = session?.browserPages.findIndex(
    (page) => page.id === admission.pageId
  );
  if (!session || pageIndex === undefined || pageIndex < 0) return current;
  const page = session.browserPages[pageIndex];
  if (!page) return current;

  const browserPages = session.browserPages.slice();
  browserPages[pageIndex] = {
    ...page,
    closeBeforeOpenSessionIds: Array.from(
      new Set([
        ...(page.closeBeforeOpenSessionIds ?? []),
        ...admission.closeBeforeOpenSessionIds,
      ])
    ),
  };
  const sessions = new Map(current);
  sessions.set(admission.hostKey, { ...session, browserPages });
  return sessions;
}

function safeBrowserUrl(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.toString()
      : undefined;
  } catch {
    return undefined;
  }
}
