// A UI's side of a core: no Effect in here.
export {
  CoreClient,
  CoreError,
  topicKey,
  type Channel,
  type ClientOptions,
  type CoreFailure,
  type CoreFault,
  type ErrorBody,
  type Opener,
  type Topic,
} from "./client.ts";
export { applyDelta, type DeltaOp } from "./apply.ts";
