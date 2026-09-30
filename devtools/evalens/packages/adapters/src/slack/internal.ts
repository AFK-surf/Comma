import { WebClient } from "@slack/web-api";
import { z, type JSONType } from "zod";

import type {
  SlackAdapterOptions,
  SlackObservedFile,
  SlackObservedMessage,
  SlackObservedReaction,
  SlackPostedMessage,
  SlackWebClient,
} from "./types";

export type SlackJsonObject = Record<string, JSONType>;

const SlackJsonObjectSchema = z.record(z.string(), z.json());
const SlackObservedFilePayloadSchema = z
  .object({
    id: z.string().min(1),
    name: z.string().optional(),
    mimetype: z.string().optional(),
    size: z.number().finite().optional(),
    permalink: z.string().optional(),
    url_private_download: z.string().optional(),
    url_private: z.string().optional(),
  })
  .loose();
const SlackObservedReactionPayloadSchema = z
  .object({
    name: z.string().min(1),
    count: z.number().finite().optional(),
    users: z.array(z.string()).default([]),
  })
  .loose();
const SlackObservedMessagePayloadSchema = z
  .object({
    ts: z.string().min(1),
    text: z.string().default(""),
    user: z.string().optional(),
    bot_id: z.string().optional(),
    thread_ts: z.string().optional(),
    subtype: z.string().optional(),
    files: z.array(SlackObservedFilePayloadSchema).default([]),
    reactions: z.array(SlackObservedReactionPayloadSchema).default([]),
  })
  .loose();

export function createSlackClient(config: SlackAdapterOptions): SlackWebClient {
  return new WebClient(config.token) as unknown as SlackWebClient;
}

export class SlackClientBoundary {
  private readonly allowedChannelIds: ReadonlySet<string>;

  constructor(
    readonly config: SlackAdapterOptions,
    protected readonly client: SlackWebClient = createSlackClient(config)
  ) {
    this.allowedChannelIds = new Set(config.allowedChannelIds);
  }

  assertAllowedChannel(channelId: string): void {
    if (!this.allowedChannelIds.has(channelId)) {
      throw new Error(`Slack channel is not allowed by adapter config: ${channelId}`);
    }
  }
}

export function observedMessage(value: unknown): SlackObservedMessage {
  const message = parseBoundary(
    SlackObservedMessagePayloadSchema,
    value,
    "Slack message"
  );
  return {
    ts: message.ts,
    text: message.text,
    ...(message.user ? { userId: message.user } : {}),
    ...(message.bot_id ? { botId: message.bot_id } : {}),
    ...(message.thread_ts ? { threadTs: message.thread_ts } : {}),
    ...(message.subtype ? { subtype: message.subtype } : {}),
    files: message.files.map(observedFile),
    reactions: message.reactions.map(observedReaction),
  };
}

export function postedMessage(
  response: Awaited<ReturnType<SlackWebClient["chat"]["postMessage"]>>,
  text: string,
  threadTs?: string
): SlackPostedMessage {
  if (!response.ok || !response.channel || !response.ts) {
    throw new Error("Slack chat.postMessage did not return channel and ts");
  }
  return {
    channelId: response.channel,
    ts: response.ts,
    text,
    ...(threadTs ? { threadTs } : {}),
  };
}

export function parseSlackObject(value: unknown, label: string): SlackJsonObject {
  return parseBoundary(SlackJsonObjectSchema, value, label);
}

function observedFile(
  file: z.output<typeof SlackObservedFilePayloadSchema>
): SlackObservedFile {
  const urlPrivate = file.url_private_download ?? file.url_private;
  return {
    id: file.id,
    ...(file.name ? { name: file.name } : {}),
    ...(file.mimetype ? { mimetype: file.mimetype } : {}),
    ...(file.size === undefined ? {} : { size: file.size }),
    ...(file.permalink ? { permalink: file.permalink } : {}),
    ...(urlPrivate ? { urlPrivate } : {}),
  };
}

function observedReaction(
  reaction: z.output<typeof SlackObservedReactionPayloadSchema>
): SlackObservedReaction {
  return {
    name: reaction.name,
    ...(reaction.count === undefined ? {} : { count: reaction.count }),
    userIds: reaction.users,
  };
}

function parseBoundary<Output>(
  schema: z.ZodType<Output>,
  value: unknown,
  label: string
): Output {
  const parsed = schema.safeParse(value);
  if (parsed.success) return parsed.data;
  throw new Error(`${label} is malformed: ${z.prettifyError(parsed.error)}`);
}
