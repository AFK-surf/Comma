import "../../../../../packages/app/src/styles.css";

import {
  AiActivity,
  AiWorkerActivity,
  MarkdownStream,
  type AiActivityEvent,
} from "@comma/ui";
import { StrictMode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { ParticipantStatusSlot } from "../../../../../packages/app/src/components/chat/thread/activity/ActivityLine";
import type { ChatParticipantStatus } from "../../../../../packages/app/src/components/chat/model/conversationChannel";

if (new URLSearchParams(window.location.search).has("manualReducedMotion")) {
  document.documentElement.setAttribute("data-comma-reduced-motion", "true");
}

type MainProcessStepStage =
  | "active-execution"
  | "active-thinking"
  | "error"
  | "stopped";

declare global {
  interface Window {
    aiActivityFixture?: {
      burst: () => void;
      finish: () => void;
      revealHistory: () => void;
      setMainProcessStep: (stage: MainProcessStepStage) => void;
    };
  }
}

const resultMarkdown = [
  "## Compression complete",
  "",
  "- Output: `1-compressed.mp4`",
  "- Reduction: **86.6% smaller**",
].join("\n");

const longHistory = Array.from({ length: 9 }, (_, index) => ({
  id: `history-${index}`,
  phase: "thinking" as const,
  status: "complete" as const,
  summary: `Activity event ${index + 1}`,
})) satisfies AiActivityEvent[];

const workerMessages = [
  {
    content: "Compress 1.mp4 and report back.",
    id: "assignment",
    sender: "Router",
  },
  {
    content: "The compression result is ready.",
    id: "result",
    sender: "Worker",
  },
] as const;

const rapidFrames = [
  { activityKey: "rapid-thinking:1", phase: "thinking", summary: "Thinking" },
  { activityKey: "rapid-thinking:2", phase: "thinking", summary: "Reading files" },
  {
    activityKey: "rapid-thinking:3",
    phase: "thinking",
    summary: "Planning changes",
  },
  { activityKey: "rapid-thinking:4", phase: "thinking", summary: "Searching code" },
  {
    activityKey: "rapid-thinking:5",
    phase: "thinking",
    summary: "Checking behavior",
  },
  {
    activityKey: "rapid-thinking:6",
    phase: "thinking",
    summary: "Editing components",
  },
  {
    activityKey: "rapid-thinking:7",
    phase: "thinking",
    summary: "Reviewing output",
  },
  { activityKey: "rapid-thinking:8", phase: "thinking", summary: "Preparing tests" },
  {
    activityKey: "rapid-thinking:9",
    phase: "thinking",
    summary: "Checking results",
  },
  { activityKey: "rapid-execution:10", phase: "execution", summary: "Running tests" },
] as const;

function mainProcessParticipantStatus(
  stage: MainProcessStepStage
): ChatParticipantStatus {
  switch (stage) {
    case "active-execution":
      return {
        conversationId: "main-process-conversation",
        participantId: "main-process-participant",
        state: "active",
        status: "is executing a tool...",
        updatedAt: 2,
      };
    case "active-thinking":
      return {
        conversationId: "main-process-conversation",
        participantId: "main-process-participant",
        state: "active",
        status: "is thinking...",
        updatedAt: 1,
      };
    case "error":
      return {
        conversationId: "main-process-conversation",
        participantId: "main-process-participant",
        state: "error",
        status: "error: task.create failed.",
        updatedAt: 3,
      };
    case "stopped":
      return {
        conversationId: "main-process-conversation",
        participantId: "main-process-participant",
        state: "stopped",
        status: "",
        updatedAt: 4,
      };
  }
}
function AiActivityFixture() {
  const [complete, setComplete] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [originExpanded, setOriginExpanded] = useState(false);
  const [rapidFrame, setRapidFrame] = useState(0);
  const [stableHistoryVisible, setStableHistoryVisible] = useState(false);
  const [mainProcessStep, setMainProcessStep] =
    useState<MainProcessStepStage>("active-thinking");
  const burstTimersRef = useRef<number[]>([]);

  useEffect(() => {
    window.aiActivityFixture = {
      burst: () => {
        burstTimersRef.current.forEach((timer) => window.clearTimeout(timer));
        burstTimersRef.current = [];
        setRapidFrame(0);
        rapidFrames.slice(1).forEach((_, index) => {
          const timer = window.setTimeout(
            () => setRapidFrame(index + 1),
            (index + 1) * 30
          );
          burstTimersRef.current.push(timer);
        });
      },
      finish: () => setComplete(true),
      revealHistory: () => setStableHistoryVisible(true),
      setMainProcessStep,
    };

    return () => {
      burstTimersRef.current.forEach((timer) => window.clearTimeout(timer));
      delete window.aiActivityFixture;
    };
  }, []);

  const rapidActivity = rapidFrames[rapidFrame]!;

  return (
    <main
      style={{
        background: "var(--color-bg-primary)",
        color: "var(--color-text-primary)",
        minHeight: "100vh",
        padding: 32,
      }}
    >
      <section
        data-testid="ai-activity-fixture"
        style={{ margin: "0 auto", maxWidth: 744 }}
      >
        <AiActivity
          activityKey={complete ? "complete" : "thinking"}
          collapseOnComplete
          details={
            <AiWorkerActivity
              messages={complete ? workerMessages : workerMessages.slice(0, 1)}
              status={complete ? "complete" : "running"}
            />
          }
          expanded={expanded}
          onExpandedChange={setExpanded}
          phase={complete ? "messaging" : "thinking"}
          result={
            complete ? (
              <MarkdownStream
                animation="none"
                content={resultMarkdown}
                final
                streamId="ai-activity-e2e-result"
              />
            ) : undefined
          }
          shimmer={!complete}
          status={complete ? "complete" : "running"}
          summary={complete ? "Worked for 17 seconds" : "Thinking"}
        />
        <button data-testid="after-activity" type="button">
          After activity
        </button>
        <AiActivity
          activityKey="origin-regression"
          data-testid="origin-activity"
          events={longHistory.slice(0, 3)}
          expanded={originExpanded}
          onExpandedChange={setOriginExpanded}
          phase="thinking"
          status="complete"
          summary="Thought for 7 seconds"
        />
        <AiActivity
          activityKey="long-history"
          data-testid="long-history"
          defaultExpanded
          events={longHistory}
          phase="messaging"
          status="complete"
          summary="Worked through long history"
        />
        <AiActivity
          activityKey={rapidActivity.activityKey}
          data-testid="rapid-activity"
          phase={rapidActivity.phase}
          shimmer={false}
          status="running"
          summary={rapidActivity.summary}
        />
        <AiActivity
          activityKey={
            stableHistoryVisible ? "stable-public-work" : "stable-generic-thinking"
          }
          data-testid="stable-history-handoff"
          events={stableHistoryVisible ? [longHistory[0]!] : []}
          phase={stableHistoryVisible ? "execution" : "thinking"}
          shimmer={!stableHistoryVisible}
          status="running"
          summary={stableHistoryVisible ? "Reading the workspace" : "Thinking"}
        />
        <AiActivity
          activityKey="bounded-shimmer"
          data-testid="bounded-shimmer-activity"
          phase="thinking"
          shimmer
          status="running"
          summary="Analyzing the workspace before preparing a response"
        />
        {/* Match the production chat column's 744px maximum: a failed card is
            the chat notice frame, so it takes the column at every copy length
            and only wraps once the copy outgrows it. */}
        <section data-testid="failed-card-fixture" style={{ width: "100%" }}>
          <AiActivity
            activityKey="failed-short"
            data-testid="failed-short-activity"
            phase="execution"
            status="failed"
            summary="Searching the web"
          />
          <AiActivity
            activityKey="failed-medium"
            data-testid="failed-medium-activity"
            phase="execution"
            status="failed"
            summary="Searching the web for the release notes that explain this failure"
          />
          <AiActivity
            activityKey="failed-oversized"
            data-testid="failed-oversized-activity"
            phase="execution"
            status="failed"
            summary="Searching the web for release notes, checking deployment logs, validating the failing request, and preparing a clear recovery message for this conversation"
          />
        </section>
        <section data-testid="main-process-step-fixture">
          <ParticipantStatusSlot
            participantStatus={mainProcessParticipantStatus(mainProcessStep)}
          />
        </section>
      </section>
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <AiActivityFixture />
  </StrictMode>
);
