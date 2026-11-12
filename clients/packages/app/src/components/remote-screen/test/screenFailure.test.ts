import { describe, expect, it } from "vitest";
import {
  screenFailureDetail,
  screenFailureKind,
  screenFailureRetries,
} from "../screenFailure";

const messages = {
  remote_screen_failure_unreachable: () => "lost",
  remote_screen_failure_refused: () => "no access",
  remote_screen_failure_app_gone: () => "app gone",
  remote_screen_failure_unsupported: () => "cannot decode",
};

describe("what a failed screen says", () => {
  it("says a known code in words", () => {
    expect(screenFailureDetail("upstream_unavailable", messages)).toBe("lost");
    expect(screenFailureDetail("forbidden", messages)).toBe("no access");
    expect(screenFailureDetail("unauthorized", messages)).toBe("no access");
    expect(screenFailureDetail("App was not found: Calculator", messages)).toBe(
      "app gone"
    );
    expect(screenFailureDetail("decoder_unsupported", messages)).toBe("cannot decode");
  });

  it("never shows a bare code it has no words for, and keeps a sentence it does not know", () => {
    expect(screenFailureDetail("some_new_code", messages)).toBeUndefined();
    expect(screenFailureDetail("station.screen.failed", messages)).toBeUndefined();
    expect(screenFailureDetail("The helper could not start.", messages)).toBe(
      "The helper could not start."
    );
    expect(screenFailureDetail(undefined, messages)).toBeUndefined();
  });

  it("tries again unasked only where that can help", () => {
    expect(screenFailureRetries("upstream_unavailable")).toBe(true);
    expect(screenFailureRetries("something else")).toBe(true);
    expect(screenFailureRetries("forbidden")).toBe(false);
    expect(screenFailureRetries("unauthorized")).toBe(false);
    expect(screenFailureRetries("App was not found: Calculator")).toBe(false);
    expect(screenFailureKind(undefined)).toBe("other");
    // A real missing app: the code says only that it failed, the sentence says why.
    expect(screenFailureRetries("App was not found: Calculator", "http_503")).toBe(
      false
    );
    expect(screenFailureRetries("its access is not Full", "forbidden")).toBe(false);
    // A page that cannot decode a screen cannot by trying again.
    expect(
      screenFailureRetries("This page cannot decode a screen.", "decoder_unsupported")
    ).toBe(false);
    expect(
      screenFailureRetries("The mesh did not reach that computer.", "unreachable")
    ).toBe(true);
  });
});
