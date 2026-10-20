// The domain-free base of a client core; the Comma client core
// (packages/core) is built on it: the runner its fibers run on, its topics and their keyed deltas, the scheduler
// its sync runs on, the `doing` of calls under way, the protocol to its UIs and its single-writer SQLite. The UI's side
// (`./client`) and the web's worker relay (`./web-worker`) use no Effect.
export { Runner, TurnScheduler, type Scoped } from "./runtime.ts";
export {
  CoreError,
  HostError,
  asCoreError,
  type ErrorBody,
  type Result,
} from "./error.ts";
export { diff, apply, largerThan, type Op, type Segment } from "./delta.ts";
export {
  diffKeyed,
  applyKeyed,
  keyOf,
  heavier,
  type AnyOp,
  type Key,
  type KeyedOp,
  type Spec,
} from "./collections.ts";
export {
  parseTopic,
  parseClientMessage,
  topicKey,
  sameTopic,
  type ClientId,
  type ClientMessage,
  type CoreMessage,
  type Param,
  type ParamSpec,
  type RequestId,
  type Topic,
  type TopicParams,
  type TopicSpecs,
} from "./protocol.ts";
export {
  Store,
  Watch,
  sameValue,
  COALESCE_MS,
  EVICT_AFTER_MS,
  type Source,
  type StoreOptions,
  type Value,
} from "./store.ts";
export { Scheduler, Priority } from "./scheduler.ts";
export { Doing, FAILED_SHOWN_MS, type DoingItem } from "./doing.ts";
export {
  Kernel,
  DOING,
  type Call,
  type CallContext,
  type KernelOptions,
} from "./kernel.ts";
export {
  SqlError,
  sqlError,
  transaction,
  migrate,
  type Sql,
  type SqlRow,
  type SqlValue,
} from "./sql.ts";
export {
  equal,
  isObject,
  compareKeys,
  sorted,
  toJson,
  toJsonBytes,
  parseJson,
  utf8,
  fromUtf8,
  type Json,
  type JsonObject,
} from "./json.ts";
