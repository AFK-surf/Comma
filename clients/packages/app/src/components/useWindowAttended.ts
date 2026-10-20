import { useSyncExternalStore } from "react";

function subscribeWindowAttention(listener: () => void) {
  window.addEventListener("focus", listener);
  window.addEventListener("blur", listener);
  document.addEventListener("visibilitychange", listener);
  return () => {
    window.removeEventListener("focus", listener);
    window.removeEventListener("blur", listener);
    document.removeEventListener("visibilitychange", listener);
  };
}

const windowAttended = () =>
  document.visibilityState === "visible" && document.hasFocus();

/** Whether the app's window is in front: visible and focused. */
export function useWindowAttended() {
  return useSyncExternalStore(subscribeWindowAttention, windowAttended, () => false);
}
