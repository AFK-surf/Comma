import { Button, CheckIcon, LoaderIcon } from "@comma/ui";
import { useLayoutEffect, useRef } from "react";
import { OnboardingSwap } from "./OnboardingCard";

/**
 * - `checking`: the answer is not known yet; the cell stays empty.
 * - `idle`: the action is offered.
 * - `pending`: the action runs (a sign-in in the browser, macOS asking); its
 *   button shows a small spinner (its label read out) and ignores presses.
 * - `done`: settled, with a check.
 * - `settings`: only System Settings can change it now.
 */
export type OnboardingRowActionState =
  | "checking"
  | "idle"
  | "pending"
  | "done"
  | "settings";

/**
 * A row's trailing action (Connect, Allow) in the plugin list's own action
 * style, at full contrast in every state. Every state it can show shares one
 * cell whose width an invisible copy of each holds, so the row's text never
 * reflows as they trade places. The button's hit area reaches 40px tall.
 *
 * A row that settles while its button has the focus (the user comes back from
 * the browser or macOS) hands the focus to the card's primary, which now says
 * Continue, and says that the row is done.
 */
export function OnboardingRowAction({
  actionAriaLabel,
  actionLabel,
  doneLabel,
  onAction,
  onSettings,
  pendingLabel,
  settingsLabel,
  state,
}: {
  state: OnboardingRowActionState;
  actionLabel: string;
  actionAriaLabel: string;
  /** What the pending button says ("Connecting…", "Waiting…"). */
  pendingLabel: string;
  doneLabel: string;
  onAction: () => void;
  /** Where System Settings can take over (notifications refused). */
  settingsLabel?: string | undefined;
  onSettings?: (() => void) | undefined;
}) {
  const offered = state === "idle" || state === "pending";
  const offeredRef = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const layer = offeredRef.current;
    if (offered || !layer?.contains(document.activeElement)) return;
    layer
      .closest(".comma-onboarding-card")
      ?.querySelector<HTMLElement>(".comma-onboarding-primary")
      ?.focus({ preventScroll: true });
  }, [offered]);
  const label = (
    <OnboardingSwap
      states={[
        { key: "idle", label: actionLabel },
        {
          key: "pending",
          label: (
            // Only the spinner shows, so the button stays as narrow as its
            // action; what it waits for is read out.
            <span className="comma-onboarding-action__pending">
              <LoaderIcon className="comma-onboarding-action__spinner animate-spin" />
              <span className="app-sr-only">{pendingLabel}</span>
            </span>
          ),
        },
      ]}
      value={state === "pending" ? "pending" : "idle"}
    />
  );

  return (
    <span className="comma-onboarding-action" data-state={state}>
      <span aria-hidden="true" className="comma-onboarding-action__sizer">
        <span className="comma-onboarding-action__done">
          <CheckIcon />
          {doneLabel}
        </span>
        <span className="comma-onboarding-action__button">{label}</span>
        {settingsLabel ? (
          <span className="comma-onboarding-action__button">{settingsLabel}</span>
        ) : null}
      </span>
      <span
        aria-hidden={!offered || undefined}
        className="comma-onboarding-action__layer"
        data-on={offered}
        inert={!offered || undefined}
        ref={offeredRef}
      >
        <Button
          aria-label={actionAriaLabel}
          className="comma-onboarding-action__button"
          data-pending={state === "pending" || undefined}
          hierarchy="secondary-gray"
          isPending={state === "pending"}
          onPress={onAction}
          size="sm"
        >
          {label}
        </Button>
      </span>
      <span
        aria-hidden="true"
        className="comma-onboarding-action__layer"
        data-on={state === "done"}
      >
        <span className="comma-onboarding-action__done">
          <CheckIcon />
          {doneLabel}
        </span>
      </span>
      {/* What assistive tech reads for the settled row: the label arrives in
          a live region, so the row settling is read out. */}
      <output className="app-sr-only">{state === "done" ? doneLabel : null}</output>
      {settingsLabel && onSettings ? (
        <span
          aria-hidden={state !== "settings" || undefined}
          className="comma-onboarding-action__layer"
          data-on={state === "settings"}
          inert={state !== "settings" || undefined}
        >
          <Button
            className="comma-onboarding-action__button"
            hierarchy="secondary-gray"
            onPress={onSettings}
            size="sm"
          >
            {settingsLabel}
          </Button>
        </span>
      ) : null}
    </span>
  );
}
