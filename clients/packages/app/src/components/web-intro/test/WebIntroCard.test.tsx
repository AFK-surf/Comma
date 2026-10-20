import { initializeCommaI18n } from "@comma/i18n";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import {
  act,
  cleanup,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
  readWebCommaClientSettings,
} from "../../commaClientSettings";
import { WebIntroCard } from "../WebIntroCard";

const userId = "usr_1";

describe("WebIntroCard", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    installNativeBridgeMock();
  });

  afterEach(() => {
    localStorage.clear();
    vi.restoreAllMocks();
  });

  it("walks through its tips, opens Plugins and the Mac download, and records that it was seen", async () => {
    const user = userEvent.setup();
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    const router = renderCard(["usr_earlier"]);

    const card = await screen.findByRole("complementary", { name: "Comma on the web" });
    // Every tip's copy stays in the card; only the one on show is exposed.
    expect(within(card).getByRole("heading")).toHaveTextContent("Just ask your Router");
    expect(card).toHaveTextContent("1 of 3");

    await user.click(within(card).getByRole("button", { name: "Next" }));
    expect(within(card).getByRole("heading")).toHaveTextContent("Connect your apps");
    await user.click(within(card).getByRole("button", { name: "Open Plugins" }));
    expect(router.state.location.pathname).toBe("/plugins");

    // The step indicator also goes back.
    await user.click(
      within(card).getByRole("button", { name: "Just ask your Router" })
    );
    expect(within(card).getByRole("heading")).toHaveTextContent("Just ask your Router");
    await user.click(within(card).getByRole("button", { name: "More in the Mac app" }));
    expect(within(card).getByRole("heading")).toHaveTextContent("More in the Mac app");
    await user.click(within(card).getByRole("button", { name: "Download for Mac" }));
    expect(open).toHaveBeenCalledWith(
      "https://comma.surf/download?start=mac",
      "_blank",
      "noopener,noreferrer"
    );

    await user.click(within(card).getByRole("button", { name: "Got it" }));
    expect(screen.queryByRole("complementary")).toBeNull();
    await waitFor(() =>
      expect(readWebCommaClientSettings().onboardingCompletedUserIds).toEqual([
        "usr_earlier",
        userId,
      ])
    );
  });

  it("closes from any tip, replays from the first tip, and stays closed once seen", async () => {
    const user = userEvent.setup();
    renderCard([]);

    const card = await screen.findByRole("complementary", { name: "Comma on the web" });
    await user.click(within(card).getByRole("button", { name: "Next" }));
    await user.click(within(card).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("complementary")).toBeNull();
    await waitFor(() =>
      expect(readWebCommaClientSettings().onboardingCompletedUserIds).toEqual([userId])
    );

    // The Settings replay drops the record; the card comes back on its first tip.
    storeCompletedUserIds([]);
    const replayed = await screen.findByRole("complementary", {
      name: "Comma on the web",
    });
    expect(within(replayed).getByRole("heading")).toHaveTextContent(
      "Just ask your Router"
    );

    // Another tab records it while this one stands on tip 2; a replay starts on
    // tip 1.
    await user.click(within(replayed).getByRole("button", { name: "Next" }));
    storeCompletedUserIds([userId]);
    expect(screen.queryByRole("complementary")).toBeNull();
    storeCompletedUserIds([]);
    const again = await screen.findByRole("complementary", {
      name: "Comma on the web",
    });
    expect(within(again).getByRole("heading")).toHaveTextContent(
      "Just ask your Router"
    );
    cleanup();

    renderCard([userId]);
    await act(async () => undefined);
    expect(screen.queryByRole("complementary")).toBeNull();
  });
});

/** Writes the record the way another tab or the Settings replay would. */
function storeCompletedUserIds(onboardingCompletedUserIds: string[]) {
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({ ...readWebCommaClientSettings(), onboardingCompletedUserIds })
  );
  act(() => window.dispatchEvent(new StorageEvent("storage", { key: null })));
}

function renderCard(onboardingCompletedUserIds: string[]) {
  const rootRoute = createRootRoute({
    component: () => <WebIntroCard userId={userId} />,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren(
      ["/", "/plugins"].map((path) =>
        createRoute({ getParentRoute: () => rootRoute, path, component: () => null })
      )
    ),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(
    <CommaWebClientSettingsProvider
      initialSettings={{ ...defaultCommaClientSettings, onboardingCompletedUserIds }}
    >
      <RouterProvider router={router} />
    </CommaWebClientSettingsProvider>
  );
  return router;
}
