import { useCommaMessages } from "@comma/i18n/react";
import { Button, LoaderIcon, cx } from "@comma/ui";
import type { ReactNode, Ref } from "react";
import type { OnboardingItemId } from "./onboardingSetup";

/**
 * The card attached under Comma's question: the item's controls and its one
 * primary action. It is named by the question it answers. A leaving card is
 * out of reach at once; its motion is played by onboardingMotion.ts.
 */
export function OnboardingCard({
  cardRef,
  children,
  item,
  label,
  leaving,
}: {
  item: OnboardingItemId;
  /** The question the card answers. */
  label: string;
  leaving: boolean;
  cardRef?: Ref<HTMLFieldSetElement> | undefined;
  children: ReactNode;
}) {
  return (
    <fieldset
      aria-hidden={leaving || undefined}
      aria-label={label}
      className="comma-onboarding-card"
      data-item={item}
      data-leaving={leaving || undefined}
      data-onboarding-part=""
      inert={leaving || undefined}
      ref={cardRef}
      tabIndex={-1}
    >
      {children}
    </fieldset>
  );
}

/**
 * The card's last line: its one primary action at the card's inner corner,
 * a quieter action just before it where the card offers one, and where one
 * is needed, a short note on its left.
 */
export function OnboardingCardFooter({
  note,
  primary,
  secondary,
}: {
  note?: ReactNode;
  secondary?: ReactNode;
  primary: ReactNode;
}) {
  return (
    <div className="comma-onboarding-card__footer">
      {note}
      {secondary}
      {primary}
    </div>
  );
}

/**
 * An item's one primary action, labelled by what it does: "Skip for now"
 * while nothing is done yet, "Continue" once something is. Never disabled.
 * Both labels share one cell, so the button keeps its width as they trade
 * places; while busy, a spinner takes the label's place.
 */
export function OnboardingPrimaryButton({
  busy = false,
  done,
  onPress,
  quietSkip = false,
}: {
  done: boolean;
  busy?: boolean;
  onPress: () => void;
  /** "Skip for now" as plain text rather than a button's outline. */
  quietSkip?: boolean;
}) {
  const messages = useCommaMessages();
  return (
    <Button
      className="comma-onboarding-primary"
      hierarchy={done ? "primary" : quietSkip ? "tertiary-gray" : "secondary-gray"}
      isPending={busy}
      onPress={onPress}
      size="md"
    >
      <OnboardingSwap
        states={[
          { key: "skip", label: messages.onboarding_skip_for_now() },
          { key: "continue", label: messages.onboarding_continue() },
        ]}
        value={done ? "continue" : "skip"}
      />
      <span aria-hidden="true" className="comma-onboarding-primary__spinner">
        <LoaderIcon className="animate-spin" />
      </span>
    </Button>
  );
}

/**
 * States that trade places in one grid cell: the widest holds the width, the
 * one on show fades in as the others fade out, and only it is named.
 */
export function OnboardingSwap({
  className,
  states,
  value,
}: {
  className?: string | undefined;
  states: readonly { key: string; label: ReactNode }[];
  value: string;
}) {
  return (
    <span className={cx("comma-onboarding-swap", className)}>
      {states.map((state) => (
        <span
          aria-hidden={state.key !== value || undefined}
          data-on={state.key === value}
          key={state.key}
        >
          {state.label}
        </span>
      ))}
    </span>
  );
}
