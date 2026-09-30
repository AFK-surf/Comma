import { Trajectories } from "@evalens/core/message";
import type { Trajectory, TrajectoryStep } from "@evalens/core/message";
import { z } from "zod";

export type ToolWarning =
  "pending" | "orphan-result" | "duplicate-result" | "name-mismatch";

export type TrajectoryEvent = {
  key: string;
  trajectoryId: string;
  laneIndex: number;
  stepIndex: number;
  timestamp: Date;
  step: TrajectoryStep;
  result?: Extract<TrajectoryStep, { type: "tool_result" }>;
  resultStepIndex?: number;
  warnings: ToolWarning[];
  durationMs?: number;
  durationDerived?: boolean;
  searchText: string;
};

export type ParsedTrajectories = {
  trajectories: Trajectory[];
  eventsByTrajectory: Map<string, TrajectoryEvent[]>;
};

export function defaultTrajectoryMode(count: number): "grouped" | "merged" {
  return count > 1 ? "merged" : "grouped";
}

export function parseTrajectories(value: unknown): ParsedTrajectories {
  const trajectories = Trajectories.parse(value);
  return {
    trajectories,
    eventsByTrajectory: new Map(
      trajectories.map((trajectory, laneIndex) => [
        trajectory.id,
        buildTrajectoryEvents(trajectory, laneIndex),
      ])
    ),
  };
}

export function formatTrajectoryParseError(error: unknown): string {
  if (!(error instanceof z.ZodError)) {
    return error instanceof Error ? error.message : String(error);
  }
  return error.issues
    .map((issue) => {
      const [trajectoryIndex, ...rest] = issue.path;
      const path =
        typeof trajectoryIndex === "number"
          ? `trajectory[${trajectoryIndex}]${rest
              .map((part) =>
                typeof part === "number" ? `[${part}]` : `.${String(part)}`
              )
              .join("")}`
          : issue.path.length
            ? `trajectory.${issue.path.map(String).join(".")}`
            : "trajectory";
      return `${path}: ${issue.message}`;
    })
    .join("\n");
}

export function buildTrajectoryEvents(
  trajectory: Trajectory,
  laneIndex: number
): TrajectoryEvent[] {
  const calls = new Map<string, { event: TrajectoryEvent; resultCount: number }>();
  const events: TrajectoryEvent[] = [];

  trajectory.steps.forEach((step, stepIndex) => {
    if (step.type === "tool_result") {
      const call = calls.get(step.toolCallId);
      if (!call) {
        events.push(
          createEvent(trajectory.id, laneIndex, stepIndex, step, ["orphan-result"])
        );
        return;
      }
      call.resultCount += 1;
      if (call.resultCount > 1) {
        events.push(
          createEvent(trajectory.id, laneIndex, stepIndex, step, ["duplicate-result"])
        );
        return;
      }
      call.event.result = step;
      call.event.resultStepIndex = stepIndex;
      call.event.durationMs =
        step.durationMs ?? step.timestamp.getTime() - call.event.timestamp.getTime();
      call.event.durationDerived = step.durationMs === undefined;
      if (call.event.step.type === "tool_call" && step.name !== call.event.step.name) {
        call.event.warnings.push("name-mismatch");
      }
      call.event.searchText += ` ${step.name} ${JSON.stringify(step.output)}`;
      return;
    }

    const event = createEvent(trajectory.id, laneIndex, stepIndex, step);
    events.push(event);
    if (step.type === "tool_call") {
      calls.set(step.id, { event, resultCount: 0 });
    }
  });

  for (const { event, resultCount } of calls.values()) {
    if (resultCount === 0) event.warnings.push("pending");
  }
  return events;
}

export function mergeTrajectoryEvents(
  eventsByTrajectory: ReadonlyMap<string, readonly TrajectoryEvent[]>,
  laneOrder: readonly string[]
): TrajectoryEvent[] {
  const laneRank = new Map(laneOrder.map((id, index) => [id, index]));
  return laneOrder
    .flatMap((id) => eventsByTrajectory.get(id) ?? [])
    .toSorted(
      (left, right) =>
        left.timestamp.getTime() - right.timestamp.getTime() ||
        (laneRank.get(left.trajectoryId) ?? Number.MAX_SAFE_INTEGER) -
          (laneRank.get(right.trajectoryId) ?? Number.MAX_SAFE_INTEGER) ||
        left.stepIndex - right.stepIndex
    );
}

export function eventMatches(event: TrajectoryEvent, query: string): boolean {
  const normalized = query.trim().toLocaleLowerCase();
  return !normalized || event.searchText.toLocaleLowerCase().includes(normalized);
}

export function hasTimestampRegression(events: readonly TrajectoryEvent[]): boolean {
  return events.some(
    (event, index) => index > 0 && event.timestamp < events[index - 1]!.timestamp
  );
}

function createEvent(
  trajectoryId: string,
  laneIndex: number,
  stepIndex: number,
  step: TrajectoryStep,
  warnings: ToolWarning[] = []
): TrajectoryEvent {
  return {
    key: `${trajectoryId}:${stepIndex}`,
    trajectoryId,
    laneIndex,
    stepIndex,
    timestamp: step.timestamp,
    step,
    warnings,
    searchText: searchableStep(trajectoryId, step),
  };
}

function searchableStep(trajectoryId: string, step: TrajectoryStep): string {
  switch (step.type) {
    case "system":
    case "user":
      return `${trajectoryId} ${step.content}`;
    case "assistant":
      return `${trajectoryId} ${step.content ?? ""} ${step.model ?? ""}`;
    case "tool_call":
      return `${trajectoryId} ${step.name} ${JSON.stringify(step.arguments)}`;
    case "tool_result":
      return `${trajectoryId} ${step.name} ${JSON.stringify(step.output)}`;
  }
}
