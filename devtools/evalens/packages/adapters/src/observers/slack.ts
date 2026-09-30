import type {
  SlackAdapterOptions,
  SlackThreadReplyWaitResult,
  SlackObservedMessage,
  SlackWebClient,
} from "../slack/types";
import { z } from "zod";
import {
  observedMessage,
  parseSlackObject,
  SlackClientBoundary,
  type SlackJsonObject,
} from "../slack/internal";
import type { ExternalResourceObservation, ExternalResourceObserver } from "./types";
import { createExternalObservation } from "./types";

const SlackMessageListSchema = z.array(z.unknown());
const ThreadResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), messages: SlackMessageListSchema }).loose(),
  z.object({ ok: z.literal(false), error: z.string().optional() }).loose(),
]);
const PermalinkResponseSchema = z.object({ permalink: z.string().min(1) }).loose();
const HistoryResponseSchema = z.object({ messages: SlackMessageListSchema }).loose();
const ChannelInfoResponseSchema = z
  .object({ channel: z.record(z.string(), z.json()) })
  .loose();
const PinsResponseSchema = z
  .object({ items: z.array(z.record(z.string(), z.json())) })
  .loose();
const FileInfoResponseSchema = z
  .object({ file: z.record(z.string(), z.json()) })
  .loose();
const PinnedMessageSchema = z
  .object({ message: z.object({ ts: z.string().min(1) }).loose() })
  .loose();
const FileDownloadMetadataSchema = z
  .object({
    url_private_download: z.string().min(1).optional(),
    url_private: z.string().min(1).optional(),
  })
  .loose()
  .refine(
    (file) => file.url_private_download !== undefined || file.url_private !== undefined,
    "Slack file metadata must include a private download URL"
  );
const SlackErrorSchema = z
  .object({
    error: z.string().optional(),
    data: z.object({ error: z.string().optional() }).loose().optional(),
  })
  .loose();

export type SlackObservationTarget =
  | {
      kind: "thread";
      channelId: string;
      threadTs: string;
      /** When present, the thread exists only if this user has replied in it. */
      replyUserId?: string;
    }
  | { kind: "channel"; channelId: string }
  | { kind: "pin"; channelId: string; messageTs: string }
  | { kind: "file"; fileId: string };

export type SlackThreadResource = {
  channelId: string;
  threadTs: string;
  messages: SlackObservedMessage[];
};

export type SlackChannelResource = {
  channelId: string;
  metadata: SlackJsonObject;
};

export type SlackPinResource = {
  channelId: string;
  messageTs: string;
  item: SlackJsonObject;
};

export type SlackFileResource = {
  fileId: string;
  metadata: SlackJsonObject;
};

export type SlackObservation = ExternalResourceObservation<
  SlackThreadResource | SlackChannelResource | SlackPinResource | SlackFileResource
>;

/** Read-only external-result observer for Slack-backed evaluations. */
export class SlackObserver
  extends SlackClientBoundary
  implements ExternalResourceObserver<SlackObservationTarget, SlackObservation>
{
  readonly provider = "slack" as const;

  constructor(
    config: SlackAdapterOptions,
    client?: SlackWebClient,
    private readonly now: () => Date = () => new Date(),
    private readonly monotonicNow: () => number = Date.now,
    private readonly sleep: (durationMs: number) => Promise<void> = Bun.sleep,
    private readonly fetchImpl: typeof fetch = fetch
  ) {
    super(config, client);
  }

  /** Returns a read-only observer authorized for one provider-returned channel. */
  withAllowedChannel(channelId: string): SlackObserver {
    return new SlackObserver(
      {
        ...this.config,
        allowedChannelIds: [...new Set([...this.config.allowedChannelIds, channelId])],
      },
      this.client,
      this.now,
      this.monotonicNow,
      this.sleep,
      this.fetchImpl
    );
  }

  async observe(target: SlackObservationTarget): Promise<SlackObservation> {
    if (target.kind === "thread") return this.observeThread(target);
    if (target.kind === "channel") return this.observeChannel(target);
    if (target.kind === "pin") return this.observePin(target);
    return this.observeFile(target);
  }

  async getPermalink(input: { channelId: string; ts: string }): Promise<string> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.chat.getPermalink;
    if (!method) {
      throw new Error("Slack SDK method is unavailable: chat.getPermalink");
    }
    const result = parseSlackObject(
      await method.call(this.client.chat, {
        channel: input.channelId,
        message_ts: input.ts,
      }),
      "Slack chat.getPermalink response"
    );
    assertSlackSuccess("chat.getPermalink", result);
    return PermalinkResponseSchema.parse(result).permalink;
  }

  async readThread(input: {
    channelId: string;
    threadTs: string;
  }): Promise<SlackObservedMessage[]> {
    this.assertAllowedChannel(input.channelId);
    const threadTs = input.threadTs.trim();
    if (!threadTs) throw new Error("threadTs is required");
    const response = ThreadResponseSchema.parse(
      await this.client.conversations.replies({
        channel: input.channelId,
        ts: threadTs,
        limit: 100,
      })
    );
    if (!response.ok) throw slackApiError("conversations.replies", response);
    return response.messages.map(observedMessage);
  }

  async readChannelHistory(input: {
    channelId: string;
    oldest?: string;
    latest?: string;
    limit?: number;
  }): Promise<SlackObservedMessage[]> {
    return this.readConversationHistory(input);
  }

  async readConversationHistory(input: {
    channelId: string;
    oldest?: string;
    latest?: string;
    limit?: number;
  }): Promise<SlackObservedMessage[]> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.conversations.history;
    if (!method) {
      throw new Error("Slack SDK method is unavailable: conversations.history");
    }
    const result = parseSlackObject(
      await method.call(this.client.conversations, {
        channel: input.channelId,
        oldest: input.oldest,
        latest: input.latest,
        inclusive: true,
        limit: input.limit ?? 100,
      }),
      "Slack conversations.history response"
    );
    assertSlackSuccess("conversations.history", result);
    return HistoryResponseSchema.parse(result).messages.map(observedMessage);
  }

  async waitForBotReplies(input: {
    channelId: string;
    threadTs: string;
    botUserId: string;
    timeoutMs: number;
    pollMs?: number;
    settleMs?: number;
  }): Promise<SlackThreadReplyWaitResult> {
    const startedAt = this.monotonicNow();
    const pollMs = input.pollMs ?? this.config.pollMs;
    const settleMs = input.settleMs ?? 0;
    const deadline = startedAt + input.timeoutMs;
    let lastReplyChangeAt: number | undefined;
    let replySignature = "";
    let replies: SlackObservedMessage[] = [];

    while (true) {
      const messages = await this.readThread(input);
      replies = messages.filter(
        (message) => message.ts !== input.threadTs && message.userId === input.botUserId
      );
      if (replies.length > 0) {
        const nextSignature = replies.map((reply) => reply.ts).join("\n");
        if (nextSignature !== replySignature) {
          replySignature = nextSignature;
          lastReplyChangeAt = this.monotonicNow();
        }
        if (
          lastReplyChangeAt !== undefined &&
          this.monotonicNow() - lastReplyChangeAt >= settleMs
        ) {
          return botReplyObservation(
            input,
            replies,
            this.monotonicNow() - startedAt,
            false
          );
        }
      }
      const remainingMs = deadline - this.monotonicNow();
      if (remainingMs <= 0) break;
      await this.sleep(Math.min(pollMs, remainingMs));
    }
    return botReplyObservation(input, replies, this.monotonicNow() - startedAt, true);
  }

  async channelInfo(channelId: string): Promise<SlackJsonObject> {
    this.assertAllowedChannel(channelId);
    const method = this.client.conversations.info;
    if (!method) {
      throw new Error("Slack SDK method is unavailable: conversations.info");
    }
    const result = parseSlackObject(
      await method.call(this.client.conversations, { channel: channelId }),
      "Slack conversations.info response"
    );
    assertSlackSuccess("conversations.info", result);
    return ChannelInfoResponseSchema.parse(result).channel;
  }

  async assertChannelMember(channelId: string): Promise<void> {
    const channel = await this.channelInfo(channelId);
    if (channel.is_member !== true) {
      throw new Error(
        `Slack identity is not a member of the evaluation channel: ${channelId}`
      );
    }
  }

  async listPins(channelId: string): Promise<SlackJsonObject[]> {
    this.assertAllowedChannel(channelId);
    const method = this.client.pins?.list;
    if (!method) throw new Error("Slack SDK method is unavailable: pins.list");
    const result = parseSlackObject(
      await method.call(this.client.pins, { channel: channelId }),
      "Slack pins.list response"
    );
    assertSlackSuccess("pins.list", result);
    return PinsResponseSchema.parse(result).items;
  }

  async fileInfo(fileId: string): Promise<SlackJsonObject> {
    const method = this.client.files?.info;
    if (!method) throw new Error("Slack SDK method is unavailable: files.info");
    const result = parseSlackObject(
      await method.call(this.client.files, { file: fileId }),
      "Slack files.info response"
    );
    assertSlackSuccess("files.info", result);
    return FileInfoResponseSchema.parse(result).file;
  }

  async downloadFile(fileId: string): Promise<Uint8Array> {
    const file = await this.fileInfo(fileId);
    const metadata = FileDownloadMetadataSchema.parse(file);
    const url = metadata.url_private_download ?? metadata.url_private!;
    const response = await this.fetchImpl(url, {
      headers: { authorization: `Bearer ${this.config.token}` },
    });
    if (!response.ok) {
      throw new Error(`Slack file download failed with HTTP ${response.status}`);
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  private async observeThread(
    target: Extract<SlackObservationTarget, { kind: "thread" }>
  ): Promise<SlackObservation> {
    const lookup = `${target.channelId}:${target.threadTs}${
      target.replyUserId ? `:replyUser=${target.replyUserId}` : ""
    }`;
    try {
      const thread = await this.readThread(target);
      const messages = target.replyUserId
        ? thread.filter(
            (message) =>
              message.ts !== target.threadTs && message.userId === target.replyUserId
          )
        : thread;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "thread",
        lookup,
        ...(messages.length === 0
          ? {}
          : {
              resource: {
                channelId: target.channelId,
                threadTs: target.threadTs,
                messages,
              },
            }),
        now: this.now,
      });
    } catch (error) {
      if (!isSlackMissing(error, ["message_not_found", "thread_not_found"])) {
        throw error;
      }
      return createExternalObservation({
        provider: this.provider,
        resourceType: "thread",
        lookup,
        now: this.now,
      });
    }
  }

  private async observeChannel(
    target: Extract<SlackObservationTarget, { kind: "channel" }>
  ): Promise<SlackObservation> {
    try {
      const metadata = await this.channelInfo(target.channelId);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "channel",
        lookup: target.channelId,
        resource: { channelId: target.channelId, metadata },
        now: this.now,
      });
    } catch (error) {
      if (!isSlackMissing(error, ["channel_not_found"])) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "channel",
        lookup: target.channelId,
        now: this.now,
      });
    }
  }

  private async observePin(
    target: Extract<SlackObservationTarget, { kind: "pin" }>
  ): Promise<SlackObservation> {
    const lookup = `${target.channelId}:${target.messageTs}`;
    try {
      const item = (await this.listPins(target.channelId)).find((candidate) => {
        const parsed = PinnedMessageSchema.safeParse(candidate);
        return parsed.success && parsed.data.message.ts === target.messageTs;
      });
      return createExternalObservation({
        provider: this.provider,
        resourceType: "pin",
        lookup,
        ...(item === undefined
          ? {}
          : {
              resource: {
                channelId: target.channelId,
                messageTs: target.messageTs,
                item,
              },
            }),
        now: this.now,
      });
    } catch (error) {
      if (!isSlackMissing(error, ["channel_not_found"])) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "pin",
        lookup,
        now: this.now,
      });
    }
  }

  private async observeFile(
    target: Extract<SlackObservationTarget, { kind: "file" }>
  ): Promise<SlackObservation> {
    try {
      const metadata = await this.fileInfo(target.fileId);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "file",
        lookup: target.fileId,
        resource: { fileId: target.fileId, metadata },
        now: this.now,
      });
    } catch (error) {
      if (!isSlackMissing(error, ["file_not_found", "file_deleted"])) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "file",
        lookup: target.fileId,
        now: this.now,
      });
    }
  }
}

function botReplyObservation(
  input: { channelId: string; threadTs: string; botUserId: string },
  messages: SlackObservedMessage[],
  elapsedMs: number,
  timedOut: boolean
): SlackThreadReplyWaitResult {
  return {
    channelId: input.channelId,
    threadTs: input.threadTs,
    botUserId: input.botUserId,
    messages,
    elapsedMs,
    timedOut,
  };
}

function slackApiError(method: string, result: object): Error {
  const code = slackErrorCode(result);
  const error = new Error(
    `Slack ${method} failed${code === undefined ? "" : `: ${code}`}`
  );
  Object.assign(error, { data: result });
  return error;
}

function assertSlackSuccess(method: string, result: SlackJsonObject): void {
  if (result.ok === false) throw slackApiError(method, result);
}

function isSlackMissing(error: unknown, codes: readonly string[]): boolean {
  const code = slackErrorCode(error);
  return code !== undefined && codes.includes(code);
}

function slackErrorCode(value: unknown): string | undefined {
  const parsed = SlackErrorSchema.safeParse(value);
  return parsed.success ? (parsed.data.error ?? parsed.data.data?.error) : undefined;
}
