import { z } from "zod";

export const SystemMessage = z.object({
  type: z.literal("system"),
  content: z.string(),
  timestamp: z.coerce.date(),
});
export type SystemMessage = z.infer<typeof SystemMessage>;

export const UserMessage = z.object({
  type: z.literal("user"),
  content: z.string(),
  timestamp: z.coerce.date(),
});
export type UserMessage = z.infer<typeof UserMessage>;

export const AssistantMessage = z.object({
  type: z.literal("assistant"),
  content: z.string().optional(),
  model: z.string().optional(),
  timestamp: z.coerce.date(),
});
export type AssistantMessage = z.infer<typeof AssistantMessage>;

export const ToolCall = z.object({
  type: z.literal("tool_call"),
  id: z.string(),
  name: z.string(),
  arguments: z.json(),
  timestamp: z.coerce.date(),
});
export type ToolCall = z.infer<typeof ToolCall>;

export const ToolResult = z.object({
  type: z.literal("tool_result"),
  toolCallId: z.string(),
  name: z.string(),
  output: z.json(),
  timestamp: z.coerce.date(),
  durationMs: z.number().optional(),
  status: z.string().optional(),
  errorClass: z.string().optional(),
  errorMessage: z.string().optional(),
});
export type ToolResult = z.infer<typeof ToolResult>;

export const TrajectoryStep = z.discriminatedUnion("type", [
  SystemMessage,
  UserMessage,
  AssistantMessage,
  ToolCall,
  ToolResult,
]);
export type TrajectoryStep = z.infer<typeof TrajectoryStep>;

export const Trajectory = z.object({
  id: z.string(),
  steps: z.array(TrajectoryStep),
});
export type Trajectory = z.infer<typeof Trajectory>;

export const Trajectories = z.array(Trajectory).superRefine((trajectories, context) => {
  const ids = new Set<string>();
  trajectories.forEach((trajectory, index) => {
    if (ids.has(trajectory.id)) {
      context.addIssue({
        code: "custom",
        path: [index, "id"],
        message: `duplicate trajectory id: ${trajectory.id}`,
      });
    }
    ids.add(trajectory.id);
  });
});
export type Trajectories = z.infer<typeof Trajectories>;
