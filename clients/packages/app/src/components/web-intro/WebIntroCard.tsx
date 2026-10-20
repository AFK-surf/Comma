import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { XIcon } from "@comma/ui/components/icons";
import { cx } from "@comma/ui/components/utils";
import { registerToastObstructionTarget } from "@comma/ui/components/toast";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import {
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "../commaClientSettings";
import { commaMacDownloadUrl } from "../DesktopAppPrompt";
import { OnboardingSwap } from "../onboarding/OnboardingCard";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import { WebIntroMotion, layerPosition, type WebIntroScene } from "./WebIntroMotion";

type Messages = ReturnType<typeof useCommaMessages>;

type WebIntroTip = {
  id: WebIntroScene;
  title: (m: Messages) => string;
  body: (m: Messages) => string;
  action?: { label: (m: Messages) => string; run: "plugins" | "download" };
};

const tips: readonly WebIntroTip[] = [
  {
    id: "router",
    title: (m) => m.web_intro_router_title(),
    body: (m) => m.web_intro_router_body(),
  },
  {
    id: "apps",
    title: (m) => m.web_intro_apps_title(),
    body: (m) => m.web_intro_apps_body(),
    action: { label: (m) => m.web_intro_apps_action(), run: "plugins" },
  },
  {
    id: "mac",
    title: (m) => m.web_intro_mac_title(),
    body: (m) => m.web_intro_mac_body(),
    action: { label: (m) => m.desktop_app_get_mac(), run: "download" },
  },
];

/**
 * The web's first-launch introduction: a small card in the window's
 * bottom-right corner that walks through a few things Comma does, one tip at
 * a time. It takes the place of the desktop onboarding, which the web does
 * not show, and leaves the product usable around it: it rests above the
 * composer's line, so a narrow window or an open right sidebar never puts it
 * over the composer. It shares the toast stack's corner, so it steps left of
 * an open right sidebar the same way.
 *
 * It shares the onboarding's per-device record: an account that finished
 * either one does not see it, closing it on any tip records it, and the
 * Settings replay shows it again. Closing plays the entry backwards and hands
 * focus back to where it was before the card took it.
 */
export function WebIntroCard({ userId }: { userId: string }) {
  const m = useCommaMessages();
  const navigate = useNavigate();
  const { settings, update } = useCommaClientSettings();
  const settingsPending = useCommaClientSettingsPending();
  const [index, setIndex] = useState(0);
  // Closed but not recorded yet by the settings owner. A failed write shows
  // the card again on the next launch, not now.
  const [closed, setClosed] = useState(false);
  // Closed, and still playing its exit.
  const [leaving, setLeaving] = useState(false);
  const cardRef = useRef<HTMLElement | null>(null);
  // Where focus was before it entered the card; closing returns it there.
  const returnFocus = useRef<HTMLElement | null>(null);
  const completedUserIds = settings.onboardingCompletedUserIds;
  const completed = completedUserIds.includes(userId);

  // Reads the live obstruction through `--comma-toast-obstruction-right` set on
  // the card (see `toastObstruction`), and remembers where focus came from
  // each time it enters the card. A callback ref, because the card mounts only
  // once settings have loaded and unmounts when it is closed.
  const attachCard = useCallback((card: HTMLElement | null) => {
    if (!card) return undefined;
    cardRef.current = card;
    const release = registerToastObstructionTarget(card);
    const rememberReturn = (event: FocusEvent) => {
      const from = event.relatedTarget;
      if (from instanceof Node && card.contains(from)) return;
      returnFocus.current = from instanceof HTMLElement ? from : null;
    };
    card.addEventListener("focusin", rememberReturn);
    return () => {
      card.removeEventListener("focusin", rememberReturn);
      cardRef.current = null;
      release();
    };
  }, []);

  // The exit is the card's own transitions, retargeted from wherever the entry
  // stood; it unmounts when they finish. getAnimations() flushes style, so they
  // exist by now. Either reduced-motion signal starts none, and the card
  // unmounts at once.
  useLayoutEffect(() => {
    const card = cardRef.current;
    if (!leaving || !card) return undefined;
    const exits = card.getAnimations();
    if (exits.length === 0) {
      setLeaving(false);
      return undefined;
    }
    let live = true;
    void Promise.allSettled(exits.map((exit) => exit.finished)).then(() => {
      if (live) setLeaving(false);
    });
    return () => {
      live = false;
    };
  }, [leaving]);

  // Recorded and gone, by this tab or another: a later replay from Settings
  // starts again from the first tip. Not while leaving, so the exit keeps
  // showing the tip it closed on.
  if (completed && !leaving && (closed || index !== 0)) {
    setClosed(false);
    setIndex(0);
  }
  if (settingsPending || ((completed || closed) && !leaving)) return null;

  const tip = tips[index]!;
  const last = index === tips.length - 1;
  const close = () => {
    // Before the card goes inert, which would drop focus on <body>.
    if (cardRef.current?.contains(document.activeElement)) {
      returnFocus.current?.focus({ preventScroll: true });
    }
    setClosed(true);
    setLeaving(true);
    void update({ onboardingCompletedUserIds: [...completedUserIds, userId] });
  };
  const runAction = (run: "plugins" | "download") => {
    if (run === "plugins") void navigate({ to: "/plugins" });
    if (run === "download") void openNativePlatformExternalUrl(commaMacDownloadUrl);
  };

  return (
    <aside
      aria-hidden={leaving || undefined}
      aria-label={m.web_intro_label()}
      className={cx(
        "fixed right-[calc(var(--spacing-3xl)+var(--comma-toast-obstruction-right,0px))] bottom-8xl z-40",
        "flex w-[var(--container-xxs)] max-w-[calc(100vw-var(--comma-toast-obstruction-right,0px)-var(--spacing-3xl)*2)] flex-col gap-lg",
        "comma-web-intro-card rounded-2xl bg-popup-secondary p-md"
      )}
      data-leaving={leaving || undefined}
      data-testid="web-intro-card"
      inert={leaving || undefined}
      ref={attachCard}
    >
      <WebIntroMotion scene={tip.id} />
      <div className="flex flex-col gap-lg px-md pb-md">
        <div className="relative">
          {/* Every tip shares one cell, so the card keeps its tallest tip's
              height and nothing under the pointer moves. A polite region:
              a new tip is read out with its step. */}
          <div aria-atomic="true" aria-live="polite" className="grid min-w-0">
            {tips.map((item, itemIndex) => {
              const position = layerPosition(itemIndex, index);
              return (
                <div
                  aria-hidden={position !== "current" || undefined}
                  className="comma-web-intro-layer flex min-w-0 flex-col gap-xxs [grid-area:1/1]"
                  data-position={position}
                  key={item.id}
                >
                  <h2 className="pe-4xl text-sm font-medium text-balance break-words text-primary">
                    {item.title(m)}
                  </h2>
                  <p className="text-sm font-regular text-pretty break-words text-tertiary">
                    {item.body(m)}
                  </p>
                </div>
              );
            })}
            <span className="sr-only">
              {m.web_intro_step({
                current: String(index + 1),
                total: String(tips.length),
              })}
            </span>
          </div>
          <Button
            aria-label={m.web_intro_close()}
            className="absolute -top-sm -right-md"
            hierarchy="tertiary-gray"
            iconLeading={<XIcon />}
            iconOnly
            onPress={close}
            size="xs"
          />
        </div>
        <div className="flex items-center gap-md">
          <div className="flex flex-1 items-center gap-xs">
            {tips.map((item, itemIndex) => (
              <button
                aria-current={itemIndex === index ? "step" : undefined}
                aria-label={item.title(m)}
                className="comma-web-intro-dot"
                data-current={itemIndex === index}
                data-no-press-feedback=""
                key={item.id}
                onClick={() => setIndex(itemIndex)}
                type="button"
              />
            ))}
          </div>
          {/* Each tip's action shares one cell beside the primary, so the
              footer keeps its widest action's width and nothing in it moves. */}
          <div className="grid justify-items-end">
            {tips.map((item, itemIndex) => {
              if (!item.action) return null;
              const { label, run } = item.action;
              const position = layerPosition(itemIndex, index);
              return (
                <div
                  aria-hidden={position !== "current" || undefined}
                  className="comma-web-intro-layer comma-web-intro-action [grid-area:1/1]"
                  data-position={position}
                  inert={position !== "current" || undefined}
                  key={item.id}
                >
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => runAction(run)}
                    size="xs"
                  >
                    {label(m)}
                  </Button>
                </div>
              );
            })}
          </div>
          <Button
            hierarchy="primary"
            onPress={last ? close : () => setIndex(index + 1)}
            size="xs"
          >
            <OnboardingSwap
              className="justify-items-center"
              states={[
                { key: "next", label: m.web_intro_next() },
                { key: "done", label: m.web_intro_done() },
              ]}
              value={last ? "done" : "next"}
            />
          </Button>
        </div>
      </div>
    </aside>
  );
}
