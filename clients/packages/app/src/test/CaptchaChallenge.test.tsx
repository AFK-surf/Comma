import { act, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { CaptchaChallenge } from "../components/CaptchaChallenge";
import type { SessionAuthenticatorController } from "../session/controller";

describe("CAPTCHA frame completion", () => {
  it("accepts only the active iframe's exact origin and challenge, and cancels through the core action", async () => {
    const answer = vi.fn(async () => true);
    const authenticator = {
      captcha: {
        get: () => ({
          challengeId: "current_challenge",
          url: "https://api.comma.test/v1/comma/auth/captcha?challenge_id=current_challenge&action=email_login",
        }),
        subscribe: () => () => undefined,
        answer,
      },
    } as unknown as SessionAuthenticatorController;
    // Keep the topic value stable, as the core controller does.
    const challenge = authenticator.captcha!.get();
    authenticator.captcha!.get = () => challenge;
    render(<CaptchaChallenge authenticator={authenticator} />);
    const frame = screen.getByTitle("Security check") as HTMLIFrameElement;
    const token = {
      type: "comma.captcha",
      challengeId: "current_challenge",
      token: "provider_token",
    };
    postFrameMessage("https://other.example", frame.contentWindow, token);
    postFrameMessage("https://api.comma.test", window, token);
    postFrameMessage("https://api.comma.test", frame.contentWindow, {
      ...token,
      challengeId: "previous_challenge",
    });
    expect(answer).not.toHaveBeenCalled();
    postFrameMessage("https://api.comma.test", frame.contentWindow, token);
    expect(answer).toHaveBeenLastCalledWith("current_challenge", "provider_token");
    await act(() => screen.getByRole("button", { name: /Cancel/ }).click());
    expect(answer).toHaveBeenLastCalledWith("current_challenge", null);
  });
});

function postFrameMessage(origin: string, source: Window | null, data: unknown) {
  act(() => {
    window.dispatchEvent(new MessageEvent("message", { origin, source, data }));
  });
}
