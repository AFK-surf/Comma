import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import {
  meetingCatalogSchema,
  meetingHistorySchema,
  meetingsOverviewSchema,
  type BftApi,
} from "../src/api";
import { MeetingsPage } from "../src/MeetingsPage";
import { ApiContext } from "../src/resource";

const swarms = [{ id: "p-1", name: "Lark Swarm" }];

function makeLarkOverview(settingsOverride: Record<string, unknown> = {}) {
  return meetingsOverviewSchema.parse({
    settings: {
      enabled: true,
      provider: "feishu",
      mode: "join",
      connect_id: "feishu-main",
      channel: "Product Team",
      channel_id: "oc_team",
      calendar_scope: "selected",
      calendar_source: "feishu_lark",
      delivery: "channel",
      calendar_selections: [
        {
          account_id: "app",
          calendar_id: "feishu.cn_team@group.calendar.feishu.cn",
          name: "Team meetings",
        },
      ],
      preparation_lead_minutes: 10,
      research_enabled: false,
      calendar_writeback: false,
      personal_preparation: false,
      channel_notice: false,
      series: [],
      ...settingsOverride,
    },
    connects: [
      {
        connect_id: "feishu-main",
        provider: "feishu",
        app_name: "Feishu Bot",
        bot_username: null,
        workspace_name: null,
        state: "connected",
        preparation: "enabled",
        missing_scopes: null,
      },
    ],
    events: [],
    calendar_health: "ok",
    truncated: false,
    runtime_enabled: true,
  });
}

const larkCatalog = meetingCatalogSchema.parse({
  calendars: [
    {
      account_id: "app",
      calendar_id: "feishu.cn_team@group.calendar.feishu.cn",
      name: "Team meetings",
      account_name: "app",
    },
  ],
  channels: [{ id: "oc_team", name: "Product Team" }],
  next_cursor: null,
});

function renderMeetings(view: "settings" | "past", overrides: Partial<BftApi>) {
  const api = {
    meetings: vi.fn().mockResolvedValue(makeLarkOverview()),
    meetingCatalog: vi.fn().mockResolvedValue(larkCatalog),
    saveMeetings: vi.fn().mockResolvedValue({}),
    meetingHistory: vi.fn().mockResolvedValue(
      meetingHistorySchema.parse({
        channel: "Product Team",
        provider: "feishu",
        meetings: [],
        next_cursor: null,
      })
    ),
    ...overrides,
  } as unknown as BftApi;

  render(
    <ApiContext.Provider value={api}>
      <MeetingsPage org="acme" swarms={swarms} view={view} />
    </ApiContext.Provider>
  );

  return api;
}

describe("MeetingsPage Feishu/Lark validation and history", () => {
  it("allows saving pure autojoin on selected Feishu/Lark calendars with a notice chat", async () => {
    const user = userEvent.setup();
    const saveMeetings = vi.fn().mockResolvedValue({});
    renderMeetings("settings", {
      meetings: vi.fn().mockResolvedValue(
        makeLarkOverview({
          mode: "join",
          channel_notice: false,
          personal_preparation: false,
          delivery: "channel",
          channel_id: "oc_team",
        })
      ),
      saveMeetings,
    });

    const save = await screen.findByRole("button", { name: "Save and enable" });
    await waitFor(() => expect(save).not.toBeDisabled());
    await user.click(save);

    await waitFor(() => expect(saveMeetings).toHaveBeenCalledTimes(1));
    expect(saveMeetings).toHaveBeenCalledWith(
      "acme",
      "p-1",
      expect.objectContaining({
        autojoin: true,
        channel_notice: false,
        personal_preparation: false,
        channel_id: "oc_team",
        delivery: "channel",
      })
    );
  });

  it("allows saving pure autojoin on selected Feishu/Lark calendars with organizer DM and no chat", async () => {
    const user = userEvent.setup();
    const saveMeetings = vi.fn().mockResolvedValue({});
    renderMeetings("settings", {
      meetings: vi.fn().mockResolvedValue(
        makeLarkOverview({
          mode: "join",
          channel_notice: false,
          personal_preparation: false,
          delivery: "organizer",
          channel_id: "",
          channel: "",
        })
      ),
      saveMeetings,
    });

    const save = await screen.findByRole("button", { name: "Save and enable" });
    await waitFor(() => expect(save).not.toBeDisabled());
    await user.click(save);

    await waitFor(() => expect(saveMeetings).toHaveBeenCalledTimes(1));
    expect(saveMeetings).toHaveBeenCalledWith(
      "acme",
      "p-1",
      expect.objectContaining({
        autojoin: true,
        channel_notice: false,
        personal_preparation: false,
        channel_id: "",
        delivery: "organizer",
      })
    );
  });

  it("blocks saving Feishu/Lark autojoin with group delivery when no chat is selected (selected and members scopes)", async () => {
    const user = userEvent.setup();

    for (const calendar_scope of ["selected", "members"] as const) {
      const saveMeetings = vi.fn().mockResolvedValue({});
      const { unmount } = render(
        <ApiContext.Provider
          value={
            {
              meetings: vi.fn().mockResolvedValue(
                makeLarkOverview({
                  calendar_scope,
                  mode: "join",
                  channel_notice: false,
                  personal_preparation: false,
                  delivery: "channel",
                  channel_id: "",
                  channel: "",
                })
              ),
              meetingCatalog: vi.fn().mockResolvedValue(larkCatalog),
              saveMeetings,
            } as unknown as BftApi
          }
        >
          <MeetingsPage org="acme" swarms={swarms} view="settings" />
        </ApiContext.Provider>
      );

      const save = await screen.findByRole("button", { name: "Save and enable" });
      await waitFor(() => expect(save).not.toBeDisabled());
      await user.click(save);

      expect(saveMeetings).not.toHaveBeenCalled();
      expect(await screen.findByRole("alert")).toHaveTextContent(
        "Select a notice chat, or send join notices and minutes to the organizer in a DM."
      );
      unmount();
    }
  });

  it("renders Feishu/Lark past meeting group name without # prefix and shows Minutes/AI notes links", async () => {
    const user = userEvent.setup();
    renderMeetings("past", {
      meetingHistory: vi.fn().mockResolvedValue(
        meetingHistorySchema.parse({
          channel: "Product Team",
          provider: "feishu",
          meetings: [
            {
              meeting_id: "m-1",
              title: "Weekly Feishu Sync",
              status: "done",
              start_ms: 1_789_610_000_000,
              recording_url: "https://acme.feishu.cn/minutes/obcn123",
              recording_status: "available",
              canvas_url: "https://acme.feishu.cn/docx/doxcn456",
              thread_url:
                "https://applink.feishu.cn/client/chat/open?openChatId=oc_public",
            },
          ],
          next_cursor: null,
        })
      ),
    });

    const heading = await screen.findByRole("heading", { name: "Product Team" });
    expect(heading.textContent).toBe("Product Team");
    expect(
      screen.getByText("Meeting minutes and AI notes shared in the notice chat.")
    ).toBeInTheDocument();
    expect(screen.queryByText(/#Product Team/)).toBeNull();

    await user.click(screen.getByRole("button", { name: /Weekly Feishu Sync/ }));
    expect(screen.queryByText(/#Product Team/)).toBeNull();
    expect(screen.getByRole("link", { name: /Minutes/i })).toHaveAttribute(
      "href",
      "https://acme.feishu.cn/minutes/obcn123"
    );
    expect(screen.getByRole("link", { name: /AI notes/i })).toHaveAttribute(
      "href",
      "https://acme.feishu.cn/docx/doxcn456"
    );
    expect(screen.getByRole("link", { name: /group chat/i })).toHaveAttribute(
      "href",
      "https://applink.feishu.cn/client/chat/open?openChatId=oc_public"
    );
  });
});
