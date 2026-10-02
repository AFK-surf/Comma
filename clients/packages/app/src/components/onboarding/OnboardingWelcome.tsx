import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui";
import { useId, useLayoutEffect, useRef } from "react";
import { CommaProductMark } from "../CommaProductMark";
import { withRouterNameSpacing } from "../router-identity/routerNameSpacing";
import { playPartsEnter } from "./onboardingMotion";

/**
 * The closing page, on the deepest light, once the light that swept up the
 * screen has passed: the Comma mark, the assistant ready by the name it goes
 * by, and the one way on, into the chat. Its parts arrive one after another;
 * Start chatting has the focus, so Return or Space starts.
 */
export function OnboardingWelcome({
  assistantName,
  leaving,
  onStart,
  reducedMotion,
}: {
  assistantName: string;
  /** Start chatting was pressed: the page lifts away. */
  leaving: boolean;
  onStart: () => void;
  reducedMotion: boolean;
}) {
  const messages = useCommaMessages();
  const titleId = useId();
  const bodyId = useId();
  const pageRef = useRef<HTMLElement>(null);
  const arrived = useRef(false);

  useLayoutEffect(() => {
    const page = pageRef.current;
    // It arrives once; a later change of the motion preference replays nothing.
    if (!page || arrived.current) return;
    arrived.current = true;
    playPartsEnter(
      [...page.querySelectorAll<HTMLElement>("[data-onboarding-part]")],
      reducedMotion
    );
    page
      .querySelector<HTMLElement>(".comma-onboarding-welcome__start")
      ?.focus({ preventScroll: true });
  }, [reducedMotion]);

  return (
    <section
      aria-labelledby={titleId}
      className="comma-onboarding-welcome"
      data-leaving={leaving || undefined}
      ref={pageRef}
    >
      <span
        aria-hidden="true"
        className="comma-onboarding-welcome__mark"
        data-onboarding-part=""
      >
        <CommaProductMark viewBox="2 2 16 16" />
      </span>
      <h1
        className="comma-onboarding-welcome__title"
        data-onboarding-part=""
        id={titleId}
      >
        {withRouterNameSpacing(
          messages.onboarding_welcome_title({ name: assistantName })
        )}
      </h1>
      <p className="comma-onboarding-welcome__body" data-onboarding-part="" id={bodyId}>
        {messages.onboarding_welcome_body()}
      </p>
      <span className="comma-onboarding-welcome__action" data-onboarding-part="">
        {/* The focus lands here: the page's words are read with it. */}
        <Button
          aria-describedby={`${titleId} ${bodyId}`}
          className="comma-onboarding-pill comma-onboarding-welcome__start"
          hierarchy="secondary-gray"
          onPress={onStart}
          size="lg"
        >
          {messages.onboarding_welcome_action()}
        </Button>
      </span>
    </section>
  );
}
