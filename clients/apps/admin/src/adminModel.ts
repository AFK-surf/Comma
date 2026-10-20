// What every Admin view model shares: how a failed read or command is shown, and the audited-command review.
//
// A view model is an object made by an Effect in its view's Scope: its state in a SubscriptionRef, which the view
// shows, and commands (Effects) the view runs. Closing the Scope (the operator left the view, or the session changed)
// interrupts what the model still has under way, which aborts its requests.
import { Context, Effect, SubscriptionRef } from "effect";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminRedeemTarget,
} from "./adminApi";
import type { AdminSection } from "./adminNavigation";
import { messages } from "@comma/i18n";

/** The Admin shell, as views reach it. */
export class AdminShellLinks extends Context.Service<
  AdminShellLinks,
  {
    /** The server refused the operator Admin access: the whole dashboard is replaced. */
    readonly denyAccess: Effect.Effect<void>;
    readonly select: (section: AdminSection) => Effect.Effect<void>;
    /** Opens Redeem codes with a code application prepared for `target`. */
    readonly applyRedeemCode: (target: AdminRedeemTarget) => Effect.Effect<void>;
    /** Opens the account's page in Users. */
    readonly openUser: (userId: string) => Effect.Effect<void>;
  }
>()("admin/AdminShellLinks") {}

export const sessionChangedMessage = (): string => messages.admin_session_changed();
export const commandFallbackMessage = (): string => messages.admin_command_failed();

function messageOf(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

export interface Failures {
  /**
   * What a failed read shows: nothing when it failed for the session (the auth service takes over), the
   * access-denied screen when the operator may not use Admin, otherwise the error's message (or `fallback`).
   */
  readonly read: (
    error: unknown,
    fallback: string
  ) => Effect.Effect<string | undefined>;
  /** What a failed command shows: a session refusal asks to sign in again; an operator refusal denies access. */
  readonly command: (error: unknown, fallback?: string) => Effect.Effect<string>;
}

/** How the view models made in this Scope show failures. */
export const makeFailures = Effect.gen(function* () {
  const links = yield* AdminShellLinks;
  const failures: Failures = {
    read: (error, fallback) =>
      Effect.gen(function* () {
        if (isAdminSessionRejection(error)) return undefined;
        if (isAdminAccessDenied(error)) {
          yield* links.denyAccess;
          return undefined;
        }
        return messageOf(error, fallback);
      }),
    command: (error, fallback = commandFallbackMessage()) =>
      Effect.gen(function* () {
        if (isAdminAccessDenied(error)) yield* links.denyAccess;
        if (isAdminSessionRejection(error)) return sessionChangedMessage();
        return messageOf(error, fallback);
      }),
  };
  return failures;
});

/** One field an audited command changes, shown in its review. */
export interface ConfirmationChange {
  readonly label: string;
  readonly before: string;
  readonly after: string;
}

export interface ConfirmationState {
  readonly busy: boolean;
  readonly changes: ReadonlyArray<ConfirmationChange>;
  readonly destructive: boolean;
  readonly error: string | undefined;
  readonly explanation: string | undefined;
  /** The command's idempotency key: the same for every try from one opening. */
  readonly key: string;
  readonly open: boolean;
  /** Why the operator runs the command; stored in its audit event. */
  readonly reason: string;
  readonly title: string;
  /** What the operator types to confirm a guarded command; undefined for a routine one. */
  readonly typed: string | undefined;
  readonly value: string;
}

export interface ConfirmationRequest {
  /** The fields the command changes, before and after. */
  readonly changes?: ReadonlyArray<ConfirmationChange>;
  readonly destructive?: boolean;
  /** Consequences the operator must read before confirming. */
  readonly explanation?: string;
  /** The idempotency key to use; a new `prefix:uuid` key when absent. */
  readonly key?: string;
  readonly keyPrefix: string;
  /**
   * Runs the command with the operator's reason; a failure is the message to show, and the dialog stays open for
   * another try.
   */
  readonly run: (key: string, reason: string) => Effect.Effect<void, string>;
  readonly title: string;
  /**
   * A guarded command (a global policy, a grant of access, an irreversible change) asks the operator to type this
   * name of its target. A routine command asks only for the reason.
   */
  readonly typed?: string;
}

export interface Confirmation {
  readonly state: SubscriptionRef.SubscriptionRef<ConfirmationState | undefined>;
  readonly open: (request: ConfirmationRequest) => Effect.Effect<void>;
  readonly setReason: (reason: string) => Effect.Effect<void>;
  readonly setValue: (value: string) => Effect.Effect<void>;
  /** Closes the dialog, unless the command is under way. */
  readonly cancel: Effect.Effect<void>;
  readonly confirm: Effect.Effect<void>;
}

export const minimumReasonLength = 3;
export const reasonMissingMessage = (): string => messages.admin_reason_missing();
export const confirmationMismatchMessage = (): string =>
  messages.admin_confirmation_mismatch();

const noCommand = () => Effect.void;

/**
 * The audited-command review: the operator gives a reason (and types the target's name for a guarded command), then
 * the command runs once at a time.
 */
export const makeConfirmation = Effect.gen(function* () {
  const state = yield* SubscriptionRef.make<ConfirmationState | undefined>(undefined);
  let run: ConfirmationRequest["run"] = noCommand;

  const update = (change: (current: ConfirmationState) => ConfirmationState) =>
    SubscriptionRef.update(state, (current) => (current ? change(current) : current));

  const confirmation: Confirmation = {
    state,
    open: (request) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (current?.busy) return;
        run = request.run;
        const key =
          request.key ??
          (yield* Effect.sync(() => createIdempotencyKey(request.keyPrefix)));
        yield* SubscriptionRef.set(state, {
          busy: false,
          changes: request.changes ?? [],
          destructive: request.destructive ?? false,
          error: undefined,
          explanation: request.explanation,
          key,
          open: true,
          // Another try of the same command keeps the reason the operator wrote.
          reason: current && current.key === key ? current.reason : "",
          title: request.title,
          typed: request.typed,
          value: "",
        });
      }),
    setReason: (reason) =>
      update((current) => ({ ...current, reason, error: undefined })),
    setValue: (value) => update((current) => ({ ...current, value, error: undefined })),
    cancel: update((current) => (current.busy ? current : { ...current, open: false })),
    confirm: Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (!current?.open || current.busy) return;
      const reason = current.reason.trim();
      if (reason.length < minimumReasonLength) {
        yield* update((value) => ({ ...value, error: reasonMissingMessage() }));
        return;
      }
      if (current.typed !== undefined && current.value.trim() !== current.typed) {
        yield* update((value) => ({ ...value, error: confirmationMismatchMessage() }));
        return;
      }
      yield* update((value) => ({ ...value, busy: true, error: undefined }));
      yield* run(current.key, reason).pipe(
        Effect.matchEffect({
          onFailure: (message) =>
            update((value) => ({ ...value, busy: false, error: message })),
          onSuccess: () => update((value) => ({ ...value, busy: false, open: false })),
        }),
        Effect.onInterrupt(() => update((value) => ({ ...value, busy: false })))
      );
    }),
  };
  return confirmation;
});

/** Whether `confirmation` has a command under way (views lock what it guards). */
export const confirmationBusy = (state: ConfirmationState | undefined) =>
  state?.busy ?? false;
