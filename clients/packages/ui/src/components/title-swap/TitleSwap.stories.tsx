import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { Button, TaskCard, TaskListItem, TitleSwap } from "../index";
import {
  contentTaskIconStates,
  sidebarRunIconStates,
} from "../TaskListItem/taskListItemStoryIcons";

const meta = {
  title: "App components/Tasks/Title Swap",
  component: TitleSwap,
  args: { text: "Untitled", identity: "task" },
  parameters: { layout: "fullscreen" },
} satisfies Meta<typeof TitleSwap>;

export default meta;
type Story = StoryObj<typeof meta>;

// Two batches a Router might write with internal.update_conversation_titles.
const batches = [
  [
    "Draft launch notes",
    "Login timeout bug",
    "Family onboarding plan",
    "Release notes",
  ],
  [
    "🚀 Launch checklist",
    "🐛 修复登录超时",
    "👨‍👩‍👧 Family onboarding 🇯🇵 rollout kickoff plan for the Tokyo team",
    "✅ Release notes · v2.4",
  ],
] as const;

const ids = ["t1", "t2", "t3", "t4"];

export const AgentRenamesTasks: Story = {
  name: "Agent renames Tasks",
  render: function Render() {
    const [batch, setBatch] = useState(0);
    const titles = batches[batch]!;
    return (
      <div className="flex min-h-screen flex-col items-start gap-xl bg-secondary p-3xl">
        <Button onPress={() => setBatch((current) => 1 - current)}>
          Agent renames Tasks
        </Button>
        <div className="flex flex-wrap items-start gap-xl">
          <div className="flex w-[260px] flex-col gap-xxs rounded-xl bg-primary p-md">
            {ids.map((id, index) => (
              <TaskListItem
                icon={sidebarRunIconStates.success.renderIcon()}
                key={id}
                layout="sidebar"
                title={titles[index]!}
                titleIdentity={id}
              />
            ))}
          </div>
          <div className="flex w-[420px] flex-col gap-xxs rounded-xl bg-primary p-md">
            {ids.map((id, index) => (
              <TaskListItem
                icon={contentTaskIconStates["in-progress"].renderIcon()}
                key={id}
                layout="content"
                tail="2m"
                title={titles[index]!}
                titleIdentity={id}
              />
            ))}
          </div>
          <div className="flex w-[240px] flex-col gap-md">
            {ids.slice(0, 2).map((id, index) => (
              <TaskCard
                footer="Created May 9"
                icon={contentTaskIconStates["in-progress"].renderIcon()}
                key={id}
                title={titles[index + 2]!}
                titleClassName="line-clamp-2"
                titleIdentity={id}
              />
            ))}
          </div>
        </div>
      </div>
    );
  },
};
