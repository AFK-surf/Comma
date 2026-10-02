import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { holdOnboardingOpen } from "../onboardingPresence";
import { useOnboardingAhead } from "../useOnboardingAhead";

function signedIn(userId: string, completed: string[]) {
  const settings = {
    ...defaultCommaClientSettings,
    onboardingCompletedUserIds: completed,
  };
  const auth = { userId } as unknown as CommaAuthContextValue;
  return ({ children }: { children: ReactNode }) => (
    <CommaWebClientSettingsProvider initialSettings={settings}>
      <CommaAuthContext.Provider value={auth}>{children}</CommaAuthContext.Provider>
    </CommaWebClientSettingsProvider>
  );
}

describe("useOnboardingAhead", () => {
  it("holds an account that has not finished the onboarding, before it has opened", () => {
    const { result } = renderHook(useOnboardingAhead, {
      wrapper: signedIn("usr_new", ["usr_other"]),
    });
    expect(result.current).toBe(true);
  });

  it("lets an account that finished the onboarding through", () => {
    const { result } = renderHook(useOnboardingAhead, {
      wrapper: signedIn("usr_done", ["usr_done"]),
    });
    expect(result.current).toBe(false);
  });

  it("counts only an open onboarding outside a signed-in session", () => {
    const { result } = renderHook(useOnboardingAhead);
    expect(result.current).toBe(false);
    let release!: () => void;
    act(() => {
      release = holdOnboardingOpen();
    });
    expect(result.current).toBe(true);
    act(() => release());
    expect(result.current).toBe(false);
  });
});
