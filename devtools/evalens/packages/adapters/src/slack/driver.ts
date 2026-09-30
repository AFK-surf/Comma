import type {
  SlackAdapterOptions,
  SlackActorIdentity,
  SlackPostedMessage,
  SlackWebClient,
} from "./types";
import { z } from "zod";
import { postedMessage, SlackClientBoundary } from "./internal";

const UploadedFileSchema = z
  .object({ id: z.string().min(1), permalink: z.string().optional() })
  .loose();
const UploadBatchSchema = z.object({ files: z.array(UploadedFileSchema) }).loose();
const UploadResponseSchema = z.object({ files: z.array(z.unknown()) }).loose();

/** Sends the deterministic user/setup actions that drive a Slack evaluation. */
export class SlackDriver extends SlackClientBoundary {
  constructor(config: SlackAdapterOptions, client?: SlackWebClient) {
    super(config, client);
  }

  async preflight(): Promise<SlackActorIdentity> {
    const response = await this.client.auth.test();
    if (!response.ok) throw new Error("Slack auth.test failed");
    if (!response.team_id || !response.user_id) {
      throw new Error("Slack auth.test did not return workspace and user identity");
    }
    if (response.team_id !== this.config.workspaceId) {
      throw new Error(
        `Slack driver workspace mismatch: expected ${this.config.workspaceId}, got ${response.team_id}`
      );
    }
    if (this.config.expectedUserId && response.user_id !== this.config.expectedUserId) {
      throw new Error(
        `Slack actor mismatch: expected ${this.config.expectedUserId}, got ${response.user_id}`
      );
    }
    return {
      workspaceId: response.team_id,
      userId: response.user_id,
      ...(response.bot_id ? { botId: response.bot_id } : {}),
    };
  }

  async postMention(input: {
    channelId: string;
    botUserId: string;
    text: string;
  }): Promise<SlackPostedMessage> {
    const botUserId = input.botUserId.trim();
    if (!botUserId) throw new Error("botUserId is required");
    const text = input.text.trim();
    if (!text) throw new Error("text is required");
    return this.postMessage({
      channelId: input.channelId,
      text: `<@${botUserId}> ${text}`,
    });
  }

  async postMessage(input: {
    channelId: string;
    text: string;
    threadTs?: string;
  }): Promise<SlackPostedMessage> {
    this.assertAllowedChannel(input.channelId);
    const text = input.text.trim();
    if (!text) throw new Error("text is required");
    const response = await this.client.chat.postMessage({
      channel: input.channelId,
      text,
      ...(input.threadTs ? { thread_ts: input.threadTs } : {}),
    });
    return postedMessage(response, text, input.threadTs);
  }

  async postThreadMessage(input: {
    channelId: string;
    threadTs: string;
    text: string;
  }): Promise<SlackPostedMessage> {
    return this.postMessage(input);
  }

  async uploadTextFile(input: {
    channelId: string;
    filename: string;
    content: string;
    title?: string;
    threadTs?: string;
  }): Promise<{ fileId: string; permalink?: string }> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.files?.uploadV2;
    if (!method) throw new Error("Slack SDK method is unavailable: files.uploadV2");
    const filename = input.filename.trim();
    if (!filename) throw new Error("filename is required");
    const result = UploadResponseSchema.parse(
      await method.call(this.client.files, {
        channel_id: input.channelId,
        filename,
        title: input.title,
        content: input.content,
        thread_ts: input.threadTs,
      })
    );
    const files = result.files.flatMap((entry) => {
      const direct = UploadedFileSchema.safeParse(entry);
      if (direct.success) return [direct.data];
      const batch = UploadBatchSchema.safeParse(entry);
      if (batch.success) return batch.data.files;
      throw new Error(`Slack files.uploadV2 returned malformed file metadata`);
    });
    const file = files[0];
    if (!file) throw new Error("Slack files.uploadV2 returned no uploaded file");
    return {
      fileId: file.id,
      ...(file.permalink ? { permalink: file.permalink } : {}),
    };
  }

  async addReaction(input: {
    channelId: string;
    ts: string;
    name: string;
  }): Promise<void> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.reactions?.add;
    if (!method) throw new Error("Slack SDK method is unavailable: reactions.add");
    const name = input.name.trim();
    if (!name) throw new Error("reaction name is required");
    await method.call(this.client.reactions, {
      channel: input.channelId,
      timestamp: input.ts,
      name,
    });
  }

  async pinMessage(input: { channelId: string; ts: string }): Promise<void> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.pins?.add;
    if (!method) throw new Error("Slack SDK method is unavailable: pins.add");
    await method.call(this.client.pins, {
      channel: input.channelId,
      timestamp: input.ts,
    });
  }

  async setChannelTopic(channelId: string, topic: string): Promise<void> {
    this.assertAllowedChannel(channelId);
    const method = this.client.conversations.setTopic;
    if (!method) {
      throw new Error("Slack SDK method is unavailable: conversations.setTopic");
    }
    await method.call(this.client.conversations, { channel: channelId, topic });
  }

  async setChannelPurpose(channelId: string, purpose: string): Promise<void> {
    this.assertAllowedChannel(channelId);
    const method = this.client.conversations.setPurpose;
    if (!method) {
      throw new Error("Slack SDK method is unavailable: conversations.setPurpose");
    }
    await method.call(this.client.conversations, { channel: channelId, purpose });
  }
}
