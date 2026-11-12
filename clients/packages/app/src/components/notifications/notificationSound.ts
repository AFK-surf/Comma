import notificationSoundUrl from "./assets/notification.wav";
import requestSoundUrl from "./assets/request.wav";

/** The sound a Router notification plays, shared with the settings preview. */
export function playNotificationSound() {
  void new Audio(notificationSoundUrl).play().catch(() => undefined);
}

/** The sound a new request plays, shared with the settings preview. */
export function playRequestSound() {
  void new Audio(requestSoundUrl).play().catch(() => undefined);
}
