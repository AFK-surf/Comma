import { defaultCommaClientSettings } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CommaSessionHostProvider } from "../../../../session/react";
import {
  createTestSessionHostController,
  signedInSessionSnapshot,
} from "../../../../test/sessionHostHarness";
import {
  CommaWebClientSettingsProvider,
  readWebCommaClientSettings,
} from "../../../commaClientSettings";
import type { OnboardingExperienceProps } from "../../OnboardingExperience";
import { OnboardingWindowApp } from "../OnboardingWindowApp";

vi.mock("../../OnboardingExperience", () => ({
  OnboardingExperience: ({
    onComplete,
    onExited,
    presentation,
  }: OnboardingExperienceProps) => (
    <section aria-label={`Onboarding, ${presentation} presentation`}>
      <button onClick={onComplete} type="button">
        Start chatting
      </button>
      <button onClick={onExited} type="button">
        Exit reveal finished
      </button>
    </section>
  ),
}));

describe("OnboardingWindowApp", () => {
  beforeEach(() => {
    // The signed-in gate reads the profile; this test does not need it.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("offline");
      })
    );
  });

  afterEach(() => {
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("leaves completion to Main and asks it to close the window after the exit", async () => {
    const bridge = installNativeBridgeMock({ os: "macos", platform: "electron" });
    const user = userEvent.setup();
    renderOnboardingWindow(["usr_earlier"]);

    const onboarding = await screen.findByRole("region", {
      name: "Onboarding, window presentation",
    });
    await user.click(
      within(onboarding).getByRole("button", { name: "Start chatting" })
    );
    expect(bridge.onboarding.closeWindow).not.toHaveBeenCalled();

    // Main records the completion for the user it presented the window to,
    // and hands the user on to the main window's Home.
    await user.click(
      within(onboarding).getByRole("button", { name: "Exit reveal finished" })
    );
    expect(bridge.onboarding.closeWindow).toHaveBeenCalledExactlyOnceWith({});
    expect(readWebCommaClientSettings().onboardingCompletedUserIds).toEqual([
      "usr_earlier",
    ]);
  });
});

function renderOnboardingWindow(onboardingCompletedUserIds: string[]) {
  return render(
    <CommaWebClientSettingsProvider
      initialSettings={{ ...defaultCommaClientSettings, onboardingCompletedUserIds }}
    >
      <CommaSessionHostProvider
        controller={createTestSessionHostController({
          initial: signedInSessionSnapshot,
        })}
      >
        <OnboardingWindowApp />
      </CommaSessionHostProvider>
    </CommaWebClientSettingsProvider>
  );
}
