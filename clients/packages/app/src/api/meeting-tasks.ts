import { z } from "zod";

export const meetingTaskReceiptSchema = z.object({
  group_id: z.string(),
  task_id: z.string(),
  status: z.string(),
  meeting: z
    .object({
      occurrence_id: z.string(),
      name: z.string(),
      archive_date: z.string(),
      started_at: z.number(),
      phase: z.enum([
        "awaiting_recording",
        "recording",
        "paused",
        "dismissed",
        "discarded",
        "saving",
        "processing",
        "saved",
      ]),
      version: z.number().int().nonnegative(),
    })
    .strip(),
});
export type MeetingTaskReceipt = z.infer<typeof meetingTaskReceiptSchema>;
export type MeetingTaskEntry = Pick<
  MeetingTaskReceipt["meeting"],
  "occurrence_id" | "name" | "archive_date" | "started_at"
>;
export type MeetingTaskCommand = { version: number } & (
  | { action: "recording" | "paused" | "dismiss" | "discard" }
  | {
      action: "finalize";
      smart_summary: boolean;
      recording: {
        recording_id: string;
        durationMs: number;
        driveFile: { space: string; path: string };
      };
      file: { localFileRef: string; name: string; mediaType: string; size: number };
    }
);
