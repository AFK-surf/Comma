import { CoreProvider } from "@comma/core-client";
import type {
  LinkPreview,
  LinkPreviewValue,
  RecommendationsValue,
} from "@comma/core/contract";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock } from "@comma/ui/clock/virtual";
import {
  createScriptedCore,
  delegateScriptedCore,
} from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { useProductInboxProjection } from "../../../product-inbox";
import { createProductInboxProjectionHarness } from "../../../test/productInboxProjectionHarness";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import {
  act,
  createEvent,
  fireEvent,
  render as renderBase,
  screen,
  within,
} from "@comma/test-utils/render";
import type {
  RecommendationCard,
  RecommendationEnvelope,
  RecommendationSnapshot,
  RecommendationSource,
} from "@comma/recommendation-contract";
import { recommendationGeneratedCardSchema } from "@comma/recommendation-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Toaster, toast } from "@comma/ui/components/toast";
import {
  RecommendationCardView,
  RecommendationLinkPreviewProvider as Provider,
  RecommendationRail as Rail,
  RecommendationSummary,
  boundRoutineDragTranslation,
  briefingGreeting,
  reconcileRoutineCardOrder,
  reorderRoutineCardIds,
  routineDragOverdragCap,
} from "../RecommendationRail";

const { loadRecommendationMediaMock, nativePlatform } = vi.hoisted(() => ({
  loadRecommendationMediaMock: vi.fn(),
  nativePlatform: {
    openNativePlatformExternalUrl: vi.fn(),
    writeText: vi.fn(),
  },
}));

vi.mock("../recommendationMedia", () => ({
  loadRecommendationMedia: loadRecommendationMediaMock,
}));

vi.mock("../../../nativePlatformActions", () => ({
  nativePlatformClipboard: { writeText: nativePlatform.writeText },
  openNativePlatformExternalUrl: nativePlatform.openNativePlatformExternalUrl,
}));

afterEach(() => {
  act(() => toast.dismissAll());
  vi.restoreAllMocks();
  initializeCommaI18n(["en"]);
});
beforeEach(() => {
  // Announced Routine problems belong to one window session.
  sessionStorage.clear();
  nativePlatform.openNativePlatformExternalUrl.mockReset();
  nativePlatform.writeText.mockReset();
  loadRecommendationMediaMock.mockReset();
  loadRecommendationMediaMock.mockResolvedValue({ status: "unavailable" });
  core = railCore();
});

const linear: RecommendationSource = {
  appId: "linear",
  appName: "Linear",
  connectionId: "linear-account",
  enabled: true,
  kind: "composio",
  label: "Linear",
};

/** A briefing the server has published: `snapshot` from `sources`. */
function envelope(
  snapshot: RecommendationSnapshot | null = recommendationSnapshot(),
  sources: RecommendationSource[] = [linear],
  state: RecommendationEnvelope["state"] = "fresh"
): RecommendationEnvelope {
  return {
    settings: {
      autoEnableNewSources: true,
      sourcesCheckedAt: "2026-08-14T00:00:00Z",
      schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
      sourceRevision: 1,
      sources,
    },
    snapshot,
    state,
  } as RecommendationEnvelope;
}

/** No briefing yet (`state`), with a GitHub source enabled or none. */
function envelopeWithoutSnapshot(
  hasEnabledSource: boolean,
  state: "empty" | "refreshing" | "error" = "empty"
): RecommendationEnvelope {
  return envelope(
    null,
    hasEnabledSource
      ? [
          {
            appId: "github",
            appName: "GitHub",
            connectionId: "github-account",
            enabled: true,
            kind: "native_mcp_oauth",
            label: "github",
          },
        ]
      : [],
    state
  );
}

/**
 * The core the rail is rendered over (`render` uses the one made last): the briefing it says (`shown`; none: not
 * read yet), a hovered link's preview (`previewOf`; none: the server has no preview), and its answer to a refresh
 * (`refresh`; by default accepted). `say` changes what it says of the briefing; `topics` are the topics the UI asked
 * for, in order.
 */
function railCore({
  shown,
  previewOf = () => undefined,
  refresh = () => ({ rateLimited: false }),
}: {
  shown?: Partial<RecommendationsValue> | undefined;
  previewOf?: (href: string) => LinkPreview | undefined;
  refresh?: () => unknown;
} = {}) {
  let value: RecommendationsValue | undefined = shown && briefing(shown);
  const topics: Record<string, unknown>[] = [];
  const scripted = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "recommendations") return value;
      if (topic.topic !== "linkPreview") return undefined;
      const preview = previewOf(String(topic.href));
      return (
        preview ? { status: "ready", preview } : { status: "missing" }
      ) satisfies LinkPreviewValue;
    },
    calls: (name) => (name === "recommendations.refresh" ? refresh() : null),
    onSubscribe: (topic) => topics.push(topic),
  });
  return {
    ...scripted,
    topics,
    /** The topics named `name` the UI asked for. */
    asked: (name: string) => topics.filter((topic) => topic.topic === name),
    /** What the core says of the briefing from now on (the rest as it was). */
    say(next: Partial<RecommendationsValue>) {
      value = briefing({ ...value, ...next });
      scripted.changed("recommendations");
    },
  };
}

function briefing(shown: Partial<RecommendationsValue>): RecommendationsValue {
  return {
    workspace: "wsp_1",
    envelope: null,
    failure: null,
    discovering: false,
    refreshing: false,
    ...shown,
  };
}

/** The core says `shown` of the briefing (a published one by default). */
function script(
  options: Parameters<typeof railCore>[0] = { shown: { envelope: envelope() } }
) {
  core = railCore(options);
  return core;
}

/** A promise the test settles. */
function pending<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { promise, resolve };
}

/** The user, on the fake clock. */
function pointerUser() {
  setInteractionModality("pointer");
  return userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
}

const routinesHeadingFollowsGreeting = () =>
  Boolean(
    screen
      .getByRole("heading", { level: 1 })
      .compareDocumentPosition(
        screen.getByRole("heading", { level: 2, name: "Routines" })
      ) & Node.DOCUMENT_POSITION_FOLLOWING
  );

describe("RecommendationRail", () => {
  it("reconciles and reorders current-snapshot routine cards without losing new cards", () => {
    expect(
      reconcileRoutineCardOrder(["news", "document"], ["document", "tasks"])
    ).toEqual(["document", "tasks"]);
    expect(
      reorderRoutineCardIds(
        ["document", "news", "tasks"],
        ["document"],
        "tasks",
        "after"
      )
    ).toEqual(["news", "tasks", "document"]);
    expect(
      reorderRoutineCardIds(
        ["document", "news", "tasks"],
        ["news", "tasks"],
        "document",
        "before"
      )
    ).toEqual(["news", "tasks", "document"]);
  });

  it("bounds the pointer-drag translation to the row band with damped overshoot", () => {
    const initialTops = new Map([
      ["document", 100],
      ["news", 128],
      ["tasks", 156],
    ]);

    // Inside the band the translation tracks the pointer 1:1.
    expect(boundRoutineDragTranslation(10, initialTops, 128)).toBe(10);
    expect(boundRoutineDragTranslation(-28, initialTops, 128)).toBe(-28);
    expect(boundRoutineDragTranslation(56, initialTops, 100)).toBe(56);

    // Past the band the overshoot is damped, monotonic, and capped so the
    // scroll viewport's scrollable overflow stays bounded.
    const nearOvershoot = boundRoutineDragTranslation(70, initialTops, 100);
    const farOvershoot = boundRoutineDragTranslation(500, initialTops, 100);
    expect(nearOvershoot).toBeGreaterThan(56);
    expect(nearOvershoot).toBeLessThan(70);
    expect(farOvershoot).toBeGreaterThan(nearOvershoot);
    expect(farOvershoot).toBeLessThanOrEqual(56 + routineDragOverdragCap);

    const farUndershoot = boundRoutineDragTranslation(-500, initialTops, 156);
    expect(farUndershoot).toBeLessThan(-56);
    expect(farUndershoot).toBeGreaterThanOrEqual(-56 - routineDragOverdragCap);

    // A lone row stays pinned within the overshoot cap.
    expect(
      Math.abs(boundRoutineDragTranslation(90, new Map([["only", 30]]), 30))
    ).toBeLessThanOrEqual(routineDragOverdragCap);
  });

  it("does not fetch recommendations while the home surface is paused", async () => {
    script();
    render(
      <Rail
        active={false}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    // The core reads the briefing only for a surface that asks for it.
    expect(core.asked("recommendations")).toEqual([]);
  });

  it("re-reads the briefing once when the app language changes", async () => {
    script();
    const props = {
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const rail = (locale: "en" | "zh-CN") => (
      <CommaI18nProvider locale={locale}>
        <Rail {...props} />
      </CommaI18nProvider>
    );
    const { rerender } = render(rail("en"));

    await flush();
    expect(core.asked("recommendations")).toEqual([
      {
        topic: "recommendations",
        workspace: "wsp_1",
        timezone: expect.any(String),
        locale: "en",
      },
    ]);

    // The server regenerates on a language change, so the rail asks for the briefing in the new language (another
    // topic, which the core reads at once) instead of the old one.
    rerender(rail("zh-CN"));
    await flush();
    expect(core.asked("recommendations")).toHaveLength(2);
    expect(core.asked("recommendations")[1]).toMatchObject({
      workspace: "wsp_1",
      locale: "zh-CN",
    });
  });

  it("does not re-render recommendation documents when its stable props are repeated", async () => {
    script();
    const parse = vi.spyOn(recommendationGeneratedCardSchema, "safeParse");
    const props = {
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const { rerender } = render(<Rail {...props} />);

    await flush();
    expect(screen.getByRole("heading", { name: "Good morning." })).toBeInTheDocument();
    const initialParseCount = parse.mock.calls.length;
    expect(initialParseCount).toBeGreaterThan(0);

    rerender(<Rail {...props} />);

    expect(parse).toHaveBeenCalledTimes(initialParseCount);
  });

  it("renders a pre-action text-list snapshot as inert fallback text", () => {
    const legacyCard = {
      fallbackText: "Review the legacy issue.",
      id: "legacy-text-list",
      items: [
        {
          id: "legacy-item",
          parts: [{ kind: "markdown", text: "Review COMMA-OLD" }],
        },
      ],
      sourceIds: ["linear-account"],
      template: "text-list@1",
      title: "Linear",
    } as RecommendationCard;
    vi.spyOn(recommendationGeneratedCardSchema, "safeParse").mockReturnValueOnce({
      data: legacyCard,
      success: true,
    } as never);

    const action = vi.fn();
    render(
      <RecommendationCardView
        card={legacyCard}
        onAction={action}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
      />
    );

    expect(screen.getByRole("heading", { name: "Linear" })).toBeInTheDocument();
    expect(screen.getByText("Review the legacy issue.")).toBeInTheDocument();
    expect(screen.queryByText("Review COMMA-OLD")).not.toBeInTheDocument();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(action).not.toHaveBeenCalled();
  });

  it("renders a removed template as inert fallback text without parsing its data", () => {
    const removedCard = {
      fallbackText: "Review the Linear incidents.",
      id: "legacy-rich-list",
      items: [
        {
          id: "legacy-item",
          parts: [{ kind: "markdown", text: "Review the incident" }],
          secondaryText: "This old row has no action.",
        },
      ],
      sourceIds: ["linear-account"],
      template: "rich-list@1",
      title: "Linear",
    } as unknown as RecommendationCard;
    const parse = vi
      .spyOn(recommendationGeneratedCardSchema, "safeParse")
      .mockReturnValueOnce({ data: removedCard, success: true } as never);

    render(
      <RecommendationCardView
        card={removedCard}
        onAction={vi.fn()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
      />
    );

    expect(parse).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "Linear" })).toBeInTheDocument();
    expect(screen.getByText("Review the Linear incidents.")).toBeInTheDocument();
    expect(screen.queryByText("Review the incident")).not.toBeInTheDocument();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("prompts an enabled source to generate instead of claiming no app is connected", async () => {
    script({ shown: { envelope: envelopeWithoutSnapshot(true) } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(
      screen.getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    expect(screen.queryByText("No routines created yet")).not.toBeInTheDocument();
  });

  it("shows the server-owned generating state and keeps duplicate refresh disabled", async () => {
    script({ shown: { envelope: envelopeWithoutSnapshot(true, "refreshing") } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByText("Generating your briefing…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    await flush();
    expect(screen.getByRole("dialog", { name: "Customize routines" })).toHaveAttribute(
      "data-has-cards",
      "false"
    );
    expect(screen.queryByRole("menuitem", { name: "Refresh" })).not.toBeInTheDocument();
  });

  it("asks the core to start discovery over each time Home is shown again", async () => {
    // How often the core checks (at most 10 times per showing) is the core's: recommendations.test.ts, "checks for
    // connected apps at most 10 times, and again from the start on a new visit".
    script({
      shown: {
        envelope: {
          ...envelopeWithoutSnapshot(false),
          settings: {
            ...envelopeWithoutSnapshot(false).settings,
            sourcesCheckedAt: null,
          },
        },
        discovering: true,
      },
    });
    const props = {
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const view = render(<Rail {...props} />);
    await advance(60_000);
    expect(core.sentTo("recommendations.visit")).toEqual([]);
    view.rerender(<Rail {...props} active={false} />);
    await flush();
    view.rerender(<Rail {...props} active />);
    await flush();
    expect(core.sentTo("recommendations.visit")).toEqual([{ workspace: "wsp_1" }]);
  });

  it("keeps a terminal generation error out of the UI", async () => {
    script({ shown: { envelope: envelopeWithoutSnapshot(true, "error") } });
    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const rail = container.querySelector<HTMLElement>(".comma-recommendations")!;
    expect(
      within(rail).getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
  });

  it.each([
    // An empty day is a result, not a failure: the rail says so in place.
    ["renderer_declined", "Nothing new in your apps to brief today."],
    // The member cannot fix a missing identity stamp; the rail stays neutral.
    ["member_identity_required", "Refresh to generate your first briefing."],
  ] as const)(
    "shows failure class %s as neutral rail copy",
    async (lastError, copy) => {
      script({
        shown: { envelope: { ...envelopeWithoutSnapshot(true, "error"), lastError } },
      });
      render(
        <Rail
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={vi.fn()}
          workspaceId="wsp_1"
        />
      );

      await flush();
      expect(screen.getByText(copy)).toBeInTheDocument();
      expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled();
    }
  );

  it("keeps an unreadable projection quiet and the header refresh as the way back", async () => {
    // A briefing the core cannot read is `unavailable` (recommendations.test.ts, "calls the briefing unavailable
    // when it cannot be read, and when a refresh fails").
    script({
      shown: { failure: "unavailable" },
      refresh: () => {
        throw Object.assign(new Error("network down"), { code: "offline" });
      },
    });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
    // An unreadable projection lists no sources, and the header still refreshes.
    const refresh = screen.getByRole("button", { name: "Refresh" });
    expect(refresh).toBeEnabled();
    fireEvent.click(refresh);
    await flush();
    expect(core.sentTo("recommendations.refresh")).toEqual([{ workspace: "wsp_1" }]);
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
  });

  it("generates from the moment Refresh is pressed after a failed generation, before the server reports the run", async () => {
    // The core says `refreshing` from the moment it is asked until the server answers (recommendations.test.ts,
    // "says a refresh is under way until the server answers").
    const answer = pending<unknown>();
    script({
      shown: { envelope: envelopeWithoutSnapshot(true, "error") },
      refresh: () => {
        core.say({ refreshing: true });
        return answer.promise;
      },
    });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(
      screen.getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();
    // The refresh request is still collecting sources on the server.
    expect(core.sentTo("recommendations.refresh")).toEqual([{ workspace: "wsp_1" }]);
    expect(screen.getByTestId("recommendations-generating")).toBeInTheDocument();
    // With no briefing on screen the generating copy is the progress; the
    // refresh control keeps its icon instead of spinning.
    expect(
      screen
        .getByRole("button", { name: "Refresh" })
        .querySelector("[class*=animate-spin]")
    ).toBeNull();
  });

  it("explains a refused refresh instead of calling routines unavailable", async () => {
    // A refusal (429) is `rateLimited`, and the core says `rate_limited` (recommendations.test.ts, "explains a
    // refused refresh until a new briefing arrives, and follows an accepted one").
    script({
      shown: { envelope: envelopeWithoutSnapshot(true, "error") },
      refresh: () => {
        core.say({ failure: "rate_limited" });
        return { rateLimited: true };
      },
    });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(
      screen.getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();
    // The member asked for this refresh, so its refusal is answered.
    expect(
      screen.getByText("Too many refreshes in the last hour. Try again later.")
    ).toBeInTheDocument();
    // The header refresh stays the way to try again.
    expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled();
  });

  it("asks the core to re-read the projection when the member returns to the window", async () => {
    // Whether it reads (a minute after the last read, not sooner) is the core's: recommendations.test.ts, "reads
    // again when a window comes back after a minute, not sooner".
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await flush();
    expect(core.sentTo("recommendations.revisit")).toEqual([]);

    window.dispatchEvent(new Event("focus"));
    await flush();
    expect(core.sentTo("recommendations.revisit")).toEqual([{}]);

    await advance(61_000);
    window.dispatchEvent(new Event("focus"));
    await flush();
    expect(core.sentTo("recommendations.revisit")).toEqual([{}, {}]);
  });

  it("stops showing a server-owned run once its projection can no longer be read", async () => {
    // When the core gives up on the run's projection (after 45 failed 2 s reads) is the core's:
    // recommendations.test.ts, "calls a run unavailable only when more than 45 reads failed, and stops there".
    const toastError = vi.spyOn(toast, "error");
    script({ shown: { envelope: envelopeWithoutSnapshot(true, "refreshing") } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await flush();
    expect(screen.getByText("Generating your briefing…")).toBeInTheDocument();

    // The core keeps the run's last envelope and calls the projection unavailable.
    core.say({ failure: "unavailable" });
    await flush();
    expect(toastError).not.toHaveBeenCalled();
    expect(screen.queryByText("Generating your briefing…")).not.toBeInTheDocument();
  });

  it("says it is looking for connected apps while the first discovery runs", async () => {
    const waiting = envelopeWithoutSnapshot(false);
    script({
      shown: {
        envelope: {
          ...waiting,
          settings: { ...waiting.settings, sourcesCheckedAt: null },
        },
        discovering: true,
      },
    });

    render(
      <Rail
        onConnectApps={vi.fn()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await flush();
    expect(screen.getByTestId("recommendations-discovering")).toHaveTextContent(
      "Looking for connected apps…"
    );
    expect(screen.queryByText("No routines created yet")).not.toBeInTheDocument();

    // The next check finds the sources checked (the core checks every 1.5 s).
    core.say({ envelope: waiting, discovering: false });
    await flush();
    expect(screen.getByText("No routines created yet")).toBeInTheDocument();
  });

  it("explains a refused refresh in a toast while the briefing stays", async () => {
    script({
      shown: { envelope: envelope() },
      refresh: () => {
        core.say({ failure: "rate_limited" });
        return { rateLimited: true };
      },
    });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    // The toolbar moves into the briefing scroll area once the snapshot
    // arrives; wait for that render before pressing its Refresh control.
    await flush();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();
    expect(
      screen.getByText("Too many refreshes in the last hour. Try again later.")
    ).toBeInTheDocument();
    expect(
      screen.queryByText("Couldn’t update routines. Showing the previous briefing.")
    ).not.toBeInTheDocument();
  });

  it("lays out the first read as a briefing so the routines heading holds its place", async () => {
    // Not read yet: the core says nothing.
    script({});
    render(
      <Rail
        greetingName="Zanwei"
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByTestId("recommendations-loading")).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Zanwei");
    expect(routinesHeadingFollowsGreeting()).toBe(true);

    core.say({ envelope: envelope() });
    await flush();

    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
    expect(screen.queryByTestId("recommendations-loading")).not.toBeInTheDocument();
    expect(routinesHeadingFollowsGreeting()).toBe(true);
  });

  it("keeps the briefing on screen and spins the refresh control while it regenerates", async () => {
    const toastSuccess = vi.spyOn(toast, "success");
    const snapshot = recommendationSnapshot();
    const next = envelope({
      ...snapshot,
      cards: [{ ...snapshot.cards[0]!, title: "Planning" }],
      generation: 2,
      generatedAt: 2,
    });
    const answer = pending<unknown>();
    script({
      shown: { envelope: envelope() },
      refresh: () => {
        core.say({ refreshing: true });
        return answer.promise;
      },
    });
    render(
      <Rail
        greetingName="Zanwei"
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
    // The first read of a briefing is not news.
    expect(toastSuccess).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();

    const refresh = screen.getByRole("button", { name: "Refresh" });
    expect(refresh.querySelector("[class*=animate-spin]")).not.toBeNull();
    expect(refresh).toBeDisabled();
    // The current briefing holds in place instead of collapsing to a skeleton.
    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
    expect(screen.getByText(/before standup/)).toBeInTheDocument();
    expect(screen.queryByTestId("recommendations-loading")).not.toBeInTheDocument();

    // The run published: the core takes the answer's briefing.
    core.say({ envelope: next, refreshing: false });
    answer.resolve({ rateLimited: false });
    await flush();

    expect(screen.getByRole("heading", { name: "Planning" })).toBeInTheDocument();
    expect(
      screen
        .getByRole("button", { name: "Refresh" })
        .querySelector("[class*=animate-spin]")
    ).toBeNull();
    expect(toastSuccess).toHaveBeenCalledTimes(1);
    expect(toastSuccess).toHaveBeenCalledWith(
      "Routines updated",
      expect.objectContaining({ testId: "routine-updated-toast" })
    );
  });

  it("previews an inline link on hover with its source, label and destination", async () => {
    render(
      <RecommendationSummary
        fallbackTitle="Good morning."
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        parts={[
          { kind: "markdown", text: "Review " },
          {
            kind: "inline-link",
            link: {
              href: "https://github.com/AFK-surf/Comma/pull/845/",
              label: "PR #845",
              sourceId: "github-account",
            },
          },
        ]}
        sources={[
          {
            appId: "github",
            appName: "GitHub",
            connectionId: "github-account",
            enabled: true,
            kind: "native_mcp_oauth",
            label: "github",
          },
        ]}
      />
    );

    const user = pointerUser();
    await user.hover(screen.getByRole("button", { name: "PR #845" }));
    await advance(500);
    const preview = screen.getByRole("tooltip");
    expect(preview).toHaveTextContent("PR #845");
    expect(preview).toHaveTextContent("GitHub · github.com/AFK-surf/Comma/pull/845");
    expect(preview.querySelector('svg[data-provider-logo="github"]')).not.toBeNull();
  });

  it("upgrades a GitHub pull request link to the pull request card on hover", async () => {
    // Card times are relative within the local day only; pin "now" to a local
    // noon so "6h ago" / "3h ago" cannot roll into "yesterday" on CI.
    vi.setSystemTime(new Date(2026, 7, 22, 12));
    script({
      previewOf: () => ({
        additions: 12_593,
        author: {
          avatarUrl: "https://avatars.example/catsjuice.png",
          login: "CatsJuice",
        },
        changedFiles: 147,
        deletions: 829,
        href: "https://github.com/AFK-surf/Comma/pull/845",
        kind: "github_pull_request",
        number: 845,
        repository: "AFK-surf/Comma",
        state: "merged",
        title: "feat(chat): add inline task elements",
        updatedAt: Date.now() - 6 * 60 * 60_000,
      }),
    });
    render(
      <Provider workspaceId="wsp_1">
        <RecommendationSummary
          fallbackTitle="Good morning."
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          parts={[
            { kind: "markdown", text: "Review " },
            {
              kind: "inline-link",
              link: {
                href: "https://github.com/AFK-surf/Comma/pull/845/",
                label: "PR #845",
                sourceId: "github-account",
              },
            },
          ]}
          sources={[
            {
              appId: "github",
              appName: "GitHub",
              connectionId: "github-account",
              enabled: true,
              kind: "native_mcp_oauth",
              label: "github",
            },
          ]}
        />
      </Provider>
    );

    const user = pointerUser();
    await user.hover(screen.getByRole("button", { name: "PR #845" }));
    await advance(500);
    const card = screen.getByTestId("recommendation-link-card");
    // The request it makes of the server is the core's (link-previews.test.ts, "is read once for every card showing
    // it, and kept for the next one").
    expect(core.asked("linkPreview")).toEqual([
      {
        topic: "linkPreview",
        workspace: "wsp_1",
        href: "https://github.com/AFK-surf/Comma/pull/845/",
        source: "github-account",
      },
    ]);
    expect(card).toHaveTextContent("Merged");
    expect(card).toHaveTextContent("AFK-surf/Comma #845");
    expect(card).toHaveTextContent("6h ago");
    expect(card).toHaveTextContent("feat(chat): add inline task elements");
    expect(card).toHaveTextContent("+12,593");
    expect(card).toHaveTextContent("-829");
    expect(card).toHaveTextContent("147 files");
    const author = card.querySelector(".comma-recommendation-link-card-person");
    expect(author).toHaveTextContent("CatsJuice");
    expect(author).toHaveAttribute("title", "Author: CatsJuice");
    expect(
      card.querySelector(".comma-recommendation-link-card-state svg")
    ).not.toBeNull();
    expect(card.querySelector(".comma-recommendation-link-card-state")).toHaveAttribute(
      "data-state",
      "merged"
    );
  });

  it("renders Linear issue and public Google Calendar event previews in the same card", async () => {
    // Card times are relative within the local day only; pin "now" to a local
    // noon so "6h ago" / "3h ago" cannot roll into "yesterday" on CI.
    vi.setSystemTime(new Date(2026, 7, 22, 12));
    script({
      previewOf: (href) =>
        (href.includes("linear.app")
          ? {
              assignee: { avatarUrl: null, name: "zanwei" },
              href,
              identifier: "COMMA-143",
              kind: "linear_issue",
              priority: 2,
              priorityLabel: "High",
              project: "Launch",
              state: { color: "#f2c94c", name: "In Progress", type: "started" },
              team: "COMMA",
              title: "Fix onboarding crash on first launch",
              updatedAt: Date.now() - 3 * 60 * 60_000,
            }
          : {
              allDay: true,
              attendeeCount: 2,
              endsAt: Date.UTC(2026, 8, 2),
              href,
              kind: "google_calendar_event",
              location: "Room 4",
              meetingUrl: "https://meet.google.com/abc-defg-hij",
              organizer: { name: "Dana Wu" },
              startsAt: Date.UTC(2026, 8, 1),
              status: "confirmed",
              title: "Offsite",
              updatedAt: null,
            }) as LinkPreview,
    });
    render(
      <Provider workspaceId="wsp_1">
        <RecommendationSummary
          fallbackTitle="Good morning."
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          parts={[
            { kind: "markdown", text: "Review " },
            {
              kind: "inline-link",
              link: {
                href: "https://linear.app/comma/issue/COMMA-143",
                label: "COMMA-143",
                sourceId: "linear-account",
              },
            },
            { kind: "markdown", text: " before " },
            {
              kind: "inline-link",
              link: {
                href: "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
                label: "the offsite",
                sourceId: "calendar-account",
              },
            },
          ]}
          sources={[
            {
              appId: "linear",
              appName: "Linear",
              connectionId: "linear-account",
              enabled: true,
              kind: "composio",
              label: "Linear",
            },
            {
              appId: "googlecalendar",
              appName: "Google Calendar",
              connectionId: "calendar-account",
              enabled: true,
              kind: "composio",
              label: "Google Calendar",
            },
          ]}
        />
      </Provider>
    );

    const user = pointerUser();
    await user.hover(screen.getByRole("button", { name: "COMMA-143" }));
    await advance(500);
    const issue = screen.getByTestId("recommendation-link-card");
    expect(issue).toHaveAttribute("data-kind", "linear_issue");
    expect(issue).toHaveTextContent("In Progress");
    expect(issue).toHaveTextContent("COMMA-143 · Launch");
    expect(issue).toHaveTextContent("3h ago");
    expect(issue).toHaveTextContent("Fix onboarding crash on first launch");
    expect(issue).toHaveTextContent("zanwei");
    expect(issue).toHaveTextContent("High");
    expect(
      issue.querySelector(".comma-recommendation-link-card-state")
    ).toHaveAttribute("data-state", "started");

    await user.unhover(screen.getByRole("button", { name: "COMMA-143" }));
    await user.hover(screen.getByRole("button", { name: "the offsite" }));
    await advance(500);
    expect(screen.getByTestId("recommendation-link-card")).toHaveAttribute(
      "data-kind",
      "google_calendar_event"
    );
    const event = screen.getByTestId("recommendation-link-card");
    expect(event).toHaveTextContent("Confirmed");
    expect(event).toHaveTextContent("Sep 1 · All day");
    expect(event).toHaveTextContent("Offsite");
    expect(event).toHaveTextContent("Dana Wu");
    expect(
      event.querySelector(".comma-recommendation-link-card-state")
    ).toHaveAttribute("data-state", "confirmed");
  });

  it("shows no link card for private links (Gmail) and never requests a preview", async () => {
    render(
      <Provider workspaceId="wsp_1">
        <RecommendationSummary
          fallbackTitle="Good morning."
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          parts={[
            { kind: "markdown", text: "Review " },
            {
              kind: "inline-link",
              link: {
                href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
                label: "Launch approval",
                sourceId: "gmail-account",
              },
            },
          ]}
          sources={[
            {
              appId: "gmail",
              appName: "Gmail",
              connectionId: "gmail-account",
              enabled: true,
              kind: "composio",
              label: "Gmail",
            },
          ]}
        />
      </Provider>
    );

    const user = pointerUser();
    await user.hover(screen.getByRole("button", { name: "Launch approval" }));
    await advance(600);
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(core.asked("linkPreview")).toEqual([]);
  });

  it("lets a chip with no preview of its own stand in for the row's prompt", async () => {
    const card = {
      fallbackText: "Reply to the launch approval.",
      id: "mail-card",
      items: [
        {
          action: {
            label: "Draft a reply",
            prompt: "Draft a reply to Dana Wu about the launch approval",
            requiresConfirmation: false,
            type: "open_task_form",
          },
          id: "mail-item",
          parts: [
            { kind: "markdown", text: "Dana Wu \u00b7 " },
            {
              kind: "inline-link",
              link: {
                href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
                label: "launch approval",
                sourceId: "gmail-account",
              },
            },
            { kind: "markdown", text: " and " },
            {
              kind: "inline-task",
              task: { conversationId: "cnv_reply", label: "COMMA-144" },
            },
          ],
        },
      ],
      sourceIds: ["gmail-account"],
      template: "text-list@1",
      title: "Launch approval",
    } as RecommendationCard;
    const sources: RecommendationSource[] = [
      {
        appId: "gmail",
        appName: "Gmail",
        connectionId: "gmail-account",
        enabled: true,
        kind: "composio",
        label: "Gmail",
      },
    ];
    render(
      <Provider workspaceId="wsp_1">
        <RecommendationCardView
          card={card}
          onAction={vi.fn()}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          sources={sources}
        />
      </Provider>
    );

    const user = pointerUser();

    // The private mail chip has no card of its own, and the task chip never had
    // one; both would otherwise be holes in the row's hover surface.
    for (const chip of ["launch approval", "COMMA-144"]) {
      await user.hover(screen.getByRole("button", { name: chip }));
      await advance(500);
      const preview = screen.getByRole("tooltip");
      expect(preview).toHaveTextContent(
        "Draft a reply to Dana Wu about the launch approval"
      );
      await user.unhover(screen.getByRole("button", { name: chip }));
      await advance(500);
    }
    expect(core.asked("linkPreview")).toEqual([]);
  });

  it("uses a fixed time-of-day greeting as the briefing title", async () => {
    vi.setSystemTime(new Date("2026-08-27T09:15:00"));
    render(
      <RecommendationSummary
        fallbackTitle="Your briefing"
        greetingName="Zanwei"
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        parts={[
          {
            kind: "markdown",
            text: "Here\u2019s your clearest path through today\n\nLinear has 2 updates.",
          },
        ]}
      />
    );

    // The model's own opener never reaches the heading, and it is not repeated
    // in the body either.
    expect(
      screen.getByRole("heading", { name: "Good morning, Zanwei." })
    ).toBeVisible();
    expect(screen.queryByText(/clearest path through today/)).toBeNull();
    expect(screen.getByText(/Linear has 2 updates/)).toBeVisible();
  });

  it("picks the greeting from the local time of day", () => {
    const messages = {
      recommendations_greeting_morning: ({ name }: { name: string }) =>
        `Good morning, ${name}.`,
      recommendations_greeting_afternoon: ({ name }: { name: string }) =>
        `Good afternoon, ${name}.`,
      recommendations_greeting_evening: ({ name }: { name: string }) =>
        `Good evening, ${name}.`,
    } as unknown as Parameters<typeof briefingGreeting>[0];

    const at = (hour: number) =>
      briefingGreeting(messages, "zanwei.guo", new Date(2026, 7, 27, hour, 0, 0));

    expect(at(0)).toBe("Good morning, zanwei.guo.");
    expect(at(11)).toBe("Good morning, zanwei.guo.");
    expect(at(12)).toBe("Good afternoon, zanwei.guo.");
    expect(at(17)).toBe("Good afternoon, zanwei.guo.");
    expect(at(18)).toBe("Good evening, zanwei.guo.");
    expect(at(23)).toBe("Good evening, zanwei.guo.");
  });

  it("sends the empty state's Connect apps action to its handler", async () => {
    const onConnectApps = vi.fn();
    script({ shown: { envelope: envelopeWithoutSnapshot(false) } });
    render(
      <Rail
        onConnectApps={onConnectApps}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByText("No routines created yet")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Connect apps" }));
    expect(onConnectApps).toHaveBeenCalledTimes(1);
  });

  it("names a source only the member can repair and sends Reconnect to Plugins", async () => {
    const onConnectApps = vi.fn();
    script({
      shown: {
        envelope: envelope(recommendationSnapshot(), [
          {
            appId: "slack",
            appName: "Slack",
            connectionId: "slack-binding",
            enabled: true,
            kind: "managed_oauth" as const,
            label: "Slack",
            needsReconnect: true,
          },
          {
            appId: "linear",
            appName: "Linear",
            connectionId: "linear-account",
            enabled: true,
            kind: "composio" as const,
            label: "Linear",
            needsReconnect: false,
          },
        ]),
      },
    });
    render(
      <Rail
        onConnectApps={onConnectApps}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByTestId("routine-reconnect-notice")).toHaveTextContent(
      "Routines can’t read Slack. Reconnect to continue."
    );
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Reconnect" }));
    expect(onConnectApps).toHaveBeenCalledTimes(1);
  });

  it("renders versioned cards and keeps inline identities out of markdown", async () => {
    const openTask = vi.fn();
    const openUrl = vi.fn();

    script();
    render(
      <Rail
        onOpenTask={openTask}
        onOpenUrl={openUrl}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByText("Document")).toBeInTheDocument();
    expect(screen.getByText("COMMA-143")).toBeInTheDocument();
    expect(document.body.innerHTML).not.toContain("cnv_private_task_identity");

    fireEvent.click(screen.getByText("COMMA-143"));
    expect(openTask).toHaveBeenCalledWith("cnv_private_task_identity");
    fireEvent.click(screen.getByText("Open report"));
    expect(openUrl).toHaveBeenCalledWith("https://example.com/report");
    fireEvent.click(screen.getByText("COMMA-151 summary"));
    expect(openUrl).toHaveBeenCalledWith("https://linear.app/comma/issue/COMMA-151");
  });

  it("renders the greeting and brief before the routines toolbar and cards", async () => {
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const greeting = screen.getByText("Good morning.");
    const brief = screen.getByText("COMMA-151 summary");
    const routines = screen.getByRole("heading", { name: "Routines" });
    const card = screen.getByRole("heading", { name: "Document" });

    expect(greeting.compareDocumentPosition(brief)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(brief.compareDocumentPosition(routines)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(routines.compareDocumentPosition(card)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    const routinesControl = screen.getByRole("button", {
      name: "Customize routines",
    });
    const refreshControl = screen.getByRole("button", { name: "Refresh" });
    expect(routinesControl).toHaveClass(
      "comma-icon-button",
      "size-7",
      "p-xs",
      "text-sidebar-icon-primary"
    );
    expect(routinesControl.querySelector("svg")).toHaveClass("comma-input-icon");
    expect(routinesControl).toHaveAttribute("data-no-press-feedback");
    expect(refreshControl).toHaveAttribute("data-no-press-feedback");
    expect(refreshControl).toHaveClass(
      "comma-icon-button",
      "size-7",
      "p-xs",
      "text-sidebar-icon-primary"
    );
    expect(refreshControl).toHaveAttribute("aria-label", "Refresh");
    expect(refreshControl).not.toHaveTextContent("Refresh");
    expect(refreshControl.querySelector("[data-comma-icon]")).toHaveClass(
      "comma-input-icon"
    );
    expect(refreshControl.compareDocumentPosition(routinesControl)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(
      routinesControl
        .closest(".comma-recommendations-heading")
        ?.querySelectorAll("button, a")
    ).toHaveLength(2);
    fireEvent.click(routinesControl);
    expect(document.querySelector('[data-slot="menu-popover"]')).toHaveClass(
      "comma-routines-popover"
    );
    expect(screen.queryByRole("menuitem", { name: "Refresh" })).not.toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Routines settings" })).toHaveAttribute(
      "href",
      "/#/settings?category=recommendations"
    );
    expect(
      screen
        .getByRole("menuitem", { name: "Routines settings" })
        .querySelector('[data-slot="menu-item-icon"]')
    ).toBeNull();
  });

  it("shows product logos and lets a routine be hidden and shown from the panel", async () => {
    script();
    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const documentHeading = screen.getByRole("heading", { name: "Document" });
    expect(
      documentHeading.parentElement?.querySelector(
        '.comma-recommendation-card-logo svg[data-provider-logo="linear"]'
      )
    ).toBeInTheDocument();
    expect(
      container.querySelectorAll(".comma-recommendation-card-heading")
    ).toHaveLength(2);

    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    expect(
      screen.getByRole("button", { name: "Reorder Document" })
    ).toBeInTheDocument();
    const visibility = screen.getByRole("button", {
      name: /Document visibility$/,
    });
    fireEvent.click(visibility);
    await flush();
    fireEvent.click(screen.getByRole("option", { name: "Hidden" }));

    await flush();
    expect(
      [...container.querySelectorAll(".comma-recommendation-card h3")].map(
        (heading) => heading.textContent
      )
    ).not.toContain("Document");
    expect(
      screen.getByRole("button", { name: /Document visibility$/ })
    ).toHaveTextContent("Hidden");

    fireEvent.click(screen.getByRole("button", { name: /Document visibility$/ }));
    await flush();
    fireEvent.click(screen.getByRole("option", { name: "Show" }));
    await flush();
    expect(
      [...container.querySelectorAll(".comma-recommendation-card h3")].map(
        (heading) => heading.textContent
      )
    ).toContain("Document");
  });

  it("keeps a routine row dragged past the list end pinned to the last slot", async () => {
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));

    const rows = [
      ...document.querySelectorAll<HTMLElement>(".comma-routines-card-row"),
    ];
    expect(rows.map((row) => row.textContent)).toEqual([
      expect.stringContaining("Document"),
      expect.stringContaining("News"),
    ]);
    // Keep jsdom's shared capability set unchanged. This regression alone
    // exercises the FLIP animation path, so only its routine rows receive the
    // minimal Web Animations surface used by the drag implementation.
    rows.forEach((row) => {
      Object.defineProperties(row, {
        animate: {
          configurable: true,
          value: vi.fn(() => ({ cancel: vi.fn() }) as unknown as Animation),
        },
        getAnimations: {
          configurable: true,
          value: vi.fn(() => []),
        },
      });
    });
    const rowHeight = 28;
    const rowRect = (top: number) =>
      ({
        bottom: top + rowHeight,
        height: rowHeight,
        left: 0,
        right: 320,
        toJSON: () => ({}),
        top,
        width: 320,
        x: 0,
        y: top,
      }) as DOMRect;
    rows.forEach((row, index) => {
      vi.spyOn(row, "getBoundingClientRect").mockImplementation(() =>
        rowRect(100 + index * rowHeight)
      );
    });
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      callback(performance.now());
      return 0;
    });

    const dragHitArea = rows[0]!.querySelector<HTMLElement>(
      ".comma-routines-card-drag-hit-area"
    )!;
    fireEvent.pointerDown(dragHitArea, {
      button: 0,
      clientY: 114,
      isPrimary: true,
      pointerId: 7,
      pointerType: "mouse",
    });
    fireEvent.pointerMove(dragHitArea, {
      clientY: 614,
      isPrimary: true,
      pointerId: 7,
      pointerType: "mouse",
    });

    // A drag 500px past the list must keep the row at the last slot plus at
    // most the damped overshoot cap; unbounded translation opens an
    // ever-growing empty scroll region.
    expect(rows[0]).toHaveAttribute("data-pointer-dragging", "true");
    const draggedTranslate = Number(
      /translate3d\(0, (-?[\d.]+)px, 0\)/.exec(rows[0]!.style.transform)?.[1]
    );
    expect(draggedTranslate).toBeGreaterThanOrEqual(rowHeight);
    expect(draggedTranslate).toBeLessThanOrEqual(rowHeight + routineDragOverdragCap);
    expect(rows[1]).toHaveAttribute("data-routine-drag-shift", "up");

    fireEvent.pointerUp(dragHitArea, {
      clientY: 614,
      isPrimary: true,
      pointerId: 7,
      pointerType: "mouse",
    });

    await flush();
    expect(
      [...document.querySelectorAll<HTMLElement>(".comma-routines-card-row")].map(
        (row) => row.textContent
      )
    ).toEqual([expect.stringContaining("News"), expect.stringContaining("Document")]);
  });

  it("autoscrolls a held routine row the same distance by a moment whatever the frame rate before it", async () => {
    // A row is lifted and held near the bottom of the list; 400ms after the
    // hold began, the list has scrolled the same way at 60fps, at 10fps, and
    // with one frame straight at 400ms.
    const scrolledAt400ms = async (frameMs: number) => {
      script();
      const view = render(
        <Rail
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={vi.fn()}
          workspaceId="wsp_1"
        />
      );
      await flush();
      fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
      const rows = [
        ...document.querySelectorAll<HTMLElement>(".comma-routines-card-row"),
      ];
      rows.forEach((row, index) => {
        Object.defineProperties(row, {
          animate: {
            configurable: true,
            value: vi.fn(() => ({ cancel: vi.fn() }) as unknown as Animation),
          },
          getAnimations: { configurable: true, value: vi.fn(() => []) },
        });
        vi.spyOn(row, "getBoundingClientRect").mockImplementation(() =>
          DOMRect.fromRect({ x: 0, y: 100 + index * 28, width: 320, height: 28 })
        );
      });
      const viewport = document.querySelector<HTMLElement>(
        ".comma-routines-card-scroll [data-slot='scroll-area-viewport']"
      )!;
      vi.spyOn(viewport, "getBoundingClientRect").mockImplementation(() =>
        DOMRect.fromRect({ x: 0, y: 100, width: 320, height: 200 })
      );
      Object.defineProperty(viewport, "scrollHeight", {
        configurable: true,
        value: 2_000,
      });
      Object.defineProperty(viewport, "clientHeight", {
        configurable: true,
        value: 200,
      });
      viewport.scrollTop = 0;

      const clock = createVirtualUiClock({ frameMs });
      const restore = installUiClock(clock);
      try {
        const hitArea = rows[0]!.querySelector<HTMLElement>(
          ".comma-routines-card-drag-hit-area"
        )!;
        const pointer = { isPrimary: true, pointerId: 7, pointerType: "mouse" };
        fireEvent.pointerDown(hitArea, { ...pointer, button: 0, clientY: 114 });
        fireEvent.pointerMove(hitArea, { ...pointer, clientY: 280 });
        act(() => clock.advance(150));
        fireEvent.pointerMove(hitArea, { ...pointer, clientY: 295 });
        act(() => clock.advance(250));
        return viewport.scrollTop;
      } finally {
        restore();
        view.unmount();
      }
    };
    // Frames every 16ms land on 400ms exactly; 1000/60 does not add up to it.
    const at60fps = await scrolledAt400ms(16);
    expect(at60fps).toBeGreaterThan(0);
    expect(await scrolledAt400ms(100)).toBe(at60fps);
    // One frame, at 400ms: straight to the moment.
    expect(await scrolledAt400ms(400)).toBe(at60fps);
  });

  it("uses the Gmail brand logo for Gmail routine sources", () => {
    const gmailCard = {
      ...recommendationSnapshot().cards[0],
      sourceIds: ["gmail-account"],
      title: "Gmail",
    } as RecommendationCard;
    const { container } = render(
      <RecommendationCardView
        card={gmailCard}
        onAction={vi.fn()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        sources={[
          {
            appId: "gmail",
            appName: "Gmail",
            connectionId: "gmail-account",
            enabled: true,
            iconUrl: "https://cdn.example.test/legacy-gmail-icon.svg",
            kind: "composio",
            label: "Gmail",
          },
        ]}
      />
    );

    expect(
      container.querySelector(
        '.comma-recommendation-card-logo svg[data-provider-logo="gmail"]'
      )
    ).toBeInTheDocument();
    expect(container.querySelector(".comma-recommendation-card-logo img")).toBeNull();
  });

  it("uses the canonical Google Calendar name in the card and routines panel", async () => {
    const baseSnapshot = recommendationSnapshot();
    const baseCard = baseSnapshot.cards.find((card) => card.template === "text-list@1");
    expect(baseCard).toBeDefined();
    const snapshot: RecommendationSnapshot = {
      ...baseSnapshot,
      cards: [
        {
          ...baseCard!,
          sourceIds: ["google-calendar-account"],
          title: "Googlecaleandar",
        },
      ],
    };
    script({
      shown: {
        envelope: envelope(snapshot, [
          {
            appId: "google-calendar",
            appName: "Google Calendar",
            connectionId: "google-calendar-account",
            enabled: true,
            kind: "composio",
            label: "Google Calendar",
          },
        ]),
      },
    });
    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(
      screen.getByRole("heading", { name: "Google Calendar" })
    ).toBeInTheDocument();
    expect(screen.queryByText("Googlecaleandar")).not.toBeInTheDocument();
    expect(
      container.querySelector(
        '.comma-recommendation-card-logo svg[data-provider-logo="google-calendar"]'
      )
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    const calendarRow = screen.getByRole("row", { name: "Google Calendar" });
    expect(calendarRow).toBeInTheDocument();
    expect(
      calendarRow.querySelector('svg[data-provider-logo="google-calendar"]')
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Reorder Google Calendar" })
    ).toBeInTheDocument();
  });

  it("resets temporary routine visibility when a new snapshot arrives", async () => {
    const nextSnapshot = {
      ...recommendationSnapshot(),
      generatedAt: 2,
      generation: 2,
    };
    // An accepted refresh: the core takes the briefing it answers with.
    script({
      shown: { envelope: envelope() },
      refresh: () => {
        core.say({ envelope: envelope(nextSnapshot) });
        return { rateLimited: false };
      },
    });

    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    fireEvent.click(screen.getByRole("button", { name: /Document visibility$/ }));
    await flush();
    fireEvent.click(screen.getByRole("option", { name: "Hidden" }));
    await flush();
    expect(container.querySelector(".comma-recommendation-card h3")).toHaveTextContent(
      "News"
    );

    fireEvent.click(
      screen.getByRole("button", { name: "Customize routines", hidden: true })
    );
    await flush();
    expect(
      screen.queryByRole("dialog", { name: "Customize routines" })
    ).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));

    await flush();
    expect(screen.getByRole("heading", { name: "Document" })).toBeInTheDocument();
  });

  it("preserves every summary paragraph after the greeting", async () => {
    const snapshot = recommendationSnapshot();
    snapshot.summary = [
      {
        kind: "markdown",
        text: "Good morning.\n\nFirst brief paragraph.\n\nSecond brief paragraph.",
      },
    ];

    script({ shown: { envelope: envelope(snapshot) } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByText("First brief paragraph.")).toBeInTheDocument();
    expect(screen.getByText("Second brief paragraph.")).toBeInTheDocument();
  });

  it("does not promote an oversized legacy summary paragraph to the title", async () => {
    const oversized =
      "GitHub: 3 unread notifications to review, including PR #884 for Comma Center recommendations.";
    const snapshot = {
      ...recommendationSnapshot(),
      summary: [
        {
          kind: "markdown" as const,
          text: `${oversized}\n\nLinear has two issues to review.`,
        },
      ],
    };

    script({ shown: { envelope: envelope(snapshot) } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Your briefing" })).toBeInTheDocument();
    expect(screen.getByText(oversized)).toBeInTheDocument();
  });

  it("omits a removed template from the production rail", async () => {
    const snapshot = {
      ...recommendationSnapshot(),
      cards: [
        {
          fallbackText: "Review unread GitHub notifications.",
          id: "legacy-rich-list",
          items: [],
          sourceIds: ["github-account"],
          template: "rich-list@1",
          title: "GitHub: unread notifications",
        } as unknown as RecommendationCard,
      ],
    };

    script({ shown: { envelope: envelope(snapshot) } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Routines" })).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "GitHub: unread notifications" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("Review unread GitHub notifications.")
    ).not.toBeInTheDocument();
  });

  it("stages a send_to_comma action in the composer instead of sending", async () => {
    const usePrompt = vi.fn();
    const confirmSpy = vi.spyOn(window, "confirm");
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const footerAction = screen.getByRole("button", {
      name: "Summarize the report",
    });
    expect(footerAction.querySelector("svg[data-comma-icon]")).toBeInTheDocument();
    fireEvent.click(footerAction);
    expect(confirmSpy).not.toHaveBeenCalled();
    // The card reads one source, which marks the staged prompt.
    expect(usePrompt).toHaveBeenCalledWith({
      source: linear,
      sourceUrl: undefined,
      text: "Summarize the latest report",
    });
  });

  it("asks Comma for help with the member's own task in the app language", async () => {
    const url = "https://comma.slack.com/archives/C1/p1";
    const memberTask = (label: string, objective: string) => {
      const snapshot = recommendationSnapshot();
      const card = snapshot.cards[0]!;
      return {
        ...snapshot,
        cards: [
          {
            ...card,
            items: [
              {
                action: {
                  label,
                  memberTask: true as const,
                  prompt: `${objective}\n\n${url}`,
                  requiresConfirmation: true as const,
                  sourceId: "slack-account",
                  sourceUrl: url,
                  type: "send_to_comma" as const,
                },
                id: "member-task",
                parts: [{ kind: "markdown" as const, text: objective }],
              },
            ],
          },
        ],
      };
    };
    const slack: RecommendationSource = {
      appId: "slack",
      appName: "Slack",
      connectionId: "slack-account",
      enabled: true,
      kind: "composio",
      label: "Slack",
    };
    const usePrompt = vi.fn();
    script({
      shown: {
        envelope: envelope(
          memberTask("Use prompt", "Decide whether to merge PR #2071"),
          [linear, slack]
        ),
      },
    });
    const english = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );
    await flush();
    fireEvent.click(screen.getByRole("button", { name: "Use prompt" }));
    // The task's own source marks it and is the item opened after the send.
    expect(usePrompt).toHaveBeenLastCalledWith({
      source: slack,
      sourceUrl: url,
      text: `Help me decide whether to merge PR #2071\n\n${url}`,
    });
    english.unmount();

    script({
      shown: { envelope: envelope(memberTask("填入输入框", "决定是否合并 PR #2071")) },
    });
    render(
      <CommaI18nProvider locale="zh-CN">
        <Rail
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={usePrompt}
          workspaceId="wsp_1"
        />
      </CommaI18nProvider>
    );
    await flush();
    fireEvent.click(screen.getByRole("button", { name: "填入输入框" }));
    expect(usePrompt).toHaveBeenLastCalledWith(
      expect.objectContaining({ text: `帮我决定是否合并 PR #2071\n\n${url}` })
    );
  });

  it("executes a media row action from the whole row", async () => {
    const usePrompt = vi.fn();

    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    await flush();
    fireEvent.click(screen.getByText("Release brief"));
    expect(usePrompt).toHaveBeenCalledWith(
      expect.objectContaining({ text: "Open the release brief" })
    );
  });

  it("does not hand remote recommendation media URLs to the renderer", async () => {
    script();
    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(screen.getByText("Release brief")).toBeInTheDocument();
    expect(
      container.querySelector('img[src="https://example.com/release.png"]')
    ).toBeNull();
    expect(screen.getByRole("button", { name: /Release/ })).toHaveAttribute(
      "data-has-image",
      "false"
    );
    expect(loadRecommendationMediaMock).toHaveBeenCalledWith(
      "https://example.com/release.png",
      { signal: expect.any(AbortSignal) }
    );
  });

  it("renders controlled recommendation media through a revocable blob URL", async () => {
    loadRecommendationMediaMock.mockResolvedValue({
      bytes: new Uint8Array([137, 80, 78, 71]),
      mediaType: "image/png",
      status: "ready",
    });
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:recommendation-media");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    script();
    const { container, unmount } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    expect(container.querySelector("img")).toHaveAttribute(
      "src",
      "blob:recommendation-media"
    );
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: /Release/ })).toHaveAttribute(
      "data-has-image",
      "true"
    );

    unmount();
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:recommendation-media");
  });

  it("executes a text row action while keeping rich inline actions independent", async () => {
    const openTask = vi.fn();
    const usePrompt = vi.fn();

    script();
    render(
      <Rail
        onOpenTask={openTask}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    await flush();
    fireEvent.click(screen.getByRole("button", { name: "Review COMMA-143" }));
    expect(usePrompt).toHaveBeenCalledWith(
      expect.objectContaining({ text: "Review COMMA-143" })
    );
    expect(openTask).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "COMMA-143" }));
    expect(openTask).toHaveBeenCalledWith("cnv_private_task_identity");
    expect(usePrompt).toHaveBeenCalledTimes(1);
  });

  it("omits redundant row logos while retaining provider identity on task references", async () => {
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const inlineLink = screen.getByRole("button", { name: "Open report" });
    expect(inlineLink).toHaveClass("comma-recommendation-inline-link");
    expect(
      inlineLink.querySelector('svg[data-provider-logo="linear"]')
    ).not.toBeInTheDocument();

    const inlineTask = screen.getByRole("button", { name: "COMMA-143" });
    expect(inlineTask).toHaveClass("comma-recommendation-inline-source");
    expect(
      inlineTask.querySelector('svg[data-provider-logo="linear"]')
    ).toBeInTheDocument();
  });

  it("keeps partial-source warnings and a stale briefing out of the UI", async () => {
    script({
      shown: {
        envelope: envelope(
          {
            ...recommendationSnapshot(),
            warnings: [
              {
                code: "partial_sources" as const,
                message: "Notion was temporarily unavailable.",
                sourceIds: ["notion-account"],
              },
            ],
          },
          [linear],
          "stale"
        ),
      },
    });

    const { container } = render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    // The previous briefing stays on screen without a problem notice.
    await flush();
    expect(container.querySelector(".comma-recommendations")).toHaveAttribute(
      "data-state",
      "stale"
    );
    expect(container.querySelector(".comma-recommendations-scroll")).not.toBeNull();
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
    expect(screen.queryByTestId("routine-warning-toast")).not.toBeInTheDocument();
    expect(screen.queryByText("Notion was temporarily unavailable.")).toBeNull();
  });

  it("answers a right-click on a greeting inline link with the chat link menu", async () => {
    const onOpenUrl = vi.fn();
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={onOpenUrl}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await flush();
    const inlineLink = screen.getByRole("button", { name: "COMMA-151 summary" });
    expect(inlineLink.closest(".comma-recommendations-summary")).toBeInTheDocument();

    fireEvent.contextMenu(inlineLink, { clientX: 120, clientY: 80 });

    await flush();
    const menu = screen.getByRole("menu", { name: "Link menu" });
    // The same items chat offers, minus the one that has no meaning here:
    // a briefing link sits in prose, not in a message.
    expect(
      within(menu)
        .getAllByRole("menuitem")
        .map((item) => item.textContent)
    ).toEqual(["Open in External Browser", "Open in Comma", "Copy Link"]);

    fireEvent.click(within(menu).getByRole("menuitem", { name: "Copy Link" }));
    expect(nativePlatform.writeText).toHaveBeenCalledWith(
      "https://linear.app/comma/issue/COMMA-151"
    );
    // A right-click must not also follow the link the way a left-click does.
    expect(onOpenUrl).not.toHaveBeenCalled();
  });

  it("opens a briefing link in Comma or the external browser from the link menu", async () => {
    const onOpenUrl = vi.fn();
    script();
    const props = {
      onOpenTask: vi.fn(),
      onOpenUrl,
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const { rerender } = render(<Rail {...props} />);

    await flush();
    const inlineLink = screen.getByRole("button", { name: "COMMA-151 summary" });
    fireEvent.contextMenu(inlineLink, { clientX: 120, clientY: 80 });
    await flush();
    fireEvent.click(
      within(screen.getByRole("menu", { name: "Link menu" })).getByRole("menuitem", {
        name: "Open in Comma",
      })
    );
    expect(onOpenUrl).toHaveBeenCalledWith("https://linear.app/comma/issue/COMMA-151");

    rerender(<Rail {...props} />);
    await flush();
    fireEvent.contextMenu(screen.getByRole("button", { name: "COMMA-151 summary" }), {
      clientX: 120,
      clientY: 80,
    });
    await flush();
    fireEvent.click(
      within(screen.getByRole("menu", { name: "Link menu" })).getByRole("menuitem", {
        name: "Open in External Browser",
      })
    );
    expect(nativePlatform.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://linear.app/comma/issue/COMMA-151"
    );
  });

  it("stages a summary task link's prompt and opens a plain summary link", async () => {
    const issueUrl = "https://linear.app/comma/issue/COMMA-152";
    const snapshot = recommendationSnapshot();
    snapshot.summary = [
      ...snapshot.summary,
      {
        kind: "inline-link" as const,
        link: {
          href: issueUrl,
          label: "Linear source",
          previewText: "Determinism failed (attempt 1)",
          sourceId: "linear-account",
          taskPrompt: `Investigate the determinism failure\n\n${issueUrl}`,
        },
      },
    ];
    const usePrompt = vi.fn();
    const onOpenUrl = vi.fn();
    script({ shown: { envelope: envelope(snapshot) } });
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={onOpenUrl}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );
    await flush();

    // A link that names the member's task stages it, as the task's row does.
    fireEvent.click(screen.getByRole("button", { name: "Linear source" }));
    expect(usePrompt).toHaveBeenCalledWith({
      source: linear,
      sourceUrl: issueUrl,
      text: `Help me investigate the determinism failure\n\n${issueUrl}`,
    });
    expect(onOpenUrl).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "COMMA-151 summary" }));
    expect(onOpenUrl).toHaveBeenCalledWith("https://linear.app/comma/issue/COMMA-151");
  });

  it("leaves briefing text alone and exposes Task archive actions on task chips", async () => {
    script();
    render(
      <Rail
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />,
      true
    );

    await flush();
    const heading = screen.getByRole("heading", { name: "Good morning." });
    const headingEvent = createEvent.contextMenu(heading, { clientX: 8, clientY: 8 });
    fireEvent(heading, headingEvent);
    expect(headingEvent.defaultPrevented).toBe(false);

    // Task chips now expose the shared Archive action; link menus stay separate.
    const taskChip = screen.getByRole("button", { name: "COMMA-143" });
    const taskEvent = createEvent.contextMenu(taskChip, { clientX: 8, clientY: 8 });
    fireEvent(taskChip, taskEvent);
    expect(taskEvent.defaultPrevented).toBe(true);

    expect(screen.queryByRole("menu", { name: "Link menu" })).not.toBeInTheDocument();
  });
});

describe("linked mail Tasks", () => {
  for (const status of ["active", "completed"] as const) {
    it(
      "keeps the canonical Task action and respects " + status + " state",
      async () => {
        const snapshot = recommendationSnapshot();
        snapshot.cards = [
          {
            id: "mail",
            title: "Gmail",
            template: "text-list@1",
            fallbackText: "Follow up",
            sourceIds: ["gmail-account"],
            items: [
              {
                id: "mail-task",
                parts: [
                  {
                    kind: "inline-task",
                    task: {
                      conversationId: "cnv_private_task_identity",
                      label: "Follow up on contract",
                      sourceId: "gmail-account",
                    },
                  },
                ],
                action: {
                  type: "open_url",
                  label: "Open mail",
                  href: "https://mail.google.com/mail/#inbox/m1",
                  requiresConfirmation: false,
                },
              },
            ],
          },
        ];
        const onOpenTask = vi.fn();
        const onUsePrompt = vi.fn();
        script({ shown: { envelope: envelope(snapshot) } });
        render(
          <Rail
            workspaceId="wsp_1"
            onOpenTask={onOpenTask}
            onOpenUrl={vi.fn()}
            onUsePrompt={onUsePrompt}
          />,
          true,
          status
        );
        await flush();
        expect(screen.getByRole("heading", { name: "Gmail" })).toBeInTheDocument();
        if (status === "active") {
          await flush();
          const targets = screen.getAllByRole("button", {
            name: "Follow up on contract",
          });
          fireEvent.click(targets[0]!);
          expect(onOpenTask).toHaveBeenCalledWith("cnv_private_task_identity");
        } else {
          expect(
            screen.queryByRole("button", { name: "Follow up on contract" })
          ).not.toBeInTheDocument();
          expect(
            screen.queryByRole("button", { name: "Open mail" })
          ).not.toBeInTheDocument();
        }
        expect(onUsePrompt).not.toHaveBeenCalled();
      }
    );
  }
});

function recommendationSnapshot(): RecommendationSnapshot {
  return {
    cards: [
      {
        fallbackText: "Review COMMA-143 and open the report.",
        footerAction: {
          label: "Summarize the report",
          prompt: "Summarize the latest report",
          requiresConfirmation: true as const,
          type: "send_to_comma" as const,
        },
        id: "document",
        items: [
          {
            action: {
              label: "Review COMMA-143",
              prompt: "Review COMMA-143",
              requiresConfirmation: false as const,
              type: "open_task_form" as const,
            },
            id: "task",
            parts: [
              { kind: "markdown" as const, text: "Review " },
              {
                kind: "inline-task" as const,
                task: {
                  conversationId: "cnv_private_task_identity",
                  label: "COMMA-143",
                  sourceId: "linear-account",
                },
              },
            ],
          },
          {
            action: {
              href: "https://example.com/report",
              label: "Open report row",
              requiresConfirmation: false as const,
              type: "open_url" as const,
            },
            id: "report",
            parts: [
              {
                kind: "inline-link" as const,
                link: {
                  href: "https://example.com/report",
                  label: "Open report",
                  sourceId: "linear-account",
                },
              },
            ],
          },
        ],
        sourceIds: ["linear-account"],
        template: "text-list@1" as const,
        title: "Document",
      },
      {
        fallbackText: "Release brief",
        id: "news",
        items: [
          {
            action: {
              label: "Open release brief",
              prompt: "Open the release brief",
              requiresConfirmation: false as const,
              type: "open_task_form" as const,
            },
            description: "Everything that changed in today's release.",
            id: "release-brief",
            imageUrl: "https://example.com/release.png",
            title: "Release brief",
          },
        ],
        sourceIds: ["news-account"],
        template: "media-list@1" as const,
        title: "News",
      },
    ],
    generatedAt: 1,
    generation: 1,
    protocolVersion: 1 as const,
    sourceRevision: 1,
    summary: [
      { kind: "markdown" as const, text: "Good morning.\n\nReview " },
      {
        kind: "inline-link" as const,
        link: {
          href: "https://linear.app/comma/issue/COMMA-151",
          label: "COMMA-151 summary",
          sourceId: "linear-account",
        },
      },
      { kind: "markdown" as const, text: " before standup." },
    ],
    templateCatalogVersion: 1,
    warnings: [],
  };
}

function FixtureDemand() {
  useProductInboxProjection({ enabled: true });
  return null;
}
/** The core of the rail rendered next (`script` makes another). */
let core: ReturnType<typeof railCore>;

// Routine problems are toasts, so the toast surface renders beside the rail.
function render(element: ReactNode, withTaskFacts = false, taskStatus = "completed") {
  const tree = (
    <>
      {element}
      <Toaster />
    </>
  );
  if (!withTaskFacts)
    return renderBase(tree, { wrapper: ({ children }) => core.wrap(children) });
  // The task list is the harness's; the rest is the rail's core.
  const projection = createProductInboxProjectionHarness({
    initial: {
      activeWorkspaceId: "wsp_1",
      source: "live-sync",
      workspaces: [{ id: "wsp_1", group_id: "grp_1", name: "Workspace" }],
      items: ["cnv_reply", "cnv_private_task_identity"].map((id) => ({
        id,
        conversationId: id,
        groupId: "grp_1",
        workspaceId: "wsp_1",
        workspaceName: "Workspace",
        title: id,
        archiveAvailability: { allowed: true, reason: null },
        archiveVersion: 1,
        kind: "agent_task" as const,
        status: taskStatus,
        updatedAt: 1,
        source: "salix.conversation" as const,
      })),
    },
  });
  delegateScriptedCore(projection.controller, core.client);
  return renderBase(tree, {
    wrapper: ({ children }) => (
      <CoreProvider client={projection.controller}>
        <FixtureDemand />
        {children}
      </CoreProvider>
    ),
  });
}
