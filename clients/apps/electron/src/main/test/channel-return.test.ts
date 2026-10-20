import { describe, expect, it } from "vitest";
import { channelSettingsRoute, isChannelReturnUrl } from "../channel-return";

describe("channel return", () => {
  it("opens Channels for a Telegram or Linear return without trusting a claimed binding or crossing environments", () => {
    expect(
      isChannelReturnUrl(
        "comma-staging://telegram/return?connected=true",
        "comma-staging"
      )
    ).toBe(true);
    expect(
      isChannelReturnUrl(
        "comma-staging://linear/return?workspace_id=wsp_selected",
        "comma-staging"
      )
    ).toBe(true);
    expect(channelSettingsRoute).toBe("/settings?category=channels");
    for (const url of [
      "comma://telegram/return",
      "https://linear/return",
      "comma-staging://telegram/task",
      "comma-staging://slack/return",
      "comma-staging://user@linear/return",
      "not a url",
    ]) {
      expect(isChannelReturnUrl(url, "comma-staging")).toBe(false);
    }
  });
});
