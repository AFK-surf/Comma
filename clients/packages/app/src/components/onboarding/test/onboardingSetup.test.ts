import { defaultSideChatShortcut } from "@comma/native-bridge";
import { describe, expect, it } from "vitest";
import {
  fitOnboardingAppRows,
  onboardingMissing,
  initialOnboardingThread,
  nextOnboardingStep,
  onboardingGreetingLanded,
  onboardingItemsFor,
  onboardingLightDepth,
  onboardingMessageInFlight,
  onboardingThreadReducer,
  type OnboardingStart,
  type OnboardingThread,
  type OnboardingThreadAction,
} from "../onboardingSetup";

const timing = {
  cardLeave: 200,
  firstLine: 400,
  replyBeat: 1000,
  shortcutDone: 800,
  stagger: 2500,
  welcomeBeat: 1200,
  shortcutBeat: 3500,
};
const source = { bottom: 0, height: 36, left: 0, right: 480, top: 0, width: 480 };

const mac = onboardingItemsFor({ permissions: true });
const run = (thread: OnboardingThread, ...actions: OnboardingThreadAction[]) =>
  actions.reduce(onboardingThreadReducer, thread);
/** Where the thread stands: who said what, in order. */
const said = (thread: OnboardingThread) =>
  thread.messages.map((message) =>
    message.from === "user"
      ? `user:${message.result.item}`
      : `${message.speaker}:${message.line.kind}${
          message.line.kind === "greeting"
            ? message.line.index
            : message.line.kind === "question"
              ? `:${message.line.item}`
              : message.line.kind === "recap"
                ? `:${message.line.missing.join(",")}`
                : message.line.kind === "side-chat"
                  ? ""
                  : `:${message.line.result.item}${message.line.index}`
        }`
  );
/** Runs the conversation's own steps until it waits for the user. */
function play(thread: OnboardingThread, speaker = "Comma") {
  let current = thread;
  for (let step = nextOnboardingStep(current, timing); step; ) {
    const at = step.at;
    const action: OnboardingThreadAction =
      step.step.type === "say"
        ? { type: "say", at, line: step.step.line, source, speaker }
        : step.step.type === "reply"
          ? { type: "reply", at, source }
          : step.step.type === "show-card"
            ? { type: "show-card", item: step.step.item }
            : step.step.type === "shortcut"
              ? { type: "shortcut", at }
              : { type: "welcome", at };
    current = onboardingThreadReducer(current, action);
    // Each send motion lands a moment after it leaves.
    const last = current.messages.at(-1);
    if (last && last.landedAt === undefined) {
      current = onboardingThreadReducer(current, {
        type: "landed",
        id: last.id,
        at: at + 900,
      });
    }
    step = nextOnboardingStep(current, timing);
  }
  return current;
}

describe("onboarding thread", () => {
  it("greets once the intro is over, asks for each item in turn, answers each reply, and closes on the welcome page", () => {
    const intro = initialOnboardingThread({ at: 0, items: mac, speaker: "Comma" });
    // Nothing is said while the intro plays.
    expect(intro.phase).toBe("intro");
    expect(nextOnboardingStep(intro, timing)).toBeUndefined();

    const greeting = run(intro, { type: "begin", at: 6000 });
    // The greeting's first line comes a beat after the intro; each next line
    // one stagger on.
    expect(nextOnboardingStep(greeting, timing)).toEqual({
      at: 6400,
      step: { type: "say", line: { kind: "greeting", index: 0 } },
    });

    const asked = play(greeting);
    expect(asked.card).toBe("apps");
    expect(said(asked)).toEqual([
      "Comma:greeting0",
      "Comma:greeting1",
      "Comma:greeting2",
      "Comma:question:apps",
    ]);
    // The lines are sent a stagger apart; the card waits for its question to land.
    expect(asked.messages.map((message) => message.sentAt)).toEqual([
      6400, 8900, 11_400, 13_900,
    ]);
    expect(nextOnboardingStep(asked, timing)).toBeUndefined();

    const connected = play(
      run(asked, {
        type: "finish",
        at: 20_000,
        result: { item: "apps", connected: ["GitHub"] },
      })
    );
    expect(said(connected).slice(4)).toEqual([
      "user:apps",
      "Comma:bridge:apps0",
      "Comma:question:name",
    ]);
    // The reply follows the card's leave; Comma answers a beat after it lands.
    expect(connected.messages[4]!.sentAt).toBe(20_200);
    expect(connected.messages[5]!.sentAt).toBe(20_200 + 900 + 1000);
    expect(connected.results.apps).toEqual({ item: "apps", connected: ["GitHub"] });
    expect(connected.card).toBe("name");

    const named = play(
      run(connected, {
        type: "finish",
        at: 40_000,
        result: { item: "name", name: "Atlas", named: true },
      }),
      "Atlas"
    );
    // The name gets two lines, a stagger apart: the acknowledgement, then
    // what the Router does from now on; the next question a stagger later.
    expect(said(named).slice(7)).toEqual([
      "user:name",
      "Atlas:bridge:name0",
      "Atlas:bridge:name1",
      "Atlas:question:permissions",
    ]);
    const answered = named.messages.slice(8).map((message) => message.sentAt);
    expect(answered).toEqual([
      40_200 + 900 + 1000,
      40_200 + 900 + 1000 + 2500,
      40_200 + 900 + 1000 + 5000,
    ]);

    const done = play(
      run(named, {
        type: "finish",
        at: 60_000,
        result: {
          item: "permissions",
          allowed: 0,
          total: 3,
          computerUse: false,
          missing: ["accessibility", "screenRecording", "notifications"],
        },
      }),
      "Atlas"
    );
    // Before the welcome page, Comma reminds the user what is still off.
    expect(done.phase).toBe("welcome");
    expect(said(done).slice(11)).toEqual([
      "user:permissions",
      "Atlas:bridge:permissions0",
      "Atlas:recap:accessibility,screenRecording,notifications",
    ]);
  });

  it("puts the Open Comma shortcut between the last answer and the welcome page where it is offered", () => {
    const permissionsSkipped = {
      type: "finish",
      at: 1000,
      result: {
        item: "permissions",
        allowed: 0,
        total: 3,
        computerUse: false,
        missing: ["accessibility", "screenRecording", "notifications"],
      },
    } as const;
    const atPermissions = (shortcut: boolean) =>
      initialOnboardingThread({
        at: 0,
        items: mac,
        shortcut,
        speaker: "Atlas",
        start: "permissions",
      });

    // Not offered (the web, no shortcut): the welcome page follows the recap.
    expect(play(run(atPermissions(false), permissionsSkipped), "Atlas").phase).toBe(
      "welcome"
    );

    // Offered: once the recap has landed, the step waits for the user.
    const waiting = play(run(atPermissions(true), permissionsSkipped), "Atlas");
    expect(waiting.phase).toBe("shortcut");
    expect(said(waiting).at(-1)).toBe(
      "Atlas:recap:apps,accessibility,screenRecording,notifications"
    );
    // The step came 3.5 s after the recap landed, time to read it.
    expect(nextOnboardingStep({ ...waiting, phase: "conversation" }, timing)).toEqual({
      at: waiting.messages.at(-1)!.landedAt! + 3500,
      step: { type: "shortcut" },
    });
    expect(nextOnboardingStep(waiting, timing)).toBeUndefined();
    // Comma has nothing left to say there.
    expect(run(waiting, { type: "hurry", at: 1, speaker: "Atlas" })).toBe(waiting);

    // Every key pressed: the welcome page follows a beat later, and the keys
    // count once.
    const pressed = run(waiting, { type: "shortcut-pressed", at: 50_000 });
    expect(nextOnboardingStep(pressed, timing)).toEqual({
      at: 50_800,
      step: { type: "welcome" },
    });
    expect(run(pressed, { type: "shortcut-pressed", at: 51_000 })).toBe(pressed);
    expect(play(pressed).phase).toBe("welcome");

    // Skip setup leaves the step for the welcome page.
    expect(run(waiting, { type: "welcome", at: 70_000 }).phase).toBe("welcome");
  });

  it("tells of the Side Chat after the last answer, before what is still off", () => {
    const thread = initialOnboardingThread({
      at: 0,
      items: mac,
      speaker: "Atlas",
      start: "permissions",
    });
    const skipped = {
      type: "finish",
      at: 1000,
      result: {
        item: "permissions",
        allowed: 0,
        total: 3,
        computerUse: false,
        missing: ["accessibility", "screenRecording", "notifications"],
      },
    } as const;
    // Where the Side Chat has no shortcut, Comma does not tell of it.
    expect(said(play(run(thread, skipped), "Atlas")).at(-2)).toBe(
      "Atlas:bridge:permissions0"
    );
    // Its shortcut set while Comma still talks: told after the grants' answer.
    const told = play(
      run(
        thread,
        { type: "offer-side-chat", shortcut: defaultSideChatShortcut },
        skipped
      ),
      "Atlas"
    );
    expect(said(told).slice(-3)).toEqual([
      "Atlas:bridge:permissions0",
      "Atlas:side-chat",
      "Atlas:recap:apps,accessibility,screenRecording,notifications",
    ]);
    expect(told.messages.at(-2)).toMatchObject({
      line: { kind: "side-chat", shortcut: defaultSideChatShortcut },
    });
  });

  it("offers the Open Comma shortcut only until the conversation is over", () => {
    const thread = initialOnboardingThread({
      at: 0,
      items: mac,
      speaker: "Comma",
      start: "greeting",
    });
    expect(thread.shortcut).toBeUndefined();
    const offered = run(thread, { type: "offer-shortcut", offered: true });
    expect(offered.shortcut).toBeDefined();
    expect(run(offered, { type: "offer-shortcut", offered: false }).shortcut).toBe(
      undefined
    );
    // Once on the welcome page it is too late to change.
    const welcome = run(offered, { type: "welcome", at: 1 });
    expect(run(welcome, { type: "offer-shortcut", offered: false })).toBe(welcome);
    // Not offered, the step never starts.
    expect(run(thread, { type: "shortcut", at: 1 }).phase).toBe("conversation");
  });

  it("goes to the welcome page from anywhere, and lands what is in flight", () => {
    // From the intro, before anything was said.
    const skipped = run(
      initialOnboardingThread({ at: 0, items: mac, speaker: "Comma" }),
      {
        type: "welcome",
        at: 100,
      }
    );
    expect(skipped.phase).toBe("welcome");
    expect(run(skipped, { type: "begin", at: 200 }).phase).toBe("welcome");

    const greeting = initialOnboardingThread({
      at: 0,
      items: mac,
      speaker: "Comma",
      start: "greeting",
    });
    const talking = run(greeting, {
      type: "say",
      at: 400,
      line: { kind: "greeting", index: 0 },
      source,
      speaker: "Comma",
    });
    expect(talking.messages[0]!.landedAt).toBeUndefined();

    const welcome = run(talking, { type: "welcome", at: 500 });

    expect(welcome.phase).toBe("welcome");
    expect(welcome.messages[0]!.landedAt).toBe(500);
    expect(nextOnboardingStep(welcome, timing)).toBeUndefined();
    // Nothing more is said.
    expect(
      run(welcome, {
        type: "say",
        at: 600,
        line: { kind: "greeting", index: 1 },
        speaker: "Comma",
      }).messages
    ).toHaveLength(1);
  });

  it("hurries through what Comma has left to say, up to the next card", () => {
    const greeting = initialOnboardingThread({
      at: 0,
      items: mac,
      speaker: "Comma",
      start: "greeting",
    });

    const hurried = run(greeting, { type: "hurry", at: 100, speaker: "Comma" });

    expect(said(hurried)).toEqual([
      "Comma:greeting0",
      "Comma:greeting1",
      "Comma:greeting2",
      "Comma:question:apps",
    ]);
    expect(hurried.messages.every((message) => message.landedAt === 100)).toBe(true);
    expect(nextOnboardingStep(hurried, timing)).toEqual({
      at: 100,
      step: { type: "show-card", item: "apps" },
    });
  });

  it("starts a story or test further on, with the items passed answered", () => {
    const thread = initialOnboardingThread({
      at: 0,
      items: mac,
      results: { name: { item: "name", name: "Atlas", named: true } },
      speaker: "Comma",
      start: "permissions",
    });

    expect(thread.card).toBe("permissions");
    expect(said(thread).slice(3)).toEqual([
      "Comma:question:apps",
      "user:apps",
      "Comma:bridge:apps0",
      "Comma:question:name",
      "user:name",
      "Atlas:bridge:name0",
      "Atlas:bridge:name1",
      "Atlas:question:permissions",
    ]);
    // An item passed without a result was skipped.
    expect(thread.results.apps).toEqual({ item: "apps", connected: [] });

    // At the Side Chat shortcut, every item is answered and the recap said.
    const shortcut = initialOnboardingThread({
      at: 0,
      items: mac,
      speaker: "Comma",
      start: "shortcut",
    });
    expect(shortcut.phase).toBe("shortcut");
    expect(said(shortcut).at(-1)).toBe(
      "Comma:recap:apps,accessibility,screenRecording,notifications"
    );
  });
});

describe("fitOnboardingAppRows", () => {
  it("shows every app that fits", () => {
    expect(fitOnboardingAppRows({ room: 571, rowCount: 6, rowHeight: 60 })).toBe(6);
  });

  it("cuts a longer list at a half row, never under three and a half", () => {
    expect(fitOnboardingAppRows({ room: 336, rowCount: 6, rowHeight: 60 })).toBe(5.5);
    expect(fitOnboardingAppRows({ room: 210, rowCount: 6, rowHeight: 60 })).toBe(3.5);
  });

  it("stops at eight and a half rows on a tall display, however many fit", () => {
    // A 1080x1920 portrait display leaves room for about 25 rows.
    expect(fitOnboardingAppRows({ room: 1500, rowCount: 40, rowHeight: 60 })).toBe(8.5);
    expect(fitOnboardingAppRows({ room: 1500, rowCount: 9, rowHeight: 60 })).toBe(8.5);
    expect(fitOnboardingAppRows({ room: 1500, rowCount: 8, rowHeight: 60 })).toBe(8);
  });

  it("keeps a too-short window's card within its room, at a row and a half", () => {
    // 150% zoom on a 720p display leaves about two rows of room.
    expect(fitOnboardingAppRows({ room: 120, rowCount: 6, rowHeight: 60 })).toBe(1.5);
  });
});

describe("onboardingMissing", () => {
  it("lists what was left off, but not apps when there were none to connect", () => {
    const permissions = {
      item: "permissions",
      allowed: 2,
      total: 3,
      computerUse: true,
      missing: ["notifications"],
    } as const;
    expect(
      onboardingMissing({ apps: { item: "apps", connected: [] }, permissions })
    ).toEqual(["apps", "notifications"]);
    expect(
      onboardingMissing({
        apps: { item: "apps", connected: [], offered: false },
        permissions,
      })
    ).toEqual(["notifications"]);
  });
});

describe("onboardingLightDepth", () => {
  it("deepens the light one even step per finished item, the Side Chat shortcut and the welcome page deepest", () => {
    for (const items of [mac, onboardingItemsFor({ permissions: false })]) {
      const at = (start: OnboardingStart) =>
        onboardingLightDepth(
          initialOnboardingThread({ at: 0, items, speaker: "Comma", start })
        );
      const passed = items.map((item) => at(`after-${item}`));
      // A card up is not a step yet; each item answered, done or skipped, is.
      expect([at("intro"), at("greeting"), at(items[0]!), ...passed]).toEqual([
        0,
        0,
        0,
        ...items.map((_, index) => (index + 1) / (items.length + 1)),
      ]);
      expect(at("shortcut")).toBe(1);
      expect(at("welcome")).toBe(1);
    }
  });

  it("changes only between flights: it calms after the greeting and steps deeper once Comma has answered", () => {
    let thread = run(initialOnboardingThread({ at: 0, items: mac, speaker: "Comma" }), {
      type: "begin",
      at: 0,
    });
    for (const index of [0, 1, 2]) {
      thread = run(thread, {
        type: "say",
        at: index * 2500,
        line: { kind: "greeting", index },
        source,
        speaker: "Comma",
      });
      expect(onboardingMessageInFlight(thread)).toBe(true);
      expect(onboardingGreetingLanded(thread)).toBe(false);
      thread = run(thread, { type: "landed", id: index, at: index * 2500 + 900 });
    }
    // The greeting is over before the first question is sent.
    expect(onboardingGreetingLanded(thread)).toBe(true);

    const result = { item: "apps", connected: [] } as const;
    const replying = run(
      play(thread),
      { type: "finish", at: 20_000, result },
      { type: "reply", at: 20_200, source }
    );
    // Neither the reply in flight nor its landing deepens the light...
    expect(onboardingLightDepth(replying)).toBe(0);
    const replied = run(replying, { type: "landed", id: 4, at: 21_100 });
    expect(onboardingLightDepth(replied)).toBe(0);
    const answering = run(replied, {
      type: "say",
      at: 22_100,
      line: { kind: "bridge", result, index: 0 },
      source,
      speaker: "Comma",
    });
    expect(onboardingLightDepth(answering)).toBe(0);
    // ...Comma's answer landing does, in the beat before its next line.
    const answered = run(answering, { type: "landed", id: 5, at: 23_000 });
    expect(onboardingMessageInFlight(answered)).toBe(false);
    expect(onboardingLightDepth(answered)).toBe(1 / 4);
  });
});
