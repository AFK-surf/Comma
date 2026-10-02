import { useCommaMessages } from "@comma/i18n/react";
import { Button, CommaLogoAnimation, motionDuration } from "@comma/ui";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import {
  introLeaveMs,
  introTiming,
  playIntroLeave,
  playIntroPartsEnter,
  playIntroSkip,
  playLogoEnter,
  playLogoFade,
  playLogoTravel,
  stopLogoThinking,
} from "./onboardingMotion";

/**
 * - `dim`: the screen dims; nothing is shown yet.
 * - `welcome`: the mark in the middle, the welcome and Start under it.
 * - `starting`: Start was pressed; the welcome and Start leave.
 * - `header`: the mark heads the conversation.
 */
type IntroStage = "dim" | "welcome" | "starting" | "header";

/**
 * The onboarding's opening, and then the head of its conversation. The
 * screen dims first (the light field does that); then the Comma mark arrives
 * in the middle and starts thinking, and the welcome and Start follow under
 * it. Start begins the onboarding, and so does Start left alone for a while
 * (no countdown shows): the mark stops thinking and moves up to the top,
 * where it stays over the conversation. A flow that starts further on has
 * the mark at the top.
 */
export function OnboardingIntro({
  leaving,
  onBegin,
  onPressStart,
  onStart,
  playing,
  reducedMotion,
  takeFocus,
}: {
  /** The intro plays; otherwise the mark heads the conversation already. */
  playing: boolean;
  /** Closed during the intro: everything here leaves at once. */
  leaving: boolean;
  /** Start was pressed, or its countdown ran out. */
  onStart: () => void;
  /** Start was pressed by the user, just before `onStart`. */
  onPressStart: () => void;
  /** The mark has reached the top: the conversation begins. */
  onBegin: () => void;
  reducedMotion: boolean;
  /** Moves the focus to `control`, as the onboarding does for each part. */
  takeFocus: (control: HTMLElement) => void;
}) {
  const messages = useCommaMessages();
  const titleId = useId();
  const [stage, setStage] = useState<IntroStage>(playing ? "dim" : "header");
  const [thinking, setThinking] = useState(false);
  const sectionRef = useRef<HTMLElement>(null);
  const logoRef = useRef<HTMLSpanElement>(null);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const actionRef = useRef<HTMLSpanElement>(null);
  // Where the mark was drawn as it left the middle, for its move to the top.
  const travelFrom = useRef<DOMRect>(undefined);
  const timers = useRef<number[]>([]);
  const latest = useRef({ leaving, onBegin, onStart, reducedMotion, takeFocus });
  useLayoutEffect(() => {
    latest.current = { leaving, onBegin, onStart, reducedMotion, takeFocus };
  });

  useEffect(() => {
    const scheduled = timers.current;
    return () => scheduled.forEach((timer) => window.clearTimeout(timer));
  }, []);
  const later = (run: () => void, ms: number) => {
    timers.current.push(
      window.setTimeout(() => {
        if (!latest.current.leaving) run();
      }, ms)
    );
  };

  // The mark arrives once the screen has dimmed.
  useEffect(() => {
    if (stage !== "dim" || leaving) return undefined;
    const timer = window.setTimeout(() => setStage("welcome"), introTiming.dim);
    return () => window.clearTimeout(timer);
  }, [leaving, stage]);

  const start = () => {
    if (stage !== "welcome" || latest.current.leaving) return;
    setStage("starting");
    latest.current.onStart();
    const logo = logoRef.current;
    const reduced = latest.current.reducedMotion;
    playIntroLeave(
      [titleRef.current, actionRef.current].filter(
        (part): part is HTMLElement => part !== null
      ),
      reduced
    );
    // The mark finishes the turn under way, quickly, then moves up.
    const thinkingMark = logo?.querySelector("svg");
    const settleMs = thinkingMark
      ? stopLogoThinking(thinkingMark, motionDuration.dialogEnter)
      : 0;
    if (reduced && logo) playLogoFade(logo);
    later(
      () => {
        travelFrom.current = logoRef.current?.getBoundingClientRect();
        setStage("header");
      },
      Math.max(introLeaveMs, settleMs)
    );
  };
  const startRef = useRef(start);
  useLayoutEffect(() => {
    startRef.current = start;
  });

  // The mark, then the welcome and Start under it. Start takes the focus as
  // it appears; left alone, it starts by itself.
  useLayoutEffect(() => {
    if (stage !== "welcome") return undefined;
    const reduced = latest.current.reducedMotion;
    if (logoRef.current) playLogoEnter(logoRef.current, reduced);
    playIntroPartsEnter(
      [titleRef.current, actionRef.current].filter(
        (part): part is HTMLElement => part !== null
      ),
      reduced
    );
    const steps = [
      window.setTimeout(() => setThinking(true), introTiming.thinking),
      window.setTimeout(() => {
        const action = actionRef.current?.querySelector<HTMLElement>("button");
        if (action) latest.current.takeFocus(action);
      }, introTiming.start),
      window.setTimeout(() => startRef.current(), introTiming.autoStart),
    ];
    return () => steps.forEach((step) => window.clearTimeout(step));
  }, [stage]);

  // At the top the mark heads the conversation, which begins once it is there.
  useLayoutEffect(() => {
    const from = travelFrom.current;
    const logo = logoRef.current;
    if (stage !== "header" || !from || !logo) return;
    travelFrom.current = undefined;
    const travelMs = playLogoTravel(logo, from, latest.current.reducedMotion);
    later(() => latest.current.onBegin(), travelMs);
  }, [stage]);

  useLayoutEffect(() => {
    if (leaving && sectionRef.current) playIntroSkip(sectionRef.current);
  }, [leaving]);

  const welcoming = stage === "welcome" || stage === "starting";

  return (
    <section
      aria-labelledby={welcoming ? titleId : undefined}
      className="comma-onboarding-intro"
      data-stage={stage}
      ref={sectionRef}
    >
      {/* Laid out, unseen and out of reach while the screen dims, so the
          mark arrives on a frame that only has to start its motion. */}
      <div
        aria-hidden={stage === "dim" || undefined}
        className="comma-onboarding-intro__column"
        inert={stage === "dim"}
      >
        <span aria-hidden="true" className="comma-onboarding-intro__mark" ref={logoRef}>
          <CommaLogoAnimation
            className="comma-onboarding-intro__logo"
            cutout
            paused={!thinking}
          />
        </span>
        {stage === "header" ? null : (
          <>
            <h1 className="comma-onboarding-intro__title" id={titleId} ref={titleRef}>
              {messages.onboarding_intro_title()}
            </h1>
            <span className="comma-onboarding-intro__action" ref={actionRef}>
              <Button
                className="comma-onboarding-pill"
                hierarchy="secondary-gray"
                isDisabled={stage !== "welcome" || leaving}
                onPress={() => {
                  // Pressed, not the start it makes by itself: a click.
                  onPressStart();
                  startRef.current();
                }}
                size="lg"
              >
                {messages.onboarding_intro_start()}
              </Button>
            </span>
          </>
        )}
      </div>
    </section>
  );
}
