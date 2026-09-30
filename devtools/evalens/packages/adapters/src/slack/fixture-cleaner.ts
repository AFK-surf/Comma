import type { SlackAdapterOptions, SlackWebClient } from "./types";
import {
  parseSlackObject,
  SlackClientBoundary,
  type SlackJsonObject,
} from "./internal";

/** Best-effort teardown for Slack resources created by an evaluation run. */
export class SlackFixtureCleaner extends SlackClientBoundary {
  constructor(config: SlackAdapterOptions, client?: SlackWebClient) {
    super(config, client);
  }

  async cleanup(action: () => Promise<unknown>): Promise<string | undefined> {
    try {
      await action();
      return undefined;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return /(?:message_not_found|file_deleted|file_not_found|no_reaction|not_pinned|no_pin)/u.test(
        message
      )
        ? undefined
        : message;
    }
  }

  async deleteMessage(channelId: string, ts: string): Promise<void> {
    this.assertAllowedChannel(channelId);
    const method = this.client.chat.delete;
    if (!method) throw new Error("Slack SDK method is unavailable: chat.delete");
    await method.call(this.client.chat, { channel: channelId, ts });
  }

  async deleteFile(fileId: string): Promise<void> {
    const method = this.client.files?.delete;
    if (!method) throw new Error("Slack SDK method is unavailable: files.delete");
    await method.call(this.client.files, { file: fileId });
  }

  async removeReaction(input: {
    channelId: string;
    ts: string;
    name: string;
  }): Promise<void> {
    this.assertAllowedChannel(input.channelId);
    const method = this.client.reactions?.remove;
    if (!method) throw new Error("Slack SDK method is unavailable: reactions.remove");
    await method.call(this.client.reactions, {
      channel: input.channelId,
      timestamp: input.ts,
      name: input.name,
    });
  }

  async unpinMessage(channelId: string, ts: string): Promise<void> {
    this.assertAllowedChannel(channelId);
    const method = this.client.pins?.remove;
    if (!method) throw new Error("Slack SDK method is unavailable: pins.remove");
    await method.call(this.client.pins, { channel: channelId, timestamp: ts });
  }

  /**
   * Narrow escape hatch for cleanup methods that the official SDK does not expose
   * as typed helpers yet (currently canvases.delete).
   */
  async apiCall(
    channelId: string,
    methodName: string,
    input: SlackJsonObject
  ): Promise<SlackJsonObject> {
    this.assertAllowedChannel(channelId);
    const method = this.client.apiCall;
    if (!method) throw new Error(`Slack SDK method is unavailable: ${methodName}`);
    return parseSlackObject(
      await method.call(this.client, methodName, input),
      `Slack ${methodName} response`
    );
  }
}
