// Main's part of message notifications: the system banners and the app icon's badge. The client core says which
// messages get a banner and words it (`chatAppended`: title, body, reply placeholder); Main shows them while the
// person is away from Comma and its notification settings allow, and acts on a banner's click and reply.
import type { ChatTarget } from "@comma/chat-contract";
import type { ChatAppendedValue } from "@comma/core/contract";

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

export class MessageNotificationsService {
  readonly #platform: MessageNotificationsPlatform;
  readonly #preferences: () => MessageNotificationsPreferences;
  readonly #emitEvent: (payload: MessageNotificationEmission) => void;
  readonly #onDeliveryRefused: () => void;
  readonly #sendReply: (target: ChatTarget, text: string) => Promise<void>;
  readonly #log: { warn: (message: string) => void };
  // Router messages delivered since the user was last in Comma.
  #unseenCount = 0;
  // The OS keeps the icon's badge across launches, so one a previous run left
  // is cleared on the first return to Comma even with nothing counted here.
  #badgeMayBeStale = true;
  // Counts returns to Comma, so a delivery that settles after one is not
  // added to a badge the user has already cleared.
  #focusGeneration = 0;

  constructor({
    emitEvent,
    log,
    onDeliveryRefused,
    platform,
    preferences,
    sendReply,
  }: {
    emitEvent: (payload: MessageNotificationEmission) => void;
    log: { warn: (message: string) => void };
    /**
     * The OS took none of the banners just raised. The authorization the
     * Settings switch reads back is stale at that point, so the owner
     * re-reads it.
     */
    onDeliveryRefused: () => void;
    platform: MessageNotificationsPlatform;
    preferences: () => MessageNotificationsPreferences;
    sendReply: (target: ChatTarget, text: string) => Promise<void>;
  }) {
    this.#emitEvent = emitEvent;
    this.#log = log;
    this.#onDeliveryRefused = onDeliveryRefused;
    this.#platform = platform;
    this.#preferences = preferences;
    this.#sendReply = sendReply;
    // A banner exists to bring the user back. Once they are here, whatever
    // is still listed in Notification Center is stale and would only be
    // read a second time, and the badge counts messages already in view.
    platform.onAppFocused(() => {
      this.#focusGeneration += 1;
      platform.dismissAll();
      if (this.#unseenCount === 0 && !this.#badgeMayBeStale) return;
      this.#unseenCount = 0;
      this.#badgeMayBeStale = false;
      platform.setBadgeCount(0);
    });
  }

  /** Shows the banners the core worded for the messages a conversation gained. */
  async show({
    notices,
    target,
  }: Pick<ChatAppendedValue, "notices" | "target">): Promise<void> {
    if (!this.#platform.isSupported()) return;
    const preferences = this.#preferences();
    // System notifications is the master switch; Router messages is one
    // kind of notification under it.
    if (!preferences.systemNotifications) return;
    if (!preferences.notifyRouterMessages) return;
    if (this.#platform.isAppFocused()) return;

    if (notices.length === 0) return;

    const eventTarget = {
      conversationId: target.conversationId,
      groupId: target.groupId,
      workspaceId: target.workspaceId,
    };

    const focusGeneration = this.#focusGeneration;
    let deliveredCount = 0;
    for (const notice of notices) {
      // A focus event also cancels banners not yet submitted to the OS.
      if (focusGeneration !== this.#focusGeneration) return;
      const delivered = await this.#platform.show({
        body: notice.body,
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
        replyPlaceholder: notice.replyPlaceholder,
        title: notice.title,
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
