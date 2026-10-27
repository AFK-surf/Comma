import type { Meta, StoryObj } from "@storybook/react-vite";
import { uiClock } from "@comma/ui/clock";
import "../../../../styles.css";
import { ParticipantStatusSlot } from "./ActivityLine";

const meta = {
  title: "App components/Chat activity",
  component: ParticipantStatusSlot,
  args: {
    participantStatus: {
      conversationId: "preview",
      participantId: "router",
      actorRole: "router",
      state: "active",
      status: "is thinking...",
      updatedAt: 1,
    },
  },
  decorators: [
    (Story) => (
      <div style={{ width: 320, padding: 24 }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof ParticipantStatusSlot>;

export default meta;
type Story = StoryObj<typeof meta>;

export const RouterThinking: Story = {};

export const WorkingOnWeChat: Story = {
  args: {
    participantStatus: { ...meta.args.participantStatus, workingProvider: "wechat" },
  },
};

export const WorkingOnTelegram: Story = {
  args: {
    participantStatus: { ...meta.args.participantStatus, workingProvider: "telegram" },
  },
};

export const WorkingOnSignal: Story = {
  args: {
    participantStatus: { ...meta.args.participantStatus, workingProvider: "signal" },
  },
};

export const RouterError: Story = {
  args: {
    participantStatus: {
      ...meta.args.participantStatus,
      state: "error",
      status: "Runtime unavailable",
    },
  },
};

export const FollowingTaskWorkers: Story = {
  args: {
    participantStatus: {
      ...meta.args.participantStatus,
      workingConversationIds: ["task_report", "task_billing"],
    },
    focus: {
      groupId: "preview",
      mode: "following",
      tasks: [
        {
          conversationId: "task_report",
          title: "Weekly report",
          statusBucket: "in_progress",
          worker: {
            active: true,
            avatarId: "actor_claude",
            name: "Claude Sonnet",
            participantId: "ptp_claude",
            vendor: "anthropic",
          },
        },
        {
          conversationId: "task_billing",
          title: "Q3 billing",
          statusBucket: "in_progress",
          worker: {
            active: true,
            avatarId: "actor_codex",
            name: "GPT-5.5",
            participantId: "ptp_codex",
            vendor: "openai",
          },
        },
      ],
    },
  },
};

export const SearchingTheWeb: Story = {
  args: {
    activity: {
      phase: "execution",
      status: "running",
      summaryClass: "public",
      target: "Beijing weather today",
      toolName: "web.search",
    },
  },
};

export const LongToolCall: Story = {
  render: (args) => (
    <ParticipantStatusSlot
      {...args}
      participantStatus={{
        ...meta.args.participantStatus,
        waitTool: "cloud_vm.start",
        waitStartedAt: uiClock.now() - 12_000,
      }}
    />
  ),
};

export const WaitingForATask: Story = {
  render: (args) => (
    <ParticipantStatusSlot
      {...args}
      participantStatus={{
        ...meta.args.participantStatus,
        waiting: true,
        waitStartedAt: uiClock.now() - 42_000,
      }}
    />
  ),
};
