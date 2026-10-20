// Main's part of message notifications: showing the banners the core worded while the person is away and Comma's
// switches allow, their sound and badge, and a banner's click and reply. Which messages get a banner and its words
// are the core's (packages/core/test/chat/notices.test.ts).
import type { ChatTarget } from "@comma/chat-contract";
import type { ChatAppendedValue } from "@comma/core/contract";
import { describe, expect, it, vi } from "vitest";

import {
  MessageNotificationsService,
  type MessageNotificationEmission,
  type MessageNotificationShowInput,
} from "../modules/message-notifications";

const noop = () => undefined;

const target: ChatTarget = {
  conversationId: "conv_1",
  groupId: "grp_1",
  workspaceId: "ws_1",
};

/** The core's notice for message `messageId`, as the core words one in Home chat. */
function notice(
  overrides: Partial<ChatAppendedValue["notices"][number]> = {}
): ChatAppendedValue["notices"][number] {
  return {
    messageId: "msg_1",
    title: "Comma",
    body: "Router replied.",
    replyPlaceholder: "Reply",
    ...overrides,
  };
}

/** What the core says one conversation gained: a notice per message. */
const arrival = (...ids: string[]) => ({
  target,
  notices: (ids.length ? ids : ["msg_1"]).map((messageId) => notice({ messageId })),
});

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

describe("MessageNotificationsService", () => {
  it("shows each notice as the core worded it, with the sound on the first", async () => {
    const { emitted, service, setBadgeCount, shown } = createHarness();

    await service.show({
      target,
      notices: [
        notice({ messageId: "msg_1", title: "Plan the offsite", body: "First." }),
        notice({
          messageId: "msg_2",
          title: "Plan the offsite",
          replyPlaceholder: "回复",
        }),
      ],
    });

    expect(shown).toMatchObject([
      {
        title: "Plan the offsite",
        body: "First.",
        replyPlaceholder: "Reply",
        playSound: true,
      },
      {
        title: "Plan the offsite",
        body: "Router replied.",
        replyPlaceholder: "回复",
        playSound: false,
      },
    ]);
    expect(setBadgeCount).toHaveBeenLastCalledWith(2);
    expect(emitted).toEqual([]);
  });

  it.each([
    ["the window holds focus", { isAppFocused: true }],
    ["Router notifications are disabled", { notifyRouterMessages: false }],
    ["the platform cannot notify", { isSupported: false }],
    // The master switch beats the Router-specific choice.
    ["system notifications are switched off", { systemNotifications: false }],
  ])("raises nothing while %s", async (_label, options) => {
    const { emitted, onDeliveryRefused, service, setBadgeCount, shown } =
      createHarness(options);

    await service.show(arrival());

    expect(shown).toEqual([]);
    expect(emitted).toEqual([]);
    expect(setBadgeCount).not.toHaveBeenCalled();
    // Comma's own gates are not an OS refusal: nothing to re-read.
    expect(onDeliveryRefused).not.toHaveBeenCalled();
  });

  it("re-reads the OS switch when the banner is refused", async () => {
    const { onDeliveryRefused, service, shown } = createHarness({
      deliver: false,
    });

    await service.show(arrival());

    expect(shown).toHaveLength(1);
    expect(onDeliveryRefused).toHaveBeenCalledOnce();
  });

  it("passes the sound to the next banner when the first is refused", async () => {
    const { onDeliveryRefused, service, shown } = createHarness({
      deliver: [false, true, true],
    });

    await service.show(arrival("msg_1", "msg_2", "msg_3"));

    expect(shown.map((input) => input.playSound)).toEqual([true, true, false]);
    expect(onDeliveryRefused).not.toHaveBeenCalled();
  });

  it("dismisses every delivered banner once the user is back in Comma", async () => {
    const { dismissAll, focusApp, service } = createHarness();
    await service.show(arrival());
    expect(dismissAll).not.toHaveBeenCalled();

    focusApp();

    expect(dismissAll).toHaveBeenCalledOnce();
  });

  it("cancels the rest of an arrival when Comma gains focus during delivery", async () => {
    const delivery = Promise.withResolvers<boolean>();
    const { focusApp, service, setBadgeCount, shown } = createHarness({
      deliver: delivery.promise,
    });

    const pending = service.show(arrival("msg_1", "msg_2"));
    expect(shown).toHaveLength(1);
    focusApp();
    delivery.resolve(true);
    await pending;

    expect(shown).toHaveLength(1);
    expect(setBadgeCount).not.toHaveBeenCalled();
  });

  it("badges the app icon with Router messages delivered while away", async () => {
    const { focusApp, service, setBadgeCount } = createHarness({
      deliver: [true, false, true],
    });

    await service.show(arrival("msg_1", "msg_2"));
    await service.show(arrival("msg_3"));

    // A refused banner never reached the user, so it is not counted.
    expect(setBadgeCount.mock.calls).toEqual([[1], [2]]);

    focusApp();
    expect(setBadgeCount).toHaveBeenLastCalledWith(0);
  });

  it("leaves the badge alone when nothing reached the user", async () => {
    const { focusApp, service, setBadgeCount } = createHarness({ deliver: false });

    await service.show(arrival());
    focusApp();

    expect(setBadgeCount).not.toHaveBeenCalled();
  });

  it("leaves the banner silent when Comma's sound preference is off", async () => {
    const { service, shown } = createHarness({ notificationSound: false });

    await service.show(arrival());

    expect(shown[0]).toMatchObject({ playSound: false });
  });

  it("emits a click event carrying the conversation target", async () => {
    const { emitted, service, shown } = createHarness();
    await service.show(arrival());

    shown[0]?.onClick();

    expect(emitted).toContainEqual({ target, type: "clicked" });
  });

  it("routes an inline reply into the conversation", async () => {
    const { sendReply, service, shown } = createHarness();
    await service.show(arrival());

    shown[0]?.onReply("On it");

    expect(sendReply).toHaveBeenCalledWith(target, "On it");
  });

  it("logs a reply that fails to send", async () => {
    const { service, shown, warn } = createHarness({
      replyError: new Error("offline"),
    });
    await service.show(arrival());

    const warned = Promise.withResolvers<void>();
    warn.mockImplementation(() => warned.resolve());
    shown[0]?.onReply("On it");
    await warned.promise;
    expect(warn).toHaveBeenCalledOnce();
  });
});
