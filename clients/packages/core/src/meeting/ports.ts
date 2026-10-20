// Main's meeting commands as Effects: Main's answer, or the failure it named (`MeetingPortFailure`), or a HostError
// when Main did not answer at all.
import type { HostError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { MeetingOp, MeetingOps, MeetingPorts } from "../host.ts";
import { MeetingPortFailure } from "./errors.ts";

export type MeetingPortError = HostError | MeetingPortFailure;

export function meetingCommand<O extends MeetingOp>(
  ports: MeetingPorts,
  op: O,
  input: MeetingOps[O]["input"]
): Effect.Effect<MeetingOps[O]["output"], MeetingPortError> {
  return ports
    .command(op, input)
    .pipe(
      Effect.flatMap((answer) =>
        "failure" in answer
          ? Effect.fail(new MeetingPortFailure(answer.failure))
          : Effect.succeed(answer.ok)
      )
    );
}
