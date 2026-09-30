import { PageLoading } from "@comma/ui";
import type { SideChatPresentation } from "@comma/chat-contract";
import { useCommaMessages } from "@comma/i18n/react";
import {
  compactTypeScale,
  SideChatPanel,
  SideChatStatus,
  SideChatSurface,
} from "@comma/ui";
import {
  useCallback,
  useEffect,
  memo,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import type { CommaApiClient } from "../../../api";
import {
  closeNativeSideChat,
  openNativeMainWindow,
  setNativeSideChatContentSize,
  subscribeNativeSideChatPresentation,
} from "../../../runtime-side-chat/nativeSideChat";
import { CommaAuthGate, useCommaAuth } from "../../AuthGate";
import {
  CommaAppearanceProvider,
  commaFontSizeScale,
  useCommaAppearance,
} from "../../commaAppearance";
import { CommaUiThemeProvider } from "../../commaUiTheme";
import { useSideChatAppearance, useSideChatThemeName } from "../../sideChatAppearance";
import { ChatProvider } from "../ChatProvider";
import { Composer } from "../composer/Composer";
import { fixedDraftSource } from "../composer/conversationDraft";
import {
  ConversationView,
  type ConversationViewActions,
} from "../conversation/ConversationView";
import { sideChatInlineTaskLinkAdapter } from "./sideChatInlineTaskLink";
import { useWorkspaceChat } from "../useWorkspaceChat";
import { useConversation } from "../conversation/useConversation";
import { useWorkspaceSkills } from "../useWorkspaceSkills";

const SIDE_CHAT_WIDTH = 364;
const SIDE_CHAT_LEFT = 5;
const SIDE_CHAT_BOTTOM = -9;
const SIDE_CHAT_MIN_HEIGHT = 215;
const SIDE_CHAT_FALLBACK_MAX_HEIGHT = 640;
const SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT = 20;
const SIDE_CHAT_INPUT_MAX_TEXTAREA_HEIGHT = 80;
// ChatPanelImageGroup uses 165px-wide 3:4 cards. The Side Chat transcript has
// room for one card per row after its 24px inline padding and the group's 26px
// fan allowances, so 1-3 images must reserve their actual wrapped card height.
const SIDE_CHAT_IMAGE_CARD_HEIGHT = 220;
const SIDE_CHAT_IMAGE_GROUP_BLOCK_ALLOWANCE = 16;
const SIDE_CHAT_IMAGE_GROUP_ROW_GAP = 8;
const SIDE_CHAT_IMAGE_GROUP_STACK_CONTROLS_HEIGHT = 30;
// Panel padding (36px) + composer zone (50px).
// The status card reports its own natural height separately so fallback copy
// can grow the native surface without stealing space from adjacent rows.
const SIDE_CHAT_FALLBACK_CHROME_HEIGHT = 86;

type SideChatHeightReporter = (visibleHeight: number, nativeHeight?: number) => void;

export function SideChatApp() {
  return (
    <CommaAppearanceProvider>
      <SideChatRuntime />
    </CommaAppearanceProvider>
  );
}

function SideChatRuntime() {
  const [preferredHeights, setPreferredHeights] = useState({
    native: SIDE_CHAT_MIN_HEIGHT,
    visible: SIDE_CHAT_MIN_HEIGHT,
  });
  const reportPreferredHeight = useCallback<SideChatHeightReporter>(
    (visible, native = visible) => {
      setPreferredHeights((current) =>
        current.visible === visible && current.native === native
          ? current
          : { native, visible }
      );
    },
    []
  );

  useSideChatDocumentRole();

  return (
    <SideChatPresentationShell
      nativePreferredHeight={preferredHeights.native}
      preferredHeight={preferredHeights.visible}
    >
      <SideChatContent onPreferredHeight={reportPreferredHeight} />
    </SideChatPresentationShell>
  );
}

const SideChatContent = memo(function SideChatContent({
  onPreferredHeight,
}: {
  onPreferredHeight: SideChatHeightReporter;
}) {
  return (
    <CommaAuthGate
      signedOutFallback={<SideChatSignedOut onPreferredHeight={onPreferredHeight} />}
    >
      <SideChatAuthenticated onPreferredHeight={onPreferredHeight} />
    </CommaAuthGate>
  );
});

function SideChatPresentationShell({
  children,
  nativePreferredHeight,
  preferredHeight,
}: {
  children: ReactNode;
  nativePreferredHeight: number;
  preferredHeight: number;
}) {
  const appearance = useSideChatAppearance();
  const theme = useSideChatThemeName(appearance);
  const rootRef = useRef<HTMLElement | null>(null);
  const { layout, presentationRef } = useSideChatPresentation(rootRef);
  const availableHeight = layout.availableContentHeight;
  const height = clamp(
    preferredHeight,
    SIDE_CHAT_MIN_HEIGHT,
    availableHeight > 0 ? availableHeight : SIDE_CHAT_FALLBACK_MAX_HEIGHT
  );
  const nativeHeight = clamp(
    Math.max(nativePreferredHeight, preferredHeight),
    SIDE_CHAT_MIN_HEIGHT,
    availableHeight > 0 ? availableHeight : SIDE_CHAT_FALLBACK_MAX_HEIGHT
  );
  const presentation = presentationRef.current;

  useReportSideChatSize(rootRef, nativeHeight, height);

  useEffect(() => {
    if (layout.phase !== "open") return;
    const animationFrame = window.requestAnimationFrame(() => {
      rootRef.current
        ?.querySelector<HTMLTextAreaElement>("textarea")
        ?.focus({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(animationFrame);
  }, [layout.phase]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) {
        return;
      }
      event.preventDefault();
      void closeNativeSideChat().catch((error: unknown) => {
        console.error("[side-chat] close handoff failed", error);
      });
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  return (
    <CommaUiThemeProvider theme={theme}>
      <SideChatSurface
        bottom={layout.bottom}
        height={height}
        left={layout.left}
        phase={presentation?.phase ?? "closed"}
        presentationReady={Boolean(presentation)}
        progress={presentation?.progress ?? 0}
        ref={rootRef}
        theme={theme}
        width={layout.width}
      >
        {children}
      </SideChatSurface>
    </CommaUiThemeProvider>
  );
}

function SideChatAuthenticated({
  onPreferredHeight,
}: {
  onPreferredHeight: SideChatHeightReporter;
}) {
  const { api, productLease, sessionSignal } = useCommaAuth();

  return (
    <ChatProvider api={api} productLease={productLease} sessionSignal={sessionSignal}>
      <SideChatConversationResolver api={api} onPreferredHeight={onPreferredHeight} />
    </ChatProvider>
  );
}

function SideChatConversationResolver({
  api,
  onPreferredHeight,
}: {
  api: CommaApiClient;
  onPreferredHeight: SideChatHeightReporter;
}) {
  const m = useCommaMessages();
  const { retry, state } = useWorkspaceChat({ api, nativeDefault: true });

  if (state.status === "loading") {
    return (
      <SideChatFallbackPanel
        loading
        onPreferredHeight={onPreferredHeight}
        title={m.side_chat_connecting()}
      />
    );
  }

  if (state.status === "provisioning") {
    return (
      <SideChatFallbackPanel
        action={
          <button className="comma-chat-link-button" onClick={retry} type="button">
            {m.common_retry_now()}
          </button>
        }
        detail={m.side_chat_preparing_detail()}
        onPreferredHeight={onPreferredHeight}
        title={m.side_chat_preparing_title()}
      />
    );
  }

  if (state.status === "unauthorized") {
    return (
      <SideChatFallbackPanel
        detail={m.side_chat_session_expired_detail()}
        onPreferredHeight={onPreferredHeight}
        title={m.side_chat_session_expired()}
      />
    );
  }

  if (state.status === "hidden") {
    return (
      <SideChatFallbackPanel
        detail={m.side_chat_unavailable_detail()}
        onPreferredHeight={onPreferredHeight}
        title={m.side_chat_unavailable()}
      />
    );
  }

  if (state.status === "error") {
    return (
      <SideChatFallbackPanel
        action={
          <button className="comma-chat-link-button" onClick={retry} type="button">
            {m.common_retry()}
          </button>
        }
        detail={state.message}
        onPreferredHeight={onPreferredHeight}
        title={m.side_chat_connect_failed()}
      />
    );
  }

  return (
    <SideChatConversation
      api={api}
      conversationId={state.conversation.id}
      groupId={state.groupId}
      key={`${state.groupId}/${state.conversation.id}`}
      onPreferredHeight={onPreferredHeight}
      workspaceId={state.workspaceId}
    />
  );
}

function SideChatConversation({
  api,
  conversationId,
  groupId,
  onPreferredHeight,
  workspaceId,
}: {
  api: CommaApiClient;
  conversationId: string;
  groupId: string;
  onPreferredHeight: SideChatHeightReporter;
  workspaceId: string;
}) {
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const { fontSize } = useCommaAppearance();
  const skills = useWorkspaceSkills(api, workspaceId);
  const [composerContentHeight, setComposerContentHeight] = useState(
    SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT
  );
  const [composerNoticeHeight, setComposerNoticeHeight] = useState(0);
  // Depend on the stable per-channel action identities, not the conversation
  // object (whose identity changes on every state emit).
  const actions = useMemo<ConversationViewActions>(
    () => ({
      attachFiles: conversation.attachFiles,
      discard: conversation.discard,
      ...(conversation.pickAttachments
        ? { pickAttachments: conversation.pickAttachments }
        : {}),
      ...(conversation.previewLocalFile
        ? { previewLocalFile: conversation.previewLocalFile }
        : {}),
      refresh: conversation.refresh,
      removeAttachment: conversation.removeAttachment,
      retry: conversation.retry,
      retryAttachment: conversation.retryAttachment,
      send: conversation.send,
      setDraft: conversation.setDraft,
    }),
    [
      conversation.attachFiles,
      conversation.discard,
      conversation.pickAttachments,
      conversation.previewLocalFile,
      conversation.refresh,
      conversation.removeAttachment,
      conversation.retry,
      conversation.retryAttachment,
      conversation.send,
      conversation.setDraft,
    ]
  );
  const preferredHeights = useMemo(() => {
    const messages = conversation.state.messages.map((message) => ({
      files: message.attachments.filter(
        (attachment) => attachment.blockType !== "image" || !attachment.localFileRef
      ).length,
      images: message.attachments.filter(
        (attachment) =>
          attachment.blockType === "image" && Boolean(attachment.localFileRef)
      ).length,
      text: message.text,
    }));
    const assistantDraft = conversation.state.assistantDraft?.text;
    const messageLineHeight =
      compactTypeScale.regular.lineHeight * commaFontSizeScale[fontSize];
    return {
      native: estimateSideChatHeight(
        messages,
        assistantDraft,
        Math.max(composerContentHeight, SIDE_CHAT_INPUT_MAX_TEXTAREA_HEIGHT) +
          composerNoticeHeight,
        messageLineHeight
      ),
      visible: estimateSideChatHeight(
        messages,
        assistantDraft,
        composerContentHeight + composerNoticeHeight,
        messageLineHeight
      ),
    };
  }, [
    composerContentHeight,
    composerNoticeHeight,
    conversation.state.assistantDraft?.text,
    conversation.state.messages,
    fontSize,
  ]);

  useEffect(() => {
    onPreferredHeight(preferredHeights.visible, preferredHeights.native);
  }, [onPreferredHeight, preferredHeights]);

  return (
    <SideChatPanel>
      <ConversationView
        actions={actions}
        api={api}
        groupId={groupId}
        conversationId={conversationId}
        draftSource={conversation.draftSource}
        inlineTaskLinkAdapter={sideChatInlineTaskLinkAdapter}
        onComposerContentHeightChange={setComposerContentHeight}
        onComposerNoticeHeightChange={setComposerNoticeHeight}
        skills={skills}
        state={conversation.state}
        variant="side-chat"
        workspaceId={workspaceId}
      />
    </SideChatPanel>
  );
}

function SideChatSignedOut({
  onPreferredHeight,
}: {
  onPreferredHeight: SideChatHeightReporter;
}) {
  const m = useCommaMessages();

  return (
    <SideChatFallbackPanel
      action={
        <button
          className="comma-chat-link-button comma-side-chat-sign-in-button"
          onClick={openSideChatSignIn}
          type="button"
        >
          {m.side_chat_sign_in_action()}
        </button>
      }
      detail={m.side_chat_signed_out_detail()}
      onPreferredHeight={onPreferredHeight}
      title={m.side_chat_signed_out()}
    />
  );
}

function openSideChatSignIn() {
  void openNativeMainWindow().catch((error: unknown) => {
    console.error("[side-chat] failed to open the sign-in window", error);
  });
}

function SideChatFallbackPanel({
  loading = false,
  action,
  detail,
  onPreferredHeight,
  title,
}: {
  loading?: boolean;
  action?: ReactNode;
  detail?: string;
  onPreferredHeight: SideChatHeightReporter;
  title: string;
}) {
  const m = useCommaMessages();
  const [draft, setDraft] = useState("");
  const draftSource = useMemo(() => fixedDraftSource(draft), [draft]);
  const [composerContentHeight, setComposerContentHeight] = useState(
    SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT
  );
  const [statusRequiredHeight, setStatusRequiredHeight] = useState(0);
  const fallbackBaseHeight = Math.max(
    SIDE_CHAT_MIN_HEIGHT,
    SIDE_CHAT_FALLBACK_CHROME_HEIGHT + statusRequiredHeight
  );
  const preferredVisibleHeight =
    fallbackBaseHeight +
    Math.max(0, composerContentHeight - SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT);
  const preferredNativeHeight =
    fallbackBaseHeight +
    Math.max(
      0,
      Math.max(composerContentHeight, SIDE_CHAT_INPUT_MAX_TEXTAREA_HEIGHT) -
        SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT
    );

  useEffect(() => {
    onPreferredHeight(preferredVisibleHeight, preferredNativeHeight);
  }, [onPreferredHeight, preferredNativeHeight, preferredVisibleHeight]);

  return (
    <SideChatPanel>
      <section
        className="comma-chat-route comma-side-chat-fallback flex min-h-0 w-full min-w-0 flex-1 flex-col bg-primary"
        data-variant="side-chat"
      >
        {loading ? (
          <PageLoading label={title} />
        ) : (
          <SideChatStatus
            {...(action !== undefined ? { action } : {})}
            {...(detail !== undefined ? { detail } : {})}
            onRequiredHeight={setStatusRequiredHeight}
            title={title}
          />
        )}
        <div className="comma-chat-composer-zone">
          <div className="comma-chat-composer-frame">
            <Composer
              draftSource={draftSource}
              onContentHeightChange={setComposerContentHeight}
              onDraftChange={setDraft}
              onSend={() => undefined}
              placeholder={m.chat_side_composer_placeholder()}
              submitDisabled
              variant="side-chat"
            />
          </div>
        </div>
      </section>
    </SideChatPanel>
  );
}

type SideChatPresentationLayout = Pick<
  SideChatPresentation,
  "availableContentHeight" | "phase"
> & {
  bottom: number;
  left: number;
  width: number;
};

const defaultSideChatPresentationLayout: SideChatPresentationLayout = {
  availableContentHeight: 0,
  bottom: SIDE_CHAT_BOTTOM,
  left: SIDE_CHAT_LEFT,
  phase: "closed",
  width: SIDE_CHAT_WIDTH,
};

function sideChatPresentationLayout(
  presentation: SideChatPresentation
): SideChatPresentationLayout {
  const { contentFrame, windowFrame } = presentation;
  const unavailable = contentFrame.width <= 0 || windowFrame.width <= 0;
  return {
    availableContentHeight: presentation.availableContentHeight,
    bottom: unavailable ? SIDE_CHAT_BOTTOM : contentFrame.y - windowFrame.y,
    left: unavailable ? SIDE_CHAT_LEFT : contentFrame.x - windowFrame.x,
    phase: presentation.phase,
    width: unavailable ? SIDE_CHAT_WIDTH : contentFrame.width,
  };
}

function useSideChatPresentation(rootRef: RefObject<HTMLElement | null>) {
  const presentationRef = useRef<SideChatPresentation | null>(null);
  const [layout, setLayout] = useState<SideChatPresentationLayout>(
    defaultSideChatPresentationLayout
  );
  const layoutRef = useRef(layout);

  useEffect(
    () =>
      subscribeNativeSideChatPresentation((next) => {
        const current = presentationRef.current;
        if (current && next.revision < current.revision) {
          return;
        }
        presentationRef.current = next;

        const element = rootRef.current;
        if (element) {
          element.dataset.phase = next.phase;
          element.dataset.presentationReady = "true";
          element.dataset.progress = String(next.progress);
        }

        const currentLayout = layoutRef.current;
        const nextLayout = sideChatPresentationLayout(next);
        if (
          currentLayout.availableContentHeight !== nextLayout.availableContentHeight ||
          currentLayout.bottom !== nextLayout.bottom ||
          currentLayout.left !== nextLayout.left ||
          currentLayout.phase !== nextLayout.phase ||
          currentLayout.width !== nextLayout.width
        ) {
          layoutRef.current = nextLayout;
          setLayout(nextLayout);
        }
      }),
    [rootRef]
  );

  return { layout, presentationRef };
}

function useSideChatDocumentRole() {
  useEffect(() => {
    const previousDocumentRole = document.documentElement.dataset.commaWindowRole;
    const previousBodyRole = document.body.dataset.commaWindowRole;
    document.documentElement.dataset.commaWindowRole = "side-chat";
    document.body.dataset.commaWindowRole = "side-chat";
    return () => {
      if (previousDocumentRole === undefined) {
        delete document.documentElement.dataset.commaWindowRole;
      } else {
        document.documentElement.dataset.commaWindowRole = previousDocumentRole;
      }
      if (previousBodyRole === undefined) {
        delete document.body.dataset.commaWindowRole;
      } else {
        document.body.dataset.commaWindowRole = previousBodyRole;
      }
    };
  }, []);
}

function useReportSideChatSize(
  rootRef: RefObject<HTMLElement | null>,
  preferredHeight: number,
  visibleHeight: number
) {
  useEffect(() => {
    const element = rootRef.current;
    if (!element) {
      return;
    }

    let animationFrame: number | undefined;
    let lastSize = "";
    const report = (contentRect?: DOMRectReadOnly) => {
      if (animationFrame !== undefined) {
        window.cancelAnimationFrame(animationFrame);
      }
      animationFrame = window.requestAnimationFrame(() => {
        animationFrame = undefined;
        const rect = contentRect ?? element.getBoundingClientRect();
        const width = clamp(
          Math.ceil(Math.max(rect.width, element.scrollWidth, SIDE_CHAT_WIDTH)),
          120,
          1_024
        );
        const height = clamp(
          Math.ceil(Math.max(rect.height, element.scrollHeight, preferredHeight)),
          40,
          4_096
        );
        // Same source as SideChatSurface.height; reserve size never defines paint.
        const visualHeight = clamp(Math.ceil(visibleHeight), 40, height);
        const sizeKey = `${width}x${height}:${visualHeight}`;
        if (sizeKey === lastSize) {
          return;
        }
        lastSize = sizeKey;
        void setNativeSideChatContentSize({ height, visualHeight, width }).catch(
          (error: unknown) => {
            console.error("[side-chat] content-size handoff failed", error);
          }
        );
      });
    };

    report();
    if (typeof ResizeObserver === "undefined") {
      return () => {
        if (animationFrame !== undefined) {
          window.cancelAnimationFrame(animationFrame);
        }
      };
    }

    const observer = new ResizeObserver((entries) => {
      report(entries.at(-1)?.contentRect);
    });
    observer.observe(element);
    return () => {
      observer.disconnect();
      if (animationFrame !== undefined) {
        window.cancelAnimationFrame(animationFrame);
      }
    };
  }, [preferredHeight, visibleHeight, rootRef]);
}

function estimateSideChatHeight(
  messages: { files: number; images: number; text: string }[],
  assistantDraft: string | undefined,
  composerContentHeight: number,
  messageLineHeight: number
) {
  const content = assistantDraft
    ? [...messages, { files: 0, images: 0, text: assistantDraft }]
    : messages;
  if (content.length === 0) {
    // Keep room for the empty card as the composer grows, just as we do for
    // message content below. The bottom-anchored surface expands upward.
    return (
      SIDE_CHAT_MIN_HEIGHT +
      Math.max(0, composerContentHeight - SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT)
    );
  }

  const messageContentHeight = content.reduce((height, message) => {
    const lines = Math.max(
      1,
      message.text
        .split("\n")
        .reduce((total, line) => total + Math.max(1, Math.ceil(line.length / 34)), 0)
    );
    const imageGroupHeight =
      message.images === 0
        ? 0
        : message.images <= 3
          ? SIDE_CHAT_IMAGE_GROUP_BLOCK_ALLOWANCE +
            message.images * SIDE_CHAT_IMAGE_CARD_HEIGHT +
            (message.images - 1) * SIDE_CHAT_IMAGE_GROUP_ROW_GAP
          : SIDE_CHAT_IMAGE_GROUP_BLOCK_ALLOWANCE +
            SIDE_CHAT_IMAGE_CARD_HEIGHT +
            SIDE_CHAT_IMAGE_GROUP_STACK_CONTROLS_HEIGHT;
    const attachmentGap = imageGroupHeight > 0 && message.files > 0 ? 6 : 0;
    return (
      height +
      Math.max(40, lines * messageLineHeight + 20) +
      imageGroupHeight +
      attachmentGap +
      message.files * 30
    );
  }, 0);
  const spacing = Math.max(0, content.length - 1) * 10;
  return Math.max(
    SIDE_CHAT_MIN_HEIGHT,
    144 +
      messageContentHeight +
      spacing +
      Math.max(0, composerContentHeight - SIDE_CHAT_INPUT_MIN_CONTENT_HEIGHT)
  );
}

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value));
}
