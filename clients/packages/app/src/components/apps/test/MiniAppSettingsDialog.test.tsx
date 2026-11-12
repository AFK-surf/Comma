import {
  render as baseRender,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { MiniAppSettingsDialog } from "../MiniAppSettingsDialog";

const app = {
  id: "a1",
  slug: "x7k2q9",
  workspace_id: "wsp",
  name: "Habit tracker",
  description: "",
  icon_url: null,
  cover_url: null,
  screenshot_urls: [],
  repo: null,
  visibility: "workspace",
  status: "active",
  live_version: 2,
  latest_version: 2,
  author: { name: "Ada" },
  capabilities: [],
  egress: [],
  secrets: [],
  grants: [],
  installed: false,
  install: null,
  storage: [],
  has_backend: false,
  created_at: "",
  updated_at: "",
};

function render(
  ui: ReactNode,
  link: { token: string; url: string } | null = null,
  screenshots: string[] = []
) {
  const images: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    onSubscribe: (topic) => {
      if (topic.topic === "miniAppImage") images.push(topic);
    },
    values: (topic) =>
      topic.topic === "miniAppImage"
        ? { status: "ready", src: "data:image/png;base64,iVBORw==" }
        : topic.topic === "miniApp"
          ? {
              status: "ready",
              app: { ...app, screenshot_urls: screenshots },
              versions: [],
              link,
              error: null,
            }
          : undefined,
  });
  baseRender(ui, {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  return Object.assign(core, { images });
}

/** Who can open the app is a menu: open it, then pick anyone with the link. */
async function chooseLinkVisibility() {
  const dialog = await screen.findByRole("dialog");
  const user = userEvent.setup();
  await user.click(within(dialog).getByRole("button", { name: /Visibility/ }));
  await user.click(await screen.findByRole("option", { name: "Anyone with the link" }));
}

describe("an app's settings", () => {
  it("shows the selected Version screenshots in order through Core", async () => {
    const urls = [
      "/v1/comma/apps/a1/screenshots/0?v=2",
      "/v1/comma/apps/a1/screenshots/1?v=2",
    ];
    const core = render(
      <MiniAppSettingsDialog appId="a1" onClose={() => {}} workspaceId="wsp" />,
      null,
      urls
    );
    await screen.findByRole("img", { name: "Habit tracker · 1" });
    expect(
      screen.getAllByRole("img").map((image) => image.getAttribute("alt"))
    ).toEqual(["Habit tracker · 1", "Habit tracker · 2"]);
    expect(core.images).toEqual(
      urls.map((url) => ({ topic: "miniAppImage", url, workspace: "wsp" }))
    );
  });

  // The link is the only way in for anyone with the link: choosing it makes one, without a second step.
  it("makes the link when anyone with the link may open the app", async () => {
    const core = render(
      <MiniAppSettingsDialog appId="a1" onClose={() => {}} workspaceId="wsp" />
    );
    await chooseLinkVisibility();
    await waitFor(() =>
      expect(core.sentTo("miniApps.link.publish")).toEqual([
        { workspace: "wsp", app: "a1" },
      ])
    );
    expect(core.sentTo("miniApps.update")).toEqual([
      { workspace: "wsp", app: "a1", visibility: "link" },
    ]);
  });

  it("keeps the link that exists", async () => {
    const core = render(
      <MiniAppSettingsDialog appId="a1" onClose={() => {}} workspaceId="wsp" />,
      { token: "t", url: "https://app.comma.test/a/t" }
    );
    await chooseLinkVisibility();
    await waitFor(() => expect(core.sentTo("miniApps.update")).toHaveLength(1));
    expect(core.sentTo("miniApps.link.publish")).toEqual([]);
  });
});
