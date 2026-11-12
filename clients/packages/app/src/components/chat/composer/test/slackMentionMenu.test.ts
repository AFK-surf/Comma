import { filterAiInputMenuGroups } from "@comma/ui/components/ai-input";
import { describe, expect, it } from "vitest";
import { slackMentionMenu } from "../slackMentionMenu";

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
const channel = (name: string) => ({
  id: `C-${name}`,
  name,
  member: true,
  teamId: "T1",
});
const person = (name: string, handle: string) => ({
  id: `U-${handle}`,
  name,
  handle,
  avatarRef: null,
  teamId: "T1",
});

describe("slackMentionMenu", () => {
  const menu = slackMentionMenu(
    {
      channels: [channel("bugs"), channel("comma-bugs")],
      people: [person("Amy Li", "amy"), person("Bugsy", "bee")],
    },
    labels,
    null,
    () => null
  );
  const shown = (query: string) =>
    filterAiInputMenuGroups(
      {
        id: "mentions",
        trigger: "@",
        label: "Mentions",
        maxItems: Number.POSITIVE_INFINITY,
        groups: menu.groups,
      },
      query
    ).map((group) => [group.label, group.items.map((item) => item.label)]);

  it("lists channels and people by a typed name, and nothing for an empty query", () => {
    expect(shown("")).toEqual([]);
    expect(shown("bug")).toEqual([
      ["Slack channels", ["#bugs", "#comma-bugs"]],
      ["Slack direct messages", ["Bugsy"]],
    ]);
    expect(shown("#bug")).toEqual([["Slack channels", ["#bugs"]]]);
    expect(shown("amy")).toEqual([["Slack direct messages", ["Amy Li"]]]);
    expect(shown("U-")).toEqual([]);
  });

  it("lists every match", () => {
    const { groups } = slackMentionMenu(
      {
        channels: Array.from({ length: 12 }, (_, i) => channel(`bug-${i}`)),
        people: [],
      },
      labels,
      null,
      () => null
    );
    const [section] = filterAiInputMenuGroups(
      {
        id: "mentions",
        trigger: "@",
        label: "Mentions",
        maxItems: Number.POSITIVE_INFINITY,
        groups,
      },
      "bug"
    );
    expect(section?.items).toHaveLength(12);
  });

  it("names a channel and a direct message to the agent by their Slack links", () => {
    expect(menu.groups[0]?.items[0]?.plainText).toBe(
      "[Slack #bugs](https://app.slack.com/client/T1/C-bugs)"
    );
    expect(menu.groups[1]?.items[0]?.plainText).toBe(
      "[Slack DM @Amy Li](https://app.slack.com/team/U-amy)"
    );
  });

  it("opens the Slack row's second level unfiltered, with channels and direct messages apart", () => {
    expect(menu.rowBrowse.startsUnfiltered).toBe(true);
    expect(
      menu.rowBrowse.groups.map((group) => [
        group.label,
        group.items.map((item) => item.label),
      ])
    ).toEqual([
      ["Channels", ["#bugs", "#comma-bugs"]],
      ["Direct messages", ["Amy Li", "Bugsy"]],
    ]);
  });

  it("offers behind a channel the whole channel and its members, named with the channel", () => {
    const opened: (string | null)[] = [];
    const { rowBrowse } = slackMentionMenu(
      {
        channels: [channel("bugs")],
        people: [person("Amy Li", "amy"), person("Bugsy", "bee")],
      },
      labels,
      null,
      () => null,
      { channelId: "C-bugs", memberIds: ["U-amy", "U-gone"] },
      (id) => opened.push(id)
    );
    const behind = rowBrowse.groups[0]?.items[0]?.browse;
    expect(behind?.groups.map((g) => g.items.map((item) => item.label))).toEqual([
      ["Whole channel"],
      ["Amy Li"],
    ]);
    expect(behind?.groups[0]?.items[0]?.plainText).toBe(
      "[Slack #bugs](https://app.slack.com/client/T1/C-bugs)"
    );
    const member = behind?.groups[1]?.items[0];
    expect(member?.tokenLabel).toBe("#bugs · Amy Li");
    expect(member?.plainText).toBe(
      "[Slack #bugs](https://app.slack.com/client/T1/C-bugs) [Slack @Amy Li](https://app.slack.com/team/U-amy)"
    );

    behind?.onQueryChange?.("");
    behind?.onQueryChange?.(null);
    expect(opened).toEqual(["C-bugs", null]);
  });

  it("gives every token the Slack logo, not the row's own icon", () => {
    const { groups } = slackMentionMenu(
      { channels: [channel("bugs")], people: [person("Amy Li", "amy")] },
      labels,
      "logo",
      () => null
    );
    expect(groups.map((group) => group.items[0]?.tokenIconMarkup)).toEqual([
      "logo",
      "logo",
    ]);
  });
});
