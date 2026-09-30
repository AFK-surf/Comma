import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect, useMemo, useState } from "react";
import { expect } from "storybook/test";
import { Button } from "../Button";
import { MarkdownStream } from "../markdown-stream";
import { AiActivity, AiWorkerActivity } from "./AiActivity";
import {
  compressionChoseCompression,
  compressionCompressedVideo,
  compressionInspectedVideo,
  compressionLifecycleScenario,
  compressionRouterSummaryEvents,
  compressionVerifiedOutput,
  flattenLifecycleStages,
  type LifecycleScenario,
} from "./AiActivity.lifecycle-fixtures";

const compressionResult = (
  <MarkdownStream
    animation="none"
    content={compressionLifecycleScenario.resultMarkdown}
    final
  />
);

function LifecycleDemo({ scenario }: { scenario: LifecycleScenario }) {
  const [run, setRun] = useState(0);
  const [stage, setStage] = useState(0);
  const [traceExpanded, setTraceExpanded] = useState(false);
  const stages = useMemo(
    () => flattenLifecycleStages(scenario.segments),
    [scenario.segments]
  );
  const activeStage = stages[stage] ?? stages[0]!;
  const lifecycleComplete = stage >= stages.length - 1;
  // Thinking is the initialization surface. It remains visible until the
  // activity stream publishes its first feedback; the story timer only mocks
  // that external feedback arriving.
  const lifecycleThinking = stage === 0;
  const elapsedSeconds = Math.max(
    1,
    Math.ceil((stage * scenario.feedbackIntervalMs) / 1000)
  );
  const lifecycleActivityKey = lifecycleComplete
    ? "lifecycle-complete"
    : lifecycleThinking
      ? "lifecycle-thinking"
      : "lifecycle-working";
  const lifecycleSummary = lifecycleComplete ? (
    scenario.completedSummary
  ) : lifecycleThinking ? (
    "Thinking"
  ) : (
    <>
      <span aria-hidden className="comma-ai-activity-elapsed">
        Working in {elapsedSeconds} {elapsedSeconds === 1 ? "second" : "seconds"}
      </span>
      <span className="sr-only">Working</span>
    </>
  );

  useEffect(() => {
    if (stage >= stages.length - 1) return;
    const timeout = window.setTimeout(
      () => setStage((current) => current + 1),
      scenario.feedbackIntervalMs
    );
    return () => window.clearTimeout(timeout);
  }, [run, scenario.feedbackIntervalMs, stage, stages.length]);

  useEffect(() => {
    if (lifecycleComplete) {
      setTraceExpanded(false);
    } else if (stage === 1) {
      setTraceExpanded(true);
    }
  }, [lifecycleComplete, stage]);

  const replay = () => {
    setStage(0);
    setTraceExpanded(false);
    setRun((current) => current + 1);
  };

  const lifecycleDetails = (
    <div className="comma-ai-activity-flow" key={run}>
      {scenario.segments
        .slice(0, activeStage.segmentIndex + 1)
        .map((segment, segmentIndex) => {
          const frameIndex =
            segmentIndex < activeStage.segmentIndex
              ? segment.frames.length - 1
              : activeStage.frameIndex;

          if (segment.kind === "worker") {
            const workerFrame = segment.frames[frameIndex] ?? segment.frames[0]!;

            return (
              <div
                className="comma-ai-activity-flow-turn"
                data-initial={segmentIndex === 0 ? "true" : "false"}
                key={segment.id}
              >
                {segment.publicSummary ? (
                  <output className="comma-ai-activity-flow-summary">
                    <MarkdownStream
                      animation="none"
                      content={segment.publicSummary}
                      final
                    />
                  </output>
                ) : null}
                <AiWorkerActivity
                  actor={segment.actor}
                  messages={workerFrame.messages}
                  status={workerFrame.status}
                />
              </div>
            );
          }

          const routerFrame = segment.frames[frameIndex] ?? segment.frames[0]!;

          return (
            <div
              className="comma-ai-activity-flow-turn"
              data-initial={segmentIndex === 0 ? "true" : "false"}
              key={segment.id}
            >
              {segment.publicSummary ? (
                <output className="comma-ai-activity-flow-summary">
                  <MarkdownStream
                    animation="none"
                    content={segment.publicSummary}
                    final
                  />
                </output>
              ) : null}
              <AiActivity
                activityKey={routerFrame.activityKey}
                collapseOnComplete
                defaultExpanded
                events={routerFrame.events}
                phase={routerFrame.phase}
                status={routerFrame.status}
                summary={routerFrame.summary}
                {...(routerFrame.toolName ? { toolName: routerFrame.toolName } : {})}
              />
            </div>
          );
        })}
    </div>
  );

  return (
    <div className="grid gap-lg">
      <div className="flex justify-end">
        <Button hierarchy="secondary-gray" onPress={replay} size="sm">
          Replay lifecycle
        </Button>
      </div>
      <AiActivity
        activityKey={lifecycleActivityKey}
        details={lifecycleDetails}
        expanded={traceExpanded}
        key={run}
        onExpandedChange={setTraceExpanded}
        phase={lifecycleComplete ? "messaging" : "thinking"}
        result={
          lifecycleComplete ? (
            <MarkdownStream animation="none" content={scenario.resultMarkdown} final />
          ) : undefined
        }
        status={lifecycleComplete ? "complete" : "running"}
        summary={lifecycleSummary}
      />
    </div>
  );
}

function AgentStatesDemo() {
  return (
    <div className="grid gap-xl">
      <AiWorkerActivity
        actor="Worker"
        messages={[
          {
            content: "Compress 1.mp4 and report back.",
            id: "assignment",
            sender: "Router",
          },
          {
            content: "Compression is running.",
            id: "progress",
            sender: "Worker",
          },
        ]}
        status="running"
      />
      <AiWorkerActivity actor="Worker" status="running" />
      <AiWorkerActivity actor="Worker" status="complete" />
      <AiWorkerActivity actor="Worker" status="failed" />
    </div>
  );
}

const meta = {
  title: "App components/AI activity",
  component: AiActivity,
  parameters: {
    layout: "padded",
  },
  decorators: [
    (Story) => (
      <div className="mx-auto w-[min(680px,calc(100vw-var(--spacing-3xl)))]">
        <Story />
      </div>
    ),
  ],
  args: {
    activityKey: "needs-review",
    defaultExpanded: true,
    events: compressionRouterSummaryEvents,
    phase: "messaging",
    result: compressionResult,
    status: "complete",
    summary: "Summarized the result",
  },
} satisfies Meta<typeof AiActivity>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Result: Story = {};

/** Router → Worker → Router → Worker → Router summary. */
export const Lifecycle: Story = {
  render: () => <LifecycleDemo scenario={compressionLifecycleScenario} />,
  play: async () => {
    const stories = await import("./AiActivity.stories");

    expect(stories).toHaveProperty("Lifecycle");
    expect(stories).not.toHaveProperty("OpenAiNewsWebsiteLifecycle");
  },
};

export const AgentStates: Story = {
  render: () => <AgentStatesDemo />,
};

export const Thinking: Story = {
  args: {
    activityKey: "thinking",
    events: [],
    phase: "thinking",
    result: undefined,
    status: "running",
    summary: "Choosing a compression profile",
  },
};

export const ToolCall: Story = {
  args: {
    activityKey: "tool-call",
    defaultExpanded: true,
    events: [compressionInspectedVideo],
    phase: "execution",
    result: undefined,
    status: "running",
    summary: "Compressing 1.mp4",
    toolName: "env.exec",
  },
};

export const Messaging: Story = {
  args: {
    activityKey: "messaging",
    defaultExpanded: true,
    events: [compressionCompressedVideo, compressionVerifiedOutput],
    phase: "messaging",
    result: undefined,
    status: "running",
    summary: "Reporting completion to the Router",
  },
};

export const SafeError: Story = {
  args: {
    activityKey: "tool-error",
    defaultExpanded: true,
    events: [
      compressionInspectedVideo,
      compressionChoseCompression,
      {
        id: "tool-error",
        phase: "execution",
        status: "failed",
        summary: "Compressed the video",
        toolName: "env.exec",
      },
    ],
    phase: "execution",
    result: undefined,
    status: "failed",
    summary: "The compression command failed",
    toolName: "env.exec",
  },
};
