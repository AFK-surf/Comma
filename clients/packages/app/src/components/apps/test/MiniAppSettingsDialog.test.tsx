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

function render(ui: ReactNode, link: { token: string; url: string } | null = null) {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "miniApp"
        ? { status: "ready", app, versions: [], link, error: null }
        : undefined,
  });
  baseRender(ui, {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  return core;
}

/** Who can open the app is a menu: open it, then pick anyone with the link. */
async function chooseLinkVisibility() {
  const dialog = await screen.findByRole("dialog");
  const user = userEvent.setup();
  await user.click(within(dialog).getByRole("button", { name: /Visibility/ }));
  await user.click(await screen.findByRole("option", { name: "Anyone with the link" }));
}

describe("an app's settings", () => {
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
