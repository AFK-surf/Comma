/* oxlint-disable jsx-a11y/no-autofocus -- The onboarding is a modal flow: while Comma talks, its full-window control takes focus so Return and Space hurry it along. */
import { useCommaMessages } from "@comma/i18n/react";
import type { SideChatShortcut } from "@comma/native-bridge";
import {
  Button,
  isMediaMuteShortcut,
  NativeSurfaceSuppressor,
  Tooltip,
  XIcon,
  motionDuration,
  spacing,
} from "@comma/ui";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { flushSync } from "react-dom";
import { Dialog, Modal, ModalOverlay } from "react-aria-components";
import { measureOutgoingBubbleSource } from "../chat/motion/outgoingBubbleMotion";
import { useLeaving } from "../chat/motion/useLeaving";
import { onboardingAssistantName } from "../router-identity/onboardingAssistantName";
import { withRouterNameSpacing } from "../router-identity/routerNameSpacing";
import { OnboardingCard } from "./OnboardingCard";
import { OnboardingConversation } from "./OnboardingConversation";
import { OnboardingIntro } from "./OnboardingIntro";
import { OnboardingShortcut } from "./OnboardingShortcut";
import { OnboardingSoundControl, useOnboardingSound } from "./OnboardingSound";
import {
  OnboardingLightField,
  type OnboardingLightIntensity,
} from "./OnboardingLightField";
import { OnboardingWelcome } from "./OnboardingWelcome";
import {
  OnboardingAppsPanel,
  onboardingConnectedAppIds,
  onboardingConnectedApps,
} from "./items/OnboardingAppsPanel";
import {
  OnboardingNamePanel,
  type AssistantNameSave,
} from "./items/OnboardingNamePanel";
import {
  flashClearMs,
  flashMs,
  introLeaveMs,
  playCardEnter,
  playCardLeave,
  playFlash,
  playSweep,
  playThreadMove,
  playThreadRecede,
  sweepBand,
  sweepClearMs,
  threadRecedeMs,
  threadTop,
} from "./onboardingMotion";
import { useHoldOnboardingOpen } from "./onboardingPresence";
import {
  fitOnboardingAppRows,
  initialOnboardingThread,
  nextOnboardingStep,
  onboardingItemDone,
  onboardingGreetingLanded,
  onboardingItemsFor,
  onboardingLightDepth,
  onboardingMessageInFlight,
  onboardingThreadReducer,
  pendingOnboardingLine,
  type OnboardingItemId,
  type OnboardingItemResult,
  type OnboardingLine,
  type OnboardingMissing,
  type OnboardingPresentation,
  type OnboardingResults,
  type OnboardingStart,
  type OnboardingStep,
  type OnboardingThreadAction,
  type OnboardingTiming,
} from "./onboardingSetup";
import { onboardingKeycaps } from "./onboardingShortcutKeys";
import type { OnboardingPermissionsResult } from "./permissions/PermissionsPanel";
import {
  onboardingPreferredPluginCount,
  type OnboardingPluginList,
} from "./useOnboardingPlugins";
import type { OnboardingWorkspace } from "./useOnboardingWorkspace";
import { useReducedMotion } from "./useReducedMotion";

type Messages = ReturnType<typeof useCommaMessages>;

export type OnboardingPermissionsSlot = {
  /** The name the assistant goes by right now. */
  assistantName: string;
  /** The user moved on: the item is done once one grant is allowed. */
  onAdvance: (result: OnboardingPermissionsResult) => void;
};

export type OnboardingOverlayProps = {
  /** Over the product in its own window, or over the desktop (Electron). */
  presentation: OnboardingPresentation;
  /** Where the flow starts; the product starts at the intro. */
  initialStage?: OnboardingStart;
  /**
   * What the items passed on the way to `initialStage` came to (stories and
   * tests); an item missing here was skipped.
   */
  initialResults?: OnboardingResults;
  /** The Router Agent's stored name, `undefined` until it is read. */
  routerName: string | undefined;
  workspace: OnboardingWorkspace;
  plugins: OnboardingPluginList;
  onConnectPlugin: (pluginId: string) => void;
  /**
   * The macOS grants, where they exist. Given, "Let me work on this Mac" is
   * the third exchange and its card mounts only while it is up; otherwise the
   * setup has two.
   */
  renderPermissions?: ((slot: OnboardingPermissionsSlot) => ReactNode) | undefined;
  /** Renames the Router of `workspaceId`; rejects when the name was not saved. */
  onSaveRouterName: (name: string, workspaceId: string) => Promise<void>;
  /** The user pressed Start chatting on the welcome page. Record completion now. */
  onComplete: () => void;
  /** The user answered an item: its card leaves with what it came to. */
  onItemAnswered?: ((result: OnboardingItemResult) => void) | undefined;
  /**
   * The user left the setup before its end, by the corner's Close or the
   * shortcut's Skip: what is still to do is skipped.
   */
  onSkipSetup?: (() => void) | undefined;
  /** The exit has played out; unmount the overlay or close the window. */
  onExited: () => void;
  /** The tone Comma speaks in for the whole conversation; calm by default. */
  voice?: OnboardingVoice;
  /**
   * The Open Comma shortcut, where the onboarding teaches it (the macOS app,
   * with the shortcut set). Given, the user presses its keys between the
   * conversation and the welcome page; otherwise the welcome page follows the
   * conversation.
   */
  openShortcut?: SideChatShortcut | undefined;
  /**
   * The Side Chat shortcut, where the Side Chat can be brought out (the macOS
   * app, with the shortcut set). Given, Comma tells of the Side Chat and its
   * shortcut once every item is answered.
   */
  sideChatShortcut?: SideChatShortcut | undefined;
};

/**
 * The tones Comma can speak in. The product picks one at random for each
 * onboarding (`randomOnboardingVoice`) and keeps it to the end, so the
 * conversation reads as one speaker. Every line Comma says has a wording in
 * each: the calm one under its own key, the others under `<key>_<voice>`.
 */
export const onboardingVoices = [
  "calm",
  "brisk",
  "playful",
  "warm",
  "witty",
  "minimal",
] as const;
export type OnboardingVoice = (typeof onboardingVoices)[number];

export function randomOnboardingVoice(): OnboardingVoice {
  return onboardingVoices[Math.floor(Math.random() * onboardingVoices.length)]!;
}

/** The catalog keys of Comma's lines, each worded in every voice. */
export const onboardingVoicedKeys = [
  "onboarding_greeting_value",
  "onboarding_greeting_no_group",
  "onboarding_greeting_items_three",
  "onboarding_greeting_items_two",
  "onboarding_question_apps",
  "onboarding_question_name",
  "onboarding_question_permissions",
  "onboarding_bridge_apps_connected",
  "onboarding_bridge_apps_uses",
  "onboarding_bridge_apps_skipped",
  "onboarding_bridge_name_named",
  "onboarding_bridge_name_skipped",
  "onboarding_bridge_name_router",
  "onboarding_bridge_permissions_allowed",
  "onboarding_bridge_permissions_skipped",
  "onboarding_bridge_permissions_partial",
  "onboarding_side_chat",
  "onboarding_recap",
] as const satisfies readonly (keyof Messages)[];
type VoicedKey = (typeof onboardingVoicedKeys)[number];

/** A line's wording in `voice`; every voice takes the calm one's parameters. */
function voiced<Key extends VoicedKey>(
  messages: Messages,
  voice: OnboardingVoice,
  key: Key
): Messages[Key] {
  return messages[(voice === "calm" ? key : `${key}_${voice}`) as Key];
}

const timing: OnboardingTiming = {
  // The first line comes a beat after the mark has settled at the top.
  firstLine: motionDuration.onboardingFirstLine,
  stagger: motionDuration.onboardingBubbleStagger,
  replyBeat: motionDuration.onboardingReplyBeat,
  welcomeBeat: motionDuration.onboardingWelcomeBeat,
  shortcutBeat: motionDuration.onboardingShortcutBeat,
  cardLeave: motionDuration.stateChange,
  shortcutDone: motionDuration.onboardingShortcutDone,
};

/** Where the light that sweeps up into the welcome page runs, in the screen's height. */
const sweepStyle = {
  "--onboarding-sweep-reach": `${sweepBand.reach * 100}cqh`,
  "--onboarding-sweep-core": `${sweepBand.core * 100}cqh`,
} as CSSProperties;

/**
 * How long a rename may take before the card says it was not saved and
 * offers to try again: a request that never answers (the network gone
 * quiet) must not hold the card.
 */
const nameSaveTimeoutMs = 15_000;

/**
 * One app row at the default font size: the plugin artwork and its padding.
 * The list is sized from a rendered row once there is one.
 */
const appRowHeight = spacing["5xl"] + spacing.xs + 2 * spacing.md;
/** Kept clear at the thread's top edge, where what no longer fits fades out. */
const threadFade = spacing["3xl"];
/** The question over the card on two lines, and the gap under it. */
const questionBlock = spacing["7xl"] + spacing.md;
/** The card around its list: its padding, and its footer with the primary. */
const cardFrame = 2 * spacing.md + spacing.lg + spacing["5xl"];

/**
 * The first-launch onboarding as a conversation with Comma. The screen dims,
 * and the Comma mark welcomes the user until they start (OnboardingIntro.tsx);
 * then, under the mark, Comma greets the user and asks for each setup item in
 * turn: its question comes with a card of the item's controls, the user's
 * answer is sent back as their reply, and Comma acknowledges it before asking
 * for the next. Where the Side Chat can be brought out, Comma then tells of it
 * and its shortcut. Where an Open Comma shortcut is set, the conversation then
 * steps back for it (OnboardingShortcut.tsx): the user presses its keys, they
 * turn green, and a beat later a white light sweeping up
 * the screen clears the conversation (or the shortcut) for the welcome page,
 * which hands the user to the chat. Skip setup goes to that page at any point.
 * Everything it shows or changes arrives through props, so the product and
 * the stories drive it the same way. While mounted it holds the onboarding
 * presence (onboardingPresence.ts).
 *
 * `overlay` covers the product inside its window and blurs it. `window` fills
 * a transparent, immovable window over the desktop, below its menu bar and
 * over its Dock.
 */
export function OnboardingOverlay({
  initialResults,
  initialStage = "intro",
  onComplete,
  onConnectPlugin,
  onItemAnswered,
  onSkipSetup,
  onExited,
  onSaveRouterName,
  openShortcut,
  plugins,
  presentation,
  renderPermissions,
  routerName,
  sideChatShortcut,
  voice = "calm",
  workspace,
}: OnboardingOverlayProps) {
  useHoldOnboardingOpen();
  const messages = useCommaMessages();
  const reducedMotion = useReducedMotion();
  const [keyboardNavigating, stopKeyboardNavigation] = useKeyboardNavigation();

  // The assistant's name: the one it has, else "Comma". The onboarding never
  // calls it "Router".
  const brandName = onboardingAssistantName(undefined);
  const storedName = onboardingAssistantName(routerName);
  const savedName = storedName === brandName ? "" : storedName;

  const [thread, dispatch] = useReducer(
    onboardingThreadReducer,
    undefined,
    (): ReturnType<typeof initialOnboardingThread> =>
      initialOnboardingThread({
        at: performance.now(),
        items: onboardingItemsFor({ permissions: renderPermissions !== undefined }),
        results: initialResults,
        shortcut: openShortcut !== undefined,
        sideChat: sideChatShortcut,
        speaker: storedName,
        start: initialStage,
      })
  );
  const { phase } = thread;
  const itemCount = thread.items.length;
  const named = thread.results.name;
  // The name it goes by from here on: the one given here, else the one it has.
  const assistantName = named?.named ? named.name : storedName;
  // What Comma's lines are labelled with as they are sent. Until the stored
  // name is read, a line waits for it rather than keeping "Comma".
  const speaker = named?.named || routerName !== undefined ? assistantName : undefined;

  // Its intro sound plays from the start, and fades out as the onboarding exits.
  const sound = useOnboardingSound({
    ending: phase === "exit",
    play: initialStage === "intro",
  });
  const { toggleMuted } = sound;
  // M mutes, or brings the sound back, wherever the focus is but a text field.
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (!isMediaMuteShortcut(event) || isTextEntry(event.target)) return;
      event.preventDefault();
      toggleMuted();
    };
    document.addEventListener("keydown", keydown);
    return () => document.removeEventListener("keydown", keydown);
  }, [toggleMuted]);

  const [nameDraft, setNameDraft] = useState<string>();
  const nameValue = nameDraft ?? savedName;
  const [nameSave, setNameSave] = useState<AssistantNameSave>({ status: "idle" });

  const dialogRef = useRef<HTMLElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const stageContentRef = useRef<HTMLDivElement>(null);
  const lightRef = useRef<HTMLDivElement>(null);
  // The thread mounts with the conversation, after the intro.
  const [threadElement, setThreadElement] = useState<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const columnRef = useRef<HTMLDivElement>(null);
  const launchpadRef = useRef<HTMLDivElement>(null);
  const cardRef = useRef<HTMLFieldSetElement>(null);
  const skipRef = useRef<HTMLDivElement>(null);
  const focusTimer = useRef<number>(undefined);
  useEffect(() => () => window.clearTimeout(focusTimer.current), []);

  const spaceName = messages.onboarding_shortcut_space();
  const commaName = messages.onboarding_shortcut_comma();
  const keycaps = useMemo(
    () =>
      openShortcut
        ? onboardingKeycaps(openShortcut, { comma: commaName, space: spaceName })
        : [],
    [commaName, openShortcut, spaceName]
  );

  const lineText = useCallback(
    (line: OnboardingLine) => onboardingLineText(line, messages, itemCount, voice),
    [itemCount, messages, voice]
  );
  const texts = useMemo(
    () =>
      thread.messages.map((message) =>
        message.from === "comma"
          ? lineText(message.line)
          : onboardingReplyText(message.result, messages)
      ),
    [lineText, messages, thread.messages]
  );
  // The invisible composer holds what is sent next, as the chat's composer
  // holds the draft: the send motion lifts it off from there.
  const pendingLine = pendingOnboardingLine(thread);
  const draft = thread.finishing
    ? onboardingReplyText(thread.finishing.result, messages)
    : pendingLine
      ? lineText(pendingLine)
      : "";

  /**
   * Commits a change to the thread and plays the thread back from where it
   * was drawn. A send first lays its bubble out on the next frame (the chat's
   * send motion measures it there), so the move is placed on that frame.
   */
  const move = useCallback(
    (action: OnboardingThreadAction, withSend: boolean) => {
      const content = contentRef.current;
      const from = content ? threadTop(content) : undefined;
      flushSync(() => dispatch(action));
      // Comma done talking takes its full-window control away; the dialog
      // keeps the focus rather than the modal handing it to Skip setup.
      const dialog = dialogRef.current;
      if (dialog && !dialog.contains(document.activeElement)) {
        dialog.focus({ preventScroll: true });
      }
      if (!content || from === undefined) return;
      const play = () => playThreadMove(content, from, { reducedMotion, withSend });
      if (withSend) requestAnimationFrame(play);
      else play();
    },
    [reducedMotion]
  );

  // The onboarding moves the focus itself to each part's control; that focus
  // shows no ring until the user moves on with the keyboard.
  // A card's text field takes the focus; any other card takes it itself, so
  // a Return or Space pressed to hurry Comma along never lands on its
  // primary (Skip for now) and skips the item. Tab moves into its controls.
  const focusCard = useCallback(() => {
    const card = cardRef.current;
    // The user already reached into the card (a quick Allow): leave it there.
    const active = document.activeElement;
    if (card && active !== card && card.contains(active)) return;
    const field = card?.querySelector<HTMLElement>("[data-onboarding-focus] input");
    stopKeyboardNavigation();
    (field ?? card)?.focus({ preventScroll: true });
  }, [stopKeyboardNavigation]);

  // The onboarding moves the focus itself: it shows no ring.
  const takeFocus = useCallback(
    (control: HTMLElement) => {
      stopKeyboardNavigation();
      control.focus({ preventScroll: true });
    },
    [stopKeyboardNavigation]
  );
  const focusDialog = useCallback(() => {
    if (dialogRef.current) takeFocus(dialogRef.current);
  }, [takeFocus]);
  const begin = useCallback(
    () => dispatch({ type: "begin", at: performance.now() }),
    []
  );

  /**
   * The welcome page, from the conversation, the Open Comma shortcut, or the
   * intro. A white light sweeps up the screen and clears what is on show
   * behind it (reduced motion: a quick flash); the intro simply leaves.
   */
  const toWelcome = useCallback(() => {
    if (phase !== "intro" && phase !== "conversation" && phase !== "shortcut") return;
    window.clearTimeout(focusTimer.current);
    focusDialog();
    // What is still to do is skipped: a name that waits for the workspace is
    // never sent. One already on its way cannot be recalled.
    setNameSave((save) => (save.status === "waiting" ? { status: "idle" } : save));
    flushSync(() => dispatch({ type: "welcome", at: performance.now() }));
    const stage = stageRef.current;
    const content = stageContentRef.current;
    const light = lightRef.current;
    const skip = skipRef.current;
    if (phase === "intro" || !stage || !content || !light) return;
    if (reducedMotion) {
      playFlash({ flash: light, skip, stage });
      return;
    }
    playSweep({
      band: light,
      content,
      screen: dialogRef.current?.getBoundingClientRect() ?? {
        height: window.innerHeight,
        top: 0,
      },
      skip,
      stage,
    });
  }, [focusDialog, phase, reducedMotion]);

  const runStep = (step: OnboardingStep) => {
    switch (step.type) {
      case "say":
        move(
          {
            type: "say",
            at: performance.now(),
            line: step.line,
            source: measureOutgoingBubbleSource(launchpadRef.current),
            speaker,
          },
          true
        );
        return;
      case "reply":
        move(
          {
            type: "reply",
            at: performance.now(),
            source: measureOutgoingBubbleSource(launchpadRef.current),
          },
          true
        );
        return;
      case "show-card": {
        move({ type: "show-card", item: step.item }, false);
        if (cardRef.current) playCardEnter(cardRef.current, reducedMotion);
        // Hold focus on the dialog while the thread makes room, so a second
        // Return that hurried Comma along cannot also press the card's action.
        dialogRef.current?.focus({ preventScroll: true });
        window.clearTimeout(focusTimer.current);
        focusTimer.current = window.setTimeout(
          focusCard,
          motionDuration.onboardingSettle
        );
        return;
      }
      case "shortcut": {
        // The shortcut is no longer set: on to the welcome page.
        if (!openShortcut) {
          toWelcome();
          return;
        }
        window.clearTimeout(focusTimer.current);
        focusDialog();
        flushSync(() => dispatch({ type: "shortcut", at: performance.now() }));
        if (columnRef.current) playThreadRecede(columnRef.current, reducedMotion);
        return;
      }
      case "welcome":
        toWelcome();
    }
  };
  const runStepRef = useRef(runStep);
  useLayoutEffect(() => {
    runStepRef.current = runStep;
  });

  // The conversation goes on by itself: each step when it is due.
  useEffect(() => {
    const next = nextOnboardingStep(thread, timing);
    if (!next) return undefined;
    const timer = window.setTimeout(
      () => runStepRef.current(next.step),
      Math.max(0, next.at - performance.now())
    );
    return () => window.clearTimeout(timer);
  }, [thread]);

  // Whether the Open Comma shortcut step is offered, and the Side Chat
  // shortcut Comma tells of, follow the settings until the conversation is
  // over.
  const shortcutOffered = openShortcut !== undefined;
  useEffect(() => {
    dispatch({ type: "offer-shortcut", offered: shortcutOffered });
  }, [shortcutOffered]);
  useEffect(() => {
    dispatch({ type: "offer-side-chat", shortcut: sideChatShortcut });
  }, [sideChatShortcut]);

  // The shortcut is turned off mid-step: nothing is left to press, so on to
  // the welcome page.
  const shortcutGone = phase === "shortcut" && !openShortcut;
  useEffect(() => {
    if (!shortcutGone) return undefined;
    // Out of the commit, as every step runs (the sweep flushes its state).
    const timer = window.setTimeout(toWelcome);
    return () => window.clearTimeout(timer);
  }, [shortcutGone, toWelcome]);

  const shortcutPressed = useCallback(
    () => dispatch({ type: "shortcut-pressed", at: performance.now() }),
    []
  );
  const skipShortcut = () => {
    onSkipSetup?.();
    toWelcome();
  };

  const landed = useCallback(
    (id: number) => dispatch({ type: "landed", id, at: performance.now() }),
    []
  );

  /**
   * The user finished the item on show: its card leaves, and the reply follows.
   * Answering the name passes the name the assistant had until then.
   */
  const finishItem = (result: OnboardingItemResult, previousName?: string) => {
    if (phase !== "conversation" || thread.card !== result.item || thread.finishing) {
      return;
    }
    window.clearTimeout(focusTimer.current);
    dialogRef.current?.focus({ preventScroll: true });
    flushSync(() =>
      dispatch({ type: "finish", result, at: performance.now(), speaker: previousName })
    );
    if (cardRef.current) playCardLeave(cardRef.current, reducedMotion);
    onItemAnswered?.(result);
  };
  const finishItemRef = useRef(finishItem);
  useLayoutEffect(() => {
    finishItemRef.current = finishItem;
  });

  const hurry = () => move({ type: "hurry", at: performance.now(), speaker }, false);

  const start = () => {
    if (phase !== "welcome") return;
    sound.click();
    onComplete();
    dispatch({ type: "exit" });
  };

  // The corner's Close: the onboarding leaves from where it is, without the
  // welcome page, and counts as finished.
  const [closed, setClosed] = useState(false);
  const close = () => {
    if (phase === "welcome" || phase === "exit") return;
    // As on the way to the welcome page, a name that waits for the workspace
    // is never sent.
    setNameSave((save) => (save.status === "waiting" ? { status: "idle" } : save));
    onSkipSetup?.();
    onComplete();
    setClosed(true);
    dispatch({ type: "exit" });
  };

  useEffect(() => {
    if (phase !== "exit") return undefined;
    // The page leaves, then the light lifts; reduced motion has nothing to fade.
    const timer = window.setTimeout(
      onExited,
      reducedMotion ? 0 : motionDuration.revealItem + motionDuration.onboardingExit
    );
    return () => window.clearTimeout(timer);
  }, [onExited, phase, reducedMotion]);

  // Name: saving is a request. Unchanged, the item moves on without one;
  // empty, it skips and keeps the name saved before; a failure stays, and says so.
  // Each save is one attempt; a skip or a slow save's timeout leaves it, so
  // an answer arriving after the user has moved on changes nothing here.
  const saveAttempt = useRef(0);
  const saveName = useCallback(
    async (name: string, workspaceId: string, previousName: string) => {
      const attempt = ++saveAttempt.current;
      setNameSave({ status: "saving" });
      let timer: number | undefined;
      try {
        await Promise.race([
          onSaveRouterName(name, workspaceId),
          new Promise<never>((_, reject) => {
            timer = window.setTimeout(
              () => reject(new Error("rename timed out")),
              nameSaveTimeoutMs
            );
          }),
        ]);
      } catch {
        if (attempt === saveAttempt.current) setNameSave({ status: "failed" });
        return;
      } finally {
        window.clearTimeout(timer);
      }
      if (attempt !== saveAttempt.current) return;
      setNameSave({ status: "idle" });
      setNameDraft(undefined);
      // Shown as every chat surface shows it: "Router" or a provisioned
      // "Default workspace …" name reads as the rest of the product reads it.
      finishItemRef.current(
        { item: "name", name: onboardingAssistantName(name), named: true },
        previousName
      );
    },
    [onSaveRouterName]
  );

  const submitName = () => {
    if (nameSave.status === "saving" || nameSave.status === "waiting") return;
    const name = nameValue.trim();
    if (!name || name === savedName) {
      setNameSave({ status: "idle" });
      setNameDraft(undefined);
      finishItem(
        name
          ? { item: "name", name: onboardingAssistantName(name), named: true }
          : { item: "name", name: storedName, named: false },
        storedName
      );
      return;
    }
    if (workspace.status === "ready") {
      void saveName(name, workspace.workspaceId, storedName);
      return;
    }
    setNameSave(
      workspace.status === "unavailable"
        ? { status: "unavailable" }
        : { status: "waiting", name }
    );
  };

  // Skip never saves: what was typed is dropped and the name saved before
  // stays. It is there whenever a name is typed, a save still running
  // included: that save is left behind.
  const skipName = () => {
    saveAttempt.current += 1;
    setNameSave({ status: "idle" });
    setNameDraft(undefined);
    finishItem({ item: "name", name: storedName, named: false }, storedName);
  };

  // A name submitted while the workspace was being prepared saves once it is ready.
  useEffect(() => {
    if (nameSave.status !== "waiting") return;
    if (workspace.status === "ready") {
      void saveName(nameSave.name, workspace.workspaceId, storedName);
    } else if (workspace.status === "unavailable") {
      setNameSave({ status: "unavailable" });
    }
  }, [nameSave, saveName, storedName, workspace]);

  // The apps card shows every app that fits over the composer, with its
  // question above it; a longer list scrolls inside it. Its rows are as tall
  // as the font size makes them.
  const threadHeight = useContentHeight(threadElement);
  const [rowHeight, setRowHeight] = useState(appRowHeight);
  const rowCount =
    plugins.status === "ready" ? plugins.rows.length : onboardingPreferredPluginCount;
  const listRows =
    threadHeight === undefined
      ? rowCount
      : fitOnboardingAppRows({
          room: threadHeight - threadFade - questionBlock - cardFrame,
          rowCount,
          rowHeight,
        });

  const renderCard = (item: OnboardingItemId) => {
    switch (item) {
      case "apps":
        return (
          <OnboardingAppsPanel
            fits={listRows >= rowCount}
            list={plugins}
            onConnect={onConnectPlugin}
            onContinue={() =>
              finishItem({
                item: "apps",
                connected: onboardingConnectedApps(plugins),
                ids: onboardingConnectedAppIds(plugins),
                offered: plugins.status !== "ready" || plugins.rows.length > 0,
              })
            }
            onRowHeight={setRowHeight}
          />
        );
      case "name":
        return (
          <OnboardingNamePanel
            onChange={(value) => {
              setNameDraft(value);
              if (nameSave.status === "failed") setNameSave({ status: "idle" });
            }}
            onSkip={skipName}
            onSubmit={submitName}
            save={nameSave}
            unreachable={
              workspace.status === "preparing" && workspace.unreachable === true
            }
            value={nameValue}
          />
        );
      case "permissions":
        return renderPermissions?.({
          assistantName,
          onAdvance: (result) => finishItem({ item: "permissions", ...result }),
        });
    }
  };
  const cardItem = thread.card;
  const card = cardItem ? (
    <OnboardingCard
      cardRef={cardRef}
      item={cardItem}
      key={cardItem}
      label={lineText({ kind: "question", item: cardItem })}
      leaving={thread.finishing !== undefined}
    >
      {renderCard(cardItem)}
    </OnboardingCard>
  ) : null;

  // The conversation (and the shortcut after it) stays until the light has
  // cleared it, and the light until it has passed; the intro stays for its
  // leave after Skip setup. The welcome page comes in once they are gone,
  // right behind the light.
  const introducing = phase === "intro";
  const talking = phase === "conversation";
  const keying = phase === "shortcut";
  const closing = phase === "welcome" || phase === "exit";
  const clearMs = reducedMotion ? flashClearMs : sweepClearMs;
  const clearing =
    useLeaving(talking || keying, clearMs) === true && !talking && !keying;
  const keysClearing = useLeaving(keying, clearMs) === true && !keying;
  // The conversation has stepped back for the shortcut.
  const receded = keying || keysClearing;
  // The light is drawn ahead, parked under the screen, while nothing moves:
  // from Comma's last line, through the beat before what closes the setup.
  // The GPU builds what it draws with then rather than as the sweep starts,
  // where the first frames would stall.
  const closingNext = talking
    ? nextOnboardingStep(thread, timing)?.step.type
    : undefined;
  const lightParked = keying || closingNext === "shortcut" || closingNext === "welcome";
  const lightPassing =
    useLeaving(
      talking || keying,
      reducedMotion ? flashMs : motionDuration.onboardingSweep
    ) === true &&
    !talking &&
    !keying;
  const lighting = !closed && (lightParked || lightPassing);
  const skipping = useLeaving(introducing, introLeaveMs) === true && closing;
  const staged = introducing || talking || keying || clearing || skipping;
  const welcoming = closing && !clearing && !lighting && !skipping && !closed;
  const hurrying =
    talking && !thread.card && !thread.finishing && pendingLine !== undefined;

  // The light answers progress: it calms once the greeting is over, each
  // finished item takes it a step deeper, and the Open Comma shortcut and the
  // welcome page, whose words stand in the middle of the screen, are the
  // deepest. Each change waits for the bubbles to land (onboardingSetup.ts).
  const intensity: OnboardingLightIntensity =
    phase === "exit"
      ? "exit"
      : phase === "welcome" || phase === "shortcut"
        ? "finale"
        : onboardingGreetingLanded(thread)
          ? "thread"
          : "intro";

  return (
    <ModalOverlay
      className="comma-onboarding"
      data-keyboard={keyboardNavigating ? "true" : "false"}
      data-closed={closed || undefined}
      data-phase={phase}
      data-presentation={presentation}
      data-reduced-motion={reducedMotion ? "true" : "false"}
      isDismissable={false}
      isKeyboardDismissDisabled
      isOpen
    >
      <Modal className="comma-onboarding__modal">
        <NativeSurfaceSuppressor />
        <OnboardingLightField
          depth={onboardingLightDepth(thread)}
          holding={onboardingMessageInFlight(thread)}
          intensity={intensity}
          presentation={presentation}
        />
        <Dialog
          aria-label={messages.onboarding_dialog_label()}
          className="comma-onboarding__dialog"
          ref={dialogRef}
          style={sweepStyle}
        >
          {hurrying ? (
            // While Comma talks, the whole window is the way on: a click
            // anywhere, or Return or Space on this focused control, brings
            // what it has left to say at once.
            <button
              aria-label={messages.onboarding_continue()}
              autoFocus
              className="comma-onboarding__hurry"
              data-no-press-feedback=""
              onClick={hurry}
              type="button"
            />
          ) : null}
          {staged ? (
            // The conversation and what heads it, cut from the bottom up as
            // the light clears them (onboardingMotion.ts).
            <div className="comma-onboarding__stage" ref={stageRef}>
              <div className="comma-onboarding__stage-content" ref={stageContentRef}>
                {talking || keying || clearing ? (
                  // Stepped back for the shortcut, the conversation is out
                  // of reach and no longer read.
                  <div
                    aria-hidden={receded || undefined}
                    className="comma-onboarding__column"
                    data-receded={receded || undefined}
                    inert={receded || undefined}
                    ref={columnRef}
                    style={
                      {
                        "--onboarding-app-row": `${rowHeight}px`,
                        "--onboarding-list-rows": listRows,
                      } as CSSProperties
                    }
                  >
                    <div className="comma-onboarding-thread" ref={setThreadElement}>
                      <OnboardingConversation
                        card={card}
                        cardItem={cardItem}
                        contentRef={contentRef}
                        messages={thread.messages}
                        onLanded={landed}
                        settled={!talking}
                        speaker={storedName}
                        texts={texts}
                      />
                    </div>
                    {/* The invisible composer every message is sent from, where
                        the chat keeps its own. It holds what is sent next, as
                        the chat's composer holds the draft. */}
                    <div
                      aria-hidden="true"
                      className="comma-onboarding-launchpad"
                      inert
                    >
                      <div
                        className="comma-onboarding-launchpad__composer"
                        ref={launchpadRef}
                      >
                        {/* oxlint-disable jsx-a11y/control-has-associated-label, jsx-a11y/prefer-tag-over-role -- The send motion reads the composer's text box by role, as the chat's rich editor exposes it; this stand-in is inert and hidden from assistive tech. */}
                        <div
                          aria-readonly="true"
                          className="comma-onboarding-launchpad__editor"
                          data-draft={draft}
                          data-from={thread.finishing ? "user" : "comma"}
                          role="textbox"
                          tabIndex={-1}
                        />
                        {/* oxlint-enable jsx-a11y/control-has-associated-label, jsx-a11y/prefer-tag-over-role */}
                      </div>
                    </div>
                  </div>
                ) : null}
                {openShortcut && receded ? (
                  <OnboardingShortcut
                    active={keying}
                    delay={threadRecedeMs}
                    keycaps={keycaps}
                    onPressed={shortcutPressed}
                    onSkip={skipShortcut}
                    reducedMotion={reducedMotion}
                    takeFocus={takeFocus}
                    together={onboardingNameList(
                      keycaps.map(({ name }) => name),
                      messages
                    )}
                  />
                ) : null}
                <OnboardingIntro
                  leaving={skipping}
                  onBegin={begin}
                  onPressStart={sound.click}
                  onStart={focusDialog}
                  playing={introducing}
                  reducedMotion={reducedMotion}
                  takeFocus={takeFocus}
                />
              </div>
            </div>
          ) : null}
          {lighting ? (
            <div
              aria-hidden="true"
              className="comma-onboarding-sweep"
              data-flash={reducedMotion || undefined}
              ref={lightRef}
            />
          ) : null}
          {welcoming ? (
            <OnboardingWelcome
              assistantName={assistantName}
              leaving={phase === "exit"}
              onStart={start}
              reducedMotion={reducedMotion}
            />
          ) : null}
          {/* The onboarding's top-right corner, last in the tab order: the
              sound's volume, then Close. The volume stays until the
              onboarding exits. Close ends the onboarding from where it is;
              on the way to the welcome page it is cut by the light as it
              passes, and the volume takes its place. */}
          <div
            className="comma-onboarding__corner"
            data-alone={!staged || undefined}
            data-exiting={phase === "exit" || undefined}
          >
            <OnboardingSoundControl alone={!staged} sound={sound} />
            <div
              className="comma-onboarding__skip"
              data-leaving={skipping || undefined}
              ref={skipRef}
            >
              {staged ? (
                <Tooltip content={messages.onboarding_close()} placement="bottom">
                  <Button
                    aria-label={messages.onboarding_close()}
                    className="comma-onboarding-corner-button"
                    hierarchy="tertiary-gray"
                    iconLeading={<XIcon />}
                    iconOnly
                    isDisabled={!introducing && !talking && !keying}
                    onPress={close}
                    size="md"
                  />
                </Tooltip>
              ) : null}
            </div>
          </div>
          {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- A sound effect without words: there is nothing to caption. */}
          <audio preload="auto" ref={sound.audioRef} src={sound.src} />
        </Dialog>
        {/* After the dialog: Electron merges drag regions in document order,
            so the strip must follow the full-window layers to stay draggable.
            The desktop presentation's window does not move. */}
        {presentation === "overlay" ? (
          <div aria-hidden="true" className="comma-onboarding__drag-strip" />
        ) : null}
      </Modal>
    </ModalOverlay>
  );
}

/** Comma's words for one of its lines. */
export function onboardingLineText(
  line: OnboardingLine,
  messages: Messages,
  items: number,
  voice: OnboardingVoice = "calm"
) {
  const say = <Key extends VoicedKey>(key: Key) => voiced(messages, voice, key);
  switch (line.kind) {
    case "greeting":
      return say(
        (
          [
            "onboarding_greeting_value",
            "onboarding_greeting_no_group",
            items === 3
              ? "onboarding_greeting_items_three"
              : "onboarding_greeting_items_two",
          ] as const
        )[line.index]!
      )();
    case "question":
      return say(
        (
          {
            apps: "onboarding_question_apps",
            name: "onboarding_question_name",
            permissions: "onboarding_question_permissions",
          } as const
        )[line.item]
      )();
    case "bridge":
      return onboardingBridgeText(line.result, line.index, messages, voice);
    case "side-chat":
      // Each modifier by its symbol, then the key (⌃ + Z).
      return say("onboarding_side_chat")({
        keys: onboardingKeycaps(line.shortcut, {
          comma: messages.onboarding_shortcut_comma(),
          space: messages.onboarding_shortcut_space(),
        })
          .map(({ glyph, name }) => glyph ?? name)
          .join(" + "),
      });
    case "recap":
      return withRouterNameSpacing(
        say("onboarding_recap")({
          missing: onboardingNameList(
            line.missing.map((missing) => onboardingMissingName(missing, messages)),
            messages
          ),
        })
      );
  }
}

/** What Comma keeps up with in an app it knows, for the connected-apps reply. */
function onboardingAppUse(id: string, messages: Messages) {
  switch (id) {
    case "google":
      return messages.onboarding_apps_use_google();
    case "github":
      return messages.onboarding_apps_use_github();
    case "notion":
      return messages.onboarding_apps_use_notion();
    case "slack":
      return messages.onboarding_apps_use_slack();
    case "linear":
      return messages.onboarding_apps_use_linear();
    case "feishu":
      return messages.onboarding_apps_use_feishu();
    default:
      return undefined;
  }
}

/** What the recap calls something the user left off. */
function onboardingMissingName(missing: OnboardingMissing, messages: Messages) {
  switch (missing) {
    case "apps":
      return messages.onboarding_recap_apps();
    case "accessibility":
      return messages.onboarding_permissions_accessibility();
    case "screenRecording":
      return messages.onboarding_permissions_screen_recording();
    case "notifications":
      return messages.onboarding_permissions_notifications();
  }
}

/**
 * Comma's answer to a reply, line by line. Naming it gets a second line: what
 * the Router does for the user from now on.
 */
function onboardingBridgeText(
  result: OnboardingItemResult,
  index: number,
  messages: Messages,
  voice: OnboardingVoice
) {
  const say = <Key extends VoicedKey>(key: Key) => voiced(messages, voice, key);
  const done = onboardingItemDone(result);
  switch (result.item) {
    case "apps": {
      if (!done) return say("onboarding_bridge_apps_skipped")();
      const apps = onboardingNameList(result.connected, messages);
      // What Comma does with the apps it knows: the daily briefing reads them,
      // and Workers use them on tasks.
      const uses = (result.ids ?? []).flatMap((id) => {
        const use = onboardingAppUse(id, messages);
        return use ? [use] : [];
      });
      return withRouterNameSpacing(
        uses.length > 0
          ? say("onboarding_bridge_apps_uses")({
              apps,
              uses: onboardingNameList(uses, messages),
            })
          : say("onboarding_bridge_apps_connected")({ apps })
      );
    }
    case "name":
      if (index > 0) return say("onboarding_bridge_name_router")();
      return withRouterNameSpacing(
        say(done ? "onboarding_bridge_name_named" : "onboarding_bridge_name_skipped")({
          name: result.name,
        })
      );
    case "permissions":
      // Working on this Mac takes both Computer Use grants; fewer are only a start.
      return say(
        result.computerUse
          ? "onboarding_bridge_permissions_allowed"
          : done
            ? "onboarding_bridge_permissions_partial"
            : "onboarding_bridge_permissions_skipped"
      )();
  }
}

/** The user's reply for what an item came to. */
export function onboardingReplyText(result: OnboardingItemResult, messages: Messages) {
  if (!onboardingItemDone(result)) return messages.onboarding_reply_skipped();
  switch (result.item) {
    case "apps":
      return withRouterNameSpacing(
        messages.onboarding_reply_apps({
          apps: onboardingNameList(result.connected, messages),
        })
      );
    case "name":
      return result.name;
    case "permissions":
      return messages.onboarding_reply_permissions({
        count: result.allowed,
        total: result.total,
      });
  }
}

/**
 * Names joined as the reader's language joins them: "GitHub and Notion",
 * "GitHub, Notion and Slack"; "GitHub 和 Notion", "GitHub、Notion 和 Slack".
 */
export function onboardingNameList(names: readonly string[], messages: Messages) {
  const last = names.at(-1) ?? "";
  if (names.length < 2) return last;
  return withRouterNameSpacing(
    messages.onboarding_list_pair({
      first: names.slice(0, -1).join(messages.onboarding_list_separator()),
      second: last,
    })
  );
}

/** The content height of `element`, kept current while it is mounted. */
function useContentHeight(element: HTMLElement | null) {
  const [height, setHeight] = useState<number>();
  useLayoutEffect(() => {
    if (!element || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(([entry]) => {
      const next = entry?.contentRect.height;
      if (next !== undefined)
        setHeight((current) => (current === next ? current : next));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);
  return height;
}

/**
 * Whether the user is moving through the onboarding with the keyboard: focus
 * rings show only then. Tab turns it on, a pointer turns it off, and so does
 * the onboarding when it moves the focus itself (a card or the welcome page
 * arriving). Any other key leaves it as it is: after Return in the name
 * field, the next card's primary takes the focus without a ring.
 */
function useKeyboardNavigation() {
  const [navigating, setNavigating] = useState(false);
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Tab") setNavigating(true);
    };
    const pointer = () => setNavigating(false);
    window.addEventListener("keydown", keydown, true);
    window.addEventListener("pointerdown", pointer, true);
    return () => {
      window.removeEventListener("keydown", keydown, true);
      window.removeEventListener("pointerdown", pointer, true);
    };
  }, []);
  const stop = useCallback(() => setNavigating(false), []);
  return [navigating, stop] as const;
}

/** Where a key types text, so M is a letter there rather than the mute key. */
function isTextEntry(target: EventTarget | null) {
  return (
    target instanceof HTMLElement &&
    (target.isContentEditable ||
      target instanceof HTMLTextAreaElement ||
      (target instanceof HTMLInputElement && target.type !== "range"))
  );
}
