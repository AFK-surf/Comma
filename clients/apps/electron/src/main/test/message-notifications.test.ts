import type { ChatTarget } from "@comma/chat-contract";
import type { CommaConversation } from "@comma/app/api";
import type { ChatMessage } from "@comma/app/chat-runtime";
import { describe, expect, it, vi } from "vitest";

import {
  MessageNotificationsService,
  boundNotificationBody,
  type MessageNotificationEmission,
  type MessageNotificationShowInput,
} from "../modules/message-notifications";

const noop = () => undefined;

const target: ChatTarget = {
  conversationId: "conv_1",
  groupId: "grp_1",
  workspaceId: "ws_1",
};

function conversation(overrides: Partial<CommaConversation> = {}): CommaConversation {
  return {
    group_id: target.groupId,
    id: target.conversationId,
    kind: "user_chat",
    status: "idle",
    title: "Home",
    ...overrides,
  } as CommaConversation;
}

function message(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "delivered" as ChatMessage["delivery"],
    error: undefined,
    messageId: "msg_1",
    refs: [],
    role: "assistant",
    source: "server",
    status: undefined,
    text: "Router replied.",
    ...overrides,
  };
}

function createHarness({
  deliver = true,
  isAppFocused = false,
  isSupported = true,
  notificationSound = true,
  notifyRouterMessages = true,
  replyError,
  systemNotifications = true,
}: {
  /** Per-banner OS outcome; a single value answers every banner. */
  deliver?: boolean | boolean[] | Promise<boolean>;
  isAppFocused?: boolean;
  isSupported?: boolean;
  notificationSound?: boolean;
  notifyRouterMessages?: boolean;
  replyError?: Error;
  systemNotifications?: boolean;
} = {}) {
  const shown: MessageNotificationShowInput[] = [];
  const emitted: MessageNotificationEmission[] = [];
  const outcomes = Array.isArray(deliver) ? [...deliver] : undefined;
  const sendReply = vi.fn(async () => {
    if (replyError) throw replyError;
  });
  const onDeliveryRefused = vi.fn();
  const dismissAll = vi.fn();
  const setBadgeCount = vi.fn();
  let focusApp: () => void = noop;
  const warn = vi.fn();
  const service = new MessageNotificationsService({
    emitEvent: (payload) => emitted.push(payload),
    log: { warn },
    onDeliveryRefused,
    platform: {
      dismissAll,
      isAppFocused: () => isAppFocused,
      isSupported: () => isSupported,
      onAppFocused: (listener) => {
        focusApp = listener;
        return noop;
      },
      setBadgeCount,
      show: async (input) => {
        shown.push(input);
        return outcomes
          ? (outcomes.shift() ?? false)
          : (deliver as boolean | Promise<boolean>);
      },
    },
    preferences: () => ({
      notificationSound,
      notifyRouterMessages,
      systemNotifications,
    }),
    productName: "Comma Staging",
    sendReply,
  });
  return {
    dismissAll,
    emitted,
    focusApp: () => focusApp(),
    onDeliveryRefused,
    sendReply,
    service,
    setBadgeCount,
    shown,
    warn,
  };
}

describe("boundNotificationBody", () => {
  it("hands a normal reply to the banner untouched", () => {
    const body = "Shipped it.\n\nTests pass.\n\nReady for review.";
    expect(boundNotificationBody(body)).toBe(body);
  });

  it("leaves line breaks alone so the banner lays the body out", () => {
    const body = "1\n2\n3\n4\n5\n6\n7\n8";
    expect(boundNotificationBody(body)).toBe(body);
  });

  it("adds no ellipsis of its own, leaving the overflow fade to the banner", () => {
    expect(boundNotificationBody("a".repeat(900))).not.toContain("…");
  });

  it("bounds a runaway body to the payload budget", () => {
    expect(boundNotificationBody("a".repeat(900))).toHaveLength(500);
  });
});

describe("MessageNotificationsService", () => {
  it("notifies for an unattributed assistant message in the Home chat as Comma", async () => {
    const { emitted, service, shown } = createHarness();

    await service.handleAppendedMessages({
      // The server names the Home conversation for storage, not for the user.
      conversation: conversation({ title: "Bridge chat" }),
      messages: [message()],
      target,
    });

    expect(shown).toHaveLength(1);
    expect(shown[0]).toMatchObject({
      body: "Router replied.",
      playSound: true,
      title: "Comma",
    });
    expect(emitted).toEqual([]);
  });

  it("notifies for a Router-attributed message in an agent task under the task title", async () => {
    const { service, shown } = createHarness();

    await service.handleAppendedMessages({
      conversation: conversation({ kind: "agent_task", title: "Task" }),
      messages: [message({ actorRole: "router" })],
      target,
    });

    expect(shown).toHaveLength(1);
    expect(shown[0]?.title).toBe("Task");
  });

  it.each([
    ["a worker message", { actorRole: "worker" as const }],
    ["a user message", { role: "user" }],
    ["an empty assistant message", { text: "   " }],
  ])("ignores %s", async (_label, overrides) => {
    const { emitted, service, shown } = createHarness();

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message(overrides)],
      target,
    });

    expect(shown).toEqual([]);
    expect(emitted).toEqual([]);
  });

  it("ignores an unattributed assistant message outside the Home chat", async () => {
    const { service, shown } = createHarness();

    await service.handleAppendedMessages({
      conversation: conversation({ kind: "agent_task" }),
      messages: [message()],
      target,
    });

    expect(shown).toEqual([]);
  });

  it.each([
    ["the window holds focus", { isAppFocused: true }],
    ["Router notifications are disabled", { notifyRouterMessages: false }],
    ["the platform cannot notify", { isSupported: false }],
  ])("raises nothing while %s", async (_label, options) => {
    const { emitted, onDeliveryRefused, service, shown } = createHarness(options);

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    expect(shown).toEqual([]);
    expect(emitted).toEqual([]);
    // Comma's own gates are not an OS refusal: nothing to re-read.
    expect(onDeliveryRefused).not.toHaveBeenCalled();
  });

  it("raises nothing while system notifications are switched off", async () => {
    const { emitted, service, shown } = createHarness({ systemNotifications: false });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    // The master switch beats the Router-specific choice: no banner and no
    // sound event either.
    expect(shown).toHaveLength(0);
    expect(emitted).toEqual([]);
  });

  it("re-reads the OS switch when the banner is refused", async () => {
    const { onDeliveryRefused, service, shown } = createHarness({
      deliver: false,
    });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    expect(shown).toHaveLength(1);
    expect(onDeliveryRefused).toHaveBeenCalledOnce();
  });

  it("passes the sound to the next banner when the first is refused", async () => {
    const { onDeliveryRefused, service, shown } = createHarness({
      deliver: [false, true, true],
    });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [
        message({ messageId: "msg_1" }),
        message({ messageId: "msg_2" }),
        message({ messageId: "msg_3" }),
      ],
      target,
    });

    expect(shown.map((input) => input.playSound)).toEqual([true, true, false]);
    expect(onDeliveryRefused).not.toHaveBeenCalled();
  });

  it("dismisses every delivered banner once the user is back in Comma", async () => {
    const { dismissAll, focusApp, service } = createHarness();
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });
    expect(dismissAll).not.toHaveBeenCalled();

    focusApp();

    expect(dismissAll).toHaveBeenCalledOnce();
  });

  it("cancels the rest of an arrival when Comma gains focus during delivery", async () => {
    const delivery = Promise.withResolvers<boolean>();
    const { focusApp, service, setBadgeCount, shown } = createHarness({
      deliver: delivery.promise,
    });

    const pending = service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message({ messageId: "msg_1" }), message({ messageId: "msg_2" })],
      target,
    });
    expect(shown).toHaveLength(1);
    focusApp();
    delivery.resolve(true);
    await pending;

    expect(shown).toHaveLength(1);
    expect(setBadgeCount).not.toHaveBeenCalled();
  });

  it("sounds only once when all banners arrive", async () => {
    const { service, shown, setBadgeCount } = createHarness();
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message({ messageId: "msg_1" }), message({ messageId: "msg_2" })],
      target,
    });

    expect(shown.map((input) => input.playSound)).toEqual([true, false]);
    expect(setBadgeCount).toHaveBeenLastCalledWith(2);
  });

  it("badges the app icon with Router messages delivered while away", async () => {
    const { focusApp, service, setBadgeCount } = createHarness({
      deliver: [true, false, true],
    });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message({ messageId: "msg_1" }), message({ messageId: "msg_2" })],
      target,
    });
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message({ messageId: "msg_3" })],
      target,
    });

    // A refused banner never reached the user, so it is not counted.
    expect(setBadgeCount.mock.calls).toEqual([[1], [2]]);

    focusApp();
    expect(setBadgeCount).toHaveBeenLastCalledWith(0);
  });

  it("leaves the badge alone when nothing reached the user", async () => {
    const { focusApp, service, setBadgeCount } = createHarness({ deliver: false });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });
    focusApp();

    expect(setBadgeCount).not.toHaveBeenCalled();
  });

  it("leaves the banner silent when Comma's sound preference is off", async () => {
    const { service, shown } = createHarness({ notificationSound: false });

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    expect(shown[0]).toMatchObject({ playSound: false });
  });

  it("falls back to the product name for an untitled task", async () => {
    const { service, shown } = createHarness();

    await service.handleAppendedMessages({
      conversation: conversation({ kind: "agent_task", title: "  " }),
      messages: [message({ actorRole: "router" })],
      target,
    });

    expect(shown[0]?.title).toBe("Comma Staging");
  });

  it("passes a multi-paragraph reply to the banner intact", async () => {
    const { service, shown } = createHarness();
    const text = "First.\n\nSecond.\n\nThird.\n\nFourth.";

    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message({ text })],
      target,
    });

    expect(shown[0]?.body).toBe(text);
  });

  it("emits a click event carrying the conversation target", async () => {
    const { emitted, service, shown } = createHarness();
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    shown[0]?.onClick();

    expect(emitted).toContainEqual({ target, type: "clicked" });
  });

  it("routes an inline reply into the conversation", async () => {
    const { sendReply, service, shown } = createHarness();
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    shown[0]?.onReply("On it");

    expect(sendReply).toHaveBeenCalledWith(target, "On it");
  });

  it("logs a reply that fails to send", async () => {
    const { service, shown, warn } = createHarness({
      replyError: new Error("offline"),
    });
    await service.handleAppendedMessages({
      conversation: conversation(),
      messages: [message()],
      target,
    });

    shown[0]?.onReply("On it");
    await vi.waitFor(() => expect(warn).toHaveBeenCalledOnce());
  });
});
