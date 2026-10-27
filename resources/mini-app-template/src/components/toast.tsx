import { Check } from "lucide-react";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

/**
 * One toast at a time (DESIGN.md §9): a line that confirms a success or notes
 * something needing no reply, gone after 1.8 s. An error that needs action is
 * an `ErrorState` in place, never a toast.
 */

type Toast = { id: number; message: string; tone: "info" | "success" };
type Show = (message: string, options?: { tone?: Toast["tone"] }) => void;

const ToastContext = createContext<Show>(() => {});

export const TOAST_MS = 1800;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<Toast | null>(null);
  const timer = useRef<number | undefined>(undefined);
  const show = useCallback<Show>((message, options) => {
    window.clearTimeout(timer.current);
    const id = Date.now();
    setToast({ id, message, tone: options?.tone ?? "info" });
    timer.current = window.setTimeout(
      () => setToast((current) => (current?.id === id ? null : current)),
      TOAST_MS,
    );
  }, []);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  return (
    <ToastContext.Provider value={show}>
      {children}
      <div
        aria-live="polite"
        data-slot="toast-region"
        className="pointer-events-none fixed inset-x-0 bottom-0 z-50 flex justify-center px-4 pb-4"
        role="status"
        style={{ paddingBottom: "max(1rem, env(safe-area-inset-bottom))" }}
      >
        {toast ? (
          <div
            key={toast.id}
            className="flex max-w-full items-center gap-2 rounded-lg bg-foreground px-3 py-2 text-subheadline text-background shadow-md motion-safe:animate-in motion-safe:fade-in motion-safe:slide-in-from-bottom-2"
          >
            {toast.tone === "success" ? (
              <Check aria-hidden className="size-4" />
            ) : null}
            <span className="truncate">{toast.message}</span>
          </div>
        ) : null}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): Show {
  return useContext(ToastContext);
}
