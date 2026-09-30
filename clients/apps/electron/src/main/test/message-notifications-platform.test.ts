import { beforeEach, describe, expect, it, vi } from "vitest";

const electronMock = vi.hoisted(() => {
  type Listener = (...args: unknown[]) => void;

  class Notification {
    static isSupported = vi.fn(() => true);
    static instances: Notification[] = [];
    /** Makes the next constructed wrapper's show() throw, as Electron does without a presenter. */
    static failNextShow: Error | undefined;

    readonly close = vi.fn(() => this.emit("close"));
    readonly listeners = new Map<
      string,
      Array<{ listener: Listener; once: boolean }>
    >();
    readonly options: Record<string, unknown>;
    readonly show = vi.fn(() => {
      const error = Notification.failNextShow;
      if (error) {
        Notification.failNextShow = undefined;
        throw error;
      }
    });

    constructor(options: Record<string, unknown>) {
      this.options = options;
      Notification.instances.push(this);
    }

    on(event: string, listener: Listener) {
      this.listeners.set(event, [
        ...(this.listeners.get(event) ?? []),
        { listener, once: false },
      ]);
      return this;
    }

    once(event: string, listener: Listener) {
      this.listeners.set(event, [
        ...(this.listeners.get(event) ?? []),
        { listener, once: true },
      ]);
      return this;
    }

    emit(event: string, ...args: unknown[]) {
      const listeners = this.listeners.get(event) ?? [];
      this.listeners.set(
        event,
        listeners.filter(({ once }) => !once)
      );
      for (const { listener } of listeners) listener(...args);
    }
  }

  const appListeners = new Map<string, Set<Listener>>();
  const app = {
    emit(event: string) {
      for (const listener of appListeners.get(event) ?? []) listener();
    },
    off: vi.fn((event: string, listener: Listener) => {
      appListeners.get(event)?.delete(listener);
    }),
    on: vi.fn((event: string, listener: Listener) => {
      appListeners.set(event, new Set([...(appListeners.get(event) ?? []), listener]));
    }),
  };

  return {
    BrowserWindow: { getFocusedWindow: vi.fn(() => null) },
    Notification,
    app,
  };
});

vi.mock("electron", () => electronMock);

import {
  MAX_RETAINED_MESSAGE_NOTIFICATIONS,
  MESSAGE_NOTIFICATION_SOUND,
  createElectronMessageNotificationsPlatform,
} from "../message-notifications-platform";

// Lets the authorization hop settle so the wrapper reaches Electron.
const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

const instances = () => electronMock.Notification.instances;

function input(overrides: { title?: string; body?: string } = {}) {
  return {
    body: "body",
    onClick: vi.fn(),
    onReply: vi.fn(),
    playSound: true,
    replyPlaceholder: "Reply",
    title: "title",
    ...overrides,
  };
}

function deferredAuthorization() {
  let grant!: (granted: boolean) => void;
  const authorize = vi.fn(
    () =>
      new Promise<boolean>((resolve) => {
        grant = resolve;
      })
  );
  return { authorize, grant: (granted: boolean) => grant(granted) };
}

function createPlatform({
  authorize = vi.fn(async () => true),
}: { authorize?: () => Promise<boolean> } = {}) {
  const activateApp = vi.fn();
  const openMainWindow = vi.fn(async () => undefined);
  const warn = vi.fn();
  const platform = createElectronMessageNotificationsPlatform({
    activateApp,
    authorize,
    log: { warn },
    openMainWindow,
    setBadgeCount: vi.fn(),
  });
  return { activateApp, openMainWindow, platform, warn };
}

beforeEach(() => {
  instances().length = 0;
});

describe("createElectronMessageNotificationsPlatform", () => {
  it("keeps live notifications through callbacks and bounds retained wrappers", async () => {
    const onClick = vi.fn();
    const onReply = vi.fn();
    const { activateApp, openMainWindow, platform } = createPlatform();

    for (let index = 0; index < MAX_RETAINED_MESSAGE_NOTIFICATIONS; index += 1) {
      void platform.show({
        ...input({ body: `body-${index}`, title: `title-${index}` }),
        onClick,
        onReply,
      });
    }
    await flush();

    const [first, second] = instances();
    expect(instances()).toHaveLength(MAX_RETAINED_MESSAGE_NOTIFICATIONS);
    expect(first?.show).toHaveBeenCalledOnce();
    first?.emit("reply", {}, "sent from the banner");
    expect(onReply).toHaveBeenCalledWith("sent from the banner");

    // Releasing the first wrapper leaves room for one more notification.
    void platform.show({ ...input({ title: "title-extra-1" }), onClick, onReply });
    await flush();
    expect(second?.close).not.toHaveBeenCalled();

    // The next notification crosses the live-wrapper bound and evicts the
    // oldest wrapper that has not received a terminal event.
    void platform.show({ ...input({ title: "title-extra-2" }), onClick, onReply });
    await flush();
    expect(second?.close).toHaveBeenCalledOnce();

    const latest = instances().at(-1);
    latest?.emit("click");
    expect(activateApp).toHaveBeenCalledOnce();
    expect(openMainWindow).toHaveBeenCalledOnce();
    await vi.waitFor(() => expect(onClick).toHaveBeenCalledOnce());
  });

  it.each(["close", "failed"])("releases a wrapper on %s", async (event) => {
    const { platform } = createPlatform();

    for (let index = 0; index < MAX_RETAINED_MESSAGE_NOTIFICATIONS; index += 1) {
      void platform.show(input());
    }
    await flush();
    instances()[0]?.emit(event, {}, "refused");
    void platform.show(input());
    await flush();

    expect(instances()[1]?.close).not.toHaveBeenCalled();
  });

  it("asks the OS before the first banner and shows only once it grants", async () => {
    const { authorize, grant } = deferredAuthorization();
    const { platform } = createPlatform({ authorize });

    const shown = platform.show(input());
    await flush();
    expect(instances()).toHaveLength(0);

    grant(true);
    await flush();
    expect(instances()).toHaveLength(1);
    expect(instances()[0]?.show).toHaveBeenCalledOnce();

    instances()[0]?.emit("show");
    await expect(shown).resolves.toBe(true);
  });

  it("shares one in-flight request across concurrent banners and keeps a grant", async () => {
    const { authorize, grant } = deferredAuthorization();
    const { platform } = createPlatform({ authorize });

    void platform.show(input());
    void platform.show(input());
    expect(authorize).toHaveBeenCalledOnce();

    grant(true);
    await flush();
    expect(instances()).toHaveLength(2);

    void platform.show(input());
    await flush();
    expect(authorize).toHaveBeenCalledOnce();
    expect(instances()).toHaveLength(3);
  });

  it("posts nothing while the OS refuses and asks again for the next banner", async () => {
    const authorize = vi.fn(async () => false);
    const { platform, warn } = createPlatform({ authorize });

    await expect(platform.show(input())).resolves.toBe(false);
    expect(instances()).toHaveLength(0);
    expect(warn).not.toHaveBeenCalled();

    // The switch flipped in System Settings in the meantime.
    authorize.mockResolvedValueOnce(true);
    void platform.show(input());
    await flush();
    expect(authorize).toHaveBeenCalledTimes(2);
    expect(instances()).toHaveLength(1);
  });

  it("reports a banner the OS refused after taking the request", async () => {
    const { platform, warn } = createPlatform();

    const shown = platform.show(input());
    await flush();
    instances()[0]?.emit("failed", {}, "UNErrorDomain error 1");

    await expect(shown).resolves.toBe(false);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("UNErrorDomain error 1"));
  });

  it("removes every delivered banner on dismissAll and releases the wrappers", async () => {
    const { platform } = createPlatform();
    void platform.show(input());
    void platform.show(input());
    await flush();
    instances()[0]?.emit("show");

    platform.dismissAll();

    expect(instances()[0]?.close).toHaveBeenCalledOnce();
    expect(instances()[1]?.close).toHaveBeenCalledOnce();
    // Released wrappers no longer count towards the live bound.
    for (let index = 0; index < MAX_RETAINED_MESSAGE_NOTIFICATIONS; index += 1) {
      void platform.show(input());
    }
    await flush();
    expect(instances()[2]?.close).not.toHaveBeenCalled();
  });

  it("drops a banner still waiting for authorization when the user comes back", async () => {
    const { authorize, grant } = deferredAuthorization();
    const { platform } = createPlatform({ authorize });

    const shown = platform.show(input());
    await flush();
    platform.dismissAll();
    grant(true);
    await flush();

    expect(instances()).toHaveLength(0);
    await expect(shown).resolves.toBe(false);

    // A banner raised after the dismissal is not stale.
    void platform.show(input());
    await flush();
    expect(instances()).toHaveLength(1);
  });

  it("hands the sound to the OS so its sound switch applies", async () => {
    const { platform } = createPlatform();
    void platform.show(input());
    void platform.show({ ...input(), playSound: false });
    await flush();

    expect(instances()[0]?.options).toMatchObject({
      silent: false,
      sound: MESSAGE_NOTIFICATION_SOUND,
    });
    expect(instances()[1]?.options).toMatchObject({ silent: true });
  });

  it("reports window focus through the app and unsubscribes cleanly", () => {
    const { platform } = createPlatform();
    const listener = vi.fn();

    const unsubscribe = platform.onAppFocused(listener);
    electronMock.app.emit("browser-window-focus");
    expect(listener).toHaveBeenCalledOnce();

    unsubscribe();
    electronMock.app.emit("browser-window-focus");
    expect(listener).toHaveBeenCalledOnce();
  });

  it("removes a banner the user answered from", async () => {
    const onReply = vi.fn();
    const { platform } = createPlatform();
    void platform.show({ ...input(), onReply });
    await flush();

    instances()[0]?.emit("reply", {}, "on it");

    expect(onReply).toHaveBeenCalledWith("on it");
    expect(instances()[0]?.close).toHaveBeenCalledOnce();
  });

  it("settles a banner closed before it showed as not delivered", async () => {
    const { platform } = createPlatform();

    const shown = platform.show(input());
    await flush();
    instances()[0]?.close();

    await expect(shown).resolves.toBe(false);
  });

  it("settles a banner Electron could not show as not delivered", async () => {
    const { platform, warn } = createPlatform();
    electronMock.Notification.failNextShow = new Error("no presenter");

    await expect(platform.show(input())).resolves.toBe(false);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("no presenter"));
  });
});
