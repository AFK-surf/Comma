import type { SideChatShortcut } from "@comma/native-bridge";
import type { OutgoingBubbleFrame } from "../chat/motion/outgoingBubbleMotion";

/**
 * `overlay`: inside the product window (web). The experience covers the app
 * shell and blurs it.
 * `window`: the Electron full-screen onboarding window. The page is
 * transparent over the desktop; the experience paints its own light.
 */
export type OnboardingPresentation = "overlay" | "window";

/**
 * The setup items, in order. "Let me work on this Mac" exists only where
 * macOS reports the grants it offers (the macOS app); elsewhere the setup has
 * the first two.
 */
export const onboardingItemIds = ["apps", "name", "permissions"] as const;

export type OnboardingItemId = (typeof onboardingItemIds)[number];

/** The macOS grants the onboarding offers, in the order they are shown. */
export const permissionIds = [
  "accessibility",
  "screenRecording",
  "notifications",
] as const;
export type PermissionId = (typeof permissionIds)[number];

export function onboardingItemsFor({
  permissions,
}: {
  permissions: boolean;
}): readonly OnboardingItemId[] {
  return permissions ? onboardingItemIds : onboardingItemIds.slice(0, 2);
}

/**
 * What an item came to. The user's reply says it, and Comma's answer
 * acknowledges it.
 * - `apps`: the apps connected when the user moved on, by name and by plugin
 *   id; none is a skip. `offered` is false when the catalog had no app to
 *   connect, so nothing was left off.
 * - `name`: the name the assistant goes by from here on, and whether the user
 *   gave it one now.
 * - `permissions`: the grants allowed when the user moved on, the ones still
 *   missing, and whether they include both Computer Use grants, which Comma
 *   needs to work on the Mac; none allowed is a skip.
 */
export type OnboardingItemResult =
  | {
      item: "apps";
      connected: readonly string[];
      ids?: readonly string[];
      offered?: boolean;
    }
  | { item: "name"; name: string; named: boolean }
  | {
      item: "permissions";
      allowed: number;
      total: number;
      computerUse: boolean;
      missing: readonly PermissionId[];
    };

/** What each item answered so far came to. */
export type OnboardingResults = {
  [Item in OnboardingItemId]?: Extract<OnboardingItemResult, { item: Item }>;
};

/** Whether the user did the item, rather than skipping it. */
export function onboardingItemDone(result: OnboardingItemResult) {
  switch (result.item) {
    case "apps":
      return result.connected.length > 0;
    case "name":
      return result.named;
    case "permissions":
      return result.allowed > 0;
  }
}

/**
 * Comma's greeting, once the intro has welcomed the user: what it does, no
 * group chats, what comes next.
 */
export const greetingLineCount = 3;

/**
 * How many lines Comma answers a reply with. The name gets two: an
 * acknowledgement, then what the Router does for the user from now on.
 */
export function onboardingBridgeLineCount(result: OnboardingItemResult) {
  return result.item === "name" ? 2 : 1;
}

/** One of Comma's lines in the thread. */
export type OnboardingLine =
  | { kind: "greeting"; index: number }
  /** Asks for an item; the item's card comes under it once it has landed. */
  | { kind: "question"; item: OnboardingItemId }
  /** Answers the user's reply, line by line, before the next question. */
  | { kind: "bridge"; result: OnboardingItemResult; index: number }
  /**
   * Once every item is answered, where the Side Chat can be brought out (the
   * macOS app, with its shortcut set): what it is and the shortcut for it.
   */
  | { kind: "side-chat"; shortcut: SideChatShortcut }
  /**
   * Once every item is answered: what the user left off (apps not connected,
   * grants not allowed), so they know what to turn on later.
   */
  | { kind: "recap"; missing: readonly OnboardingMissing[] };

/** Something the setup offered that the user left off. */
export type OnboardingMissing = "apps" | PermissionId;

/** What the answered items left off, in the order they were offered. */
export function onboardingMissing(results: OnboardingResults): OnboardingMissing[] {
  return [
    ...(results.apps &&
    results.apps.connected.length === 0 &&
    results.apps.offered !== false
      ? ["apps" as const]
      : []),
    ...(results.permissions?.missing ?? []),
  ];
}

type Sent = {
  /** Its place in the thread; messages are only ever added. */
  id: number;
  /** When it was sent and when it landed, on the `performance.now()` clock. */
  sentAt: number;
  landedAt: number | undefined;
  /**
   * The invisible composer as the message left it, which its send motion
   * flies from. None: the message was simply there (a thread that starts
   * further on, or Comma hurried along).
   */
  source: OutgoingBubbleFrame | undefined;
};

export type OnboardingMessage =
  | (Sent & {
      from: "comma";
      line: OnboardingLine;
      /**
       * The assistant's name when it said this: the label over its group.
       * None: said before the stored name was read, so it goes by that name
       * once it is known (fixed when the naming is answered).
       */
      speaker: string | undefined;
    })
  | (Sent & { from: "user"; result: OnboardingItemResult });

/**
 * `intro`: the screen dims and the Comma mark welcomes the user, until they
 * press Start (or it starts by itself).
 * `conversation`: Comma's greeting, then one exchange per item.
 * `shortcut`: the last step, where the Open Comma shortcut is taught (the
 * macOS app with that shortcut set): the conversation steps back, and the
 * user presses the shortcut's keys.
 * `welcome`: the closing page.
 * `exit`: the page leaves and the light lifts.
 */
export type OnboardingPhase =
  | "intro"
  | "conversation"
  | "shortcut"
  | "welcome"
  | "exit";

/**
 * Where a flow starts. The product starts at the intro; stories and tests may
 * start at the greeting, with an item's card up, just after an item was
 * answered (`after-*`: the user's reply and Comma's answer in the thread), at
 * the Open Comma shortcut once every item is answered, or at the welcome page.
 */
export type OnboardingStart =
  | "intro"
  | "greeting"
  | OnboardingItemId
  | `after-${OnboardingItemId}`
  | "shortcut"
  | "welcome";

/**
 * The Open Comma shortcut step: when the user had pressed every key of the
 * shortcut, on the `performance.now()` clock.
 */
export type OnboardingShortcutStep = { pressedAt: number | undefined };

export type OnboardingThread = {
  items: readonly OnboardingItemId[];
  phase: OnboardingPhase;
  /** When the conversation started, on the `performance.now()` clock. */
  startedAt: number;
  messages: readonly OnboardingMessage[];
  /** The item whose card is up, under its question. */
  card: OnboardingItemId | undefined;
  /** The card is leaving with what its item came to; the user's reply follows. */
  finishing: { result: OnboardingItemResult; at: number } | undefined;
  results: OnboardingResults;
  /**
   * The Open Comma shortcut step, where it is offered; none elsewhere (the
   * web, no Open Comma shortcut set), and the welcome page follows the
   * conversation.
   */
  shortcut: OnboardingShortcutStep | undefined;
  /**
   * The Side Chat shortcut, where Comma tells of the Side Chat once every
   * item is answered; none elsewhere (the web, no Side Chat shortcut set).
   */
  sideChat: SideChatShortcut | undefined;
};

export type OnboardingThreadAction =
  /** Comma sends a line: with its send motion from `source`, or at once. */
  | {
      type: "say";
      line: OnboardingLine;
      speaker: string | undefined;
      at: number;
      source?: OutgoingBubbleFrame | undefined;
    }
  /** The intro is over: the conversation starts. */
  | { type: "begin"; at: number }
  /** A message's send motion has landed. */
  | { type: "landed"; id: number; at: number }
  | { type: "show-card"; item: OnboardingItemId }
  /**
   * The user finished the item on show: its card leaves. Answering the name
   * gives every line said before the stored name was read the name the
   * assistant had until then (`speaker`).
   */
  | {
      type: "finish";
      result: OnboardingItemResult;
      at: number;
      speaker?: string | undefined;
    }
  /** The user's reply is sent in the card's place. */
  | { type: "reply"; at: number; source?: OutgoingBubbleFrame | undefined }
  /**
   * Comma says, at once, every line it has left before the next card (or
   * before the welcome page), and what is in flight lands.
   */
  | { type: "hurry"; speaker: string | undefined; at: number }
  /**
   * The welcome page: after the last exchange, or from Skip setup at any
   * point, the intro included. What is still to do is skipped; what was done
   * stays.
   */
  | { type: "welcome"; at: number }
  /**
   * Whether the Open Comma shortcut step is offered, as the shortcut is set
   * or not; it can change until the conversation is over.
   */
  | { type: "offer-shortcut"; offered: boolean }
  /** The Side Chat shortcut Comma tells of, as it is set; it can change until then. */
  | { type: "offer-side-chat"; shortcut: SideChatShortcut | undefined }
  /** The conversation is over: the Open Comma shortcut step starts. */
  | { type: "shortcut"; at: number }
  /** The user has pressed every key of the shortcut. */
  | { type: "shortcut-pressed"; at: number }
  | { type: "exit" };

/** The first item not answered yet. */
export function nextOnboardingItem(thread: OnboardingThread) {
  return thread.items.find((item) => thread.results[item] === undefined);
}

/**
 * The line Comma says next, whenever it says it: the greeting's next line,
 * the answer to a reply, or after those the next item's question. None
 * while a question waits for its card, or once there is nothing left to ask.
 */
export function pendingOnboardingLine(
  thread: OnboardingThread
): OnboardingLine | undefined {
  const last = thread.messages.at(-1);
  if (!last) return { kind: "greeting", index: 0 };
  if (last.from === "user") return { kind: "bridge", result: last.result, index: 0 };
  const { line } = last;
  if (line.kind === "question") return undefined;
  if (line.kind === "greeting" && line.index < greetingLineCount - 1) {
    return { kind: "greeting", index: line.index + 1 };
  }
  if (
    line.kind === "bridge" &&
    line.index < onboardingBridgeLineCount(line.result) - 1
  ) {
    return { kind: "bridge", result: line.result, index: line.index + 1 };
  }
  const item = nextOnboardingItem(thread);
  if (item) return { kind: "question", item };
  if (line.kind === "recap") return undefined;
  // The last item answered: the Side Chat first, then what is still off.
  if (thread.sideChat && line.kind !== "side-chat") {
    return { kind: "side-chat", shortcut: thread.sideChat };
  }
  const missing = onboardingMissing(thread.results);
  return missing.length > 0 ? { kind: "recap", missing } : undefined;
}

export type OnboardingTiming = {
  /** From the start to the first line. */
  firstLine: number;
  /** From one of Comma's lines being sent to the next one. */
  stagger: number;
  /** From the user's reply landing to Comma's answer. */
  replyBeat: number;
  /** From Comma's last answer landing to the welcome page. */
  welcomeBeat: number;
  /**
   * From Comma's last line landing to the Open Comma shortcut step, where it
   * is offered: long enough to read that line.
   */
  shortcutBeat: number;
  /** How long a card takes to leave before the reply is sent. */
  cardLeave: number;
  /**
   * From the shortcut's keys all pressed (green, the step's words the
   * success) to the welcome page.
   */
  shortcutDone: number;
};

/** What the onboarding does next, on its own. */
export type OnboardingStep =
  | { type: "say"; line: OnboardingLine }
  | { type: "show-card"; item: OnboardingItemId }
  | { type: "reply" }
  | { type: "shortcut" }
  | { type: "welcome" };

/**
 * The onboarding's next step and when it is due, on the `performance.now()`
 * clock; none while it waits for the user (a card is up, the Side Chat
 * shortcut not pressed yet) or for a message to land.
 */
export function nextOnboardingStep(
  thread: OnboardingThread,
  timing: OnboardingTiming
): { at: number; step: OnboardingStep } | undefined {
  if (thread.phase === "shortcut") return nextShortcutStep(thread, timing);
  if (thread.phase !== "conversation") return undefined;
  if (thread.finishing) {
    return { at: thread.finishing.at + timing.cardLeave, step: { type: "reply" } };
  }
  if (thread.card) return undefined;
  const last = thread.messages.at(-1);
  const line = pendingOnboardingLine(thread);
  if (!last) {
    return (
      line && { at: thread.startedAt + timing.firstLine, step: { type: "say", line } }
    );
  }
  if (last.from === "user") {
    return last.landedAt === undefined || !line
      ? undefined
      : { at: last.landedAt + timing.replyBeat, step: { type: "say", line } };
  }
  if (last.line.kind === "question") {
    return last.landedAt === undefined
      ? undefined
      : { at: last.landedAt, step: { type: "show-card", item: last.line.item } };
  }
  if (line) return { at: last.sentAt + timing.stagger, step: { type: "say", line } };
  if (last.landedAt === undefined) return undefined;
  return thread.shortcut
    ? { at: last.landedAt + timing.shortcutBeat, step: { type: "shortcut" } }
    : { at: last.landedAt + timing.welcomeBeat, step: { type: "welcome" } };
}

/**
 * The Open Comma shortcut step waits for the user to press its keys; a beat
 * after they have, the welcome page follows.
 */
function nextShortcutStep(
  { shortcut }: OnboardingThread,
  timing: OnboardingTiming
): { at: number; step: OnboardingStep } | undefined {
  if (shortcut?.pressedAt === undefined) return undefined;
  return { at: shortcut.pressedAt + timing.shortcutDone, step: { type: "welcome" } };
}

/** The result of an item the user moved past without doing it. */
export function skippedOnboardingResult(
  item: OnboardingItemId,
  name: string
): OnboardingItemResult {
  switch (item) {
    case "apps":
      return { item, connected: [] };
    case "name":
      return { item, name, named: false };
    case "permissions":
      return {
        item,
        allowed: 0,
        total: permissionIds.length,
        computerUse: false,
        missing: permissionIds,
      };
  }
}

function send(
  thread: OnboardingThread,
  message:
    | { from: "comma"; line: OnboardingLine; speaker: string | undefined }
    | { from: "user"; result: OnboardingItemResult },
  at: number,
  source: OutgoingBubbleFrame | undefined
): OnboardingThread {
  const sent = {
    id: thread.messages.length,
    landedAt: source ? undefined : at,
    sentAt: at,
    source,
  };
  return { ...thread, messages: [...thread.messages, { ...message, ...sent }] };
}

const withResult = (results: OnboardingResults, result: OnboardingItemResult) =>
  ({ ...results, [result.item]: result }) as OnboardingResults;

const landAll = (messages: readonly OnboardingMessage[], at: number) =>
  messages.every((message) => message.landedAt !== undefined)
    ? messages
    : messages.map((message) =>
        message.landedAt === undefined ? { ...message, landedAt: at } : message
      );

/**
 * The first state of a flow. The product starts at the intro. A flow that
 * starts further on finds the thread as it would stand there, each item
 * passed answered as `results` says (skipped when it does not).
 */
export function initialOnboardingThread({
  at,
  items,
  results = {},
  shortcut = false,
  sideChat,
  speaker,
  start = "intro",
}: {
  at: number;
  items: readonly OnboardingItemId[];
  results?: OnboardingResults | undefined;
  /** Whether the Open Comma shortcut step is offered. */
  shortcut?: boolean | undefined;
  /** The Side Chat shortcut Comma tells of, where it does. */
  sideChat?: SideChatShortcut | undefined;
  /** The assistant's name as the flow starts. */
  speaker: string;
  start?: OnboardingStart | undefined;
}): OnboardingThread {
  let thread: OnboardingThread = {
    card: undefined,
    finishing: undefined,
    items,
    messages: [],
    phase: "conversation",
    results: {},
    shortcut: shortcut ? unstartedShortcut : undefined,
    sideChat,
    startedAt: at,
  };
  if (start === "intro") return { ...thread, phase: "intro" };
  if (start === "greeting") return thread;
  if (start === "welcome") {
    return {
      ...thread,
      phase: "welcome",
      results: items.reduce<OnboardingResults>((kept, item) => {
        const result = results[item];
        return result ? withResult(kept, result) : kept;
      }, {}),
    };
  }
  if (start === "shortcut") {
    // Every item answered, the Side Chat and the recap said: the
    // conversation has stepped back.
    let said = initialOnboardingThread({
      at,
      items,
      results,
      sideChat,
      speaker,
      start: `after-${items.at(-1) ?? "apps"}`,
    });
    for (
      let line = pendingOnboardingLine(said);
      line;
      line = pendingOnboardingLine(said)
    ) {
      said = send(said, { from: "comma", line, speaker }, at, undefined);
    }
    return { ...said, phase: "shortcut", shortcut: unstartedShortcut };
  }
  const answered = start.startsWith("after-");
  const target = (answered ? start.slice("after-".length) : start) as OnboardingItemId;
  const stop = Math.max(0, items.indexOf(target)) + (answered ? 1 : 0);
  let name = speaker;
  const say = (line: OnboardingLine) => {
    thread = send(thread, { from: "comma", line, speaker: name }, at, undefined);
  };
  for (let index = 0; index < greetingLineCount; index += 1) {
    say({ kind: "greeting", index });
  }
  for (const item of items.slice(0, stop)) {
    const result = results[item] ?? skippedOnboardingResult(item, name);
    say({ kind: "question", item });
    thread = send(thread, { from: "user", result }, at, undefined);
    thread = { ...thread, results: withResult(thread.results, result) };
    if (result.item === "name") name = result.name;
    for (let index = 0; index < onboardingBridgeLineCount(result); index += 1) {
      say({ kind: "bridge", result, index });
    }
  }
  const item = items[stop];
  if (answered || !item) return thread;
  say({ kind: "question", item });
  return { ...thread, card: item };
}

const unstartedShortcut: OnboardingShortcutStep = { pressedAt: undefined };

export function onboardingThreadReducer(
  thread: OnboardingThread,
  action: OnboardingThreadAction
): OnboardingThread {
  if (thread.phase === "exit") return thread;
  if (action.type === "exit") return { ...thread, phase: "exit" };
  if (action.type === "begin") {
    return thread.phase === "intro"
      ? { ...thread, phase: "conversation", startedAt: action.at }
      : thread;
  }
  if (action.type === "welcome") {
    return thread.phase === "intro" ||
      thread.phase === "conversation" ||
      thread.phase === "shortcut"
      ? { ...thread, messages: landAll(thread.messages, action.at), phase: "welcome" }
      : thread;
  }
  if (action.type === "offer-side-chat") {
    if (thread.phase !== "intro" && thread.phase !== "conversation") return thread;
    return action.shortcut === thread.sideChat
      ? thread
      : { ...thread, sideChat: action.shortcut };
  }
  if (action.type === "offer-shortcut") {
    if (thread.phase !== "intro" && thread.phase !== "conversation") return thread;
    if (action.offered === (thread.shortcut !== undefined)) return thread;
    return { ...thread, shortcut: action.offered ? unstartedShortcut : undefined };
  }
  if (thread.phase === "shortcut") {
    // Its keys count once.
    return action.type === "shortcut-pressed" &&
      thread.shortcut &&
      thread.shortcut.pressedAt === undefined
      ? { ...thread, shortcut: { pressedAt: action.at } }
      : thread;
  }
  if (action.type === "landed") {
    const message = thread.messages[action.id];
    if (!message || message.landedAt !== undefined) return thread;
    const messages = thread.messages.slice();
    messages[action.id] = { ...message, landedAt: action.at };
    return { ...thread, messages };
  }
  if (thread.phase !== "conversation") return thread;
  switch (action.type) {
    case "say":
      return thread.card || thread.finishing
        ? thread
        : send(
            thread,
            { from: "comma", line: action.line, speaker: action.speaker },
            action.at,
            action.source
          );
    case "show-card":
      return thread.card ? thread : { ...thread, card: action.item };
    case "finish": {
      if (thread.card !== action.result.item || thread.finishing) return thread;
      const { speaker } = action;
      return {
        ...thread,
        finishing: { result: action.result, at: action.at },
        messages:
          speaker === undefined
            ? thread.messages
            : thread.messages.map((message) =>
                message.from === "comma" && message.speaker === undefined
                  ? { ...message, speaker }
                  : message
              ),
      };
    }
    case "reply": {
      const finishing = thread.finishing;
      if (!finishing) return thread;
      const replied = send(
        { ...thread, card: undefined, finishing: undefined },
        { from: "user", result: finishing.result },
        action.at,
        action.source
      );
      return { ...replied, results: withResult(thread.results, finishing.result) };
    }
    case "shortcut":
      return thread.shortcut && !thread.card && !thread.finishing
        ? {
            ...thread,
            messages: landAll(thread.messages, action.at),
            phase: "shortcut",
          }
        : thread;
    case "hurry": {
      if (thread.card || thread.finishing) return thread;
      let next: OnboardingThread = {
        ...thread,
        messages: landAll(thread.messages, action.at),
      };
      for (let line = pendingOnboardingLine(next); line; ) {
        next = send(
          next,
          { from: "comma", line, speaker: action.speaker },
          action.at,
          undefined
        );
        line = line.kind === "question" ? undefined : pendingOnboardingLine(next);
      }
      return next;
    }
    default:
      return thread;
  }
}

/**
 * Below this the list of apps would not read as a list; a window too short
 * for it (a large zoom on a small display) still gets a row and a half that
 * fit, never a card taller than the room.
 */
const minAppRows = 3.5;
const leastAppRows = 1.5;
/**
 * Above this the card would tower over the thread on a tall (portrait)
 * display; the rest of a long list scrolls.
 */
const maxAppRows = 8.5;

/**
 * How many rows of apps the card shows before its list scrolls: every row
 * when they fit in `room` and stay under eight and a half, otherwise as many
 * as fit up to eight and a half, cut at a half row (the half row says the
 * list scrolls) and never under three and a half where three and a half fit.
 */
export function fitOnboardingAppRows({
  room,
  rowCount,
  rowHeight,
}: {
  room: number;
  rowCount: number;
  rowHeight: number;
}) {
  if (rowCount <= maxAppRows && rowCount * rowHeight <= room) return rowCount;
  const rows = Math.min(maxAppRows, Math.floor(room / rowHeight - 0.5) + 0.5);
  const floor = room >= minAppRows * rowHeight ? minAppRows : leastAppRows;
  return Math.min(rowCount, Math.max(floor, rows));
}

/**
 * How deep the light behind the thread is, from 0 at the intro and the
 * greeting to 1 on the welcome page: each finished item takes it one step
 * deeper, and the welcome page (and the Open Comma shortcut before it) is one
 * step past the last item.
 *
 * A step is taken once Comma's answer to the item's reply has landed, in the
 * quiet beat before its next line: the light never changes under a bubble in
 * flight.
 */
export function onboardingLightDepth(thread: OnboardingThread) {
  if (thread.phase !== "intro" && thread.phase !== "conversation") return 1;
  const finished = thread.messages.filter(
    (message, index) =>
      message.from === "user" && thread.messages[index + 1]?.landedAt !== undefined
  ).length;
  return finished / (thread.items.length + 1);
}

/**
 * Whether Comma's greeting is over, its last line landed: the light calms
 * behind the thread then, in the beat before the first question is sent.
 */
export function onboardingGreetingLanded(thread: OnboardingThread) {
  return thread.messages.some(
    (message) =>
      message.landedAt !== undefined &&
      (message.from === "user" ||
        message.line.kind !== "greeting" ||
        message.line.index === greetingLineCount - 1)
  );
}

/** Whether a message is still flying in from the composer. */
export function onboardingMessageInFlight(thread: OnboardingThread) {
  return (
    thread.phase === "conversation" &&
    thread.messages.some((message) => message.landedAt === undefined)
  );
}
