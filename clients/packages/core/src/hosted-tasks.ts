// The Tasks Comma's server does not keep (a Task a station hosts, stations/conversation.ts): what a Task's list and
// page change of one is made where it is kept, and its facts read from there. It has no Worker of Comma's.
import type { CoreError, Topic } from "@comma/core-kernel";
import type { Effect } from "effect";
import type { Account } from "./account.ts";
import type { TaskSummary } from "./contract.ts";

export interface HostedTasks {
  owns(conversation: string): boolean;
  rename(
    group: string,
    conversation: string,
    title: string
  ): Effect.Effect<void, CoreError>;
  setLabels(
    group: string,
    conversation: string,
    labels: string[]
  ): Effect.Effect<void, CoreError>;
  /** Stops its Worker. */
  cancel(group: string, conversation: string): Effect.Effect<void, CoreError>;
  /** Accepts its review: it is done. */
  accept(group: string, conversation: string): Effect.Effect<void, CoreError>;
  /** Archives it (`archived`) or takes it out of the archive, where it is kept: every list shows it so at once. */
  archive(
    group: string,
    conversation: string,
    archived: boolean
  ): Effect.Effect<void, CoreError>;
  /** A Group's archived ones, newest change first, as summaries. */
  archived(account: Account, group: string): TaskSummary[];
  /** Keeps what they are current while `topic` (an archived list) shows them; `stop` when it no longer does. */
  keep(topic: Topic): Effect.Effect<void>;
  stop(topic: Topic): void;
  /** Keeps it at the top of the person's list in its Group (`pinned`) or lets it go, where it is kept. */
  pin(
    group: string,
    conversation: string,
    pinned: boolean
  ): Effect.Effect<void, CoreError>;
  /** A Group's pinned ones, first pinned first; `showPins` while a surface shows a Group's pins, `hidePins` after. */
  pinned(account: Account, group: string): string[];
  showPins(group: string): void;
  hidePins(group: string): void;
  /** Its facts, as a summary has them; null where this device knows none. */
  summary(account: Account, group: string, id: string): TaskSummary | null;
}
