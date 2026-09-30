import { SlackObserver } from "../observers/slack";
import { SlackDriver } from "./driver";
import { SlackFixtureCleaner } from "./fixture-cleaner";
import { createSlackClient } from "./internal";
import type { SlackAdapterOptions, SlackWebClient } from "./types";

export type SlackEvaluationTools = {
  readonly config: SlackAdapterOptions;
  readonly driver: SlackDriver;
  readonly observer: SlackObserver;
  readonly fixtureCleaner: SlackFixtureCleaner;
};

/** Creates explicit Slack evaluation boundaries that share one official SDK client. */
export function createSlackEvaluationTools(
  config: SlackAdapterOptions,
  client: SlackWebClient = createSlackClient(config)
): SlackEvaluationTools {
  return {
    config,
    driver: new SlackDriver(config, client),
    observer: new SlackObserver(config, client),
    fixtureCleaner: new SlackFixtureCleaner(config, client),
  };
}
