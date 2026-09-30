import notificationSoundUrl from "./assets/notification.wav";

/** The sound a Router notification plays, shared with the settings preview. */
export function playNotificationSound() {
  void new Audio(notificationSoundUrl).play().catch(() => undefined);
}
