import { describe, expect, it } from "vitest";
import {
  isTelegramReturnUrl,
  telegramSettingsRoute,
  telegramSettingsRouteForReturn,
} from "../telegram-return";

describe("Telegram return", () => {
  it("opens Channels without trusting a claimed binding or crossing environments", () => {
    expect(
      isTelegramReturnUrl(
        "comma-staging://telegram/return?connected=true",
        "comma-staging"
      )
    ).toBe(true);
    expect(telegramSettingsRoute).toBe("/settings?category=channels");
    expect(
      telegramSettingsRouteForReturn(
        "comma-staging://telegram/return?workspace_id=wsp_selected&connected=true"
      )
    ).toBe("/settings?category=channels&telegram-workspace=wsp_selected");
    expect(
      telegramSettingsRouteForReturn(
        "comma-staging://telegram/return?workspace_id=https://other.example"
      )
    ).toBe(telegramSettingsRoute);
    for (const url of [
      "comma://telegram/return",
      "https://telegram/return",
      "comma-staging://telegram/task",
      "comma-staging://user@telegram/return",
      "not a url",
    ]) {
      expect(isTelegramReturnUrl(url, "comma-staging")).toBe(false);
    }
  });
});
