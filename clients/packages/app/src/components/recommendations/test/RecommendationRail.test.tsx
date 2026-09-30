import type { ReactNode } from "react";
import {
  ProductInboxProjectionProvider,
  useProductInboxProjection,
} from "../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  testProductLease,
} from "../../../test/productInboxProjectionHarness";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import {
  act,
  createEvent,
  fireEvent,
  render as renderBase,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import type {
  RecommendationCard,
  RecommendationSnapshot,
  RecommendationSource,
} from "@comma/recommendation-contract";
import { recommendationGeneratedCardSchema } from "@comma/recommendation-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GmailProviderLogo, PuzzleIcon, Toaster, toast } from "@comma/ui";
import { CommaApiError, type CommaApiClient } from "../../../api";
import {
  RecommendationCardView,
  RecommendationDocument,
  RecommendationLinkPreviewProvider,
  RecommendationRail,
  RecommendationSummary,
  boundRoutineDragTranslation,
  briefingGreeting,
  deliveryReloadGraceMs,
  msUntilDailyDelivery,
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

vi.mock("../../../runtime-chat/nativePlatformActions", () => ({
  nativePlatformClipboard: { writeText: nativePlatform.writeText },
  openNativePlatformExternalUrl: nativePlatform.openNativePlatformExternalUrl,
}));

afterEach(() => {
  act(() => toast.dismissAll());
  vi.restoreAllMocks();
  vi.useRealTimers();
  initializeCommaI18n(["en"]);
});
beforeEach(() => {
  // Announced Routine problems belong to one window session.
  sessionStorage.clear();
  nativePlatform.openNativePlatformExternalUrl.mockReset();
  nativePlatform.writeText.mockReset();
  loadRecommendationMediaMock.mockReset();
  loadRecommendationMediaMock.mockResolvedValue({ status: "unavailable" });
});

function api(
  snapshot = recommendationSnapshot(),
  sources: RecommendationSource[] = [
    {
      appId: "linear",
      appName: "Linear",
      connectionId: "linear-account",
      enabled: true,
      kind: "composio" as const,
      label: "Linear",
    },
  ]
): CommaApiClient {
  return {
    getRecommendations: vi.fn().mockResolvedValue({
      settings: {
        autoEnableNewSources: true,
        sourcesCheckedAt: "2026-08-14T00:00:00Z",
        schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
        sourceRevision: 1,
        sources,
      },
      snapshot,
      state: "fresh",
    }),
    refreshRecommendations: vi.fn(),
  } as unknown as CommaApiClient;
}

function apiWithoutSnapshot(
  hasEnabledSource: boolean,
  state: "empty" | "refreshing" | "error" = "empty"
): CommaApiClient {
  return {
    getRecommendations: vi.fn().mockResolvedValue({
      settings: {
        autoEnableNewSources: true,
        sourcesCheckedAt: "2026-08-14T00:00:00Z",
        schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
        sourceRevision: 1,
        sources: hasEnabledSource
          ? [
              {
                appId: "github",
                appName: "GitHub",
                connectionId: "github-account",
                enabled: true,
                kind: "mcp" as const,
                label: "github",
              },
            ]
          : [],
      },
      snapshot: null,
      state,
    }),
    refreshRecommendations: vi.fn(),
  } as unknown as CommaApiClient;
}

const withStableMaskIds = (markup: string | undefined) =>
  markup?.replaceAll(/[a-z-]*provider-logo-[^")]+/g, "provider-logo");

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
    const pausedApi = api();
    render(
      <RecommendationRail
        active={false}
        api={pausedApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await Promise.resolve();
    expect(pausedApi.getRecommendations).not.toHaveBeenCalled();
  });

  it("reports the UI language so the briefing is generated in it", async () => {
    const localeApi = api();
    const { rerender } = render(
      <CommaI18nProvider locale="en">
        <RecommendationRail
          api={localeApi}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={vi.fn()}
          workspaceId="wsp_1"
        />
      </CommaI18nProvider>
    );

    await waitFor(() => expect(localeApi.getRecommendations).toHaveBeenCalled());
    expect(localeApi.getRecommendations).toHaveBeenLastCalledWith(
      "wsp_1",
      expect.objectContaining({ locale: "en" })
    );

    // Switching the language has to refetch: that request is what re-pins the
    // renderer's output language for the next briefing.
    rerender(
      <CommaI18nProvider locale="zh-CN">
        <RecommendationRail
          api={localeApi}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={vi.fn()}
          workspaceId="wsp_1"
        />
      </CommaI18nProvider>
    );

    await waitFor(() =>
      expect(localeApi.getRecommendations).toHaveBeenLastCalledWith(
        "wsp_1",
        expect.objectContaining({ locale: "zh-CN" })
      )
    );
  });

  it("does not re-render recommendation documents when its stable props are repeated", async () => {
    const recommendationApi = api();
    const parse = vi.spyOn(recommendationGeneratedCardSchema, "safeParse");
    const props = {
      api: recommendationApi,
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const { rerender } = render(<RecommendationRail {...props} />);

    await screen.findByRole("heading", { name: "Good morning." });
    const initialParseCount = parse.mock.calls.length;
    expect(initialParseCount).toBeGreaterThan(0);

    rerender(<RecommendationRail {...props} />);

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
    render(
      <RecommendationRail
        api={apiWithoutSnapshot(true)}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(
      await screen.findByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    expect(screen.queryByText("No routines created yet")).not.toBeInTheDocument();
  });

  it("shows the server-owned generating state and keeps duplicate refresh disabled", async () => {
    render(
      <RecommendationRail
        api={apiWithoutSnapshot(true, "refreshing")}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("Generating your briefing…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    expect(screen.getByRole("dialog", { name: "Customize routines" })).toHaveAttribute(
      "data-has-cards",
      "false"
    );
    expect(screen.queryByRole("menuitem", { name: "Refresh" })).not.toBeInTheDocument();
  });

  it("keeps observing a server-owned run after mount until it becomes terminal", async () => {
    const refreshingApi = apiWithoutSnapshot(true, "refreshing");
    vi.mocked(refreshingApi.getRecommendations)
      .mockResolvedValueOnce(
        await apiWithoutSnapshot(true, "refreshing").getRecommendations("wsp_1", {
          timezone: "UTC",
        })
      )
      .mockResolvedValueOnce(
        await apiWithoutSnapshot(true, "error").getRecommendations("wsp_1", {
          timezone: "UTC",
        })
      );

    render(
      <RecommendationRail
        api={refreshingApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("Generating your briefing…")).toBeInTheDocument();
    expect(
      await screen.findByText(
        "Couldn’t generate your briefing.",
        {},
        { timeout: 3_000 }
      )
    ).toBeInTheDocument();
    expect(refreshingApi.getRecommendations).toHaveBeenCalledTimes(2);
  });

  it("retries a transient polling failure until the server-owned run becomes terminal", async () => {
    const refreshingApi = apiWithoutSnapshot(true, "refreshing");
    vi.mocked(refreshingApi.getRecommendations)
      .mockResolvedValueOnce(
        await apiWithoutSnapshot(true, "refreshing").getRecommendations("wsp_1", {
          timezone: "UTC",
        })
      )
      .mockRejectedValueOnce(new Error("transient 503"))
      .mockResolvedValueOnce(
        await apiWithoutSnapshot(true, "error").getRecommendations("wsp_1", {
          timezone: "UTC",
        })
      );

    render(
      <RecommendationRail
        api={refreshingApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("Generating your briefing…")).toBeInTheDocument();
    expect(
      await screen.findByText(
        "Couldn’t generate your briefing.",
        {},
        { timeout: 6_000 }
      )
    ).toBeInTheDocument();
    expect(refreshingApi.getRecommendations).toHaveBeenCalledTimes(3);
  }, 7_000);

  it("bounds initial source discovery retries and resets them after leaving Home", async () => {
    vi.useFakeTimers();
    const waitingApi = apiWithoutSnapshot(false);
    const waiting = await waitingApi.getRecommendations("wsp_1");
    vi.mocked(waitingApi.getRecommendations)
      .mockClear()
      .mockResolvedValue({
        ...waiting,
        settings: { ...waiting.settings, sourcesCheckedAt: null },
      });
    const props = {
      api: waitingApi,
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const view = render(<RecommendationRail {...props} />);
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(waitingApi.getRecommendations).toHaveBeenCalledTimes(11);
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(waitingApi.getRecommendations).toHaveBeenCalledTimes(11);
    view.rerender(<RecommendationRail {...props} active={false} />);
    view.rerender(<RecommendationRail {...props} active />);
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(waitingApi.getRecommendations).toHaveBeenCalledTimes(22);
  });

  it("keeps polling after a manual refresh enters a server-owned run and the first poll fails", async () => {
    vi.useFakeTimers();
    const manualRefreshApi = apiWithoutSnapshot(true);
    const refreshingEnvelope = await apiWithoutSnapshot(
      true,
      "refreshing"
    ).getRecommendations("wsp_1", { timezone: "UTC" });
    const terminalEnvelope = await apiWithoutSnapshot(true, "error").getRecommendations(
      "wsp_1",
      { timezone: "UTC" }
    );
    vi.mocked(manualRefreshApi.getRecommendations)
      .mockResolvedValueOnce(
        await apiWithoutSnapshot(true).getRecommendations("wsp_1", {
          timezone: "UTC",
        })
      )
      .mockRejectedValueOnce(new Error("transient 503"))
      .mockResolvedValueOnce(terminalEnvelope);
    vi.mocked(manualRefreshApi.refreshRecommendations).mockResolvedValue({
      envelope: refreshingEnvelope,
      run: {
        generation: 1,
        id: "rrn_manual",
        sourceRevision: 1,
        status: "running",
        trigger: "manual",
      },
    });

    render(
      <RecommendationRail
        api={manualRefreshApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await act(async () => Promise.resolve());
    expect(
      screen.getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await act(async () => Promise.resolve());

    expect(screen.getByText("Generating your briefing…")).toBeInTheDocument();
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    expect(manualRefreshApi.getRecommendations).toHaveBeenCalledTimes(2);
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    // The toast surface mounts a raised toast on its next tick.
    await act(async () => vi.advanceTimersByTimeAsync(1));

    expect(screen.getByText("Couldn’t generate your briefing.")).toBeInTheDocument();
    expect(manualRefreshApi.getRecommendations).toHaveBeenCalledTimes(3);
    // A failed generation is terminal: no discovery checks keep re-reading it.
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(manualRefreshApi.getRecommendations).toHaveBeenCalledTimes(3);
  });

  it("reports a terminal generation error in a toast, not in the rail", async () => {
    const { container } = render(
      <RecommendationRail
        api={apiWithoutSnapshot(true, "error")}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByTestId("routine-problem-toast")).toHaveTextContent(
      "Couldn’t generate your briefing."
    );
    const rail = container.querySelector<HTMLElement>(".comma-recommendations")!;
    expect(within(rail).queryByText("Couldn’t generate your briefing.")).toBeNull();
    expect(
      within(rail).getByText("Refresh to generate your first briefing.")
    ).toBeInTheDocument();
    expect(screen.queryByText("Routines are unavailable")).not.toBeInTheDocument();
  });

  it.each([
    ["renderer_declined", "Nothing new in your apps to brief today."],
    [
      "member_identity_required",
      "Reconnect your apps in Plugins to verify your personal account.",
    ],
  ] as const)(
    "reads failure class %s into actionable copy",
    async (lastError, copy) => {
      const declinedApi = apiWithoutSnapshot(true, "error");
      const declined = await declinedApi.getRecommendations("wsp_1", {
        timezone: "UTC",
      });
      vi.mocked(declinedApi.getRecommendations).mockResolvedValue({
        ...declined,
        lastError,
      });
      render(
        <RecommendationRail
          api={declinedApi}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={vi.fn()}
          workspaceId="wsp_1"
        />
      );

      expect(await screen.findByText(copy)).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled();
    }
  );

  it("shows the projection as unavailable and keeps the header refresh as the way back", async () => {
    const offlineApi = {
      getRecommendations: vi.fn().mockRejectedValue(new Error("network down")),
      refreshRecommendations: vi.fn().mockRejectedValue(new Error("network down")),
    } as unknown as CommaApiClient;
    render(
      <RecommendationRail
        api={offlineApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByTestId("routine-problem-toast")).toHaveTextContent(
      "Routines are unavailable"
    );
    expect(
      screen.queryByText("Couldn’t generate your briefing.")
    ).not.toBeInTheDocument();
    // An unreadable projection lists no sources, and the header still refreshes.
    const refresh = screen.getByRole("button", { name: "Refresh" });
    expect(refresh).toBeEnabled();
    fireEvent.click(refresh);
    await waitFor(() =>
      expect(offlineApi.refreshRecommendations).toHaveBeenCalledWith("wsp_1")
    );
  });

  it("generates from the moment Refresh is pressed after a failed generation, before the server reports the run", async () => {
    const errorApi = apiWithoutSnapshot(true, "error");
    let finishRefresh: (() => void) | undefined;
    vi.mocked(errorApi.refreshRecommendations).mockImplementation(
      () =>
        new Promise((resolve) => {
          finishRefresh = () =>
            resolve({
              envelope: {
                ...(apiWithoutSnapshot(true, "refreshing") as unknown as {
                  getRecommendations: () => Promise<never>;
                }),
              } as never,
              run: {
                generation: 2,
                id: "rrn_manual",
                sourceRevision: 1,
                status: "pending",
                trigger: "manual",
              },
            });
        })
    );
    render(
      <RecommendationRail
        api={errorApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByTestId("routine-problem-toast");
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    // The refresh request is still collecting sources on the server.
    expect(await screen.findByTestId("recommendations-generating")).toBeInTheDocument();
    await waitFor(() =>
      expect(
        screen.queryByText("Couldn’t generate your briefing.")
      ).not.toBeInTheDocument()
    );
    expect(finishRefresh).toBeDefined();
  });

  it("explains a refused refresh instead of calling routines unavailable", async () => {
    const errorApi = apiWithoutSnapshot(true, "error");
    vi.mocked(errorApi.refreshRecommendations).mockRejectedValue(
      new CommaApiError(429, "rate_limited")
    );
    render(
      <RecommendationRail
        api={errorApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByTestId("routine-problem-toast");
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    expect(
      await screen.findByText("Too many refreshes in the last hour. Try again later.")
    ).toBeInTheDocument();
    expect(screen.queryByText("Routines are unavailable")).not.toBeInTheDocument();
    // The header refresh stays the way to try again.
    expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled();
  });

  it("re-reads the projection when the member returns to the window", async () => {
    vi.useFakeTimers();
    const freshApi = api();
    render(
      <RecommendationRail
        api={freshApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    // A focus that lands while the initial read is still open issues nothing.
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    await act(async () => Promise.resolve());
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(1);

    // Coming straight back is within the revisit interval: no extra read.
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(1);

    await act(async () => vi.advanceTimersByTimeAsync(61_000));
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(2);
  });

  it("re-reads the projection shortly after the daily delivery instant", async () => {
    vi.useFakeTimers();
    // 07:59:30 in Asia/Singapore (UTC+8), thirty seconds before the 08:00 run.
    vi.setSystemTime(new Date("2026-09-11T23:59:30Z"));
    const freshApi = api();
    render(
      <RecommendationRail
        api={freshApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await act(async () => Promise.resolve());
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(1);

    await act(async () =>
      vi.advanceTimersByTimeAsync(30_000 + deliveryReloadGraceMs - 1_000)
    );
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(1);
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    expect(freshApi.getRecommendations).toHaveBeenCalledTimes(2);
  });

  it("stops polling a server-owned run whose projection can no longer be read", async () => {
    // Under fake timers the toast surface is not driven; assert the raised toast.
    const toastError = vi.spyOn(toast, "error");
    vi.useFakeTimers();
    const refreshingApi = apiWithoutSnapshot(true, "refreshing");
    const refreshingEnvelope = await refreshingApi.getRecommendations("wsp_1", {
      timezone: "UTC",
    });
    vi.mocked(refreshingApi.getRecommendations)
      .mockReset()
      .mockResolvedValueOnce(refreshingEnvelope)
      .mockRejectedValue(new Error("projection unreadable"));

    render(
      <RecommendationRail
        api={refreshingApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await act(async () => Promise.resolve());
    expect(screen.getByText("Generating your briefing…")).toBeInTheDocument();

    // Two-second polls fail for longer than any run can live.
    await act(async () => vi.advanceTimersByTimeAsync(100_000));
    expect(toastError).toHaveBeenCalledWith(
      "Routines",
      expect.objectContaining({
        description: "Routines are unavailable",
        testId: "routine-problem-toast",
      })
    );
    const callsAtStop = vi.mocked(refreshingApi.getRecommendations).mock.calls.length;
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(refreshingApi.getRecommendations).toHaveBeenCalledTimes(callsAtStop);
  });

  it("says it is looking for connected apps while the first discovery runs", async () => {
    vi.useFakeTimers();
    const waitingApi = apiWithoutSnapshot(false);
    const waiting = await waitingApi.getRecommendations("wsp_1");
    vi.mocked(waitingApi.getRecommendations)
      .mockReset()
      .mockResolvedValueOnce({
        ...waiting,
        settings: { ...waiting.settings, sourcesCheckedAt: null },
      })
      .mockResolvedValue(waiting);

    render(
      <RecommendationRail
        api={waitingApi}
        onConnectApps={vi.fn()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );
    await act(async () => Promise.resolve());
    expect(screen.getByTestId("recommendations-discovering")).toHaveTextContent(
      "Looking for connected apps…"
    );
    expect(screen.queryByText("No routines created yet")).not.toBeInTheDocument();

    await act(async () => vi.advanceTimersByTimeAsync(1_500));
    expect(screen.getByText("No routines created yet")).toBeInTheDocument();
  });

  it("explains a refused refresh in a toast while the briefing stays", async () => {
    const briefingApi = api();
    vi.mocked(briefingApi.refreshRecommendations).mockRejectedValue(
      new CommaApiError(429, "rate_limited")
    );
    render(
      <RecommendationRail
        api={briefingApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    // The toolbar moves into the briefing scroll area once the snapshot
    // arrives; wait for that render before pressing its Refresh control.
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Refresh" })).toBeEnabled()
    );
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    expect(
      await screen.findByText(
        "Too many refreshes in the last hour. Try again later.",
        {},
        { timeout: 3_000 }
      )
    ).toBeInTheDocument();
    expect(
      screen.queryByText("Couldn’t update routines. Showing the previous briefing.")
    ).not.toBeInTheDocument();
  });

  it("measures the wait until the next daily delivery on the schedule's clock", () => {
    const schedule = { hour: 8, minute: 0, timezone: "Asia/Singapore" };
    // 07:30 Singapore time.
    expect(msUntilDailyDelivery(schedule, Date.parse("2026-09-11T23:30:00Z"))).toBe(
      30 * 60_000
    );
    // 08:00:30 Singapore time: the next delivery is tomorrow.
    expect(msUntilDailyDelivery(schedule, Date.parse("2026-09-11T00:00:30Z"))).toBe(
      86_400_000 - 30_000
    );
    expect(
      msUntilDailyDelivery({ ...schedule, timezone: "Mars/Phobos" }, Date.now())
    ).toBeUndefined();
  });

  it.each([
    ["2026-11-01T04:30:00Z", 8, "2026-11-01T13:00:00Z"],
    ["2026-03-08T05:30:00Z", 8, "2026-03-08T12:00:00Z"],
    // Today's target passed and tomorrow's 02:00 does not exist.
    ["2026-03-07T08:00:00Z", 2, "2026-03-09T06:00:00Z"],
    // There is no 02:00 on the spring-forward day.
    ["2026-03-08T05:30:00Z", 2, "2026-03-09T06:00:00Z"],
    // The second 01:00 is still in the future after the first 01:30.
    ["2026-11-01T05:30:00Z", 1, "2026-11-01T06:00:00Z"],
  ])("uses the next real delivery instant across DST from %s", (now, hour, next) => {
    expect(
      msUntilDailyDelivery(
        { hour, minute: 0, timezone: "America/New_York" },
        Date.parse(now)
      )
    ).toBe(Date.parse(next) - Date.parse(now));
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

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "PR #845" }));
    const preview = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(preview).toHaveTextContent("PR #845");
    expect(preview).toHaveTextContent("GitHub · github.com/AFK-surf/Comma/pull/845");
    expect(preview.querySelector('svg[data-provider-logo="github"]')).not.toBeNull();
  });

  it("upgrades a GitHub pull request link to the pull request card on hover", async () => {
    // Card times are relative within the local day only; pin "now" to a local
    // noon so "6h ago" / "3h ago" cannot roll into "yesterday" on CI.
    vi.spyOn(Date, "now").mockReturnValue(new Date(2026, 7, 22, 12).getTime());
    const previewApi = {
      getRecommendationLinkPreview: vi.fn().mockResolvedValue({
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
    } as unknown as CommaApiClient;
    render(
      <RecommendationLinkPreviewProvider api={previewApi} workspaceId="wsp_1">
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
      </RecommendationLinkPreviewProvider>
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "PR #845" }));
    const card = await screen.findByTestId(
      "recommendation-link-card",
      {},
      { timeout: 3_000 }
    );
    expect(previewApi.getRecommendationLinkPreview).toHaveBeenCalledWith("wsp_1", {
      href: "https://github.com/AFK-surf/Comma/pull/845/",
      sourceId: "github-account",
    });
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
    vi.spyOn(Date, "now").mockReturnValue(new Date(2026, 7, 22, 12).getTime());
    const previewApi = {
      getRecommendationLinkPreview: vi.fn(
        async (_workspaceId: string, link: { href: string }) =>
          link.href.includes("linear.app")
            ? {
                assignee: { avatarUrl: null, name: "zanwei" },
                href: link.href,
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
                href: link.href,
                kind: "google_calendar_event",
                location: "Room 4",
                meetingUrl: "https://meet.google.com/abc-defg-hij",
                organizer: { name: "Dana Wu" },
                startsAt: Date.UTC(2026, 8, 1),
                status: "confirmed",
                title: "Offsite",
                updatedAt: null,
              }
      ),
    } as unknown as CommaApiClient;
    render(
      <RecommendationLinkPreviewProvider api={previewApi} workspaceId="wsp_1">
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
      </RecommendationLinkPreviewProvider>
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "COMMA-143" }));
    const issue = await screen.findByTestId(
      "recommendation-link-card",
      {},
      { timeout: 3_000 }
    );
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
    await waitFor(
      () =>
        expect(screen.getByTestId("recommendation-link-card")).toHaveAttribute(
          "data-kind",
          "google_calendar_event"
        ),
      { timeout: 3_000 }
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
    const previewApi = {
      getRecommendationLinkPreview: vi.fn(),
    } as unknown as CommaApiClient;
    render(
      <RecommendationLinkPreviewProvider api={previewApi} workspaceId="wsp_1">
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
      </RecommendationLinkPreviewProvider>
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "Launch approval" }));
    await new Promise((resolve) => setTimeout(resolve, 600));
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(previewApi.getRecommendationLinkPreview).not.toHaveBeenCalled();
  });

  it("lets a chip with no preview of its own stand in for the row's prompt", async () => {
    const previewApi = {
      getRecommendationLinkPreview: vi.fn(),
    } as unknown as CommaApiClient;
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
      <RecommendationLinkPreviewProvider api={previewApi} workspaceId="wsp_1">
        <RecommendationCardView
          card={card}
          onAction={vi.fn()}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          sources={sources}
        />
      </RecommendationLinkPreviewProvider>
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");

    // The private mail chip has no card of its own, and the task chip never had
    // one; both would otherwise be holes in the row's hover surface.
    for (const chip of ["launch approval", "COMMA-144"]) {
      await user.hover(screen.getByRole("button", { name: chip }));
      const preview = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
      expect(preview).toHaveTextContent(
        "Draft a reply to Dana Wu about the launch approval"
      );
      await user.unhover(screen.getByRole("button", { name: chip }));
    }
    expect(previewApi.getRecommendationLinkPreview).not.toHaveBeenCalled();
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
    render(
      <RecommendationRail
        api={apiWithoutSnapshot(false)}
        onConnectApps={onConnectApps}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByText("No routines created yet");
    fireEvent.click(screen.getByRole("button", { name: "Connect apps" }));
    expect(onConnectApps).toHaveBeenCalledTimes(1);
  });

  it("renders versioned cards and keeps inline identities out of markdown", async () => {
    const openTask = vi.fn();
    const openUrl = vi.fn();

    render(
      <RecommendationRail
        api={api()}
        onOpenTask={openTask}
        onOpenUrl={openUrl}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("Document")).toBeInTheDocument();
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
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    const greeting = await screen.findByText("Good morning.");
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
    const { container } = render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    const documentHeading = await screen.findByRole("heading", { name: "Document" });
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
    fireEvent.click(await screen.findByRole("option", { name: "Hidden" }));

    await waitFor(() =>
      expect(
        [...container.querySelectorAll(".comma-recommendation-card h3")].map(
          (heading) => heading.textContent
        )
      ).not.toContain("Document")
    );
    expect(
      screen.getByRole("button", { name: /Document visibility$/ })
    ).toHaveTextContent("Hidden");

    fireEvent.click(screen.getByRole("button", { name: /Document visibility$/ }));
    fireEvent.click(await screen.findByRole("option", { name: "Show" }));
    await waitFor(() =>
      expect(
        [...container.querySelectorAll(".comma-recommendation-card h3")].map(
          (heading) => heading.textContent
        )
      ).toContain("Document")
    );
  });

  it("keeps a routine row dragged past the list end pinned to the last slot", async () => {
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByRole("heading", { name: "Document" });
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

    await waitFor(() =>
      expect(
        [...document.querySelectorAll<HTMLElement>(".comma-routines-card-row")].map(
          (row) => row.textContent
        )
      ).toEqual([expect.stringContaining("News"), expect.stringContaining("Document")])
    );
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
    const { container } = render(
      <RecommendationRail
        api={api(snapshot, [
          {
            appId: "google-calendar",
            appName: "Google Calendar",
            connectionId: "google-calendar-account",
            enabled: true,
            kind: "composio",
            label: "Google Calendar",
          },
        ])}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(
      await screen.findByRole("heading", { name: "Google Calendar" })
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
    const recommendationApi = api();
    const nextSnapshot = {
      ...recommendationSnapshot(),
      generatedAt: 2,
      generation: 2,
    };
    const currentEnvelope = await recommendationApi.getRecommendations("wsp_1", {
      timezone: "Asia/Singapore",
    });
    vi.mocked(recommendationApi.refreshRecommendations).mockResolvedValue({
      envelope: {
        ...currentEnvelope,
        snapshot: nextSnapshot,
      },
    } as never);

    const { container } = render(
      <RecommendationRail
        api={recommendationApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByRole("heading", { name: "Document" });
    fireEvent.click(screen.getByRole("button", { name: "Customize routines" }));
    fireEvent.click(screen.getByRole("button", { name: /Document visibility$/ }));
    fireEvent.click(await screen.findByRole("option", { name: "Hidden" }));
    await waitFor(() =>
      expect(
        container.querySelector(".comma-recommendation-card h3")
      ).toHaveTextContent("News")
    );

    fireEvent.click(
      screen.getByRole("button", { name: "Customize routines", hidden: true })
    );
    await waitFor(() =>
      expect(
        screen.queryByRole("dialog", { name: "Customize routines" })
      ).not.toBeInTheDocument()
    );
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));

    expect(
      await screen.findByRole("heading", { name: "Document" })
    ).toBeInTheDocument();
  });

  it("preserves every summary paragraph after the greeting", async () => {
    const snapshot = recommendationSnapshot();
    snapshot.summary = [
      {
        kind: "markdown",
        text: "Good morning.\n\nFirst brief paragraph.\n\nSecond brief paragraph.",
      },
    ];

    render(
      <RecommendationRail
        api={api(snapshot)}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("First brief paragraph.")).toBeInTheDocument();
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

    render(
      <RecommendationRail
        api={api(snapshot)}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(
      await screen.findByRole("heading", { name: "Your briefing" })
    ).toBeInTheDocument();
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

    render(
      <RecommendationRail
        api={api(snapshot)}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByRole("heading", { name: "Routines" });
    expect(
      screen.queryByRole("heading", { name: "GitHub: unread notifications" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("Review unread GitHub notifications.")
    ).not.toBeInTheDocument();
  });

  it("fills the composer draft for a send_to_comma action instead of sending", async () => {
    const usePrompt = vi.fn();
    const confirmSpy = vi.spyOn(window, "confirm");
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    const footerAction = await screen.findByRole("button", {
      name: "Summarize the report",
    });
    expect(footerAction.querySelector("svg[data-comma-icon]")).toBeInTheDocument();
    fireEvent.click(footerAction);
    expect(confirmSpy).not.toHaveBeenCalled();
    expect(usePrompt).toHaveBeenCalledWith("Summarize the latest report");
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
    const usePrompt = vi.fn();
    const english = render(
      <RecommendationRail
        api={api(memberTask("Use prompt", "Decide whether to merge PR #2071"))}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );
    fireEvent.click(await screen.findByRole("button", { name: "Use prompt" }));
    expect(usePrompt).toHaveBeenLastCalledWith(
      `Help me decide whether to merge PR #2071\n\n${url}`
    );
    english.unmount();

    render(
      <CommaI18nProvider locale="zh-CN">
        <RecommendationRail
          api={api(memberTask("填入输入框", "决定是否合并 PR #2071"))}
          onOpenTask={vi.fn()}
          onOpenUrl={vi.fn()}
          onUsePrompt={usePrompt}
          workspaceId="wsp_1"
        />
      </CommaI18nProvider>
    );
    fireEvent.click(await screen.findByRole("button", { name: "填入输入框" }));
    expect(usePrompt).toHaveBeenLastCalledWith(`帮我决定是否合并 PR #2071\n\n${url}`);
  });

  it("executes a media row action from the whole row", async () => {
    const usePrompt = vi.fn();

    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    fireEvent.click(await screen.findByText("Release brief"));
    expect(usePrompt).toHaveBeenCalledWith("Open the release brief");
  });

  it("does not hand remote recommendation media URLs to the renderer", async () => {
    const { container } = render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByText("Release brief");
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
    const { container, unmount } = render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await waitFor(() =>
      expect(container.querySelector("img")).toHaveAttribute(
        "src",
        "blob:recommendation-media"
      )
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

    render(
      <RecommendationRail
        api={api()}
        onOpenTask={openTask}
        onOpenUrl={vi.fn()}
        onUsePrompt={usePrompt}
        workspaceId="wsp_1"
      />
    );

    fireEvent.click(await screen.findByRole("button", { name: "Review COMMA-143" }));
    expect(usePrompt).toHaveBeenCalledWith("Review COMMA-143");
    expect(openTask).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "COMMA-143" }));
    expect(openTask).toHaveBeenCalledWith("cnv_private_task_identity");
    expect(usePrompt).toHaveBeenCalledTimes(1);
  });

  it("omits redundant row logos while retaining provider identity on task references", async () => {
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    const inlineLink = await screen.findByRole("button", { name: "Open report" });
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

  it("renders the Gmail brand logo for gmail-source inline links", async () => {
    const { container: gmailLogo } = render(<GmailProviderLogo />);
    const { container: puzzleIcon } = render(<PuzzleIcon />);

    render(
      <RecommendationDocument
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        parts={[
          { kind: "markdown" as const, text: "Dana Wu asks for " },
          {
            kind: "inline-link" as const,
            link: {
              href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
              label: "launch approval",
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
            kind: "composio" as const,
            label: "Gmail",
          },
        ]}
      />
    );

    const chip = await screen.findByRole("button", { name: "launch approval" });
    const chipMarkup = withStableMaskIds(chip.querySelector("svg")?.innerHTML);
    expect(chipMarkup).toBeTruthy();
    expect(chipMarkup).toBe(
      withStableMaskIds(gmailLogo.querySelector("svg")?.innerHTML)
    );
    expect(chipMarkup).not.toBe(puzzleIcon.querySelector("svg")?.innerHTML);
  });

  it("surfaces bounded partial-source warnings as toasts", async () => {
    const snapshot = {
      ...recommendationSnapshot(),
      warnings: [
        {
          code: "partial_sources" as const,
          message: "Notion was temporarily unavailable.",
          sourceIds: ["notion-account"],
        },
      ],
    };

    render(
      <RecommendationRail
        api={api(snapshot)}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByTestId("routine-warning-toast")).toHaveTextContent(
      "Notion was temporarily unavailable."
    );
    expect(
      within(
        document.querySelector<HTMLElement>(".comma-recommendations")!
      ).queryByText("Notion was temporarily unavailable.")
    ).toBeNull();
  });

  it("announces a failed refresh once per window session while the briefing stays", async () => {
    const staleApi = api();
    vi.mocked(staleApi.getRecommendations).mockResolvedValue({
      ...(await staleApi.getRecommendations("wsp_1")),
      state: "stale",
    });
    const props = {
      api: staleApi,
      onOpenTask: vi.fn(),
      onOpenUrl: vi.fn(),
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };

    const first = render(<RecommendationRail {...props} />);
    expect(await screen.findByTestId("routine-problem-toast")).toHaveTextContent(
      "Couldn’t update routines. Showing the previous briefing."
    );
    expect(
      within(
        first.container.querySelector<HTMLElement>(".comma-recommendations")!
      ).queryByText("Couldn’t update routines. Showing the previous briefing.")
    ).toBeNull();

    // Returning to Home in the same window does not repeat the notice.
    first.unmount();
    act(() => toast.dismissAll());
    await waitFor(() =>
      expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument()
    );
    render(<RecommendationRail {...props} />);
    await waitFor(() => expect(staleApi.getRecommendations).toHaveBeenCalledTimes(3));
    await act(async () => Promise.resolve());
    expect(screen.queryByTestId("routine-problem-toast")).not.toBeInTheDocument();
  });

  it("reloads canonical sources after a rejected refresh instead of retaining mock cards", async () => {
    const initial = {
      settings: {
        autoEnableNewSources: true,
        sourcesCheckedAt: "2026-08-14T00:00:00Z",
        schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
        sourceRevision: 1,
        sources: [
          {
            appId: "linear",
            appName: "Linear",
            connectionId: "local-linear",
            enabled: true,
            kind: "composio" as const,
            label: "Linear",
          },
        ],
      },
      snapshot: recommendationSnapshot(),
      state: "fresh" as const,
    };
    const empty = {
      ...initial,
      settings: { ...initial.settings, sourceRevision: 2, sources: [] },
      snapshot: null,
      state: "empty" as const,
    };
    const getRecommendations = vi
      .fn()
      .mockResolvedValueOnce(initial)
      .mockResolvedValue(empty);
    const refreshRecommendations = vi.fn().mockRejectedValue(new Error("no sources"));
    const failedApi = {
      getRecommendations,
      refreshRecommendations,
    } as unknown as CommaApiClient;

    render(
      <RecommendationRail
        api={failedApi}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    await screen.findByRole("heading", { name: "Document" });
    const refresh = screen.getByRole("button", { name: "Refresh" });
    expect(refresh).toBeEnabled();
    fireEvent.click(refresh);

    expect(await screen.findByText("No routines created yet")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Document" })).not.toBeInTheDocument();
  });

  it("answers a right-click on a greeting inline link with the chat link menu", async () => {
    const onOpenUrl = vi.fn();
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={onOpenUrl}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />
    );

    const inlineLink = await screen.findByRole("button", { name: "COMMA-151 summary" });
    expect(inlineLink.closest(".comma-recommendations-summary")).toBeInTheDocument();

    fireEvent.contextMenu(inlineLink, { clientX: 120, clientY: 80 });

    const menu = await screen.findByRole("menu", { name: "Link menu" });
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
    const props = {
      api: api(),
      onOpenTask: vi.fn(),
      onOpenUrl,
      onUsePrompt: vi.fn(),
      workspaceId: "wsp_1",
    };
    const { rerender } = render(<RecommendationRail {...props} />);

    const inlineLink = await screen.findByRole("button", { name: "COMMA-151 summary" });
    fireEvent.contextMenu(inlineLink, { clientX: 120, clientY: 80 });
    fireEvent.click(
      within(await screen.findByRole("menu", { name: "Link menu" })).getByRole(
        "menuitem",
        { name: "Open in Comma" }
      )
    );
    expect(onOpenUrl).toHaveBeenCalledWith("https://linear.app/comma/issue/COMMA-151");

    rerender(<RecommendationRail {...props} />);
    fireEvent.contextMenu(
      await screen.findByRole("button", { name: "COMMA-151 summary" }),
      { clientX: 120, clientY: 80 }
    );
    fireEvent.click(
      within(await screen.findByRole("menu", { name: "Link menu" })).getByRole(
        "menuitem",
        { name: "Open in External Browser" }
      )
    );
    expect(nativePlatform.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://linear.app/comma/issue/COMMA-151"
    );
  });

  it("leaves briefing text alone and exposes Task archive actions on task chips", async () => {
    render(
      <RecommendationRail
        api={api()}
        onOpenTask={vi.fn()}
        onOpenUrl={vi.fn()}
        onUsePrompt={vi.fn()}
        workspaceId="wsp_1"
      />,
      true
    );

    const heading = await screen.findByRole("heading", { name: "Good morning." });
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
        render(
          <RecommendationRail
            api={api(snapshot)}
            workspaceId="wsp_1"
            onOpenTask={onOpenTask}
            onOpenUrl={vi.fn()}
            onUsePrompt={onUsePrompt}
          />,
          true,
          status
        );
        await screen.findByRole("heading", { name: "Gmail" });
        if (status === "active") {
          const targets = await screen.findAllByRole("button", {
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
  useProductInboxProjection({ enabled: true, session: testProductLease });
  return null;
}
// Routine problems are toasts, so the toast surface renders beside the rail.
function render(element: ReactNode, withTaskFacts = false, taskStatus = "completed") {
  const tree = (
    <>
      {element}
      <Toaster />
    </>
  );
  if (!withTaskFacts) return renderBase(tree);
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
  return renderBase(tree, {
    wrapper: ({ children }) => (
      <ProductInboxProjectionProvider controller={projection.controller}>
        <FixtureDemand />
        {children}
      </ProductInboxProjectionProvider>
    ),
  });
}
