import type {
  AiActivityEvent,
  AiActivityPhase,
  AiActivityStatus,
  AiWorkerActivityMessage,
} from "./AiActivity";

export interface ActivityFrame {
  activityKey: string;
  events: readonly AiActivityEvent[];
  phase: AiActivityPhase;
  status: AiActivityStatus;
  summary: string;
  toolName?: string;
}

export interface WorkerFrame {
  messages: readonly AiWorkerActivityMessage[];
  status: AiActivityStatus;
}

export interface RouterSegment {
  frames: readonly ActivityFrame[];
  id: string;
  kind: "router";
  publicSummary?: string;
}

export interface WorkerSegment {
  actor: "Worker";
  frames: readonly WorkerFrame[];
  id: string;
  kind: "worker";
  publicSummary?: string;
}

export type AgentSegment = RouterSegment | WorkerSegment;

export interface LifecycleScenario {
  completedSummary: string;
  feedbackIntervalMs: number;
  id: string;
  resultMarkdown: string;
  segments: readonly AgentSegment[];
}

export interface LifecycleStage {
  frameIndex: number;
  segmentIndex: number;
}

export function flattenLifecycleStages(
  segments: readonly AgentSegment[]
): LifecycleStage[] {
  return segments.flatMap((segment, segmentIndex) =>
    segment.frames.map((_frame, frameIndex) => ({ frameIndex, segmentIndex }))
  );
}

const preparedTask = {
  id: "prepared-task",
  phase: "thinking",
  status: "complete",
  summary: "Prepared the task request",
} satisfies AiActivityEvent;

const validatedTask = {
  id: "validated-task",
  phase: "thinking",
  status: "complete",
  summary: "Validated the task scope",
} satisfies AiActivityEvent;

const locatedVideo = {
  id: "located-video",
  phase: "execution",
  status: "complete",
  summary: "Located the source video",
  toolName: "fs.read_file",
} satisfies AiActivityEvent;

const foundWorker = {
  id: "found-worker",
  phase: "execution",
  status: "complete",
  summary: "Found an available Worker",
  toolName: "agent.list",
} satisfies AiActivityEvent;

const matchedWorker = {
  id: "matched-worker",
  phase: "thinking",
  status: "complete",
  summary: "Matched the Worker capability",
} satisfies AiActivityEvent;

const createdTask = {
  id: "created-task",
  phase: "execution",
  status: "complete",
  summary: "Created the Worker task",
  toolName: "task.create",
} satisfies AiActivityEvent;

const attachedContext = {
  id: "attached-context",
  phase: "messaging",
  status: "complete",
  summary: "Attached the bounded task context",
} satisfies AiActivityEvent;

const handedOffTask = {
  id: "handed-off-task",
  phase: "messaging",
  status: "complete",
  summary: "Handed the task to the Worker",
} satisfies AiActivityEvent;

export const compressionInspectedVideo = {
  id: "inspected-video",
  phase: "execution",
  status: "complete",
  summary: "Inspected the source video",
  toolName: "env.exec",
} satisfies AiActivityEvent;

export const compressionChoseCompression = {
  id: "chose-compression",
  phase: "thinking",
  status: "complete",
  summary: "Chose a smaller H.264 profile",
} satisfies AiActivityEvent;

const reviewedPlan = {
  id: "reviewed-plan",
  phase: "thinking",
  status: "complete",
  summary: "Reviewed the Worker plan",
} satisfies AiActivityEvent;

const approvedPlan = {
  id: "approved-plan",
  phase: "messaging",
  status: "complete",
  summary: "Approved the Worker to continue",
} satisfies AiActivityEvent;

export const compressionCompressedVideo = {
  id: "compressed-video",
  phase: "execution",
  status: "complete",
  summary: "Compressed the video",
  toolName: "env.exec",
} satisfies AiActivityEvent;

export const compressionVerifiedOutput = {
  id: "verified-output",
  phase: "execution",
  status: "complete",
  summary: "Verified the compressed output",
  toolName: "env.exec",
} satisfies AiActivityEvent;

const receivedWorkerResult = {
  id: "received-worker-result",
  phase: "thinking",
  status: "complete",
  summary: "Reviewed the Worker result",
} satisfies AiActivityEvent;

const composedResult = {
  id: "composed-result",
  phase: "messaging",
  status: "complete",
  summary: "Composed the task summary",
} satisfies AiActivityEvent;

const routerDelegationEvents = [
  preparedTask,
  validatedTask,
  locatedVideo,
  compressionInspectedVideo,
  foundWorker,
  matchedWorker,
  createdTask,
  attachedContext,
  handedOffTask,
] satisfies readonly AiActivityEvent[];

const routerApprovalEvents = [
  reviewedPlan,
  approvedPlan,
] satisfies readonly AiActivityEvent[];

export const compressionRouterSummaryEvents = [
  receivedWorkerResult,
  composedResult,
] satisfies readonly AiActivityEvent[];

const compressionResultMarkdown = `**Task needs review.**

I compressed \`1.mp4\` and verified the output successfully.

- **Output:** \`1-compressed.mp4\`
- **File size:** 590.6 KB → 79.4 KB
- **Reduction:** 86.6% smaller
- **Dimensions:** 960 × 768
- **Codec:** H.264

The source dimensions were preserved, and the compressed file is ready to use.`;

const workerPlanningChat = [
  {
    content: "Compress 1.mp4 and send me a safe plan before you execute it.",
    id: "planning-assignment",
    sender: "Router",
  },
  {
    content: "I’m inspecting the source and choosing a smaller H.264 profile.",
    id: "planning-progress",
    sender: "Worker",
  },
  {
    content: "The compression plan is ready. I’m waiting for approval.",
    id: "planning-ready",
    sender: "Worker",
  },
] satisfies readonly AiWorkerActivityMessage[];

const workerExecutionChat = [
  {
    content: "Approved. Continue with the H.264 profile.",
    id: "execution-approval",
    sender: "Router",
  },
  {
    content: "Compression is running.",
    id: "execution-progress",
    sender: "Worker",
  },
  {
    content: "Compression finished. I’m verifying the output now.",
    id: "execution-verification",
    sender: "Worker",
  },
  {
    content: "Output verified. I’m sending the result back.",
    id: "execution-complete",
    sender: "Worker",
  },
] satisfies readonly AiWorkerActivityMessage[];

/**
 * Router owns the user-facing narrative. Delegated Worker work is represented
 * by a compact status boundary; its safe detail is available on hover/focus.
 */
const compressionSegments: readonly AgentSegment[] = [
  {
    id: "router-delegation",
    kind: "router",
    frames: [
      {
        activityKey: "router-thinking",
        events: [],
        phase: "thinking",
        status: "running",
        summary: "Thinking",
      },
      {
        activityKey: "validate-task",
        events: [preparedTask],
        phase: "thinking",
        status: "running",
        summary: "Validating the task scope",
      },
      {
        activityKey: "locate-video",
        events: [preparedTask, validatedTask],
        phase: "execution",
        status: "running",
        summary: "Locating the source video",
        toolName: "fs.read_file",
      },
      {
        activityKey: "inspect-video",
        events: [preparedTask, validatedTask, locatedVideo],
        phase: "execution",
        status: "running",
        summary: "Inspecting the source video",
        toolName: "env.exec",
      },
      {
        activityKey: "find-worker",
        events: [preparedTask, validatedTask, locatedVideo, compressionInspectedVideo],
        phase: "execution",
        status: "running",
        summary: "Finding an available Worker",
        toolName: "agent.list",
      },
      {
        activityKey: "match-worker",
        events: [
          preparedTask,
          validatedTask,
          locatedVideo,
          compressionInspectedVideo,
          foundWorker,
        ],
        phase: "thinking",
        status: "running",
        summary: "Matching the Worker capability",
      },
      {
        activityKey: "create-task",
        events: [
          preparedTask,
          validatedTask,
          locatedVideo,
          compressionInspectedVideo,
          foundWorker,
          matchedWorker,
        ],
        phase: "execution",
        status: "running",
        summary: "Creating the Worker task",
        toolName: "task.create",
      },
      {
        activityKey: "attach-context",
        events: [
          preparedTask,
          validatedTask,
          locatedVideo,
          compressionInspectedVideo,
          foundWorker,
          matchedWorker,
          createdTask,
        ],
        phase: "messaging",
        status: "running",
        summary: "Attaching the task context",
      },
      {
        activityKey: "hand-off-task",
        events: [
          preparedTask,
          validatedTask,
          locatedVideo,
          compressionInspectedVideo,
          foundWorker,
          matchedWorker,
          createdTask,
          attachedContext,
        ],
        phase: "messaging",
        status: "running",
        summary: "Handing the task to the Worker",
      },
      {
        activityKey: "delegated",
        events: routerDelegationEvents,
        phase: "messaging",
        status: "complete",
        summary: "Delegated in 1 second",
      },
    ],
  },
  {
    actor: "Worker",
    id: "worker-planning",
    kind: "worker",
    publicSummary: "The Worker is preparing a compression plan",
    frames: [
      {
        messages: workerPlanningChat.slice(0, 2),
        status: "running",
      },
      {
        messages: workerPlanningChat.slice(0, 2),
        status: "running",
      },
      {
        messages: workerPlanningChat,
        status: "running",
      },
      {
        messages: workerPlanningChat,
        status: "complete",
      },
    ],
  },
  {
    id: "router-approval",
    kind: "router",
    publicSummary:
      "The proposed H.264 profile keeps the source dimensions while reducing bitrate",
    frames: [
      {
        activityKey: "review-plan",
        events: [],
        phase: "thinking",
        status: "running",
        summary: "Reviewing the Worker plan",
      },
      {
        activityKey: "approve-plan",
        events: [reviewedPlan],
        phase: "messaging",
        status: "running",
        summary: "Approving the Worker to continue",
      },
      {
        activityKey: "approved",
        events: routerApprovalEvents,
        phase: "messaging",
        status: "complete",
        summary: "Approved the plan",
      },
    ],
  },
  {
    actor: "Worker",
    id: "worker-execution",
    kind: "worker",
    publicSummary: "The approved plan is ready for compression and verification",
    frames: [
      {
        messages: workerExecutionChat.slice(0, 2),
        status: "running",
      },
      {
        messages: workerExecutionChat.slice(0, 3),
        status: "running",
      },
      {
        messages: workerExecutionChat,
        status: "running",
      },
      {
        messages: workerExecutionChat,
        status: "complete",
      },
    ],
  },
  {
    id: "router-summary",
    kind: "router",
    publicSummary: "The verified output is 86.6% smaller and ready to summarize",
    frames: [
      {
        activityKey: "review-worker-result",
        events: [],
        phase: "thinking",
        status: "running",
        summary: "Reviewing the Worker result",
      },
      {
        activityKey: "compose-result",
        events: [receivedWorkerResult],
        phase: "messaging",
        status: "running",
        summary: "Composing the task summary",
      },
      {
        activityKey: "needs-review",
        events: compressionRouterSummaryEvents,
        phase: "messaging",
        status: "complete",
        summary: "Summarized the result",
      },
    ],
  },
];

export const compressionLifecycleScenario: LifecycleScenario = {
  completedSummary: "Worked for 17 seconds",
  feedbackIntervalMs: 700,
  id: "video-compression",
  resultMarkdown: compressionResultMarkdown,
  segments: compressionSegments,
};
