import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { userEvent, within } from "storybook/test";
import {
  AiInput,
  createAiInputRichValue,
  type AiInputMenuGroup,
  type AiInputRichValue,
} from "@comma/ui/components/ai-input";
import { Avatar } from "@comma/ui/components/avatar";
import { resolveProviderBrandLogo } from "@comma/ui/components/provider-brand-logos";
import { slackMentionMenu } from "./slackMentionMenu";

const SlackLogo = resolveProviderBrandLogo("slack");
const icon = SlackLogo ? <SlackLogo /> : null;
const channels = ["bug-reports", "bugs", "comma-bugs", "design", "general", "ios-bugs"];
const people = [
  ["Amy Li", "amy"],
  ["Ben Wu", "ben"],
  ["Bugsy Chen", "bugsy"],
] as const;
const menu = slackMentionMenu(
  {
    channels: channels.map((name, index) => ({
      id: `C${index}`,
      name,
      member: index < 3,
      teamId: "T1",
    })),
    people: people.map(([name, handle]) => ({
      id: `U-${handle}`,
      name,
      handle,
      avatarRef: null,
      teamId: "T1",
    })),
  },
  {
    channelsGroup: "Slack channels",
    dmsGroup: "Slack direct messages",
    channels: "Channels",
    dms: "Direct messages",
    wholeChannel: "Whole channel",
    channelMembers: "Members",
    search: "Search channels and people",
    empty: "No channels or people",
    noResults: "No results",
  },
  icon,
  (person) => <Avatar alt="" name={person.name} size="xs" />,
  { channelId: "C0", memberIds: ["U-amy", "U-bugsy"] }
);
const plugins: AiInputMenuGroup = {
  id: "plugins",
  label: "Plugins",
  items: [
    {
      id: "plugin:slack",
      label: "Slack",
      icon,
      tokenLabel: "Slack",
      plainText: "@slack",
      browse: menu.rowBrowse,
    },
  ],
};

const meta = {
  title: "App/Chat/Slack mention menu",
  component: AiInput,
} satisfies Meta<typeof AiInput>;
export default meta;
type Story = StoryObj<typeof meta>;

function SlackMentionInput() {
  const [value, setValue] = useState<AiInputRichValue>(() =>
    createAiInputRichValue([])
  );
  return (
    <div className="flex min-h-96 items-end pb-xl" style={{ width: 640 }}>
      <AiInput
        menuRegistrations={[
          {
            id: "mentions",
            trigger: "@",
            label: "Mentions",
            maxItems: Number.POSITIVE_INFINITY,
            groups: [plugins, ...menu.groups],
          },
        ]}
        richValue={value}
        onRichValueChange={setValue}
      />
    </div>
  );
}

const typed = (text: string) =>
  async function play({ canvasElement }: { canvasElement: HTMLElement }) {
    await userEvent.type(within(canvasElement).getByRole("textbox"), text);
  };

export const Plugins: Story = {
  args: {},
  render: () => <SlackMentionInput />,
  play: typed("@"),
};

export const Autocomplete: Story = {
  args: {},
  render: () => <SlackMentionInput />,
  play: typed("@bug"),
};

export const SecondLevel: Story = {
  args: {},
  render: () => <SlackMentionInput />,
  play: typed("@sla{ArrowRight}"),
};

export const ThirdLevel: Story = {
  args: {},
  render: () => <SlackMentionInput />,
  play: async ({ canvasElement }) => {
    await typed("@sla{ArrowRight}")({ canvasElement });
    await userEvent.keyboard("{ArrowRight}");
  },
};
