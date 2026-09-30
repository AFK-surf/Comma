import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import {
  GithubProviderLogo,
  GmailProviderLogo,
  GoogleCalendarProviderLogo,
  GoogleDriveProviderLogo,
  GoogleProviderLogo,
  LinearProviderLogo,
  NotionProviderLogo,
  SlackProviderLogo,
} from "../ProviderBrandLogos";
import { LarkProviderLogo } from "../LarkProviderLogo";
import { SignalProviderMark } from "../SignalProviderLogo";
import { resolveProviderBrandLogo } from "../providerBrandLogoResolver";

describe("ProviderBrandLogos", () => {
  it.each([
    ["github", "github"],
    ["Gmail", "gmail"],
    ["Google Drive", "google-drive"],
    ["Google Workspace", "google"],
    ["google-calendar", "google-calendar"],
    ["linear", "linear"],
    ["notion", "notion"],
    ["slack", "slack"],
    ["Telegram", "telegram"],
    ["Signal", "signal"],
    ["Feishu", "feishu"],
    ["Lark", "lark"],
  ])("resolves %s to the %s identity artwork", (provider, expectedLogo) => {
    const Logo = resolveProviderBrandLogo(provider);
    expect(Logo).toBeDefined();

    const { container } = render(Logo ? <Logo /> : null);
    expect(container.querySelector("svg")).toHaveAttribute(
      "data-provider-logo",
      expectedLogo
    );
    expect(container.querySelector("svg")).not.toHaveAttribute("data-comma-icon");
  });

  it("renders the eight supplied provider marks as decorative 24px artwork", () => {
    const { container } = render(
      <>
        <GithubProviderLogo />
        <GmailProviderLogo />
        <GoogleProviderLogo />
        <GoogleCalendarProviderLogo />
        <GoogleDriveProviderLogo />
        <LinearProviderLogo />
        <NotionProviderLogo />
        <SlackProviderLogo />
      </>
    );

    const logos = [...container.querySelectorAll("svg[data-provider-logo]")];
    expect(logos).toHaveLength(8);
    for (const logo of logos) {
      expect(logo).toHaveAttribute("aria-hidden", "true");
      expect(logo).toHaveAttribute("focusable", "false");
      expect(logo).toHaveAttribute("height", "24");
      expect(logo).toHaveAttribute("viewBox");
      expect(logo).toHaveAttribute("width", "24");
    }
  });

  it("draws the Signal chip mark as the logo in white on a Signal-blue disc", () => {
    const { container } = render(<SignalProviderMark />);

    expect(container.querySelector("svg")).toHaveAttribute(
      "data-provider-logo",
      "signal"
    );
    expect(container.querySelector("circle")).toHaveAttribute("fill", "#3B45FD");
    const paths = [...container.querySelectorAll("path")];
    expect(paths).toHaveLength(2);
    for (const path of paths) {
      expect(path).toHaveAttribute("fill", "#FFFFFF");
    }
  });

  it("keeps mask and clip identifiers unique when logos repeat in a list", () => {
    const { container } = render(
      <>
        <GoogleProviderLogo />
        <GoogleProviderLogo />
        <GoogleCalendarProviderLogo />
        <GoogleCalendarProviderLogo />
        <GmailProviderLogo />
        <GmailProviderLogo />
        <LarkProviderLogo />
        <LarkProviderLogo />
      </>
    );

    const ids = [...container.querySelectorAll("mask[id], clipPath[id]")].map(
      (element) => element.id
    );
    expect(ids).toHaveLength(8);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
