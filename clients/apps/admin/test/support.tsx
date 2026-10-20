// Admin test harness: a view model made against fake services, rendered in the Admin runtime. Fake API methods return
// Effects (`ok`, `refuse`, or a `pending` reply the test settles when it chooses). Time is a TestClock the test moves
// (`advance`); `settle` lets what is ready run, without waiting on real time.
import { act, render as renderDom, screen, within } from "@comma/test-utils/render";
import type userEvent from "@testing-library/user-event";
import {
  Deferred,
  Duration,
  Effect,
  Exit,
  Layer,
  ManagedRuntime,
  Scope,
  Stream,
  type Context,
} from "effect";
import { TestClock } from "effect/testing";
import type { ReactNode } from "react";
import { onTestFinished, vi } from "vitest";
import {
  AdminApi,
  AdminApiError,
  type AdminApiShape,
  type AdminRequestError,
} from "../src/adminApi";
import { AdminBrowser } from "../src/adminBrowser";
import { AdminShellLinks } from "../src/adminModel";
import { AdminRuntimeProvider } from "../src/adminRuntime";

export const ok = <A,>(value: A): Effect.Effect<A, AdminRequestError> =>
  Effect.succeed(value);

/** The server refused: `status` and `code` as `AdminApiError` carries them. */
export const refuse = (status: number, code: string, message = code) =>
  Effect.fail(new AdminApiError({ code, message, status }));

/** A reply the test gives later: `effect` waits until `succeed` or `fail`. */
export function pending<A>() {
  const deferred = Deferred.makeUnsafe<A, AdminRequestError>();
  return {
    effect: Deferred.await(deferred),
    fail: (error: AdminRequestError) => {
      Effect.runSync(Deferred.fail(deferred, error));
    },
    succeed: (value: A) => {
      Effect.runSync(Deferred.succeed(deferred, value));
    },
  };
}

/** An `AdminApi` with only the given methods; any other call fails the test. */
export function fakeApi(methods: Partial<AdminApiShape>): AdminApiShape {
  return new Proxy(methods as AdminApiShape, {
    get(target, name: string) {
      const method = target[name as keyof AdminApiShape];
      if (method) return method;
      return () => Effect.die(new Error(`Unexpected Admin API call: ${name}`));
    },
  });
}

export interface FakeBrowser {
  readonly copied: string[];
  readonly service: Context.Service.Shape<typeof AdminBrowser>;
}

/** The page as jsdom has it, with a clipboard that records what was copied. */
export function fakeBrowser(): FakeBrowser {
  const copied: string[] = [];
  return {
    copied,
    service: AdminBrowser.of({
      href: Effect.sync(() => window.location.href),
      push: (href) => Effect.sync(() => window.history.pushState(null, "", href)),
      replaceParams: (params) =>
        Effect.sync(() => {
          const url = new URL(window.location.href);
          for (const [name, value] of Object.entries(params)) {
            if (value) url.searchParams.set(name, value);
            else url.searchParams.delete(name);
          }
          window.history.replaceState(window.history.state, "", url);
        }),
      popstate: Stream.never,
      online: Stream.never,
      narrow: Effect.succeed(false),
      copy: (text) => Effect.sync(() => void copied.push(text)),
      setLocale: () => Effect.void,
    }),
  };
}

/**
 * Awaits `promise` while the test clock (test-clock.ts) moves from timer to
 * timer: the runtime's scheduler, and the live sleeps TestClock takes while
 * fibers settle, wait on it, so a run would not finish otherwise.
 */
export async function onTestClock<A>(promise: Promise<A>): Promise<A> {
  const settled = promise.then(
    () => true,
    () => true
  );
  while (!(await Promise.race([settled, Promise.resolve(false)])))
    await vi.advanceTimersToNextTimerAsync();
  return promise;
}

/** Lets what is ready run: promise continuations and the runtime's scheduled fibers. */
export async function settle(rounds = 25) {
  await act(async () => {
    // Each round runs what is due now on the test clock (test-clock.ts): the
    // runtime's scheduled fibers and React's work, then their promises.
    for (let round = 0; round < rounds; round += 1) {
      await vi.advanceTimersByTimeAsync(0);
    }
  });
}

/**
 * A view model made by `make` against `api`, with the shell's links as spies. `render` shows a view in the model's
 * runtime; `advance` moves the TestClock.
 */
export function mountModel<M>(
  make: Effect.Effect<
    M,
    never,
    AdminApi | AdminBrowser | AdminShellLinks | Scope.Scope
  >,
  options: { api?: Partial<AdminApiShape>; browser?: FakeBrowser } = {}
) {
  const links = {
    applyRedeemCode: vi.fn(),
    openUser: vi.fn(),
    denyAccess: vi.fn(),
    select: vi.fn(),
  };
  const browser = options.browser ?? fakeBrowser();
  const layer = Layer.mergeAll(
    Layer.succeed(AdminApi, fakeApi(options.api ?? {})),
    Layer.succeed(AdminBrowser, browser.service),
    Layer.succeed(
      AdminShellLinks,
      AdminShellLinks.of({
        applyRedeemCode: (target) => Effect.sync(() => links.applyRedeemCode(target)),
        openUser: (userId) => Effect.sync(() => links.openUser(userId)),
        denyAccess: Effect.sync(() => links.denyAccess()),
        select: (section) => Effect.sync(() => links.select(section)),
      })
    ),
    TestClock.layer()
  );
  const runtime = ManagedRuntime.make(layer);
  onTestFinished(() => runtime.dispose());
  const scope = runtime.runSync(Scope.make());
  const model = runtime.runSync(Scope.provide(make, scope));
  return {
    browser,
    links,
    model,
    runtime,
    advance: async (duration: Duration.Input) => {
      await onTestClock(runtime.runPromise(TestClock.adjust(duration)));
      await settle();
    },
    render: (ui: ReactNode) =>
      renderDom(<AdminRuntimeProvider runtime={runtime}>{ui}</AdminRuntimeProvider>),
    close: () => onTestClock(runtime.runPromise(Scope.close(scope, Exit.void))),
  };
}

/** Confirms the open audited-command review: gives the reason and, for a guarded command, types the target's name. */
export async function review(
  user: ReturnType<typeof userEvent.setup>,
  title: string,
  reason: string,
  typed?: string
) {
  const dialog = screen.getByRole("dialog", { name: title });
  await user.click(within(dialog).getByRole("textbox", { name: "Reason" }));
  await user.paste(reason);
  if (typed !== undefined) {
    await user.click(
      within(dialog).getByRole("textbox", { name: `Type “${typed}” to confirm` })
    );
    await user.paste(typed);
  }
  await user.click(within(dialog).getByRole("button", { name: "Confirm" }));
  await settle();
}
