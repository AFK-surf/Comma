import { useCommaMessages } from "@comma/i18n/react";
import { Button, InputField, isImeKeyEvent } from "@comma/ui";
import {
  OnboardingCardFooter,
  OnboardingPrimaryButton,
  OnboardingSwap,
} from "../OnboardingCard";

export const assistantNameMaxLength = 40;

export type AssistantNameSave =
  | { status: "idle" }
  /** Continue was pressed while the workspace is still being prepared. */
  | { status: "waiting"; name: string }
  | { status: "saving" }
  /** The rename was refused: another try may save it. */
  | { status: "failed" }
  /** The workspace answered that it cannot be used: no try can save it now. */
  | { status: "unavailable" };

/**
 * The name card: a field, four suggestions that fill it, and its actions.
 * Naming can always be skipped. Empty, the one primary skips and keeps any
 * name saved before; typed, the primary saves the name and moves on, and a
 * quiet Skip beside it moves on without saving. Nothing here animates while
 * typing.
 */
export function OnboardingNamePanel({
  onChange,
  onSkip,
  onSubmit,
  save,
  unreachable = false,
  value,
}: {
  value: string;
  /** The workspace could not be reached: a waiting name says so. */
  unreachable?: boolean;
  onChange: (value: string) => void;
  /** The primary action, and Return in the field. */
  onSubmit: () => void;
  /** Moves on without saving what was typed. */
  onSkip: () => void;
  save: AssistantNameSave;
}) {
  const messages = useCommaMessages();
  const typed = value.trim();
  const busy = save.status === "saving" || save.status === "waiting";
  const suggestions = [
    messages.onboarding_name_suggestion_1(),
    messages.onboarding_name_suggestion_2(),
    messages.onboarding_name_suggestion_3(),
    messages.onboarding_name_suggestion_4(),
  ];

  return (
    <>
      <div className="comma-onboarding-card__content comma-onboarding-name">
        <div data-onboarding-focus="">
          <InputField
            aria-label={messages.onboarding_name_label()}
            autoComplete="off"
            className="comma-onboarding-name__field"
            maxLength={assistantNameMaxLength}
            onChange={(event) => onChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== "Enter" || isImeKeyEvent(event.nativeEvent)) return;
              event.preventDefault();
              // Return on an empty field does nothing: a key pressed to hurry
              // Comma along never skips the naming. Skip for now does that.
              if (value.trim()) onSubmit();
            }}
            placeholder={messages.onboarding_name_placeholder()}
            readOnly={busy}
            value={value}
            {...(save.status === "failed"
              ? { errorMessage: messages.onboarding_name_save_failed() }
              : save.status === "unavailable"
                ? { errorMessage: messages.onboarding_name_workspace_unavailable() }
                : {})}
          />
        </div>
        <fieldset
          aria-label={messages.onboarding_name_suggestions()}
          className="comma-onboarding-name__suggestions"
        >
          {suggestions.map((suggestion) => (
            <button
              aria-pressed={typed === suggestion}
              className="comma-onboarding-chip"
              key={suggestion}
              onClick={() => onChange(suggestion)}
              type="button"
            >
              {suggestion}
            </button>
          ))}
        </fieldset>
      </div>
      <OnboardingCardFooter
        note={
          <span aria-live="polite" className="comma-onboarding-card__note">
            <OnboardingSwap
              states={[
                { key: "", label: null },
                { key: "preparing", label: messages.onboarding_workspace_preparing() },
                {
                  key: "unreachable",
                  label: messages.onboarding_workspace_unreachable(),
                },
              ]}
              value={
                save.status === "waiting"
                  ? unreachable
                    ? "unreachable"
                    : "preparing"
                  : ""
              }
            />
          </span>
        }
        secondary={
          typed ? (
            <span className="comma-onboarding-card__secondary">
              <Button
                className="comma-onboarding-name__skip"
                hierarchy="tertiary-gray"
                onPress={onSkip}
                size="md"
              >
                {messages.onboarding_name_skip()}
              </Button>
            </span>
          ) : null
        }
        primary={
          <OnboardingPrimaryButton
            busy={busy}
            done={typed.length > 0}
            onPress={onSubmit}
          />
        }
      />
    </>
  );
}
