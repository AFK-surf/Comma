import type { ChatTarget } from "@comma/chat-contract";
import type { CommaConversation } from "@comma/app/api";
import type { ChatMessage } from "@comma/app/chat-runtime";
import { baseLocale, messages as i18n, type CommaLocale } from "@comma/i18n";

// The banner wraps the body to a few lines and fades out the overflow itself,
// so visual truncation belongs to the platform. This budget only keeps the
// payload small; it sits far past anything a banner renders, so the cut is
// never visible and never competes with the native fade.
const NOTIFICATION_BODY_MAX_CHARS = 500;

export interface MessageNotificationShowInput {
  body: string;
  onClick: () => void;
  onReply: (text: string) => void;
  /** Whether the banner carries Comma's sound; the OS switch still applies. */
  playSound: boolean;
  replyPlaceholder: string;
  title: string;
}

export interface MessageNotificationsPlatform {
  /** Removes every banner still delivered. */
  dismissAll(): void;
  isAppFocused(): boolean;
  isSupported(): boolean;
  /** Fires whenever a Comma window comes to the foreground; returns the unsubscribe. */
  onAppFocused(listener: () => void): () => void;
  /**
   * Shows the count on the app icon; zero clears it. The OS applies the
   * user's "Badge application icon" switch.
   */
  setBadgeCount(count: number): void;
  /** Resolves with whether the OS took the banner. */
  show(input: MessageNotificationShowInput): Promise<boolean>;
}

export interface MessageNotificationsPreferences {
  notificationSound: boolean;
  notifyRouterMessages: boolean;
  systemNotifications: boolean;
}

export interface MessageNotificationEmission {
  target: { conversationId: string; groupId: string; workspaceId: string };
  type: "clicked";
}

export function boundNotificationBody(
  text: string,
  maxChars = NOTIFICATION_BODY_MAX_CHARS
): string {
  return text.length <= maxChars ? text : text.slice(0, maxChars);
}

// Router attribution: the server stamps actor_role only on agent_task
// conversations, so an unattributed assistant message in a user_chat is the
// Router replying in Home chat.
function isRouterMessage(
  message: ChatMessage,
  conversation: CommaConversation
): boolean {
  if (message.role !== "assistant") return false;
  if (message.text.trim() === "") return false;
  if (message.actorRole === "router") return true;
  return message.actorRole === undefined && conversation.kind === "user_chat";
}

export class MessageNotificationsService {
  readonly #platform: MessageNotificationsPlatform;
  readonly #preferences: () => MessageNotificationsPreferences;
  readonly #emitEvent: (payload: MessageNotificationEmission) => void;
  readonly #onDeliveryRefused: () => void;
  readonly #sendReply: (target: ChatTarget, text: string) => Promise<void>;
  readonly #locale: CommaLocale;
  readonly #productName: string;
  readonly #log: { warn: (message: string) => void };
  // Router messages delivered since the user was last in Comma.
  #unseenCount = 0;
  // Counts returns to Comma, so a delivery that settles after one is not
  // added to a badge the user has already cleared.
  #focusGeneration = 0;

  constructor({
    emitEvent,
    locale = baseLocale,
    log,
    onDeliveryRefused,
    platform,
    preferences,
    productName,
    sendReply,
  }: {
    emitEvent: (payload: MessageNotificationEmission) => void;
    locale?: CommaLocale;
    log: { warn: (message: string) => void };
    /**
     * The OS took none of the banners just raised. The authorization the
     * Settings switch reads back is stale at that point, so the owner
     * re-reads it.
     */
    onDeliveryRefused: () => void;
    platform: MessageNotificationsPlatform;
    preferences: () => MessageNotificationsPreferences;
    productName: string;
    sendReply: (target: ChatTarget, text: string) => Promise<void>;
  }) {
    this.#emitEvent = emitEvent;
    this.#locale = locale;
    this.#log = log;
    this.#onDeliveryRefused = onDeliveryRefused;
    this.#platform = platform;
    this.#preferences = preferences;
    this.#productName = productName;
    this.#sendReply = sendReply;
    // A banner exists to bring the user back. Once they are here, whatever
    // is still listed in Notification Center is stale and would only be
    // read a second time, and the badge counts messages already in view.
    platform.onAppFocused(() => {
      this.#focusGeneration += 1;
      platform.dismissAll();
      if (this.#unseenCount === 0) return;
      this.#unseenCount = 0;
      platform.setBadgeCount(0);
    });
  }

  async handleAppendedMessages({
    conversation,
    messages,
    target,
  }: {
    conversation: CommaConversation;
    messages: readonly ChatMessage[];
    target: ChatTarget;
  }): Promise<void> {
    if (!this.#platform.isSupported()) return;
    const preferences = this.#preferences();
    // System notifications is the master switch; Router messages is one
    // kind of notification under it.
    if (!preferences.systemNotifications) return;
    if (!preferences.notifyRouterMessages) return;
    if (this.#platform.isAppFocused()) return;

    const routerMessages = messages.filter((message) =>
      isRouterMessage(message, conversation)
    );
    if (routerMessages.length === 0) return;

    const eventTarget = {
      conversationId: target.conversationId,
      groupId: target.groupId,
      workspaceId: target.workspaceId,
    };

    const focusGeneration = this.#focusGeneration;
    let deliveredCount = 0;
    for (const message of routerMessages) {
      // A focus event also cancels banners not yet submitted to the OS.
      if (focusGeneration !== this.#focusGeneration) return;
      const delivered = await this.#platform.show({
        body: boundNotificationBody(message.text),
        onClick: () => {
          this.#emitEvent({ target: eventTarget, type: "clicked" });
        },
        onReply: (text) => {
          void this.#sendReply(target, text).catch((error: unknown) => {
            this.#log.warn(
              `Notification reply failed to send: ${
                error instanceof Error ? error.message : String(error)
              }`
            );
          });
        },
        // Keep the sound until the OS accepts a banner.
        playSound: preferences.notificationSound && deliveredCount === 0,
        replyPlaceholder: i18n.electron_notification_reply_placeholder(
          {},
          { locale: this.#locale }
        ),
        // The Router speaks as Comma. The Home chat's server title ("Bridge
        // chat") names storage, not who is talking; a task keeps its own.
        title:
          conversation.kind === "user_chat"
            ? i18n.electron_notification_router_title({}, { locale: this.#locale })
            : conversation.title.trim() || this.#productName,
      });
      if (delivered) deliveredCount += 1;
    }

    if (deliveredCount === 0) {
      this.#onDeliveryRefused();
      return;
    }
    if (focusGeneration !== this.#focusGeneration) return;
    this.#unseenCount += deliveredCount;
    this.#platform.setBadgeCount(this.#unseenCount);
  }
}
