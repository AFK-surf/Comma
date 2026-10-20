// The one binding between React and Admin's Effect services: a provider for the runtime, a hook that shows a
// SubscriptionRef's current value, and a hook that runs commands. Components show state and run commands; they read
// no data and keep no time of their own.
import {
  type Context,
  Effect,
  Fiber,
  type ManagedRuntime,
  Stream,
  SubscriptionRef,
} from "effect";
import {
  createContext,
  useCallback,
  useContext,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import type { AdminApi } from "./adminApi";
import type { AdminBrowser } from "./adminBrowser";
import type { AdminShell } from "./adminShell";
import type { AdminAuth } from "./auth";

/** The services components run commands against. */
export type AdminServices = AdminApi | AdminAuth | AdminBrowser | AdminShell;

export type AdminRuntime = ManagedRuntime.ManagedRuntime<AdminServices, never>;

const RuntimeContext = createContext<ManagedRuntime.ManagedRuntime<
  never,
  never
> | null>(null);

export function AdminRuntimeProvider<R>({
  children,
  runtime,
}: {
  children: ReactNode;
  runtime: ManagedRuntime.ManagedRuntime<R, never>;
}) {
  return (
    <RuntimeContext.Provider
      value={runtime as unknown as ManagedRuntime.ManagedRuntime<never, never>}
    >
      {children}
    </RuntimeContext.Provider>
  );
}

function useRuntime() {
  const runtime = useContext(RuntimeContext);
  if (!runtime)
    throw new Error("Admin components must be inside AdminRuntimeProvider.");
  return runtime as unknown as ManagedRuntime.ManagedRuntime<AdminServices, never>;
}

// Each shown value is read again right after a command starts. A command runs at once until it first waits, so what
// it changed (the text of a field, say) is shown in the same event, as React's own state would be.
const shown = new Set<() => void>();

/**
 * The current value of `ref`, or the part `select` reads from it; the component renders again when that changes.
 * `select` must return the same value for the same state (a field, a flag), not a new object.
 */
export function useAdminState<A>(ref: SubscriptionRef.SubscriptionRef<A>): A;
export function useAdminState<A, B>(
  ref: SubscriptionRef.SubscriptionRef<A>,
  select: (value: A) => B
): B;
export function useAdminState<A, B>(
  ref: SubscriptionRef.SubscriptionRef<A>,
  select?: (value: A) => B
): A | B {
  const subscribe = useCallback(
    (onChange: () => void) => {
      shown.add(onChange);
      const fiber = Effect.runFork(
        SubscriptionRef.changes(ref).pipe(
          Stream.runForEach(() => Effect.sync(onChange))
        )
      );
      return () => {
        shown.delete(onChange);
        Effect.runFork(Fiber.interrupt(fiber));
      };
    },
    [ref]
  );
  return useSyncExternalStore(subscribe, () => {
    const value = SubscriptionRef.getUnsafe(ref);
    return select ? select(value) : value;
  });
}

/** Runs a command in the Admin runtime. The returned function stops it. */
export function useAdminCommand() {
  const runtime = useRuntime();
  return useCallback(
    <A, E>(command: Effect.Effect<A, E, AdminServices>) => {
      const fiber = runtime.runFork(command);
      for (const onChange of shown) onChange();
      return () => {
        runtime.runFork(Fiber.interrupt(fiber));
      };
    },
    [runtime]
  );
}

/** The Admin service `tag`, from the runtime. */
export function useAdminService<I extends AdminServices, S>(tag: Context.Key<I, S>): S {
  const runtime = useRuntime();
  return runtime.runSync(tag);
}
