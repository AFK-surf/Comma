import "@comma/ui/styles.css";

import { cleanup, render } from "@comma/test-utils/render";
import {
  AiInput,
  createAiInputRichValue,
  type AiInputRichValue,
} from "@comma/ui/components/ai-input";
import { useMemo, useState } from "react";
import { afterEach, expect, it } from "vitest";
import { page, userEvent } from "vitest/browser";
import { slackMentionMenu } from "../slackMentionMenu";

afterEach(cleanup);

const people = Array.from({ length: 12 }, (_, index) => ({
  id: `U${index}`,
  name: `Person ${index}`,
  handle: `person${index}`,
  avatarRef: null,
  teamId: "T1",
}));
const directory = {
  channels: Array.from({ length: 20 }, (_, index) => ({
    id: `C${index}`,
    name: `channel-${index}`,
    member: true,
    teamId: "T1",
  })),
  people,
};
const labels = {
  channelsGroup: "Slack channels",
  dmsGroup: "Slack direct messages",
  channels: "Channels",
  dms: "Direct messages",
  wholeChannel: "Whole channel",
  channelMembers: "Members",
  search: "Search channels and people",
  empty: "No channels or people",
  noResults: "No results",
};

/** The app's frame: a clipped pane with the composer at the bottom of the window. Members arrive after the row opens. */
function Pane() {
  const [value, setValue] = useState<AiInputRichValue>(() =>
    createAiInputRichValue([])
  );
  const [channelId, setChannelId] = useState<string | null>(null);
  const menu = useMemo(
    () =>
      slackMentionMenu(
        directory,
        labels,
        <span>#</span>,
        () => <span>@</span>,
        channelId
          ? { channelId, memberIds: people.map((person) => person.id) }
          : undefined,
        setChannelId
      ),
    [channelId]
  );
  return (
    <div
      data-testid="pane"
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100vh",
        overflow: "hidden",
      }}
    >
      <div style={{ flex: 1 }} />
      <div style={{ padding: 16 }}>
        <AiInput
          menuRegistrations={[
            {
              id: "mentions",
              trigger: "@",
              label: "Mentions",
              maxItems: Number.POSITIVE_INFINITY,
              groups: [
                {
                  id: "plugins",
                  label: "Plugins",
                  items: [
                    {
                      id: "plugin:slack",
                      label: "Slack",
                      tokenLabel: "Slack",
                      plainText: "@slack",
                      browse: menu.rowBrowse,
                    },
                  ],
                },
              ],
            },
          ]}
          richValue={value}
          onRichValueChange={setValue}
        />
      </div>
    </div>
  );
}

it("keeps the channel's members inside the window and leaves the composer where it is", async () => {
  await page.viewport(1000, 600);
  const { container } = render(<Pane />);
  await userEvent.click(page.getByRole("textbox"));
  await userEvent.keyboard("@sla{ArrowRight}");
  for (let row = 0; row < 7; row += 1) await userEvent.keyboard("{ArrowDown}");
  await userEvent.keyboard("{Enter}");
  await expect.element(page.getByText("Person 11").first()).toBeInTheDocument();

  const pane = container.querySelector<HTMLElement>('[data-testid="pane"]')!;
  const inWindow = async (name: string) => {
    const row = page.getByRole("option", { name });
    await expect.element(row).toHaveAttribute("aria-selected", "true");
    const panel = row
      .element()
      .closest(".comma-ai-input-menu")!
      .getBoundingClientRect();
    expect(pane.scrollTop).toBe(0);
    expect(panel.top).toBeGreaterThanOrEqual(0);
    expect(panel.bottom).toBeLessThanOrEqual(window.innerHeight);
    expect(row.element().getBoundingClientRect().bottom).toBeLessThanOrEqual(
      panel.bottom
    );
  };
  for (let row = 0; row < 5; row += 1) await userEvent.keyboard("{ArrowDown}");
  await inWindow("Person 4 @person4");
  for (let row = 0; row < 7; row += 1) await userEvent.keyboard("{ArrowDown}");
  await inWindow("Person 11 @person11");
});
