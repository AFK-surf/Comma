import { app, BrowserWindow, Notification } from "electron";

import type {
  MessageNotificationShowInput,
  MessageNotificationsPlatform,
} from "./modules/message-notifications";

// Native banners can outlive their JavaScript call site. Electron requires the
// wrapper to remain reachable for its events to keep firing, while this bound
// prevents unacknowledged banners from retaining memory indefinitely.
export const MAX_RETAINED_MESSAGE_NOTIFICATIONS = 64;

// Packaged into the bundle's Resources (forge.config.ts), where macOS looks the
// banner sound up by name. The OS plays it, so the "Play sound for
// notification" switch in System Settings applies.
export const MESSAGE_NOTIFICATION_SOUND = "notification.wav";

export function createElectronMessageNotificationsPlatform({
  activateApp,
  authorize,
  log,
  openMainWindow,
  setBadgeCount,
}: {
  activateApp: () => void;
  /** Resolves once the OS has decided whether it will take Comma's banners. */
  authorize: () => Promise<boolean>;
  log: { warn: (message: string) => void };
  openMainWindow: () => Promise<void>;
  /** Shows the count on the app icon under the OS badge switch; zero clears it. */
  setBadgeCount: (count: number) => void;
}): MessageNotificationsPlatform {
  const liveNotifications = new Set<Notification>();
  // The OS answers a decided request from its record without prompting, so
  // only the in-flight request and a grant are worth keeping. A refusal is
  // asked again on the next banner, which is how a switch flipped later in
  // System Settings takes effect without a restart.
  let authorization: Promise<boolean> | undefined;
  const ensureAuthorized = () => {
    authorization ??= authorize().then((granted) => {
      if (!granted) authorization = undefined;
      return granted;
    });
    return authorization;
  };

  // A dismissal covers every banner in flight when it happened, including one
  // still waiting for authorization: it is a generation, not a sweep of what
  // has been delivered so far.
  let dismissals = 0;

  return {
    dismissAll: () => {
      dismissals += 1;
      // Each close releases its wrapper through the close event; deleting the
      // current entry is well-defined for a Set iterator.
      for (const notification of liveNotifications) notification.close();
    },
    isAppFocused: () => BrowserWindow.getFocusedWindow() !== null,
    isSupported: () => Notification.isSupported(),
    onAppFocused: (listener) => {
      app.on("browser-window-focus", listener);
      return () => {
        app.off("browser-window-focus", listener);
      };
    },
    setBadgeCount,
    show: async (input: MessageNotificationShowInput) => {
      const dismissalsBefore = dismissals;
      if (!(await ensureAuthorized())) return false;
      // The user came back while the OS was still deciding: this banner is
      // as stale as the ones the dismissal closed.
      if (dismissals !== dismissalsBefore) return false;

      const notification = new Notification({
        body: input.body,
        hasReply: true,
        replyPlaceholder: input.replyPlaceholder,
        silent: !input.playSound,
        sound: MESSAGE_NOTIFICATION_SOUND,
        title: input.title,
      });
      const release = () => {
        liveNotifications.delete(notification);
      };
      return new Promise<boolean>((resolve) => {
        // Electron settles every banner with exactly one of these once the
        // OS answers; a close before any show is a dismissal below.
        notification.once("show", () => resolve(true));
        notification.once("close", () => {
          release();
          resolve(false);
        });
        notification.once("failed", (_event, error) => {
          log.warn(`Notification refused by the OS: ${error}`);
          release();
          resolve(false);
        });
        notification.on("click", () => {
          release();
          activateApp();
          // The click event only reaches the renderer once a window exists to
          // receive it; a recreated window already boots on Home.
          void openMainWindow().then(input.onClick);
        });
        notification.on("reply", (_event, reply) => {
          // Answered from the banner: the OS would keep it listed otherwise.
          notification.close();
          input.onReply(reply);
        });
        liveNotifications.add(notification);
        try {
          notification.show();
        } catch (error) {
          log.warn(
            `Notification could not be shown: ${
              error instanceof Error ? error.message : String(error)
            }`
          );
          release();
          resolve(false);
          return;
        }
        if (liveNotifications.size > MAX_RETAINED_MESSAGE_NOTIFICATIONS) {
          const oldest = liveNotifications.values().next().value;
          if (oldest) {
            liveNotifications.delete(oldest);
            oldest.close();
          }
        }
      });
    },
  };
}
